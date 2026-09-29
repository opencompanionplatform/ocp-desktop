//! The AI Router core (AI_PROVIDER_API §4–§5, AI_ROUTER.md): provider
//! registry, ordered fallback chains per route (route = capability + cost
//! class per §4), the provider health FSM, the SEC-035 cloud-consent gate,
//! and SEC-033 confused-deputy tool-call mediation. Every routing decision
//! is logged and, where the contract calls for it, emitted as an event with
//! `correlationId` (NFR-004, "no silent changes").

use std::collections::HashMap;

use ocp_event_bus::InProcessBus;
use ocp_shared_types::Envelope;
use serde_json::json;
use uuid::Uuid;

use crate::adapter::{ProviderAdapter, ProviderError};
use crate::consent::ConsentStore;
use crate::credentials::CredentialStore;
use crate::health::ProviderHealth;
use crate::types::{CallerContext, Capability, CostClass, Locality, RouterRequest, RouterResponse};

/// Envelope `source` for everything this crate emits.
pub const SOURCE: &str = "ai-router";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RouterError {
    /// No fallback chain was registered for this (capability, cost class) route.
    NoRouteConfigured(Capability, CostClass),
    /// Every provider in the chain is `Failed` (or none are registered) —
    /// containment, not a core crash (mirrors SEC-004's spirit for the AI
    /// Routing context: an outage here degrades the companion, it never
    /// takes down the kernel).
    AllProvidersUnavailable,
}

impl core::fmt::Display for RouterError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::NoRouteConfigured(cap, cost) => {
                write!(f, "no fallback chain configured for route {cap:?}/{cost:?}")
            }
            Self::AllProvidersUnavailable => {
                write!(
                    f,
                    "every provider in the chain is Failed; request could not be routed"
                )
            }
        }
    }
}

impl std::error::Error for RouterError {}

struct ProviderEntry {
    adapter: Box<dyn ProviderAdapter>,
    health: ProviderHealth,
}

/// The AI Router. Owns the provider registry, fallback chains, health
/// state, and the consent/credential seams (real backing stores are a
/// later slice — see `consent.rs`/`credentials.rs` module docs).
pub struct Router {
    bus: InProcessBus,
    consent: Box<dyn ConsentStore>,
    credentials: Box<dyn CredentialStore>,
    providers: HashMap<String, ProviderEntry>,
    /// Ordered fallback chain per route (§4: "route = capability + policy class").
    chains: HashMap<(Capability, CostClass), Vec<String>>,
    /// The provider that most recently served each route, so a change can
    /// be recognized as a swap (`provider-swapped`, "no silent changes").
    active_provider: HashMap<(Capability, CostClass), String>,
    audit: Vec<String>,
}

impl Router {
    #[must_use]
    pub fn new(
        bus: InProcessBus,
        consent: Box<dyn ConsentStore>,
        credentials: Box<dyn CredentialStore>,
    ) -> Self {
        Self {
            bus,
            consent,
            credentials,
            providers: HashMap::new(),
            chains: HashMap::new(),
            active_provider: HashMap::new(),
            audit: Vec::new(),
        }
    }

    /// Register a provider, `Available` by default. Re-registering the same
    /// `providerId` replaces the adapter but keeps no history — callers that
    /// need a clean health reset should just construct a new `Router`.
    pub fn register_provider(&mut self, adapter: Box<dyn ProviderAdapter>) {
        let id = adapter.capabilities().provider_id.clone();
        self.providers.insert(
            id,
            ProviderEntry {
                adapter,
                health: ProviderHealth::Available,
            },
        );
    }

    /// Set the ordered fallback chain for one route. Every id must already
    /// (or later) be registered via `register_provider` — an unregistered id
    /// referenced at route time is a programmer error (`expect`, not a
    /// recoverable `RouterError`), since chain configuration is host-side
    /// setup, never user/network input.
    pub fn register_chain(
        &mut self,
        capability: Capability,
        cost_class: CostClass,
        provider_ids: &[&str],
    ) {
        self.chains.insert(
            (capability, cost_class),
            provider_ids.iter().map(|s| (*s).to_owned()).collect(),
        );
    }

    #[must_use]
    pub fn health(&self, provider_id: &str) -> Option<ProviderHealth> {
        self.providers.get(provider_id).map(|e| e.health)
    }

    /// Human-readable trace of every routing/health/tool decision this
    /// router has made — the "every routing decision is explainable"
    /// AI_ROUTER.md rule, in a form a developer can inspect directly
    /// (structured events cover the machine-readable half).
    #[must_use]
    pub fn audit_log(&self) -> &[String] {
        &self.audit
    }

