//! Gemini 3.8 Live audio-to-audio transport for OCP Live Voice mode.
//!
//! Runtime owns microphone capture and client-side VAD. Kernel owns the
//! credential and this WebSocket session. Input is mono PCM16/16 kHz; output is
//! mono PCM16/24 kHz plus input/output transcription metadata.

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

pub const LIVE_VOICE_MODEL: &str = "gemini-3.8-live";
pub const LIVE_VOICE_INPUT_RATE: u32 = 16_000;
pub const LIVE_VOICE_OUTPUT_RATE: u32 = 24_000;
const LIVE_WS_ENDPOINT: &str = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent";
const SETUP_TIMEOUT: Duration = Duration::from_secs(5);
const READ_POLL_INTERVAL: Duration = Duration::from_millis(25);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GeminiLiveVoiceEvent {
    Ready,
    InputTranscript(String),
    OutputTranscript(String),
    Audio(Vec<u8>),
    TurnComplete,
    Interrupted,
    Error(&'static str),
    Closed,
}

#[derive(Debug)]
pub enum GeminiLiveVoiceStartError {
    MissingCredential,
    WorkerSpawnFailed,
}

impl fmt::Display for GeminiLiveVoiceStartError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingCredential => f.write_str("Gemini Live credential is missing"),
            Self::WorkerSpawnFailed => f.write_str("Gemini Live worker could not be started"),
        }
    }
}

impl std::error::Error for GeminiLiveVoiceStartError {}

#[derive(Debug)]
enum Command {
    ActivityStart,
    Audio(Vec<u8>),
    ActivityEnd,
    Close,
}

#[derive(Clone)]
pub struct GeminiLiveVoiceControl {
    commands: Sender<Command>,
}

impl GeminiLiveVoiceControl {
    pub fn activity_start(&self) -> bool {
        self.commands.send(Command::ActivityStart).is_ok()
    }

    pub fn send_pcm16(&self, pcm_le: Vec<u8>) -> bool {
        if pcm_le.is_empty() || pcm_le.len() % 2 != 0 {
            return false;
        }
        self.commands.send(Command::Audio(pcm_le)).is_ok()
    }

    pub fn activity_end(&self) -> bool {
        self.commands.send(Command::ActivityEnd).is_ok()
    }

    pub fn close(&self) -> bool {
        self.commands.send(Command::Close).is_ok()
    }
}

pub struct GeminiLiveVoiceEvents {
    events: Receiver<GeminiLiveVoiceEvent>,
    worker: Option<JoinHandle<()>>,
}

impl GeminiLiveVoiceEvents {
    pub fn recv(&self) -> Option<GeminiLiveVoiceEvent> {
        self.events.recv().ok()
    }

    pub fn try_recv(&self) -> Option<GeminiLiveVoiceEvent> {
        self.events.try_recv().ok()
    }

