//! OpenAI (GPT) adapter (I5 slice 5) — a third real cloud provider, and the
//! first built against the **Responses API** (`POST /v1/responses`) rather
//! than the older Chat Completions shape the OpenRouter adapter uses.
//!
//! This was a deliberate choice, made with the Chief AI Architect: OpenAI's
//! own docs steer new integrations toward Responses ("Starting a new
//! project? We recommend trying Responses..."), and Chat Completions
//! remains supported but is explicitly the legacy path going forward.
//!
//! Verified directly against OpenAI's own developer docs before writing any
//! code — the migration guide
//! (`developers.openai.com/api/docs/guides/migrate-to-responses`), the
//! function-calling guide
//! (`developers.openai.com/api/docs/guides/function-calling`), and the
//! `responses.create` reference page all rendered as real, readable content
//! this session (unlike the Claude docs page last slice, which needed a
//! secondary source) — so this adapter is verified against OpenAI's primary
//! docs directly, not cross-checked through a mirror.
//!
//! Confirmed request/response shape: `POST https://api.openai.com/v1/responses`,
//! `Authorization: Bearer <key>` (same auth style as OpenRouter); request
//! `{model, instructions, input, tools, max_output_tokens, stream}`; response
//! `{id, object:"response", output:[Item], usage:{input_tokens,output_tokens}}`
//! where `output` is an array of typed Items (`reasoning`, `message`,
//! `function_call`, ...) rather than Chat Completions' `choices[].message`.
//!
//! Real wire-format differences from the other three adapters, all
//! confirmed via the docs above rather than assumed by analogy:
//! - **`system` becomes a top-level `instructions` string**, like Claude's
//!   top-level `system` field (not sent as a message) — but unlike Claude,
//!   OpenAI's own migration guide notes messages are still accepted as
//!   compatible input, so this adapter takes the same approach as
//!   `ClaudeAdapter`: extract `Role::System` content into `instructions`
//!   rather than sending a `system`-role input Item, since that's the
//!   documented idiomatic shape for Responses.
//! - **Tool definitions are internally tagged**: `{type:"function", name,
//!   description, parameters}` — no nested `function: {...}` wrapper object
//!   like Chat Completions/OpenRouter use. Sending the externally-tagged
//!   shape here would silently produce a malformed tool definition.
//! - **`function_call` is a distinct output Item**, not an array hung off a
//!   message: `{type:"function_call", call_id, name, arguments}`, found by
//!   scanning `output` for `type == "function_call"` rather than reading a
//!   `tool_calls` field. `arguments` is a JSON-encoded **string**, the same
//!   as OpenRouter (and unlike Ollama/Claude's plain JSON object) — the one
//!   real gotcha here, caught the same way OpenRouter's was: checked before
//!   coding rather than assumed from the object-shaped adapters already
//!   written this slice.
//! - **No `finish_reason`.** Responses has no per-choice finish reason at
//!   all; the closest equivalent is each output Item's own `status` field
//!   (`"in_progress" | "completed" | "incomplete"`, confirmed in the
//!   reference schema). This adapter maps a `message` Item's `status ==
//!   "incomplete"` to `StopReason::MaxTokens`, and any `function_call`
//!   Item's presence to `StopReason::ToolCall` (same precedence rule as
//!   every other adapter this slice — a tool call always wins).
//!
//! **Documented simplification, flagged rather than silently assumed**
//! (same practice as the Provider Health FSM addition and I3's
//! `CompanionState` additions): unlike OpenRouter's `content_filter`/`error`
//! `finish_reason` values, this session's direct fetch of OpenAI's own docs
//! did not surface an equivalent top-level refusal/moderation signal on the
//! Responses object (no `incomplete_details.reason` or response-level
//! `error` field appeared in the rendered reference content this session
//! could retrieve). `StopReason::Refused` is therefore never produced by
//! this adapter for now — a real gap relative to OpenRouter's coverage, not
//! a claim that OpenAI has no such signal. If/when this is confirmed
//! (e.g. via a live call that actually surfaces one), this mapping should
//! be revisited rather than guessed at now.
//!
//! Deliberately out of scope, same as the other three adapters:
//! multi-turn tool-result continuation (`function_call_output` input Items,
//! keyed on `call_id`), `previous_response_id`-based conversation chaining,
//! streaming, and image/audio content parts.

