//! One deliberate, user-run Gemini Developer API smoke test.
//!
//! This example makes exactly one small text request through OCP's real
//! `Router`: OS-keystore credential lookup, cloud-provider registration,
//! policy selection, Gemini request/response mapping, and TLS. It never logs
//! the API key and is intentionally not a CI test.

use std::time::Duration;

use ocp_event_bus::InProcessBus;
use ocp_llm_router::providers::gemini::GeminiAdapter;
use ocp_llm_router::types::{
    CallerContext, Capability, ContentPart, CostClass, Limits, Message, Role, RoutePolicy,
    RouterRequest,
};
use ocp_llm_router::{InMemoryConsentStore, OsKeystoreCredentialStore, Router};
use uuid::Uuid;

fn main() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let provider_id = args
        .next()
        .ok_or("usage: cargo run -p ocp-llm-router --example gemini_smoke_live -- <provider-id> <model-id>")?;
    let model_id = args
        .next()
        .ok_or("usage: cargo run -p ocp-llm-router --example gemini_smoke_live -- <provider-id> <model-id>")?;
    if args.next().is_some() {
        return Err("usage: cargo run -p ocp-llm-router --example gemini_smoke_live -- <provider-id> <model-id>".to_owned());
    }

    let mut router = Router::new(
        InProcessBus::new(),
        Box::new(InMemoryConsentStore::new()),
        Box::new(OsKeystoreCredentialStore::new("ocp-ai-provider")),
    );
    router.register_provider(Box::new(GeminiAdapter::new(
        provider_id.clone(),
        model_id.clone(),
        Duration::from_secs(30),
    )));
    router.register_chain(
        Capability::Chat,
        CostClass::Metered,
        &[provider_id.as_str()],
    );

    let request = RouterRequest {
        request_id: Uuid::now_v7(),
        correlation_id: Uuid::now_v7(),
        capability: Capability::Chat,
        messages: vec![Message {
            role: Role::User,
            content: vec![ContentPart::Text {
                value: "Reply with exactly: Gemini direct adapter smoke test passed.".to_owned(),
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
        foreground: true,
        limits: Limits {
            max_output_tokens: 64,
        },
    };

    let response = router
        .route(&request)
        .map_err(|error| format!("Gemini smoke test failed: {error:?}"))?;
    let text = response
        .content
        .iter()
        .filter_map(|part| match part {
            ContentPart::Text { value } => Some(value.as_str()),
            ContentPart::Image { .. } | ContentPart::Audio { .. } => None,
        })
        .collect::<Vec<_>>()
        .join("\n");
    println!(
        "Gemini smoke test succeeded: provider={}, model={}",
        response.provider_id, response.model_id
    );
    println!("Response: {text}");
    Ok(())
}
