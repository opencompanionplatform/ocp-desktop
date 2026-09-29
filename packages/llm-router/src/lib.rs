//! OCP AI Router logic tier.
//!
//! Binding specs: ocp-architecture/06-api/AI_PROVIDER_API.md (Approved,
//! closes RFC-0002), 04-architecture/AI_ROUTER.md, 08-guidelines/
//! SECURITY_STANDARD.md (SEC-030..035), 13-quality/THREAT_MODEL.md (X2).
//!
//! **I5 slice 1**: the router's own logic — provider-neutral contract,
//! ordered fallback chains, provider health FSM, the SEC-035 cloud-consent
//! gate, SEC-033 confused-deputy tool-call mediation, and SEC-032
//! untrusted-content delimitation — proven against two in-process reference
//! adapters (`adapter::LocalEchoAdapter`, `adapter::ScriptedAdapter`).
//!
//! **I5 slice 2**: the first real, non-reference adapter —
//! `providers::ollama::OllamaAdapter`, talking to a real local Ollama
//! server's `/api/chat`.
//!
//! **I5 slice 3**: the first real *cloud* adapter —
//! `providers::openrouter::OpenRouterAdapter`, the first to actually
//! exercise TLS, a mandatory Bearer-token credential (SEC-030), and the
//! SEC-035 consent gate against a genuinely reachable cloud provider.
//!
//! **I5 slice 4**: `providers::claude::ClaudeAdapter` — Claude (Anthropic)
//! reached directly, a second independently-verified cloud wire format.
//!
//! **I5 slice 5**: `providers::openai::OpenAiAdapter` — OpenAI (GPT) direct,
//! via the Responses API rather than Chat Completions, a third cloud
//! provider and the first with a fundamentally different response shape
//! (typed `output` Items instead of `choices[].message`). Now three
//! independently-verified cloud wire formats exist alongside the one real
//! local provider (Ollama) and the two in-process reference adapters.
//!
//! **I5 follow-up**: `providers::gemini::GeminiAdapter` — direct Google
//! AI Studio Gemini Developer API access for stateless text + tool calling.
//!
//! **I5 slice 6**: `credentials::OsKeystoreCredentialStore` — the real
//! SEC-030 credential store, backed by the `keyring` crate's `v1` API
//! (Windows Credential Manager / macOS Keychain / Linux Secret Service,
//! selected automatically per platform). `examples/store_credential.rs` is
//! the setup-time CLI for storing/inspecting/removing a provider's key.
//!
//! Consent persistence (SEC-035) remains an in-memory-only seam
//! (`consent::ConsentStore`) — no later slice has revisited it yet.
//!
//! **I6.5 slice 5**: `scheduler::TurnScheduler` — AI_PROVIDER_API §7
//! turn-scheduling (ADR-0013 §5): a current-speaker gate *in front of*
//! `Router` — foreground requests from non-speakers queue (never refused,
//! never dropped), background requests (`RouterRequest::foreground: false`,
//! the one §2 field §7.4 adds) bypass the gate; `speaker-changed`/
//! `request-queued`/`request-dequeued` facts returned to the caller to
//! publish. `Router` itself is untouched, per §7.4.

#![forbid(unsafe_code)] // SEC-042

pub mod adapter;
pub mod consent;
pub mod credentials;
pub mod delimiter;
pub mod health;
pub mod providers;
pub mod router;
pub mod scheduler;
pub mod types;

pub use consent::{ConsentStore, InMemoryConsentStore};
pub use credentials::{CredentialStore, InMemoryCredentialStore, OsKeystoreCredentialStore};
pub use health::ProviderHealth;
pub use router::{Router, RouterError, SOURCE};
pub use scheduler::{QueuedRequest, SubmitDecision, TurnScheduler};