    /// Route one request through its fallback chain (AI_PROVIDER_API §4).
    ///
    /// For each provider in order: skip it if `Failed` (§4: "Failed removes
    /// the provider until health checks pass" — the only removal language
    /// in the contract, see `health.rs`); skip it too if it's `Cloud` and
    /// `policy.allowCloud` is `false` (a blanket per-request opt-out,
    /// independent of and stronger than the consent gate below); otherwise,
    /// if it's `Cloud` and the request still carries a `sensitive` memory excerpt without that provider's
    /// consent, strip the sensitive excerpts before this call (SEC-035) —
    /// once stripped, they stay stripped for every subsequent hop in this
    /// same call too, so a denied cloud provider can never cause the
    /// content to reach a *different* cloud provider intact ("never
    /// silently falls back up... with the sensitive excerpts included").
    /// Read the credential at call time (SEC-030) and hand it to the
    /// adapter; on success, note any provider swap, gate tool calls
    /// (SEC-033), and return; on failure, record the health transition and
    /// continue down the chain.
    pub fn route(&mut self, request: &RouterRequest) -> Result<RouterResponse, RouterError> {
        let key = (request.capability, request.policy.max_cost_class);
        let chain = self
            .chains
            .get(&key)
            .cloned()
            .ok_or(RouterError::NoRouteConfigured(
                request.capability,
                request.policy.max_cost_class,
            ))?;

        let mut working = request.clone();
        let mut fallback_depth = 0u32;
        let correlation = Some(request.correlation_id);

        for (idx, provider_id) in chain.iter().enumerate() {
            let health = self
                .providers
                .get(provider_id)
                .map(|e| e.health)
                .unwrap_or(ProviderHealth::Failed);
            if !health.is_tryable() {
                fallback_depth += 1;
                continue;
            }

            let locality = self
                .providers
                .get(provider_id)
                .expect("chain references a registered provider")
                .adapter
                .capabilities()
                .locality;
            if locality == Locality::Cloud {
                // §2's `policy.allowCloud` is a blanket per-request opt-out of
                // cloud entirely -- stronger than, and independent of, the
                // SEC-035 consent gate below (which only concerns *sensitive*
                // excerpts). A request with `allowCloud: false` must never
                // reach a cloud provider at all, sensitive content or not.
                if !request.policy.allow_cloud {
                    self.audit.push(format!(
                        "POLICY {provider_id}: skipped, request set allowCloud=false"
                    ));
                    fallback_depth += 1;
                    continue;
                }
                let has_sensitive = working.memory_excerpts.iter().any(|e| e.sensitive);
                if has_sensitive && !self.consent.has_consent(provider_id) {
                    working.memory_excerpts.retain(|e| !e.sensitive);
                    self.audit.push(format!(
                        "CONSENT-GATE {provider_id}: sensitive excerpts dropped before transmission (SEC-035)"
                    ));
                }
            }

            let credential = self.credentials.get(provider_id);
            let outcome = self
                .providers
                .get(provider_id)
                .expect("chain references a registered provider")
                .adapter
                .invoke(&working, credential.as_deref());

            match outcome {
                Ok(mut response) => {
                    response.fallback_depth = fallback_depth;
                    self.note_active_and_maybe_swap(
                        key,
                        provider_id,
                        request.request_id,
                        correlation,
                    );
                    self.filter_tool_calls(&request.caller_context, &mut response, correlation);
                    return Ok(response);
                }
                Err(err) => {
                    let next_hint = chain.get(idx + 1).cloned();
                    self.record_failure(provider_id, err, next_hint, correlation);
                    fallback_depth += 1;
                }
            }
        }
        Err(RouterError::AllProvidersUnavailable)
    }

    /// Explicit recovery probe (STATE_MACHINE.md: `Failed -> Available`
    /// only happens this way, never silently on the next successful call —
    /// a caller/health-checker outside this crate decides when to probe).
    pub fn recover(&mut self, provider_id: &str, probe_latency_ms: u32, correlation: Option<Uuid>) {
        let Some(entry) = self.providers.get_mut(provider_id) else {
            return;
        };
        if !entry.health.can_transition_to(ProviderHealth::Available) {
            return;
        }
        entry.health = ProviderHealth::Available;
        self.audit.push(format!(
            "PROVIDER {provider_id}: recovered via probe ({probe_latency_ms}ms)"
        ));
        self.emit(
            "ocp.ai-routing.provider-recovered",
            json!({ "providerId": provider_id, "probeLatencyMs": probe_latency_ms }),
            correlation,
        );
    }

