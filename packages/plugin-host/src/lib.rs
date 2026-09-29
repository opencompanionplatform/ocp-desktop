//! OCP Plugin Host — logic tier (PLUGIN_API, ADR-0007, ADR-0011).
//!
//! This slice implements everything around the sandbox: manifest validation,
//! signature verification at install AND load (SEC-010), the lifecycle state
//! machine with envelope events per transition (§3), per-call capability
//! enforcement (SEC-002) with runtime revocation (SEC-001), and event-rate
//! quotas where breach ⇒ Suspended, never core failure (SEC-004).
//! The WASM execution engine (wasmtime embedding, host function wiring per §7)
//! is the next slice; the WASI capability spike validated its feasibility
//! (12-research/WASI_SPIKE_REPORT.md).

#![forbid(unsafe_code)] // SEC-042

#[cfg(feature = "battery-telemetry")]
pub mod battery;
pub mod capability;
#[cfg(feature = "engine")]
pub mod engine;
#[cfg(feature = "foreground-mouse-telemetry")]
pub mod foreground_mouse;
pub mod manifest;
#[cfg(feature = "os-telemetry")]
pub mod telemetry;
pub mod verify;

use std::collections::HashMap;
use std::time::{Duration, Instant};

use ocp_event_bus::{BusError, InProcessBus};
use ocp_shared_types::Envelope;
use serde_json::json;
use uuid::Uuid;

use capability::{CapabilityError, CapabilityRequest, GrantSet};
use manifest::{Manifest, ManifestError, TelemetryKind};
use verify::{TrustStore, VerifyError};

/// Maps a sensor kind to its registered event type (EVENT_CATALOG.md,
/// PLUGIN_API §7a).
fn telemetry_event_type(kind: TelemetryKind) -> &'static str {
    match kind {
        TelemetryKind::Cpu => "ocp.plugin.os-telemetry-cpu-changed",
        TelemetryKind::Memory => "ocp.plugin.os-telemetry-memory-changed",
        TelemetryKind::Battery => "ocp.plugin.os-telemetry-battery-changed",
        TelemetryKind::Foreground => "ocp.plugin.os-telemetry-foreground-changed",
        TelemetryKind::Mouse => "ocp.plugin.os-telemetry-mouse-changed",
    }
}

/// Plugin lifecycle states (STATE_MACHINE.md).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PluginState {
    Discovered,
    Installed,
    Active,
    Suspended,
    Rejected,
    Removed,
}

#[derive(Debug)]
pub enum HostError {
    UnknownPlugin(String),
    InvalidTransition {
        from: PluginState,
        action: &'static str,
    },
    Manifest(ManifestError),
    Verify(VerifyError),
    Capability(CapabilityError),
    /// Event-rate quota breached; the plugin has been Suspended (SEC-004).
    QuotaBreached,
    Bus(BusError),
    ManifestParse(serde_json::Error),
}

impl core::fmt::Display for HostError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::UnknownPlugin(id) => write!(f, "unknown plugin: {id}"),
            Self::InvalidTransition { from, action } => {
                write!(f, "invalid lifecycle transition: {action} from {from:?}")
            }
            Self::Manifest(e) => write!(f, "{e}"),
            Self::Verify(e) => write!(f, "{e}"),
            Self::Capability(e) => write!(f, "{e}"),
            Self::QuotaBreached => {
                write!(f, "event-rate quota breached; plugin suspended (SEC-004)")
            }
            Self::Bus(e) => write!(f, "{e}"),
            Self::ManifestParse(e) => write!(f, "manifest is not valid JSON: {e}"),
        }
    }
}

impl std::error::Error for HostError {}

/// Host-enforced ceilings (§5). Manifest `quotas` may request lower, never higher.
#[derive(Debug, Clone)]
pub struct HostConfig {
    pub max_events_per_window: u32,
    pub window: Duration,
}

impl Default for HostConfig {
    fn default() -> Self {
        Self {
            max_events_per_window: 100,
            window: Duration::from_secs(1),
        }
    }
}

/// Fixed-window event-rate limiter. Counted **before** any envelope
/// validation work (X1-D DoS containment, §5).
#[derive(Debug, Clone)]
struct RateLimiter {
    max: u32,
    window: Duration,
    count: u32,
    started: Instant,
}

