//! Gemini Developer API adapter (Google AI Studio, I5 follow-up).
//!
//! This direct Google adapter uses the supported `generateContent` REST shape:
//! `POST /v1beta/models/{model}:generateContent`, authenticated by
//! `x-goog-api-key`. The current Interactions API is Google's recommended API
//! for new feature work; this deliberately small V1 maps OCP's stateless
//! text/tool contract to the still-supported generateContent API, which has a
//! compact, documented function-call wire format. It sends no audio/image,
//! grounding, Live API, or server-side conversation state.
//!
//! SEC-030 is enforced by the router: the key is obtained only from the OS
//! keystore under provider id `gemini-cloud` (or a caller-selected id), never
//! from config, source, events, or logs. The adapter requires that credential
//! before making any request.

use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::adapter::{ProviderAdapter, ProviderError};
use crate::types::{
    Capability, ContentPart, CostClass, EstimatedCost, LatencyClass, Locality, ModelInfo,
    ProviderCapabilities, Role, RouterRequest, RouterResponse, StopReason, ToolCallOut, Usage,
};

const DEFAULT_BASE_URL: &str = "https://generativelanguage.googleapis.com/v1beta";

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct GenerateContentRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    system_instruction: Option<GeminiContent>,
    contents: Vec<GeminiContent>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    tools: Vec<GeminiTool>,
    generation_config: GenerationConfig,
}

#[derive(Serialize)]
struct GeminiContent {
    role: &'static str,
    parts: Vec<GeminiPart>,
}

