//! Provider health FSM — STATE_MACHINE.md "Provider": `Available ⇄ Degraded
//! → Failed → Available (after recovery probe)`.

/// Interpretive note (flagged for review, same practice as I3's
/// `CompanionState` additions): the diagram only shows `Failed` as
/// requiring an explicit recovery probe to leave. A hard, immediate outage
/// (connection refused, DNS failure — never merely "elevated error rate")
/// is modeled here as `Available -> Failed` directly rather than forcing a
/// `Degraded` stop-over that never actually happened. `Degraded` itself is
/// NOT skipped by the router when picking a provider to try — only `Failed`
/// is (AI_PROVIDER_API §4: "Failed removes the provider until health checks
/// pass" is the only removal language in the contract); a chain's ordering
/// already encodes preference, so a `Degraded` provider ranked first is
/// still attempted, just more likely to fail again.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProviderHealth {
    Available,
    Degraded,
    Failed,
}

impl ProviderHealth {
    /// Whether the FSM permits `self -> next`.
    #[must_use]
    pub fn can_transition_to(self, next: Self) -> bool {
        matches!(
            (self, next),
            (Self::Available, Self::Degraded)
                | (Self::Degraded, Self::Available)
                | (Self::Available, Self::Failed)
                | (Self::Degraded, Self::Failed)
                | (Self::Failed, Self::Available)
        )
    }

    /// Only `Failed` removes a provider from being tried at all (§4).
    #[must_use]
    pub fn is_tryable(self) -> bool {
        self != Self::Failed
    }
}
