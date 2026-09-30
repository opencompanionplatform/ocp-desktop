//! Gemini Live transcription transport for Voice Realtime V2.
//!
//! The Runtime owns microphone capture and client-side VAD. Kernel owns this
//! provider session and the Gemini credential. Audio is sent as mono PCM16 at
//! 16 kHz only while the local VAD reports an active utterance. The worker uses
//! a short socket read timeout so one blocking WebSocket can multiplex outgoing
//! audio/control commands and incoming interim/final transcripts without an
//! async runtime.

use std::collections::VecDeque;
use std::fmt;
use std::io::{self, ErrorKind};
use std::net::TcpStream;
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use base64::Engine as _;
use serde_json::{json, Value};
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{connect, Error as WebSocketError, Message, WebSocket};

pub const LIVE_TRANSCRIBE_MODEL: &str = "gemini-3.5-transcribe-live";
pub const LIVE_TRANSCRIBE_SAMPLE_RATE: u32 = 16_000;
const LIVE_WS_ENDPOINT: &str = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent";
const SETUP_READ_TIMEOUT: Duration = Duration::from_secs(5);
const READ_POLL_INTERVAL: Duration = Duration::from_millis(25);

fn trace_enabled() -> bool {
    std::env::var("OCP_GEMINI_ASR_TRACE").ok().as_deref() == Some("1")
}

fn trace(message: impl AsRef<str>) {
    if trace_enabled() {
        eprintln!("[gemini-asr] {}", message.as_ref());
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GeminiAsrEvent {
    Ready,
    Interim(String),
    Final(String),
    TurnComplete,
    Interrupted,
    Error(&'static str),
    Closed,
}

#[derive(Debug)]
pub enum GeminiAsrStartError {
    MissingCredential,
    WorkerSpawnFailed,
}

impl fmt::Display for GeminiAsrStartError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingCredential => f.write_str("Gemini ASR credential is missing"),
            Self::WorkerSpawnFailed => f.write_str("Gemini ASR worker could not be started"),
        }
    }
}

impl std::error::Error for GeminiAsrStartError {}

#[derive(Debug)]
enum GeminiAsrCommand {
    ActivityStart,
    Audio(Vec<u8>),
    ActivityEnd,
    Close,
}

/// Cloneable command side of one Gemini Live ASR session. Kernel can keep this
/// beside its Runtime input handler while a separate pump thread owns the event
/// stream and forwards transcript events back to Runtime.
#[derive(Clone)]
pub struct GeminiLiveAsrControl {
    commands: Sender<GeminiAsrCommand>,
}

impl GeminiLiveAsrControl {
    pub fn activity_start(&self) -> bool {
        self.commands.send(GeminiAsrCommand::ActivityStart).is_ok()
    }

    pub fn send_pcm16(&self, pcm_le: Vec<u8>) -> bool {
        if pcm_le.is_empty() || pcm_le.len() % 2 != 0 {
            return false;
        }
        self.commands.send(GeminiAsrCommand::Audio(pcm_le)).is_ok()
    }

    pub fn activity_end(&self) -> bool {
        self.commands.send(GeminiAsrCommand::ActivityEnd).is_ok()
    }

    pub fn close(&self) -> bool {
        self.commands.send(GeminiAsrCommand::Close).is_ok()
    }
}

/// Event side of one Gemini Live ASR session. It owns the network worker join
/// handle so the transport can be shut down deterministically once all command
/// handles have been dropped or explicitly closed.
pub struct GeminiLiveAsrEvents {
    events: Receiver<GeminiAsrEvent>,
    worker: Option<JoinHandle<()>>,
}

impl GeminiLiveAsrEvents {
    pub fn recv(&self) -> Option<GeminiAsrEvent> {
        self.events.recv().ok()
    }

    pub fn try_recv(&self) -> Option<GeminiAsrEvent> {
        self.events.try_recv().ok()
    }

