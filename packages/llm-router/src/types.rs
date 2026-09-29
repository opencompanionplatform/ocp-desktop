//! Provider-neutral contract types — AI_PROVIDER_API §1–§3. Provider wire
//! formats never leak inward (anti-corruption layer, AI_ROUTER.md); every
//! `ProviderAdapter` translates its own vendor shape to/from these types at
//! the boundary, so the router core never sees anything vendor-specific.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// AI_PROVIDER_API §1 `capabilities` entries.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum Capability {
    Chat,
    Embedding,
    Stt,
    Tts,
    Vision,
}

/// Drives the SEC-035 consent gate: it applies only to `Cloud` (§1).
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum Locality {
    Local,
    Cloud,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum LatencyClass {
    Interactive,
    Batch,
}

/// Also doubles as a route's policy class (§4: "route = capability + policy
/// class"); `RoutePolicy::max_cost_class` is matched against this.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum CostClass {
    Free,
    Metered,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ModelInfo {
    pub model_id: String,
    pub capabilities: Vec<Capability>,
    pub streaming: bool,
}

/// AI_PROVIDER_API §1 provider capability declaration.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ProviderCapabilities {
    pub provider_id: String,
    pub locality: Locality,
    pub capabilities: Vec<Capability>,
    pub streaming: bool,
    pub context_window: u32,
    pub latency_class: LatencyClass,
    pub cost_class: CostClass,
    #[serde(default)]
    pub models: Vec<ModelInfo>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    System,
    User,
    Assistant,
    Tool,
}

/// One content part of a message. Kept a closed enum (not a raw string) so a
/// vendor adapter cannot slip an untyped blob past the neutral shape.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase", tag = "type")]
pub enum ContentPart {
    Text { value: String },
    Image { value: String },
    Audio { value: String },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Message {
    pub role: Role,
    pub content: Vec<ContentPart>,
}

/// MEMORY_API recall excerpt (§2): excerpt-only, never raw store access
/// (SEC-024). `sensitive` drives the SEC-035 cloud-consent gate.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MemoryExcerpt {
    pub record_id: Uuid,
    pub scope: String,
    pub excerpt: String,
    pub sensitive: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ToolSpec {
    pub name: String,
    pub description: String,
    pub input_schema: serde_json::Value,
}

/// Identifies which context this request is on behalf of, and what it may
/// actually do — the confused-deputy check (SEC-033) is keyed on this, never
/// on anything the model claims about itself.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CallerContext {
    pub context_id: String,
    pub granted_capabilities: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RoutePolicy {
    pub max_cost_class: CostClass,
    pub allow_cloud: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Limits {
    pub max_output_tokens: u32,
}

fn default_foreground() -> bool {
    true
}

/// AI_PROVIDER_API §2 request shape (§7.4 adds the optional `foreground`
/// field — the only §2 change turn-scheduling makes).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RouterRequest {
    pub request_id: Uuid,
    /// Mandatory: every routing decision must be traceable to the causing
    /// user turn or event (EVENT_API, AI_ROUTER.md rule, NFR-004).
    pub correlation_id: Uuid,
    pub capability: Capability,
    pub messages: Vec<Message>,
    #[serde(default)]
    pub memory_excerpts: Vec<MemoryExcerpt>,
    #[serde(default)]
    pub tools: Vec<ToolSpec>,
    pub caller_context: CallerContext,
    pub policy: RoutePolicy,
    #[serde(default)]
    pub streaming: bool,
    /// §7.3: only foreground (user-facing) completions serialize through the
    /// current-speaker gate; `false` marks background work (summarization,
    /// embeddings) that may run concurrently. Defaults to `true` — the §7
    /// gate never engages for single-companion deployments.
    #[serde(default = "default_foreground")]
    pub foreground: bool,
    pub limits: Limits,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum StopReason {
    End,
    ToolCall,
    MaxTokens,
    Refused,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ToolCallOut {
    pub name: String,
    pub input: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EstimatedCost {
    pub amount: f64,
    pub currency: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Usage {
    pub input_tokens: u32,
    pub output_tokens: u32,
    pub cost_class: CostClass,
    pub estimated_cost: EstimatedCost,
}

/// AI_PROVIDER_API §3 response shape.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RouterResponse {
    pub request_id: Uuid,
    pub provider_id: String,
    pub model_id: String,
    pub content: Vec<ContentPart>,
    /// Gated on return by the router (SEC-033) — see `router::filter_tool_calls`.
    #[serde(default)]
    pub tool_calls: Vec<ToolCallOut>,
    pub stop_reason: StopReason,
    pub usage: Usage,
    /// How far down the fallback chain this response came from (§3, §4).
    pub fallback_depth: u32,
}
