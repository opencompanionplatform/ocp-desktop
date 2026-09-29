//! CS-IPC transport เนโฌโ€ the OS local-socket binding (RUNTIME_API เธขเธ4, ADR-0005).
//! Certifies that the framing + SEC-040 handshake + SEC-041 validation run
//! over a real Unix domain socket / Windows named pipe, not just a loopback
//! stand-in: authenticated session both directions, and an unauthenticated
//! peer rejected at the socket.

use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::Duration;

use ocp_ipc::transport::{connect_authenticated, connect_authenticated_with_intent, Listener};
use ocp_ipc::{recv_envelope, send_envelope, IpcError, INTENT_PUBLISH, INTENT_SUBSCRIBE};
use ocp_shared_types::Envelope;
use serde_json::json;

// Windows named-pipe tests share a kernel namespace. `interprocess` can return
// ERROR_ACCESS_DENIED when independent listener/connector handshakes race in
// parallel test threads, even when their names differ. The production design
// has one core listener; serialize only this OS-resource test suite.
static OS_SOCKET_TEST_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

struct SocketTestGuard {
    _lock: std::sync::MutexGuard<'static, ()>,
}

impl Drop for SocketTestGuard {
    fn drop(&mut self) {
        // `interprocess` named-pipe teardown is asynchronous on Windows.
        // Keep the suite lock while the OS releases the just-dropped endpoint.
        thread::sleep(Duration::from_millis(75));
    }
}

fn socket_test_guard() -> SocketTestGuard {
    SocketTestGuard {
        _lock: OS_SOCKET_TEST_LOCK
            .get_or_init(|| Mutex::new(()))
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()),
    }
}
/// Unique per test run so parallel tests / stale sockets never collide.
fn unique_name(tag: &str) -> String {
    let t = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    format!("ocp-test-{tag}-{t}-{:?}", thread::current().id())
}

fn envelope(text: &str) -> Envelope {
    Envelope::new(
        "ocp.runtime.bubble-shown",
        "runtime",
        json!({ "text": text }),
    )
    .expect("valid")
}

#[test]
fn authenticated_session_over_os_socket_both_directions() {
    let _guard = socket_test_guard();
    let name = unique_name("session");
    let token = "s3cret-session-token";
    let listener = Listener::bind(&name).expect("bind local socket");

    let server_name = name.clone();
    let server_token = token.to_owned();
    let server = thread::spawn(move || {
        let _ = server_name; // name captured for clarity
        let mut conn = listener
            .accept_authenticated(&server_token)
            .expect("server handshake");
        // Core receives one event, replies with one.
        let got = recv_envelope(&mut conn).expect("recv");
        assert_eq!(got.event_type, "ocp.runtime.bubble-shown");
        send_envelope(&mut conn, &envelope("ack")).expect("reply");
    });

    // Give the listener a moment to be ready before connecting.
    thread::sleep(Duration::from_millis(50));
    let mut client = connect_authenticated(&name, token).expect("client handshake");
    send_envelope(&mut client, &envelope("hello")).expect("send");
    let reply = recv_envelope(&mut client).expect("recv reply");
    assert_eq!(reply.data["text"], "ack");

    server.join().unwrap();
}

#[test]
fn wrong_token_rejected_at_socket() {
    let _guard = socket_test_guard();
    let name = unique_name("badtoken");
    let listener = Listener::bind(&name).expect("bind");
    let server = thread::spawn(move || {
        // Server expects the real token; the client will present a wrong one.
        listener.accept_authenticated("right-token")
    });

    thread::sleep(Duration::from_millis(50));
    let client_res = connect_authenticated(&name, "wrong-token");
    assert!(client_res.is_err(), "client must not complete handshake");

    let server_res = server.join().unwrap();
    assert!(
        matches!(server_res, Err(IpcError::HandshakeRejected)),
        "server must reject the peer (SEC-040)"
    );
}

#[test]
fn declared_intent_reaches_the_server_and_absent_intent_is_none() {
    let _guard = socket_test_guard();
    let name = unique_name("intent");
    let token = "intent-token";
    let listener = Listener::bind(&name).expect("bind");

    let server = thread::spawn(move || {
        let mut hellos = Vec::new();
        for _ in 0..3 {
            let (_conn, hello) = listener
                .accept_authenticated_hello(token)
                .expect("server handshake");
            hellos.push(hello.intent);
        }
        hellos
    });

    thread::sleep(Duration::from_millis(50));
    // Order is deterministic: sequential connects on one client thread.
    let _c1 = connect_authenticated_with_intent(&name, token, INTENT_SUBSCRIBE).expect("subscribe");
    let _c2 = connect_authenticated_with_intent(&name, token, INTENT_PUBLISH).expect("publish");
    let _c3 = connect_authenticated(&name, token).expect("no intent (older client)");

    let hellos = server.join().unwrap();
    assert_eq!(
        hellos,
        vec![
            Some(INTENT_SUBSCRIBE.to_owned()),
            Some(INTENT_PUBLISH.to_owned()),
            None,
        ],
        "intent must round-trip; absent intent must parse as None (lockstep, TD-010)"
    );
}

#[test]
fn second_bind_on_same_name_fails() {
    let _guard = socket_test_guard();
    let name = unique_name("dup");
    let _first = Listener::bind(&name).expect("first bind");
    // A second core (or stale peer) must not silently share the name.
    assert!(Listener::bind(&name).is_err(), "duplicate bind should fail");
}
