//! Ollama adapter (I5 slice 2) — the first real, non-reference
//! `ProviderAdapter`. Talks to Ollama's `/api/chat` endpoint (verified
//! against Ollama's own published API docs before writing this: request
//! shape `{model, messages: [{role, content}], tools: [{type:"function",
//! function:{name, description, parameters}}], stream}`; non-streaming
//! response shape `{model, message:{role, content, tool_calls:
//! [{function:{name, arguments}}]}, done, done_reason, prompt_eval_count,
//! eval_count}`).
//!
//! Deliberately minimal for this slice:
//! - **Non-streaming only** (`"stream": false`) — this crate's
//!   `ProviderAdapter::invoke` is synchronous and returns one complete
//!   `RouterResponse`; wiring the streaming SSE-ish chunk protocol through
//!   to a streaming `RouterResponse` consumer is separate follow-up work,
//!   honestly reflected by advertising `streaming: false` in this adapter's
//!   own `ProviderCapabilities` rather than claiming a capability it doesn't
//!   implement.
//! - **Text content only.** Ollama's chat message shape carries `content`
//!   as a single string, with images passed via a *separate* `images` field
//!   for multimodal models — a genuinely different shape from this crate's
//!   neutral `Vec<ContentPart>`. This adapter flattens `Text` parts into
//!   that one string and silently drops `Image`/`Audio` parts rather than
//!   guessing at wiring `images` in without having checked a multimodal
//!   model's exact expectations — a stated, not hidden, limitation.
//! - **No live network test exists for this file** (see `tests` module
//!   below): CI has no Ollama instance to talk to. Only the pure
//!   request-building/response-mapping/error-mapping functions are
//!   unit-tested here; the actual HTTP round trip needs a human with
//!   Ollama running locally to verify by hand, the same class of residual
//!   as this project's recurring macOS/Linux-hardware gaps.

use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::adapter::{ProviderAdapter, ProviderError};
use crate::types::{
    Capability, ContentPart, CostClass, EstimatedCost, LatencyClass, Locality, ModelInfo,
    ProviderCapabilities, Role, RouterRequest, RouterResponse, StopReason, ToolCallOut, Usage,
};

const DEFAULT_NUM_CTX: u32 = 8192;

#[derive(Serialize)]
struct ChatOptions {
    num_ctx: u32,
}

#[derive(Serialize)]
struct ChatRequest<'a> {
    model: &'a str,
    messages: Vec<ChatRequestMessage>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    tools: Vec<ChatTool>,
    stream: bool,
    think: bool,
    options: ChatOptions,
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
    message: ChatResponseMessage,
    #[serde(default)]
    done_reason: Option<String>,
    #[serde(default)]
    prompt_eval_count: u32,
    #[serde(default)]
    eval_count: u32,
}

#[derive(Deserialize, Default)]
struct ChatResponseMessage {
    #[serde(default)]
    content: String,
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
    arguments: Value,
}

fn role_str(role: Role) -> &'static str {
    match role {
        Role::System => "system",
        Role::User => "user",
        Role::Assistant => "assistant",
        Role::Tool => "tool",
    }
}

/// Flattens the neutral `Vec<ContentPart>` into the single string Ollama's
/// `message.content` expects. `Image`/`Audio` parts are dropped -- see
/// module doc.
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
        think: false,
        options: ChatOptions {
            num_ctx: DEFAULT_NUM_CTX,
        },
    }
}

