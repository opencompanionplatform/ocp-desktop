//! OCP IPC bridge tier — ADR-0005 tier 2.
//!
//! Length-prefixed JSON frames carrying the EVENT_API envelope between the
//! Desktop Runtime and the Native Core Service. This crate is the *protocol*
//! layer, written against `Read + Write` so it runs identically over a Unix
//! domain socket, a Windows named pipe, or a test loopback. The concrete OS
//! socket binding (Unix domain socket / Windows named pipe) lives in the
//! [`transport`] module (I2).
//!
//! Security gates:
//! - SEC-040: token handshake authenticates the peer before any payload is
//!   processed; rejection reveals nothing about which check failed.
//! - SEC-041: every received envelope is validated at this entry point;
//!   malformed frames are surfaced as [`IpcError::InvalidEnvelope`] /
//!   [`IpcError::Parse`] so the caller drops + logs them — they are never
//!   propagated, and the connection survives (drop the event, not the peer).
//! - Envelope evolution (TD-010): the handshake carries `PROTOCOL_VERSION`;
//!   a different major is rejected at connect time (EVENT_API Rules).
//!
//! Framing: `u32` big-endian payload length, then that many bytes of JSON.
//! Frames above [`MAX_FRAME_BYTES`] are rejected without allocation
//! (DoS containment, CS-RT oversized-frame rule).

#![forbid(unsafe_code)] // SEC-042

use std::io::{Read, Write};

use ocp_shared_types::{Envelope, EnvelopeError};
use serde::{Deserialize, Serialize};

pub mod transport;

/// Handshake protocol identifier.
pub const PROTOCOL: &str = "ocp-ipc";
/// Transport protocol version, `major.minor`. Major mismatch → reject (TD-010).
pub const PROTOCOL_VERSION: &str = "1.0";
/// Hard cap on a single frame. Oversized frames are rejected before allocation.
pub const MAX_FRAME_BYTES: u32 = 1024 * 1024;

/// IPC failures. `InvalidEnvelope`/`Parse` mean: log and drop the event,
/// keep the connection (SEC-041). `Oversized`/`Io`/`HandshakeRejected` mean:
/// the connection is not trustworthy — close it.
#[derive(Debug)]
pub enum IpcError {
    Io(std::io::Error),
    /// Frame length exceeds MAX_FRAME_BYTES (attempted length inside).
    Oversized(u64),
    /// Peer failed authentication or protocol negotiation (SEC-040).
    /// Deliberately carries no detail about which check failed.
    HandshakeRejected,
    /// Frame bytes are not a JSON envelope.
    Parse(serde_json::Error),
    /// Envelope parsed but violates EVENT_API (SEC-041).
    InvalidEnvelope(EnvelopeError),
}

impl From<std::io::Error> for IpcError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}

impl core::fmt::Display for IpcError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::Io(e) => write!(f, "ipc io error: {e}"),
            Self::Oversized(n) => write!(f, "frame exceeds {MAX_FRAME_BYTES} bytes: {n}"),
            Self::HandshakeRejected => write!(f, "peer handshake rejected (SEC-040)"),
            Self::Parse(e) => write!(f, "frame is not a JSON envelope: {e}"),
            Self::InvalidEnvelope(e) => write!(f, "envelope rejected at IPC entry (SEC-041): {e}"),
        }
    }
}

impl std::error::Error for IpcError {}

// --- Framing -----------------------------------------------------------------

/// Write one length-prefixed frame.
pub fn write_frame<W: Write>(w: &mut W, payload: &[u8]) -> Result<(), IpcError> {
    let len =
        u32::try_from(payload.len()).map_err(|_| IpcError::Oversized(payload.len() as u64))?;
    if len > MAX_FRAME_BYTES {
        return Err(IpcError::Oversized(u64::from(len)));
    }
    w.write_all(&len.to_be_bytes())?;
    w.write_all(payload)?;
    w.flush()?;
    Ok(())
}

/// Read one length-prefixed frame. Blocks until the frame is complete, so
/// partial writes reassemble correctly; interleaved frames arrive in order.
pub fn read_frame<R: Read>(r: &mut R) -> Result<Vec<u8>, IpcError> {
    let mut len_bytes = [0u8; 4];
    r.read_exact(&mut len_bytes)?;
    let len = u32::from_be_bytes(len_bytes);
    if len > MAX_FRAME_BYTES {
        return Err(IpcError::Oversized(u64::from(len)));
    }
    let mut buf = vec![0u8; len as usize];
    r.read_exact(&mut buf)?;
    Ok(buf)
}

// --- Handshake (SEC-040) -----------------------------------------------------

/// Connection intent: the client subscribes to events pushed by the server
/// (long-lived, server→client direction).
pub const INTENT_SUBSCRIBE: &str = "subscribe";
/// Connection intent: the client will publish envelopes to the server.
pub const INTENT_PUBLISH: &str = "publish";

