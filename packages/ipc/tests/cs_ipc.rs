//! CS-IPC — IPC-bridge conformance (the IPC rows of CS-RT, TEST_STRATEGY §3.5).
//! Certifies: SEC-040 peer authentication before payload, SEC-041 boundary
//! validation with connection survival, framing rules (partial, oversized,
//! interleaved) per ADR-0005.
//!
//! Transport in these tests is a TCP loopback purely as a stand-in duplex
//! stream; the protocol layer is transport-agnostic by design.

use std::io::Write;
use std::net::{TcpListener, TcpStream};
use std::thread;

use ocp_ipc::{
    accept_handshake, client_handshake, generate_token, read_frame, recv_envelope, send_envelope,
    write_frame, IpcError, MAX_FRAME_BYTES,
};
use ocp_shared_types::Envelope;
use serde_json::json;

/// One connected loopback pair: (client, server).
fn pair() -> (TcpStream, TcpStream) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().expect("addr");
    let join = thread::spawn(move || listener.accept().expect("accept").0);
    let client = TcpStream::connect(addr).expect("connect");
    let server = join.join().expect("join");
    (client, server)
}

fn valid_envelope() -> Envelope {
    Envelope::new(
        "ocp.runtime.bubble-shown",
        "runtime",
        json!({ "text": "hi" }),
    )
    .expect("valid envelope")
}

// --- SEC-040: peer authentication before payload ---

#[test]
fn handshake_accepts_valid_token() {
    let (mut client, mut server) = pair();
    let token = generate_token();
    let t2 = token.clone();
    let s = thread::spawn(move || accept_handshake(&mut server, &t2));
    client_handshake(&mut client, &token).expect("client side");
    s.join().unwrap().expect("server side");
}

#[test]
fn handshake_rejects_wrong_token() {
    let (mut client, mut server) = pair();
    let s = thread::spawn(move || accept_handshake(&mut server, "right-token"));
    let _ = client_handshake(&mut client, "wrong-token");
    assert!(matches!(
        s.join().unwrap(),
        Err(IpcError::HandshakeRejected)
    ));
}

#[test]
fn handshake_rejects_wrong_protocol_and_major() {
    for hello in [
        r#"{"protocol":"not-ocp","version":"1.0","token":"t"}"#,
        r#"{"protocol":"ocp-ipc","version":"2.0","token":"t"}"#,
        r#"{"protocol":"ocp-ipc","version":"1.0","token":"t","extra":"smuggled"}"#,
    ] {
        let (mut client, mut server) = pair();
        let s = thread::spawn(move || accept_handshake(&mut server, "t"));
        write_frame(&mut client, hello.as_bytes()).expect("send");
        assert!(
            matches!(s.join().unwrap(), Err(IpcError::HandshakeRejected)),
            "accepted: {hello}"
        );
    }
}

#[test]
fn payload_before_handshake_is_rejected() {
    // SEC-040: an envelope pushed as the first frame must not be processed.
    let (mut client, mut server) = pair();
    let s = thread::spawn(move || accept_handshake(&mut server, "token"));
    send_envelope(&mut client, &valid_envelope()).expect("send");
    assert!(matches!(
        s.join().unwrap(),
        Err(IpcError::HandshakeRejected)
    ));
}

// --- Framing (ADR-0005 / CS-RT) ---

#[test]
fn partial_frames_reassemble() {
    let (mut client, mut server) = pair();
    let payload = br#"{"hello":"split"}"#;
    let len = (payload.len() as u32).to_be_bytes();
    let w = thread::spawn(move || {
        client.write_all(&len[..2]).unwrap();
        client.flush().unwrap();
        thread::sleep(std::time::Duration::from_millis(20));
        client.write_all(&len[2..]).unwrap();
        client.write_all(&payload[..5]).unwrap();
        client.flush().unwrap();
        thread::sleep(std::time::Duration::from_millis(20));
        client.write_all(&payload[5..]).unwrap();
    });
    let frame = read_frame(&mut server).expect("reassembled");
    assert_eq!(frame, payload);
    w.join().unwrap();
}

#[test]
fn oversized_frame_rejected_without_allocation() {
    let (mut client, mut server) = pair();
    let bad_len = (MAX_FRAME_BYTES + 1).to_be_bytes();
    client.write_all(&bad_len).unwrap();
    client.flush().unwrap();
    assert!(matches!(
        read_frame(&mut server),
        Err(IpcError::Oversized(_))
    ));
}

#[test]
fn oversized_send_refused_locally() {
    let mut sink = Vec::new();
    let big = vec![b'x'; MAX_FRAME_BYTES as usize + 1];
    assert!(matches!(
        write_frame(&mut sink, &big),
        Err(IpcError::Oversized(_))
    ));
    assert!(sink.is_empty(), "no partial oversized frame may leak");
}

#[test]
fn interleaved_envelopes_arrive_in_order() {
    let (mut client, mut server) = pair();
    let sent: Vec<Envelope> = (0..10).map(|_| valid_envelope()).collect();
    let ids: Vec<_> = sent.iter().map(|e| e.id).collect();
    let w = thread::spawn(move || {
        for env in &sent {
            send_envelope(&mut client, env).expect("send");
        }
    });
    let received: Vec<_> = (0..10)
        .map(|_| recv_envelope(&mut server).expect("recv").id)
        .collect();
    assert_eq!(ids, received, "IPC must preserve per-source order");
    w.join().unwrap();
}

// --- SEC-041: boundary validation, connection survives a bad event ---

#[test]
fn malformed_envelope_dropped_connection_survives() {
    let (mut client, mut server) = pair();

    // 1. Parses as JSON but violates EVENT_API (unknown context).
    let bad = json!({
        "id": "0198c0de-0000-7000-8000-000000000000",
        "type": "ocp.billing.charged",
        "version": "1.0",
        "source": "evil",
        "time": "2026-07-19T00:00:00Z",
        "contentType": "application/json",
        "data": {}
    });
    write_frame(&mut client, bad.to_string().as_bytes()).expect("send bad");
    // 2. Not JSON at all.
    write_frame(&mut client, b"\x00\x01garbage").expect("send junk");
    // 3. A good envelope behind them.
    let good = valid_envelope();
    send_envelope(&mut client, &good).expect("send good");

    assert!(matches!(
        recv_envelope(&mut server),
        Err(IpcError::InvalidEnvelope(_))
    ));
    assert!(matches!(
        recv_envelope(&mut server),
        Err(IpcError::Parse(_))
    ));
    let survived = recv_envelope(&mut server).expect("connection must survive drops");
    assert_eq!(survived.id, good.id);
}

#[test]
fn send_validates_before_wire() {
    // SEC-041 applies on egress too: an invalid envelope never leaves.
    let mut env = valid_envelope();
    env.version = "broken".to_owned();
    let mut sink = Vec::new();
    assert!(matches!(
        send_envelope(&mut sink, &env),
        Err(IpcError::InvalidEnvelope(_))
    ));
    assert!(sink.is_empty());
}

// --- Token quality ---

#[test]
fn generated_tokens_are_long_and_unique() {
    let a = generate_token();
    let b = generate_token();
    assert!(a.len() >= 64, "token too short: {}", a.len());
    assert_ne!(a, b);
}
