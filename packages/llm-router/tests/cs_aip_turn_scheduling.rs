//! CS-AIP §7 — turn-scheduling for multiple companions (AI_PROVIDER_API §7,
//! ADR-0013 §5; I6.5 slice 5). The `TurnScheduler` is a routing-policy layer
//! in front of `Router` (§7.4): these tests pin the current-speaker gate
//! (§7.1), queue-not-reject ordering (§7.2), the background bypass (§7.3),
//! and — in the last test — the actual composition with the real `Router`.

use ocp_event_bus::InProcessBus;
use ocp_llm_router::adapter::LocalEchoAdapter;
use ocp_llm_router::types::{
    CallerContext, Capability, ContentPart, CostClass, LatencyClass, Limits, Locality, Message,
    ModelInfo, ProviderCapabilities, Role, RoutePolicy, RouterRequest,
};
use ocp_llm_router::{
    InMemoryConsentStore, InMemoryCredentialStore, Router, SubmitDecision, TurnScheduler,
};
use uuid::Uuid;

fn request(foreground: bool) -> RouterRequest {
    RouterRequest {
        request_id: Uuid::now_v7(),
        correlation_id: Uuid::now_v7(),
        capability: Capability::Chat,
        messages: vec![Message {
            role: Role::User,
            content: vec![ContentPart::Text {
                value: "hi".to_owned(),
            }],
        }],
        memory_excerpts: vec![],
        tools: vec![],
        caller_context: CallerContext {
            context_id: "companion".to_owned(),
            granted_capabilities: vec![],
        },
        policy: RoutePolicy {
            max_cost_class: CostClass::Metered,
            allow_cloud: true,
        },
        streaming: false,
        foreground,
        limits: Limits {
            max_output_tokens: 64,
        },
    }
}

#[test]
fn first_foreground_submit_takes_the_floor_with_a_speaker_changed_fact() {
    let mut sched = TurnScheduler::new(Uuid::now_v7());
    let req = request(true);
    let correlation = req.correlation_id;

    let (decision, runnable, events) = sched.submit("aiko", req);
    assert_eq!(decision, SubmitDecision::Proceed);
    assert!(runnable.is_some(), "granted request handed back to run");
    assert_eq!(sched.current_speaker(), Some("aiko"));

    assert_eq!(events.len(), 1);
    let ev = &events[0];
    ev.validate().expect("valid envelope");
    assert_eq!(ev.event_type, "ocp.ai-routing.speaker-changed");
    assert_eq!(ev.data["companionId"], "aiko");
    assert_eq!(ev.data["previousCompanionId"], serde_json::Value::Null);
    assert_eq!(ev.correlation_id, Some(correlation), "NFR-004");
}

#[test]
fn the_current_speaker_resubmits_without_new_facts() {
    let mut sched = TurnScheduler::new(Uuid::now_v7());
    sched.submit("aiko", request(true));
    let (decision, runnable, events) = sched.submit("aiko", request(true));
    assert_eq!(decision, SubmitDecision::Proceed);
    assert!(runnable.is_some());
    assert!(events.is_empty(), "no state change, no event");
}

#[test]
fn a_non_speaker_is_queued_not_rejected_and_the_fact_is_reported() {
    let mut sched = TurnScheduler::new(Uuid::now_v7());
    sched.submit("aiko", request(true));

    let req_b = request(true);
    let (decision, runnable, events) = sched.submit("bob", req_b);
    assert_eq!(
        decision,
        SubmitDecision::Queued,
        "queued, never refused (§7.2)"
    );
    assert!(runnable.is_none(), "held by the scheduler");
    assert_eq!(sched.queue_len(), 1);
    assert_eq!(sched.current_speaker(), Some("aiko"), "floor unchanged");

    assert_eq!(events.len(), 1);
    assert_eq!(events[0].event_type, "ocp.ai-routing.request-queued");
    assert_eq!(events[0].data["companionId"], "bob");
    assert_eq!(events[0].data["queuePosition"], 1);
}

