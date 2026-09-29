//! OCP Companion Manager — ADR-0013 (Multi-Companion Actor Architecture), I6.5.
//!
//! Kernel-side owner of N companion **Actors**: each companion has its own
//! mailbox and context, multiplexed over the platform's existing
//! single-threaded event model (ADR-0013 §2 — "no thread per companion"; the
//! same shape `DeterministicEngine` and `ActivityContextEngine` already use).
//! This crate is a **routing/addressing layer, not a concurrency primitive**:
//!
//! - **Targeted, never broadcast** (§3): an event addressed by `companionId`
//!   (or §2.7's `target: "companion:<id>"`) reaches exactly that actor; an
//!   unaddressed event reaches only actors whose *subscriptions* prefix-match
//!   its type (same family semantics as `ocp-behavior-api`'s `Trigger`).
//!   An event nobody subscribes to is delivered to no one — provably.
//! - **Staggered scheduling** (§4): [`CompanionManager::tick`] processes at
//!   most one event of one actor per call, rotating across actors — the
//!   kernel-side analog of the ADR's frame-rotation rendering rule.
//! - **Lifecycle mirroring**: the manager emits RUNTIME_API §8.2 *request*
//!   facts (spawn/despawn/sleep/show/hide/focus) and mirrors the runtime's
//!   *outcome* facts back into actor state. It never assumes an outcome —
//!   an actor is `Requested` until `companion-spawned` actually arrives
//!   (same truthfulness discipline as §3.1's degradation reporting).
//! - **Wake-on-request** (§8): routing an event to a sleeping companion queues
//!   the event and emits ONE wake request ("requests never block on
//!   presentation capability") — proven by test, including the only-once part.
//!
//! Interpretive readings, flagged for review (same practice as every engine):
//! - `target: "companion"` (§2.7's legacy value, no id) maps to
//!   [`DEFAULT_COMPANION_ID`] — the single-companion-compat reading of §8.1.
//! - Hidden ≠ sleeping at the manager too: a hidden actor still processes its
//!   mailbox (§8.2 says hidden companions "still render/update state"); only
//!   sleeping actors hold their mail.
//! - The per-companion Behavior/AI wiring is NOT in this crate: the manager
//!   hands each delivered event to a caller-supplied [`ActorHandler`] — the
//!   kernel decides what an actor *does* (run Behavior rules, call the AI
//!   Router, ...); this crate only guarantees who gets what, in what order.

#![forbid(unsafe_code)] // SEC-042

use std::collections::VecDeque;

use ocp_runtime_api::{Position, DEFAULT_COMPANION_ID};
use ocp_shared_types::Envelope;
use serde_json::json;

// Re-exported so manager consumers (e.g. `services/kernel`) can build spawn
// positions without a direct ocp-runtime-api dependency.
pub use ocp_runtime_api::Position as CompanionPosition;

/// Envelope `source` for every fact this manager emits (X1-S spirit: the
/// component identifies itself; it never impersonates `behavior-engine` or
/// `runtime`).
pub const MANAGER_SOURCE: &str = "companion-manager";

/// Actor lifecycle as mirrored from runtime outcomes (never assumed).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lifecycle {
    /// `companion-spawn-requested` emitted; `companion-spawned` not yet seen.
    Requested,
    /// `companion-spawned` (or `companion-woken`) confirmed.
    Active,
    /// `companion-slept` confirmed. Mailbox holds; wake-on-request applies.
    Sleeping,
}

/// One companion Actor: identity + mirrored presentation state + mailbox.
#[derive(Debug)]
pub struct CompanionActor {
    pub companion_id: String,
    pub character_package_id: String,
    pub lifecycle: Lifecycle,
    /// Visibility flag (§8.2: distinct from sleep — hidden still processes).
    pub hidden: bool,
    pub focused: bool,
    /// Mirrored from `companion-spawned` (and later `moved`) outcomes.
    pub position: Option<Position>,
    /// Event-type prefixes this actor receives *unaddressed* events for
    /// (family semantics: `"ocp.plugin.os-telemetry-"` matches its subtypes).
    pub subscriptions: Vec<String>,
    /// True while a wake request has been emitted but `companion-woken` has
    /// not yet arrived — guards the emit-wake-only-once rule.
    wake_pending: bool,
    mailbox: VecDeque<Envelope>,
    /// Events handed to the handler so far (observability aid).
    pub processed: u64,
}