    fn note_active_and_maybe_swap(
        &mut self,
        key: (Capability, CostClass),
        provider_id: &str,
        request_id: Uuid,
        correlation: Option<Uuid>,
    ) {
        let previous = self.active_provider.get(&key).cloned();
        if previous.as_deref() != Some(provider_id) {
            if let Some(from) = previous {
                // A swap away from a still-nameable previous provider. This
                // slice's router only ever changes the active provider via
                // fallback (chain-walk after a failure) or a `recover` call
                // making the original choice reachable again — "policy"/
                // "manual" reasons are reserved for a persona-preference or
                // explicit-override API this slice doesn't add yet.
                let reason = if self
                    .providers
                    .get(&from)
                    .is_some_and(|e| e.health == ProviderHealth::Available)
                {
                    "recovery"
                } else {
                    "fallback"
                };
                self.emit(
                    "ocp.ai-routing.provider-swapped",
                    json!({ "from": from, "to": provider_id, "reason": reason, "requestId": request_id }),
                    correlation,
                );
            }
            self.active_provider.insert(key, provider_id.to_owned());
        }
    }

    fn record_failure(
        &mut self,
        provider_id: &str,
        err: ProviderError,
        next_hint: Option<String>,
        correlation: Option<Uuid>,
    ) {
        let Some(entry) = self.providers.get_mut(provider_id) else {
            return;
        };
        let current = entry.health;
        let target = match err {
            ProviderError::Unreachable
            | ProviderError::AuthFailed
            | ProviderError::QuotaExceeded => ProviderHealth::Failed,
            ProviderError::Timeout
            | ProviderError::ElevatedErrorRate
            | ProviderError::RateLimited => {
                if current == ProviderHealth::Available {
                    ProviderHealth::Degraded
                } else {
                    ProviderHealth::Failed
                }
            }
        };
        if !current.can_transition_to(target) {
            return; // already at/worse than target -- no duplicate transition/event
        }
        entry.health = target;
        self.audit.push(format!(
            "PROVIDER {provider_id}: {current:?} -> {target:?} ({err:?})"
        ));
        match target {
            ProviderHealth::Degraded => {
                let reason = match err {
                    ProviderError::Timeout => "timeout",
                    ProviderError::ElevatedErrorRate => "error-rate",
                    ProviderError::RateLimited => "rate-limit",
                    ProviderError::Unreachable
                    | ProviderError::AuthFailed
                    | ProviderError::QuotaExceeded => {
                        unreachable!("hard provider failures always target Failed")
                    }
                };
                self.emit(
                    "ocp.ai-routing.provider-degraded",
                    json!({ "providerId": provider_id, "reason": reason, "detail": format!("{err:?}") }),
                    correlation,
                );
            }
            ProviderHealth::Failed => {
                self.emit(
                    "ocp.ai-routing.provider-failed",
                    json!({ "providerId": provider_id, "reason": format!("{err:?}"), "fallbackProviderId": next_hint }),
                    correlation,
                );
            }
            ProviderHealth::Available => unreachable!("record_failure never targets Available"),
        }
    }

    /// SEC-033 confused-deputy gate: a `toolCalls` entry only survives if
    /// the *calling context* (never the model's own claim) was granted that
    /// capability. Denials are stripped, logged, and reported via
    /// `tool-call-denied` — never silently dropped.
    fn filter_tool_calls(
        &mut self,
        ctx: &CallerContext,
        response: &mut RouterResponse,
        correlation: Option<Uuid>,
    ) {
        let granted: std::collections::HashSet<&str> = ctx
            .granted_capabilities
            .iter()
            .map(String::as_str)
            .collect();
        let (allowed, denied): (Vec<_>, Vec<_>) = response
            .tool_calls
            .drain(..)
            .partition(|tc| granted.contains(tc.name.as_str()));
        response.tool_calls = allowed;
        for tc in denied {
            self.audit.push(format!(
                "TOOL-DENY {}: {} exceeds granted capabilities (SEC-033 confused-deputy)",
                ctx.context_id, tc.name
            ));
            self.emit(
                "ocp.ai-routing.tool-call-denied",
                json!({ "callId": Uuid::now_v7(), "reason": "out-of-scope" }),
                correlation,
            );
        }
    }

    fn emit(&mut self, event_type: &str, data: serde_json::Value, correlation: Option<Uuid>) {
        match Envelope::new(event_type, SOURCE, data) {
            Ok(env) => {
                let env = match correlation {
                    Some(c) => env.with_correlation(c),
                    None => env,
                };
                if let Err(e) = self.bus.publish(env) {
                    self.audit.push(format!("EMIT-FAILED {event_type}: {e}"));
                }
            }
            Err(e) => self.audit.push(format!("BUILD-FAILED {event_type}: {e}")),
        }
    }
}