    pub fn join(mut self) {
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

/// Start one provider session and split it into command/event halves.
pub fn start_live_asr(
    api_key: String,
    language_codes: Vec<String>,
) -> Result<(GeminiLiveAsrControl, GeminiLiveAsrEvents), GeminiAsrStartError> {
    if api_key.trim().is_empty() {
        return Err(GeminiAsrStartError::MissingCredential);
    }
    let (command_tx, command_rx) = mpsc::channel();
    let (event_tx, event_rx) = mpsc::channel();
    let worker = thread::Builder::new()
        .name("ocp-gemini-live-asr".to_owned())
        .spawn(move || run_worker(api_key, language_codes, command_rx, event_tx))
        .map_err(|_| GeminiAsrStartError::WorkerSpawnFailed)?;
    Ok((
        GeminiLiveAsrControl {
            commands: command_tx,
        },
        GeminiLiveAsrEvents {
            events: event_rx,
            worker: Some(worker),
        },
    ))
}

fn run_worker(
    api_key: String,
    language_codes: Vec<String>,
    commands: Receiver<GeminiAsrCommand>,
    events: Sender<GeminiAsrEvent>,
) {
    let url = format!("{LIVE_WS_ENDPOINT}?key={api_key}");
    let Ok((mut socket, response)) = connect(url.as_str()) else {
        let _ = events.send(GeminiAsrEvent::Error("asr-connect-failed"));
        return;
    };
    trace(format!(
        "websocket connected status={}",
        response.status().as_u16()
    ));
    // Provider setup can take substantially longer than one realtime audio
    // cadence on corporate/VPN networks. Use a generous timeout until
    // setupComplete arrives, then switch to the short poll interval needed to
    // interleave outgoing 20 ms PCM frames with incoming transcript events.
    set_read_timeout(&mut socket, SETUP_READ_TIMEOUT);

    if socket
        .send(Message::Text(
            setup_message(&language_codes).to_string().into(),
        ))
        .is_err()
    {
        let _ = events.send(GeminiAsrEvent::Error("asr-setup-send-failed"));
        return;
    }
    trace("setup message sent");

    let mut closing = false;
    let mut ready = false;
    let mut pending = VecDeque::<GeminiAsrCommand>::new();
    while !closing {
        loop {
            match commands.try_recv() {
                Ok(GeminiAsrCommand::Close) | Err(TryRecvError::Disconnected) => {
                    closing = true;
                    break;
                }
                Ok(command) => {
                    if ready {
                        if let Err(reason) = send_worker_command(&mut socket, command) {
                            let _ = events.send(GeminiAsrEvent::Error(reason));
                            closing = true;
                            break;
                        }
                    } else {
                        pending.push_back(command);
                    }
                }
                Err(TryRecvError::Empty) => break,
            }
        }
        if closing {
            break;
        }

        match socket.read() {
            Ok(Message::Text(text)) => {
                if let Ok(value) = serde_json::from_str::<Value>(text.as_str()) {
                    if !handle_server_value(
                        &mut socket,
                        &value,
                        "text",
                        &mut ready,
                        &mut pending,
                        &events,
                    ) {
                        closing = true;
                    }
                }
            }
            Ok(Message::Close(frame)) => {
                if let Some(frame) = frame {
                    trace(format!(
                        "close frame code={:?} reason_len={}",
                        frame.code,
                        frame.reason.len()
                    ));
                } else {
                    trace("close frame without reason");
                }
                break;
            }
            Ok(Message::Ping(payload)) => {
                trace("ping frame");
                let _ = socket.send(Message::Pong(payload));
            }
            Ok(Message::Binary(payload)) => {
                if let Some(value) = decode_binary_server_value(&payload) {
                    if !handle_server_value(
                        &mut socket,
                        &value,
                        "binary",
                        &mut ready,
                        &mut pending,
                        &events,
                    ) {
                        closing = true;
                    }
                } else {
                    trace(format!("binary frame bytes={} non-json", payload.len()));
                }
            }
            Ok(_) => {}
            Err(WebSocketError::Io(error)) if is_poll_timeout(&error) => {}
            Err(WebSocketError::ConnectionClosed | WebSocketError::AlreadyClosed) => break,
            Err(_) => {
                let _ = events.send(GeminiAsrEvent::Error("asr-websocket-failed"));
                break;
            }
        }
    }

    let _ = socket.close(None);
    let _ = events.send(GeminiAsrEvent::Closed);
}

fn decode_binary_server_value(payload: &[u8]) -> Option<Value> {
    serde_json::from_slice::<Value>(payload).ok()
}

fn handle_server_value(
    socket: &mut WebSocket<MaybeTlsStream<TcpStream>>,
    value: &Value,
    frame_kind: &str,
    ready: &mut bool,
    pending: &mut VecDeque<GeminiAsrCommand>,
    events: &Sender<GeminiAsrEvent>,
) -> bool {
    if trace_enabled() {
        let keys = value
            .as_object()
            .map(|object| object.keys().cloned().collect::<Vec<_>>().join(","))
            .unwrap_or_else(|| "non-object".to_owned());
        trace(format!("{frame_kind} frame keys={keys}"));
    }

    for event in parse_server_message(value) {
        let terminal_error = matches!(event, GeminiAsrEvent::Error(_));
        if event == GeminiAsrEvent::Ready {
            *ready = true;
            set_read_timeout(socket, READ_POLL_INTERVAL);
            while let Some(command) = pending.pop_front() {
                if let Err(reason) = send_worker_command(socket, command) {
                    let _ = events.send(GeminiAsrEvent::Error(reason));
                    return false;
                }
            }
        }
        let _ = events.send(event);
        if terminal_error {
            return false;
        }
    }
    true
}

fn send_worker_command(
    socket: &mut WebSocket<MaybeTlsStream<TcpStream>>,
    command: GeminiAsrCommand,
) -> Result<(), &'static str> {
    match command {
        GeminiAsrCommand::ActivityStart => {
            send_json(socket, activity_start_message()).map_err(|_| "asr-activity-start-failed")
        }
        GeminiAsrCommand::Audio(pcm) => {
            send_json(socket, audio_message(&pcm)).map_err(|_| "asr-audio-send-failed")
        }
        GeminiAsrCommand::ActivityEnd => {
            send_json(socket, activity_end_message()).map_err(|_| "asr-activity-end-failed")
        }
        GeminiAsrCommand::Close => Ok(()),
    }
}

fn set_read_timeout(socket: &mut WebSocket<MaybeTlsStream<TcpStream>>, timeout: Duration) {
    match socket.get_mut() {
        MaybeTlsStream::Plain(stream) => {
            let _ = stream.set_read_timeout(Some(timeout));
        }
        MaybeTlsStream::NativeTls(stream) => {
            let _ = stream.get_mut().set_read_timeout(Some(timeout));
        }
        _ => {}
    }
}

fn is_poll_timeout(error: &io::Error) -> bool {
    matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut)
}

