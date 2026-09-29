use chrono::Utc;
use ocp_desktop_physics::{
    AabbCollider, AttachmentState, JumpDirection, PhysicsBody, PhysicsCommand, SurfaceAttachment,
};
use ocp_desktop_world::{DesktopWorldCapabilities, DesktopWorldSnapshot};
use ocp_event_bus::InProcessBus;
use ocp_kernel::desktop_physics_host::{
    KernelDesktopPhysicsConfig, KernelDesktopPhysicsError, KernelDesktopPhysicsHost,
    KernelDesktopPhysicsState, DESKTOP_PHYSICS_STARTED, DESKTOP_PHYSICS_STOPPED,
};
use ocp_shared_types::surface::SurfaceGeometry;
use ocp_shared_types::{
    Bounds, CoordinateSpace, Orientation, Point2, Rect, SurfaceCapabilities, SurfaceDescriptor,
    SurfaceId, SurfaceKind, SurfaceStability, Vector2, WorldId, WorldRevision,
};
use std::time::Duration;

fn floor_surface() -> SurfaceDescriptor {
    SurfaceDescriptor {
        id: SurfaceId::new(),
        provider_id: "test.desktop-physics".to_owned(),
        owner_entity_id: None,
        surface_kind: SurfaceKind::DesktopFloor,
        geometry: SurfaceGeometry::Segment {
            start: Point2::new(0.0, 500.0),
            end: Point2::new(1_000.0, 500.0),
        },
        orientation: Orientation::Horizontal,
        normal: Vector2::new(0.0, -1.0),
        capabilities: SurfaceCapabilities::LANDABLE
            .union(SurfaceCapabilities::WALKABLE)
            .union(SurfaceCapabilities::JUMP_ORIGIN),
        stability: SurfaceStability::Static,
        motion_binding: None,
        attachment_points: Vec::new(),
        tags: vec!["test-floor".to_owned()],
        revision: 1,
    }
}

fn world_with_floor(surface: SurfaceDescriptor) -> DesktopWorldSnapshot {
    DesktopWorldSnapshot {
        world_id: WorldId::new(),
        revision: WorldRevision::INITIAL,
        observed_at: Utc::now(),
        coordinate_space: CoordinateSpace::DesktopGlobalPhysical,
        capabilities: DesktopWorldCapabilities::default(),
        virtual_desktop_bounds: Bounds(Rect::new(0.0, 0.0, 1_000.0, 800.0)),
        monitors: Vec::new(),
        workspaces: Vec::new(),
        windows: Vec::new(),
        cursor: None,
        taskbar_or_dock: None,
        surfaces: vec![surface],
        obstacles: Vec::new(),
        active_window_id: None,
        active_application: None,
    }
}

fn grounded_body(surface_id: SurfaceId) -> PhysicsBody {
    let mut body = PhysicsBody::new(Point2::new(400.0, 480.0), AabbCollider::new(10.0, 20.0));

    body.attachment = AttachmentState::Grounded {
        attachment: SurfaceAttachment {
            surface_id,
            anchor: Point2::new(400.0, 500.0),
            normal: Vector2::new(0.0, -1.0),
        },
    };

    body
}

#[test]
fn default_host_config_tracks_high_refresh_fixed_step() {
    let config = KernelDesktopPhysicsConfig::default();

    assert_eq!(config.fixed_step, Duration::from_micros(8_333));
    assert_eq!(config.max_catch_up_steps, 16);
}

#[test]
fn disabled_host_rejects_runtime_operations() {
    let bus = InProcessBus::new();
    let mut host = KernelDesktopPhysicsHost::new(
        bus,
        KernelDesktopPhysicsConfig {
            enabled: false,
            ..KernelDesktopPhysicsConfig::default()
        },
    )
    .expect("disabled host");

    assert_eq!(host.state(), KernelDesktopPhysicsState::Disabled);

    let error = host
        .insert_body(PhysicsBody::new(Point2::ZERO, AabbCollider::default()))
        .expect_err("disabled insert");

    assert!(matches!(error, KernelDesktopPhysicsError::Disabled));
}

#[test]
fn lifecycle_events_are_published() {
    let bus = InProcessBus::new();
    let started = bus.subscribe(DESKTOP_PHYSICS_STARTED);
    let stopped = bus.subscribe(DESKTOP_PHYSICS_STOPPED);

    let mut host =
        KernelDesktopPhysicsHost::new(bus, KernelDesktopPhysicsConfig::default()).expect("host");

    let started_event = started
        .recv_timeout(Duration::from_millis(50))
        .expect("started event");
    assert_eq!(started_event.version, "1.0");

    host.shutdown().expect("shutdown");

    stopped
        .recv_timeout(Duration::from_millis(50))
        .expect("stopped event");
}

#[test]
fn host_publishes_typed_physics_events() {
    let surface = floor_surface();
    let world = world_with_floor(surface.clone());
    let bus = InProcessBus::new();
    let physics_events = bus.subscribe("ocp.physics.");
    let character_events = bus.subscribe("ocp.character.");

    let mut host = KernelDesktopPhysicsHost::new(
        bus,
        KernelDesktopPhysicsConfig {
            fixed_step: Duration::from_millis(10),
            ..KernelDesktopPhysicsConfig::default()
        },
    )
    .expect("host");

    let body = grounded_body(surface.id);
    let body_id = host.insert_body(body).expect("insert");
    host.enqueue(
        body_id,
        PhysicsCommand::Jump {
            direction: JumpDirection::Right,
        },
    )
    .expect("jump");

    host.tick(Duration::from_millis(10), &world).expect("tick");
    host.tick(Duration::from_millis(10), &world).expect("tick");

    let detached = physics_events
        .recv_timeout(Duration::from_millis(50))
        .expect("physics event");
    assert_eq!(detached.event_type, "ocp.physics.detached");
    assert_eq!(detached.version, "1.0");
    assert_eq!(detached.source, "ocp-kernel-desktop-physics",);

    let moved = character_events
        .recv_timeout(Duration::from_millis(50))
        .expect("character moved");
    assert_eq!(moved.event_type, "ocp.character.moved");

    let health = host.health();
    assert!(health.completed_ticks >= 2);
    assert!(health.published_events >= 2);
    assert_eq!(health.body_count, 1);
}

#[test]
fn rejected_command_is_counted_and_published() {
    let surface = floor_surface();
    let world = world_with_floor(surface);
    let bus = InProcessBus::new();
    let rejected = bus.subscribe("ocp.physics.command-rejected");

    let mut host = KernelDesktopPhysicsHost::new(
        bus,
        KernelDesktopPhysicsConfig {
            fixed_step: Duration::from_millis(10),
            ..KernelDesktopPhysicsConfig::default()
        },
    )
    .expect("host");

    let body = PhysicsBody::new(Point2::new(50.0, 50.0), AabbCollider::default());
    let body_id = host.insert_body(body).expect("insert");

    host.enqueue(
        body_id,
        PhysicsCommand::Jump {
            direction: JumpDirection::Vertical,
        },
    )
    .expect("enqueue");

    host.tick(Duration::from_millis(10), &world).expect("tick");

    rejected
        .recv_timeout(Duration::from_millis(50))
        .expect("rejected event");

    assert_eq!(host.health().rejected_commands, 1);
}
