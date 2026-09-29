//! Claude (Anthropic) adapter (I5 slice 4) — a second real cloud provider,
//! reached directly (not via OpenRouter's proxy).
//!
//! Verified against Anthropic's own Messages API reference and Amazon
//! Bedrock's mirror of the same Messages API shape (used to cross-confirm
//! the content-block/`stop_reason` semantics, since the primary docs page
//! is a client-rendered app this session's fetch tooling couldn't read
//! directly — cross-checking a second independent source rather than
//! guessing from the one page that failed to render) before writing any
//! code: `POST https://api.anthropic.com/v1/messages`, headers `x-api-key`
//! + `anthropic-version`, request `{model, max_tokens, system, messages:
//! [{role,content}], tools:[{name,description,input_schema}]}`, response
//!   `{content:[{type:"text",text}|{type:"tool_use",name,input}], stop_reason,
//! usage:{input_tokens,output_tokens}}`.
//!
//! Two real wire-format differences from the other two adapters, both
//! confirmed before writing code rather than assumed by analogy:
//! - **`system` is not a message.** Anthropic's Messages API takes only
//!   `user`/`assistant` roles in `messages`; a system prompt is a separate
//!   top-level `system` string field. This crate's neutral `Message` array
//!   can carry `Role::System` entries (Ollama and OpenRouter both accept a
//!   `system`-role message directly), so this adapter extracts and joins
//!   them into the top-level field instead of sending them as messages.
//! - **`tool_use.input` is already a JSON object**, like Ollama's shape and
//!   unlike OpenRouter's JSON-*string*-encoded `arguments` — no defensive
//!   string-parsing needed here.
//! - **`stop_reason: "refusal"` is an explicit, first-class value** — this
//!   is the first adapter where `StopReason::Refused` maps from a reason
//!   Anthropic documents by name, rather than an inferred/normalized
//!   `content_filter` the way OpenRouter's proxied vendors report it.
//!
//! Deliberately out of scope, same as Ollama/OpenRouter: multi-turn
//! tool-result messages (`tool_use_id`/`tool_result` content blocks --
//! this crate's neutral `Message` has no such field yet) and image content
//! parts (this crate's `ContentPart::Image.value` doesn't yet specify
//! URL-vs-base64 encoding, and Anthropic's image blocks want base64 +
//! media_type specifically -- wiring it now would mean guessing at our own
//! contract's semantics, not just the vendor's).

use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::adapter::{ProviderAdapter, ProviderError};
use crate::types::{
    Capability, ContentPart, CostClass, EstimatedCost, LatencyClass, Locality, ModelInfo,
    ProviderCapabilities, Role, RouterRequest, RouterResponse, StopReason, ToolCallOut, Usage,
};

const DEFAULT_BASE_URL: &str = "https://api.anthropic.com/v1";
/// The stable Messages API version header value (unrelated to model
/// versioning -- this identifies the wire-format revision, not the model).
const ANTHROPIC_VERSION: &str = "2023-06-01";

#[derive(Serialize)]
struct MessagesRequest<'a> {
    model: &'a str,
    max_tokens: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    system: Option<String>,
    messages: Vec<RequestMessage>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    tools: Vec<RequestTool>,
    stream: bool,
}

#[derive(Serialize)]
struct RequestMessage {
    role: &'static str,
    content: String,
}

#[derive(Serialize)]
struct RequestTool {
    name: String,
    description: String,
    input_schema: Value,
}

#[derive(Deserialize)]
struct MessagesResponse {
    #[serde(default)]
    content: Vec<ResponseContentBlock>,
    #[serde(default)]
    stop_reason: Option<String>,
    usage: ResponseUsage,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ResponseContentBlock {
    Text {
        text: String,
    },
    ToolUse {
        name: String,
        input: Value,
    },
    /// Anything else (e.g. `image`, or a future block type this adapter
    /// hasn't been taught about) is ignored rather than failing the whole
    /// response to parse.
    #[serde(other)]
    Other,
}

#[derive(Deserialize)]
struct ResponseUsage {
    #[serde(default)]
    input_tokens: u32,
    #[serde(default)]
    output_tokens: u32,
}

fn role_str(role: Role) -> &'static str {
    match role {
        Role::Assistant => "assistant",
        // Anthropic's Messages API has only user/assistant roles.
        // `Role::System` is extracted separately (see `build_request`) and
        // never reaches here in practice; `Role::Tool` (multi-turn
        // tool-result messages) is out of scope this slice, same as the
        // other two adapters -- mapped to "user" as the closest fallback
        // rather than silently dropping the message.
        Role::System | Role::User | Role::Tool => "user",
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

fn build_request<'a>(model: &'a str, request: &RouterRequest) -> MessagesRequest<'a> {
    let system_text = request
        .messages
        .iter()
        .filter(|m| m.role == Role::System)
        .map(|m| flatten_content(&m.content))
        .collect::<Vec<_>>()
        .join("\n\n");