impl RateLimiter {
    fn new(max: u32, window: Duration) -> Self {
        Self {
            max,
            window,
            count: 0,
            started: Instant::now(),
        }
    }

    fn allow(&mut self, now: Instant) -> bool {
        if now.duration_since(self.started) >= self.window {
            self.started = now;
            self.count = 0;
        }
        self.count += 1;
        self.count <= self.max
    }
}

struct PluginRecord {
    manifest: Manifest,
    state: PluginState,
    grants: GrantSet,
    limiter: RateLimiter,
    /// Subscribed-event receivers, filled at activation (`ocp_event_next` feed).
    inbox: Vec<std::sync::mpsc::Receiver<Envelope>>,
    /// An envelope already popped from `inbox` but not yet successfully
    /// delivered to the guest (buffer-too-small retry, ABI §3). `inbox`'s
    /// `mpsc::Receiver::try_recv` is destructive — without this slot, the
    /// guest's retry call (with a bigger buffer) would pop the *next* queue
    /// item instead of re-receiving the one that didn't fit, silently
    /// losing it. Found in I4 slice 3 (`os-telemetry-monitor` was the first
    /// plugin to actually subscribe to something and receive an envelope
    /// bigger than the SDK's default buffer).
    pending_event: Option<Envelope>,
}

/// The Plugin Host. Owns lifecycle, grants, and quotas; emits every
/// transition as an envelope event with `source: "plugin-host"` (§3).
pub struct PluginHost {
    bus: InProcessBus,
    trust: TrustStore,
    config: HostConfig,
    plugins: HashMap<String, PluginRecord>,
    /// Alpha plugin key-value store (`ocp_memory_*` §7); the real Memory
    /// Layer replaces this at I6. Scope enforcement still applies (SEC-020).
    kv: HashMap<String, HashMap<String, Vec<u8>>>,
    /// Capability audit log (X1-R). Alpha: in-memory; event-backed later.
    pub audit: Vec<String>,
}

impl PluginHost {
    #[must_use]
    pub fn new(bus: InProcessBus, trust: TrustStore, config: HostConfig) -> Self {
        Self {
            bus,
            trust,
            config,
            plugins: HashMap::new(),
            kv: HashMap::new(),
            audit: Vec::new(),
        }
    }

    pub fn state(&self, id: &str) -> Option<PluginState> {
        self.plugins.get(id).map(|r| r.state)
    }

    fn emit(&self, event: &str, data: serde_json::Value, correlation: Option<Uuid>) {
        // Lifecycle facts about plugins; failures here must never take the
        // host down — an emit error is a bus programming error, surfaced in
        // the audit trail only.
        if let Ok(env) = Envelope::new(event, "plugin-host", data) {
            let env = match correlation {
                Some(c) => env.with_correlation(c),
                None => env,
            };
            let _ = self.bus.publish(env);
        }
    }

    /// Package found, manifest read → Discovered (`ocp.plugin.discovered`).
    /// Invalid manifests are Rejected immediately (`ocp.plugin.rejected`).
    pub fn discover(
        &mut self,
        manifest_json: &str,
        correlation: Option<Uuid>,
    ) -> Result<String, HostError> {
        let manifest: Manifest = match serde_json::from_str(manifest_json) {
            Ok(m) => m,
            Err(e) => {
                self.emit(
                    "ocp.plugin.rejected",
                    json!({ "reason": "manifest-unparseable" }),
                    correlation,
                );
                return Err(HostError::ManifestParse(e));
            }
        };
        let id = manifest.id.clone();
        if let Err(e) = manifest.validate() {
            self.plugins.insert(
                id.clone(),
                PluginRecord {
                    manifest,
                    state: PluginState::Rejected,
                    grants: GrantSet::default(),
                    limiter: RateLimiter::new(
                        self.config.max_events_per_window,
                        self.config.window,
                    ),
                    inbox: Vec::new(),
                    pending_event: None,
                },
            );
            self.emit(
                "ocp.plugin.rejected",
                json!({ "pluginId": id, "reason": e.to_string() }),
                correlation,
            );
            return Err(HostError::Manifest(e));
        }
        self.plugins.insert(
            id.clone(),
            PluginRecord {
                manifest,
                state: PluginState::Discovered,
                grants: GrantSet::default(),
                limiter: RateLimiter::new(self.config.max_events_per_window, self.config.window),
                inbox: Vec::new(),
                pending_event: None,
            },
        );
        self.emit(
            "ocp.plugin.discovered",
            json!({ "pluginId": id }),
            correlation,
        );
        Ok(id)
    }