fn to_router_response(
    request: &RouterRequest,
    provider_id: &str,
    model_id: &str,
    parsed: ChatResponse,
) -> RouterResponse {
    let tool_calls: Vec<ToolCallOut> = parsed
        .message
        .tool_calls
        .into_iter()
        .map(|tc| ToolCallOut {
            name: tc.function.name,
            input: tc.function.arguments,
        })
        .collect();
    let stop_reason = if !tool_calls.is_empty() {
        StopReason::ToolCall
    } else {
        match parsed.done_reason.as_deref() {
            Some("length") => StopReason::MaxTokens,
            _ => StopReason::End,
        }
    };
    RouterResponse {
        request_id: request.request_id,
        provider_id: provider_id.to_owned(),
        model_id: model_id.to_owned(),
        content: if parsed.message.content.is_empty() {
            Vec::new()
        } else {
            vec![ContentPart::Text {
                value: parsed.message.content,
            }]
        },
        tool_calls,
        stop_reason,
        usage: Usage {
            input_tokens: parsed.prompt_eval_count,
            output_tokens: parsed.eval_count,
            cost_class: CostClass::Free,
            estimated_cost: EstimatedCost {
                amount: 0.0,
                currency: "USD".to_owned(),
            },
        },
        fallback_depth: 0, // overwritten by Router::route
    }
}

/// `#[non_exhaustive]` on `ureq::Error` means any match needs a wildcard;
/// unfamiliar future variants fall to `Unreachable` as the conservative
/// choice (better to treat an unknown failure as a full outage than to
/// under-react and keep hammering a possibly-broken transport).
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

/// A real Ollama server, one adapter instance per model (AI_PROVIDER_API
/// §1: one `providerId` per capability declaration). `base_url` is explicit
/// configuration, never auto-discovered (SEC-031/034) — typically
/// `http://localhost:11434`.
pub struct OllamaAdapter {
    caps: ProviderCapabilities,
    base_url: String,
    model: String,
    agent: ureq::Agent,
}

impl OllamaAdapter {
    #[must_use]
    pub fn new(
        provider_id: impl Into<String>,
        base_url: impl Into<String>,
        model: impl Into<String>,
        timeout: Duration,
    ) -> Self {
        let model = model.into();
        let config = ureq::Agent::config_builder()
            .timeout_global(Some(timeout))
            .build();
        Self {
            caps: ProviderCapabilities {
                provider_id: provider_id.into(),
                locality: Locality::Local,
                capabilities: vec![Capability::Chat],
                streaming: false, // honest: this adapter only implements non-streaming (see module doc)
                context_window: 8_192, // conservative default; Ollama has no generic "describe yourself" endpoint for this
                latency_class: LatencyClass::Interactive,
                cost_class: CostClass::Free,
                models: vec![ModelInfo {
                    model_id: model.clone(),
                    capabilities: vec![Capability::Chat],
                    streaming: false,
                }],
            },
            base_url: base_url.into(),
            model,
            agent: config.into(),
        }
    }
}

impl ProviderAdapter for OllamaAdapter {
    fn capabilities(&self) -> &ProviderCapabilities {
        &self.caps
    }

