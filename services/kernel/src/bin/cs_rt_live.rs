//! cs_rt_live — CS-RT (RUNTIME_API §6) driven over a real OS socket against
//! whatever runtime subscribes, instead of in-process against a `Runtime`
//! trait object like `ocp_runtime_api::certify` does for the headless stub.
//!
//! Why this exists instead of gdext's `itest`: `itest` is godot-rust's own
//! internal integration-test harness for testing the *bindings crate itself*
//! — it isn't published as a reusable framework for downstream GDExtensions,
//! and adopting its internal macros/project layout here would mean copying
//! gdext's own test infrastructure rather than testing our contract. Driving
//! the exact same 5-step script as `certify()` over the real socket instead
//! is arguably more faithful to production anyway: it exercises the same
//! IPC framing, SEC-040 handshake, and SEC-041 validation a real kernel
//! would, not just an in-process Rust call.
//!
//! Keep this script's steps in sync with `packages/runtime-api::certify()` by
//! hand — duplicated deliberately rather than shared, since certify() takes
//! a `Runtime` trait object and this drives a network peer; unifying them
//! would need a bigger refactor that isn't worth it for a 5-step script.
//!
//! Usage: start this, then launch the runtime under test (Godot, headless or
//! not) with OCP_IPC_SOCKET/OCP_IPC_TOKEN matching what this prints. Exits 0
//! if every step's expected outcome fact(s) arrive, correlated, from
//! `source: "runtime"`; exits 1 with a diagnostic otherwise.
//!
//! Env:
//!   OCP_IPC_SOCKET   socket name (default "ocp-cs-rt")
//!   OCP_IPC_TOKEN    session token (default: freshly generated and printed)
//!   CS_RT_TIMEOUT_S  seconds to wait for the runtime to subscribe and for
//!                    each step's outcome fact(s) (default 30)

#![forbid(unsafe_code)] // SEC-042

use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::thread;
use std::time::{Duration, Instant};

use ocp_ipc::transport::Listener;
use ocp_ipc::{generate_token, recv_envelope, send_envelope, IpcError, INTENT_SUBSCRIBE};
use ocp_shared_types::Envelope;
use serde_json::json;

struct Step {
    input: Envelope,
    /// Outcome event types expected in response (order-independent, must all
    /// appear); empty means "must emit nothing" (the mirror-only step).
    expected: &'static [&'static str],
}

fn ev(event_type: &str, source: &str, data: serde_json::Value) -> Envelope {
    Envelope::new(event_type, source, data).expect("valid conformance envelope")
}

/// The exact script from `packages/runtime-api::certify()` (kept in sync by
/// hand — see module doc).
fn script() -> Vec<Step> {
    let bubble_id = uuid::Uuid::now_v7();
    let speech_id = uuid::Uuid::now_v7();
    vec![
        Step {
            input: ev(
                "ocp.behavior.bubble-requested",
                "behavior",
                json!({ "bubbleId": bubble_id, "text": "hello", "tone": "happy", "anchor": "companion" }),
            ),
            expected: &["ocp.runtime.bubble-shown"],
        },
        Step {
            input: ev(
                "ocp.behavior.speech-requested",
                "behavior",
                json!({ "speechId": speech_id, "text": "hi there", "subtitle": true }),
            ),
            expected: &["ocp.runtime.speech-started", "ocp.runtime.speech-completed"],
        },
        Step {
            input: ev(
                "ocp.behavior.emotion-changed",
                "behavior",
                json!({ "companionId": uuid::Uuid::now_v7(), "from": "neutral", "to": "happy" }),
            ),
            expected: &["ocp.runtime.emotion-presented"],
        },
        Step {
            input: ev(
                "ocp.companion.window-policy-changed",
                "companion",
                json!({
                    "transparent": true, "alwaysOnTop": true, "clickThrough": "outside-sprite"
                }),
            ),
            expected: &["ocp.runtime.window-state-changed"],
        },
        Step {
            input: ev(
                "ocp.companion.state-changed",
                "companion",
                json!({
                    "companionId": uuid::Uuid::now_v7(), "from": "Idle", "to": "Speaking"
                }),
            ),
            expected: &[], // mirrored; no outbound fact required, must not error
        },
    ]
}

fn fail(msg: &str) -> ! {
    eprintln!("[cs-rt] FAIL: {msg}");
    std::process::exit(1);
}

