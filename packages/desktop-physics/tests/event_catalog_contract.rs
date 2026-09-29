use ocp_desktop_physics::{
    AttachmentTransition, PhysicsBodyId, PhysicsCommand, PhysicsEventPayload,
    PhysicsEventProjector, PhysicsFrameResult, PhysicsRuntimeEvent, RuntimeBodySnapshot,
    RuntimeBodyState, RuntimeTransition, WalkDirection, WalkEdgeBehavior, CHARACTER_MOVED,
    PHYSICS_ATTACHED, PHYSICS_COMMAND_REJECTED, PHYSICS_DETACHED, PHYSICS_EVENT_CATALOG,
    PHYSICS_EVENT_VERSION, PHYSICS_FALLING, PHYSICS_GROUNDED, PHYSICS_LANDED,
};
use ocp_shared_types::{Point2, SurfaceId, Vector2};
use std::collections::BTreeSet;

fn snapshot(
    body_id: PhysicsBodyId,
    position: Point2,
    velocity: Vector2,
    state: RuntimeBodyState,
    surface_id: Option<SurfaceId>,
) -> RuntimeBodySnapshot {
    RuntimeBodySnapshot {
        body_id,
        position,
        velocity,
        state,
        attachment_surface_id: surface_id,
    }
}

#[test]
fn event_catalog_is_unique_and_versioned() {
    let unique: BTreeSet<_> = PHYSICS_EVENT_CATALOG.iter().copied().collect();

    assert_eq!(unique.len(), PHYSICS_EVENT_CATALOG.len());
    assert_eq!(PHYSICS_EVENT_VERSION, "1.0");

    for event_type in PHYSICS_EVENT_CATALOG {
        assert!(event_type.starts_with("ocp."));
        assert_eq!(event_type.split('.').count(), 3);
    }
}

#[test]
fn attachment_transitions_map_to_typed_events() {
    let body_id = PhysicsBodyId::new();
    let surface_id = SurfaceId::new();
    let mut projector = PhysicsEventProjector::default();

    let frame = PhysicsFrameResult {
        frame_index: 7,
        simulated_steps: 1,
        bodies: vec![snapshot(
            body_id,
            Point2::new(10.0, 20.0),
            Vector2::ZERO,
            RuntimeBodyState::Idle,
            Some(surface_id),
        )],
        transitions: vec![
            RuntimeTransition::Attachment {
                body_id,
                transition: AttachmentTransition::Attached { surface_id },
            },
            RuntimeTransition::Attachment {
                body_id,
                transition: AttachmentTransition::Grounded { surface_id },
            },
            RuntimeTransition::Attachment {
                body_id,
                transition: AttachmentTransition::Detached {
                    previous_surface_id: surface_id,
                },
            },
        ],
    };

    let events = projector.project(&frame);

    assert_eq!(events.len(), 3);
    assert_eq!(events[0].event_type, PHYSICS_ATTACHED);
    assert_eq!(events[1].event_type, PHYSICS_GROUNDED);
    assert_eq!(events[2].event_type, PHYSICS_DETACHED);
}

#[test]
fn landed_and_rejected_commands_map_to_events() {
    let body_id = PhysicsBodyId::new();
    let surface_id = SurfaceId::new();
    let command = PhysicsCommand::Walk {
        direction: WalkDirection::Right,
        edge_behavior: WalkEdgeBehavior::StopAtEdge,
    };
    let mut projector = PhysicsEventProjector::default();

    let frame = PhysicsFrameResult {
        frame_index: 8,
        simulated_steps: 1,
        bodies: vec![snapshot(
            body_id,
            Point2::new(50.0, 80.0),
            Vector2::ZERO,
            RuntimeBodyState::Idle,
            Some(surface_id),
        )],
        transitions: vec![
            RuntimeTransition::Landed {
                body_id,
                surface_id,
            },
            RuntimeTransition::CommandRejected { body_id, command },
        ],
    };

    let events = projector.project(&frame);

    assert_eq!(events.len(), 2);
    assert_eq!(events[0].event_type, PHYSICS_LANDED);
    assert_eq!(events[1].event_type, PHYSICS_COMMAND_REJECTED);

    assert!(matches!(
        events[0].payload,
        PhysicsEventPayload::Landed {
            body_id: id,
            surface_id: sid,
            position,
        } if id == body_id
            && sid == surface_id
            && position == Point2::new(50.0, 80.0)
    ));
}

#[test]
fn movement_event_is_emitted_only_when_position_changes() {
    let body_id = PhysicsBodyId::new();
    let mut projector = PhysicsEventProjector::default();

    let first = PhysicsFrameResult {
        frame_index: 1,
        simulated_steps: 1,
        bodies: vec![snapshot(
            body_id,
            Point2::new(10.0, 20.0),
            Vector2::ZERO,
            RuntimeBodyState::Idle,
            None,
        )],
        transitions: Vec::new(),
    };

    assert!(projector.project(&first).is_empty());

    let unchanged = PhysicsFrameResult {
        frame_index: 2,
        ..first.clone()
    };
    assert!(projector.project(&unchanged).is_empty());

    let moved = PhysicsFrameResult {
        frame_index: 3,
        simulated_steps: 1,
        bodies: vec![snapshot(
            body_id,
            Point2::new(15.0, 20.0),
            Vector2::new(5.0, 0.0),
            RuntimeBodyState::Walking,
            None,
        )],
        transitions: Vec::new(),
    };

    let events = projector.project(&moved);

    assert_eq!(events.len(), 1);
    assert_eq!(events[0].event_type, CHARACTER_MOVED);
}

#[test]
fn falling_is_emitted_once_when_downward_motion_begins() {
    let body_id = PhysicsBodyId::new();
    let mut projector = PhysicsEventProjector::default();

    let rising = PhysicsFrameResult {
        frame_index: 1,
        simulated_steps: 1,
        bodies: vec![snapshot(
            body_id,
            Point2::new(10.0, 20.0),
            Vector2::new(0.0, -20.0),
            RuntimeBodyState::Airborne,
            None,
        )],
        transitions: Vec::new(),
    };
    let _ = projector.project(&rising);

    let falling = PhysicsFrameResult {
        frame_index: 2,
        simulated_steps: 1,
        bodies: vec![snapshot(
            body_id,
            Point2::new(10.0, 21.0),
            Vector2::new(0.0, 10.0),
            RuntimeBodyState::Airborne,
            None,
        )],
        transitions: Vec::new(),
    };

    let first_events = projector.project(&falling);
    assert!(first_events
        .iter()
        .any(|event| event.event_type == PHYSICS_FALLING));

    let continued = PhysicsFrameResult {
        frame_index: 3,
        bodies: vec![snapshot(
            body_id,
            Point2::new(10.0, 22.0),
            Vector2::new(0.0, 20.0),
            RuntimeBodyState::Airborne,
            None,
        )],
        ..falling
    };

    let continued_events = projector.project(&continued);
    assert!(!continued_events
        .iter()
        .any(|event| event.event_type == PHYSICS_FALLING));
}

#[test]
fn event_wire_shape_round_trips() {
    let body_id = PhysicsBodyId::new();
    let surface_id = SurfaceId::new();
    let event = PhysicsRuntimeEvent::new(
        PHYSICS_GROUNDED,
        11,
        PhysicsEventPayload::Grounded {
            body_id,
            surface_id,
        },
    );

    let json = serde_json::to_string(&event).expect("serialize");
    let decoded: PhysicsRuntimeEvent = serde_json::from_str(&json).expect("deserialize");

    assert_eq!(decoded, event);
}
