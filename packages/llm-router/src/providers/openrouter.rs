//! OpenRouter adapter (I5 slice 3) — the first real *cloud* provider,
//! and so the first adapter that actually exercises TLS, Bearer-token
//! credentials (SEC-030), and the SEC-035 consent gate's real target
//! (`router.rs`'s consent gate is only meaningful once at least one
//! registered provider is genuinely `Locality::Cloud` and genuinely
//! reachable).
//!
//! Verified against OpenRouter's own published API docs before writing any
//! code (same discipline as the Ollama adapter): `POST
//! https://openrouter.ai/api/v1/chat/completions`, `Authorization: Bearer
//! <key>`, request `{model, messages:[{role,content}],
//! tools:[{type:"function",function:{name,description,parameters}}],
//! stream, max_tokens}`, response `{choices:[{finish_reason,message:
//! {role,content,tool_calls:[{id,type:"function",function:{name,
//! arguments}}]}}], usage:{prompt_tokens,completion_tokens,total_tokens}}`.
//! OpenRouter normalizes `finish_reason` across every underlying vendor to
//! one of `tool_calls`/`stop`/`length`/`content_filter`/`error` — this is
//! the first adapter that can actually produce `StopReason::Refused`
//! (`content_filter`/`error`), which the Ollama adapter never did (local
//! models have no equivalent content-moderation stop reason).
//!
//! One real wire-format difference from Ollama worth calling out because
//! it would have been an easy, silent bug: OpenRouter's
//! `tool_calls[].function.arguments` is a **JSON-encoded string**, not a
//! JSON object like Ollama's — it must be parsed, not used as-is.
//!
//! Deliberately out of scope for this slice, same as Ollama's:
//! multi-turn tool-result continuation (sending a prior tool's output back
//! as a `role: "tool"` message with `tool_call_id`) — this crate's neutral
//! `Message` type has no `tool_call_id` field yet, and nothing else in the
//! Router exercises multi-turn conversation state either, so extending the
//! contract for this one adapter now would be guessing ahead of an actual
//! need. Image content parts are likewise not wired (OpenRouter supports
//! `image_url` parts, but this crate's own `ContentPart::Image` doesn't yet
//! specify whether `value` is a URL or base64 data — mapping it correctly
//! would mean guessing at our *own* contract's semantics, not just the
//! vendor's).

use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::adapter::{ProviderAdapter, ProviderError};
use crate::types::{
    Capability, ContentPart, CostClass, EstimatedCost, LatencyClass, Locality, ModelInfo,
    ProviderCapabilities, Role, RouterRequest, RouterResponse, StopReason, ToolCallOut, Usage,
};

const DEFAULT_BASE_URL: &str = "https://openrouter.ai/api/v1";

#[derive(Serialize)]
struct ChatRequest<'a> {
    model: &'a str,
    messages: Vec<ChatRequestMessage>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    tools: Vec<ChatTool>,
    stream: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    max_tokens: Option<u32>,
}

#[derive(Serialize)]
struct ChatRequestMessage {
    role: &'static str,
    content: String,
}

#[derive(Serialize)]
struct ChatTool {
    #[serde(rename = "type")]
    kind: &'static str,
    function: ChatToolFunction,
}

#[derive(Serialize)]
struct ChatToolFunction {
    name: String,
    description: String,
    parameters: Value,
}

#[derive(Deserialize)]
struct ChatResponse {
    #[serde(default)]
    choices: Vec<ChatChoice>,
    #[serde(default)]
    usage: Option<ChatUsage>,
}

#[derive(Deserialize)]
struct ChatChoice {
    finish_reason: Option<String>,
    message: ChatResponseMessage,
}

#[derive(Deserialize, Default)]
struct ChatResponseMessage {
    #[serde(default)]
    content: Option<String>,
    #[serde(default)]
    tool_calls: Vec<ChatResponseToolCall>,
}

#[derive(Deserialize)]
struct ChatResponseToolCall {
    function: ChatResponseFunctionCall,
}

#[derive(Deserialize)]
struct ChatResponseFunctionCall {
    name: String,
    /// A JSON-encoded **string** on this wire format, unlike Ollama's plain
    /// object -- see module doc. Parsed defensively in `to_router_response`.
    arguments: String,
}