use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::adapter::{ProviderAdapter, ProviderError};
use crate::types::{
    Capability, ContentPart, CostClass, EstimatedCost, LatencyClass, Locality, ModelInfo,
    ProviderCapabilities, Role, RouterRequest, RouterResponse, StopReason, ToolCallOut, Usage,
};

const DEFAULT_BASE_URL: &str = "https://api.openai.com/v1";

#[derive(Serialize)]
struct ResponsesRequest<'a> {
    model: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    instructions: Option<String>,
    input: Vec<InputItem>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    tools: Vec<RequestTool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    max_output_tokens: Option<u32>,
    stream: bool,
}

#[derive(Serialize)]
struct InputItem {
    role: &'static str,
    content: String,
}

/// Internally tagged, unlike Chat Completions/OpenRouter's `{type:"function",
/// function:{...}}` wrapper — see module doc.
#[derive(Serialize)]
struct RequestTool {
    #[serde(rename = "type")]
    kind: &'static str,
    name: String,
    description: String,
    parameters: Value,
}

#[derive(Deserialize)]
struct ResponsesResponse {
    #[serde(default)]
    output: Vec<OutputItem>,
    #[serde(default)]
    usage: Option<ResponsesUsage>,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum OutputItem {
    Message {
        #[serde(default)]
        status: Option<String>,
        #[serde(default)]
        content: Vec<MessageContentPart>,
    },
    FunctionCall {
        /// Not read yet: correlating a tool result back via `call_id` is
        /// part of multi-turn `function_call_output` continuation, which is
        /// out of scope this slice (see module doc). Kept on the DTO now
        /// rather than dropped, since deserialization needs the field to
        /// exist and dropping it would just mean re-adding it later.
        #[allow(dead_code)]
        call_id: String,
        name: String,
        arguments: String,
    },
    #[serde(other)]
    Other,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum MessageContentPart {
    OutputText {
        text: String,
    },
    #[serde(other)]
    Other,
}

#[derive(Deserialize)]
struct ResponsesUsage {
    #[serde(default)]
    input_tokens: u32,
    #[serde(default)]
    output_tokens: u32,
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

fn role_str(role: Role) -> &'static str {
    match role {
        Role::Assistant => "assistant",
        // Responses' `input` array only accepts user/assistant/developer
        // roles for message Items; System is extracted into `instructions`
        // before this function ever sees it (see `build_request`), and Tool
        // (multi-turn tool-result feeding) is out of scope this slice, so
        // both conservatively fall back to "user" if one ever reaches here.
        Role::System | Role::User | Role::Tool => "user",
    }
}

/// Parses the JSON-string `arguments` field defensively, same rationale as
/// the OpenRouter adapter: a malformed single tool call shouldn't fail the
/// whole response.
fn parse_tool_arguments(raw: &str) -> Value {
    serde_json::from_str(raw).unwrap_or_else(|_| Value::String(raw.to_owned()))
}

fn build_request<'a>(model: &'a str, request: &RouterRequest) -> ResponsesRequest<'a> {
    let instructions_text = request
        .messages
        .iter()
        .filter(|m| m.role == Role::System)
        .map(|m| flatten_content(&m.content))
        .collect::<Vec<_>>()
        .join("\n\n");
    let input = request
        .messages
        .iter()
        .filter(|m| m.role != Role::System)
        .map(|m| InputItem {
            role: role_str(m.role),
            content: flatten_content(&m.content),
        })
        .collect();
    ResponsesRequest {
        model,
        instructions: if instructions_text.is_empty() {
            None
        } else {
            Some(instructions_text)
        },
        input,
        tools: request
            .tools
            .iter()
            .map(|t| RequestTool {
                kind: "function",
                name: t.name.clone(),
                description: t.description.clone(),
                parameters: t.input_schema.clone(),
            })
            .collect(),
        max_output_tokens: Some(request.limits.max_output_tokens),
        stream: false,
    }
}

