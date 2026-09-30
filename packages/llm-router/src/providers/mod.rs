//! Real vendor wire adapters, one module per provider. Each translates its
//! own vendor JSON shape to/from the neutral `types::RouterRequest`/
//! `RouterResponse` contract at this boundary — the router core
//! (`router.rs`) never sees anything from this module's request/response
//! DTOs directly (AI_ROUTER.md anti-corruption layer).
//!
//! **I5 slice 2**: Ollama (a local provider — no auth required by default,
//! no TLS, matches SEC-031/034's "local providers bound to localhost by
//! default").
//!
//! **I5 slice 3**: OpenRouter (the first real *cloud* provider — TLS,
//! Bearer-token auth, the SEC-035 consent gate's actual target).
//!
//! **I5 slice 4**: Claude (Anthropic), reached directly rather than via
//! OpenRouter's proxy — a second, independently-verified cloud wire format
//! (`x-api-key` instead of `Bearer`, a top-level `system` field instead of
//! a `system`-role message, tool arguments as a real JSON object rather
//! than OpenRouter's JSON-encoded string). This project's practice
//! throughout is to verify a vendor's real, current API via its own docs
//! before writing the adapter, not guess (same discipline I4 applied to
//! `sysinfo`/`starship-battery`/`windows`).
//!
//! **I5 slice 5**: OpenAI (GPT) direct, via the **Responses API**
//! (`/v1/responses`) rather than the legacy Chat Completions shape
//! `OpenRouterAdapter` uses — a third cloud provider, and the first built
//! against a fundamentally different response shape (a typed `output` array
//! of Items, not `choices[].message`). See `openai.rs`'s module doc for the
//! full set of confirmed wire-format differences and one documented,
//! flagged simplification (no confirmed refusal/moderation signal on this
//! API shape yet, so `StopReason::Refused` is never produced by this
//! adapter for now).

pub mod claude;
pub mod gemini;
pub mod gemini_asr;
pub mod gemini_tts;
pub mod ollama;
pub mod openai;
pub mod openrouter;
