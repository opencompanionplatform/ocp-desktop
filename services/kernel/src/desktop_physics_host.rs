use ocp_desktop_physics::{
    DesktopPhysicsRuntime, DesktopWorldPhysicsQuery, FixedStepConfig, PhysicsBody, PhysicsBodyId,
    PhysicsCommand, PhysicsEventProjector, PhysicsRuntimeError, PhysicsRuntimeEvent,
};
use ocp_desktop_world::DesktopWorldSnapshot;
use ocp_event_bus::{BusError, InProcessBus};
use ocp_shared_types::Envelope;
use serde_json::Value;
use std::fmt;
use std::time::Duration;

pub const DESKTOP_PHYSICS_STARTED: &str = "ocp.runtime.desktop-physics-started";
pub const DESKTOP_PHYSICS_STOPPED: &str = "ocp.runtime.desktop-physics-stopped";
pub const DESKTOP_PHYSICS_DEGRADED: &str = "ocp.runtime.desktop-physics-degraded";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KernelDesktopPhysicsState {
    Disabled,
    Running,
    Degraded,
    Stopped,
}

impl KernelDesktopPhysicsState {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::Running => "running",
            Self::Degraded => "degraded",
            Self::Stopped => "stopped",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KernelDesktopPhysicsConfig {
    pub enabled: bool,
    pub fixed_step: Duration,
    pub max_catch_up_steps: u32,
    pub event_source: String,
}

impl Default for KernelDesktopPhysicsConfig {
    fn default() -> Self {
        let fixed_step = FixedStepConfig::default();
        Self {
            enabled: true,
            fixed_step: fixed_step.step,
            max_catch_up_steps: fixed_step.max_catch_up_steps,
            event_source: "ocp-kernel-desktop-physics".to_owned(),
        }
    }
}

impl KernelDesktopPhysicsConfig {
    #[must_use]
    pub fn from_env() -> Self {
        let defaults = Self::default();

        Self {
            enabled: env_bool("OCP_DESKTOP_PHYSICS_ENABLED", defaults.enabled),
            fixed_step: Duration::from_micros(env_u64(
                "OCP_DESKTOP_PHYSICS_STEP_US",
                u64::try_from(defaults.fixed_step.as_micros()).unwrap_or(8_333),
            )),
            max_catch_up_steps: env_u32(
                "OCP_DESKTOP_PHYSICS_MAX_CATCH_UP_STEPS",
                defaults.max_catch_up_steps,
            ),
            event_source: std::env::var("OCP_DESKTOP_PHYSICS_EVENT_SOURCE")
                .ok()
                .filter(|value| !value.trim().is_empty())
                .unwrap_or(defaults.event_source),
        }
    }

