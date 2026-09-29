use crate::world_query::PhysicsSurface;
use crate::{
    AirborneController, AttachmentError, AttachmentState, AttachmentTransition, ClimbConfig,
    ClimbDirection, DesktopPhysicsSolver, JumpDirection, JumpError, JumpMotor, LedgeTransferError,
    LedgeTransferSolver, PhysicsBody, PhysicsBodyId, PhysicsStepResult, PhysicsWorldQuery,
    SurfaceAttachmentSolver, WalkConfig, WalkDirection, WalkEdgeBehavior, WalkError, WalkMotor,
};
use ocp_shared_types::{surface::SurfaceGeometry, Point2, SurfaceDescriptor, SurfaceId};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, VecDeque};
use std::fmt;
use std::time::Duration;

// Runtime locomotion uses small acceleration/deceleration ramps so native window
// movement does not jump from rest to full speed in a single 120 Hz tick. The
// underlying motors keep their existing deterministic contracts; only Runtime
// feeds them a bounded per-body speed.
const WALK_TARGET_SPEED: f32 = 140.0;
const WALK_ACCELERATION: f32 = 900.0;
const WALK_DECELERATION: f32 = 1_200.0;
const CLIMB_TARGET_SPEED: f32 = 120.0;
const CLIMB_ACCELERATION: f32 = 700.0;
const CLIMB_DECELERATION: f32 = 900.0;
// Hanging should read as deliberate hand-over-hand movement rather than reuse
// the faster floor-walk pace. Keep this independent from WalkConfig so each
// character package can tune its visual hang FPS without changing physics.
const HANG_TRAVERSE_SPEED: f32 = 84.0;
const HANG_ACCELERATION: f32 = 450.0;
const HANG_DECELERATION: f32 = 650.0;
const LOCOMOTION_STOP_EPSILON: f32 = 0.5;

fn approach_speed(current: f32, target: f32, acceleration: f32, deceleration: f32, dt: f32) -> f32 {
    if (current - target).abs() <= LOCOMOTION_STOP_EPSILON {
        return target;
    }
    let rate = if target > current {
        acceleration
    } else {
        deceleration
    };
    let delta = rate.max(0.0) * dt.max(0.0);
    if current < target {
        (current + delta).min(target)
    } else {
        (current - delta).max(target)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "command")]
