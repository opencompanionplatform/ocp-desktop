use crate::{
    AttachmentState, AttachmentTransition, Contact, ContactKind, PhysicsBody, PhysicsConfig,
    PhysicsSurface, PhysicsWorldQuery, SurfaceAttachment,
};
use ocp_shared_types::{Orientation, Point2, SurfaceCapabilities, Vector2};
use serde::{Deserialize, Serialize};
use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PhysicsStepState {
    Grounded,
    Falling,
    Attached,
    Hanging,
    Free,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PhysicsStepResult {
    pub previous_position: Point2,
    pub position: Point2,
    pub velocity: Vector2,
    pub contacts: Vec<Contact>,
    pub attachment_transition: AttachmentTransition,
    pub state: PhysicsStepState,
    pub landed: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct DesktopPhysicsSolver {
    config: PhysicsConfig,
}

impl DesktopPhysicsSolver {
    #[must_use]
    pub const fn new(config: PhysicsConfig) -> Self {
        Self { config }
    }

    pub fn step(
        &self,
        body: &mut PhysicsBody,
        delta: Duration,
        world: &impl PhysicsWorldQuery,
    ) -> PhysicsStepResult {
        let previous_position = body.position;
        let previous_attachment = body.attachment;

        let attachment_transition = self.validate_attachment(body, world);

        if body.attachment.is_grounded() && body.velocity.y <= 0.0 {
            body.velocity.y = 0.0;
        } else if matches!(body.attachment, AttachmentState::Detached) {
            let dt = delta.as_secs_f32().min(self.config.max_step_seconds);

            body.velocity.x += body.acceleration.x * dt;
            body.velocity.y +=
                (body.acceleration.y + self.config.gravity.y * body.gravity_scale) * dt;
            body.velocity.y = body.velocity.y.min(self.config.terminal_velocity);

            let proposed = Point2::new(
                body.position.x + body.velocity.x * dt,
                body.position.y + body.velocity.y * dt,
            );

            if body.velocity.y >= 0.0 {
                if let Some(surface) = self.find_landing_surface(body, proposed, world) {
                    let landing_y = surface.start.y - body.collider.half_extents.height;

                    body.position = Point2::new(proposed.x, landing_y);
                    body.velocity.y = 0.0;
                    body.attachment = AttachmentState::Grounded {
                        attachment: SurfaceAttachment {
                            surface_id: surface.id,
                            anchor: Point2::new(proposed.x, surface.start.y),
                            normal: surface.normal,
                        },
                    };

                    let transition = AttachmentTransition::Grounded {
                        surface_id: surface.id,
                    };

                    return PhysicsStepResult {
                        previous_position,
                        position: body.position,
                        velocity: body.velocity,
                        contacts: vec![Contact {
                            kind: ContactKind::Surface,
                            point: Point2::new(proposed.x, surface.start.y),
                            normal: surface.normal,
                            surface_id: Some(surface.id),
                        }],
                        attachment_transition: transition,
                        state: PhysicsStepState::Grounded,
                        landed: !previous_attachment.is_grounded(),
                    };
                }
            }

            if let Some(surface) = self.find_fall_recovery_surface(body, proposed, world) {
                let proposed_feet = body.collider.feet_y(proposed);
                let recovery_threshold = body.collider.half_extents.height * 8.0 + 512.0;

                if proposed_feet > surface.start.y + recovery_threshold {
                    let recovery_x = recovery_center_x(body, proposed.x, surface);
                    let recovery_y = surface.start.y - body.collider.half_extents.height;

                    body.position = Point2::new(recovery_x, recovery_y);
                    body.velocity = Vector2::ZERO;
                    body.attachment = AttachmentState::Grounded {
                        attachment: SurfaceAttachment {
                            surface_id: surface.id,
                            anchor: Point2::new(recovery_x, surface.start.y),
                            normal: surface.normal,
                        },
                    };

                    return PhysicsStepResult {
                        previous_position,
                        position: body.position,
                        velocity: body.velocity,
                        contacts: vec![Contact {
                            kind: ContactKind::Surface,
                            point: Point2::new(recovery_x, surface.start.y),
                            normal: surface.normal,
                            surface_id: Some(surface.id),
                        }],
                        attachment_transition: AttachmentTransition::Grounded {
                            surface_id: surface.id,
                        },
                        state: PhysicsStepState::Grounded,
                        landed: true,
                    };
                }
            }

            body.position = proposed;
        }

        PhysicsStepResult {
            previous_position,
            position: body.position,
            velocity: body.velocity,
            contacts: Vec::new(),
            attachment_transition,
            state: state_for(body),
            landed: false,
        }
    }

    fn validate_attachment(
        &self,
        body: &mut PhysicsBody,
        world: &impl PhysicsWorldQuery,
    ) -> AttachmentTransition {
        let Some(surface_id) = body.attachment.surface_id() else {
            return AttachmentTransition::None;
        };

        if world.surface(surface_id).is_some() {
            return AttachmentTransition::None;
        }

        body.attachment = AttachmentState::Detached;
        AttachmentTransition::Detached {
            previous_surface_id: surface_id,
        }
    }

    fn find_fall_recovery_surface(
        &self,
        body: &PhysicsBody,
        proposed: Point2,
        world: &impl PhysicsWorldQuery,
    ) -> Option<PhysicsSurface> {
        let half_width = body.collider.half_extents.width;
        let proposed_feet = body.collider.feet_y(proposed);
        let from = Point2::new(proposed.x - half_width, -100_000.0);
        let to = Point2::new(proposed.x + half_width, proposed_feet);

        world
            .candidate_surfaces(from, to)
            .into_iter()
            .filter(|surface| {
                surface.orientation == Orientation::Horizontal
                    && surface.capabilities.contains(SurfaceCapabilities::LANDABLE)
                    && surface.capabilities.contains(SurfaceCapabilities::WALKABLE)
                    && surface.normal.y < 0.0
            })
            .filter(|surface| {
                let body_left = proposed.x - half_width;
                let body_right = proposed.x + half_width;
                let surface_left = surface.start.x.min(surface.end.x);
                let surface_right = surface.start.x.max(surface.end.x);

                surface_right >= body_left - self.config.contact_epsilon
                    && surface_left <= body_right + self.config.contact_epsilon
                    && surface.start.y < proposed_feet
            })
            .min_by(|left, right| {
                let left_distance = proposed_feet - left.start.y;
                let right_distance = proposed_feet - right.start.y;
                left_distance.total_cmp(&right_distance)
            })
    }

    fn find_landing_surface(
        &self,
        body: &PhysicsBody,
        proposed: Point2,
        world: &impl PhysicsWorldQuery,
    ) -> Option<PhysicsSurface> {
        let previous_feet = body.collider.feet_y(body.position);
        let proposed_feet = body.collider.feet_y(proposed);

        let previous_feet_position = Point2::new(body.position.x, previous_feet);
        let proposed_feet_position = Point2::new(proposed.x, proposed_feet);

        world
            .candidate_surfaces(previous_feet_position, proposed_feet_position)
            .into_iter()
            .filter(|surface| {
                surface.orientation == Orientation::Horizontal
                    && surface.capabilities.contains(SurfaceCapabilities::LANDABLE)
                    && surface.normal.y < 0.0
            })
            .filter(|surface| {
                let left = surface.start.x.min(surface.end.x) - self.config.contact_epsilon;
                let right = surface.start.x.max(surface.end.x) + self.config.contact_epsilon;
                proposed.x >= left && proposed.x <= right
            })
            .filter(|surface| {
                let y = surface.start.y;
                previous_feet <= y + self.config.contact_epsilon
                    && proposed_feet >= y - self.config.contact_epsilon
            })
            .min_by(|left, right| left.start.y.total_cmp(&right.start.y))
    }
}

impl Default for DesktopPhysicsSolver {
    fn default() -> Self {
        Self::new(PhysicsConfig::default())
    }
}

fn recovery_center_x(body: &PhysicsBody, requested_x: f32, surface: PhysicsSurface) -> f32 {
    let left = surface.start.x.min(surface.end.x) + body.collider.half_extents.width;
    let right = surface.start.x.max(surface.end.x) - body.collider.half_extents.width;

    if left <= right {
        requested_x.clamp(left, right)
    } else {
        (surface.start.x + surface.end.x) * 0.5
    }
}

fn state_for(body: &PhysicsBody) -> PhysicsStepState {
    match body.attachment {
        AttachmentState::Grounded { .. } => PhysicsStepState::Grounded,
        AttachmentState::Attached { .. } => PhysicsStepState::Attached,
        AttachmentState::Hanging { .. } => PhysicsStepState::Hanging,
        AttachmentState::Detached if body.velocity.y > 0.0 => PhysicsStepState::Falling,
        AttachmentState::Detached => PhysicsStepState::Free,
    }
}