#[derive(Deserialize)]
struct ChatUsage {
    #[serde(default)]
    prompt_tokens: u32,
    #[serde(default)]
    completion_tokens: u32,
}

fn role_str(role: Role) -> &'static str {
    match role {
        Role::System => "system",
        Role::User => "user",
        Role::Assistant => "assistant",
        Role::Tool => "tool",
    }
}

fn flatten_content(parts: &[ContentPart]) -> String {
    parts
        .iter()
        .filter_map(|p| match p {
            ContentPart::Text { value } => Some(value.as_str()),
            ContentPart::Image { .. } | ContentPart::Audio { .. } => None,
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn build_request<'a>(model: &'a str, request: &RouterRequest) -> ChatRequest<'a> {
    ChatRequest {
        model,
        messages: request
            .messages
            .iter()
            .map(|m| ChatRequestMessage {
                role: role_str(m.role),
                content: flatten_content(&m.content),
            })
            .collect(),
        tools: request
            .tools
            .iter()
            .map(|t| ChatTool {
                kind: "function",
                function: ChatToolFunction {
                    name: t.name.clone(),
                    description: t.description.clone(),
                    parameters: t.input_schema.clone(),
                },
            })
            .collect(),
        stream: false,
        max_tokens: Some(request.limits.max_output_tokens),
    }
}

/// Parses the JSON-string `arguments` field defensively: if it isn't valid
/// JSON (a misbehaving provider behind OpenRouter's normalization layer),
/// fall back to wrapping the raw string rather than failing the whole
/// response over one tool call's malformed arguments.
fn parse_tool_arguments(raw: &str) -> Value {
    serde_json::from_str(raw).unwrap_or_else(|_| Value::String(raw.to_owned()))
}

fn map_finish_reason(reason: Option<&str>, has_tool_calls: bool) -> StopReason {
    if has_tool_calls {
        return StopReason::ToolCall;
    }
    match reason {
        Some("length") => StopReason::MaxTokens,
        // `content_filter`: the model's output was moderated away.
        // `error`: the upstream vendor stopped generation abnormally.
        // Neither is "the model finished normally," so both map to the one
        // stop reason AI_PROVIDER_API gives us for "didn't really answer."
        Some("content_filter") | Some("error") => StopReason::Refused,
        _ => StopReason::End,
    }
}

fn to_router_response(
    request: &RouterRequest,
    provider_id: &str,
    model_id: &str,
    parsed: ChatResponse,
) -> Result<RouterResponse, ProviderError> {
    let choice = parsed
        .choices
        .into_iter()
        .next()
        .ok_or(ProviderError::Unreachable)?;
    let tool_calls: Vec<ToolCallOut> = choice
        .message
        .tool_calls
        .into_iter()
        .map(|tc| ToolCallOut {
            name: tc.function.name,
            input: parse_tool_arguments(&tc.function.arguments),
        })
        .collect();
    let stop_reason = map_finish_reason(choice.finish_reason.as_deref(), !tool_calls.is_empty());
    let content = match choice.message.content {
        Some(text) if !text.is_empty() => vec![ContentPart::Text { value: text }],
        _ => Vec::new(),
    };
    let (input_tokens, output_tokens) = parsed
        .usage
        .map(|u| (u.prompt_tokens, u.completion_tokens))
        .unwrap_or((0, 0));
    Ok(RouterResponse {
        request_id: request.request_id,
        provider_id: provider_id.to_owned(),
        model_id: model_id.to_owned(),
        content,
        tool_calls,
        stop_reason,
        usage: Usage {
            input_tokens,
            output_tokens,
            cost_class: CostClass::Metered,
            // Real cost needs a follow-up call to /api/v1/generation keyed
            // on the response `id` -- OpenRouter doesn't put actual billed
            // cost in this response body. Not wired this slice; documented
            // rather than silently reported as free.
            estimated_cost: EstimatedCost {
                amount: 0.0,
                currency: "USD".to_owned(),
            },
        },
        fallback_depth: 0, // overwritten by Router::route
    })
}

fn map_error(err: &ureq::Error) -> ProviderError {
    match err {
        ureq::Error::Timeout(_) => ProviderError::Timeout,
        ureq::Error::HostNotFound | ureq::Error::ConnectionFailed | ureq::Error::Io(_) => {
            ProviderError::Unreachable
        }
        ureq::Error::StatusCode(_) | ureq::Error::Json(_) => ProviderError::ElevatedErrorRate,
        _ => ProviderError::Unreachable,
    }
}

/// A real OpenRouter account, one adapter instance per model. `base_url`
/// defaults to the real endpoint but stays configurable (matches the
/// `OllamaAdapter` pattern, and is useful for pointing at a test double).
pub struct OpenRouterAdapter {
    caps: ProviderCapabilities,
    base_url: String,
    model: String,
    agent: ureq::Agent,
}

impl OpenRouterAdapter {
    #[must_use]
    pub fn new(
        provider_id: impl Into<String>,
        model: impl Into<String>,
        timeout: Duration,
    ) -> Self {
        Self::with_base_url(provider_id, DEFAULT_BASE_URL, model, timeout)
    }

    #[must_use]
    pub fn with_base_url(
        provider_id: impl Into<String>,
        base_url: impl Into<String>,
        model: impl Into<String>,
        timeout: Duration,
    ) -> Self {
        let model = model.into();
        // Explicit `native-tls` provider (see Cargo.toml comment): this
        // crate builds with `default-features = false`, so the TLS backend
        // must be configured here rather than relying on rustls being the
        // implicit default.
        let config = ureq::Agent::config_builder()
            .timeout_global(Some(timeout))
            .proxy(ureq::Proxy::try_from_env())
            .tls_config(
                ureq::tls::TlsConfig::builder()
                    .provider(ureq::tls::TlsProvider::NativeTls)
                    // See `providers::claude`'s identical comment: ureq's
                    // `RootCerts` default (`WebPki`) needs a cargo feature
                    // this crate doesn't enable, so under `NativeTls` it
                    // silently resolves to zero root certs -- a real bug
                    // found live via `examples/fallback_live.rs`, not by any
                    // unit test (all of which mock the adapter). explicit
                    // `PlatformVerifier` makes native-tls use the Windows
                    // Certificate Store via SChannel, as intended when this
                    // adapter switched from `Rustls` to `NativeTls`.
                    .root_certs(ureq::tls::RootCerts::PlatformVerifier)
                    .build(),
            )
            .build();
        Self {
            caps: ProviderCapabilities {
                provider_id: provider_id.into(),
                locality: Locality::Cloud,
                capabilities: vec![Capability::Chat],
                streaming: false, // this adapter only implements the non-streaming path (see module doc)
                context_window: 128_000, // conservative default; actual value is per-model, not queryable generically here
                latency_class: LatencyClass::Interactive,
                cost_class: CostClass::Metered,
                models: vec![ModelInfo {
                    model_id: model.clone(),
                    capabilities: vec![Capability::Chat],
                    streaming: false,
                }],
            },
            base_url: base_url.into(),
            model,
            agent: config.new_agent(),
        }
    }
}

impl ProviderAdapter for OpenRouterAdapter {
    fn capabilities(&self) -> &ProviderCapabilities {
        &self.caps
    }

    fn invoke(
        &self,
        request: &RouterRequest,
        credential: Option<&str>,
    ) -> Result<RouterResponse, ProviderError> {
        // SEC-030: unlike the local Ollama adapter, a credential here is
        // not optional -- OpenRouter requires it. Bailing out before making
        // a network call we already know will 401 is a courtesy, not a
        // behavior change: an unauthenticated call would fail with
        // ElevatedErrorRate anyway via `map_error`'s `StatusCode` arm.
        let Some(token) = credential else {
            return Err(ProviderError::Unreachable);
        };

        let url = format!("{}/chat/completions", self.base_url.trim_end_matches('/'));
        let body = build_request(&self.model, request);

        let mut response = self
            .agent
            .post(url.as_str())
            .header("Authorization", format!("Bearer {token}").as_str())
            .send_json(&body)
            .map_err(|e| map_error(&e))?;
        let parsed: ChatResponse = response.body_mut().read_json().map_err(|e| map_error(&e))?;
        to_router_response(request, &self.caps.provider_id, &self.model, parsed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{CallerContext, Limits, Message, RoutePolicy};
    use uuid::Uuid;

    fn sample_request() -> RouterRequest {
        RouterRequest {
            request_id: Uuid::now_v7(),
            correlation_id: Uuid::now_v7(),
            capability: Capability::Chat,
            messages: vec![Message {
                role: Role::User,
                content: vec![ContentPart::Text {
                    value: "what is the meaning of life?".to_owned(),
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
                max_output_tokens: 512,
            },
        }
    }

    #[test]
    fn build_request_sets_max_tokens_from_the_neutral_limits_field() {
        let req = build_request("openai/gpt-4o", &sample_request());
        assert_eq!(req.model, "openai/gpt-4o");
        assert_eq!(req.max_tokens, Some(512));
        assert!(!req.stream);
    }

    #[test]
    fn tool_call_arguments_are_parsed_from_a_json_encoded_string_not_used_raw() {
        let parsed = ChatResponse {
            choices: vec![ChatChoice {
                finish_reason: Some("tool_calls".to_owned()),
                message: ChatResponseMessage {
                    content: None,
                    tool_calls: vec![ChatResponseToolCall {
                        function: ChatResponseFunctionCall {
                            name: "get_current_weather".to_owned(),
                            arguments: r#"{ "location": "Boston, MA" }"#.to_owned(),
                        },
                    }],
                },
            }],
            usage: Some(ChatUsage {
                prompt_tokens: 50,
                completion_tokens: 12,
            }),
        };
        let response = to_router_response(
            &sample_request(),
            "openrouter-cloud",
            "openai/gpt-4o",
            parsed,
        )
        .expect("maps cleanly");
        assert_eq!(response.stop_reason, StopReason::ToolCall);
        assert_eq!(response.tool_calls.len(), 1);
        assert_eq!(
            response.tool_calls[0].input,
            serde_json::json!({ "location": "Boston, MA" }),
            "the string-encoded arguments must be parsed into a real JSON value, not left as a string"
        );
    }

    #[test]
    fn malformed_tool_arguments_fall_back_to_a_string_value_instead_of_failing_the_whole_response()
    {
        let parsed = ChatResponse {
            choices: vec![ChatChoice {
                finish_reason: Some("tool_calls".to_owned()),
                message: ChatResponseMessage {
                    content: None,
                    tool_calls: vec![ChatResponseToolCall {
                        function: ChatResponseFunctionCall {
                            name: "broken_tool".to_owned(),
                            arguments: "not valid json".to_owned(),
                        },
                    }],
                },
            }],
            usage: None,
        };
        let response = to_router_response(
            &sample_request(),
            "openrouter-cloud",
            "openai/gpt-4o",
            parsed,
        )
        .expect("maps cleanly even with malformed arguments");
        assert_eq!(
            response.tool_calls[0].input,
            serde_json::json!("not valid json")
        );
    }

    #[test]
    fn content_filter_and_error_finish_reasons_map_to_refused() {
        assert_eq!(
            map_finish_reason(Some("content_filter"), false),
            StopReason::Refused
        );
        assert_eq!(map_finish_reason(Some("error"), false), StopReason::Refused);
        assert_eq!(map_finish_reason(Some("stop"), false), StopReason::End);
        assert_eq!(
            map_finish_reason(Some("length"), false),
            StopReason::MaxTokens
        );
        assert_eq!(
            map_finish_reason(Some("stop"), true),
            StopReason::ToolCall,
            "a tool call present always wins over the reported finish_reason"
        );
    }

    #[test]
    fn missing_credential_is_rejected_before_any_network_call() {
        let adapter =
            OpenRouterAdapter::new("openrouter-cloud", "openai/gpt-4o", Duration::from_secs(5));
        let err = adapter
            .invoke(&sample_request(), None)
            .expect_err("OpenRouter requires a credential, unlike the local Ollama adapter");
        assert_eq!(err, ProviderError::Unreachable);
    }
}