fn send_json(
    socket: &mut WebSocket<MaybeTlsStream<TcpStream>>,
    value: Value,
) -> Result<(), WebSocketError> {
    socket.send(Message::Text(value.to_string().into()))
}

fn setup_message(language_codes: &[String]) -> Value {
    json!({
        "setup": {
            "model": format!("models/{LIVE_TRANSCRIBE_MODEL}"),
            "generationConfig": {
                "responseModalities": ["TEXT"]
            },
            "realtimeInputConfig": {
                "automaticActivityDetection": {
                    "disabled": true
                }
            },
            "inputAudioTranscription": {
                "languageCodes": language_codes,
                "mode": "SMART"
            }
        }
    })
}

fn activity_start_message() -> Value {
    json!({"realtimeInput": {"activityStart": {}}})
}

fn activity_end_message() -> Value {
    json!({"realtimeInput": {"activityEnd": {}}})
}

fn audio_message(pcm_le: &[u8]) -> Value {
    json!({
        "realtimeInput": {
            "audio": {
                "data": base64::engine::general_purpose::STANDARD.encode(pcm_le),
                "mimeType": format!("audio/pcm;rate={LIVE_TRANSCRIBE_SAMPLE_RATE}")
            }
        }
    })
}

fn provider_error_reason(value: &Value) -> Option<&'static str> {
    let error = value.get("error")?;
    let status = error
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let code = error
        .get("code")
        .and_then(Value::as_i64)
        .unwrap_or_default();
    Some(match status {
        "UNAUTHENTICATED" => "provider-auth-failed",
        "PERMISSION_DENIED" => "provider-permission-denied",
        "RESOURCE_EXHAUSTED" => "provider-rate-limited",
        "INVALID_ARGUMENT" => "asr-invalid-setup",
        "NOT_FOUND" => "asr-model-unavailable",
        "UNAVAILABLE" => "asr-provider-unavailable",
        _ if code == 401 => "provider-auth-failed",
        _ if code == 403 => "provider-permission-denied",
        _ if code == 429 => "provider-rate-limited",
        _ => "asr-provider-error",
    })
}