    /// Discovered → Installed: signature verified (SEC-010).
    /// Failure → Rejected (`ocp.plugin.rejected`).
    pub fn install(
        &mut self,
        id: &str,
        package_bytes: &[u8],
        correlation: Option<Uuid>,
    ) -> Result<(), HostError> {
        let rec = self
            .plugins
            .get(id)
            .ok_or_else(|| HostError::UnknownPlugin(id.to_owned()))?;
        if rec.state != PluginState::Discovered {
            return Err(HostError::InvalidTransition {
                from: rec.state,
                action: "install",
            });
        }
        match verify::verify_package(&rec.manifest, package_bytes, &self.trust) {
            Ok(()) => {
                self.plugins.get_mut(id).expect("checked").state = PluginState::Installed;
                self.emit(
                    "ocp.marketplace.package-verified",
                    json!({ "pluginId": id }),
                    correlation,
                );
                self.emit(
                    "ocp.plugin.installed",
                    json!({ "pluginId": id }),
                    correlation,
                );
                Ok(())
            }
            Err(e) => {
                self.plugins.get_mut(id).expect("checked").state = PluginState::Rejected;
                self.emit(
                    "ocp.plugin.rejected",
                    json!({ "pluginId": id, "reason": e.to_string() }),
                    correlation,
                );
                Err(HostError::Verify(e))
            }
        }
    }

    /// Installed → Active: user approved the grant set; signature re-verified
    /// at load (SEC-010). Grants come from the manifest — nothing else is
    /// grantable (§4.1).
    pub fn activate(
        &mut self,
        id: &str,
        package_bytes: &[u8],
        correlation: Option<Uuid>,
    ) -> Result<(), HostError> {
        let rec = self
            .plugins
            .get(id)
            .ok_or_else(|| HostError::UnknownPlugin(id.to_owned()))?;
        if rec.state != PluginState::Installed {
            return Err(HostError::InvalidTransition {
                from: rec.state,
                action: "activate",
            });
        }
        if let Err(e) = verify::verify_package(&rec.manifest, package_bytes, &self.trust) {
            self.plugins.get_mut(id).expect("checked").state = PluginState::Rejected;
            self.emit(
                "ocp.plugin.rejected",
                json!({ "pluginId": id, "reason": e.to_string(), "phase": "load" }),
                correlation,
            );
            return Err(HostError::Verify(e));
        }
        let subscribe_topics = {
            let rec = self.plugins.get(id).expect("checked");
            rec.manifest.capabilities.events.subscribe.clone()
        };
        let inbox: Vec<_> = subscribe_topics
            .into_iter()
            .map(|t| self.bus.subscribe(t))
            .collect();
        let rec = self.plugins.get_mut(id).expect("checked");
        rec.grants = GrantSet::from_capabilities(&rec.manifest.capabilities);
        rec.limiter = RateLimiter::new(self.config.max_events_per_window, self.config.window);
        rec.inbox = inbox;
        rec.pending_event = None;
        rec.state = PluginState::Active;
        self.emit(
            "ocp.plugin.activated",
            json!({ "pluginId": id }),
            correlation,
        );
        self.emit(
            "ocp.plugin.capability-granted",
            json!({ "pluginId": id, "grants": "manifest-set" }),
            correlation,
        );
        Ok(())
    }

    /// Per-call capability check for the host-function layer (SEC-002).
    /// Denials are logged (X1-R) and never reach the kernel.
    pub fn check_capability(&mut self, id: &str, req: &CapabilityRequest) -> Result<(), HostError> {
        let rec = self
            .plugins
            .get(id)
            .ok_or_else(|| HostError::UnknownPlugin(id.to_owned()))?;
        if rec.state != PluginState::Active {
            return Err(HostError::InvalidTransition {
                from: rec.state,
                action: "host-call",
            });
        }
        match rec.grants.check(req) {
            Ok(()) => Ok(()),
            Err(e) => {
                self.audit.push(format!("DENY {id}: {e}"));
                Err(HostError::Capability(e))
            }
        }
    }