fn to_router_response(
    request: &RouterRequest,
    provider_id: &str,
    model_id: &str,
    parsed: ResponsesResponse,
) -> RouterResponse {
    let mut content = Vec::new();
    let mut tool_calls = Vec::new();
    let mut any_incomplete = false;
    for item in parsed.output {
        match item {
            OutputItem::Message {
                status,
                content: parts,
            } => {
                if status.as_deref() == Some("incomplete") {
                    any_incomplete = true;
                }
                for part in parts {
                    if let MessageContentPart::OutputText { text } = part {
                        content.push(ContentPart::Text { value: text });
                    }
                }
            }
            OutputItem::FunctionCall {
                name, arguments, ..
            } => {
                tool_calls.push(ToolCallOut {
                    name,
                    input: parse_tool_arguments(&arguments),
                });
            }
            OutputItem::Other => {}
        }
    }
    let stop_reason = if !tool_calls.is_empty() {
        StopReason::ToolCall
    } else if any_incomplete {
        StopReason::MaxTokens
    } else {
        StopReason::End
    };
    let (input_tokens, output_tokens) = parsed
        .usage
        .map(|u| (u.input_tokens, u.output_tokens))
        .unwrap_or((0, 0));
    RouterResponse {
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
            estimated_cost: EstimatedCost {
                amount: 0.0,
                currency: "USD".to_owned(),
            },
        },
        fallback_depth: 0,
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

/// A real OpenAI account, reached via the Responses API. `base_url` stays
/// configurable, matching every other adapter's pattern.
pub struct OpenAiAdapter {
    caps: ProviderCapabilities,
    base_url: String,
    model: String,
    agent: ureq::Agent,
}

impl OpenAiAdapter {
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
                streaming: false,
                context_window: 128_000, // conservative default; actual value is per-model
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

impl ProviderAdapter for OpenAiAdapter {
    fn capabilities(&self) -> &ProviderCapabilities {
        &self.caps
    }

    fn invoke(
        &self,
        request: &RouterRequest,
        credential: Option<&str>,
    ) -> Result<RouterResponse, ProviderError> {
        let Some(key) = credential else {
            return Err(ProviderError::Unreachable);
        };
        let url = format!("{}/responses", self.base_url.trim_end_matches('/'));
        let body = build_request(&self.model, request);
        let mut response = self
            .agent
            .post(url.as_str())
            .header("Authorization", format!("Bearer {key}").as_str())
            .send_json(&body)
            .map_err(|e| map_error(&e))?;
        let parsed: ResponsesResponse =
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
                    value: "You are terse.".to_owned(),
                }],
            });
        }
        messages.push(Message {
            role: Role::User,
            content: vec![ContentPart::Text {
                value: "what is the meaning of life?".to_owned(),
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
    fn build_request_extracts_system_role_messages_into_top_level_instructions() {
        let req = build_request("gpt-5.6", &sample_request(true));
        assert_eq!(req.instructions.as_deref(), Some("You are terse."));
        assert_eq!(
            req.input.len(),
            1,
            "the system message must not also appear in `input`"
        );
        assert_eq!(req.input[0].role, "user");
    }

    #[test]
    fn build_request_omits_instructions_entirely_when_there_is_no_system_message() {
        let req = build_request("gpt-5.6", &sample_request(false));
        assert!(req.instructions.is_none());
    }

    #[test]
    fn build_request_uses_internally_tagged_tool_shape_with_no_function_wrapper() {
        let mut request = sample_request(false);
        request.tools.push(crate::types::ToolSpec {
            name: "get_weather".to_owned(),
            description: "look up weather".to_owned(),
            input_schema: serde_json::json!({"type": "object"}),
        });
        let req = build_request("gpt-5.6", &request);
        assert_eq!(req.tools.len(), 1);
        assert_eq!(req.tools[0].kind, "function");
        assert_eq!(req.tools[0].name, "get_weather");
    }

    #[test]
    fn function_call_output_items_are_used_directly_not_read_from_a_tool_calls_field() {
        let parsed = ResponsesResponse {
            output: vec![OutputItem::FunctionCall {
                call_id: "call_123".to_owned(),
                name: "get_weather".to_owned(),
                arguments: r#"{"location":"Paris, France"}"#.to_owned(),
            }],
            usage: Some(ResponsesUsage {
                input_tokens: 40,
                output_tokens: 10,
            }),
        };
        let response =
            to_router_response(&sample_request(false), "openai-cloud", "gpt-5.6", parsed);
        assert_eq!(response.stop_reason, StopReason::ToolCall);
        assert_eq!(response.tool_calls.len(), 1);
        assert_eq!(
            response.tool_calls[0].input,
            serde_json::json!({"location": "Paris, France"})
        );
    }

    #[test]
    fn malformed_tool_arguments_fall_back_to_a_string_value() {
        let parsed = ResponsesResponse {
            output: vec![OutputItem::FunctionCall {
                call_id: "call_x".to_owned(),
                name: "broken_tool".to_owned(),
                arguments: "not valid json".to_owned(),
            }],
            usage: None,
        };
        let response =
            to_router_response(&sample_request(false), "openai-cloud", "gpt-5.6", parsed);
        assert_eq!(
            response.tool_calls[0].input,
            serde_json::json!("not valid json")
        );
    }

    #[test]
    fn incomplete_message_status_maps_to_max_tokens() {
        let parsed = ResponsesResponse {
            output: vec![OutputItem::Message {
                status: Some("incomplete".to_owned()),
                content: vec![MessageContentPart::OutputText {
                    text: "cut off".to_owned(),
                }],
            }],
            usage: None,
        };
        let response =
            to_router_response(&sample_request(false), "openai-cloud", "gpt-5.6", parsed);
        assert_eq!(response.stop_reason, StopReason::MaxTokens);
    }

    #[test]
    fn completed_message_status_maps_to_end() {
        let parsed = ResponsesResponse {
            output: vec![OutputItem::Message {
                status: Some("completed".to_owned()),
                content: vec![MessageContentPart::OutputText {
                    text: "42".to_owned(),
                }],
            }],
            usage: None,
        };
        let response =
            to_router_response(&sample_request(false), "openai-cloud", "gpt-5.6", parsed);
        assert_eq!(response.stop_reason, StopReason::End);
        assert_eq!(
            response.content,
            vec![ContentPart::Text {
                value: "42".to_owned()
            }]
        );
    }

    #[test]
    fn a_tool_call_present_always_wins_over_an_incomplete_message_status() {
        let parsed = ResponsesResponse {
            output: vec![
                OutputItem::Message {
                    status: Some("incomplete".to_owned()),
                    content: vec![],
                },
                OutputItem::FunctionCall {
                    call_id: "call_1".to_owned(),
                    name: "tool".to_owned(),
                    arguments: "{}".to_owned(),
                },
            ],
            usage: None,
        };
        let response =
            to_router_response(&sample_request(false), "openai-cloud", "gpt-5.6", parsed);
        assert_eq!(response.stop_reason, StopReason::ToolCall);
    }

    #[test]
    fn missing_credential_is_rejected_before_any_network_call() {
        let adapter = OpenAiAdapter::new("openai-cloud", "gpt-5.6", Duration::from_secs(5));
        let err = adapter
            .invoke(&sample_request(false), None)
            .expect_err("OpenAI requires a credential");
        assert_eq!(err, ProviderError::Unreachable);
    }
}