fn parse_server_message(value: &Value) -> Vec<GeminiAsrEvent> {
    let mut events = Vec::new();
    if let Some(reason) = provider_error_reason(value) {
        events.push(GeminiAsrEvent::Error(reason));
        return events;
    }
    if value.get("setupComplete").is_some() {
        events.push(GeminiAsrEvent::Ready);
    }
    let Some(content) = value.get("serverContent") else {
        return events;
    };
    if let Some(text) = content
        .get("interimInputTranscription")
        .and_then(|transcription| transcription.get("text"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
    {
        events.push(GeminiAsrEvent::Interim(text.to_owned()));
    }
    if let Some(text) = content
        .get("inputTranscription")
        .and_then(|transcription| transcription.get("text"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
    {
        events.push(GeminiAsrEvent::Final(text.to_owned()));
    }
    if content
        .get("interrupted")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        events.push(GeminiAsrEvent::Interrupted);
    }
    if content
        .get("turnComplete")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        events.push(GeminiAsrEvent::TurnComplete);
    }
    events
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn setup_uses_manual_vad_and_live_transcription_model() {
        let setup = setup_message(&["th-TH".to_owned(), "en-US".to_owned()]);
        assert_eq!(
            setup["setup"]["model"],
            json!("models/gemini-3.5-transcribe-live")
        );
        assert_eq!(
            setup["setup"]["realtimeInputConfig"]["automaticActivityDetection"]["disabled"],
            json!(true)
        );
        assert_eq!(
            setup["setup"]["inputAudioTranscription"]["languageCodes"],
            json!(["th-TH", "en-US"])
        );
    }

    #[test]
    fn pcm_audio_is_encoded_as_16khz_realtime_input() {
        let message = audio_message(&[0, 1, 2, 3]);
        assert_eq!(
            message["realtimeInput"]["audio"]["mimeType"],
            json!("audio/pcm;rate=16000")
        );
        assert_eq!(message["realtimeInput"]["audio"]["data"], json!("AAECAw=="));
    }

    #[test]
    fn parser_returns_ready_interim_final_and_turn_events() {
        assert_eq!(
            parse_server_message(&json!({"setupComplete": {}})),
            vec![GeminiAsrEvent::Ready]
        );
        let events = parse_server_message(&json!({
            "serverContent": {
                "interimInputTranscription": {"text": "สวัส"},
                "inputTranscription": {"text": "สวัสดีครับ"},
                "turnComplete": true
            }
        }));
        assert_eq!(
            events,
            vec![
                GeminiAsrEvent::Interim("สวัส".to_owned()),
                GeminiAsrEvent::Final("สวัสดีครับ".to_owned()),
                GeminiAsrEvent::TurnComplete,
            ]
        );
    }

    #[test]
    fn parser_exposes_provider_interruption_without_transcript_data_loss() {
        let events = parse_server_message(&json!({
            "serverContent": {
                "inputTranscription": {"text": "new turn"},
                "interrupted": true
            }
        }));
        assert_eq!(
            events,
            vec![
                GeminiAsrEvent::Final("new turn".to_owned()),
                GeminiAsrEvent::Interrupted,
            ]
        );
    }

    #[test]
    fn binary_json_frame_decodes_setup_complete() {
        let value = decode_binary_server_value(br#"{"setupComplete":{}}"#)
            .expect("binary JSON frame should decode");
        assert_eq!(parse_server_message(&value), vec![GeminiAsrEvent::Ready]);
    }

    #[test]
    fn invalid_audio_is_rejected_before_worker_queue() {
        let (tx, _rx) = mpsc::channel();
        let control = GeminiLiveAsrControl { commands: tx };
        assert!(!control.send_pcm16(vec![]));
        assert!(!control.send_pcm16(vec![1]));
    }
}
