use crate::desktop_physics_boot::KernelDesktopPhysicsHandle;
use crate::desktop_physics_host::KernelDesktopPhysicsError;
use crate::drag_release_policy::{
    decide_drag_release_with_preferred_monitor, surface_by_id, DragReleaseDecision,
    DragReleaseTargetKind,
};
use ocp_companion_manager::CompanionPosition;
use ocp_desktop_physics::{
    AabbCollider, AttachmentState, ClimbDirection, JumpDirection, PhysicsBody, PhysicsBodyId,
    PhysicsCommand, SurfaceAttachment, WalkDirection, WalkEdgeBehavior,
};
use ocp_desktop_world::DesktopWorldSnapshot;
use ocp_event_bus::{BusError, InProcessBus};
use ocp_shared_types::surface::SurfaceGeometry;
use ocp_shared_types::{
    Envelope, Orientation, Point2, SurfaceCapabilities, SurfaceDescriptor, SurfaceId, SurfaceKind,
    Vector2, WorldEntityId,
};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fmt;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc, RwLock,
};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

pub const COMPANION_MOVED: &str = "ocp.runtime.companion-moved";
pub const COMPANION_PRESENTATION_STATE: &str = "ocp.runtime.companion-presentation-state";
pub const COMPANION_PRESENTATION_SCHEMA_VERSION: u64 = 1;
pub const COMPANION_PHYSICS_BOUND: &str = "ocp.runtime.companion-physics-bound";
pub const COMPANION_PHYSICS_UNBOUND: &str = "ocp.runtime.companion-physics-unbound";
pub const COMPANION_PHYSICS_SOURCE: &str = "ocp-kernel-companion-physics";
const CLIMB_HINT_TTL: Duration = Duration::from_secs(30);
const HANG_ROUTE_EDGE_MARGIN: f32 = 48.0;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CompanionPhysicsBodyConfig {
    pub half_width: f32,
    pub half_height: f32,
    pub default_x: f32,
    pub default_y: f32,
}

impl Default for CompanionPhysicsBodyConfig {
    fn default() -> Self {
        Self {
            half_width: 64.0,
            half_height: 64.0,
            // Runtime 0.1 debug-safe initial feet position. Production
            // launchers should provide restored desktop coordinates.
            default_x: 640.0,
            default_y: 700.0,
        }
    }
}

impl CompanionPhysicsBodyConfig {
    #[must_use]
    pub fn from_env() -> Self {
        let defaults = Self::default();
        Self {
            half_width: env_f32("OCP_COMPANION_PHYSICS_HALF_WIDTH", defaults.half_width),
            half_height: env_f32("OCP_COMPANION_PHYSICS_HALF_HEIGHT", defaults.half_height),
            default_x: env_f32("OCP_COMPANION_PHYSICS_DEFAULT_X", defaults.default_x),
            default_y: env_f32("OCP_COMPANION_PHYSICS_DEFAULT_Y", defaults.default_y),
        }
    }

    /// Apply a validated character package body profile without changing the
    /// restored/debug initial feet position. Package dimensions are canonical;
    /// DPI and presentation scale never flow into this configuration.
    #[must_use]
    pub fn with_collision_half_extents(mut self, half_extents: [f32; 2]) -> Self {
        if half_extents
            .iter()
            .all(|value| value.is_finite() && *value > 0.0)
        {
            self.half_width = half_extents[0];
            self.half_height = half_extents[1];
        }
        self
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CompanionPhysicsBinding {
    pub body_id: PhysicsBodyId,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CompanionMovementCommand {
    WalkLeft { edge_behavior: WalkEdgeBehavior },
    WalkRight { edge_behavior: WalkEdgeBehavior },
    JumpVertical,
    JumpLeft,
    JumpRight,
    ClimbUp,
    ClimbDown,
    HangLeft,
    HangRight,
    HangToCenter,
    HangToFarEdge,
    HangToClimbDownEdge,
    Stop,
    Detach,
    TransferLedge,
    TeleportCurrentMonitor,
}

impl CompanionMovementCommand {
    #[must_use]
    pub const fn into_physics(self) -> Option<PhysicsCommand> {
        Some(match self {
            Self::WalkLeft { edge_behavior } => PhysicsCommand::Walk {
                direction: WalkDirection::Left,
                edge_behavior,
            },
            Self::WalkRight { edge_behavior } => PhysicsCommand::Walk {
                direction: WalkDirection::Right,
                edge_behavior,
            },
            Self::JumpVertical => PhysicsCommand::Jump {
                direction: JumpDirection::Vertical,
            },
            Self::JumpLeft => PhysicsCommand::Jump {
                direction: JumpDirection::Left,
            },
            Self::JumpRight => PhysicsCommand::Jump {
                direction: JumpDirection::Right,
            },
            Self::ClimbUp => PhysicsCommand::Climb {
                direction: ClimbDirection::Up,
            },
            Self::ClimbDown => PhysicsCommand::Climb {
                direction: ClimbDirection::Down,
            },
            Self::HangLeft => PhysicsCommand::HangTraverse {
                direction: WalkDirection::Left,
            },
            Self::HangRight => PhysicsCommand::HangTraverse {
                direction: WalkDirection::Right,
            },
            Self::HangToCenter | Self::HangToFarEdge | Self::HangToClimbDownEdge => return None,
            Self::Stop => PhysicsCommand::Stop,
            Self::Detach => PhysicsCommand::Detach,
            Self::TransferLedge => PhysicsCommand::TransferLedge,
            Self::TeleportCurrentMonitor => return None,
        })
    }
}

#[derive(Debug)]
pub enum CompanionPhysicsBindingError {
    DuplicateCompanion { companion_id: String },
    UnknownCompanion { companion_id: String },
    Physics(KernelDesktopPhysicsError),
    NoGroundSurface { companion_id: String },
    NoClimbableSurface { companion_id: String },
    BodyAirborne { companion_id: String },
    AutonomousWalkRequiresDesktopFloor { companion_id: String },
    AutonomousActionRequiresCurrentMonitorSurface { companion_id: String },
    AutonomousTeleportRequiresDesktopFloor { companion_id: String },
    TeleportRequiresAutonomousSurfacePolicy { companion_id: String },
    InvalidPosition { companion_id: String },
    Event(BusError),
}

impl fmt::Display for CompanionPhysicsBindingError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::DuplicateCompanion { companion_id } => {
                write!(
                    formatter,
                    "companion already has a Physics Body: {companion_id}"
                )
            }
            Self::UnknownCompanion { companion_id } => {
                write!(formatter, "companion has no Physics Body: {companion_id}")
            }
            Self::Physics(error) => {
                write!(formatter, "Desktop Physics: {error}")
            }
            Self::NoGroundSurface { companion_id } => write!(
                formatter,
                "no LANDABLE + WALKABLE horizontal surface for companion: {companion_id}"
            ),
            Self::NoClimbableSurface { companion_id } => write!(
                formatter,
                "no nearby climbable window edge for companion: {companion_id}"
            ),
            Self::BodyAirborne { companion_id } => {
                write!(
                    formatter,
                    "companion Physics Body is airborne: {companion_id}"
                )
            }
            Self::AutonomousWalkRequiresDesktopFloor { companion_id } => write!(
                formatter,
                "autonomous walk requires a DesktopFloor attachment: {companion_id}"
            ),
            Self::AutonomousActionRequiresCurrentMonitorSurface { companion_id } => write!(
                formatter,
                "autonomous action requires the current monitor DesktopFloor or MonitorEdge: {companion_id}"
            ),
            Self::AutonomousTeleportRequiresDesktopFloor { companion_id } => write!(
                formatter,
                "autonomous teleport requires the current monitor DesktopFloor: {companion_id}"
            ),
            Self::TeleportRequiresAutonomousSurfacePolicy { companion_id } => write!(
                formatter,
                "teleport must use the autonomous current-monitor policy: {companion_id}"
            ),
            Self::InvalidPosition { companion_id } => {
                write!(
                    formatter,
                    "invalid authoritative position for companion: {companion_id}"
                )
            }
            Self::Event(error) => {
                write!(formatter, "event publication: {error}")
            }
        }
    }
}

impl std::error::Error for CompanionPhysicsBindingError {}

impl From<KernelDesktopPhysicsError> for CompanionPhysicsBindingError {
    fn from(error: KernelDesktopPhysicsError) -> Self {
        Self::Physics(error)
    }
}

impl From<BusError> for CompanionPhysicsBindingError {
    fn from(error: BusError) -> Self {
        Self::Event(error)
    }
}

#[derive(Debug, Default)]
struct BindingState {
    by_companion: BTreeMap<String, CompanionPhysicsBinding>,
    by_body: BTreeMap<PhysicsBodyId, String>,
    last_feet: BTreeMap<String, Point2>,
    climb_hints: BTreeMap<String, ClimbTargetHint>,
    climb_facing: BTreeMap<String, &'static str>,
    resting_pose: BTreeMap<String, &'static str>,
    autonomous_fall_owner: BTreeMap<String, WorldEntityId>,
    autonomous_hang_routes: BTreeMap<String, AutonomousHangRoute>,
    autonomous_hang_entry_sides: BTreeMap<String, HangEntrySide>,
}