    /// `ocp_event_publish` path (§7): quota counted **before** grant and
    /// envelope work (X1-D); breach ⇒ Suspended (SEC-004). Identity (`source`)
    /// is the host-verified plugin id, never a guest claim (X1-S).
    pub fn host_publish(
        &mut self,
        id: &str,
        topic: &str,
        data: serde_json::Value,
        correlation: Option<Uuid>,
    ) -> Result<(), HostError> {
        let over_quota = {
            let rec = self
                .plugins
                .get_mut(id)
                .ok_or_else(|| HostError::UnknownPlugin(id.to_owned()))?;
            if rec.state != PluginState::Active {
                return Err(HostError::InvalidTransition {
                    from: rec.state,
                    action: "publish",
                });
            }
            if rec.limiter.allow(Instant::now()) {
                false
            } else {
                rec.state = PluginState::Suspended;
                true
            }
        };
        if over_quota {
            self.audit.push(format!("QUOTA {id}: event-rate breach"));
            self.emit(
                "ocp.plugin.suspended",
                json!({ "pluginId": id, "reason": "event-rate quota (SEC-004)" }),
                correlation,
            );
            return Err(HostError::QuotaBreached);
        }
        self.check_capability(id, &CapabilityRequest::Publish(topic.to_owned()))?;
        let envelope =
            Envelope::new(topic, id, data).map_err(|e| HostError::Bus(BusError::Invalid(e)))?;
        let envelope = match correlation {
            Some(c) => envelope.with_correlation(c),
            None => envelope,
        };
        self.bus.publish(envelope).map_err(HostError::Bus)?;
        Ok(())
    }

    /// Load-time rejection (ABI failures, PLUGIN_ABI §1): any non-removed
    /// state → Rejected + `ocp.plugin.rejected`.
    pub fn reject(
        &mut self,
        id: &str,
        reason: &str,
        correlation: Option<Uuid>,
    ) -> Result<(), HostError> {
        let rec = self
            .plugins
            .get_mut(id)
            .ok_or_else(|| HostError::UnknownPlugin(id.to_owned()))?;
        if rec.state == PluginState::Removed {
            return Err(HostError::InvalidTransition {
                from: rec.state,
                action: "reject",
            });
        }
        rec.state = PluginState::Rejected;
        rec.grants = GrantSet::default();
        self.emit(
            "ocp.plugin.rejected",
            json!({ "pluginId": id, "reason": reason }),
            correlation,
        );
        Ok(())
    }

    /// `ocp_log` (§7): implicit grant, tagged with the host-assigned id.
    pub fn host_log(&mut self, id: &str, level: i32, message: &str) -> Result<(), HostError> {
        let rec = self
            .plugins
            .get(id)
            .ok_or_else(|| HostError::UnknownPlugin(id.to_owned()))?;
        if rec.state != PluginState::Active {
            return Err(HostError::InvalidTransition {
                from: rec.state,
                action: "log",
            });
        }
        self.audit.push(format!("LOG {id} [{level}] {message}"));
        Ok(())
    }

    /// `ocp_event_next` (§7): next event on subscribed topics. The grant is
    /// re-checked at delivery so revocation applies immediately (SEC-001);
    /// events whose grant was revoked are silently dropped.
    ///
    /// Checks `pending_event` first (an envelope already popped but not yet
    /// successfully handed to the guest — see `host_event_requeue`) before
    /// popping a fresh one from `inbox`, since `inbox`'s `try_recv` is
    /// destructive: without this, a buffer-too-small retry from the engine
    /// would silently skip to the next queued item instead of re-delivering
    /// the one that didn't fit (I4 slice 3 finding).
    pub fn host_event_next(&mut self, id: &str) -> Result<Option<Envelope>, HostError> {
        let rec = self
            .plugins
            .get_mut(id)
            .ok_or_else(|| HostError::UnknownPlugin(id.to_owned()))?;
        if rec.state != PluginState::Active {
            return Err(HostError::InvalidTransition {
                from: rec.state,
                action: "event-next",
            });
        }
        if let Some(env) = rec.pending_event.take() {
            return Ok(Some(env));
        }
        for rx in &rec.inbox {
            while let Ok(env) = rx.try_recv() {
                if rec
                    .grants
                    .check(&CapabilityRequest::Subscribe(env.event_type.clone()))
                    .is_ok()
                {
                    return Ok(Some(env));
                }
            }
        }
        Ok(None)
    }

