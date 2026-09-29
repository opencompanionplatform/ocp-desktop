use crate::{AttachmentState, AttachmentTransition, PhysicsBody, PhysicsWorldQuery};
use ocp_shared_types::{Point2, SurfaceId, Vector2};
use serde::{Deserialize, Serialize};
use std::fmt;
use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct JumpConfig {
    pub jump_speed: f32,
    pub horizontal_speed: f32,
}

impl Default for JumpConfig {
    fn default() -> Self {
        Self {
            jump_speed: 620.0,
            horizontal_speed: 180.0,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JumpDirection {
    Vertical,
    Left,
    Right,
}

impl JumpDirection {
    #[must_use]
    pub const fn horizontal_sign(self) -> f32 {
        match self {
            Self::Vertical => 0.0,
            Self::Left => -1.0,
            Self::Right => 1.0,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JumpError {
    BodyNotGrounded,
}

impl fmt::Display for JumpError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BodyNotGrounded => formatter.write_str("body is not grounded"),
        }
    }
}

impl std::error::Error for JumpError {}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct JumpStartResult {
    pub previous_position: Point2,
    pub position: Point2,
    pub velocity: Vector2,
    pub source_surface_id: SurfaceId,
    pub attachment_transition: AttachmentTransition,
}

#[derive(Debug, Clone, Copy)]
pub struct JumpMotor {
    config: JumpConfig,
}

impl JumpMotor {
    #[must_use]
    pub const fn new(config: JumpConfig) -> Self {
        Self { config }
    }

    pub fn start_jump(
        &self,
        body: &mut PhysicsBody,
        direction: JumpDirection,
    ) -> Result<JumpStartResult, JumpError> {
        let source_surface_id = match body.attachment {
            AttachmentState::Grounded { attachment } => attachment.surface_id,
            _ => return Err(JumpError::BodyNotGrounded),
        };

        let previous_position = body.position;
        body.attachment = AttachmentState::Detached;
        body.velocity = Vector2::new(
            direction.horizontal_sign() * self.config.horizontal_speed,
            -self.config.jump_speed,
        );

        Ok(JumpStartResult {
            previous_position,
            position: body.position,
            velocity: body.velocity,
            source_surface_id,
            attachment_transition: AttachmentTransition::Detached {
                previous_surface_id: source_surface_id,
            },
        })
    }
}

impl Default for JumpMotor {
    fn default() -> Self {
        Self::new(JumpConfig::default())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AirbornePhase {
    Rising,
    Apex,
    Falling,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct AirborneStepResult {
    pub previous_position: Point2,
    pub position: Point2,
    pub velocity: Vector2,
    pub phase: AirbornePhase,
    pub landed: bool,
    pub landed_surface_id: Option<SurfaceId>,
}

#[derive(Debug, Clone, Copy)]
pub struct AirborneController {
    apex_epsilon: f32,
}

impl AirborneController {
    #[must_use]
    pub const fn new(apex_epsilon: f32) -> Self {
        Self { apex_epsilon }
    }

    pub fn step(
        &self,
        body: &mut PhysicsBody,
        delta: Duration,
        world: &impl PhysicsWorldQuery,
        solver: &crate::DesktopPhysicsSolver,
    ) -> AirborneStepResult {
        let previous_position = body.position;
        let result = solver.step(body, delta, world);

        let phase = if result.landed {
            AirbornePhase::Falling
        } else if body.velocity.y < -self.apex_epsilon {
            AirbornePhase::Rising
        } else if body.velocity.y > self.apex_epsilon {
            AirbornePhase::Falling
        } else {
            AirbornePhase::Apex
        };

        AirborneStepResult {
            previous_position,
            position: body.position,
            velocity: body.velocity,
            phase,
            landed: result.landed,
            landed_surface_id: body.attachment.surface_id(),
        }
    }
}

impl Default for AirborneController {
    fn default() -> Self {
        Self::new(1.0)
    }
}
