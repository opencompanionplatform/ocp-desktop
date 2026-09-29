//! Turn-scheduling for multiple companions — AI_PROVIDER_API §7 (ADR-0013 §5).
//!
//! A **routing-policy layer in front of** [`crate::Router`] (§7.4's own words):
//! the router's request/response shapes, chains, health, and consent rules are
//! untouched. The scheduler only decides *when* a foreground request may reach
//! `Router::route` — at most one companion holds the floor (§7.1 current
//! speaker); foreground requests from anyone else are **queued, never refused,
//! never silently dropped** (§7.2), and background requests
//! (`RouterRequest::foreground == false`, §7.3) bypass the gate entirely.
//!
//! Driving pattern (kernel/Companion Manager side, synchronous like the rest
//! of this workspace):
//!
//! ```text
//! match scheduler.submit(companion, request) {
//!     (Proceed, Some(req), evs) => { publish(evs); router.route(&req); publish(scheduler.complete(companion)); }
//!     (Queued, None, evs)       => { publish(evs); /* held — a later complete() returns it */ }
//! }
//! ```
//!
//! Design notes, flagged:
//! - Events are **returned** to the caller rather than published on a bus the
//!   scheduler owns — same composition style as `ocp-companion-manager`'s
//!   request builders (the kernel owns publishing), and unlike `Router` which
//!   already had a bus of its own since I5. Both patterns exist in this
//!   workspace; picking return-style here keeps the scheduler a pure state
//!   machine with zero I/O, which is what makes its ordering guarantees
//!   trivially testable.
//! - The exact `request-queued`/`request-dequeued` payload fields are not
//!   spelled out in §7.2's prose ("report queue entry/exit as facts") — the
//!   shapes below (`sessionId`/`companionId`/`requestId` + `queuePosition` on
//!   entry) should be cross-checked against EVENT_CATALOG.md's frozen
//!   registration at review, same as every prior payload-shape reading.
//! - The idle-release `speaker-changed` (queue empty) correlates to the
//!   request whose completion released the floor — the scheduler remembers
//!   the floor-holder's `correlationId` for exactly this purpose (NFR-004:
//!   every emitted fact has a cause).

use std::collections::VecDeque;

use ocp_shared_types::Envelope;
use serde_json::json;
use uuid::Uuid;

use crate::router::SOURCE;
use crate::types::RouterRequest;

/// A held foreground request (§7.2 queuing).
#[derive(Debug)]
pub struct QueuedRequest {
    pub companion_id: String,
    pub request: RouterRequest,
}

/// What [`TurnScheduler::submit`] decided.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubmitDecision {
    /// Call `Router::route` now (speaker granted, still speaker, or §7.3
    /// background bypass).
    Proceed,
    /// Held in arrival order; a later [`TurnScheduler::complete`] returns it.
    Queued,
}

/// Who holds the floor, and the correlation of the request that granted it.
struct Speaker {
    companion_id: String,
    correlation: Uuid,
}

/// §7 current-speaker gate. One instance per active session (§7.1's
/// `sessionId`).
pub struct TurnScheduler {
    session_id: Uuid,
    speaker: Option<Speaker>,
    queue: VecDeque<QueuedRequest>,
    audit: Vec<String>,
}

impl TurnScheduler {
    #[must_use]
    pub fn new(session_id: Uuid) -> Self {
        Self {
            session_id,
            speaker: None,
            queue: VecDeque::new(),
            audit: Vec::new(),
        }
    }

    #[must_use]
    pub fn current_speaker(&self) -> Option<&str> {
        self.speaker.as_ref().map(|s| s.companion_id.as_str())
    }

    #[must_use]
    pub fn queue_len(&self) -> usize {
        self.queue.len()
    }

    /// Same explainability aid as `Router::audit_log`.
    #[must_use]
    pub fn audit_log(&self) -> &[String] {
        &self.audit
    }

    fn event(&self, event_type: &str, data: serde_json::Value, correlation: Uuid) -> Envelope {
        Envelope::new(event_type, SOURCE, data)
            .expect("valid scheduler envelope")
            .with_correlation(correlation)
    }

