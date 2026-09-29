use crate::{
    AttachmentTransition, PhysicsBodyId, PhysicsCommand, PhysicsFrameResult, RuntimeBodySnapshot,
    RuntimeBodyState, RuntimeTransition,
};
use ocp_shared_types::{Point2, SurfaceId, Vector2};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const PHYSICS_EVENT_VERSION: &str = "1.0";

pub const PHYSICS_ATTACHED: &str = "ocp.physics.attached";
pub const PHYSICS_DETACHED: &str = "ocp.physics.detached";
pub const PHYSICS_GROUNDED: &str = "ocp.physics.grounded";
pub const PHYSICS_FALLING: &str = "ocp.physics.falling";
pub const PHYSICS_LANDED: &str = "ocp.physics.landed";
pub const PHYSICS_COMMAND_REJECTED: &str = "ocp.physics.command-rejected";
pub const CHARACTER_MOVED: &str = "ocp.character.moved";

pub const PHYSICS_EVENT_CATALOG: &[&str] = &[
    PHYSICS_ATTACHED,
    PHYSICS_DETACHED,
    PHYSICS_GROUNDED,
    PHYSICS_FALLING,
    PHYSICS_LANDED,
    PHYSICS_COMMAND_REJECTED,
    CHARACTER_MOVED,
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PhysicsAttachmentMode {
    Attached,
    Hanging,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "payload_kind")]
pub enum PhysicsEventPayload {
    Attached {
        body_id: PhysicsBodyId,
        surface_id: SurfaceId,
        mode: PhysicsAttachmentMode,
    },
    Detached {
        body_id: PhysicsBodyId,
        previous_surface_id: SurfaceId,
    },
    Grounded {
        body_id: PhysicsBodyId,
        surface_id: SurfaceId,
    },
    Falling {
        body_id: PhysicsBodyId,
        position: Point2,
        velocity: Vector2,
    },
    Landed {
        body_id: PhysicsBodyId,
        surface_id: SurfaceId,
        position: Point2,
    },
    CommandRejected {
        body_id: PhysicsBodyId,
        command: PhysicsCommand,
    },
    CharacterMoved {
        body_id: PhysicsBodyId,
        previous_position: Point2,
        position: Point2,
        velocity: Vector2,
        state: RuntimeBodyState,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PhysicsRuntimeEvent {
    pub event_type: String,
    pub version: String,
    pub frame_index: u64,
    pub payload: PhysicsEventPayload,
}

impl PhysicsRuntimeEvent {
    #[must_use]
    pub fn new(event_type: &str, frame_index: u64, payload: PhysicsEventPayload) -> Self {
        Self {
            event_type: event_type.to_owned(),
            version: PHYSICS_EVENT_VERSION.to_owned(),
            frame_index,
            payload,
        }
    }
}

#[derive(Debug, Default)]
pub struct PhysicsEventProjector {
    previous_bodies: BTreeMap<PhysicsBodyId, RuntimeBodySnapshot>,
}

impl PhysicsEventProjector {
    #[must_use]
    pub fn project(&mut self, frame: &PhysicsFrameResult) -> Vec<PhysicsRuntimeEvent> {
        let mut events = Vec::new();

        for transition in &frame.transitions {
            project_transition(frame, *transition, &mut events);
        }

        for current in &frame.bodies {
            if let Some(previous) = self.previous_bodies.get(&current.body_id) {
                if previous.position != current.position
                    || previous.velocity != current.velocity
                    || previous.state != current.state
                {
                    events.push(PhysicsRuntimeEvent::new(
                        CHARACTER_MOVED,
                        frame.frame_index,
                        PhysicsEventPayload::CharacterMoved {
                            body_id: current.body_id,
                            previous_position: previous.position,
                            position: current.position,
                            velocity: current.velocity,
                            state: current.state,
                        },
                    ));
                }

                if entered_falling(previous, current) {
                    events.push(PhysicsRuntimeEvent::new(
                        PHYSICS_FALLING,
                        frame.frame_index,
                        PhysicsEventPayload::Falling {
                            body_id: current.body_id,
                            position: current.position,
                            velocity: current.velocity,
                        },
                    ));
                }
            }

            self.previous_bodies
                .insert(current.body_id, current.clone());
        }

        events
    }

    pub fn forget_body(&mut self, body_id: PhysicsBodyId) {
        self.previous_bodies.remove(&body_id);
    }

    pub fn clear(&mut self) {
        self.previous_bodies.clear();
    }
}

fn project_transition(
    frame: &PhysicsFrameResult,
    transition: RuntimeTransition,
    events: &mut Vec<PhysicsRuntimeEvent>,
) {
    match transition {
        RuntimeTransition::Attachment {
            body_id,
            transition,
        } => match transition {
            AttachmentTransition::None => {}
            AttachmentTransition::Attached { surface_id } => {
                events.push(PhysicsRuntimeEvent::new(
                    PHYSICS_ATTACHED,
                    frame.frame_index,
                    PhysicsEventPayload::Attached {
                        body_id,
                        surface_id,
                        mode: PhysicsAttachmentMode::Attached,
                    },
                ));
            }
            AttachmentTransition::Hanging { surface_id } => {
                events.push(PhysicsRuntimeEvent::new(
                    PHYSICS_ATTACHED,
                    frame.frame_index,
                    PhysicsEventPayload::Attached {
                        body_id,
                        surface_id,
                        mode: PhysicsAttachmentMode::Hanging,
                    },
                ));
            }
            AttachmentTransition::Grounded { surface_id } => {
                events.push(PhysicsRuntimeEvent::new(
                    PHYSICS_GROUNDED,
                    frame.frame_index,
                    PhysicsEventPayload::Grounded {
                        body_id,
                        surface_id,
                    },
                ));
            }
            AttachmentTransition::Detached {
                previous_surface_id,
            } => {
                events.push(PhysicsRuntimeEvent::new(
                    PHYSICS_DETACHED,
                    frame.frame_index,
                    PhysicsEventPayload::Detached {
                        body_id,
                        previous_surface_id,
                    },
                ));
            }
        },
        RuntimeTransition::Landed {
            body_id,
            surface_id,
        } => {
            let position = frame
                .bodies
                .iter()
                .find(|body| body.body_id == body_id)
                .map_or(Point2::ZERO, |body| body.position);

            events.push(PhysicsRuntimeEvent::new(
                PHYSICS_LANDED,
                frame.frame_index,
                PhysicsEventPayload::Landed {
                    body_id,
                    surface_id,
                    position,
                },
            ));
        }
        RuntimeTransition::CommandRejected { body_id, command } => {
            events.push(PhysicsRuntimeEvent::new(
                PHYSICS_COMMAND_REJECTED,
                frame.frame_index,
                PhysicsEventPayload::CommandRejected { body_id, command },
            ));
        }
    }
}

fn entered_falling(previous: &RuntimeBodySnapshot, current: &RuntimeBodySnapshot) -> bool {
    current.state == RuntimeBodyState::Airborne
        && current.velocity.y > 0.0
        && (previous.state != RuntimeBodyState::Airborne || previous.velocity.y <= 0.0)
}