/// First frame a client sends. Strict on the wire like the envelope.
/// `intent` (added I2, ships lockstep pre-1.0 per TD-010) declares which
/// direction this connection carries, so the server can route deterministically
/// instead of guessing from connect order: [`INTENT_SUBSCRIBE`] = server
/// pushes events to this connection; [`INTENT_PUBLISH`] = client sends
/// envelopes on it. Absent (older client) ⇒ server treats it as publish.
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Hello {
    pub protocol: String,
    pub version: String,
    pub token: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub intent: Option<String>,
}

/// Server acknowledgement; only sent on success.
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HelloAck {
    pub ok: bool,
    pub protocol: String,
    pub version: String,
}

/// Constant-time byte comparison — no early exit on mismatch.
fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn major_of(version: &str) -> &str {
    version.split('.').next().unwrap_or("")
}

/// Server side: authenticate the peer before anything else flows, returning
/// the accepted `Hello` (so the caller can route on `intent`).
/// On any failure the caller must close the connection.
pub fn accept_handshake_hello<S: Read + Write>(
    stream: &mut S,
    expected_token: &str,
) -> Result<Hello, IpcError> {
    let frame = read_frame(stream)?;
    let hello: Hello = serde_json::from_slice(&frame).map_err(|_| IpcError::HandshakeRejected)?;
    let protocol_ok = hello.protocol == PROTOCOL;
    let version_ok = major_of(&hello.version) == major_of(PROTOCOL_VERSION);
    let token_ok = ct_eq(hello.token.as_bytes(), expected_token.as_bytes());
    if !(protocol_ok && version_ok && token_ok) {
        return Err(IpcError::HandshakeRejected);
    }
    let ack = HelloAck {
        ok: true,
        protocol: PROTOCOL.to_owned(),
        version: PROTOCOL_VERSION.to_owned(),
    };
    write_frame(stream, &serde_json::to_vec(&ack).map_err(IpcError::Parse)?)?;
    Ok(hello)
}

/// Server side: authenticate the peer, discarding the `Hello` detail.
pub fn accept_handshake<S: Read + Write>(
    stream: &mut S,
    expected_token: &str,
) -> Result<(), IpcError> {
    accept_handshake_hello(stream, expected_token).map(|_| ())
}

/// Client side: present the token and a connection intent, await the ack.
pub fn client_handshake_with_intent<S: Read + Write>(
    stream: &mut S,
    token: &str,
    intent: Option<&str>,
) -> Result<(), IpcError> {
    let hello = Hello {
        protocol: PROTOCOL.to_owned(),
        version: PROTOCOL_VERSION.to_owned(),
        token: token.to_owned(),
        intent: intent.map(str::to_owned),
    };
    write_frame(
        stream,
        &serde_json::to_vec(&hello).map_err(IpcError::Parse)?,
    )?;
    let frame = read_frame(stream)?;
    let ack: HelloAck = serde_json::from_slice(&frame).map_err(|_| IpcError::HandshakeRejected)?;
    if ack.ok && ack.protocol == PROTOCOL && major_of(&ack.version) == major_of(PROTOCOL_VERSION) {
        Ok(())
    } else {
        Err(IpcError::HandshakeRejected)
    }
}

/// Client side: present the token, await the ack (no declared intent —
/// servers treat this as [`INTENT_PUBLISH`]).
pub fn client_handshake<S: Read + Write>(stream: &mut S, token: &str) -> Result<(), IpcError> {
    client_handshake_with_intent(stream, token, None)
}

/// Generate a fresh connection token (host side; delivered to the runtime
/// out-of-band, e.g. a 0600-permission file — provisioning is I2 wiring).
/// Two UUIDv4s ≈ 244 bits of OS-sourced randomness.
#[must_use]
pub fn generate_token() -> String {
    format!(
        "{}{}",
        uuid::Uuid::new_v4().simple(),
        uuid::Uuid::new_v4().simple()
    )
}

// --- Envelope transport (post-handshake) -------------------------------------

/// Validate (SEC-041) then send one envelope.
pub fn send_envelope<W: Write>(w: &mut W, envelope: &Envelope) -> Result<(), IpcError> {
    envelope.validate().map_err(IpcError::InvalidEnvelope)?;
    write_frame(w, &serde_json::to_vec(envelope).map_err(IpcError::Parse)?)
}

/// Receive one envelope, validating at the boundary (SEC-041).
/// `Parse`/`InvalidEnvelope` ⇒ caller logs + drops the event and continues
/// reading; the connection stays up.
pub fn recv_envelope<R: Read>(r: &mut R) -> Result<Envelope, IpcError> {
    let frame = read_frame(r)?;
    let envelope: Envelope = serde_json::from_slice(&frame).map_err(IpcError::Parse)?;
    envelope.validate().map_err(IpcError::InvalidEnvelope)?;
    Ok(envelope)
}