    /// Hands an already-popped envelope back for redelivery on the next
    /// `host_event_next` call (ABI §3 buffer-too-small retry). Called only
    /// by the engine's `event_next` host function, never by a guest
    /// directly — there is no capability check here because nothing new is
    /// being granted, this is purely "put it back," not "hand out access."
    pub fn host_event_requeue(&mut self, id: &str, env: Envelope) {
        if let Some(rec) = self.plugins.get_mut(id) {
            rec.pending_event = Some(env);
        }
    }

    /// `ocp_memory_get/set/delete` (§7): own scope only, bound by the host
    /// from verified identity (SEC-020). Alpha store; Memory Layer at I6.
    pub fn host_memory_set(
        &mut self,
        id: &str,
        key: &str,
        value: Vec<u8>,
    ) -> Result<(), HostError> {
        let scope = format!("plugin:{id}");
        self.check_capability(id, &CapabilityRequest::MemWrite(scope))?;
        self.kv
            .entry(id.to_owned())
            .or_default()
            .insert(key.to_owned(), value);
        Ok(())
    }

    pub fn host_memory_get(&mut self, id: &str, key: &str) -> Result<Option<Vec<u8>>, HostError> {
        let scope = format!("plugin:{id}");
        self.check_capability(id, &CapabilityRequest::MemRead(scope))?;
        Ok(self.kv.get(id).and_then(|m| m.get(key)).cloned())
    }

    pub fn host_memory_delete(&mut self, id: &str, key: &str) -> Result<(), HostError> {
        let scope = format!("plugin:{id}");
        self.check_capability(id, &CapabilityRequest::MemWrite(scope))?;
        if let Some(m) = self.kv.get_mut(id) {
            m.remove(key);
        }
        Ok(())
    }

    /// Plugin ids currently Active with at least one granted telemetry
    /// sensor — used by the host's OS-sampling loop (`telemetry.rs`) to know
    /// who might be listening, without it needing to reach into
    /// `PluginRecord` internals directly.
    #[must_use]
    pub fn active_telemetry_plugins(&self) -> Vec<String> {
        self.plugins
            .iter()
            .filter(|(_, r)| {
                r.state == PluginState::Active && !r.manifest.capabilities.telemetry.is_empty()
            })
            .map(|(id, _)| id.clone())
            .collect()
    }

    /// Publishes one `ocp.plugin.os-telemetry-*-changed` fact **on the
    /// host's own behalf** (PLUGIN_API §7a) — called only from the host's
    /// OS-sampling loop, never in response to a guest call. The plugin's own
    /// `telemetry` grant is re-checked here (not just at activation) so
    /// runtime revocation (SEC-001) takes effect on the very next sample,
    /// same pattern as `host_event_next`'s subscribe re-check. Deliberately
    /// does **not** count against the plugin's publish-rate quota (SEC-004):
    /// that quota exists to contain a malicious/runaway *guest* call, not
    /// the host's own trusted sampling loop.
    pub fn publish_os_telemetry(
        &mut self,
        id: &str,
        kind: TelemetryKind,
        data: serde_json::Value,
    ) -> Result<(), HostError> {
        let rec = self
            .plugins
            .get(id)
            .ok_or_else(|| HostError::UnknownPlugin(id.to_owned()))?;
        if rec.state != PluginState::Active {
            return Err(HostError::InvalidTransition {
                from: rec.state,
                action: "os-telemetry-publish",
            });
        }
        self.check_capability(id, &CapabilityRequest::TelemetryConfig(kind))?;
        let event_type = telemetry_event_type(kind);
        let envelope = Envelope::new(event_type, "plugin-host", data)
            .map_err(|e| HostError::Bus(BusError::Invalid(e)))?;
        self.bus.publish(envelope).map_err(HostError::Bus)?;
        Ok(())
    }