impl CompanionActor {
    #[must_use]
    pub fn mailbox_len(&self) -> usize {
        self.mailbox.len()
    }
}

/// What the kernel plugs in: what an actor *does* with a delivered event
/// (run Behavior rules, call the AI Router, ...). Outcome envelopes returned
/// without a `correlationId` are stamped with the causing event's id by the
/// manager (NFR-004), so handlers can't accidentally break the audit chain.
pub trait ActorHandler {
    fn on_event(&mut self, companion_id: &str, event: &Envelope) -> Vec<Envelope>;
}

/// A no-op handler for wiring/tests that only care about routing.
pub struct NullHandler;

impl ActorHandler for NullHandler {
    fn on_event(&mut self, _companion_id: &str, _event: &Envelope) -> Vec<Envelope> {
        Vec::new()
    }
}

/// Result of routing one inbound event (ADR-0013 §3).
#[derive(Debug)]
pub enum RouteOutcome {
    /// Queued into these actors' mailboxes (possibly none — targeted-not-
    /// broadcast means "delivered to no one" is a valid, auditable outcome).
    Delivered(Vec<String>),
    /// The addressed companion is sleeping: the event was queued AND this
    /// wake request must be published (§8 wake-on-request). Emitted at most
    /// once per sleep period.
    WakeRequested {
        companion_id: String,
        wake_request: Envelope,
    },
    /// Addressed companion does not exist — the caller audits this fact.
    Unroutable { companion_id: String },
}

#[derive(Debug, PartialEq, Eq)]
pub enum ManagerError {
    DuplicateCompanion(String),
    UnknownCompanion(String),
}

impl std::fmt::Display for ManagerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::DuplicateCompanion(id) => write!(f, "companion `{id}` already exists"),
            Self::UnknownCompanion(id) => write!(f, "companion `{id}` does not exist"),
        }
    }
}

impl std::error::Error for ManagerError {}

/// The Companion Manager (ADR-0013 §§1–4, §8, §10 verbs minus `group()` —
/// Groups are phase 2, OPEN_DECISIONS).
#[derive(Default)]
pub struct CompanionManager {
    /// `Vec`, not a map: deterministic spawn-order rotation for [`Self::tick`].
    actors: Vec<CompanionActor>,
    cursor: usize,
}

impl CompanionManager {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    fn emit(event_type: &str, data: serde_json::Value) -> Envelope {
        Envelope::new(event_type, MANAGER_SOURCE, data).expect("valid manager envelope")
    }

    #[must_use]
    pub fn actor(&self, companion_id: &str) -> Option<&CompanionActor> {
        self.actors.iter().find(|a| a.companion_id == companion_id)
    }

    fn actor_mut(&mut self, companion_id: &str) -> Option<&mut CompanionActor> {
        self.actors
            .iter_mut()
            .find(|a| a.companion_id == companion_id)
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.actors.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.actors.is_empty()
    }

    /// Total queued events across every actor's mailbox (includes mail held
    /// by sleeping actors). Lets a driver loop distinguish "nothing left"
    /// from "an event produced no reaction" without peeking per actor.
    #[must_use]
    pub fn pending_mail(&self) -> usize {
        self.actors.iter().map(|a| a.mailbox.len()).sum()
    }

    // --- Lifecycle requests (manager → runtime, RUNTIME_API §8.2) ------------

    /// Register a new actor and build its spawn request. The actor stays
    /// `Requested` until [`Self::ingest_outcome`] sees `companion-spawned`.
    pub fn spawn(
        &mut self,
        companion_id: &str,
        character_package_id: &str,
        initial_position: Option<Position>,
    ) -> Result<Envelope, ManagerError> {
        if self.actor(companion_id).is_some() {
            return Err(ManagerError::DuplicateCompanion(companion_id.to_owned()));
        }
        self.actors.push(CompanionActor {
            companion_id: companion_id.to_owned(),
            character_package_id: character_package_id.to_owned(),
            lifecycle: Lifecycle::Requested,
            hidden: false,
            focused: false,
            position: None,
            subscriptions: Vec::new(),
            wake_pending: false,
            mailbox: VecDeque::new(),
            processed: 0,
        });
        Ok(Self::emit(
            "ocp.behavior.companion-spawn-requested",
            json!({
                "companionId": companion_id,
                "characterPackageId": character_package_id,
                "initialPosition": initial_position,
            }),
        ))
    }