    fn speaker_changed(&self, to: Option<&str>, from: Option<&str>, correlation: Uuid) -> Envelope {
        self.event(
            "ocp.ai-routing.speaker-changed",
            json!({
                "sessionId": self.session_id,
                "companionId": to,
                "previousCompanionId": from,
            }),
            correlation,
        )
    }

    /// Submit a request on behalf of `companion_id`. Returns the decision,
    /// the request to actually run when the decision is `Proceed` (`None`
    /// when held), and the fact events the caller must publish ("no silent
    /// state changes", §6.2's discipline extended to the floor).
    pub fn submit(
        &mut self,
        companion_id: &str,
        request: RouterRequest,
    ) -> (SubmitDecision, Option<RouterRequest>, Vec<Envelope>) {
        // §7.3: background work never engages the gate and never takes the floor.
        if !request.foreground {
            self.audit
                .push(format!("BYPASS {companion_id}: background request (§7.3)"));
            return (SubmitDecision::Proceed, Some(request), Vec::new());
        }

        let speaker_is_current = self
            .speaker
            .as_ref()
            .is_some_and(|s| s.companion_id == companion_id);
        if speaker_is_current {
            // Already the speaker: no state change, no event. Remember the
            // newest request's correlation as the floor's current cause.
            if let Some(s) = self.speaker.as_mut() {
                s.correlation = request.correlation_id;
            }
            return (SubmitDecision::Proceed, Some(request), Vec::new());
        }

        if self.speaker.is_none() {
            let ev = self.speaker_changed(Some(companion_id), None, request.correlation_id);
            self.speaker = Some(Speaker {
                companion_id: companion_id.to_owned(),
                correlation: request.correlation_id,
            });
            self.audit
                .push(format!("FLOOR {companion_id}: granted (was idle)"));
            return (SubmitDecision::Proceed, Some(request), vec![ev]);
        }

        // Floor busy: hold in arrival order (§7.2 — queued, never refused).
        let ev = self.event(
            "ocp.ai-routing.request-queued",
            json!({
                "sessionId": self.session_id,
                "companionId": companion_id,
                "requestId": request.request_id,
                "queuePosition": self.queue.len() + 1,
            }),
            request.correlation_id,
        );
        self.audit
            .push(format!("QUEUE {companion_id}: floor busy (§7.2)"));
        self.queue.push_back(QueuedRequest {
            companion_id: companion_id.to_owned(),
            request,
        });
        (SubmitDecision::Queued, None, vec![ev])
    }

    /// The current speaker's foreground request finished (success *or*
    /// failure — a failed route still releases the floor). Promotes the next
    /// queued request in arrival order (§7.2): the caller must publish the
    /// returned events and then actually run the returned request through
    /// `Router::route`. Completing when not the speaker is audited and
    /// ignored (a §7.3 background completion has no floor to release).
    pub fn complete(&mut self, companion_id: &str) -> (Option<QueuedRequest>, Vec<Envelope>) {
        let Some(current) = &self.speaker else {
            self.audit.push(format!(
                "COMPLETE-IGNORED {companion_id}: floor already idle"
            ));
            return (None, Vec::new());
        };
        if current.companion_id != companion_id {
            self.audit.push(format!(
                "COMPLETE-IGNORED {companion_id}: not the current speaker"
            ));
            return (None, Vec::new());
        }
        let released_correlation = current.correlation;

        match self.queue.pop_front() {
            Some(next) => {
                let dequeued = self.event(
                    "ocp.ai-routing.request-dequeued",
                    json!({
                        "sessionId": self.session_id,
                        "companionId": next.companion_id,
                        "requestId": next.request.request_id,
                    }),
                    next.request.correlation_id,
                );
                let changed = self.speaker_changed(
                    Some(next.companion_id.as_str()),
                    Some(companion_id),
                    next.request.correlation_id,
                );
                self.audit.push(format!(
                    "FLOOR {}: granted (dequeued after {companion_id})",
                    next.companion_id
                ));
                self.speaker = Some(Speaker {
                    companion_id: next.companion_id.clone(),
                    correlation: next.request.correlation_id,
                });
                (Some(next), vec![dequeued, changed])
            }
            None => {
                let changed = self.speaker_changed(None, Some(companion_id), released_correlation);
                self.audit
                    .push(format!("FLOOR idle: {companion_id} released, queue empty"));
                self.speaker = None;
                (None, vec![changed])
            }
        }
    }
}
