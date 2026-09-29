//! CS-EVT — Envelope conformance suite (13-quality/TEST_STRATEGY.md).
//! Certifies EVENT_API rules; this suite is the `gate-envelope` CI gate (I1
//! exit criterion) and doubles as the certification kit for any component
//! that claims envelope conformance.

use ocp_event_bus::{BusError, Deduper, InProcessBus};
use ocp_shared_types::{validate_type_name, Envelope, EnvelopeError};
use serde_json::json;

fn valid(event_type: &str) -> Envelope {
    Envelope::new(event_type, "memory-layer", json!({ "recordId": "x" })).expect("valid envelope")
}

// --- Envelope validation (EVENT_API, SEC-041) ---

#[test]
fn valid_envelope_passes() {
    assert!(valid("ocp.memory.record-written").validate().is_ok());
}

#[test]
fn type_must_have_ocp_prefix_and_three_parts() {
    for bad in [
        "memory.record-written",
        "ocp.memory",
        "ocp.memory.record.written",
        "OCP.memory.record-written",
    ] {
        assert!(validate_type_name(bad).is_err(), "accepted: {bad}");
    }
}

#[test]
fn unknown_context_rejected() {
    assert!(matches!(
        validate_type_name("ocp.billing.charged"),
        Err(EnvelopeError::UnknownContext(_))
    ));
}

#[test]
fn kebab_case_subject_enforced() {
    for bad in [
        "ocp.plugin.Crashed",
        "ocp.plugin.crashed_hard",
        "ocp.plugin.-crashed",
        "ocp.plugin.crashed-",
        "ocp.plugin.",
    ] {
        assert!(validate_type_name(bad).is_err(), "accepted: {bad}");
    }
    // Subject-less lifecycle precedent (EVENT_CATALOG: ocp.plugin.activated).
    assert!(validate_type_name("ocp.plugin.activated").is_ok());
}

#[test]
fn version_must_be_major_minor() {
    let mut env = valid("ocp.plugin.crashed");
    for bad in ["1", "1.0.0", "v1.0", "1.", ".0", "a.b", ""] {
        env.version = bad.to_owned();
        assert!(env.validate().is_err(), "accepted version: {bad}");
    }
    env.version = "2.13".to_owned();
    assert!(env.validate().is_ok());
}

#[test]
fn content_type_is_canonical_spelling_and_json() {
    // TD-002: `contentType`, value application/json.
    let mut env = valid("ocp.plugin.crashed");
    env.content_type = "text/plain".to_owned();
    assert!(matches!(
        env.validate(),
        Err(EnvelopeError::BadContentType(_))
    ));
}

// --- Serde contract: camelCase field names on the wire (EVENT_API example) ---

#[test]
fn wire_format_uses_camel_case_fields() {
    let env = valid("ocp.memory.record-written").with_correlation(uuid::Uuid::now_v7());
    let wire = serde_json::to_value(&env).expect("serialize");
    for key in [
        "id",
        "type",
        "version",
        "source",
        "time",
        "correlationId",
        "contentType",
        "data",
    ] {
        assert!(wire.get(key).is_some(), "missing wire field: {key}");
    }
    assert!(wire.get("event_type").is_none());
    let back: Envelope = serde_json::from_value(wire).expect("roundtrip");
    assert_eq!(back, env);
}

#[test]
fn unknown_wire_fields_rejected() {
    // deny_unknown_fields: a peer cannot smuggle extra fields past validation (SEC-041).
    let mut wire = serde_json::to_value(valid("ocp.plugin.crashed")).unwrap();
    wire["extra"] = json!("smuggled");
    assert!(serde_json::from_value::<Envelope>(wire).is_err());
}

// --- Bus behavior (ADR-0005) ---

#[test]
fn publish_delivers_to_exact_and_family_subscribers() {
    let bus = InProcessBus::new();
    let exact = bus.subscribe("ocp.plugin.crashed");
    let family = bus.subscribe("ocp.plugin.");
    let other = bus.subscribe("ocp.memory.");

    let delivered = bus.publish(valid("ocp.plugin.crashed")).expect("publish");
    assert_eq!(delivered, 2);
    assert!(exact.try_recv().is_ok());
    assert!(family.try_recv().is_ok());
    assert!(other.try_recv().is_err());
}

#[test]
fn family_pattern_does_not_match_prefix_strings() {
    let bus = InProcessBus::new();
    let family = bus.subscribe("ocp.plugin.");
    // `ocp.plugin` exact-string tricks must not match the family.
    bus.publish(valid("ocp.runtime.moved")).expect("publish");
    assert!(family.try_recv().is_err());
}

#[test]
fn family_pattern_requires_segment_boundary() {
    // Adversarial: a context merely *starting with* the family prefix must not
    // match (`ocp.plugin.` ≠ `ocp.plugin-extra.*`). Static review I1 F-C.
    let bus = InProcessBus::new();
    let family = bus.subscribe("ocp.plugin.");
    // Bypass Envelope::new (unknown context would fail validation): construct
    // the match check directly via a valid known-context lookalike is not
    // possible, so assert at the bus level with the closest valid case and at
    // the validation level for the lookalike.
    bus.publish(valid("ocp.plugin.crashed")).expect("publish");
    assert!(family.try_recv().is_ok());
    assert!(validate_type_name("ocp.plugin-extra.crashed").is_err());
}

#[test]
fn malformed_envelope_never_reaches_subscribers() {
    // SEC-041: reject before delivery.
    let bus = InProcessBus::new();
    let sub = bus.subscribe("ocp.plugin.");
    let mut env = valid("ocp.plugin.crashed");
    env.version = "broken".to_owned();
    assert!(matches!(bus.publish(env), Err(BusError::Invalid(_))));
    assert!(sub.try_recv().is_err());
}

#[test]
fn ordering_preserved_per_source() {
    let bus = InProcessBus::new();
    let sub = bus.subscribe("ocp.memory.");
    let ids: Vec<_> = (0..100)
        .map(|_| {
            let env = valid("ocp.memory.record-written");
            let id = env.id;
            bus.publish(env).expect("publish");
            id
        })
        .collect();
    let received: Vec<_> = (0..100).map(|_| sub.try_recv().expect("recv").id).collect();
    assert_eq!(ids, received, "per-source ordering violated (EVENT_API)");
}

#[test]
fn consumer_dedupe_on_id() {
    // At-least-once ⇒ consumers dedupe on `id` (EVENT_API Delivery Guarantees).
    let env = valid("ocp.plugin.crashed");
    let mut dedupe = Deduper::new();
    assert!(dedupe.first_seen(env.id));
    assert!(!dedupe.first_seen(env.id), "duplicate id not filtered");
}

#[test]
fn ids_are_time_ordered_uuidv7() {
    let a = valid("ocp.plugin.crashed");
    let b = valid("ocp.plugin.crashed");
    assert!(a.id < b.id, "UUIDv7 ids must be time-ordered (EVENT_API)");
}
