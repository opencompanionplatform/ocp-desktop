//! Per-provider cloud consent for sensitive (`user-profile` scope by
//! default, MEMORY_API §1) memory excerpts (SEC-035). Consent is remembered
//! per provider and revocable (AI_PROVIDER_API §5).
//!
//! Real persistence (surviving process restarts, a revoke UI) is a later
//! slice; this trait is the seam so the router's own gating logic is
//! testable without it.

pub trait ConsentStore: Send + Sync {
    fn has_consent(&self, provider_id: &str) -> bool;
}

/// Reference/test implementation. Not backed by any persistent store —
/// production consent storage is deferred, see module doc.
#[derive(Debug, Clone, Default)]
pub struct InMemoryConsentStore {
    granted: std::collections::HashSet<String>,
}

impl InMemoryConsentStore {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Grant consent for one provider. Idempotent.
    pub fn grant(&mut self, provider_id: &str) {
        self.granted.insert(provider_id.to_owned());
    }

    /// Revoke consent for one provider (SEC-035: "revocable").
    pub fn revoke(&mut self, provider_id: &str) {
        self.granted.remove(provider_id);
    }
}

impl ConsentStore for InMemoryConsentStore {
    fn has_consent(&self, provider_id: &str) -> bool {
        self.granted.contains(provider_id)
    }
}
