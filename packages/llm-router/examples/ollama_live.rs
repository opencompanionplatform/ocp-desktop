//! Manual, live verification of `OllamaAdapter` against a real local Ollama
//! server. Not part of `cargo test` -- CS-AIP has no network access to a
//! live Ollama instance, so the actual HTTP round trip has always been a
//! documented residual (see SPRINT_CHECKLIST.md's I5 slice 2 note). This is
//! that residual's manual check.
//!
//! Usage:
//!   cargo run -p ocp-llm-router --example ollama_live -- [model] [question] [timeout_secs]
//!
//! Defaults to model "llama3.2", a one-line question, and a 120s timeout if
//! not given. Requires Ollama running locally (`ollama serve`, usually
//! automatic) with the model already pulled (`ollama pull <model>`) --
//! `ollama ls` lists what's actually available. The default timeout is
//! generous on purpose: a model's *first* request after being idle pays a
//! cold-start cost to load into memory, which can easily exceed the naive
//! 30s this example started with -- a `Timeout` here on the very first try
//! against a real model isn't necessarily a bug, just a slow first load.

use std::time::Duration;

use ocp_llm_router::adapter::ProviderAdapter;
use ocp_llm_router::providers::ollama::OllamaAdapter;
use ocp_llm_router::types::{
    CallerContext, Capability, ContentPart, CostClass, Limits, Message, Role, RoutePolicy,
    RouterRequest,
};
use uuid::Uuid;

fn main() {
    let mut args = std::env::args().skip(1);
    let model = args.next().unwrap_or_else(|| "llama3.2".to_owned());
    let question = args
        .next()
        .unwrap_or_else(|| "Why is the sky blue? Answer in one short sentence.".to_owned());
    let timeout_secs: u64 = args.next().and_then(|s| s.parse().ok()).unwrap_or(120);

    println!("Talking to Ollama at http://localhost:11434 with model \"{model}\" (timeout {timeout_secs}s)...");
    println!("Question: {question}\n");

    let adapter = OllamaAdapter::new(
        "ollama-local",
        "http://localhost:11434",
        model.as_str(),
        Duration::from_secs(timeout_secs),
    );

    let request = RouterRequest {
        request_id: Uuid::now_v7(),
        correlation_id: Uuid::now_v7(),
        capability: Capability::Chat,
        messages: vec![Message {
            role: Role::User,
            content: vec![ContentPart::Text {
                value: question.clone(),
            }],
        }],
        memory_excerpts: vec![],
        tools: vec![],
        caller_context: CallerContext {
            context_id: "manual-live-test".to_owned(),
            granted_capabilities: vec![],
        },
        policy: RoutePolicy {
            max_cost_class: CostClass::Free,
            allow_cloud: false,
        },
        streaming: false,
        foreground: true,
        limits: Limits {
            max_output_tokens: 256,
        },
    };

    match adapter.invoke(&request, None) {
        Ok(response) => {
            println!("--- SUCCESS ---");
            println!("provider:    {}", response.provider_id);
            println!("model:       {}", response.model_id);
            println!("stop_reason: {:?}", response.stop_reason);
            println!(
                "usage:       {} in / {} out tokens",
                response.usage.input_tokens, response.usage.output_tokens
            );
            for part in &response.content {
                if let ContentPart::Text { value } = part {
                    println!("\nreply:\n{value}");
                }
            }
        }
        Err(e) => {
            eprintln!("--- FAILED: {e:?} ---");
            match e {
                ocp_llm_router::adapter::ProviderError::Timeout => eprintln!(
                    "\nTimed out after {timeout_secs}s. If this was the model's first request in a while, it may just be a slow cold-start load -- try again (a second call is usually much faster), or re-run with a longer timeout: `... -- {model} \"{question}\" 300`."
                ),
                ocp_llm_router::adapter::ProviderError::ElevatedErrorRate => eprintln!(
                    "\nOllama returned an error response -- most commonly a model name that isn't pulled. Run `ollama ls` to see what's actually available, then `ollama pull {model}` if it's missing."
                ),
                ocp_llm_router::adapter::ProviderError::Unreachable => eprintln!(
                    "\nCouldn't reach Ollama at all. Is it running? Try `ollama serve`."
                ),
                ocp_llm_router::adapter::ProviderError::AuthFailed => eprintln!(
                    "\nThe selected provider rejected its credential. Local Ollama normally does not require one, so check the adapter/base URL configuration."
                ),
                ocp_llm_router::adapter::ProviderError::RateLimited => eprintln!(
                    "\nThe selected provider is temporarily rate-limited. Retry after a short backoff. Local Ollama normally has no cloud rate limit, so check whether this endpoint is actually a remote compatible provider."
                ),
                ocp_llm_router::adapter::ProviderError::QuotaExceeded => eprintln!(
                    "\nThe selected provider reported an exhausted project/daily quota. Local Ollama normally has no cloud quota, so check whether this endpoint is actually a remote compatible provider."
                ),
            }
            std::process::exit(1);
        }
    }
}
