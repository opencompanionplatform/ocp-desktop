//! Conservative Gemini 3.8 Live audio-in/audio-out latency diagnostic.
//!
//! Streams a PCM16 WAV in real time with client-side activityStart/activityEnd,
//! then measures time from end-of-user-audio to the first 24 kHz model-audio
//! chunk. It intentionally starts reading model output only after activityEnd,
//! so the reported first-audio latency is conservative rather than optimistic.

use std::io::{self, ErrorKind};
use std::net::TcpStream;
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

use base64::Engine as _;
use ocp_llm_router::{CredentialStore, OsKeystoreCredentialStore};
use serde_json::{json, Value};
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{connect, Error as WebSocketError, Message, WebSocket};

const KEYSTORE_SERVICE: &str = "ocp-ai-provider";
const MODEL: &str = "gemini-3.8-live";
const ENDPOINT: &str = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent";
const INPUT_RATE: u32 = 16_000;
const FRAME_MS: u64 = 100;
const READY_TIMEOUT: Duration = Duration::from_secs(10);
const RESPONSE_TIMEOUT: Duration = Duration::from_secs(15);

fn main() {
    let wav_path = std::env::args_os()
        .nth(1)
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("gemini_thai.wav"));
    let (key, source) = credential();
    let Some(key) = key else {
        fail("Gemini credential is unavailable");
    };
    let (source_pcm, source_rate) = read_pcm16_wav(&wav_path)
        .unwrap_or_else(|error| fail(&format!("could not read {}: {error}", wav_path.display())));
    let pcm = resample_mono_pcm16(&source_pcm, source_rate, INPUT_RATE);
    if pcm.is_empty() {
        fail("input WAV produced no PCM samples");
    }

    println!("credential source: {source}");
    println!("model: {MODEL}");
    println!("input: {}", wav_path.display());
    println!(
        "audio duration: {:.2} s",
        pcm.len() as f64 / INPUT_RATE as f64
    );

    let url = format!("{ENDPOINT}?key={key}");
    let (mut socket, response) = connect(url.as_str())
        .unwrap_or_else(|error| fail(&format!("Live WebSocket connect failed: {error}")));
    println!("websocket status: {}", response.status());
    set_read_timeout(&mut socket, Duration::from_secs(5));
    send_json(
        &mut socket,
        json!({
            "setup": {
                "model": format!("models/{MODEL}"),
                "generationConfig": {
                    "responseModalities": ["AUDIO"]
                },
                "systemInstruction": {
                    "parts": [{"text": "ตอบกลับเป็นภาษาไทยสั้น ๆ หนึ่งประโยคอย่างเป็นธรรมชาติ"}]
                },
                "realtimeInputConfig": {
                    "automaticActivityDetection": {"disabled": true}
                },
                "inputAudioTranscription": {},
                "outputAudioTranscription": {}
            }
        }),
    )
    .unwrap_or_else(|error| fail(&format!("Live setup send failed: {error}")));

    let setup_started = Instant::now();
    if !wait_setup_complete(&mut socket, setup_started) {
        fail("Gemini 3.8 Live did not become ready before timeout");
    }
    let ready_ms = setup_started.elapsed().as_millis();
    println!("ready: {ready_ms} ms");

    send_json(&mut socket, json!({"realtimeInput": {"activityStart": {}}}))
        .unwrap_or_else(|error| fail(&format!("activityStart failed: {error}")));
    set_read_timeout(&mut socket, Duration::from_millis(50));
    let samples_per_frame = (u64::from(INPUT_RATE) * FRAME_MS / 1000) as usize;
    let audio_started = Instant::now();
    for frame in pcm.chunks(samples_per_frame) {
        let mut bytes = Vec::with_capacity(frame.len() * 2);
        for sample in frame {
            bytes.extend_from_slice(&sample.to_le_bytes());
        }
        send_json(
            &mut socket,
            json!({
                "realtimeInput": {
                    "audio": {
                        "data": base64::engine::general_purpose::STANDARD.encode(bytes),
                        "mimeType": "audio/pcm;rate=16000"
                    }
                }
            }),
        )
        .unwrap_or_else(|error| fail(&format!("audio send failed: {error}")));
        thread::sleep(Duration::from_millis(FRAME_MS));
    }
    send_json(&mut socket, json!({"realtimeInput": {"activityEnd": {}}}))
        .unwrap_or_else(|error| fail(&format!("activityEnd failed: {error}")));
    println!("audio sent: {} ms", audio_started.elapsed().as_millis());

    let speech_ended = Instant::now();
    let mut first_audio_ms = None;
    let mut turn_complete_ms = None;
    let mut audio_chunks = 0_u64;
    let mut audio_bytes = 0_usize;
    let mut input_transcript = String::new();
    let mut output_transcript = String::new();

    while speech_ended.elapsed() < RESPONSE_TIMEOUT {
        match socket.read() {
            Ok(Message::Text(text)) => {
                if let Ok(value) = serde_json::from_str::<Value>(text.as_str()) {
                    if handle_server_value(
                        &value,
                        speech_ended,
                        &mut first_audio_ms,
                        &mut turn_complete_ms,
                        &mut audio_chunks,
                        &mut audio_bytes,
                        &mut input_transcript,
                        &mut output_transcript,
                    ) {
                        break;
                    }
                }
            }
            Ok(Message::Binary(payload)) => {
                if let Ok(value) = serde_json::from_slice::<Value>(&payload) {
                    if handle_server_value(
                        &value,
                        speech_ended,
                        &mut first_audio_ms,
                        &mut turn_complete_ms,
                        &mut audio_chunks,
                        &mut audio_bytes,
                        &mut input_transcript,
                        &mut output_transcript,
                    ) {
                        break;
                    }
                }
            }
            Ok(Message::Ping(payload)) => {
                let _ = socket.send(Message::Pong(payload));
            }
            Ok(Message::Close(frame)) => {
                eprintln!("Live socket closed: {frame:?}");
                break;
            }
            Ok(_) => {}
            Err(WebSocketError::Io(error)) if is_poll_timeout(&error) => {}
            Err(error) => fail(&format!("Live receive failed: {error}")),
        }
    }
    let _ = socket.close(None);

    let Some(first_audio_ms) = first_audio_ms else {
        fail("Gemini 3.8 Live returned no audio before timeout");
    };
    println!(
        "[VOICE-LIVE-3.8] ok=true first_audio_after_end_ms={} turn_complete_after_end_ms={} audio_chunks={} audio_bytes={} input_transcript={} output_transcript={}",
        first_audio_ms,
        turn_complete_ms.unwrap_or_default(),
        audio_chunks,
        audio_bytes,
        sanitize_metric(&input_transcript),
        sanitize_metric(&output_transcript),
    );
}