pub enum PhysicsCommand {
    Walk {
        direction: WalkDirection,
        edge_behavior: WalkEdgeBehavior,
    },
    Climb {
        direction: ClimbDirection,
    },
    HangTraverse {
        direction: WalkDirection,
    },
    Jump {
        direction: JumpDirection,
    },
    AttachVertical {
        surface_id: SurfaceId,
        anchor_y: f32,
    },
    TransferLedge,
    Detach,
    Stop,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeBodyState {
    Idle,
    Walking,
    Climbing,
    Airborne,
    Hanging,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RuntimeBodySnapshot {
    pub body_id: PhysicsBodyId,
    pub position: Point2,
    pub velocity: ocp_shared_types::Vector2,
    pub state: RuntimeBodyState,
    pub attachment_surface_id: Option<SurfaceId>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PhysicsFrameResult {
    pub frame_index: u64,
    pub simulated_steps: u32,
    pub bodies: Vec<RuntimeBodySnapshot>,
    pub transitions: Vec<RuntimeTransition>,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "kind")]
pub enum RuntimeTransition {
    Attachment {
        body_id: PhysicsBodyId,
        transition: AttachmentTransition,
    },
    Landed {
        body_id: PhysicsBodyId,
        surface_id: SurfaceId,
    },
    CommandRejected {
        body_id: PhysicsBodyId,
        command: PhysicsCommand,
    },
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FixedStepConfig {
    pub step: Duration,
    pub max_catch_up_steps: u32,
}

impl Default for FixedStepConfig {
    fn default() -> Self {
        Self {
            // Presentation can run on 120 Hz desktop displays and the native
            // host polls at ~8 ms. Keep canonical Physics at the same cadence
            // so visual movement does not advance in visible 60 Hz steps while
            // higher-frame-rate Character/3 animation is playing.
            step: Duration::from_micros(8_333),
            // Preserve roughly the same catch-up time budget as the former
            // 60 Hz / 8-step configuration (~133 ms).
            max_catch_up_steps: 16,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PhysicsRuntimeError {
    BodyNotFound { body_id: PhysicsBodyId },
    DuplicateBody { body_id: PhysicsBodyId },
}

impl fmt::Display for PhysicsRuntimeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BodyNotFound { body_id } => {
                write!(formatter, "physics body not found: {body_id:?}")
            }
            Self::DuplicateBody { body_id } => {
                write!(formatter, "duplicate physics body: {body_id:?}")
            }
        }
    }
}

impl std::error::Error for PhysicsRuntimeError {}

#[derive(Debug, Clone)]
struct RuntimeBody {
    body: PhysicsBody,
    state: RuntimeBodyState,
    queued_commands: VecDeque<PhysicsCommand>,
    active_walk: Option<(WalkDirection, WalkEdgeBehavior)>,
    active_climb: Option<ClimbDirection>,
    active_hang: Option<WalkDirection>,
    walk_speed: f32,
    climb_speed: f32,
    hang_speed: f32,
    stop_requested: bool,
}

pub struct DesktopPhysicsRuntime {
    fixed_step: FixedStepConfig,
    accumulator: Duration,
    frame_index: u64,
    bodies: BTreeMap<PhysicsBodyId, RuntimeBody>,
    physics: DesktopPhysicsSolver,
    walk: WalkMotor,
    climb: SurfaceAttachmentSolver,
    jump: JumpMotor,
    airborne: AirborneController,
    ledge: LedgeTransferSolver,
}

impl DesktopPhysicsRuntime {
    #[must_use]
    pub fn new(fixed_step: FixedStepConfig) -> Self {
        Self {
            fixed_step,
            accumulator: Duration::ZERO,
            frame_index: 0,
            bodies: BTreeMap::new(),
            physics: DesktopPhysicsSolver::default(),
            walk: WalkMotor::default(),
            climb: SurfaceAttachmentSolver::default(),
            jump: JumpMotor::default(),
            airborne: AirborneController::default(),
            ledge: LedgeTransferSolver::default(),
        }
    }

    pub fn insert_body(&mut self, body: PhysicsBody) -> Result<PhysicsBodyId, PhysicsRuntimeError> {
        let body_id = body.id;
        if self.bodies.contains_key(&body_id) {
            return Err(PhysicsRuntimeError::DuplicateBody { body_id });
        }

        self.bodies.insert(
            body_id,
            RuntimeBody {
                state: state_from_body(&body),
                body,
                queued_commands: VecDeque::new(),
                active_walk: None,
                active_climb: None,
                active_hang: None,
                walk_speed: 0.0,
                climb_speed: 0.0,
                hang_speed: 0.0,
                stop_requested: false,
            },
        );

        Ok(body_id)
    }

    pub fn remove_body(
        &mut self,
        body_id: PhysicsBodyId,
    ) -> Result<PhysicsBody, PhysicsRuntimeError> {
        self.bodies
            .remove(&body_id)
            .map(|runtime_body| runtime_body.body)
            .ok_or(PhysicsRuntimeError::BodyNotFound { body_id })
    }

    pub fn enqueue(
        &mut self,
        body_id: PhysicsBodyId,
        command: PhysicsCommand,
    ) -> Result<(), PhysicsRuntimeError> {
        let runtime_body = self
            .bodies
            .get_mut(&body_id)
            .ok_or(PhysicsRuntimeError::BodyNotFound { body_id })?;

        // Locomotion commands are authoritative and coalesced. Without this,
        // an older Walk command can remain queued behind Stop or a newer Walk
        // command and resume movement in the wrong direction several ticks later.
        if matches!(
            command,
            PhysicsCommand::Walk { .. } | PhysicsCommand::Climb { .. } | PhysicsCommand::Stop
        ) {
            runtime_body.queued_commands.retain(|queued| {
                !matches!(
                    queued,
                    PhysicsCommand::Walk { .. }
                        | PhysicsCommand::Climb { .. }
                        | PhysicsCommand::Stop
                )
            });
        }

        runtime_body.queued_commands.push_back(command);
        Ok(())
    }

    #[must_use]
    pub fn body(&self, body_id: PhysicsBodyId) -> Option<&PhysicsBody> {
        self.bodies.get(&body_id).map(|item| &item.body)
    }

    /// Move attached bodies with a dynamic surface after Desktop World
    /// reports that surface's geometry moved. Missing surfaces are left for
    /// the solver to detach and fall on the next tick.
    pub fn follow_surface_geometry(
        &mut self,
        previous: &[SurfaceDescriptor],
        current: &[SurfaceDescriptor],
    ) {
        for runtime_body in self.bodies.values_mut() {
            let Some(attachment) = runtime_body.body.attachment.attachment() else {
                continue;
            };
            let (Some(old_surface), Some(new_surface)) = (
                previous
                    .iter()
                    .find(|surface| surface.id == attachment.surface_id),
                current
                    .iter()
                    .find(|surface| surface.id == attachment.surface_id),
            ) else {
                continue;
            };
            let (
                SurfaceGeometry::Segment {
                    start: old_start, ..
                },
                SurfaceGeometry::Segment {
                    start: new_start, ..
                },
            ) = (&old_surface.geometry, &new_surface.geometry)
            else {
                continue;
            };
            let delta = Point2::new(new_start.x - old_start.x, new_start.y - old_start.y);
            if delta.x.abs() <= f32::EPSILON && delta.y.abs() <= f32::EPSILON {
                continue;
            }
            runtime_body.body.position.x += delta.x;
            runtime_body.body.position.y += delta.y;
            let moved = attachment.anchor;
            let anchor = Point2::new(moved.x + delta.x, moved.y + delta.y);
            let updated = crate::SurfaceAttachment {
                surface_id: attachment.surface_id,
                anchor,
                normal: attachment.normal,
            };
            runtime_body.body.attachment = match runtime_body.body.attachment {
                AttachmentState::Grounded { .. } => AttachmentState::Grounded {
                    attachment: updated,
                },
                AttachmentState::Attached { .. } => AttachmentState::Attached {
                    attachment: updated,
                },
                AttachmentState::Hanging { .. } => AttachmentState::Hanging {
                    attachment: updated,
                },
                AttachmentState::Detached => AttachmentState::Detached,
            };
        }
    }

    pub fn replace_body(
        &mut self,
        body_id: PhysicsBodyId,
        mut body: PhysicsBody,
    ) -> Result<(), PhysicsRuntimeError> {
        let runtime_body = self
            .bodies
            .get_mut(&body_id)
            .ok_or(PhysicsRuntimeError::BodyNotFound { body_id })?;

        body.id = body_id;
        runtime_body.body = body;
        runtime_body.state = state_from_body(&runtime_body.body);
        runtime_body.queued_commands.clear();
        runtime_body.active_walk = None;
        runtime_body.active_climb = None;
        runtime_body.active_hang = None;
        runtime_body.walk_speed = 0.0;
        runtime_body.climb_speed = 0.0;
        runtime_body.hang_speed = 0.0;
        runtime_body.stop_requested = false;
        Ok(())
    }

    pub fn tick(&mut self, delta: Duration, world: &impl PhysicsWorldQuery) -> PhysicsFrameResult {
        self.accumulator += delta;

        let mut simulated_steps = 0;
        let mut transitions = Vec::new();

        while self.accumulator >= self.fixed_step.step
            && simulated_steps < self.fixed_step.max_catch_up_steps
        {
            self.simulate_one_step(world, &mut transitions);
            self.accumulator -= self.fixed_step.step;
            simulated_steps += 1;
        }

        if simulated_steps == self.fixed_step.max_catch_up_steps
            && self.accumulator >= self.fixed_step.step
        {
            self.accumulator = Duration::ZERO;
        }

        self.frame_index += 1;

        PhysicsFrameResult {
            frame_index: self.frame_index,
            simulated_steps,
            bodies: self.bodies.values().map(snapshot).collect(),
            transitions,
        }
    }

    fn simulate_one_step(
        &mut self,
        world: &impl PhysicsWorldQuery,
        transitions: &mut Vec<RuntimeTransition>,
    ) {
        for runtime_body in self.bodies.values_mut() {
            if let Some(command) = runtime_body.queued_commands.pop_front() {
                match command {
                    PhysicsCommand::Walk {
                        direction,
                        edge_behavior,
                    } => {
                        if runtime_body.active_walk.map(|(active, _)| active) != Some(direction) {
                            runtime_body.walk_speed = 0.0;
                        }
                        runtime_body.active_climb = None;
                        runtime_body.active_hang = None;
                        runtime_body.climb_speed = 0.0;
                        runtime_body.hang_speed = 0.0;
                        runtime_body.stop_requested = false;
                        runtime_body.active_walk = Some((direction, edge_behavior));
                    }
                    PhysicsCommand::Climb { direction } => {
                        if runtime_body.active_climb != Some(direction) {
                            runtime_body.climb_speed = 0.0;
                        }
                        runtime_body.active_walk = None;
                        runtime_body.active_hang = None;
                        runtime_body.walk_speed = 0.0;
                        runtime_body.hang_speed = 0.0;
                        runtime_body.stop_requested = false;
                        runtime_body.active_climb = Some(direction);
                    }
                    PhysicsCommand::HangTraverse { direction } => {
                        if runtime_body.active_hang != Some(direction) {
                            runtime_body.hang_speed = 0.0;
                        }
                        runtime_body.active_walk = None;
                        runtime_body.active_climb = None;
                        runtime_body.walk_speed = 0.0;
                        runtime_body.climb_speed = 0.0;
                        runtime_body.stop_requested = false;
                        runtime_body.active_hang = Some(direction);
                    }
                    PhysicsCommand::Stop => {
                        // Keep the current locomotion intent alive briefly while
                        // its speed eases to zero. This preserves authoritative
                        // Stop semantics without snapping the native window in a
                        // single frame.
                        runtime_body.stop_requested = true;
                        if runtime_body.active_walk.is_none()
                            && runtime_body.active_climb.is_none()
                            && runtime_body.active_hang.is_none()
                        {
                            runtime_body.body.velocity = ocp_shared_types::Vector2::ZERO;
                            runtime_body.stop_requested = false;
                        }

                        // Stop is authoritative. Remove stale locomotion work so
                        // an older queued Walk cannot restart on the next step.
                        runtime_body.queued_commands.retain(|queued| {
                            !matches!(
                                queued,
                                PhysicsCommand::Walk { .. }
                                    | PhysicsCommand::Climb { .. }
                                    | PhysicsCommand::HangTraverse { .. }
                                    | PhysicsCommand::Stop
                            )
                        });
                    }
                    _ => {
                        runtime_body.active_walk = None;
                        runtime_body.active_climb = None;
                        runtime_body.active_hang = None;
                        runtime_body.walk_speed = 0.0;
                        runtime_body.climb_speed = 0.0;
                        runtime_body.hang_speed = 0.0;
                        runtime_body.stop_requested = false;
                        if !apply_command(
                            runtime_body,
                            command,
                            self.fixed_step.step,
                            world,
                            &self.walk,
                            &self.climb,
                            &self.jump,
                            &self.ledge,
                            transitions,
                        ) {
                            transitions.push(RuntimeTransition::CommandRejected {
                                body_id: runtime_body.body.id,
                                command,
                            });
                        }
                    }
                }
            }

            if let Some(direction) = runtime_body.active_climb {
                let command = PhysicsCommand::Climb { direction };
                let dt = self.fixed_step.step.as_secs_f32();
                let target_speed = if runtime_body.stop_requested {
                    0.0
                } else {
                    CLIMB_TARGET_SPEED
                };
                runtime_body.climb_speed = approach_speed(
                    runtime_body.climb_speed,
                    target_speed,
                    CLIMB_ACCELERATION,
                    CLIMB_DECELERATION,
                    dt,
                );
                if runtime_body.stop_requested
                    && runtime_body.climb_speed <= LOCOMOTION_STOP_EPSILON
                {
                    runtime_body.climb_speed = 0.0;
                    runtime_body.active_climb = None;
                    runtime_body.body.velocity = ocp_shared_types::Vector2::ZERO;
                    runtime_body.stop_requested = false;
                } else {
                    let corner_ready = direction != ClimbDirection::Down
                        || prepare_top_hang_for_climb_down(&mut runtime_body.body, world);
                    let climb_motor = SurfaceAttachmentSolver::new(ClimbConfig {
                        speed: runtime_body.climb_speed.max(LOCOMOTION_STOP_EPSILON),
                        ..ClimbConfig::default()
                    });
                    let result = if corner_ready {
                        climb_motor.climb(
                            &mut runtime_body.body,
                            direction,
                            self.fixed_step.step,
                            world,
                        )
                    } else {
                        Err(AttachmentError::BodyNotAttached)
                    };
                    match result {
                        Ok(result) => {
                            if result.transition != AttachmentTransition::None {
                                transitions.push(RuntimeTransition::Attachment {
                                    body_id: runtime_body.body.id,
                                    transition: result.transition,
                                });
                            }
                            if result.reached_endpoint {
                                runtime_body.active_climb = None;
                                runtime_body.climb_speed = 0.0;
                                runtime_body.stop_requested = false;
                            }
                        }
                        Err(_) => {
                            runtime_body.active_climb = None;
                            runtime_body.climb_speed = 0.0;
                            runtime_body.stop_requested = false;
                            transitions.push(RuntimeTransition::CommandRejected {
                                body_id: runtime_body.body.id,
                                command,
                            });
                        }
                    }
                }
            }

            if let Some((direction, edge_behavior)) = runtime_body.active_walk {
                let command = PhysicsCommand::Walk {
                    direction,
                    edge_behavior,
                };
                let dt = self.fixed_step.step.as_secs_f32();
                let target_speed = if runtime_body.stop_requested {
                    0.0
                } else {
                    WALK_TARGET_SPEED
                };
                runtime_body.walk_speed = approach_speed(
                    runtime_body.walk_speed,
                    target_speed,
                    WALK_ACCELERATION,
                    WALK_DECELERATION,
                    dt,
                );
                if runtime_body.stop_requested && runtime_body.walk_speed <= LOCOMOTION_STOP_EPSILON
                {
                    runtime_body.walk_speed = 0.0;
                    runtime_body.active_walk = None;
                    runtime_body.body.velocity = ocp_shared_types::Vector2::ZERO;
                    runtime_body.stop_requested = false;
                } else {
                    let walk_motor = WalkMotor::new(WalkConfig {
                        speed: runtime_body.walk_speed.max(LOCOMOTION_STOP_EPSILON),
                        ..WalkConfig::default()
                    });
                    match walk_motor.step(
                        &mut runtime_body.body,
                        direction,
                        edge_behavior,
                        self.fixed_step.step,
                        world,
                    ) {
                        Ok(result) => {
                            if result.attachment_transition != AttachmentTransition::None {
                                transitions.push(RuntimeTransition::Attachment {
                                    body_id: runtime_body.body.id,
                                    transition: result.attachment_transition,
                                });
                            }

                            // StopAtEdge is terminal for the active walk. The motor
                            // already clamps the body and sets velocity to zero; the
                            // runtime must also clear the persistent intent or the same
                            // edge step (and its diagnostic log) repeats every tick.
                            if matches!(
                                result.state,
                                crate::WalkStepState::StoppedAtEdge
                                    | crate::WalkStepState::SurfaceLost
                                    | crate::WalkStepState::WalkedOff
                            ) || matches!(
                                runtime_body.body.attachment,
                                crate::AttachmentState::Detached
                            ) {
                                runtime_body.active_walk = None;
                                runtime_body.walk_speed = 0.0;
                                runtime_body.stop_requested = false;
                            }
                        }
                        Err(
                            WalkError::BodyNotGrounded
                            | WalkError::SurfaceNotHorizontal { .. }
                            | WalkError::SurfaceNotWalkable { .. }
                            | WalkError::SurfaceTooNarrow { .. },
                        ) => {
                            runtime_body.active_walk = None;
                            runtime_body.walk_speed = 0.0;
                            runtime_body.stop_requested = false;
                            transitions.push(RuntimeTransition::CommandRejected {
                                body_id: runtime_body.body.id,
                                command,
                            });
                        }
                    }
                }
            }

            if let Some(direction) = runtime_body.active_hang {
                let command = PhysicsCommand::HangTraverse { direction };
                let dt = self.fixed_step.step.as_secs_f32();
                let target_speed = if runtime_body.stop_requested {
                    0.0
                } else {
                    HANG_TRAVERSE_SPEED
                };
                runtime_body.hang_speed = approach_speed(
                    runtime_body.hang_speed,
                    target_speed,
                    HANG_ACCELERATION,
                    HANG_DECELERATION,
                    dt,
                );
                if runtime_body.stop_requested && runtime_body.hang_speed <= LOCOMOTION_STOP_EPSILON
                {
                    runtime_body.hang_speed = 0.0;
                    runtime_body.active_hang = None;
                    runtime_body.body.velocity = ocp_shared_types::Vector2::ZERO;
                    runtime_body.stop_requested = false;
                } else if !hang_traverse(
                    &mut runtime_body.body,
                    direction,
                    runtime_body.hang_speed.max(LOCOMOTION_STOP_EPSILON),
                    self.fixed_step.step,
                    world,
                ) {
                    runtime_body.active_hang = None;
                    runtime_body.hang_speed = 0.0;
                    runtime_body.stop_requested = false;
                    transitions.push(RuntimeTransition::CommandRejected {
                        body_id: runtime_body.body.id,
                        command,
                    });
                } else if runtime_body.body.velocity.x.abs() <= f32::EPSILON {
                    // Reaching either end of the top edge is a successful,
                    // terminal traversal. Keep the body hanging at the corner
                    // but clear the persistent intent so it does not execute
                    // the same zero-distance command on every fixed step.
                    runtime_body.active_hang = None;
                    runtime_body.hang_speed = 0.0;
                    runtime_body.stop_requested = false;
                }
            }

            if matches!(
                runtime_body.body.attachment,
                crate::AttachmentState::Detached
            ) {
                runtime_body.active_climb = None;
                runtime_body.active_hang = None;
                runtime_body.climb_speed = 0.0;
                runtime_body.hang_speed = 0.0;
                runtime_body.stop_requested = false;
                let result = self.airborne.step(
                    &mut runtime_body.body,
                    self.fixed_step.step,
                    world,
                    &self.physics,
                );
                if result.landed {
                    if let Some(surface_id) = result.landed_surface_id {
                        transitions.push(RuntimeTransition::Landed {
                            body_id: runtime_body.body.id,
                            surface_id,
                        });
                    }
                }
            } else {
                let result = self
                    .physics
                    .step(&mut runtime_body.body, self.fixed_step.step, world);
                collect_physics_transition(runtime_body.body.id, &result, transitions);
            }

            runtime_body.state = state_from_body(&runtime_body.body);
        }
    }
}

impl Default for DesktopPhysicsRuntime {
    fn default() -> Self {
        Self::new(FixedStepConfig::default())
    }
}

#[allow(clippy::too_many_arguments)]
fn apply_command(
    runtime_body: &mut RuntimeBody,
    command: PhysicsCommand,
    step: Duration,
    world: &impl PhysicsWorldQuery,
    walk: &WalkMotor,
    climb: &SurfaceAttachmentSolver,
    jump: &JumpMotor,
    ledge: &LedgeTransferSolver,
    transitions: &mut Vec<RuntimeTransition>,
) -> bool {
    let body_id = runtime_body.body.id;

    let transition = match command {
        PhysicsCommand::Walk {
            direction,
            edge_behavior,
        } => match walk.step(
            &mut runtime_body.body,
            direction,
            edge_behavior,
            step,
            world,
        ) {
            Ok(result) => Some(result.attachment_transition),
            Err(WalkError::BodyNotGrounded)
            | Err(WalkError::SurfaceNotHorizontal { .. })
            | Err(WalkError::SurfaceNotWalkable { .. })
            | Err(WalkError::SurfaceTooNarrow { .. }) => return false,
        },
        PhysicsCommand::Climb { direction } => {
            match climb.climb(&mut runtime_body.body, direction, step, world) {
                Ok(result) => Some(result.transition),
                Err(AttachmentError::BodyNotAttached)
                | Err(AttachmentError::SurfaceNotFound { .. })
                | Err(AttachmentError::SurfaceNotVertical { .. })
                | Err(AttachmentError::SurfaceNotClimbable { .. })
                | Err(AttachmentError::AttachedSurfaceChanged { .. }) => return false,
            }
        }
        PhysicsCommand::HangTraverse { direction } => {
            if hang_traverse(
                &mut runtime_body.body,
                direction,
                HANG_TRAVERSE_SPEED,
                step,
                world,
            ) {
                Some(AttachmentTransition::None)
            } else {
                return false;
            }
        }
        PhysicsCommand::Jump { direction } => {
            match jump.start_jump(&mut runtime_body.body, direction) {
                Ok(result) => Some(result.attachment_transition),
                Err(JumpError::BodyNotGrounded) => return false,
            }
        }
        PhysicsCommand::AttachVertical {
            surface_id,
            anchor_y,
        } => match climb.attach_to_vertical_surface(
            &mut runtime_body.body,
            surface_id,
            anchor_y,
            world,
        ) {
            Ok(result) => Some(result),
            Err(_) => return false,
        },
        PhysicsCommand::TransferLedge => {
            match ledge.transfer_hanging_to_grounded(&mut runtime_body.body, world) {
                Ok(result) => Some(result.transition),
                Err(LedgeTransferError::BodyNotHanging)
                | Err(LedgeTransferError::SourceSurfaceNotFound { .. })
                | Err(LedgeTransferError::SourceSurfaceNotVertical { .. })
                | Err(LedgeTransferError::NoLandableLedge { .. }) => return false,
            }
        }
        PhysicsCommand::Detach => Some(climb.detach(&mut runtime_body.body)),
        PhysicsCommand::Stop => {
            runtime_body.body.velocity = ocp_shared_types::Vector2::ZERO;
            None
        }
    };

    if let Some(transition) = transition {
        if transition != AttachmentTransition::None {
            transitions.push(RuntimeTransition::Attachment {
                body_id,
                transition,
            });
        }
    }

    true
}

fn hang_traverse(
    body: &mut PhysicsBody,
    direction: WalkDirection,
    speed: f32,
    step: Duration,
    world: &impl PhysicsWorldQuery,
) -> bool {
    let AttachmentState::Hanging { attachment } = body.attachment else {
        return false;
    };
    let Some(mut surface) = world.surface(attachment.surface_id) else {
        return false;
    };
    if surface.orientation == ocp_shared_types::Orientation::Vertical {
        let top = surface.start.y.min(surface.end.y);
        if (body.position.y - top).abs() > 1.0 {
            return false;
        }
        let candidates = world.candidate_surfaces(
            Point2::new(body.position.x - 2.0, top - 2.0),
            Point2::new(body.position.x + 2.0, top + 2.0),
        );
        let is_hangable_horizontal_at_top = |candidate: &PhysicsSurface| {
            candidate.orientation == ocp_shared_types::Orientation::Horizontal
                && candidate
                    .capabilities
                    .contains(ocp_shared_types::SurfaceCapabilities::HANGABLE)
                && (candidate.start.y - top).abs() <= 1.0
        };
        // Prefer the horizontal ledge owned by the same window/monitor as the
        // vertical surface being climbed. Without owner affinity, a monitor-top
        // surface can win when it overlaps the window-top Y coordinate, causing
        // the companion to hang against the wrong surface.
        let preferred_kind = match surface.kind {
            ocp_shared_types::SurfaceKind::WindowLeft
            | ocp_shared_types::SurfaceKind::WindowRight => {
                Some(ocp_shared_types::SurfaceKind::WindowTop)
            }
            ocp_shared_types::SurfaceKind::MonitorEdge => {
                Some(ocp_shared_types::SurfaceKind::MonitorEdge)
            }
            _ => None,
        };
        // Prefer the horizontal continuation belonging to the same surface
        // family. In particular, a window side must attach to WindowTop rather
        // than an overlapping monitor-top surface at the same Y coordinate.
        let top_surface = candidates
            .iter()
            .find(|candidate| {
                is_hangable_horizontal_at_top(candidate)
                    && preferred_kind.is_some_and(|kind| candidate.kind == kind)
            })
            .copied()
            .or_else(|| candidates.into_iter().find(is_hangable_horizontal_at_top));
        let Some(top_surface) = top_surface else {
            return false;
        };
        surface = top_surface;
        let left = surface.start.x.min(surface.end.x) + body.collider.half_extents.width;
        let right = surface.start.x.max(surface.end.x) - body.collider.half_extents.width;
        if left > right {
            return false;
        }
        let anchor_x = body.position.x.clamp(left, right);
        body.position.x = anchor_x;
        body.position.y = surface.start.y;
        body.velocity = ocp_shared_types::Vector2::ZERO;
        body.attachment = AttachmentState::Hanging {
            attachment: crate::SurfaceAttachment {
                surface_id: surface.id,
                anchor: Point2::new(anchor_x, surface.start.y),
                normal: surface.normal,
            },
        };
    }
    if surface.orientation != ocp_shared_types::Orientation::Horizontal
        || !surface
            .capabilities
            .contains(ocp_shared_types::SurfaceCapabilities::HANGABLE)
    {
        return false;
    }
    let left = surface.start.x.min(surface.end.x) + body.collider.half_extents.width;
    let right = surface.start.x.max(surface.end.x) - body.collider.half_extents.width;
    if left > right {
        return false;
    }
    let distance = speed * step.as_secs_f32();
    let requested = match direction {
        WalkDirection::Left => body.position.x - distance,
        WalkDirection::Right => body.position.x + distance,
    };
    let next_x = requested.clamp(left, right);
    body.position.x = next_x;
    body.position.y = surface.start.y;
    body.velocity = ocp_shared_types::Vector2::new(
        if next_x == requested {
            match direction {
                WalkDirection::Left => -speed,
                WalkDirection::Right => speed,
            }
        } else {
            0.0
        },
        0.0,
    );
    body.attachment = AttachmentState::Hanging {
        attachment: crate::SurfaceAttachment {
            surface_id: surface.id,
            anchor: Point2::new(next_x, surface.start.y),
            normal: surface.normal,
        },
    };
    true
}

fn prepare_top_hang_for_climb_down(body: &mut PhysicsBody, world: &impl PhysicsWorldQuery) -> bool {
    let AttachmentState::Hanging { attachment } = body.attachment else {
        return true;
    };
    let Some(top_surface) = world.surface(attachment.surface_id) else {
        return false;
    };
    if top_surface.orientation == ocp_shared_types::Orientation::Vertical {
        return true;
    }
    if top_surface.orientation != ocp_shared_types::Orientation::Horizontal {
        return false;
    }

    let half_width = body.collider.half_extents.width;
    let epsilon = 1.0_f32;
    let top_y = top_surface.start.y;
    let search_from = Point2::new(body.position.x - half_width - epsilon, top_y - epsilon);
    let search_to = Point2::new(body.position.x + half_width + epsilon, top_y + epsilon);
    let candidate = world
        .candidate_surfaces(search_from, search_to)
        .into_iter()
        .filter(|surface| {
            surface.orientation == ocp_shared_types::Orientation::Vertical
                && surface
                    .capabilities
                    .contains(ocp_shared_types::SurfaceCapabilities::CLIMBABLE)
                && (surface.start.y.min(surface.end.y) - top_y).abs() <= epsilon
        })
        .filter_map(|surface| {
            let attached_x = surface.start.x + surface.normal.x * half_width;
            let distance = (attached_x - body.position.x).abs();
            (distance <= epsilon).then_some((surface, attached_x, distance))
        })
        .min_by(|left, right| left.2.total_cmp(&right.2));

    let Some((wall, attached_x, _)) = candidate else {
        return false;
    };
    body.position = Point2::new(attached_x, top_y);
    body.velocity = ocp_shared_types::Vector2::ZERO;
    body.attachment = AttachmentState::Attached {
        attachment: crate::SurfaceAttachment {
            surface_id: wall.id,
            anchor: Point2::new(wall.start.x, top_y),
            normal: wall.normal,
        },
    };
    true
}

fn collect_physics_transition(
    body_id: PhysicsBodyId,
    result: &PhysicsStepResult,
    transitions: &mut Vec<RuntimeTransition>,
) {
    if result.attachment_transition != AttachmentTransition::None {
        transitions.push(RuntimeTransition::Attachment {
            body_id,
            transition: result.attachment_transition,
        });
    }
}

fn state_from_body(body: &PhysicsBody) -> RuntimeBodyState {
    match body.attachment {
        crate::AttachmentState::Grounded { .. } => {
            if body.velocity.x.abs() > f32::EPSILON {
                RuntimeBodyState::Walking
            } else {
                RuntimeBodyState::Idle
            }
        }
        crate::AttachmentState::Attached { .. } => RuntimeBodyState::Climbing,
        crate::AttachmentState::Hanging { .. } => RuntimeBodyState::Hanging,
        crate::AttachmentState::Detached => RuntimeBodyState::Airborne,
    }
}

fn snapshot(runtime_body: &RuntimeBody) -> RuntimeBodySnapshot {
    RuntimeBodySnapshot {
        body_id: runtime_body.body.id,
        position: runtime_body.body.position,
        velocity: runtime_body.body.velocity,
        state: runtime_body.state,
        attachment_surface_id: runtime_body.body.attachment.surface_id(),
    }
}