    /// Build a despawn request. The actor is removed only when
    /// `companion-despawned` is ingested — never optimistically.
    pub fn despawn(&mut self, companion_id: &str) -> Result<Envelope, ManagerError> {
        self.require(companion_id)?;
        Ok(Self::emit(
            "ocp.behavior.companion-despawn-requested",
            json!({ "companionId": companion_id }),
        ))
    }

    /// Build a sleep (`active: true`) or wake (`active: false`) request.
    pub fn request_sleep(
        &mut self,
        companion_id: &str,
        active: bool,
    ) -> Result<Envelope, ManagerError> {
        self.require(companion_id)?;
        Ok(Self::emit(
            "ocp.behavior.companion-sleep-requested",
            json!({ "companionId": companion_id, "active": active }),
        ))
    }

    /// Build a show/hide request (`visible: false` → hide).
    pub fn request_visibility(
        &mut self,
        companion_id: &str,
        visible: bool,
    ) -> Result<Envelope, ManagerError> {
        self.require(companion_id)?;
        let event_type = if visible {
            "ocp.behavior.companion-show-requested"
        } else {
            "ocp.behavior.companion-hide-requested"
        };
        Ok(Self::emit(
            event_type,
            json!({ "companionId": companion_id }),
        ))
    }

    /// Build a focus request.
    pub fn request_focus(&mut self, companion_id: &str) -> Result<Envelope, ManagerError> {
        self.require(companion_id)?;
        Ok(Self::emit(
            "ocp.behavior.companion-focus-requested",
            json!({ "companionId": companion_id }),
        ))
    }

    fn require(&self, companion_id: &str) -> Result<(), ManagerError> {
        if self.actor(companion_id).is_none() {
            return Err(ManagerError::UnknownCompanion(companion_id.to_owned()));
        }
        Ok(())
    }

    /// Subscribe an actor to an event-type prefix for unaddressed delivery
    /// (family semantics, ADR-0013 §3's "only the companions actually
    /// subscribed to it").
    pub fn subscribe(&mut self, companion_id: &str, prefix: &str) -> Result<(), ManagerError> {
        let Some(actor) = self.actor_mut(companion_id) else {
            return Err(ManagerError::UnknownCompanion(companion_id.to_owned()));
        };
        if !actor.subscriptions.iter().any(|p| p == prefix) {
            actor.subscriptions.push(prefix.to_owned());
        }
        Ok(())
    }

    // --- Outcome mirroring (runtime → manager, RUNTIME_API §8.2) -------------

    /// Mirror a runtime outcome into actor state. Returns `true` if the event
    /// was a companion outcome this manager understood.
    pub fn ingest_outcome(&mut self, event: &Envelope) -> bool {
        let Some(id) = event
            .data
            .get("companionId")
            .and_then(|v| v.as_str())
            .map(str::to_owned)
        else {
            return false;
        };
        match event.event_type.as_str() {
            "ocp.runtime.companion-spawned" => {
                if let Some(a) = self.actor_mut(&id) {
                    a.lifecycle = Lifecycle::Active;
                    a.position = event
                        .data
                        .get("position")
                        .and_then(|p| serde_json::from_value::<Position>(p.clone()).ok());
                }
                true
            }
            "ocp.runtime.companion-despawned" => {
                self.actors.retain(|a| a.companion_id != id);
                // Keep the rotation cursor in range after removal.
                if self.cursor >= self.actors.len() {
                    self.cursor = 0;
                }
                true
            }
            "ocp.runtime.companion-slept" => {
                if let Some(a) = self.actor_mut(&id) {
                    a.lifecycle = Lifecycle::Sleeping;
                    a.wake_pending = false;
                }
                true
            }
            "ocp.runtime.companion-woken" => {
                if let Some(a) = self.actor_mut(&id) {
                    a.lifecycle = Lifecycle::Active;
                    a.wake_pending = false;
                }
                true
            }
            "ocp.runtime.companion-shown" => {
                if let Some(a) = self.actor_mut(&id) {
                    a.hidden = false;
                }
                true
            }
            "ocp.runtime.companion-hidden" => {
                if let Some(a) = self.actor_mut(&id) {
                    a.hidden = true;
                }
                true
            }
            "ocp.runtime.companion-focused" => {
                for a in &mut self.actors {
                    a.focused = a.companion_id == id;
                }
                true
            }
            _ => false,
        }
    }