    /// `ocp_telemetry_config` (§7a): grant-gated request for the host's
    /// OS-sampling loop for one sensor kind. **Slice-1 scope note**: this
    /// enforces the capability check and audit-logs the request; it does not
    /// yet run a real OS-sampling loop or publish
    /// `ocp.plugin.os-telemetry-*-changed` itself — that's Windows-API-
    /// specific work (GetSystemPowerStatus/GetForegroundWindow/GetLastInputInfo
    /// and a CPU/RAM counter), deliberately deferred to its own slice so this
    /// contract-level capability plumbing can compile and test without
    /// touching any platform API.
    pub fn host_telemetry_config(
        &mut self,
        id: &str,
        kind: TelemetryKind,
    ) -> Result<(), HostError> {
        self.check_capability(id, &CapabilityRequest::TelemetryConfig(kind))?;
        self.audit.push(format!("TELEMETRY-CONFIG {id}: {kind:?}"));
        Ok(())
    }

    /// Runtime revocation (SEC-001, §4.5). Applies from the next call.
    /// `suspend_if_unusable` ⇒ plugin transitions to Suspended.
    pub fn revoke(
        &mut self,
        id: &str,
        req: &CapabilityRequest,
        suspend_if_unusable: bool,
        correlation: Option<Uuid>,
    ) -> Result<bool, HostError> {
        let rec = self
            .plugins
            .get_mut(id)
            .ok_or_else(|| HostError::UnknownPlugin(id.to_owned()))?;
        let removed = rec.grants.revoke(req);
        if removed {
            self.emit(
                "ocp.plugin.capability-revoked",
                json!({ "pluginId": id, "capability": format!("{req:?}") }),
                correlation,
            );
        }
        if suspend_if_unusable {
            let rec = self.plugins.get_mut(id).expect("checked");
            if rec.state == PluginState::Active {
                rec.state = PluginState::Suspended;
                self.emit(
                    "ocp.plugin.suspended",
                    json!({ "pluginId": id, "reason": "revocation left plugin unusable" }),
                    correlation,
                );
            }
        }
        Ok(removed)
    }

    /// Abnormal termination: kernel unaffected (SEC-001, ADR-0007).
    /// Emits `ocp.plugin.crashed`, then the plugin is Suspended.
    pub fn report_crash(&mut self, id: &str, correlation: Option<Uuid>) -> Result<(), HostError> {
        let rec = self
            .plugins
            .get_mut(id)
            .ok_or_else(|| HostError::UnknownPlugin(id.to_owned()))?;
        if rec.state != PluginState::Active {
            return Err(HostError::InvalidTransition {
                from: rec.state,
                action: "crash-report",
            });
        }
        rec.state = PluginState::Suspended;
        self.emit("ocp.plugin.crashed", json!({ "pluginId": id }), correlation);
        Ok(())
    }

    /// Suspended → Active; load-time signature check repeats (SEC-010).
    pub fn resume(
        &mut self,
        id: &str,
        package_bytes: &[u8],
        correlation: Option<Uuid>,
    ) -> Result<(), HostError> {
        let rec = self
            .plugins
            .get(id)
            .ok_or_else(|| HostError::UnknownPlugin(id.to_owned()))?;
        if rec.state != PluginState::Suspended {
            return Err(HostError::InvalidTransition {
                from: rec.state,
                action: "resume",
            });
        }
        verify::verify_package(&rec.manifest, package_bytes, &self.trust)
            .map_err(HostError::Verify)?;
        let rec = self.plugins.get_mut(id).expect("checked");
        rec.grants = GrantSet::from_capabilities(&rec.manifest.capabilities);
        rec.state = PluginState::Active;
        self.emit("ocp.plugin.resumed", json!({ "pluginId": id }), correlation);
        Ok(())
    }

    /// Uninstall. Plugin-scope memory deletion (SEC-021) is owed by the
    /// Memory Layer, keyed off this event.
    pub fn remove(&mut self, id: &str, correlation: Option<Uuid>) -> Result<(), HostError> {
        let rec = self
            .plugins
            .get_mut(id)
            .ok_or_else(|| HostError::UnknownPlugin(id.to_owned()))?;
        match rec.state {
            PluginState::Installed | PluginState::Active | PluginState::Suspended => {
                rec.state = PluginState::Removed;
                rec.grants = GrantSet::default();
                rec.inbox = Vec::new();
                // SEC-021: plugin-scope deletion is complete (alpha store).
                self.kv.remove(id);
                self.emit("ocp.plugin.removed", json!({ "pluginId": id }), correlation);
                Ok(())
            }
            from => Err(HostError::InvalidTransition {
                from,
                action: "remove",
            }),
        }
    }
}