#[allow(clippy::too_many_arguments)]
fn handle_server_value(
    value: &Value,
    speech_ended: Instant,
    first_audio_ms: &mut Option<u128>,
    turn_complete_ms: &mut Option<u128>,
    audio_chunks: &mut u64,
    audio_bytes: &mut usize,
    input_transcript: &mut String,
    output_transcript: &mut String,
) -> bool {
    let Some(content) = value.get("serverContent") else {
        return false;
    };
    if let Some(text) = content
        .get("inputTranscription")
        .and_then(|item| item.get("text"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
    {
        *input_transcript = text.to_owned();
    }
    if let Some(text) = content
        .get("outputTranscription")
        .and_then(|item| item.get("text"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
    {
        if !output_transcript.is_empty() && !text.starts_with(output_transcript.as_str()) {
            output_transcript.push(' ');
        }
        *output_transcript = text.to_owned();
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
            let Some(data) = inline.get("data").and_then(Value::as_str) else {
                continue;
            };
            if let Ok(audio) = base64::engine::general_purpose::STANDARD.decode(data) {
                if !audio.is_empty() {
                    first_audio_ms.get_or_insert_with(|| speech_ended.elapsed().as_millis());
                    *audio_chunks += 1;
                    *audio_bytes += audio.len();
                }
            }
        }
    }
    if content
        .get("interrupted")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        fail("Gemini 3.8 Live response was interrupted during diagnostic");
    }
    if content
        .get("turnComplete")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        *turn_complete_ms = Some(speech_ended.elapsed().as_millis());
        return true;
    }
    false
}

fn wait_setup_complete(
    socket: &mut WebSocket<MaybeTlsStream<TcpStream>>,
    started: Instant,
) -> bool {
    while started.elapsed() < READY_TIMEOUT {
        match socket.read() {
            Ok(Message::Text(text)) => {
                if serde_json::from_str::<Value>(text.as_str())
                    .ok()
                    .is_some_and(|value| value.get("setupComplete").is_some())
                {
                    return true;
                }
            }
            Ok(Message::Binary(payload)) => {
                if serde_json::from_slice::<Value>(&payload)
                    .ok()
                    .is_some_and(|value| value.get("setupComplete").is_some())
                {
                    return true;
                }
            }
            Ok(Message::Ping(payload)) => {
                let _ = socket.send(Message::Pong(payload));
            }
            Ok(Message::Close(_)) => return false,
            Ok(_) => {}
            Err(WebSocketError::Io(error)) if is_poll_timeout(&error) => {}
            Err(_) => return false,
        }
    }
    false
}

fn credential() -> (Option<String>, &'static str) {
    match std::env::var("GEMINI_API_KEY").ok() {
        Some(key) if !key.trim().is_empty() => (Some(key), "env:GEMINI_API_KEY"),
        _ => (
            OsKeystoreCredentialStore::new(KEYSTORE_SERVICE).get("gemini-cloud"),
            "OS keystore:gemini-cloud",
        ),
    }
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

fn read_pcm16_wav(path: &Path) -> Result<(Vec<i16>, u32), String> {
    let bytes = std::fs::read(path).map_err(|error| error.to_string())?;
    if bytes.len() < 44 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err("not a RIFF/WAVE file".to_owned());
    }
    let mut offset = 12usize;
    let mut format: Option<(u16, u32)> = None;
    let mut data: Option<&[u8]> = None;
    while offset + 8 <= bytes.len() {
        let id = &bytes[offset..offset + 4];
        let size = u32::from_le_bytes(bytes[offset + 4..offset + 8].try_into().unwrap()) as usize;
        let start = offset + 8;
        let end = start.saturating_add(size);
        if end > bytes.len() {
            return Err("WAV chunk exceeds file length".to_owned());
        }
        if id == b"fmt " && size >= 16 {
            let audio_format = u16::from_le_bytes(bytes[start..start + 2].try_into().unwrap());
            let channels = u16::from_le_bytes(bytes[start + 2..start + 4].try_into().unwrap());
            let sample_rate = u32::from_le_bytes(bytes[start + 4..start + 8].try_into().unwrap());
            let bits = u16::from_le_bytes(bytes[start + 14..start + 16].try_into().unwrap());
            if audio_format != 1 || bits != 16 || channels == 0 {
                return Err("unsupported WAV format".to_owned());
            }
            format = Some((channels, sample_rate));
        } else if id == b"data" {
            data = Some(&bytes[start..end]);
        }
        offset = end + (size & 1);
    }
    let Some((channels, sample_rate)) = format else {
        return Err("WAV fmt chunk missing".to_owned());
    };
    let Some(data) = data else {
        return Err("WAV data chunk missing".to_owned());
    };
    let mut mono = Vec::with_capacity(data.len() / (2 * channels as usize));
    for frame in data.chunks_exact(channels as usize * 2) {
        let mut sum = 0i32;
        for channel in 0..channels as usize {
            let at = channel * 2;
            sum += i32::from(i16::from_le_bytes([frame[at], frame[at + 1]]));
        }
        mono.push((sum / i32::from(channels)) as i16);
    }
    Ok((mono, sample_rate))
}

fn resample_mono_pcm16(samples: &[i16], source_rate: u32, target_rate: u32) -> Vec<i16> {
    if samples.is_empty() || source_rate == 0 || target_rate == 0 {
        return Vec::new();
    }
    if source_rate == target_rate {
        return samples.to_vec();
    }
    let output_len =
        ((samples.len() as u64 * u64::from(target_rate)) / u64::from(source_rate)) as usize;
    let mut output = Vec::with_capacity(output_len);
    for index in 0..output_len {
        let source_index =
            ((index as u64 * u64::from(source_rate)) / u64::from(target_rate)) as usize;
        output.push(samples[source_index.min(samples.len() - 1)]);
    }
    output
}

fn sanitize_metric(value: &str) -> String {
    value
        .split_whitespace()
        .collect::<Vec<_>>()
        .join("_")
        .chars()
        .take(180)
        .collect()
}

fn fail(message: &str) -> ! {
    eprintln!("{message}");
    std::process::exit(1)
}