    pub fn join(mut self) {
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

pub fn start_live_voice(
    api_key: String,
    system_instruction: String,
) -> Result<(GeminiLiveVoiceControl, GeminiLiveVoiceEvents), GeminiLiveVoiceStartError> {
    if api_key.trim().is_empty() {
        return Err(GeminiLiveVoiceStartError::MissingCredential);
    }
    let instruction = system_instruction
        .trim()
        .chars()
        .take(2400)
        .collect::<String>();
    let (command_tx, command_rx) = mpsc::channel();
    let (event_tx, event_rx) = mpsc::channel();
    let worker = thread::Builder::new()
        .name("ocp-gemini-live-voice".to_owned())
        .spawn(move || run_worker(api_key, instruction, command_rx, event_tx))
        .map_err(|_| GeminiLiveVoiceStartError::WorkerSpawnFailed)?;
    Ok((
        GeminiLiveVoiceControl {
            commands: command_tx,
        },
        GeminiLiveVoiceEvents {
            events: event_rx,
            worker: Some(worker),
        },
    ))
}

fn run_worker(
    api_key: String,
    system_instruction: String,
    commands: Receiver<Command>,
    events: Sender<GeminiLiveVoiceEvent>,
) {
    let url = format!("{LIVE_WS_ENDPOINT}?key={api_key}");
    let Ok((mut socket, _)) = connect(url.as_str()) else {
        let _ = events.send(GeminiLiveVoiceEvent::Error("live-voice-connect-failed"));
        return;
    };
    set_read_timeout(&mut socket, SETUP_TIMEOUT);
    if send_json(&mut socket, setup_message(&system_instruction)).is_err() {
        let _ = events.send(GeminiLiveVoiceEvent::Error("live-voice-setup-send-failed"));
        return;
    }

    let mut ready = false;
    let mut closing = false;
    let mut pending = VecDeque::<Command>::new();
    while !closing {
        loop {
            match commands.try_recv() {
                Ok(Command::Close) | Err(TryRecvError::Disconnected) => {
                    closing = true;
                    break;
                }
                Ok(command) => {
                    if ready {
                        if send_command(&mut socket, command).is_err() {
                            let _ =
                                events.send(GeminiLiveVoiceEvent::Error("live-voice-send-failed"));
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

        let value = match socket.read() {
            Ok(Message::Text(text)) => serde_json::from_str::<Value>(text.as_str()).ok(),
            Ok(Message::Binary(payload)) => serde_json::from_slice::<Value>(&payload).ok(),
            Ok(Message::Ping(payload)) => {
                let _ = socket.send(Message::Pong(payload));
                None
            }
            Ok(Message::Close(_)) => break,
            Ok(_) => None,
            Err(WebSocketError::Io(error)) if is_poll_timeout(&error) => None,
            Err(WebSocketError::ConnectionClosed | WebSocketError::AlreadyClosed) => break,
            Err(_) => {
                let _ = events.send(GeminiLiveVoiceEvent::Error("live-voice-websocket-failed"));
                break;
            }
        };
        let Some(value) = value else { continue };
        for event in parse_server_message(&value) {
            if event == GeminiLiveVoiceEvent::Ready {
                ready = true;
                set_read_timeout(&mut socket, READ_POLL_INTERVAL);
                while let Some(command) = pending.pop_front() {
                    if send_command(&mut socket, command).is_err() {
                        let _ = events.send(GeminiLiveVoiceEvent::Error("live-voice-send-failed"));
                        closing = true;
                        break;
                    }
                }
            }
            let terminal_error = matches!(event, GeminiLiveVoiceEvent::Error(_));
            let _ = events.send(event);
            if terminal_error {
                closing = true;
                break;
            }
        }
    }
    let _ = socket.close(None);
    let _ = events.send(GeminiLiveVoiceEvent::Closed);
}

fn send_command(
    socket: &mut WebSocket<MaybeTlsStream<TcpStream>>,
    command: Command,
) -> Result<(), WebSocketError> {
    match command {
        Command::ActivityStart => send_json(socket, json!({"realtimeInput":{"activityStart":{}}})),
        Command::Audio(pcm) => send_json(
            socket,
            json!({"realtimeInput":{"audio":{
                "data": base64::engine::general_purpose::STANDARD.encode(pcm),
                "mimeType": "audio/pcm;rate=16000"
            }}}),
        ),
        Command::ActivityEnd => send_json(socket, json!({"realtimeInput":{"activityEnd":{}}})),
        Command::Close => Ok(()),
    }
}

fn setup_message(system_instruction: &str) -> Value {
    let instruction = if system_instruction.is_empty() {
        "You are the user's OCP desktop companion. Reply briefly and naturally."
    } else {
        system_instruction
    };
    json!({
        "setup": {
            "model": format!("models/{LIVE_VOICE_MODEL}"),
            "generationConfig": {"responseModalities": ["AUDIO"]},
            "systemInstruction": {"parts": [{"text": instruction}]},
            "realtimeInputConfig": {"automaticActivityDetection": {"disabled": true}},
            "inputAudioTranscription": {},
            "outputAudioTranscription": {}
        }
    })
}

fn parse_server_message(value: &Value) -> Vec<GeminiLiveVoiceEvent> {
    let mut events = Vec::new();
    if provider_error_reason(value).is_some() {
        events.push(GeminiLiveVoiceEvent::Error("live-voice-provider-error"));
        return events;
    }
    if value.get("setupComplete").is_some() {
        events.push(GeminiLiveVoiceEvent::Ready);
    }
    let Some(content) = value.get("serverContent") else {
        return events;
    };
    if let Some(text) = transcript_text(content, "inputTranscription") {
        events.push(GeminiLiveVoiceEvent::InputTranscript(text));
    }
    if let Some(text) = transcript_text(content, "outputTranscription") {
        events.push(GeminiLiveVoiceEvent::OutputTranscript(text));
    }
    if let Some(parts) = content
        .get("modelTurn")
        .and_then(|turn| turn.get("parts"))
        .and_then(Value::as_array)
    {
        for part in parts {
            let Some(inline) = part.get("inlineData").or_else(|| part.get("inline_data")) else {
                continue;
            };
            let mime = inline
                .get("mimeType")
                .or_else(|| inline.get("mime_type"))
                .and_then(Value::as_str)
                .unwrap_or_default();
            if !mime.starts_with("audio/pcm") {
                continue;
            }
            if let Some(encoded) = inline.get("data").and_then(Value::as_str) {
                if let Ok(audio) = base64::engine::general_purpose::STANDARD.decode(encoded) {
                    if !audio.is_empty() {
                        events.push(GeminiLiveVoiceEvent::Audio(audio));
                    }
                }
            }
        }
    }
    if content
        .get("interrupted")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        events.push(GeminiLiveVoiceEvent::Interrupted);
    }
    if content
        .get("turnComplete")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        events.push(GeminiLiveVoiceEvent::TurnComplete);
    }
    events
}

fn transcript_text(content: &Value, key: &str) -> Option<String> {
    content
        .get(key)
        .and_then(|item| item.get("text"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_owned)
}

fn provider_error_reason(value: &Value) -> Option<&'static str> {
    (value.get("error").is_some()).then_some("live-voice-provider-error")
}

fn send_json(
    socket: &mut WebSocket<MaybeTlsStream<TcpStream>>,
    value: Value,
) -> Result<(), WebSocketError> {
    socket.send(Message::Text(value.to_string().into()))
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn setup_uses_38_live_audio_and_manual_vad() {
        let setup = setup_message("ตอบสั้น ๆ");
        assert_eq!(setup["setup"]["model"], json!("models/gemini-3.8-live"));
        assert_eq!(
            setup["setup"]["generationConfig"]["responseModalities"],
            json!(["AUDIO"])
        );
        assert_eq!(
            setup["setup"]["realtimeInputConfig"]["automaticActivityDetection"]["disabled"],
            json!(true)
        );
    }

    #[test]
    fn parser_decodes_audio_and_transcripts_from_binary_json_shape() {
        let audio = base64::engine::general_purpose::STANDARD.encode([1u8, 2, 3, 4]);
        let events = parse_server_message(&json!({"serverContent":{
            "inputTranscription":{"text":"สวัสดี"},
            "outputTranscription":{"text":"สวัสดีค่ะ"},
            "modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":audio}}]},
            "turnComplete":true
        }}));
        assert_eq!(
            events[0],
            GeminiLiveVoiceEvent::InputTranscript("สวัสดี".to_owned())
        );
        assert_eq!(
            events[1],
            GeminiLiveVoiceEvent::OutputTranscript("สวัสดีค่ะ".to_owned())
        );
        assert_eq!(events[2], GeminiLiveVoiceEvent::Audio(vec![1, 2, 3, 4]));
        assert_eq!(events[3], GeminiLiveVoiceEvent::TurnComplete);
    }
}