    #[must_use]
    pub const fn fixed_step_config(&self) -> FixedStepConfig {
        FixedStepConfig {
            step: self.fixed_step,
            max_catch_up_steps: self.max_catch_up_steps,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KernelDesktopPhysicsHealth {
    pub state: KernelDesktopPhysicsState,
    pub completed_ticks: u64,
    pub published_events: u64,
    pub rejected_commands: u64,
    pub body_count: usize,
}

#[derive(Debug)]
pub enum KernelDesktopPhysicsError {
    Disabled,
    MissingWorldSnapshot,
    Runtime(PhysicsRuntimeError),
    Serialization(serde_json::Error),
    Event(BusError),
}

impl fmt::Display for KernelDesktopPhysicsError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Disabled => formatter.write_str("Desktop Physics is disabled"),
            Self::MissingWorldSnapshot => {
                formatter.write_str("Desktop World snapshot is unavailable")
            }
            Self::Runtime(error) => {
                write!(formatter, "Desktop Physics runtime: {error}")
            }
            Self::Serialization(error) => {
                write!(formatter, "Desktop Physics serialization: {error}")
            }
            Self::Event(error) => {
                write!(formatter, "Desktop Physics event publish: {error}")
            }
        }
    }
}

impl std::error::Error for KernelDesktopPhysicsError {}

impl From<PhysicsRuntimeError> for KernelDesktopPhysicsError {
    fn from(error: PhysicsRuntimeError) -> Self {
        Self::Runtime(error)
    }
}

impl From<serde_json::Error> for KernelDesktopPhysicsError {
    fn from(error: serde_json::Error) -> Self {
        Self::Serialization(error)
    }
}

impl From<BusError> for KernelDesktopPhysicsError {
    fn from(error: BusError) -> Self {
        Self::Event(error)
    }
}

pub struct KernelDesktopPhysicsHost {
    state: KernelDesktopPhysicsState,
    config: KernelDesktopPhysicsConfig,
    runtime: DesktopPhysicsRuntime,
    projector: PhysicsEventProjector,
    bus: InProcessBus,
    completed_ticks: u64,
    published_events: u64,
    rejected_commands: u64,
    body_count: usize,
    previous_surfaces: Option<Vec<ocp_shared_types::SurfaceDescriptor>>,
}

impl KernelDesktopPhysicsHost {
    pub fn new(
        bus: InProcessBus,
        config: KernelDesktopPhysicsConfig,
    ) -> Result<Self, KernelDesktopPhysicsError> {
        if !config.enabled {
            return Ok(Self {
                state: KernelDesktopPhysicsState::Disabled,
                runtime: DesktopPhysicsRuntime::new(config.fixed_step_config()),
                projector: PhysicsEventProjector::default(),
                bus,
                completed_ticks: 0,
                published_events: 0,
                rejected_commands: 0,
                body_count: 0,
                previous_surfaces: None,
                config,
            });
        }

        let host = Self {
            state: KernelDesktopPhysicsState::Running,
            runtime: DesktopPhysicsRuntime::new(config.fixed_step_config()),
            projector: PhysicsEventProjector::default(),
            bus,
            completed_ticks: 0,
            published_events: 0,
            rejected_commands: 0,
            body_count: 0,
            previous_surfaces: None,
            config,
        };

        host.publish_lifecycle(
            DESKTOP_PHYSICS_STARTED,
            serde_json::json!({
                "state": host.state.as_str(),
                "fixedStepMicros":
                    host.config.fixed_step.as_micros(),
                "maxCatchUpSteps":
                    host.config.max_catch_up_steps,
            }),
        )?;

        Ok(host)
    }

    #[must_use]
    pub const fn state(&self) -> KernelDesktopPhysicsState {
        self.state
    }

    #[must_use]
    pub fn bus(&self) -> InProcessBus {
        self.bus.clone()
    }

    pub fn insert_body(
        &mut self,
        body: PhysicsBody,
    ) -> Result<PhysicsBodyId, KernelDesktopPhysicsError> {
        self.ensure_enabled()?;
        let body_id = self.runtime.insert_body(body)?;
        self.body_count += 1;
        Ok(body_id)
    }

    pub fn remove_body(
        &mut self,
        body_id: PhysicsBodyId,
    ) -> Result<PhysicsBody, KernelDesktopPhysicsError> {
        self.ensure_enabled()?;
        let body = self.runtime.remove_body(body_id)?;
        self.projector.forget_body(body_id);
        self.body_count = self.body_count.saturating_sub(1);
        Ok(body)
    }

    pub fn enqueue(
        &mut self,
        body_id: PhysicsBodyId,
        command: PhysicsCommand,
    ) -> Result<(), KernelDesktopPhysicsError> {
        self.ensure_enabled()?;
        self.runtime.enqueue(body_id, command)?;
        Ok(())
    }

    #[must_use]
    pub fn body(&self, body_id: PhysicsBodyId) -> Option<PhysicsBody> {
        self.runtime.body(body_id).cloned()
    }

    pub fn replace_body(
        &mut self,
        body_id: PhysicsBodyId,
        body: PhysicsBody,
    ) -> Result<(), KernelDesktopPhysicsError> {
        self.ensure_enabled()?;
        self.runtime.replace_body(body_id, body)?;
        self.projector.forget_body(body_id);
        Ok(())
    }

    pub fn tick(
        &mut self,
        delta: Duration,
        world: &DesktopWorldSnapshot,
    ) -> Result<usize, KernelDesktopPhysicsError> {
        self.ensure_enabled()?;

        if let Some(previous_surfaces) = self.previous_surfaces.as_deref() {
            self.runtime
                .follow_surface_geometry(previous_surfaces, &world.surfaces);
        }
        self.previous_surfaces = Some(world.surfaces.clone());

        let query = DesktopWorldPhysicsQuery::new(world);
        let frame = self.runtime.tick(delta, &query);
        let events = self.projector.project(&frame);

        let mut published = 0;
        for event in events {
            if matches!(
                event.payload,
                ocp_desktop_physics::PhysicsEventPayload::CommandRejected { .. }
            ) {
                self.rejected_commands += 1;
            }

            self.publish_runtime_event(event)?;
            published += 1;
        }

        self.completed_ticks += 1;
        self.published_events += u64::try_from(published).unwrap_or(0);

        Ok(published)
    }