fn main() {
    let socket = std::env::var("OCP_IPC_SOCKET").unwrap_or_else(|_| "ocp-cs-rt".to_owned());
    let token = match std::env::var("OCP_IPC_TOKEN") {
        Ok(t) if !t.is_empty() => t,
        _ => {
            let t = generate_token();
            println!("[cs-rt] generated token (set these for the runtime under test BEFORE launching it):");
            println!("  $env:OCP_IPC_SOCKET = \"{socket}\"");
            println!("  $env:OCP_IPC_TOKEN  = \"{t}\"");
            t
        }
    };
    let timeout: Duration = std::env::var("CS_RT_TIMEOUT_S")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .map(Duration::from_secs)
        .unwrap_or(Duration::from_secs(30));

    let listener = match Listener::bind(&socket) {
        Ok(l) => l,
        Err(e) => fail(&format!("cannot bind socket '{socket}': {e}")),
    };
    println!("[cs-rt] listening on '{socket}', waiting up to {timeout:?} for the runtime to subscribe...");

    // One accept loop for the whole run, moved onto its own thread: the
    // subscribe connection is handed back once via `sub_tx`; every other
    // (publish) connection is drained on its own thread until the runtime
    // closes it. Runtime V3 intentionally reuses a publish connection so facts
    // remain ordered; the harness must therefore accept multiple envelopes per
    // connection rather than closing after the first fact.
    let (sub_tx, sub_rx): (Sender<_>, Receiver<_>) = channel();
    let (fact_tx, fact_rx): (Sender<Envelope>, Receiver<Envelope>) = channel();
    {
        let token = token.clone();
        thread::spawn(move || {
            let mut sub_tx = Some(sub_tx);
            loop {
                match listener.accept_authenticated_hello(&token) {
                    Ok((conn, hello)) => {
                        if hello.intent.as_deref() == Some(INTENT_SUBSCRIBE) {
                            if let Some(tx) = sub_tx.take() {
                                let _ = tx.send(conn);
                            } // a second subscribe (reconnect) is out of scope for this script
                        } else {
                            let fact_tx = fact_tx.clone();
                            thread::spawn(move || drain_publish_connection(conn, fact_tx));
                        }
                    }
                    Err(e) => eprintln!("[cs-rt] connection rejected: {e}"),
                }
            }
        });
    }

    let mut subscribe_conn = match sub_rx.recv_timeout(timeout) {
        Ok(c) => c,
        Err(RecvTimeoutError::Timeout) => {
            fail("timed out waiting for the runtime to subscribe (check OCP_IPC_SOCKET/OCP_IPC_TOKEN match, and that the runtime under test actually launched)")
        }
        Err(RecvTimeoutError::Disconnected) => fail("accept thread died unexpectedly"),
    };
    println!("[cs-rt] runtime subscribed");

    let mut all_passed = true;
    for (n, step) in script().into_iter().enumerate() {
        print!("[cs-rt] step {}: {} ... ", n + 1, step.input.event_type);
        if let Err(e) = send_envelope(&mut subscribe_conn, &step.input) {
            println!("FAIL (could not send: {e})");
            all_passed = false;
            continue;
        }

        let mut seen: Vec<String> = Vec::new();
        let deadline = Instant::now() + Duration::from_secs(3).min(timeout);
        let mut step_failed = false;
        while seen.len() < step.expected.len() {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }
            match fact_rx.recv_timeout(remaining) {
                Ok(fact) => {
                    if let Err(e) = fact.validate() {
                        println!("FAIL (runtime emitted an invalid envelope: {e})");
                        step_failed = true;
                        break;
                    }
                    if fact.correlation_id != Some(step.input.id) {
                        continue; // stray/late fact from a previous step; ignore
                    }
                    if fact.source != "runtime" {
                        println!(
                            "FAIL ({} has source '{}', expected 'runtime')",
                            fact.event_type, fact.source
                        );
                        step_failed = true;
                        break;
                    }
                    seen.push(fact.event_type.clone());
                }
                Err(RecvTimeoutError::Timeout) => break,
                Err(RecvTimeoutError::Disconnected) => {
                    println!("FAIL (fact channel closed unexpectedly)");
                    step_failed = true;
                    break;
                }
            }
        }
        if step_failed {
            all_passed = false;
            continue;
        }

        // A brief extra grace window for the zero-expected (mirror-only) step
        // to catch an unexpected emission; skip it for steps that expect facts.
        if step.expected.is_empty() {
            thread::sleep(Duration::from_millis(300));
            while let Ok(stray) = fact_rx.try_recv() {
                if stray.correlation_id == Some(step.input.id) {
                    println!(
                        "FAIL (expected no outcome for {}, got {})",
                        step.input.event_type, stray.event_type
                    );
                    all_passed = false;
                }
            }
        }

        let missing: Vec<&str> = step
            .expected
            .iter()
            .filter(|want| !seen.iter().any(|got| got == *want))
            .copied()
            .collect();
        if missing.is_empty() {
            println!("ok");
        } else {
            println!("FAIL (missing: {missing:?}, got: {seen:?})");
            all_passed = false;
        }
    }

    if all_passed {
        println!("[cs-rt] PASS -- runtime matches CS-RT minimal conformance (NFR-001)");
        std::process::exit(0);
    } else {
        fail("one or more steps failed (see above)");
    }
}

/// Drain every outcome fact from one authenticated publish connection.
///
/// Runtime V3 keeps this connection alive and writes facts in queue order.
/// Continue until the peer closes; malformed frames are logged but do not make
/// the harness tear down a healthy persistent connection.
fn drain_publish_connection(mut conn: ocp_ipc::transport::Connection, fact_tx: Sender<Envelope>) {
    loop {
        match recv_envelope(&mut conn) {
            Ok(env) => {
                if fact_tx.send(env).is_err() {
                    return;
                }
            }
            Err(IpcError::Io(_)) => return,
            Err(e) => eprintln!("[cs-rt] dropped bad frame from publish connection: {e}"),
        }
    }
}