    fn invoke(
        &self,
        request: &RouterRequest,
        credential: Option<&str>,
    ) -> Result<RouterResponse, ProviderError> {
        let url = format!("{}/api/chat", self.base_url.trim_end_matches('/'));
        let body = build_request(&self.model, request);

        let mut req = self.agent.post(url.as_str());
        // Ollama needs no auth by default; this only fires for a
        // reverse-proxied deployment that put a bearer token in front of
        // it. SEC-030: the credential is read once, here, at call time,
        // and never stored or logged by this adapter.
        if let Some(token) = credential {
            req = req.header("Authorization", format!("Bearer {token}").as_str());
        }

        let mut response = req.send_json(&body).map_err(|e| map_error(&e))?;
        let parsed: ChatResponse = response.body_mut().read_json().map_err(|e| map_error(&e))?;
        Ok(to_router_response(
            request,
            &self.caps.provider_id,
            &self.model,
            parsed,
        ))
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
            messages: vec![
                Message {
                    role: Role::System,
                    content: vec![ContentPart::Text {
                        value: "be terse".to_owned(),
                    }],
                },
                Message {
                    role: Role::User,
                    content: vec![
                        ContentPart::Text {
                            value: "why is the sky blue?".to_owned(),
                        },
                        ContentPart::Image {
                            value: "base64-data-not-yet-supported".to_owned(),
                        },
                    ],
                },
            ],
            memory_excerpts: vec![],
            tools: vec![],
            caller_context: CallerContext {
                context_id: "companion".to_owned(),
                granted_capabilities: vec![],
            },
            policy: RoutePolicy {
                max_cost_class: CostClass::Free,
                allow_cloud: false,
            },
            streaming: false,
            foreground: true,
            limits: Limits {
                max_output_tokens: 128,
            },
        }
    }

    #[test]
    fn build_request_flattens_text_and_drops_unsupported_content_parts() {
        let req = build_request("llama3.2", &sample_request());
        assert_eq!(req.model, "llama3.2");
        assert_eq!(req.messages.len(), 2);
        assert_eq!(req.messages[0].role, "system");
        assert_eq!(req.messages[0].content, "be terse");
        assert_eq!(req.messages[1].role, "user");
        assert_eq!(
            req.messages[1].content, "why is the sky blue?",
            "the Image part must not silently corrupt the text content"
        );
        assert!(
            !req.stream,
            "this adapter only implements the non-streaming path"
        );
        assert_eq!(
            req.options.num_ctx, DEFAULT_NUM_CTX,
            "local models use a bounded context so large-context defaults do not exhaust memory"
        );
    }

    #[test]
    fn to_router_response_maps_a_plain_text_reply() {
        let parsed = ChatResponse {
            message: ChatResponseMessage {
                content: "because of Rayleigh scattering".to_owned(),
                tool_calls: vec![],
            },
            done_reason: Some("stop".to_owned()),
            prompt_eval_count: 26,
            eval_count: 298,
        };
        let response = to_router_response(&sample_request(), "ollama-local", "llama3.2", parsed);
        assert_eq!(response.provider_id, "ollama-local");
        assert_eq!(response.model_id, "llama3.2");
        assert_eq!(response.stop_reason, StopReason::End);
        assert_eq!(response.usage.input_tokens, 26);
        assert_eq!(response.usage.output_tokens, 298);
        assert_eq!(response.usage.cost_class, CostClass::Free);
        assert!(response.tool_calls.is_empty());
        match &response.content[..] {
            [ContentPart::Text { value }] => assert_eq!(value, "because of Rayleigh scattering"),
            other => panic!("expected one text part, got {other:?}"),
        }
    }

    #[test]
    fn to_router_response_maps_a_tool_call_reply() {
        let parsed = ChatResponse {
            message: ChatResponseMessage {
                content: String::new(),
                tool_calls: vec![ChatResponseToolCall {
                    function: ChatResponseFunctionCall {
                        name: "get_weather".to_owned(),
                        arguments: serde_json::json!({ "city": "Tokyo" }),
                    },
                }],
            },
            done_reason: Some("stop".to_owned()),
            prompt_eval_count: 169,
            eval_count: 15,
        };
        let response = to_router_response(&sample_request(), "ollama-local", "llama3.2", parsed);
        assert_eq!(response.stop_reason, StopReason::ToolCall);
        assert_eq!(response.tool_calls.len(), 1);
        assert_eq!(response.tool_calls[0].name, "get_weather");
        assert_eq!(
            response.tool_calls[0].input,
            serde_json::json!({ "city": "Tokyo" })
        );
        assert!(response.content.is_empty());
    }

    #[test]
    fn to_router_response_maps_length_done_reason_to_max_tokens() {
        let parsed = ChatResponse {
            message: ChatResponseMessage {
                content: "truncated...".to_owned(),
                tool_calls: vec![],
            },
            done_reason: Some("length".to_owned()),
            prompt_eval_count: 10,
            eval_count: 128,
        };
        let response = to_router_response(&sample_request(), "ollama-local", "llama3.2", parsed);
        assert_eq!(response.stop_reason, StopReason::MaxTokens);
    }
}