    let messages = request
        .messages
        .iter()
        .filter(|m| m.role != Role::System)
        .map(|m| RequestMessage {
            role: role_str(m.role),
            content: flatten_content(&m.content),
        })
        .collect();

    MessagesRequest {
        model,
        max_tokens: request.limits.max_output_tokens,
        system: if system_text.is_empty() {
            None
        } else {
            Some(system_text)
        },
        messages,
        tools: request
            .tools
            .iter()
            .map(|t| RequestTool {
                name: t.name.clone(),
                description: t.description.clone(),
                input_schema: t.input_schema.clone(),
            })
            .collect(),
        stream: false,
    }
}

fn map_stop_reason(reason: Option<&str>, has_tool_calls: bool) -> StopReason {
    if has_tool_calls {
        return StopReason::ToolCall;
    }
    match reason {
        Some("max_tokens") | Some("model_context_window_exceeded") => StopReason::MaxTokens,
        Some("refusal") => StopReason::Refused,
        // "end_turn", "stop_sequence", or anything unrecognized -- treated
        // as a normal completion rather than guessed at further.
        _ => StopReason::End,
    }
}

fn to_router_response(
    request: &RouterRequest,
    provider_id: &str,
    model_id: &str,
    parsed: MessagesResponse,
) -> RouterResponse {
    let mut content = Vec::new();
    let mut tool_calls = Vec::new();
    for block in parsed.content {
        match block {
            ResponseContentBlock::Text { text } => content.push(ContentPart::Text { value: text }),
            ResponseContentBlock::ToolUse { name, input } => {
                tool_calls.push(ToolCallOut { name, input })
            }
            ResponseContentBlock::Other => {}
        }
    }
    let stop_reason = map_stop_reason(parsed.stop_reason.as_deref(), !tool_calls.is_empty());
    RouterResponse {
        request_id: request.request_id,
        provider_id: provider_id.to_owned(),
        model_id: model_id.to_owned(),
        content,
        tool_calls,
        stop_reason,
        usage: Usage {
            input_tokens: parsed.usage.input_tokens,
            output_tokens: parsed.usage.output_tokens,
            cost_class: CostClass::Metered,
            // Anthropic's response doesn't carry billed cost directly;
            // computing it needs the per-model price table applied to
            // input/output_tokens, not wired this slice -- documented, not
            // silently reported as free.
            estimated_cost: EstimatedCost {
                amount: 0.0,
                currency: "USD".to_owned(),
            },
        },
        fallback_depth: 0, // overwritten by Router::route
    }
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

/// A real Anthropic account, one adapter instance per model.
pub struct ClaudeAdapter {
    caps: ProviderCapabilities,
    base_url: String,
    model: String,
    agent: ureq::Agent,
}

impl ClaudeAdapter {
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
        let config = ureq::Agent::config_builder()
            .timeout_global(Some(timeout))
            .proxy(ureq::Proxy::try_from_env())
            .tls_config(
                ureq::tls::TlsConfig::builder()
                    .provider(ureq::tls::TlsProvider::NativeTls)
                    // ureq's `RootCerts` default is `WebPki` (a bundled
                    // Mozilla cert list) regardless of TLS provider -- but
                    // this crate's `ureq` dependency doesn't enable the
                    // `webpki-roots` feature that would actually supply
                    // those certs, so under `NativeTls` that default silently
                    // resolves to zero root certs, which native-tls reports
                    // as "unable to find any user-specified roots in the
                    // final cert chain" (a real bug, found live via
                    // `examples/fallback_live.rs` -- every unit test mocks
                    // the adapter, so nothing before a real network call
                    // could have caught this). `PlatformVerifier` is the
                    // correct pairing for `NativeTls`: per ureq's own docs,
                    // "For native-tls, this uses the roots that native-tls
                    // loads by default" -- the Windows Certificate Store via
                    // SChannel, which is what choosing `NativeTls` over
                    // `Rustls` was already meant to lean on.
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
                context_window: 200_000, // conservative published default; varies per model/beta header
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

impl ProviderAdapter for ClaudeAdapter {
    fn capabilities(&self) -> &ProviderCapabilities {
        &self.caps
    }

    fn invoke(
        &self,
        request: &RouterRequest,
        credential: Option<&str>,
    ) -> Result<RouterResponse, ProviderError> {
        // SEC-030: like OpenRouter (and unlike the local Ollama adapter), a
        // credential is mandatory -- bail before any network call rather
        // than making a request we already know will be rejected.
        let Some(key) = credential else {
            return Err(ProviderError::Unreachable);
        };

        let url = format!("{}/messages", self.base_url.trim_end_matches('/'));
        let body = build_request(&self.model, request);

        let mut response = self
            .agent
            .post(url.as_str())
            .header("x-api-key", key)
            .header("anthropic-version", ANTHROPIC_VERSION)
            .send_json(&body)
            .map_err(|e| map_error(&e))?;
        let parsed: MessagesResponse =
            response.body_mut().read_json().map_err(|e| map_error(&e))?;
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

    fn sample_request(with_system: bool) -> RouterRequest {
        let mut messages = Vec::new();
        if with_system {
            messages.push(Message {
                role: Role::System,
                content: vec![ContentPart::Text {
                    value: "be terse".to_owned(),
                }],
            });
        }
        messages.push(Message {
            role: Role::User,
            content: vec![ContentPart::Text {
                value: "why is the sky blue?".to_owned(),
            }],
        });
        RouterRequest {
            request_id: Uuid::now_v7(),
            correlation_id: Uuid::now_v7(),
            capability: Capability::Chat,
            messages,
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
    fn build_request_extracts_system_role_messages_into_the_top_level_field() {
        let req = build_request("claude-sonnet-5", &sample_request(true));
        assert_eq!(req.system.as_deref(), Some("be terse"));
        assert_eq!(
            req.messages.len(),
            1,
            "the system message must not also appear in `messages`"
        );
        assert_eq!(req.messages[0].role, "user");
        assert_eq!(
            req.max_tokens, 512,
            "max_tokens comes from the neutral Limits field, it's mandatory here"
        );
    }

    #[test]
    fn build_request_omits_system_field_entirely_when_there_is_none() {
        let req = build_request("claude-sonnet-5", &sample_request(false));
        assert_eq!(req.system, None);
    }

    #[test]
    fn tool_use_input_is_used_directly_as_a_json_object_no_string_parsing_needed() {
        let parsed = MessagesResponse {
            content: vec![ResponseContentBlock::ToolUse {
                name: "get_weather".to_owned(),
                input: serde_json::json!({ "city": "Tokyo" }),
            }],
            stop_reason: Some("tool_use".to_owned()),
            usage: ResponseUsage {
                input_tokens: 50,
                output_tokens: 12,
            },
        };
        let response = to_router_response(
            &sample_request(false),
            "claude-cloud",
            "claude-sonnet-5",
            parsed,
        );
        assert_eq!(response.stop_reason, StopReason::ToolCall);
        assert_eq!(response.tool_calls[0].name, "get_weather");
        assert_eq!(
            response.tool_calls[0].input,
            serde_json::json!({ "city": "Tokyo" })
        );
    }

    #[test]
    fn refusal_stop_reason_maps_to_refused() {
        let parsed = MessagesResponse {
            content: vec![ResponseContentBlock::Text {
                text: "I can't help with that request.".to_owned(),
            }],
            stop_reason: Some("refusal".to_owned()),
            usage: ResponseUsage {
                input_tokens: 20,
                output_tokens: 8,
            },
        };
        let response = to_router_response(
            &sample_request(false),
            "claude-cloud",
            "claude-sonnet-5",
            parsed,
        );
        assert_eq!(response.stop_reason, StopReason::Refused);
    }

    #[test]
    fn context_window_exceeded_maps_to_max_tokens() {
        assert_eq!(
            map_stop_reason(Some("model_context_window_exceeded"), false),
            StopReason::MaxTokens
        );
        assert_eq!(
            map_stop_reason(Some("max_tokens"), false),
            StopReason::MaxTokens
        );
        assert_eq!(map_stop_reason(Some("end_turn"), false), StopReason::End);
        assert_eq!(
            map_stop_reason(Some("stop_sequence"), false),
            StopReason::End
        );
        assert_eq!(
            map_stop_reason(Some("end_turn"), true),
            StopReason::ToolCall,
            "a tool_use content block present always wins over the reported stop_reason"
        );
    }

    #[test]
    fn missing_credential_is_rejected_before_any_network_call() {
        let adapter = ClaudeAdapter::new("claude-cloud", "claude-sonnet-5", Duration::from_secs(5));
        let err = adapter
            .invoke(&sample_request(false), None)
            .expect_err("Claude requires a credential, unlike the local Ollama adapter");
        assert_eq!(err, ProviderError::Unreachable);
    }
}