    // --- Routing (ADR-0013 §3: targeted, never broadcast) --------------------

    /// Extract the addressed companion, if any: `data.companionId`, or §2.7's
    /// `data.target` in its `companion:<id>` (or legacy bare `companion`) form.
    fn addressed_companion(event: &Envelope) -> Option<String> {
        if let Some(id) = event.data.get("companionId").and_then(|v| v.as_str()) {
            return Some(id.to_owned());
        }
        match event.data.get("target").and_then(|v| v.as_str()) {
            Some("companion") => Some(DEFAULT_COMPANION_ID.to_owned()),
            Some(t) => t.strip_prefix("companion:").map(str::to_owned),
            None => None,
        }
    }

    /// Route one inbound event to actor mailbox(es).
    pub fn route(&mut self, event: &Envelope) -> RouteOutcome {
        if let Some(id) = Self::addressed_companion(event) {
            let Some(actor) = self.actor_mut(&id) else {
                return RouteOutcome::Unroutable { companion_id: id };
            };
            actor.mailbox.push_back(event.clone());
            if actor.lifecycle == Lifecycle::Sleeping && !actor.wake_pending {
                actor.wake_pending = true;
                let wake = Self::emit(
                    "ocp.behavior.companion-sleep-requested",
                    json!({ "companionId": id, "active": false }),
                )
                .with_correlation(event.id);
                return RouteOutcome::WakeRequested {
                    companion_id: id,
                    wake_request: wake,
                };
            }
            return RouteOutcome::Delivered(vec![id]);
        }

        // Unaddressed: subscription (family-prefix) delivery only — an event
        // nobody subscribed to goes nowhere, by design.
        let mut delivered = Vec::new();
        for actor in &mut self.actors {
            if actor
                .subscriptions
                .iter()
                .any(|p| event.event_type.starts_with(p.as_str()))
            {
                actor.mailbox.push_back(event.clone());
                delivered.push(actor.companion_id.clone());
            }
        }
        RouteOutcome::Delivered(delivered)
    }

    // --- Staggered scheduling (ADR-0013 §4) ----------------------------------

    /// Process at most ONE queued event of ONE actor, rotating across actors
    /// (frame-rotation, kernel-side). Sleeping and not-yet-spawned actors are
    /// skipped (their mail holds). Handler outputs missing a `correlationId`
    /// are stamped with the causing event's id (NFR-004). Returns the
    /// handler's outcome envelopes; empty when there was nothing to do.
    pub fn tick(&mut self, handler: &mut dyn ActorHandler) -> Vec<Envelope> {
        if self.actors.is_empty() {
            return Vec::new();
        }
        let n = self.actors.len();
        for offset in 0..n {
            let idx = (self.cursor + offset) % n;
            let ready = self.actors[idx].lifecycle == Lifecycle::Active
                && !self.actors[idx].mailbox.is_empty();
            if !ready {
                continue;
            }
            // Rotation continues from the NEXT actor regardless of whether
            // this one has more mail — that's the stagger.
            self.cursor = (idx + 1) % n;
            let event = self.actors[idx]
                .mailbox
                .pop_front()
                .expect("checked non-empty");
            self.actors[idx].processed += 1;
            let companion_id = self.actors[idx].companion_id.clone();
            let out = handler.on_event(&companion_id, &event);
            return out
                .into_iter()
                .map(|e| {
                    if e.correlation_id.is_none() {
                        e.with_correlation(event.id)
                    } else {
                        e
                    }
                })
                .collect();
        }
        Vec::new()
    }
}
