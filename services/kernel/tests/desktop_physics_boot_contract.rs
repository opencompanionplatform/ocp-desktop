use chrono::Utc;
use ocp_desktop_physics::{
    AabbCollider, AttachmentState, JumpDirection, PhysicsBody, PhysicsCommand, SurfaceAttachment,
};
use ocp_desktop_world::{DesktopWorldCapabilities, DesktopWorldSnapshot};
use ocp_event_bus::InProcessBus;
use ocp_kernel::desktop_physics_boot::{KernelDesktopPhysicsLoop, KernelDesktopPhysicsLoopConfig};
use ocp_kernel::desktop_physics_host::{KernelDesktopPhysicsConfig, KernelDesktopPhysicsState};
use ocp_shared_types::surface::SurfaceGeometry;
use ocp_shared_types::{
    Bounds, CoordinateSpace, Orientation, Point2, Rect, SurfaceCapabilities, SurfaceDescriptor,
    SurfaceId, SurfaceKind, SurfaceStability, Vector2, WorldId, WorldRevision,
};
use std::sync::{Arc, RwLock};
use std::thread;
use std::time::Duration;

fn floor_surface() -> SurfaceDescriptor {
    SurfaceDescriptor {
        id: SurfaceId::new(),
        provider_id: "test.desktop-physics-boot".to_owned(),
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
fn default_loop_polling_supports_high_refresh_physics() {
    let config = KernelDesktopPhysicsLoopConfig::default();

    assert_eq!(config.tick_interval, Duration::from_millis(8));
}

#[test]
fn loop_waits_safely_for_first_world_snapshot() {
    let bus = InProcessBus::new();
    let store = Arc::new(RwLock::new(None));
    let mut runtime = KernelDesktopPhysicsLoop::start(
        bus,
        KernelDesktopPhysicsConfig::default(),
        KernelDesktopPhysicsLoopConfig {
            tick_interval: Duration::from_millis(2),
        },
        store,
    )
    .expect("loop");

    thread::sleep(Duration::from_millis(20));
    let health = runtime.health();

    assert!(health.loop_iterations > 0);
    assert!(health.ticks_without_world > 0);
    assert_eq!(health.host.completed_ticks, 0);

    runtime.shutdown().expect("shutdown");
}

#[test]
fn loop_ticks_against_latest_world_snapshot() {
    let surface = floor_surface();
    let store = Arc::new(RwLock::new(Some(world_with_floor(surface.clone()))));
    let bus = InProcessBus::new();
    let detached = bus.subscribe("ocp.physics.detached");
    let mut runtime = KernelDesktopPhysicsLoop::start(
        bus,
        KernelDesktopPhysicsConfig {
            fixed_step: Duration::from_millis(2),
            ..KernelDesktopPhysicsConfig::default()
        },
        KernelDesktopPhysicsLoopConfig {
            tick_interval: Duration::from_millis(2),
        },
        store,
    )
    .expect("loop");

    let body_id = runtime
        .insert_body(grounded_body(surface.id))
        .expect("body");
    runtime
        .enqueue(
            body_id,
            PhysicsCommand::Jump {
                direction: JumpDirection::Vertical,
            },
        )
        .expect("jump");

    detached
        .recv_timeout(Duration::from_millis(200))
        .expect("detached event");

    let health = runtime.health();
    assert!(health.host.completed_ticks > 0);
    assert!(health.host.published_events > 0);

    let stopped = runtime.shutdown().expect("shutdown");
    assert_eq!(stopped.host.state, KernelDesktopPhysicsState::Stopped);
}

#[test]
fn disabled_loop_exits_without_world_ticks() {
    let bus = InProcessBus::new();
    let store = Arc::new(RwLock::new(None));
    let mut runtime = KernelDesktopPhysicsLoop::start(
        bus,
        KernelDesktopPhysicsConfig {
            enabled: false,
            ..KernelDesktopPhysicsConfig::default()
        },
        KernelDesktopPhysicsLoopConfig {
            tick_interval: Duration::from_millis(2),
        },
        store,
    )
    .expect("disabled loop");

    thread::sleep(Duration::from_millis(10));
    assert_eq!(runtime.state(), KernelDesktopPhysicsState::Disabled);

    runtime.shutdown().expect("shutdown");
}