#[derive(Debug, Clone, Copy)]
struct ClimbTargetHint {
    surface_id: SurfaceId,
    anchor_y: f32,
    recorded_at: Instant,
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct AutonomousHangRoute {
    surface_id: SurfaceId,
    target_x: f32,
    direction: WalkDirection,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HangEntrySide {
    Left,
    Right,
}

#[derive(Clone)]
pub struct CompanionPhysicsBindings {
    state: Arc<RwLock<BindingState>>,
    config: CompanionPhysicsBodyConfig,
    bus: InProcessBus,
    movement_sequence: Arc<AtomicU64>,
    presentation_revision: Arc<AtomicU64>,
}

impl CompanionPhysicsBindings {
    #[must_use]
    pub fn new(bus: InProcessBus, config: CompanionPhysicsBodyConfig) -> Self {
        Self {
            state: Arc::new(RwLock::new(BindingState::default())),
            config,
            bus,
            movement_sequence: Arc::new(AtomicU64::new(0)),
            presentation_revision: Arc::new(AtomicU64::new(0)),
        }
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.state
            .read()
            .map_or(0, |state| state.by_companion.len())
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    #[must_use]
    pub fn binding(&self, companion_id: &str) -> Option<CompanionPhysicsBinding> {
        self.state
            .read()
            .ok()
            .and_then(|state| state.by_companion.get(companion_id).copied())
    }

    #[must_use]
    pub fn companion_id(&self, body_id: PhysicsBodyId) -> Option<String> {
        self.state
            .read()
            .ok()
            .and_then(|state| state.by_body.get(&body_id).cloned())
    }

    pub fn bind(
        &self,
        companion_id: &str,
        initial_position: Option<CompanionPosition>,
        physics: &KernelDesktopPhysicsHandle,
    ) -> Result<CompanionPhysicsBinding, CompanionPhysicsBindingError> {
        if let Some(binding) = self.binding(companion_id) {
            return Ok(binding);
        }

        // Input coordinates are a character-feet anchor. Resolve the nearest
        // real Desktop World floor, then convert feet to Physics body center.
        let desired_feet = initial_position.map_or_else(
            || Point2::new(self.config.default_x, self.config.default_y),
            |position| Point2::new(position.x as f32, position.y as f32),
        );
        let world = physics.latest_world_snapshot().ok_or_else(|| {
            CompanionPhysicsBindingError::NoGroundSurface {
                companion_id: companion_id.to_owned(),
            }
        })?;
        let (body, grounded_feet, surface_id) = grounded_body(desired_feet, self.config, &world)
            .ok_or_else(|| CompanionPhysicsBindingError::NoGroundSurface {
                companion_id: companion_id.to_owned(),
            })?;
        let body_id = physics.insert_body(body)?;
        let binding = CompanionPhysicsBinding { body_id };

        {
            let mut state = self.state.write().map_err(|_| {
                CompanionPhysicsBindingError::DuplicateCompanion {
                    companion_id: companion_id.to_owned(),
                }
            })?;

            if state.by_companion.contains_key(companion_id) {
                let _ = physics.remove_body(body_id);
                return Err(CompanionPhysicsBindingError::DuplicateCompanion {
                    companion_id: companion_id.to_owned(),
                });
            }

            state.by_companion.insert(companion_id.to_owned(), binding);
            state.by_body.insert(body_id, companion_id.to_owned());
            state
                .last_feet
                .insert(companion_id.to_owned(), grounded_feet);
        }

        self.publish(
            COMPANION_PHYSICS_BOUND,
            json!({
                "companionId": companion_id,
                "bodyId": body_id,
                "position": grounded_feet,
                "positionAnchor": "character-feet",
                "surfaceId": surface_id,
                "grounded": true,
            }),
        )?;
        self.publish_authoritative_state(
            companion_id,
            body_id,
            grounded_feet,
            surface_kind_by_id(&world, surface_id),
            "spawn",
        )?;

        Ok(binding)
    }

    pub fn unbind(
        &self,
        companion_id: &str,
        physics: &KernelDesktopPhysicsHandle,
    ) -> Result<PhysicsBodyId, CompanionPhysicsBindingError> {
        let binding = {
            let mut state =
                self.state
                    .write()
                    .map_err(|_| CompanionPhysicsBindingError::UnknownCompanion {
                        companion_id: companion_id.to_owned(),
                    })?;

            let binding = state.by_companion.remove(companion_id).ok_or_else(|| {
                CompanionPhysicsBindingError::UnknownCompanion {
                    companion_id: companion_id.to_owned(),
                }
            })?;

            state.by_body.remove(&binding.body_id);
            state.last_feet.remove(companion_id);
            state.autonomous_fall_owner.remove(companion_id);
            state.autonomous_hang_routes.remove(companion_id);
            state.autonomous_hang_entry_sides.remove(companion_id);
            binding
        };

        physics.remove_body(binding.body_id)?;
        self.publish(
            COMPANION_PHYSICS_UNBOUND,
            json!({
                "companionId": companion_id,
                "bodyId": binding.body_id,
            }),
        )?;

        Ok(binding.body_id)
    }

    pub fn enqueue(
        &self,
        companion_id: &str,
        command: CompanionMovementCommand,
        physics: &KernelDesktopPhysicsHandle,
    ) -> Result<(), CompanionPhysicsBindingError> {
        if let Ok(mut state) = self.state.write() {
            if !matches!(command, CompanionMovementCommand::Stop) {
                state.resting_pose.remove(companion_id);
            }
            if matches!(
                command,
                CompanionMovementCommand::Stop | CompanionMovementCommand::Detach
            ) {
                state.autonomous_hang_routes.remove(companion_id);
                state.autonomous_hang_entry_sides.remove(companion_id);
            }
        }
        let mut binding = self.binding(companion_id).ok_or_else(|| {
            CompanionPhysicsBindingError::UnknownCompanion {
                companion_id: companion_id.to_owned(),
            }
        })?;

        if command_requires_ground(command) {
            let body = physics.body(binding.body_id).ok_or_else(|| {
                CompanionPhysicsBindingError::UnknownCompanion {
                    companion_id: companion_id.to_owned(),
                }
            })?;

            if body.attachment.is_grounded() {
                // Preserve the canonical body and its accumulated state.
            } else if body.velocity.x.abs() <= 0.001 && body.velocity.y.abs() <= 0.001 {
                // The attached surface disappeared while stationary. Recover to
                // the nearest validated floor, but never reset an intentional jump.
                binding = self.rebind_grounded(companion_id, physics)?;
            } else {
                return Err(CompanionPhysicsBindingError::BodyAirborne {
                    companion_id: companion_id.to_owned(),
                });
            }
        }

        if matches!(
            command,
            CompanionMovementCommand::ClimbUp | CompanionMovementCommand::ClimbDown
        ) {
            let body = physics.body(binding.body_id).ok_or_else(|| {
                CompanionPhysicsBindingError::UnknownCompanion {
                    companion_id: companion_id.to_owned(),
                }
            })?;
            match body.attachment {
                AttachmentState::Attached { .. } | AttachmentState::Hanging { .. } => {}
                AttachmentState::Grounded { .. } => {
                    let world = physics.latest_world_snapshot().ok_or(
                        CompanionPhysicsBindingError::Physics(
                            KernelDesktopPhysicsError::MissingWorldSnapshot,
                        ),
                    )?;
                    let hinted = self
                        .state
                        .read()
                        .ok()
                        .and_then(|state| state.climb_hints.get(companion_id).copied())
                        .filter(|hint| hint.recorded_at.elapsed() <= CLIMB_HINT_TTL)
                        .filter(|hint| climbable_window_edge_by_id(&world, hint.surface_id))
                        .map(|hint| (hint.surface_id, hint.anchor_y));
                    let (surface_id, anchor_y) = hinted
                        .or_else(|| {
                            nearest_climbable_window_edge(
                                &body,
                                &world,
                                monitor_owner_for_attachment(&world, body.attachment.surface_id()),
                            )
                        })
                        .ok_or_else(|| CompanionPhysicsBindingError::NoClimbableSurface {
                            companion_id: companion_id.to_owned(),
                        })?;
                    let facing = climb_facing_for_surface(&world, surface_id);
                    if let Some(facing) = facing {
                        if let Ok(mut state) = self.state.write() {
                            state.climb_facing.insert(companion_id.to_owned(), facing);
                        }
                    }
                    if physics_debug_enabled() {
                        eprintln!(
                            "[physics-debug] phase=climb-target companion={} body={:?} surface={:?} anchor_y={:.1} source={}",
                            companion_id,
                            binding.body_id,
                            surface_id,
                            anchor_y,
                            if hinted.is_some() { "drag-hint" } else { "body-proximity" },
                        );
                    }
                    physics.enqueue(
                        binding.body_id,
                        PhysicsCommand::AttachVertical {
                            surface_id,
                            anchor_y,
                        },
                    )?;
                }
                AttachmentState::Detached => {
                    return Err(CompanionPhysicsBindingError::BodyAirborne {
                        companion_id: companion_id.to_owned(),
                    });
                }
            }
        }

        if physics_debug_enabled() {
            if let Some(body) = physics.body(binding.body_id) {
                eprintln!(
                    "[physics-debug] phase=command companion={} body={:?}                      command={:?} center=({:.1},{:.1}) velocity=({:.1},{:.1})                      attachment={:?}",
                    companion_id,
                    binding.body_id,
                    command,
                    body.position.x,
                    body.position.y,
                    body.velocity.x,
                    body.velocity.y,
                    body.attachment,
                );
            }
        }

        let physics_command = command.into_physics().ok_or_else(|| {
            CompanionPhysicsBindingError::TeleportRequiresAutonomousSurfacePolicy {
                companion_id: companion_id.to_owned(),
            }
        })?;
        physics.enqueue(binding.body_id, physics_command)?;
        Ok(())
    }

    /// G15.1 policy boundary for Runtime-originated autonomous movement.
    /// Only the current monitor's DesktopFloor and MonitorEdge are eligible;
    /// application-window surfaces remain user-drag-only.
    pub fn enqueue_autonomous_surface_action(
        &self,
        companion_id: &str,
        command: CompanionMovementCommand,
        physics: &KernelDesktopPhysicsHandle,
    ) -> Result<(), CompanionPhysicsBindingError> {
        match command {
            CompanionMovementCommand::Stop => self.enqueue(companion_id, command, physics),
            CompanionMovementCommand::WalkLeft { .. }
            | CompanionMovementCommand::WalkRight { .. } => {
                let binding = self.binding(companion_id).ok_or_else(|| {
                    CompanionPhysicsBindingError::UnknownCompanion {
                        companion_id: companion_id.to_owned(),
                    }
                })?;
                let body = physics.body(binding.body_id).ok_or_else(|| {
                    CompanionPhysicsBindingError::UnknownCompanion {
                        companion_id: companion_id.to_owned(),
                    }
                })?;
                let surface_id = body.attachment.surface_id().ok_or_else(|| {
                    CompanionPhysicsBindingError::AutonomousActionRequiresCurrentMonitorSurface {
                        companion_id: companion_id.to_owned(),
                    }
                })?;
                let owns_current_monitor = physics.latest_world_snapshot().is_some_and(|world| {
                    world.surfaces.iter().any(|surface| {
                        surface.id == surface_id
                            && surface.surface_kind == SurfaceKind::DesktopFloor
                            && surface.owner_entity_id.is_some()
                    })
                });
                if !owns_current_monitor {
                    return Err(
                        CompanionPhysicsBindingError::AutonomousActionRequiresCurrentMonitorSurface {
                            companion_id: companion_id.to_owned(),
                        },
                    );
                }
                self.enqueue_autonomous_floor_walk(companion_id, command, physics)
            }
            CompanionMovementCommand::ClimbUp => {
                let binding = self.binding(companion_id).ok_or_else(|| {
                    CompanionPhysicsBindingError::UnknownCompanion {
                        companion_id: companion_id.to_owned(),
                    }
                })?;
                let body = physics.body(binding.body_id).ok_or_else(|| {
                    CompanionPhysicsBindingError::UnknownCompanion {
                        companion_id: companion_id.to_owned(),
                    }
                })?;
                let world = physics.latest_world_snapshot().ok_or(
                    CompanionPhysicsBindingError::Physics(
                        KernelDesktopPhysicsError::MissingWorldSnapshot,
                    ),
                )?;
                let attached_edge = match body.attachment {
                    // G15.2: an edge chosen by a user drag is already a
                    // canonical vertical MonitorEdge. Continue climbing that
                    // exact current-monitor edge instead of selecting another
                    // edge or trusting a Runtime coordinate.
                    AttachmentState::Attached { attachment } => world
                        .surfaces
                        .iter()
                        .find(|surface| surface.id == attachment.surface_id)
                        .filter(|surface| {
                            surface.surface_kind == SurfaceKind::MonitorEdge
                                && surface.orientation == Orientation::Vertical
                                && surface.owner_entity_id.is_some()
                                && surface
                                    .capabilities
                                    .contains(SurfaceCapabilities::CLIMBABLE)
                        })
                        .map(|surface| surface.id),
                    _ => None,
                };
                let surface_id = if let Some(surface_id) = attached_edge {
                    surface_id
                } else {
                    let floor_surface_id = match body.attachment {
                        AttachmentState::Grounded { attachment } => attachment.surface_id,
                        _ => {
                            return Err(
                                CompanionPhysicsBindingError::AutonomousActionRequiresCurrentMonitorSurface {
                                    companion_id: companion_id.to_owned(),
                                },
                            )
                        }
                    };
                    let monitor_owner = world
                        .surfaces
                        .iter()
                        .find(|surface| surface.id == floor_surface_id)
                        .filter(|surface| surface.surface_kind == SurfaceKind::DesktopFloor)
                        .and_then(|surface| surface.owner_entity_id)
                        .ok_or_else(|| {
                            CompanionPhysicsBindingError::AutonomousActionRequiresCurrentMonitorSurface {
                                companion_id: companion_id.to_owned(),
                            }
                        })?;
                    let (surface_id, anchor_y) =
                        nearest_climbable_monitor_edge(&body, &world, monitor_owner).ok_or_else(
                            || CompanionPhysicsBindingError::NoClimbableSurface {
                                companion_id: companion_id.to_owned(),
                            },
                        )?;
                    physics.enqueue(
                        binding.body_id,
                        PhysicsCommand::AttachVertical {
                            surface_id,
                            anchor_y,
                        },
                    )?;
                    surface_id
                };
                if let Ok(mut state) = self.state.write() {
                    state.resting_pose.remove(companion_id);
                    if let Some(facing) = climb_facing_for_surface(&world, surface_id) {
                        state.climb_facing.insert(companion_id.to_owned(), facing);
                    }
                }
                physics.enqueue(
                    binding.body_id,
                    PhysicsCommand::Climb {
                        direction: ClimbDirection::Up,
                    },
                )?;
                Ok(())
            }
            CompanionMovementCommand::ClimbDown => {
                let binding = self.binding(companion_id).ok_or_else(|| {
                    CompanionPhysicsBindingError::UnknownCompanion {
                        companion_id: companion_id.to_owned(),
                    }
                })?;
                let body = physics.body(binding.body_id).ok_or_else(|| {
                    CompanionPhysicsBindingError::UnknownCompanion {
                        companion_id: companion_id.to_owned(),
                    }
                })?;
                let world = physics.latest_world_snapshot().ok_or(
                    CompanionPhysicsBindingError::Physics(
                        KernelDesktopPhysicsError::MissingWorldSnapshot,
                    ),
                )?;
                let surface_id = body.attachment.surface_id().ok_or_else(|| {
                    CompanionPhysicsBindingError::AutonomousActionRequiresCurrentMonitorSurface {
                        companion_id: companion_id.to_owned(),
                    }
                })?;
                let surface = world
                    .surfaces
                    .iter()
                    .find(|surface| {
                        surface.id == surface_id
                            && surface.surface_kind == SurfaceKind::MonitorEdge
                            && surface.owner_entity_id.is_some()
                    })
                    .ok_or_else(|| {
                        CompanionPhysicsBindingError::AutonomousActionRequiresCurrentMonitorSurface {
                            companion_id: companion_id.to_owned(),
                        }
                    })?;
                let facing = if surface.orientation == Orientation::Vertical
                    && surface
                        .capabilities
                        .contains(SurfaceCapabilities::CLIMBABLE)
                {
                    climb_facing_for_surface(&world, surface.id)
                } else if surface.orientation == Orientation::Horizontal
                    && surface.capabilities.contains(SurfaceCapabilities::HANGABLE)
                    && matches!(body.attachment, AttachmentState::Hanging { .. })
                {
                    let monitor_owner = surface.owner_entity_id.expect("validated monitor owner");
                    let half_width = body.collider.half_extents.width;
                    let top_y = match surface.geometry {
                        SurfaceGeometry::Segment { start, .. } => start.y,
                        _ => {
                            return Err(
                                CompanionPhysicsBindingError::AutonomousActionRequiresCurrentMonitorSurface {
                                    companion_id: companion_id.to_owned(),
                                },
                            )
                        }
                    };
                    world.surfaces.iter().find_map(|candidate| {
                        if candidate.surface_kind != SurfaceKind::MonitorEdge
                            || candidate.owner_entity_id != Some(monitor_owner)
                            || candidate.orientation != Orientation::Vertical
                            || !candidate
                                .capabilities
                                .contains(SurfaceCapabilities::CLIMBABLE)
                        {
                            return None;
                        }
                        let SurfaceGeometry::Segment { start, end } = candidate.geometry else {
                            return None;
                        };
                        if (start.y.min(end.y) - top_y).abs() > 1.0 {
                            return None;
                        }
                        let attached_x = start.x + candidate.normal.x * half_width;
                        if (attached_x - body.position.x).abs() > 1.0 {
                            return None;
                        }
                        climb_facing_for_surface(&world, candidate.id)
                    })
                } else {
                    None
                };
                let Some(facing) = facing else {
                    return Err(CompanionPhysicsBindingError::NoClimbableSurface {
                        companion_id: companion_id.to_owned(),
                    });
                };
                if let Ok(mut state) = self.state.write() {
                    state.resting_pose.remove(companion_id);
                    state.climb_facing.insert(companion_id.to_owned(), facing);
                }
                self.enqueue(companion_id, command, physics)
            }
            CompanionMovementCommand::HangLeft
            | CompanionMovementCommand::HangRight
            | CompanionMovementCommand::HangToCenter
            | CompanionMovementCommand::HangToFarEdge
            | CompanionMovementCommand::HangToClimbDownEdge
            | CompanionMovementCommand::Detach => {
                let binding = self.binding(companion_id).ok_or_else(|| {
                    CompanionPhysicsBindingError::UnknownCompanion {
                        companion_id: companion_id.to_owned(),
                    }
                })?;
                let body = physics.body(binding.body_id).ok_or_else(|| {
                    CompanionPhysicsBindingError::UnknownCompanion {
                        companion_id: companion_id.to_owned(),
                    }
                })?;
                let half_width = body.collider.half_extents.width;
                let surface_id = body.attachment.surface_id().ok_or_else(|| {
                    CompanionPhysicsBindingError::AutonomousActionRequiresCurrentMonitorSurface {
                        companion_id: companion_id.to_owned(),
                    }
                })?;
                let world = physics.latest_world_snapshot().ok_or(
                    CompanionPhysicsBindingError::Physics(
                        KernelDesktopPhysicsError::MissingWorldSnapshot,
                    ),
                )?;
                let monitor_owner = world
                    .surfaces
                    .iter()
                    .find(|surface| {
                        surface.id == surface_id && surface.surface_kind == SurfaceKind::MonitorEdge
                    })
                    .and_then(|surface| surface.owner_entity_id);
                if monitor_owner.is_none() {
                    return Err(
                        CompanionPhysicsBindingError::AutonomousActionRequiresCurrentMonitorSurface {
                            companion_id: companion_id.to_owned(),
                        },
                    );
                }
                match command {
                    CompanionMovementCommand::HangLeft
                    | CompanionMovementCommand::HangRight
                    | CompanionMovementCommand::HangToCenter
                    | CompanionMovementCommand::HangToFarEdge
                    | CompanionMovementCommand::HangToClimbDownEdge => {
                        // Move from the vertical monitor side to the horizontal
                        // top owned by that same monitor before traversing. This
                        // preserves G15.1's current-monitor boundary even when an
                        // application WindowTop overlaps the monitor top.
                        let current_surface = world
                            .surfaces
                            .iter()
                            .find(|surface| surface.id == surface_id)
                            .expect("validated monitor-edge surface");
                        let (top_surface_id, left, right, current_x) = if current_surface
                            .orientation
                            == Orientation::Vertical
                        {
                            let top = monitor_hang_top_for_owner(
                                &world,
                                monitor_owner.expect("validated monitor owner"),
                            )
                            .ok_or_else(|| {
                                CompanionPhysicsBindingError::AutonomousActionRequiresCurrentMonitorSurface {
                                    companion_id: companion_id.to_owned(),
                                }
                            })?;
                            let SurfaceGeometry::Segment { start, end } = top.geometry else {
                                unreachable!("monitor hang top is a segment")
                            };
                            let left = start.x.min(end.x) + body.collider.half_extents.width;
                            let right = start.x.max(end.x) - body.collider.half_extents.width;
                            if left > right {
                                return Err(
                                    CompanionPhysicsBindingError::AutonomousActionRequiresCurrentMonitorSurface {
                                        companion_id: companion_id.to_owned(),
                                    },
                                );
                            }
                            let anchor_x = body.position.x.clamp(left, right);
                            let mut top_hanging = body;
                            top_hanging.position = Point2::new(anchor_x, start.y);
                            top_hanging.velocity = Vector2::ZERO;
                            top_hanging.attachment = AttachmentState::Hanging {
                                attachment: SurfaceAttachment {
                                    surface_id: top.id,
                                    anchor: Point2::new(anchor_x, start.y),
                                    normal: top.normal,
                                },
                            };
                            physics.replace_body(binding.body_id, top_hanging)?;
                            (top.id, left, right, anchor_x)
                        } else {
                            if current_surface.orientation != Orientation::Horizontal {
                                return Err(
                                    CompanionPhysicsBindingError::AutonomousActionRequiresCurrentMonitorSurface {
                                        companion_id: companion_id.to_owned(),
                                    },
                                );
                            }
                            let SurfaceGeometry::Segment { start, end } = current_surface.geometry
                            else {
                                unreachable!("validated monitor edge is a segment")
                            };
                            let left = start.x.min(end.x) + body.collider.half_extents.width;
                            let right = start.x.max(end.x) - body.collider.half_extents.width;
                            if left > right {
                                return Err(
                                    CompanionPhysicsBindingError::AutonomousActionRequiresCurrentMonitorSurface {
                                        companion_id: companion_id.to_owned(),
                                    },
                                );
                            }
                            (
                                current_surface.id,
                                left,
                                right,
                                body.position.x.clamp(left, right),
                            )
                        };
                        let midpoint = (left + right) * 0.5;
                        let observed_entry_side = if current_x <= midpoint {
                            HangEntrySide::Left
                        } else {
                            HangEntrySide::Right
                        };
                        let remembered_entry_side = self.state.read().ok().and_then(|state| {
                            state.autonomous_hang_entry_sides.get(companion_id).copied()
                        });
                        let entry_side = remembered_entry_side.unwrap_or(observed_entry_side);
                        let (direction, target_x, facing_override) = match command {
                            CompanionMovementCommand::HangLeft => (WalkDirection::Left, None, None),
                            CompanionMovementCommand::HangRight => {
                                (WalkDirection::Right, None, None)
                            }
                            CompanionMovementCommand::HangToCenter => {
                                let direction = if midpoint >= current_x {
                                    WalkDirection::Right
                                } else {
                                    WalkDirection::Left
                                };
                                (direction, Some(midpoint), None)
                            }
                            CompanionMovementCommand::HangToFarEdge => {
                                let inset = HANG_ROUTE_EDGE_MARGIN.min((right - left) * 0.25);
                                let target = match entry_side {
                                    HangEntrySide::Left => right - inset,
                                    HangEntrySide::Right => left + inset,
                                };
                                let direction = if target >= current_x {
                                    WalkDirection::Right
                                } else {
                                    WalkDirection::Left
                                };
                                (direction, Some(target.clamp(left, right)), None)
                            }
                            CompanionMovementCommand::HangToClimbDownEdge => {
                                let (target, facing) = monitor_climb_down_target_for_owner(
                                    &world,
                                    monitor_owner.expect("validated monitor owner"),
                                    top_surface_id,
                                    half_width,
                                    entry_side,
                                )
                                .ok_or_else(|| {
                                    CompanionPhysicsBindingError::NoClimbableSurface {
                                        companion_id: companion_id.to_owned(),
                                    }
                                })?;
                                let direction = if target >= current_x {
                                    WalkDirection::Right
                                } else {
                                    WalkDirection::Left
                                };
                                (direction, Some(target), Some(facing))
                            }
                            _ => unreachable!("match arm only accepts hang commands"),
                        };
                        if let Ok(mut state) = self.state.write() {
                            state.climb_facing.insert(
                                companion_id.to_owned(),
                                facing_override.unwrap_or(
                                    if matches!(direction, WalkDirection::Left) {
                                        "left"
                                    } else {
                                        "right"
                                    },
                                ),
                            );
                            if let Some(target_x) = target_x {
                                state.autonomous_hang_routes.insert(
                                    companion_id.to_owned(),
                                    AutonomousHangRoute {
                                        surface_id: top_surface_id,
                                        target_x,
                                        direction,
                                    },
                                );
                            } else {
                                state.autonomous_hang_routes.remove(companion_id);
                            }
                            if matches!(command, CompanionMovementCommand::HangToCenter) {
                                state
                                    .autonomous_hang_entry_sides
                                    .insert(companion_id.to_owned(), observed_entry_side);
                            } else if matches!(
                                command,
                                CompanionMovementCommand::HangLeft
                                    | CompanionMovementCommand::HangRight
                            ) {
                                state.autonomous_hang_entry_sides.remove(companion_id);
                            }
                        }
                        physics
                            .enqueue(binding.body_id, PhysicsCommand::HangTraverse { direction })?;
                        Ok(())
                    }
                    CompanionMovementCommand::Detach => {
                        if let Ok(mut state) = self.state.write() {
                            state.autonomous_fall_owner.insert(
                                companion_id.to_owned(),
                                monitor_owner.expect("validated monitor owner"),
                            );
                        }
                        self.enqueue(companion_id, command, physics)
                    }
                    _ => unreachable!("match arm only accepts hang or detach"),
                }
            }
            CompanionMovementCommand::TeleportCurrentMonitor => {
                self.teleport_on_current_monitor_floor(companion_id, physics)
            }
            CompanionMovementCommand::JumpVertical
            | CompanionMovementCommand::JumpLeft
            | CompanionMovementCommand::JumpRight
            | CompanionMovementCommand::TransferLedge => Err(
                CompanionPhysicsBindingError::AutonomousActionRequiresCurrentMonitorSurface {
                    companion_id: companion_id.to_owned(),
                },
            ),
        }
    }

    /// G15.0 guard: Runtime-originated autonomous movement may only walk on
    /// the current desktop floor. Window, taskbar, edge, and airborne states
    /// remain unavailable to this narrow allowlist.
    pub fn enqueue_autonomous_floor_walk(
        &self,
        companion_id: &str,
        command: CompanionMovementCommand,
        physics: &KernelDesktopPhysicsHandle,
    ) -> Result<(), CompanionPhysicsBindingError> {
        if matches!(command, CompanionMovementCommand::Stop) {
            return self.enqueue(companion_id, command, physics);
        }
        if !matches!(
            command,
            CompanionMovementCommand::WalkLeft { .. } | CompanionMovementCommand::WalkRight { .. }
        ) {
            return Err(
                CompanionPhysicsBindingError::AutonomousWalkRequiresDesktopFloor {
                    companion_id: companion_id.to_owned(),
                },
            );
        }
        let binding = self.binding(companion_id).ok_or_else(|| {
            CompanionPhysicsBindingError::UnknownCompanion {
                companion_id: companion_id.to_owned(),
            }
        })?;
        let body = physics.body(binding.body_id).ok_or_else(|| {
            CompanionPhysicsBindingError::UnknownCompanion {
                companion_id: companion_id.to_owned(),
            }
        })?;
        let Some(surface_id) = body.attachment.surface_id() else {
            return Err(
                CompanionPhysicsBindingError::AutonomousWalkRequiresDesktopFloor {
                    companion_id: companion_id.to_owned(),
                },
            );
        };
        let is_desktop_floor = if let Some(world) = physics.latest_world_snapshot() {
            surface_by_id(&world.surfaces, surface_id)
                .is_some_and(|surface| surface.surface_kind == SurfaceKind::DesktopFloor)
        } else {
            false
        };
        if !is_desktop_floor {
            return Err(
                CompanionPhysicsBindingError::AutonomousWalkRequiresDesktopFloor {
                    companion_id: companion_id.to_owned(),
                },
            );
        }
        self.enqueue(companion_id, command, physics)
    }

    fn teleport_on_current_monitor_floor(
        &self,
        companion_id: &str,
        physics: &KernelDesktopPhysicsHandle,
    ) -> Result<(), CompanionPhysicsBindingError> {
        let binding = self.binding(companion_id).ok_or_else(|| {
            CompanionPhysicsBindingError::UnknownCompanion {
                companion_id: companion_id.to_owned(),
            }
        })?;
        let mut body = physics.body(binding.body_id).ok_or_else(|| {
            CompanionPhysicsBindingError::UnknownCompanion {
                companion_id: companion_id.to_owned(),
            }
        })?;
        let surface_id = match body.attachment {
            AttachmentState::Grounded { attachment } => attachment.surface_id,
            _ => {
                return Err(
                    CompanionPhysicsBindingError::AutonomousTeleportRequiresDesktopFloor {
                        companion_id: companion_id.to_owned(),
                    },
                )
            }
        };
        let world =
            physics
                .latest_world_snapshot()
                .ok_or(CompanionPhysicsBindingError::Physics(
                    KernelDesktopPhysicsError::MissingWorldSnapshot,
                ))?;
        let surface = world
            .surfaces
            .iter()
            .find(|surface| surface.id == surface_id)
            .filter(|surface| {
                surface.surface_kind == SurfaceKind::DesktopFloor
                    && surface.owner_entity_id.is_some()
            })
            .ok_or_else(|| {
                CompanionPhysicsBindingError::AutonomousTeleportRequiresDesktopFloor {
                    companion_id: companion_id.to_owned(),
                }
            })?;
        let candidate = surface_candidate(surface).ok_or_else(|| {
            CompanionPhysicsBindingError::AutonomousTeleportRequiresDesktopFloor {
                companion_id: companion_id.to_owned(),
            }
        })?;
        let midpoint = (candidate.left + candidate.right) * 0.5;
        let target_x = if body.position.x <= midpoint {
            candidate.left + (candidate.right - candidate.left) * 0.75
        } else {
            candidate.left + (candidate.right - candidate.left) * 0.25
        }
        .clamp(
            candidate.left + body.collider.half_extents.width,
            candidate.right - body.collider.half_extents.width,
        );
        let feet = Point2::new(target_x, candidate.y);
        body.position = Point2::new(target_x, candidate.y - body.collider.half_extents.height);
        body.velocity = Vector2::ZERO;
        body.acceleration = Vector2::ZERO;
        body.attachment = AttachmentState::Grounded {
            attachment: SurfaceAttachment {
                surface_id,
                anchor: feet,
                normal: candidate.normal,
            },
        };
        physics.replace_body(binding.body_id, body)?;
        if let Ok(mut state) = self.state.write() {
            state.last_feet.insert(companion_id.to_owned(), feet);
            state.climb_hints.remove(companion_id);
            state.climb_facing.remove(companion_id);
            state.resting_pose.remove(companion_id);
            state.autonomous_fall_owner.remove(companion_id);
            state.autonomous_hang_routes.remove(companion_id);
            state.autonomous_hang_entry_sides.remove(companion_id);
        }
        self.publish_authoritative_state(
            companion_id,
            binding.body_id,
            feet,
            Some(SurfaceKind::DesktopFloor),
            "teleport",
        )
    }

    /// An autonomous edge detach is confined to monitor-owned surfaces. The
    /// shared gravity solver may first detect a taskbar or application window;
    /// normalize that landing to the owning monitor floor before Runtime sees
    /// it. User drag clears the marker and therefore keeps its normal policy.
    fn normalize_autonomous_landing(
        &self,
        companion_id: &str,
        body_id: PhysicsBodyId,
        physics: &KernelDesktopPhysicsHandle,
    ) -> Result<bool, CompanionPhysicsBindingError> {
        let monitor_owner = self
            .state
            .read()
            .ok()
            .and_then(|state| state.autonomous_fall_owner.get(companion_id).copied());
        let Some(monitor_owner) = monitor_owner else {
            return Ok(false);
        };
        let mut body = physics.body(body_id).ok_or_else(|| {
            CompanionPhysicsBindingError::UnknownCompanion {
                companion_id: companion_id.to_owned(),
            }
        })?;
        let AttachmentState::Grounded { attachment } = body.attachment else {
            return Ok(false);
        };
        let world =
            physics
                .latest_world_snapshot()
                .ok_or(CompanionPhysicsBindingError::Physics(
                    KernelDesktopPhysicsError::MissingWorldSnapshot,
                ))?;
        let landed_on_current_floor = world.surfaces.iter().any(|surface| {
            surface.id == attachment.surface_id
                && surface.surface_kind == SurfaceKind::DesktopFloor
                && surface.owner_entity_id == Some(monitor_owner)
        });
        if landed_on_current_floor {
            if let Ok(mut state) = self.state.write() {
                state.autonomous_fall_owner.remove(companion_id);
            }
            return Ok(false);
        }
        let floor = world
            .surfaces
            .iter()
            .filter(|surface| {
                surface.surface_kind == SurfaceKind::DesktopFloor
                    && surface.owner_entity_id == Some(monitor_owner)
            })
            .filter_map(surface_candidate)
            .filter(|candidate| {
                candidate.right - candidate.left >= body.collider.half_extents.width * 2.0
            })
            .min_by(|left, right| {
                let left_distance = if body.position.x < left.left {
                    left.left - body.position.x
                } else if body.position.x > left.right {
                    body.position.x - left.right
                } else {
                    0.0
                };
                let right_distance = if body.position.x < right.left {
                    right.left - body.position.x
                } else if body.position.x > right.right {
                    body.position.x - right.right
                } else {
                    0.0
                };
                left_distance.total_cmp(&right_distance)
            })
            .ok_or_else(|| CompanionPhysicsBindingError::NoGroundSurface {
                companion_id: companion_id.to_owned(),
            })?;
        let x = body.position.x.clamp(
            floor.left + body.collider.half_extents.width,
            floor.right - body.collider.half_extents.width,
        );
        let feet = Point2::new(x, floor.y);
        body.position = Point2::new(x, floor.y - body.collider.half_extents.height);
        body.velocity = Vector2::ZERO;
        body.acceleration = Vector2::ZERO;
        body.attachment = AttachmentState::Grounded {
            attachment: SurfaceAttachment {
                surface_id: floor.surface_id,
                anchor: feet,
                normal: floor.normal,
            },
        };
        physics.replace_body(body_id, body)?;
        if let Ok(mut state) = self.state.write() {
            state.autonomous_fall_owner.remove(companion_id);
            state.last_feet.insert(companion_id.to_owned(), feet);
            state.resting_pose.remove(companion_id);
            state.autonomous_hang_routes.remove(companion_id);
            state.autonomous_hang_entry_sides.remove(companion_id);
        }
        self.publish_authoritative_state(
            companion_id,
            body_id,
            feet,
            Some(SurfaceKind::DesktopFloor),
            // Runtime's canonical presentation contract accepts correction as
            // the authoritative snap kind. The former private
            // `autonomous-land` value was discarded by the Rust bridge, leaving
            // the visual animation in fall/land after Physics was grounded.
            "correction",
        )?;
        Ok(true)
    }

    fn rebind_grounded(
        &self,
        companion_id: &str,
        physics: &KernelDesktopPhysicsHandle,
    ) -> Result<CompanionPhysicsBinding, CompanionPhysicsBindingError> {
        let old_binding = self.binding(companion_id).ok_or_else(|| {
            CompanionPhysicsBindingError::UnknownCompanion {
                companion_id: companion_id.to_owned(),
            }
        })?;

        let desired_feet = self
            .state
            .read()
            .ok()
            .and_then(|state| state.last_feet.get(companion_id).copied())
            .unwrap_or_else(|| Point2::new(self.config.default_x, self.config.default_y));

        let world = physics.latest_world_snapshot().ok_or_else(|| {
            CompanionPhysicsBindingError::NoGroundSurface {
                companion_id: companion_id.to_owned(),
            }
        })?;
        let (body, grounded_feet, surface_id) = grounded_body(desired_feet, self.config, &world)
            .ok_or_else(|| CompanionPhysicsBindingError::NoGroundSurface {
                companion_id: companion_id.to_owned(),
            })?;

        let _ = physics.remove_body(old_binding.body_id);
        let body_id = physics.insert_body(body)?;
        let binding = CompanionPhysicsBinding { body_id };

        {
            let mut state =
                self.state
                    .write()
                    .map_err(|_| CompanionPhysicsBindingError::UnknownCompanion {
                        companion_id: companion_id.to_owned(),
                    })?;
            state.by_body.remove(&old_binding.body_id);
            state.by_body.insert(body_id, companion_id.to_owned());
            state.by_companion.insert(companion_id.to_owned(), binding);
            state
                .last_feet
                .insert(companion_id.to_owned(), grounded_feet);
        }

        self.publish(
            COMPANION_PHYSICS_BOUND,
            json!({
                "companionId": companion_id,
                "bodyId": body_id,
                "position": grounded_feet,
                "positionAnchor": "character-feet",
                "surfaceId": surface_id,
                "grounded": true,
                "rebound": true,
            }),
        )?;
        self.publish_authoritative_state(
            companion_id,
            body_id,
            grounded_feet,
            surface_kind_by_id(&world, surface_id),
            "correction",
        )?;

        Ok(binding)
    }

    pub fn commit_authoritative_position(
        &self,
        companion_id: &str,
        requested_feet: Point2,
        physics: &KernelDesktopPhysicsHandle,
    ) -> Result<Point2, CompanionPhysicsBindingError> {
        if !requested_feet.x.is_finite() || !requested_feet.y.is_finite() {
            return Err(CompanionPhysicsBindingError::InvalidPosition {
                companion_id: companion_id.to_owned(),
            });
        }

        let binding = self.binding(companion_id).ok_or_else(|| {
            CompanionPhysicsBindingError::UnknownCompanion {
                companion_id: companion_id.to_owned(),
            }
        })?;
        let world = physics.latest_world_snapshot().ok_or_else(|| {
            CompanionPhysicsBindingError::NoGroundSurface {
                companion_id: companion_id.to_owned(),
            }
        })?;
        let preferred_monitor_owner = physics
            .body(binding.body_id)
            .and_then(|body| monitor_owner_for_attachment(&world, body.attachment.surface_id()));
        let drag_probe = PhysicsBody::new(
            Point2::new(requested_feet.x, requested_feet.y - self.config.half_height),
            AabbCollider::new(self.config.half_width, self.config.half_height),
        );
        let climb_hint =
            nearest_climbable_window_edge(&drag_probe, &world, preferred_monitor_owner).map(
                |(surface_id, anchor_y)| ClimbTargetHint {
                    surface_id,
                    anchor_y,
                    recorded_at: Instant::now(),
                },
            );
        let monitor_or_surface_decision = decide_drag_release_with_preferred_monitor(
            requested_feet,
            &world.surfaces,
            self.config.half_width,
            preferred_monitor_owner,
        );
        let decision =
            if monitor_or_surface_decision.target_kind == DragReleaseTargetKind::MonitorEdge {
                monitor_or_surface_decision
            } else if let Some(active_window_decision) =
                active_window_drag_release(requested_feet, &world, self.config.half_width)
            {
                active_window_decision
            } else if monitor_or_surface_decision.target_kind == DragReleaseTargetKind::WindowTop {
                // WindowTop is a deliberate active-window interaction. A
                // generic surface fallback can otherwise attach to an
                // inactive or short-lived auxiliary HWND and briefly publish
                // `sitting` before Desktop World removes that surface.
                let non_window_surfaces = world
                    .surfaces
                    .iter()
                    .filter(|surface| surface.surface_kind != SurfaceKind::WindowTop)
                    .cloned()
                    .collect::<Vec<_>>();
                decide_drag_release_with_preferred_monitor(
                    requested_feet,
                    &non_window_surfaces,
                    self.config.half_width,
                    preferred_monitor_owner,
                )
            } else {
                monitor_or_surface_decision
            };
        let (mut body, resolved_feet, grounded) =
            body_for_drag_release(decision, requested_feet, self.config, &world).ok_or_else(
                || CompanionPhysicsBindingError::NoGroundSurface {
                    companion_id: companion_id.to_owned(),
                },
            )?;
        body.id = binding.body_id;
        physics.replace_body(binding.body_id, body)?;

        if physics_debug_enabled() {
            eprintln!(
                "[physics-debug] phase=drag-release companion={} body={:?} requested=({:.1},{:.1}) resolved=({:.1},{:.1}) target={:?} surface={:?} climb_hint={:?} body_identity=preserved",
                companion_id,
                binding.body_id,
                requested_feet.x,
                requested_feet.y,
                resolved_feet.x,
                resolved_feet.y,
                decision.target_kind,
                decision.surface_id,
                climb_hint.map(|hint| (hint.surface_id, hint.anchor_y)),
            );
        }

        if let Ok(mut state) = self.state.write() {
            state
                .last_feet
                .insert(companion_id.to_owned(), resolved_feet);
            if let Some(hint) = climb_hint {
                state.climb_hints.insert(companion_id.to_owned(), hint);
            } else {
                state.climb_hints.remove(companion_id);
            }
            if decision.target_kind == DragReleaseTargetKind::WindowTop {
                state
                    .resting_pose
                    .insert(companion_id.to_owned(), "sitting");
            } else {
                state.resting_pose.remove(companion_id);
            }
            // A user drag always supersedes an in-flight autonomous detach.
            state.autonomous_fall_owner.remove(companion_id);
            state.autonomous_hang_routes.remove(companion_id);
            state.autonomous_hang_entry_sides.remove(companion_id);
        }

        let sequence = self.next_sequence();
        let revision = self.next_revision();
        let facing = decision
            .surface_id
            .and_then(|surface_id| climb_facing_for_surface(&world, surface_id))
            .unwrap_or("unchanged");
        let movement_state = if decision.target_kind == DragReleaseTargetKind::WindowTop {
            "sitting"
        } else if decision.target_kind == DragReleaseTargetKind::MonitorEdge {
            "climb-ready"
        } else if grounded {
            "stationary"
        } else {
            "airborne-falling"
        };
        if physics_debug_enabled() {
            eprintln!(
                "[physics-debug] phase=drag-presentation companion={} target={:?} movement_state={} resolved=({:.1},{:.1}) body_identity=preserved",
                companion_id,
                decision.target_kind,
                movement_state,
                resolved_feet.x,
                resolved_feet.y,
            );
        }
        self.publish_presentation_state(
            companion_id,
            binding.body_id,
            resolved_feet,
            Vector2::ZERO,
            grounded,
            movement_state,
            facing,
            decision.target_kind.attachment_state(),
            decision
                .surface_id
                .and_then(|surface_id| surface_kind_by_id(&world, surface_id)),
            "drag-commit",
            sequence,
            revision,
        )?;
        self.publish(
            COMPANION_MOVED,
            json!({
                "companionId": companion_id,
                "bodyId": binding.body_id,
                "position": {
                    "space": "desktop-logical",
                    "anchor": "character-feet",
                    "x": resolved_feet.x,
                    "y": resolved_feet.y,
                },
                "velocity": { "x": 0.0, "y": 0.0 },
                "grounded": grounded,
                "movementState": movement_state,
                "facing": facing,
                "attachmentState": decision.target_kind.attachment_state(),
                "surfaceId": decision.surface_id,
                "releaseTarget": format!("{:?}", decision.target_kind),
                "motion": if grounded {
                    "authoritative-snap"
                } else {
                    "authoritative-release"
                },
                "sequence": sequence,
                "revision": revision,
            }),
        )?;

        Ok(resolved_feet)
    }

    fn publish_authoritative_state(
        &self,
        companion_id: &str,
        body_id: PhysicsBodyId,
        feet: Point2,
        surface_kind: Option<SurfaceKind>,
        update_kind: &str,
    ) -> Result<(), CompanionPhysicsBindingError> {
        let sequence = self.next_sequence();
        let revision = self.next_revision();

        self.publish_presentation_state(
            companion_id,
            body_id,
            feet,
            Vector2::ZERO,
            true,
            "stationary",
            "unchanged",
            "grounded",
            surface_kind,
            update_kind,
            sequence,
            revision,
        )?;

        self.publish(
            COMPANION_MOVED,
            json!({
                "companionId": companion_id,
                "bodyId": body_id,
                "position": {
                    "space": "desktop-logical",
                    "anchor": "character-feet",
                    "x": feet.x,
                    "y": feet.y,
                },
                "velocity": {
                    "x": 0.0,
                    "y": 0.0,
                },
                "grounded": true,
                "movementState": "stationary",
                "motion": if update_kind == "teleport" {
                    "teleport"
                } else {
                    "authoritative-snap"
                },
                "sequence": sequence,
                "revision": revision,
            }),
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn publish_presentation_state(
        &self,
        companion_id: &str,
        body_id: PhysicsBodyId,
        feet: Point2,
        velocity: Vector2,
        grounded: bool,
        movement_state: &str,
        facing: &str,
        attachment_state: &str,
        surface_kind: Option<SurfaceKind>,
        update_kind: &str,
        sequence: u64,
        revision: u64,
    ) -> Result<(), CompanionPhysicsBindingError> {
        self.publish(
            COMPANION_PRESENTATION_STATE,
            json!({
                "schemaVersion": COMPANION_PRESENTATION_SCHEMA_VERSION,
                "companionId": companion_id,
                "bodyId": body_id,
                "sequence": sequence,
                "revision": revision,
                "desktopFeet": {
                    "space": "desktop-logical",
                    "anchor": "character-feet",
                    "x": feet.x,
                    "y": feet.y,
                },
                "velocity": {
                    "x": velocity.x,
                    "y": velocity.y,
                },
                "grounded": grounded,
                "movementState": movement_state,
                "attachmentState": attachment_state,
                "surfaceKind": surface_kind.map(surface_kind_name),
                "facing": facing,
                "updateKind": update_kind,
            }),
        )
    }

    fn next_sequence(&self) -> u64 {
        self.movement_sequence
            .fetch_add(1, Ordering::Relaxed)
            .saturating_add(1)
    }

    fn next_revision(&self) -> u64 {
        self.presentation_revision
            .fetch_add(1, Ordering::Relaxed)
            .saturating_add(1)
    }

    pub fn translate_character_moved(
        &self,
        event: &Envelope,
        physics: &KernelDesktopPhysicsHandle,
    ) -> Option<Envelope> {
        if event.event_type != "ocp.character.moved" {
            return None;
        }

        let body_id =
            serde_json::from_value::<PhysicsBodyId>(event.data.get("body_id")?.clone()).ok()?;
        let companion_id = self.companion_id(body_id)?;
        if self
            .complete_autonomous_hang_route(&companion_id, body_id, physics)
            .unwrap_or(false)
        {
            return None;
        }
        if self
            .normalize_autonomous_landing(&companion_id, body_id, physics)
            .unwrap_or(false)
        {
            return None;
        }
        let position = event.data.get("position")?;
        let velocity = event.data.get("velocity")?;
        let x = position.get("x")?.as_f64()?;
        let center_y = position.get("y")?.as_f64()?;
        let velocity_x = velocity.get("x")?.as_f64()?;
        let velocity_y = velocity.get("y")?.as_f64()?;
        let feet_y = center_y + f64::from(self.config.half_height);
        let canonical_state = event.data.get("state").and_then(Value::as_str);
        let (grounded, mut movement_state, attachment_state) = match canonical_state {
            Some("idle") => (true, "stationary", "grounded"),
            Some("walking") => (true, "walking", "grounded"),
            // Desktop Physics keeps a body attached to the wall when a climb
            // reaches its lower endpoint and reports zero velocity. Present
            // that stable attached state as climb-ready; reserving climbing
            // for actual vertical motion prevents climb animations looping at
            // the endpoint.
            Some("climbing") => (
                false,
                if velocity_y.abs() <= 0.001 && velocity_x.abs() <= 0.001 {
                    "climb-ready"
                } else {
                    "climbing"
                },
                "attached",
            ),
            Some("hanging") => (false, "hanging", "hanging"),
            Some("airborne") => (
                false,
                if velocity_y < -0.001 {
                    "airborne-rising"
                } else {
                    "airborne-falling"
                },
                "airborne",
            ),
            _ => {
                let grounded = velocity_y.abs() <= 0.001;
                let movement_state = if velocity_y < -0.001 {
                    "airborne-rising"
                } else if velocity_y > 0.001 {
                    "airborne-falling"
                } else if velocity_x.abs() > 0.001 {
                    "walking"
                } else {
                    "stationary"
                };
                (
                    grounded,
                    movement_state,
                    if grounded { "grounded" } else { "airborne" },
                )
            }
        };
        // A window attachment is only a presentation hint while the canonical body
        // remains grounded on that surface. Once Physics reports the body airborne,
        // the former sitting pose must not survive the subsequent landing. Otherwise
        // minimizing or closing the window produces fall -> sitting instead of
        // fall -> land -> stationary.
        if canonical_state == Some("airborne") {
            if let Ok(mut state) = self.state.write() {
                state.resting_pose.remove(&companion_id);
            }
        }
        if movement_state == "stationary" {
            movement_state = self
                .state
                .read()
                .ok()
                .and_then(|state| state.resting_pose.get(&companion_id).copied())
                .unwrap_or(movement_state);
        }
        if let Ok(mut state) = self.state.write() {
            state
                .last_feet
                .insert(companion_id.clone(), Point2::new(x as f32, feet_y as f32));
        }

        let sequence = self.next_sequence();
        let revision = self.next_revision();

        if physics_debug_full() {
            eprintln!(
                "[physics-debug] phase=movement companion={} body={:?}                  sequence={} feet=({:.1},{:.1}) velocity=({:.1},{:.1})                  grounded={} movement_state={} motion=continuous",
                companion_id,
                body_id,
                sequence,
                x,
                feet_y,
                velocity_x,
                velocity_y,
                grounded,
                movement_state,
            );
        }

        let facing = if matches!(canonical_state, Some("climbing") | Some("hanging")) {
            self.state
                .read()
                .ok()
                .and_then(|state| state.climb_facing.get(&companion_id).copied())
                .unwrap_or("unchanged")
        } else if velocity_x < -0.001 {
            "left"
        } else if velocity_x > 0.001 {
            "right"
        } else {
            "unchanged"
        };
        let surface_kind = surface_kind_for_body(physics, body_id);
        let _ = self.publish_presentation_state(
            &companion_id,
            body_id,
            Point2::new(x as f32, feet_y as f32),
            Vector2::new(velocity_x as f32, velocity_y as f32),
            grounded,
            movement_state,
            facing,
            attachment_state,
            surface_kind,
            "continuous",
            sequence,
            revision,
        );

        Envelope::new(
            COMPANION_MOVED,
            COMPANION_PHYSICS_SOURCE,
            json!({
                "companionId": companion_id,
                "bodyId": body_id,
                "position": {
                    "space": "desktop-logical",
                    "anchor": "character-feet",
                    "x": x,
                    "y": feet_y,
                },
                "velocity": {
                    "x": velocity_x,
                    "y": velocity_y,
                },
                "grounded": grounded,
                "movementState": movement_state,
                "attachmentState": attachment_state,
                "motion": "continuous",
                "sequence": sequence,
                "revision": revision,
            }),
        )
        .ok()
    }

    /// Kernel owns semantic hang endpoints. Clamp on the first canonical body
    /// snapshot that reaches the target, then stop the Physics motor and emit
    /// the resulting zero-velocity hanging snapshot. The direct body replace
    /// does not itself produce a later motion event, so Runtime needs this
    /// authoritative arrival fact to advance either into hang settling or the
    /// visible corner route that precedes autonomous climb-down.
    fn complete_autonomous_hang_route(
        &self,
        companion_id: &str,
        body_id: PhysicsBodyId,
        physics: &KernelDesktopPhysicsHandle,
    ) -> Result<bool, CompanionPhysicsBindingError> {
        let route = self
            .state
            .read()
            .ok()
            .and_then(|state| state.autonomous_hang_routes.get(companion_id).copied());
        let Some(route) = route else {
            return Ok(false);
        };
        let mut body = physics.body(body_id).ok_or_else(|| {
            CompanionPhysicsBindingError::UnknownCompanion {
                companion_id: companion_id.to_owned(),
            }
        })?;
        let AttachmentState::Hanging { mut attachment } = body.attachment else {
            if let Ok(mut state) = self.state.write() {
                state.autonomous_hang_routes.remove(companion_id);
                state.autonomous_hang_entry_sides.remove(companion_id);
            }
            return Ok(false);
        };
        if attachment.surface_id != route.surface_id {
            if let Ok(mut state) = self.state.write() {
                state.autonomous_hang_routes.remove(companion_id);
                state.autonomous_hang_entry_sides.remove(companion_id);
            }
            return Ok(false);
        }
        let reached = match route.direction {
            WalkDirection::Left => body.position.x <= route.target_x,
            WalkDirection::Right => body.position.x >= route.target_x,
        };
        if !reached {
            return Ok(false);
        }
        body.position.x = route.target_x;
        body.velocity = Vector2::ZERO;
        attachment.anchor.x = route.target_x;
        body.attachment = AttachmentState::Hanging { attachment };
        let mut state =
            self.state
                .write()
                .map_err(|_| CompanionPhysicsBindingError::UnknownCompanion {
                    companion_id: companion_id.to_owned(),
                })?;
        if state.autonomous_hang_routes.get(companion_id).copied() != Some(route) {
            return Ok(false);
        }
        // Keep the route state locked while stopping the motor and updating
        // the canonical body. A subsequent route request queues after this
        // Stop and cannot be cancelled by this older callback.
        let feet = Point2::new(route.target_x, body.position.y + self.config.half_height);
        physics.enqueue(body_id, PhysicsCommand::Stop)?;
        physics.replace_body(body_id, body)?;
        state.autonomous_hang_routes.remove(companion_id);
        state.last_feet.insert(companion_id.to_owned(), feet);
        let facing = state
            .climb_facing
            .get(companion_id)
            .copied()
            .unwrap_or("unchanged");
        drop(state);

        let sequence = self.next_sequence();
        let revision = self.next_revision();
        let surface_kind = surface_kind_for_body(physics, body_id);
        self.publish_presentation_state(
            companion_id,
            body_id,
            feet,
            Vector2::ZERO,
            false,
            "hanging",
            facing,
            "hanging",
            surface_kind,
            "route-arrived",
            sequence,
            revision,
        )?;
        self.publish(
            COMPANION_MOVED,
            json!({
                "companionId": companion_id,
                "bodyId": body_id,
                "position": {
                    "space": "desktop-logical",
                    "anchor": "character-feet",
                    "x": feet.x,
                    "y": feet.y,
                },
                "velocity": { "x": 0.0, "y": 0.0 },
                "grounded": false,
                "movementState": "hanging",
                "attachmentState": "hanging",
                "motion": "continuous",
                "sequence": sequence,
                "revision": revision,
            }),
        )?;
        Ok(true)
    }

    pub fn start_motion_bridge(&self, physics: KernelDesktopPhysicsHandle) -> JoinHandle<()> {
        let receiver = self.bus.subscribe("ocp.character.moved");
        let bindings = self.clone();
        let bus = self.bus.clone();

        thread::spawn(move || {
            while let Ok(event) = receiver.recv() {
                if let Some(translated) = bindings.translate_character_moved(&event, &physics) {
                    let _ = bus.publish(translated);
                }
            }
        })
    }

    fn publish(
        &self,
        event_type: &str,
        data: serde_json::Value,
    ) -> Result<(), CompanionPhysicsBindingError> {
        let envelope =
            Envelope::new(event_type, COMPANION_PHYSICS_SOURCE, data).map_err(BusError::Invalid)?;

        self.bus.publish(envelope)?;
        Ok(())
    }
}

fn surface_kind_by_id(world: &DesktopWorldSnapshot, surface_id: SurfaceId) -> Option<SurfaceKind> {
    world
        .surfaces
        .iter()
        .find(|surface| surface.id == surface_id)
        .map(|surface| surface.surface_kind)
}

fn surface_kind_for_body(
    physics: &KernelDesktopPhysicsHandle,
    body_id: PhysicsBodyId,
) -> Option<SurfaceKind> {
    let surface_id = physics.body(body_id)?.attachment.surface_id()?;
    let world = physics.latest_world_snapshot()?;
    surface_kind_by_id(&world, surface_id)
}

const fn surface_kind_name(kind: SurfaceKind) -> &'static str {
    match kind {
        SurfaceKind::DesktopFloor => "desktop_floor",
        SurfaceKind::MonitorEdge => "monitor_edge",
        SurfaceKind::WindowTop => "window_top",
        SurfaceKind::WindowLeft => "window_left",
        SurfaceKind::WindowRight => "window_right",
        SurfaceKind::WindowBottom => "window_bottom",
        SurfaceKind::TaskbarTop => "taskbar_top",
        SurfaceKind::DockTop => "dock_top",
        SurfaceKind::WidgetEdge => "widget_edge",
        SurfaceKind::FloatingPanelEdge => "floating_panel_edge",
        SurfaceKind::Custom => "custom",
    }
}

#[derive(Debug, Clone, Copy)]
struct GroundCandidate {
    surface_id: SurfaceId,
    surface_kind: SurfaceKind,
    left: f32,
    right: f32,
    y: f32,
    normal: Vector2,
}

fn command_requires_ground(command: CompanionMovementCommand) -> bool {
    matches!(
        command,
        CompanionMovementCommand::WalkLeft { .. }
            | CompanionMovementCommand::WalkRight { .. }
            | CompanionMovementCommand::JumpVertical
            | CompanionMovementCommand::JumpLeft
            | CompanionMovementCommand::JumpRight
    )
}

fn nearest_climbable_window_edge(
    body: &PhysicsBody,
    world: &DesktopWorldSnapshot,
    preferred_monitor_owner: Option<WorldEntityId>,
) -> Option<(SurfaceId, f32)> {
    const ATTACH_MARGIN: f32 = 16.0;
    let maximum_distance = body.collider.half_extents.width + ATTACH_MARGIN;

    world
        .surfaces
        .iter()
        .filter_map(|surface| {
            if surface.orientation != Orientation::Vertical
                || !matches!(
                    surface.surface_kind,
                    SurfaceKind::WindowLeft | SurfaceKind::WindowRight | SurfaceKind::MonitorEdge
                )
                || !surface
                    .capabilities
                    .contains(SurfaceCapabilities::CLIMBABLE)
            {
                return None;
            }
            let SurfaceGeometry::Segment { start, end } = &surface.geometry else {
                return None;
            };
            let top = start.y.min(end.y);
            let bottom = start.y.max(end.y);
            if body.position.y < top || body.position.y > bottom {
                return None;
            }
            let distance = (start.x - body.position.x).abs();
            (distance <= maximum_distance).then_some((
                distance,
                u8::from(
                    preferred_monitor_owner.is_some()
                        && surface.owner_entity_id != preferred_monitor_owner,
                ),
                start.x,
                top,
                surface.id,
                body.position.y.clamp(top, bottom),
            ))
        })
        .min_by(|left, right| {
            left.0
                .total_cmp(&right.0)
                .then_with(|| left.1.cmp(&right.1))
                .then_with(|| left.2.total_cmp(&right.2))
                .then_with(|| left.3.total_cmp(&right.3))
        })
        .map(|(_, _, _, _, surface_id, anchor_y)| (surface_id, anchor_y))
}

fn nearest_climbable_monitor_edge(
    body: &PhysicsBody,
    world: &DesktopWorldSnapshot,
    monitor_owner: WorldEntityId,
) -> Option<(SurfaceId, f32)> {
    const ATTACH_MARGIN: f32 = 16.0;
    let maximum_distance = body.collider.half_extents.width + ATTACH_MARGIN;

    world
        .surfaces
        .iter()
        .filter_map(|surface| {
            if surface.orientation != Orientation::Vertical
                || surface.surface_kind != SurfaceKind::MonitorEdge
                || surface.owner_entity_id != Some(monitor_owner)
                || !surface
                    .capabilities
                    .contains(SurfaceCapabilities::CLIMBABLE)
            {
                return None;
            }
            let SurfaceGeometry::Segment { start, end } = surface.geometry else {
                return None;
            };
            let top = start.y.min(end.y);
            let bottom = start.y.max(end.y);
            if body.position.y < top || body.position.y > bottom {
                return None;
            }
            let distance = (start.x - body.position.x).abs();
            (distance <= maximum_distance).then_some((
                distance,
                start.x,
                surface.id,
                body.position.y.clamp(top, bottom),
            ))
        })
        .min_by(|left, right| {
            left.0
                .total_cmp(&right.0)
                .then_with(|| left.1.total_cmp(&right.1))
                .then_with(|| left.2.cmp(&right.2))
        })
        .map(|(_, _, surface_id, anchor_y)| (surface_id, anchor_y))
}

fn monitor_hang_top_for_owner(
    world: &DesktopWorldSnapshot,
    monitor_owner: WorldEntityId,
) -> Option<&SurfaceDescriptor> {
    world.surfaces.iter().find(|surface| {
        surface.surface_kind == SurfaceKind::MonitorEdge
            && surface.owner_entity_id == Some(monitor_owner)
            && surface.orientation == Orientation::Horizontal
            && surface.capabilities.contains(SurfaceCapabilities::HANGABLE)
            && matches!(surface.geometry, SurfaceGeometry::Segment { .. })
    })
}

fn monitor_climb_down_target_for_owner(
    world: &DesktopWorldSnapshot,
    monitor_owner: WorldEntityId,
    top_surface_id: SurfaceId,
    half_width: f32,
    entry_side: HangEntrySide,
) -> Option<(f32, &'static str)> {
    const CORNER_EPSILON: f32 = 1.0;
    let top = world.surfaces.iter().find(|surface| {
        surface.id == top_surface_id
            && surface.surface_kind == SurfaceKind::MonitorEdge
            && surface.owner_entity_id == Some(monitor_owner)
            && surface.orientation == Orientation::Horizontal
            && surface.capabilities.contains(SurfaceCapabilities::HANGABLE)
    })?;
    let SurfaceGeometry::Segment { start, end } = top.geometry else {
        return None;
    };
    let top_y = start.y;
    let left = start.x.min(end.x) + half_width;
    let right = start.x.max(end.x) - half_width;

    world
        .surfaces
        .iter()
        .filter_map(|surface| {
            if surface.surface_kind != SurfaceKind::MonitorEdge
                || surface.owner_entity_id != Some(monitor_owner)
                || surface.orientation != Orientation::Vertical
                || !surface
                    .capabilities
                    .contains(SurfaceCapabilities::CLIMBABLE)
            {
                return None;
            }
            let SurfaceGeometry::Segment { start, end } = surface.geometry else {
                return None;
            };
            if (start.y.min(end.y) - top_y).abs() > CORNER_EPSILON {
                return None;
            }
            let attached_x = start.x + surface.normal.x * half_width;
            if attached_x < left - CORNER_EPSILON || attached_x > right + CORNER_EPSILON {
                return None;
            }
            let facing = if surface.normal.x > 0.0 {
                "right"
            } else if surface.normal.x < 0.0 {
                "left"
            } else {
                return None;
            };
            Some((attached_x.clamp(left, right), facing))
        })
        .reduce(|current, candidate| match entry_side {
            HangEntrySide::Left => {
                if candidate.0 > current.0 {
                    candidate
                } else {
                    current
                }
            }
            HangEntrySide::Right => {
                if candidate.0 < current.0 {
                    candidate
                } else {
                    current
                }
            }
        })
}

fn monitor_owner_for_attachment(
    world: &DesktopWorldSnapshot,
    surface_id: Option<SurfaceId>,
) -> Option<WorldEntityId> {
    let surface_id = surface_id?;
    world
        .surfaces
        .iter()
        .find(|surface| surface.id == surface_id)
        .filter(|surface| {
            matches!(
                surface.surface_kind,
                SurfaceKind::DesktopFloor | SurfaceKind::MonitorEdge
            )
        })
        .and_then(|surface| surface.owner_entity_id)
}

fn climbable_window_edge_by_id(world: &DesktopWorldSnapshot, surface_id: SurfaceId) -> bool {
    world.surfaces.iter().any(|surface| {
        surface.id == surface_id
            && surface.orientation == Orientation::Vertical
            && matches!(
                surface.surface_kind,
                SurfaceKind::WindowLeft | SurfaceKind::WindowRight | SurfaceKind::MonitorEdge
            )
            && surface
                .capabilities
                .contains(SurfaceCapabilities::CLIMBABLE)
    })
}

fn climb_facing_for_surface(
    world: &DesktopWorldSnapshot,
    surface_id: SurfaceId,
) -> Option<&'static str> {
    world
        .surfaces
        .iter()
        .find(|surface| surface.id == surface_id)
        .and_then(|surface| match surface.surface_kind {
            SurfaceKind::WindowLeft => Some("right"),
            SurfaceKind::WindowRight => Some("left"),
            SurfaceKind::MonitorEdge if surface.normal.x > 0.0 => Some("right"),
            SurfaceKind::MonitorEdge if surface.normal.x < 0.0 => Some("left"),
            _ => None,
        })
}

fn active_window_drag_release(
    requested_feet: Point2,
    world: &DesktopWorldSnapshot,
    half_width: f32,
) -> Option<DragReleaseDecision> {
    // The pointer moves the native host, while the canonical point represents
    // the character's feet near the bottom of that host. 48 logical pixels
    // was too narrow for a user to place the visible character on a title-bar
    // edge reliably, especially with tall character profiles. Keep this in
    // canonical logical units so monitor DPI does not alter the policy.
    const WINDOW_TOP_SNAP_DISTANCE: f32 = 96.0;
    // WindowTop attachment is reserved for the OS-reported active window.
    // Native companion and auxiliary windows use NOACTIVATE, so they must not
    // replace the user's active application during drag.
    let active = world
        .active_window_id
        .and_then(|id| world.windows.iter().find(|window| window.id == id))
        .or_else(|| world.windows.iter().find(|window| window.active));
    let Some(active) = active else {
        if physics_debug_enabled() {
            eprintln!(
                "[physics-debug] phase=window-top-rejected reason=no-active-window requested=({:.1},{:.1})",
                requested_feet.x, requested_feet.y,
            );
        }
        return None;
    };
    if active.minimized || !active.visible || active.occluded {
        if physics_debug_enabled() {
            eprintln!(
                "[physics-debug] phase=window-top-rejected reason=window-unavailable active={:?} minimized={} visible={} occluded={}",
                active.id, active.minimized, active.visible, active.occluded,
            );
        }
        return None;
    }
    let frame = active.frame_bounds.unwrap_or(active.bounds);
    if world.monitors.iter().any(|monitor| {
        let work_area = monitor.work_area.0;
        frame.left() <= work_area.left()
            && frame.top() <= work_area.top()
            && frame.right() >= work_area.right()
            && frame.bottom() >= work_area.bottom()
    }) {
        // Maximized/full-work-area windows intentionally have no ledge. The
        // release falls to the monitor floor/taskbar instead of sitting.
        if physics_debug_enabled() {
            eprintln!(
                "[physics-debug] phase=window-top-rejected reason=maximized active={:?} frame=({:.1},{:.1},{:.1},{:.1})",
                active.id,
                frame.left(),
                frame.top(),
                frame.right(),
                frame.bottom(),
            );
        }
        return None;
    }
    if requested_feet.x < frame.left() + half_width
        || requested_feet.x > frame.right() - half_width
        || (requested_feet.y - frame.top()).abs() > WINDOW_TOP_SNAP_DISTANCE
    {
        if physics_debug_enabled() {
            eprintln!(
                "[physics-debug] phase=window-top-rejected reason=outside-snap-band active={:?} requested=({:.1},{:.1}) frame=({:.1},{:.1},{:.1},{:.1}) snap_distance={:.1}",
                active.id,
                requested_feet.x,
                requested_feet.y,
                frame.left(),
                frame.top(),
                frame.right(),
                frame.bottom(),
                WINDOW_TOP_SNAP_DISTANCE,
            );
        }
        return None;
    }
    let surface = world.surfaces.iter().find(|surface| {
        surface.surface_kind == SurfaceKind::WindowTop
            && surface.owner_entity_id == Some(active.entity_id)
    });
    let Some(surface) = surface else {
        if physics_debug_enabled() {
            eprintln!(
                "[physics-debug] phase=window-top-rejected reason=surface-missing active={:?} entity={:?}",
                active.id, active.entity_id,
            );
        }
        return None;
    };
    let SurfaceGeometry::Segment { start, end } = surface.geometry else {
        return None;
    };
    let left = start.x.min(end.x);
    let right = start.x.max(end.x);
    let y = start.y;
    if requested_feet.x < left + half_width || requested_feet.x > right - half_width {
        return None;
    }
    Some(DragReleaseDecision {
        target_kind: DragReleaseTargetKind::WindowTop,
        resolved_feet: Point2::new(requested_feet.x, y),
        surface_id: Some(surface.id),
    })
}

fn body_for_drag_release(
    decision: DragReleaseDecision,
    requested_feet: Point2,
    config: CompanionPhysicsBodyConfig,
    world: &DesktopWorldSnapshot,
) -> Option<(PhysicsBody, Point2, bool)> {
    match decision.target_kind {
        DragReleaseTargetKind::Airborne => {
            let center = Point2::new(requested_feet.x, requested_feet.y - config.half_height);
            let body = PhysicsBody::new(
                center,
                AabbCollider::new(config.half_width, config.half_height),
            );
            Some((body, requested_feet, false))
        }
        DragReleaseTargetKind::WindowTop
        | DragReleaseTargetKind::TaskbarTop
        | DragReleaseTargetKind::DesktopFloor => {
            let surface_id = decision.surface_id?;
            let surface = surface_by_id(&world.surfaces, surface_id)?;
            let candidate = surface_candidate(surface)?;
            let feet = decision.resolved_feet;
            let center = Point2::new(feet.x, feet.y - config.half_height);
            let mut body = PhysicsBody::new(
                center,
                AabbCollider::new(config.half_width, config.half_height),
            );
            body.attachment = AttachmentState::Grounded {
                attachment: SurfaceAttachment {
                    surface_id,
                    anchor: feet,
                    normal: candidate.normal,
                },
            };
            Some((body, feet, true))
        }
        DragReleaseTargetKind::MonitorEdge => {
            let surface_id = decision.surface_id?;
            let surface = surface_by_id(&world.surfaces, surface_id)?;
            if surface.orientation != Orientation::Vertical
                || !surface.capabilities.contains(SurfaceCapabilities::HANGABLE)
            {
                return None;
            }
            let SurfaceGeometry::Segment { start, end } = surface.geometry else {
                return None;
            };
            let top = start.y.min(end.y);
            let bottom = start.y.max(end.y);
            let anchor_y = requested_feet.y.clamp(top, bottom);
            let edge_x = start.x;
            let center_x = edge_x + surface.normal.x * config.half_width;
            let center = Point2::new(center_x, anchor_y);
            let mut body = PhysicsBody::new(
                center,
                AabbCollider::new(config.half_width, config.half_height),
            );
            body.attachment = AttachmentState::Attached {
                attachment: SurfaceAttachment {
                    surface_id,
                    anchor: Point2::new(edge_x, anchor_y),
                    normal: surface.normal,
                },
            };
            let feet = Point2::new(center.x, center.y + config.half_height);
            Some((body, feet, false))
        }
    }
}

fn grounded_body(
    desired_feet: Point2,
    config: CompanionPhysicsBodyConfig,
    world: &DesktopWorldSnapshot,
) -> Option<(PhysicsBody, Point2, SurfaceId)> {
    let candidates: Vec<GroundCandidate> = world
        .surfaces
        .iter()
        .filter_map(surface_candidate)
        .filter(|surface| surface.right - surface.left >= config.half_width * 2.0)
        .collect();

    let candidate = candidates.iter().copied().min_by(|left, right| {
        ground_score(*left, desired_feet, config).total_cmp(&ground_score(
            *right,
            desired_feet,
            config,
        ))
    })?;

    if physics_debug_enabled() {
        eprintln!(
            "[physics-debug] phase=ground-select desired_feet=({:.1},{:.1})              surface_id={:?} surface_kind={:?} bounds=({:.1},{:.1},{:.1})              score={:.1} candidate_count={}",
            desired_feet.x,
            desired_feet.y,
            candidate.surface_id,
            candidate.surface_kind,
            candidate.left,
            candidate.y,
            candidate.right,
            ground_score(candidate, desired_feet, config),
            candidates.len(),
        );
    }

    let x = desired_feet.x.clamp(
        candidate.left + config.half_width,
        candidate.right - config.half_width,
    );
    let feet = Point2::new(x, candidate.y);
    let center = Point2::new(x, candidate.y - config.half_height);
    let mut body = PhysicsBody::new(
        center,
        AabbCollider::new(config.half_width, config.half_height),
    );
    body.attachment = AttachmentState::Grounded {
        attachment: SurfaceAttachment {
            surface_id: candidate.surface_id,
            anchor: feet,
            normal: candidate.normal,
        },
    };

    Some((body, feet, candidate.surface_id))
}

fn surface_candidate(surface: &SurfaceDescriptor) -> Option<GroundCandidate> {
    if surface.orientation != Orientation::Horizontal
        || surface.normal.y >= 0.0
        || !surface.capabilities.contains(SurfaceCapabilities::LANDABLE)
        || !surface.capabilities.contains(SurfaceCapabilities::WALKABLE)
    {
        return None;
    }

    let (start, end) = match surface.geometry {
        SurfaceGeometry::Segment { start, end } => (start, end),
        SurfaceGeometry::Rectangle { rect } => (
            Point2::new(rect.left(), rect.top()),
            Point2::new(rect.right(), rect.top()),
        ),
        SurfaceGeometry::Point { .. } => return None,
    };

    Some(GroundCandidate {
        surface_id: surface.id,
        surface_kind: surface.surface_kind,
        left: start.x.min(end.x),
        right: start.x.max(end.x),
        y: start.y,
        normal: surface.normal,
    })
}

fn ground_score(
    surface: GroundCandidate,
    desired_feet: Point2,
    config: CompanionPhysicsBodyConfig,
) -> f32 {
    let usable_left = surface.left + config.half_width;
    let usable_right = surface.right - config.half_width;
    let resolved_x = desired_feet.x.clamp(usable_left, usable_right);
    let horizontal_distance = (resolved_x - desired_feet.x).abs();
    let vertical_delta = surface.y - desired_feet.y;
    let vertical_distance = vertical_delta.abs();
    let contains_x = desired_feet.x >= usable_left && desired_feet.x <= usable_right;

    // Runtime 0.1 uses the desktop floor as its stable baseline. Window tops
    // remain valid Physics surfaces for later navigation features, but they
    // must not steal initial bind, drag commit, or post-surface recovery from
    // the monitor floor merely because they are closer in Y.
    let kind_penalty = if surface.surface_kind == SurfaceKind::DesktopFloor {
        0.0
    } else {
        100_000.0
    };

    // Prefer the monitor whose usable X range contains the requested feet.
    // This is essential for virtual desktops with negative monitor origins.
    let horizontal_penalty = if contains_x {
        0.0
    } else {
        10_000.0 + horizontal_distance * 10.0
    };

    // A floor above the requested feet is suspicious during bind/drag recovery.
    // It can cause the visible "jump upward before walking" failure.
    let above_penalty = if vertical_delta < -2.0 {
        50_000.0 + vertical_distance * 10.0
    } else {
        0.0
    };

    kind_penalty + horizontal_penalty + above_penalty + vertical_distance
}

fn physics_debug_enabled() -> bool {
    std::env::var("OCP_PHYSICS_DEBUG")
        .ok()
        .is_some_and(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on" | "full" | "summary"
            )
        })
}

fn physics_debug_full() -> bool {
    std::env::var("OCP_PHYSICS_DEBUG")
        .ok()
        .is_some_and(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on" | "full"
            )
        })
}

fn env_f32(name: &str, default: f32) -> f32 {
    std::env::var(name)
        .ok()
        .and_then(|value| value.trim().parse().ok())
        .filter(|value: &f32| value.is_finite() && *value > 0.0)
        .unwrap_or(default)
}