#[test]
fn background_requests_bypass_the_gate_entirely() {
    let mut sched = TurnScheduler::new(Uuid::now_v7());
    sched.submit("aiko", request(true));

    // §7.3: bob's background summarization runs concurrently — no queue, no
    // floor change, no events.
    let (decision, runnable, events) = sched.submit("bob", request(false));
    assert_eq!(decision, SubmitDecision::Proceed);
    assert!(runnable.is_some());
    assert!(events.is_empty());
    assert_eq!(sched.current_speaker(), Some("aiko"));
    assert_eq!(sched.queue_len(), 0);
}

#[test]
fn complete_promotes_queued_requests_in_arrival_order() {
    let mut sched = TurnScheduler::new(Uuid::now_v7());
    sched.submit("aiko", request(true));
    sched.submit("bob", request(true));
    sched.submit("cara", request(true));

    // aiko finishes → bob (first arrival) gets the floor.
    let (next, events) = sched.complete("aiko");
    let next = next.expect("bob promoted");
    assert_eq!(next.companion_id, "bob");
    assert_eq!(sched.current_speaker(), Some("bob"));
    let types: Vec<&str> = events.iter().map(|e| e.event_type.as_str()).collect();
    assert_eq!(
        types,
        vec![
            "ocp.ai-routing.request-dequeued",
            "ocp.ai-routing.speaker-changed"
        ]
    );
    assert_eq!(events[1].data["previousCompanionId"], "aiko");
    assert_eq!(events[1].data["companionId"], "bob");

    // bob finishes → cara; cara finishes → floor idle (§7.1 null speaker).
    let (next, _) = sched.complete("bob");
    assert_eq!(next.expect("cara promoted").companion_id, "cara");
    let (next, events) = sched.complete("cara");
    assert!(next.is_none());
    assert_eq!(sched.current_speaker(), None);
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].data["companionId"], serde_json::Value::Null);
    assert_eq!(events[0].data["previousCompanionId"], "cara");
}

#[test]
fn completing_when_not_the_speaker_is_ignored_and_audited() {
    let mut sched = TurnScheduler::new(Uuid::now_v7());
    sched.submit("aiko", request(true));
    let (next, events) = sched.complete("bob");
    assert!(next.is_none());
    assert!(events.is_empty());
    assert_eq!(sched.current_speaker(), Some("aiko"), "floor untouched");
    assert!(sched
        .audit_log()
        .iter()
        .any(|l| l.contains("COMPLETE-IGNORED bob")));
}

#[test]
fn scheduler_composes_with_the_real_router_as_a_front_layer() {
    // §7.4: the router itself is untouched — prove it by actually driving one.
    let mut router = Router::new(
        InProcessBus::new(),
        Box::new(InMemoryConsentStore::new()),
        Box::new(InMemoryCredentialStore::new()),
    );
    router.register_provider(Box::new(LocalEchoAdapter::new(ProviderCapabilities {
        provider_id: "local-echo".to_owned(),
        locality: Locality::Local,
        capabilities: vec![Capability::Chat],
        streaming: false,
        context_window: 8_000,
        latency_class: LatencyClass::Interactive,
        cost_class: CostClass::Metered,
        models: vec![ModelInfo {
            model_id: "local-echo-model".to_owned(),
            capabilities: vec![Capability::Chat],
            streaming: false,
        }],
    })));
    router.register_chain(Capability::Chat, CostClass::Metered, &["local-echo"]);

    let mut sched = TurnScheduler::new(Uuid::now_v7());

    // aiko takes the floor and completes a real route.
    let (d, runnable, _) = sched.submit("aiko", request(true));
    assert_eq!(d, SubmitDecision::Proceed);
    let resp = router.route(&runnable.expect("granted")).expect("routes");
    assert_eq!(resp.provider_id, "local-echo");

    // bob queued while aiko speaks; promoted after completion and his held
    // request routes for real too — the full §7.2 lifecycle against the
    // actual router, not a mock of it.
    let (d, _, _) = sched.submit("bob", request(true));
    assert_eq!(d, SubmitDecision::Queued);
    let (next, _) = sched.complete("aiko");
    let held = next.expect("bob's held request");
    let resp = router.route(&held.request).expect("held request routes");
    assert_eq!(resp.provider_id, "local-echo");
    let (none, _) = sched.complete("bob");
    assert!(none.is_none());
    assert_eq!(sched.current_speaker(), None);
}
