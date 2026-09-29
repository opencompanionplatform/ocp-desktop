//! OCP in-process event bus tier.
//!
//! Binding specs: ocp-architecture/06-api/EVENT_API.md, ADR-0005 (Approved).
//! Guarantees: at-least-once within a session; ordering per source only;
//! no persistence across restarts. Consumers dedupe on envelope `id`.
//! SEC-041: every publish is validated; malformed envelopes are rejected
//! (dropped by the bus, logged by the caller), never propagated.

#![forbid(unsafe_code)] // SEC-042

use std::collections::HashSet;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};

use ocp_shared_types::{Envelope, EnvelopeError};
use uuid::Uuid;

/// Publish failures. `Invalid` fulfils the SEC-041 drop rule: the event never
/// reaches any subscriber.
#[derive(Debug)]
pub enum BusError {
    /// Envelope failed EVENT_API validation (SEC-041). Contains the reason for logging.
    Invalid(EnvelopeError),
}

impl core::fmt::Display for BusError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::Invalid(e) => write!(f, "envelope rejected (SEC-041): {e}"),
        }
    }
}

impl std::error::Error for BusError {}

/// A topic subscription: exact type (`ocp.plugin.crashed`) or prefix ending
/// with `.` (`ocp.plugin.`) for a family subscription.
#[derive(Debug, Clone)]
struct Subscription {
    pattern: String,
    sender: Sender<Envelope>,
}

impl Subscription {
    fn matches(&self, event_type: &str) -> bool {
        if let Some(prefix) = self.pattern.strip_suffix('.') {
            event_type.starts_with(prefix)
                && event_type.len() > prefix.len()
                && event_type.as_bytes()[prefix.len()] == b'.'
        } else {
            event_type == self.pattern
        }
    }
}

/// In-process bus tier (ADR-0005 tier 1). Cheap to clone; clones share state.
#[derive(Clone, Default)]
pub struct InProcessBus {
    subs: Arc<Mutex<Vec<Subscription>>>,
}

impl InProcessBus {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Subscribe to an exact type or a `prefix.`-style family pattern.
    pub fn subscribe(&self, pattern: impl Into<String>) -> Receiver<Envelope> {
        let (tx, rx) = channel();
        self.subs.lock().expect("bus lock").push(Subscription {
            pattern: pattern.into(),
            sender: tx,
        });
        rx
    }

    /// Validate (SEC-041) then deliver to all matching subscribers.
    /// Delivery is at-least-once; per-source ordering follows publish order
    /// because delivery is synchronous per subscriber channel.
    pub fn publish(&self, envelope: Envelope) -> Result<usize, BusError> {
        envelope.validate().map_err(BusError::Invalid)?;
        let subs = self.subs.lock().expect("bus lock");
        let mut delivered = 0;
        for sub in subs.iter() {
            if sub.matches(&envelope.event_type) && sub.sender.send(envelope.clone()).is_ok() {
                delivered += 1;
            }
        }
        Ok(delivered)
    }
}

/// Consumer-side dedupe helper (EVENT_API: at-least-once ⇒ consumers must be
/// idempotent, dedupe on `id`).
#[derive(Default)]
pub struct Deduper {
    seen: HashSet<Uuid>,
}

impl Deduper {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns `true` the first time an id is seen, `false` on duplicates.
    pub fn first_seen(&mut self, id: Uuid) -> bool {
        self.seen.insert(id)
    }
}