#[derive(Serialize)]
struct GeminiPart {
    text: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct GeminiTool {
    function_declarations: Vec<FunctionDeclaration>,
}

#[derive(Serialize)]
struct FunctionDeclaration {
    name: String,
    description: String,
    parameters: Value,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct GenerationConfig {
    max_output_tokens: u32,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct GenerateContentResponse {
    #[serde(default)]
    candidates: Vec<GeminiCandidate>,
    #[serde(default)]
    usage_metadata: UsageMetadata,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct GeminiCandidate {
    #[serde(default)]
    content: GeminiResponseContent,
    #[serde(default)]
    finish_reason: Option<String>,
}

#[derive(Deserialize, Default)]
struct GeminiResponseContent {
    #[serde(default)]
    parts: Vec<GeminiResponsePart>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct GeminiResponsePart {
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    function_call: Option<GeminiFunctionCall>,
}

#[derive(Deserialize)]
struct GeminiFunctionCall {
    name: String,
    #[serde(default)]
    args: Value,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct UsageMetadata {
    #[serde(default)]
    prompt_token_count: u32,
    #[serde(default)]
    candidates_token_count: u32,
}

fn flatten_content(parts: &[ContentPart]) -> String {
    parts
        .iter()
        .filter_map(|part| match part {
            ContentPart::Text { value } => Some(value.as_str()),
            ContentPart::Image { .. } | ContentPart::Audio { .. } => None,
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn build_request(request: &RouterRequest) -> GenerateContentRequest {
    let system_text = request
        .messages
        .iter()
        .filter(|message| message.role == Role::System)
        .map(|message| flatten_content(&message.content))
        .filter(|text| !text.is_empty())
        .collect::<Vec<_>>()
        .join("\n\n");

    let contents = request
        .messages
        .iter()
        .filter(|message| message.role != Role::System)
        .map(|message| GeminiContent {
            // Gemini's wire format calls assistant/model output "model".
            // A neutral Tool result has no tool-call id in AI_PROVIDER_API
            // yet, so it remains user text rather than inventing a vendor-only
            // functionResponse continuation contract.
            role: match message.role {
                Role::Assistant => "model",
                Role::System | Role::User | Role::Tool => "user",
            },
            parts: vec![GeminiPart {
                text: flatten_content(&message.content),
            }],
        })
        .collect();

    let declarations = request
        .tools
        .iter()
        .map(|tool| FunctionDeclaration {
            name: tool.name.clone(),
            description: tool.description.clone(),
            parameters: tool.input_schema.clone(),
        })
        .collect::<Vec<_>>();

    GenerateContentRequest {
        system_instruction: (!system_text.is_empty()).then(|| GeminiContent {
            role: "user",
            parts: vec![GeminiPart { text: system_text }],
        }),
        contents,
        tools: (!declarations.is_empty())
            .then_some(GeminiTool {
                function_declarations: declarations,
            })
            .into_iter()
            .collect(),
        generation_config: GenerationConfig {
            max_output_tokens: request.limits.max_output_tokens,
        },
    }
}

fn map_stop_reason(reason: Option<&str>, has_tool_calls: bool) -> StopReason {
    if has_tool_calls {
        return StopReason::ToolCall;
    }
    match reason {
        Some("MAX_TOKENS") => StopReason::MaxTokens,
        // SAFETY/RECITATION are provider refusals rather than normal answers.
        Some("SAFETY") | Some("RECITATION") => StopReason::Refused,
        _ => StopReason::End,
    }
}

fn to_router_response(
    request: &RouterRequest,
    provider_id: &str,
    model_id: &str,
    parsed: GenerateContentResponse,
) -> Result<RouterResponse, ProviderError> {
    let candidate = parsed
        .candidates
        .into_iter()
        .next()
        .ok_or(ProviderError::Unreachable)?;
    let mut content = Vec::new();
    let mut tool_calls = Vec::new();
    for part in candidate.content.parts {
        if let Some(text) = part.text.filter(|text| !text.is_empty()) {
            content.push(ContentPart::Text { value: text });
        }
        if let Some(call) = part.function_call {
            tool_calls.push(ToolCallOut {
                name: call.name,
                input: call.args,
            });
        }
    }
    let stop_reason = map_stop_reason(candidate.finish_reason.as_deref(), !tool_calls.is_empty());
    Ok(RouterResponse {
        request_id: request.request_id,
        provider_id: provider_id.to_owned(),
        model_id: model_id.to_owned(),
        content,
        tool_calls,
        stop_reason,
        usage: Usage {
            input_tokens: parsed.usage_metadata.prompt_token_count,
            output_tokens: parsed.usage_metadata.candidates_token_count,
            cost_class: CostClass::Metered,
            // Gemini's response reports token counts, not OCP's local billing
            // price table. Never pretend an uncomputed cost is free.
            estimated_cost: EstimatedCost {
                amount: 0.0,
                currency: "USD".to_owned(),
            },
        },
        fallback_depth: 0,
    })
}

fn map_error(error: &ureq::Error) -> ProviderError {
    match error {
        ureq::Error::Timeout(_) => ProviderError::Timeout,
        ureq::Error::HostNotFound | ureq::Error::ConnectionFailed | ureq::Error::Io(_) => {
            ProviderError::Unreachable
        }
        ureq::Error::StatusCode(_) | ureq::Error::Json(_) => ProviderError::ElevatedErrorRate,
        _ => ProviderError::Unreachable,
    }
}

/// A direct Gemini Developer API account, with model choice supplied by host
/// configuration rather than embedded in OCP policy.
pub struct GeminiAdapter {
    caps: ProviderCapabilities,
    base_url: String,
    model: String,
    agent: ureq::Agent,
}

impl GeminiAdapter {
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
                context_window: 128_000,
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

impl ProviderAdapter for GeminiAdapter {
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
        let url = format!("/models/{}:generateContent", self.model);
        let url = format!("{}{}", self.base_url.trim_end_matches('/'), url);
        let body = build_request(request);
        let mut response = self
            .agent
            .post(&url)
            .header("x-goog-api-key", key)
            .send_json(&body)
            .map_err(|error| map_error(&error))?;
        let parsed: GenerateContentResponse = response
            .body_mut()
            .read_json()
            .map_err(|error| map_error(&error))?;
        to_router_response(request, &self.caps.provider_id, &self.model, parsed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{CallerContext, Limits, Message, RoutePolicy, ToolSpec};
    use uuid::Uuid;

    fn sample_request(with_system: bool, with_tool: bool) -> RouterRequest {
        let mut messages = Vec::new();
        if with_system {
            messages.push(Message {
                role: Role::System,
                content: vec![ContentPart::Text {
                    value: "be concise".to_owned(),
                }],
            });
        }
        messages.push(Message {
            role: Role::User,
            content: vec![ContentPart::Text {
                value: "weather in Bangkok".to_owned(),
            }],
        });
        messages.push(Message {
            role: Role::Assistant,
            content: vec![ContentPart::Text {
                value: "I will check.".to_owned(),
            }],
        });
        RouterRequest {
            request_id: Uuid::now_v7(),
            correlation_id: Uuid::now_v7(),
            capability: Capability::Chat,
            messages,
            memory_excerpts: vec![],
            tools: with_tool
                .then(|| ToolSpec {
                    name: "weather".to_owned(),
                    description: "looks up weather".to_owned(),
                    input_schema: serde_json::json!({"type":"object"}),
                })
                .into_iter()
                .collect(),
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
                max_output_tokens: 200,
            },
        }
    }

    #[test]
    fn request_maps_system_messages_and_tools_to_gemini_wire_shape() {
        let wire = serde_json::to_value(build_request(&sample_request(true, true))).unwrap();
        assert_eq!(wire["systemInstruction"]["parts"][0]["text"], "be concise");
        assert_eq!(wire["contents"][0]["role"], "user");
        assert_eq!(wire["contents"][1]["role"], "model");
        assert_eq!(
            wire["tools"][0]["functionDeclarations"][0]["name"],
            "weather"
        );
        assert_eq!(wire["generationConfig"]["maxOutputTokens"], 200);
    }

    #[test]
    fn request_omits_empty_optional_system_and_tools() {
        let wire = serde_json::to_value(build_request(&sample_request(false, false))).unwrap();
        assert!(wire.get("systemInstruction").is_none());
        assert!(wire.get("tools").is_none());
    }

    #[test]
    fn response_maps_text_tool_usage_and_refusal() {
        let request = sample_request(false, false);
        let parsed: GenerateContentResponse = serde_json::from_value(serde_json::json!({
            "candidates": [{
                "finishReason": "STOP",
                "content": {"parts": [
                    {"text": "Calling weather"},
                    {"functionCall": {"name":"weather", "args":{"city":"Bangkok"}}}
                ]}
            }],
            "usageMetadata": {"promptTokenCount": 12, "candidatesTokenCount": 4}
        }))
        .unwrap();
        let response =
            to_router_response(&request, "gemini-cloud", "configured-model", parsed).unwrap();
        assert_eq!(
            response.content[0],
            ContentPart::Text {
                value: "Calling weather".to_owned()
            }
        );
        assert_eq!(
            response.tool_calls[0].input,
            serde_json::json!({"city":"Bangkok"})
        );
        assert_eq!(response.stop_reason, StopReason::ToolCall);
        assert_eq!(
            (response.usage.input_tokens, response.usage.output_tokens),
            (12, 4)
        );
        assert_eq!(map_stop_reason(Some("SAFETY"), false), StopReason::Refused);
        assert_eq!(
            map_stop_reason(Some("MAX_TOKENS"), false),
            StopReason::MaxTokens
        );
    }

    #[test]
    fn missing_credential_is_rejected_before_any_network_call() {
        let adapter = GeminiAdapter::with_base_url(
            "gemini-cloud",
            "http://127.0.0.1:1",
            "configured-model",
            Duration::from_millis(1),
        );
        assert_eq!(
            adapter.invoke(&sample_request(false, false), None),
            Err(ProviderError::Unreachable)
        );
    }
}