    #[must_use]
    pub const fn health(&self) -> KernelDesktopPhysicsHealth {
        KernelDesktopPhysicsHealth {
            state: self.state,
            completed_ticks: self.completed_ticks,
            published_events: self.published_events,
            rejected_commands: self.rejected_commands,
            body_count: self.body_count,
        }
    }

    pub fn mark_degraded(
        &mut self,
        message: impl Into<String>,
    ) -> Result<(), KernelDesktopPhysicsError> {
        self.ensure_enabled()?;
        self.state = KernelDesktopPhysicsState::Degraded;
        self.publish_lifecycle(
            DESKTOP_PHYSICS_DEGRADED,
            serde_json::json!({
                "state": self.state.as_str(),
                "message": message.into(),
            }),
        )
    }

    pub fn shutdown(&mut self) -> Result<(), KernelDesktopPhysicsError> {
        if self.state == KernelDesktopPhysicsState::Disabled
            || self.state == KernelDesktopPhysicsState::Stopped
        {
            return Ok(());
        }

        self.state = KernelDesktopPhysicsState::Stopped;
        self.publish_lifecycle(
            DESKTOP_PHYSICS_STOPPED,
            serde_json::json!({
                "state": self.state.as_str(),
                "completedTicks": self.completed_ticks,
                "publishedEvents": self.published_events,
                "rejectedCommands": self.rejected_commands,
                "bodyCount": self.body_count,
            }),
        )
    }

    fn ensure_enabled(&self) -> Result<(), KernelDesktopPhysicsError> {
        if self.state == KernelDesktopPhysicsState::Disabled {
            Err(KernelDesktopPhysicsError::Disabled)
        } else {
            Ok(())
        }
    }

    fn publish_runtime_event(
        &self,
        event: PhysicsRuntimeEvent,
    ) -> Result<(), KernelDesktopPhysicsError> {
        let data = serde_json::to_value(event.payload)?;
        let mut envelope = Envelope::new(event.event_type, self.config.event_source.clone(), data)
            .map_err(|error| KernelDesktopPhysicsError::Event(BusError::Invalid(error)))?;

        envelope.version = event.version;
        self.bus.publish(envelope)?;
        Ok(())
    }

    fn publish_lifecycle(
        &self,
        event_type: &'static str,
        data: Value,
    ) -> Result<(), KernelDesktopPhysicsError> {
        let envelope = Envelope::new(event_type, self.config.event_source.clone(), data)
            .map_err(|error| KernelDesktopPhysicsError::Event(BusError::Invalid(error)))?;

        self.bus.publish(envelope)?;
        Ok(())
    }
}

fn env_bool(name: &str, default: bool) -> bool {
    std::env::var(name)
        .ok()
        .and_then(|value| match value.trim().to_ascii_lowercase().as_str() {
            "1" | "true" | "yes" | "on" => Some(true),
            "0" | "false" | "no" | "off" => Some(false),
            _ => None,
        })
        .unwrap_or(default)
}

fn env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|value| value.trim().parse().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default)
}

fn env_u32(name: &str, default: u32) -> u32 {
    std::env::var(name)
        .ok()
        .and_then(|value| value.trim().parse().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default)
}

/// Replay the current Kernel-owned Desktop Physics lifecycle state to a newly
/// subscribed Runtime. The original lifecycle event may have been published
/// before the presentation channel existed.
pub fn publish_lifecycle_replay(
    state: KernelDesktopPhysicsState,
    bus: &InProcessBus,
) -> Result<(), KernelDesktopPhysicsError> {
    let event_type = match state {
        KernelDesktopPhysicsState::Running => DESKTOP_PHYSICS_STARTED,
        KernelDesktopPhysicsState::Degraded => DESKTOP_PHYSICS_DEGRADED,
        KernelDesktopPhysicsState::Stopped => DESKTOP_PHYSICS_STOPPED,
        KernelDesktopPhysicsState::Disabled => return Ok(()),
    };

    let envelope = Envelope::new(
        event_type,
        "ocp-kernel",
        serde_json::json!({
            "state": state.as_str(),
            "replay": true,
        }),
    )
    .map_err(|error| KernelDesktopPhysicsError::Event(BusError::Invalid(error)))?;

    bus.publish(envelope)?;
    Ok(())
}
