use chrono::Utc;
use ocp_desktop_physics::{
    AttachmentState, JumpDirection, PhysicsCommand, SurfaceAttachment, WalkDirection,
    WalkEdgeBehavior,
};
use ocp_desktop_world::{DesktopWorldCapabilities, DesktopWorldSnapshot};
use ocp_event_bus::InProcessBus;
use ocp_kernel::companion_physics_binding::{
    CompanionMovementCommand, CompanionPhysicsBindingError, CompanionPhysicsBindings,
    CompanionPhysicsBodyConfig, COMPANION_MOVED, COMPANION_PHYSICS_BOUND,
    COMPANION_PHYSICS_UNBOUND, COMPANION_PRESENTATION_STATE,
};

use ocp_kernel::desktop_physics_boot::{KernelDesktopPhysicsLoop, KernelDesktopPhysicsLoopConfig};
use ocp_kernel::desktop_physics_host::KernelDesktopPhysicsConfig;
use ocp_shared_types::surface::SurfaceGeometry;
use ocp_shared_types::{
    Bounds, CoordinateSpace, Envelope, Monitor, MonitorId, Orientation, Point2, Rect,
    SurfaceCapabilities, SurfaceDescriptor, SurfaceId, SurfaceKind, SurfaceStability, Vector2,
    Window, WindowId, WorldEntityId, WorldId, WorldRevision,
};
use serde_json::json;
use std::sync::{Arc, RwLock};
use std::time::Duration;

#[test]
fn character_body_profile_changes_collider_without_changing_initial_feet() {
    let defaults = CompanionPhysicsBodyConfig::default();
    let configured = defaults.with_collision_half_extents([48.0, 62.0]);

    assert_eq!(configured.half_width, 48.0);
    assert_eq!(configured.half_height, 62.0);
    assert_eq!(configured.default_x, defaults.default_x);
    assert_eq!(configured.default_y, defaults.default_y);
}

#[test]
fn invalid_character_body_profile_cannot_poison_physics_config() {
    let defaults = CompanionPhysicsBodyConfig::default();
    assert_eq!(
        defaults.with_collision_half_extents([f32::NAN, -1.0]),
        defaults
    );
}

fn horizontal_surface_with_kind(
    left: f32,
    right: f32,
    y: f32,
    tag: &str,
    surface_kind: SurfaceKind,
) -> SurfaceDescriptor {
    SurfaceDescriptor {
        id: SurfaceId::new(),
        provider_id: "test.companion-physics".to_owned(),
        owner_entity_id: None,
        surface_kind,
        geometry: SurfaceGeometry::Segment {
            start: Point2::new(left, y),
            end: Point2::new(right, y),
        },
        orientation: Orientation::Horizontal,
        normal: Vector2::new(0.0, -1.0),
        capabilities: SurfaceCapabilities::LANDABLE
            .union(SurfaceCapabilities::WALKABLE)
            .union(SurfaceCapabilities::JUMP_ORIGIN),
        stability: SurfaceStability::Static,
        motion_binding: None,
        attachment_points: Vec::new(),
        tags: vec![tag.to_owned()],
        revision: 1,
    }
}

fn horizontal_surface(left: f32, right: f32, y: f32, tag: &str) -> SurfaceDescriptor {
    horizontal_surface_with_kind(left, right, y, tag, SurfaceKind::DesktopFloor)
}

fn floor_surface() -> SurfaceDescriptor {
    horizontal_surface(0.0, 1_000.0, 700.0, "test-floor")
}

fn climbable_window_edge(x: f32, top: f32, bottom: f32) -> SurfaceDescriptor {
    SurfaceDescriptor {
        id: SurfaceId::new(),
        provider_id: "test.companion-physics".to_owned(),
        owner_entity_id: None,
        surface_kind: SurfaceKind::WindowLeft,
        geometry: SurfaceGeometry::Segment {
            start: Point2::new(x, top),
            end: Point2::new(x, bottom),
        },
        orientation: Orientation::Vertical,
        normal: Vector2::new(-1.0, 0.0),
        capabilities: SurfaceCapabilities::CLIMBABLE
            .union(SurfaceCapabilities::HANGABLE)
            .union(SurfaceCapabilities::DYNAMIC),
        stability: SurfaceStability::Dynamic,
        motion_binding: None,
        attachment_points: Vec::new(),
        tags: vec!["window".to_owned()],
        revision: 1,
    }
}

fn climbable_monitor_edge(x: f32, top: f32, bottom: f32, normal_x: f32) -> SurfaceDescriptor {
    let mut surface = climbable_window_edge(x, top, bottom);
    surface.surface_kind = SurfaceKind::MonitorEdge;
    surface.normal = Vector2::new(normal_x, 0.0);
    surface.stability = SurfaceStability::Static;
    surface.capabilities = SurfaceCapabilities::CLIMBABLE.union(SurfaceCapabilities::HANGABLE);
    surface.tags = vec!["monitor-edge".to_owned()];
    surface
}

fn owned(mut surface: SurfaceDescriptor, owner: WorldEntityId) -> SurfaceDescriptor {
    surface.owner_entity_id = Some(owner);
    surface
}

fn empty_world() -> DesktopWorldSnapshot {
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
        surfaces: vec![floor_surface()],
        obstacles: Vec::new(),
        active_window_id: None,
        active_application: None,
    }
}

fn physics(bus: InProcessBus) -> KernelDesktopPhysicsLoop {
    KernelDesktopPhysicsLoop::start(
        bus,
        KernelDesktopPhysicsConfig {
            fixed_step: Duration::from_millis(10),
            ..KernelDesktopPhysicsConfig::default()
        },
        KernelDesktopPhysicsLoopConfig {
            tick_interval: Duration::from_millis(10),
        },
        Arc::new(RwLock::new(Some(empty_world()))),
    )
    .expect("physics loop")
}

#[test]
fn binding_is_bijective_and_lifecycle_is_published() {
    let bus = InProcessBus::new();
    let bound = bus.subscribe(COMPANION_PHYSICS_BOUND);
    let unbound = bus.subscribe(COMPANION_PHYSICS_UNBOUND);
    let mut loop_owner = physics(bus.clone());
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());

    let binding = bindings.bind("aiko", None, &handle).expect("bind");

    assert_eq!(bindings.binding("aiko"), Some(binding));
    assert_eq!(
        bindings.companion_id(binding.body_id).as_deref(),
        Some("aiko"),
    );
    let bound_event = bound
        .recv_timeout(Duration::from_millis(50))
        .expect("bound event");
    assert_eq!(bound_event.data["grounded"], true);
    assert_eq!(bound_event.data["positionAnchor"], "character-feet");
    assert_eq!(bound_event.data["position"]["y"], 700.0);

    bindings.unbind("aiko", &handle).expect("unbind");
    assert!(bindings.binding("aiko").is_none());
    unbound
        .recv_timeout(Duration::from_millis(50))
        .expect("unbound event");

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn default_binding_uses_debug_safe_configured_position() {
    let config = CompanionPhysicsBodyConfig::default();
    assert_eq!(config.default_x, 640.0);
    assert_eq!(config.default_y, 700.0);
}

#[test]
fn repeated_bind_returns_existing_body() {
    let bus = InProcessBus::new();
    let mut loop_owner = physics(bus.clone());
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());

    let first = bindings.bind("aiko", None, &handle).expect("first");
    let second = bindings.bind("aiko", None, &handle).expect("second");

    assert_eq!(first, second);
    assert_eq!(bindings.len(), 1);

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn lazy_binding_is_grounded_before_first_walk_and_jump() {
    let bus = InProcessBus::new();
    let rejected = bus.subscribe("ocp.physics.command-rejected");
    let mut loop_owner = physics(bus.clone());
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());

    bindings.bind("aiko", None, &handle).expect("bind grounded");
    bindings
        .enqueue(
            "aiko",
            CompanionMovementCommand::WalkLeft {
                edge_behavior: WalkEdgeBehavior::StopAtEdge,
            },
            &handle,
        )
        .expect("walk accepted");

    std::thread::sleep(Duration::from_millis(30));
    assert!(rejected.try_recv().is_err(), "walk must not be rejected");
    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn climb_auto_attaches_to_nearby_window_edge_and_preserves_body_identity() {
    let bus = InProcessBus::new();
    let edge = climbable_window_edge(704.0, 200.0, 700.0);
    let edge_id = edge.id;
    let world = DesktopWorldSnapshot {
        surfaces: vec![floor_surface(), edge],
        ..empty_world()
    };
    let mut loop_owner = KernelDesktopPhysicsLoop::start(
        bus.clone(),
        KernelDesktopPhysicsConfig {
            fixed_step: Duration::from_millis(10),
            ..KernelDesktopPhysicsConfig::default()
        },
        KernelDesktopPhysicsLoopConfig {
            tick_interval: Duration::from_millis(10),
        },
        Arc::new(RwLock::new(Some(world))),
    )
    .expect("physics loop");
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());
    let _bridge = bindings.start_motion_bridge(handle.clone());
    let binding = bindings.bind("aiko", None, &handle).expect("bind");

    bindings
        .enqueue("aiko", CompanionMovementCommand::ClimbUp, &handle)
        .expect("nearby climb");
    let mut body = handle.body(binding.body_id).expect("body");
    for _ in 0..100 {
        if body.attachment.surface_id() == Some(edge_id) && body.position.y < 636.0 {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
        body = handle.body(binding.body_id).expect("body");
    }

    assert_eq!(body.id, binding.body_id);
    assert_eq!(body.attachment.surface_id(), Some(edge_id));
    assert!(body.position.y < 636.0, "climb command moves upward");

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn climb_auto_attaches_to_monitor_side_without_wraparound() {
    let bus = InProcessBus::new();
    let edge = climbable_monitor_edge(704.0, 0.0, 700.0, -1.0);
    let edge_id = edge.id;
    let world = DesktopWorldSnapshot {
        surfaces: vec![floor_surface(), edge],
        ..empty_world()
    };
    let mut loop_owner = KernelDesktopPhysicsLoop::start(
        bus.clone(),
        KernelDesktopPhysicsConfig {
            fixed_step: Duration::from_millis(10),
            ..KernelDesktopPhysicsConfig::default()
        },
        KernelDesktopPhysicsLoopConfig {
            tick_interval: Duration::from_millis(10),
        },
        Arc::new(RwLock::new(Some(world))),
    )
    .expect("physics loop");
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());
    let _bridge = bindings.start_motion_bridge(handle.clone());
    let binding = bindings.bind("aiko", None, &handle).expect("bind");

    bindings
        .enqueue("aiko", CompanionMovementCommand::ClimbUp, &handle)
        .expect("nearby monitor side climb");
    let mut body = handle.body(binding.body_id).expect("body");
    for _ in 0..100 {
        if body.attachment.surface_id() == Some(edge_id) && body.position.y < 636.0 {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
        body = handle.body(binding.body_id).expect("body");
    }

    assert_eq!(body.id, binding.body_id);
    assert_eq!(body.attachment.surface_id(), Some(edge_id));
    assert!(body.position.y < 636.0, "climb command moves upward");
    assert_eq!(body.position.x, 640.0, "body remains inside monitor edge");

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn autonomous_climb_selects_current_monitor_edge_instead_of_window_edge() {
    let bus = InProcessBus::new();
    let monitor_owner = WorldEntityId::new();
    let floor = owned(floor_surface(), monitor_owner);
    let monitor_edge = owned(
        climbable_monitor_edge(824.0, 0.0, 700.0, -1.0),
        monitor_owner,
    );
    let monitor_edge_id = monitor_edge.id;
    let window_edge = climbable_window_edge(804.0, 200.0, 700.0);
    let world = DesktopWorldSnapshot {
        surfaces: vec![floor, window_edge, monitor_edge],
        ..empty_world()
    };
    let mut loop_owner = KernelDesktopPhysicsLoop::start(
        bus.clone(),
        KernelDesktopPhysicsConfig {
            fixed_step: Duration::from_millis(10),
            ..KernelDesktopPhysicsConfig::default()
        },
        KernelDesktopPhysicsLoopConfig {
            tick_interval: Duration::from_millis(10),
        },
        Arc::new(RwLock::new(Some(world))),
    )
    .expect("physics loop");
    let handle = loop_owner.handle();
    let config = CompanionPhysicsBodyConfig {
        default_x: 760.0,
        ..CompanionPhysicsBodyConfig::default()
    };
    let bindings = CompanionPhysicsBindings::new(bus, config);
    let _bridge = bindings.start_motion_bridge(handle.clone());
    let binding = bindings.bind("aiko", None, &handle).expect("bind");

    bindings
        .enqueue_autonomous_surface_action("aiko", CompanionMovementCommand::ClimbUp, &handle)
        .expect("current-monitor climb");
    let mut body = handle.body(binding.body_id).expect("body");
    for _ in 0..100 {
        if body.attachment.surface_id() == Some(monitor_edge_id) && body.position.y < 636.0 {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
        body = handle.body(binding.body_id).expect("body");
    }

    assert_eq!(body.id, binding.body_id);
    assert_eq!(body.attachment.surface_id(), Some(monitor_edge_id));
    assert!(body.position.y < 636.0, "climb command moves upward");

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn autonomous_climb_continues_a_user_attached_current_monitor_edge() {
    let bus = InProcessBus::new();
    let monitor_owner = WorldEntityId::new();
    let floor = owned(floor_surface(), monitor_owner);
    let monitor_edge = owned(
        climbable_monitor_edge(824.0, 0.0, 700.0, -1.0),
        monitor_owner,
    );
    let monitor_edge_id = monitor_edge.id;
    let window_edge = climbable_window_edge(804.0, 0.0, 700.0);
    let window_edge_id = window_edge.id;
    let world = DesktopWorldSnapshot {
        surfaces: vec![floor, window_edge, monitor_edge],
        ..empty_world()
    };
    let mut loop_owner = KernelDesktopPhysicsLoop::start(
        bus.clone(),
        KernelDesktopPhysicsConfig {
            fixed_step: Duration::from_millis(10),
            ..KernelDesktopPhysicsConfig::default()
        },
        KernelDesktopPhysicsLoopConfig {
            tick_interval: Duration::from_millis(10),
        },
        Arc::new(RwLock::new(Some(world))),
    )
    .expect("physics loop");
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(
        bus,
        CompanionPhysicsBodyConfig {
            default_x: 760.0,
            ..CompanionPhysicsBodyConfig::default()
        },
    );
    let binding = bindings.bind("aiko", None, &handle).expect("bind");
    let mut body = handle.body(binding.body_id).expect("body");
    body.position = Point2::new(760.0, 500.0);
    body.attachment = AttachmentState::Attached {
        attachment: SurfaceAttachment {
            surface_id: monitor_edge_id,
            anchor: Point2::new(824.0, 500.0),
            normal: Vector2::new(-1.0, 0.0),
        },
    };
    handle
        .replace_body(binding.body_id, body)
        .expect("user edge attachment");

    bindings
        .enqueue_autonomous_surface_action("aiko", CompanionMovementCommand::ClimbUp, &handle)
        .expect("current monitor edge climb");
    let mut climbed = handle.body(binding.body_id).expect("climbed body");
    for _ in 0..100 {
        if climbed.attachment.surface_id() == Some(monitor_edge_id) && climbed.position.y < 500.0 {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
        climbed = handle.body(binding.body_id).expect("climbed body");
    }

    assert_eq!(climbed.id, binding.body_id);
    assert_eq!(climbed.attachment.surface_id(), Some(monitor_edge_id));
    assert!(
        climbed.position.y < 500.0,
        "climb keeps the user-selected edge"
    );

    let mut window_attached = climbed;
    window_attached.attachment = AttachmentState::Attached {
        attachment: SurfaceAttachment {
            surface_id: window_edge_id,
            anchor: Point2::new(804.0, window_attached.position.y),
            normal: Vector2::new(-1.0, 0.0),
        },
    };
    handle
        .replace_body(binding.body_id, window_attached)
        .expect("window attachment");
    let rejected = bindings.enqueue_autonomous_surface_action(
        "aiko",
        CompanionMovementCommand::ClimbUp,
        &handle,
    );
    assert!(matches!(
        rejected,
        Err(CompanionPhysicsBindingError::AutonomousActionRequiresCurrentMonitorSurface { .. })
    ));

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn autonomous_teleport_stays_on_current_floor_and_preserves_body_identity() {
    let bus = InProcessBus::new();
    let presentation = bus.subscribe(COMPANION_PRESENTATION_STATE);
    let monitor_owner = WorldEntityId::new();
    let floor = owned(floor_surface(), monitor_owner);
    let floor_id = floor.id;
    let world = DesktopWorldSnapshot {
        surfaces: vec![floor],
        ..empty_world()
    };
    let mut loop_owner = KernelDesktopPhysicsLoop::start(
        bus.clone(),
        KernelDesktopPhysicsConfig::default(),
        KernelDesktopPhysicsLoopConfig::default(),
        Arc::new(RwLock::new(Some(world))),
    )
    .expect("physics loop");
    let handle = loop_owner.handle();
    let config = CompanionPhysicsBodyConfig {
        default_x: 200.0,
        ..CompanionPhysicsBodyConfig::default()
    };
    let bindings = CompanionPhysicsBindings::new(bus, config);
    let binding = bindings.bind("aiko", None, &handle).expect("bind");
    presentation
        .recv_timeout(Duration::from_millis(50))
        .expect("initial presentation");

    bindings
        .enqueue_autonomous_surface_action(
            "aiko",
            CompanionMovementCommand::TeleportCurrentMonitor,
            &handle,
        )
        .expect("same-monitor teleport");

    let body = handle.body(binding.body_id).expect("body");
    assert_eq!(body.id, binding.body_id);
    assert_eq!(body.attachment.surface_id(), Some(floor_id));
    assert_eq!(body.position, Point2::new(750.0, 636.0));

    let event = presentation
        .recv_timeout(Duration::from_millis(50))
        .expect("teleport presentation");
    assert_eq!(event.data["bodyId"], binding.body_id.0);
    assert_eq!(event.data["desktopFeet"]["x"], 750.0);
    assert_eq!(event.data["desktopFeet"]["y"], 700.0);
    assert_eq!(event.data["surfaceKind"], "desktop_floor");
    assert_eq!(event.data["updateKind"], "teleport");

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn autonomous_hang_routes_stop_at_kernel_resolved_center_and_far_edge() {
    let bus = InProcessBus::new();
    let presentation = bus.subscribe(COMPANION_PRESENTATION_STATE);
    let monitor_owner = WorldEntityId::new();
    let floor = owned(floor_surface(), monitor_owner);
    let mut monitor_top =
        horizontal_surface_with_kind(0.0, 1_000.0, 0.0, "monitor-top", SurfaceKind::MonitorEdge);
    monitor_top.normal = Vector2::new(0.0, 1.0);
    monitor_top.capabilities = SurfaceCapabilities::HANGABLE;
    let monitor_top = owned(monitor_top, monitor_owner);
    let monitor_top_id = monitor_top.id;
    let monitor_top_normal = monitor_top.normal;
    let world = DesktopWorldSnapshot {
        surfaces: vec![floor, monitor_top],
        ..empty_world()
    };
    let mut loop_owner = KernelDesktopPhysicsLoop::start(
        bus.clone(),
        KernelDesktopPhysicsConfig {
            fixed_step: Duration::from_millis(10),
            ..KernelDesktopPhysicsConfig::default()
        },
        KernelDesktopPhysicsLoopConfig {
            tick_interval: Duration::from_millis(10),
        },
        Arc::new(RwLock::new(Some(world))),
    )
    .expect("physics loop");
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());
    let _bridge = bindings.start_motion_bridge(handle.clone());
    let binding = bindings.bind("aiko", None, &handle).expect("bind");
    let mut hanging = handle.body(binding.body_id).expect("body");
    hanging.position = Point2::new(936.0, 0.0);
    hanging.attachment = AttachmentState::Hanging {
        attachment: SurfaceAttachment {
            surface_id: monitor_top_id,
            anchor: Point2::new(936.0, 0.0),
            normal: monitor_top_normal,
        },
    };
    handle
        .replace_body(binding.body_id, hanging)
        .expect("replace hanging body");

    bindings
        .enqueue_autonomous_surface_action("aiko", CompanionMovementCommand::HangToCenter, &handle)
        .expect("center route");
    let mut centered = handle.body(binding.body_id).expect("center route body");
    for _ in 0..400 {
        if (centered.position.x - 500.0).abs() <= 0.01 && centered.velocity.x.abs() <= 0.01 {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
        centered = handle.body(binding.body_id).expect("center route body");
    }
    assert_eq!(centered.id, binding.body_id);
    assert_eq!(centered.attachment.surface_id(), Some(monitor_top_id));
    assert!((centered.position.x - 500.0).abs() <= 0.01);
    assert!(centered.velocity.x.abs() <= 0.01);
    let arrival = (0..1_000)
        .filter_map(|_| presentation.recv_timeout(Duration::from_millis(20)).ok())
        .find(|event| event.data["updateKind"] == "route-arrived")
        .expect("Kernel publishes the zero-velocity hang-route arrival");
    assert_eq!(arrival.data["movementState"], "hanging");
    assert_eq!(arrival.data["attachmentState"], "hanging");
    assert_eq!(arrival.data["velocity"]["x"], 0.0);
    assert_eq!(arrival.data["velocity"]["y"], 0.0);

    bindings
        .enqueue_autonomous_surface_action("aiko", CompanionMovementCommand::HangToFarEdge, &handle)
        .expect("far edge route");
    let mut far = handle.body(binding.body_id).expect("far route body");
    for _ in 0..400 {
        if (far.position.x - 112.0).abs() <= 0.01 && far.velocity.x.abs() <= 0.01 {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
        far = handle.body(binding.body_id).expect("far route body");
    }
    assert_eq!(far.id, binding.body_id);
    assert_eq!(far.attachment.surface_id(), Some(monitor_top_id));
    assert!(
        (far.position.x - 112.0).abs() <= 0.01,
        "far route must stop at the resolved endpoint; actual x={}, velocity={:?}",
        far.position.x,
        far.velocity
    );
    assert!(far.velocity.x.abs() <= 0.01);

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn autonomous_hang_routes_to_connected_corner_then_climbs_down() {
    let bus = InProcessBus::new();
    let monitor_owner = WorldEntityId::new();
    let floor = owned(floor_surface(), monitor_owner);
    let left_edge = owned(climbable_monitor_edge(0.0, 0.0, 700.0, 1.0), monitor_owner);
    let right_edge = owned(
        climbable_monitor_edge(1_000.0, 0.0, 700.0, -1.0),
        monitor_owner,
    );
    let right_edge_id = right_edge.id;
    let mut monitor_top =
        horizontal_surface_with_kind(0.0, 1_000.0, 0.0, "monitor-top", SurfaceKind::MonitorEdge);
    monitor_top.normal = Vector2::new(0.0, 1.0);
    monitor_top.capabilities = SurfaceCapabilities::HANGABLE;
    let monitor_top = owned(monitor_top, monitor_owner);
    let monitor_top_id = monitor_top.id;
    let monitor_top_normal = monitor_top.normal;
    let world = DesktopWorldSnapshot {
        surfaces: vec![floor, left_edge, right_edge, monitor_top],
        ..empty_world()
    };
    let mut loop_owner = KernelDesktopPhysicsLoop::start(
        bus.clone(),
        KernelDesktopPhysicsConfig {
            fixed_step: Duration::from_millis(10),
            ..KernelDesktopPhysicsConfig::default()
        },
        KernelDesktopPhysicsLoopConfig {
            tick_interval: Duration::from_millis(10),
        },
        Arc::new(RwLock::new(Some(world))),
    )
    .expect("physics loop");
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());
    let _bridge = bindings.start_motion_bridge(handle.clone());
    let binding = bindings.bind("aiko", None, &handle).expect("bind");
    let mut hanging = handle.body(binding.body_id).expect("body");
    hanging.position = Point2::new(500.0, 0.0);
    hanging.attachment = AttachmentState::Hanging {
        attachment: SurfaceAttachment {
            surface_id: monitor_top_id,
            anchor: Point2::new(500.0, 0.0),
            normal: monitor_top_normal,
        },
    };
    handle
        .replace_body(binding.body_id, hanging)
        .expect("replace hanging body");

    bindings
        .enqueue_autonomous_surface_action(
            "aiko",
            CompanionMovementCommand::HangToClimbDownEdge,
            &handle,
        )
        .expect("climb-down corner route");
    let mut corner = handle.body(binding.body_id).expect("corner route body");
    for _ in 0..300 {
        if (corner.position.x - 936.0).abs() <= 0.01 && corner.velocity.x.abs() <= 0.01 {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
        corner = handle.body(binding.body_id).expect("corner route body");
    }
    assert_eq!(corner.attachment.surface_id(), Some(monitor_top_id));
    assert!(
        (corner.position.x - 936.0).abs() <= 0.01,
        "climb-down route reaches the connected right corner; actual x={} attachment={:?}",
        corner.position.x,
        corner.attachment
    );
    assert!(corner.velocity.x.abs() <= 0.01);

    bindings
        .enqueue_autonomous_surface_action("aiko", CompanionMovementCommand::ClimbDown, &handle)
        .expect("autonomous climb down");
    let mut descending = handle.body(binding.body_id).expect("descending body");
    for _ in 0..60 {
        if descending.position.y > 1.0 {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
        descending = handle.body(binding.body_id).expect("descending body");
    }
    assert_eq!(descending.attachment.surface_id(), Some(right_edge_id));
    assert!(descending.position.y > 0.0, "climb-down moves downward");
    assert!(descending.velocity.y > 0.0);

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn autonomous_hang_traverses_current_monitor_top_then_detach_resumes_gravity() {
    let bus = InProcessBus::new();
    let presentation = bus.subscribe(COMPANION_PRESENTATION_STATE);
    let monitor_owner = WorldEntityId::new();
    let floor = owned(floor_surface(), monitor_owner);
    let floor_id = floor.id;
    let mut window_top =
        horizontal_surface_with_kind(100.0, 900.0, 0.0, "window-top", SurfaceKind::WindowTop);
    window_top.capabilities = SurfaceCapabilities::HANGABLE;
    let window_top = owned(window_top, WorldEntityId::new());
    let edge = owned(
        climbable_monitor_edge(824.0, 0.0, 700.0, -1.0),
        monitor_owner,
    );
    let edge_id = edge.id;
    let edge_normal = edge.normal;
    let mut monitor_top =
        horizontal_surface_with_kind(0.0, 1_000.0, 0.0, "monitor-top", SurfaceKind::MonitorEdge);
    monitor_top.normal = Vector2::new(0.0, 1.0);
    monitor_top.capabilities = SurfaceCapabilities::HANGABLE;
    let monitor_top = owned(monitor_top, monitor_owner);
    let monitor_top_id = monitor_top.id;
    let taskbar_top = owned(
        horizontal_surface_with_kind(0.0, 1_000.0, 650.0, "taskbar-top", SurfaceKind::TaskbarTop),
        WorldEntityId::new(),
    );
    let world = DesktopWorldSnapshot {
        surfaces: vec![floor, window_top, edge, monitor_top, taskbar_top],
        ..empty_world()
    };
    let mut loop_owner = KernelDesktopPhysicsLoop::start(
        bus.clone(),
        KernelDesktopPhysicsConfig {
            fixed_step: Duration::from_millis(10),
            ..KernelDesktopPhysicsConfig::default()
        },
        KernelDesktopPhysicsLoopConfig {
            tick_interval: Duration::from_millis(10),
        },
        Arc::new(RwLock::new(Some(world))),
    )
    .expect("physics loop");
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());
    let _bridge = bindings.start_motion_bridge(handle.clone());
    let binding = bindings.bind("aiko", None, &handle).expect("bind");
    let mut hanging = handle.body(binding.body_id).expect("body");
    hanging.position = Point2::new(760.0, 0.0);
    hanging.attachment = AttachmentState::Hanging {
        attachment: SurfaceAttachment {
            surface_id: edge_id,
            anchor: Point2::new(824.0, 0.0),
            normal: edge_normal,
        },
    };
    handle
        .replace_body(binding.body_id, hanging)
        .expect("replace hanging body");

    bindings
        .enqueue_autonomous_surface_action("aiko", CompanionMovementCommand::HangLeft, &handle)
        .expect("hang left");
    let mut left = handle.body(binding.body_id).expect("left command body");
    for _ in 0..100 {
        if left.attachment.surface_id() == Some(monitor_top_id)
            && left.position.x < 760.0
            && left.velocity.x < 0.0
        {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
        left = handle.body(binding.body_id).expect("left hanging body");
    }
    assert_eq!(left.id, binding.body_id);
    assert!(matches!(left.attachment, AttachmentState::Hanging { .. }));
    assert_eq!(left.attachment.surface_id(), Some(monitor_top_id));
    assert!(left.position.x < 760.0, "hang-left traverses monitor top");
    assert!(left.velocity.x < 0.0);

    bindings
        .enqueue_autonomous_surface_action("aiko", CompanionMovementCommand::HangRight, &handle)
        .expect("hang right");
    let mut right = handle.body(binding.body_id).expect("right command body");
    for _ in 0..100 {
        if right.position.x > left.position.x && right.velocity.x > 0.0 {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
        right = handle.body(binding.body_id).expect("right hanging body");
    }
    assert_eq!(right.attachment.surface_id(), Some(monitor_top_id));
    assert!(
        right.position.x > left.position.x,
        "hang-right reverses traversal"
    );
    assert!(right.velocity.x > 0.0);

    bindings
        .enqueue_autonomous_surface_action("aiko", CompanionMovementCommand::Detach, &handle)
        .expect("detach");
    let mut falling = handle.body(binding.body_id).expect("detach command body");
    for _ in 0..100 {
        if matches!(falling.attachment, AttachmentState::Detached) && falling.velocity.y > 0.0 {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
        falling = handle.body(binding.body_id).expect("falling body");
    }
    assert_eq!(falling.id, binding.body_id);
    assert!(matches!(falling.attachment, AttachmentState::Detached));
    assert!(falling.velocity.y > 0.0, "gravity resumes after detach");

    let mut landed = handle.body(binding.body_id).expect("falling body");
    for _ in 0..150 {
        if landed.attachment.surface_id() == Some(floor_id) {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
        landed = handle.body(binding.body_id).expect("landing body");
    }
    assert_eq!(landed.id, binding.body_id);
    assert!(matches!(
        landed.attachment,
        AttachmentState::Grounded { .. }
    ));
    assert_eq!(
        landed.attachment.surface_id(),
        Some(floor_id),
        "autonomous fall skips application surfaces and returns to current floor"
    );
    let corrected = (0..200)
        .filter_map(|_| presentation.recv_timeout(Duration::from_millis(20)).ok())
        .find(|event| event.data["updateKind"] == "correction")
        .expect("authoritative landing correction");
    assert_eq!(corrected.data["movementState"], "stationary");
    assert_eq!(corrected.data["surfaceKind"], "desktop_floor");

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn autonomous_actions_are_suppressed_on_application_window_top() {
    let bus = InProcessBus::new();
    let monitor_owner = WorldEntityId::new();
    let window_owner = WorldEntityId::new();
    let floor = owned(floor_surface(), monitor_owner);
    let window_top = owned(
        horizontal_surface_with_kind(100.0, 900.0, 500.0, "window-top", SurfaceKind::WindowTop),
        window_owner,
    );
    let window_top_id = window_top.id;
    let window_normal = window_top.normal;
    let world = DesktopWorldSnapshot {
        surfaces: vec![floor, window_top],
        ..empty_world()
    };
    let mut loop_owner = KernelDesktopPhysicsLoop::start(
        bus.clone(),
        KernelDesktopPhysicsConfig::default(),
        KernelDesktopPhysicsLoopConfig::default(),
        Arc::new(RwLock::new(Some(world))),
    )
    .expect("physics loop");
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());
    let binding = bindings.bind("aiko", None, &handle).expect("bind");
    let mut sitting = handle.body(binding.body_id).expect("body");
    sitting.position = Point2::new(640.0, 436.0);
    sitting.attachment = AttachmentState::Grounded {
        attachment: SurfaceAttachment {
            surface_id: window_top_id,
            anchor: Point2::new(640.0, 500.0),
            normal: window_normal,
        },
    };
    handle
        .replace_body(binding.body_id, sitting)
        .expect("replace sitting body");

    for command in [
        CompanionMovementCommand::WalkLeft {
            edge_behavior: WalkEdgeBehavior::StopAtEdge,
        },
        CompanionMovementCommand::ClimbUp,
        CompanionMovementCommand::ClimbDown,
        CompanionMovementCommand::HangToCenter,
        CompanionMovementCommand::HangToFarEdge,
        CompanionMovementCommand::HangToClimbDownEdge,
        CompanionMovementCommand::TeleportCurrentMonitor,
    ] {
        assert!(bindings
            .enqueue_autonomous_surface_action("aiko", command, &handle)
            .is_err());
    }
    let after = handle.body(binding.body_id).expect("body after rejection");
    assert_eq!(after.id, binding.body_id);
    assert_eq!(after.attachment.surface_id(), Some(window_top_id));

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn climb_rejects_distant_window_edge_without_moving_body() {
    let bus = InProcessBus::new();
    let world = DesktopWorldSnapshot {
        surfaces: vec![floor_surface(), climbable_window_edge(900.0, 200.0, 700.0)],
        ..empty_world()
    };
    let mut loop_owner = KernelDesktopPhysicsLoop::start(
        bus.clone(),
        KernelDesktopPhysicsConfig::default(),
        KernelDesktopPhysicsLoopConfig::default(),
        Arc::new(RwLock::new(Some(world))),
    )
    .expect("physics loop");
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());
    let binding = bindings.bind("aiko", None, &handle).expect("bind");
    let before = handle.body(binding.body_id).expect("body before");

    let error = bindings
        .enqueue("aiko", CompanionMovementCommand::ClimbUp, &handle)
        .expect_err("distant edge must be rejected");
    assert!(matches!(
        error,
        CompanionPhysicsBindingError::NoClimbableSurface { .. }
    ));
    assert_eq!(handle.body(binding.body_id), Some(before));

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn climb_uses_recent_drag_height_before_ground_snap() {
    let bus = InProcessBus::new();
    let moved = bus.subscribe(COMPANION_MOVED);
    let presentation = bus.subscribe(COMPANION_PRESENTATION_STATE);
    let edge = climbable_window_edge(564.0, 150.0, 650.0);
    let edge_id = edge.id;
    let world = DesktopWorldSnapshot {
        surfaces: vec![floor_surface(), edge],
        ..empty_world()
    };
    let mut loop_owner = KernelDesktopPhysicsLoop::start(
        bus.clone(),
        KernelDesktopPhysicsConfig::default(),
        KernelDesktopPhysicsLoopConfig::default(),
        Arc::new(RwLock::new(Some(world))),
    )
    .expect("physics loop");
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());
    let _bridge = bindings.start_motion_bridge(handle.clone());
    let binding = bindings.bind("aiko", None, &handle).expect("bind");
    moved
        .recv_timeout(Duration::from_millis(50))
        .expect("initial movement");
    presentation
        .recv_timeout(Duration::from_millis(50))
        .expect("initial presentation");

    let committed = bindings
        .commit_authoritative_position("aiko", Point2::new(564.0, 630.0), &handle)
        .expect("drag commit");
    assert_eq!(
        committed.y, 700.0,
        "a nearby floor remains a valid snap target"
    );

    bindings
        .enqueue("aiko", CompanionMovementCommand::ClimbUp, &handle)
        .expect("recent drag edge remains the climb target");
    let mut body = handle.body(binding.body_id).expect("body");
    for _ in 0..100 {
        if body.attachment.surface_id() == Some(edge_id) && body.position.y < 630.0 {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
        body = handle.body(binding.body_id).expect("body");
    }

    assert_eq!(body.id, binding.body_id);
    assert_eq!(body.attachment.surface_id(), Some(edge_id));
    assert!(
        body.position.y < 630.0,
        "climb continues from drag height; actual center y={}",
        body.position.y
    );
    let climbing = (0..10)
        .filter_map(|_| presentation.recv_timeout(Duration::from_millis(20)).ok())
        .find(|event| event.data["movementState"] == "climbing")
        .expect("climbing presentation event");
    assert_eq!(climbing.data["facing"], "right");

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn binding_prefers_broad_floor_over_nearby_narrow_window_edge() {
    let bus = InProcessBus::new();
    let broad = horizontal_surface(0.0, 1_920.0, 760.0, "broad-floor");
    let broad_id = broad.id;
    let narrow = horizontal_surface_with_kind(
        560.0,
        760.0,
        600.0,
        "narrow-window-edge",
        SurfaceKind::WindowTop,
    );
    let world = DesktopWorldSnapshot {
        surfaces: vec![narrow, broad],
        virtual_desktop_bounds: Bounds(Rect::new(0.0, 0.0, 1_920.0, 1_080.0)),
        ..empty_world()
    };
    let mut loop_owner = KernelDesktopPhysicsLoop::start(
        bus.clone(),
        KernelDesktopPhysicsConfig {
            fixed_step: Duration::from_millis(10),
            ..KernelDesktopPhysicsConfig::default()
        },
        KernelDesktopPhysicsLoopConfig {
            tick_interval: Duration::from_millis(10),
        },
        Arc::new(RwLock::new(Some(world))),
    )
    .expect("physics loop");
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(
        bus.clone(),
        CompanionPhysicsBodyConfig {
            default_x: 640.0,
            default_y: 600.0,
            ..CompanionPhysicsBodyConfig::default()
        },
    );
    let bound = bus.subscribe(COMPANION_PHYSICS_BOUND);

    bindings.bind("aiko", None, &handle).expect("bind");
    let event = bound
        .recv_timeout(Duration::from_millis(50))
        .expect("bound event");

    assert_eq!(event.data["surfaceId"], json!(broad_id));
    assert_eq!(event.data["position"]["y"], 760.0);

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn companion_commands_map_to_typed_physics_commands() {
    assert_eq!(
        CompanionMovementCommand::WalkLeft {
            edge_behavior: WalkEdgeBehavior::StopAtEdge,
        }
        .into_physics(),
        Some(PhysicsCommand::Walk {
            direction: WalkDirection::Left,
            edge_behavior: WalkEdgeBehavior::StopAtEdge,
        }),
    );
    assert_eq!(
        CompanionMovementCommand::JumpRight.into_physics(),
        Some(PhysicsCommand::Jump {
            direction: JumpDirection::Right,
        }),
    );
    assert_eq!(
        CompanionMovementCommand::TeleportCurrentMonitor.into_physics(),
        None
    );
}

#[test]
fn character_motion_translates_to_companion_motion() {
    let bus = InProcessBus::new();
    let moved = bus.subscribe(COMPANION_MOVED);
    let mut loop_owner = physics(bus.clone());
    let handle = loop_owner.handle();
    let bindings =
        CompanionPhysicsBindings::new(bus.clone(), CompanionPhysicsBodyConfig::default());
    let binding = bindings.bind("aiko", None, &handle).expect("bind");

    // Binding now publishes an authoritative initial visual snapshot. Consume
    // and verify it before asserting the continuous event translated by the
    // character-motion bridge.
    let initial = moved
        .recv_timeout(Duration::from_millis(100))
        .expect("initial authoritative movement");
    assert_eq!(initial.data["companionId"], "aiko");
    assert_eq!(initial.data["bodyId"], json!(binding.body_id));
    assert_eq!(initial.data["motion"], "authoritative-snap");
    let initial_sequence = initial.data["sequence"].as_u64().expect("initial sequence");
    assert_eq!(initial.data["sequence"], 1);

    let _bridge = bindings.start_motion_bridge(handle.clone());

    let event = Envelope::new(
        "ocp.character.moved",
        "test",
        json!({
            "body_id": binding.body_id,
            "previous_position": Point2::new(10.0, 10.0),
            "position": Point2::new(20.0, 30.0),
            "velocity": Vector2::new(10.0, 20.0),
        }),
    )
    .expect("movement");
    bus.publish(event).expect("publish");

    let translated = moved
        .recv_timeout(Duration::from_millis(100))
        .expect("translated event");

    assert_eq!(translated.data["companionId"], "aiko");
    assert_eq!(translated.data["bodyId"], json!(binding.body_id),);
    assert_eq!(translated.data["position"]["space"], "desktop-logical");
    assert_eq!(translated.data["position"]["anchor"], "character-feet");
    assert_eq!(translated.data["motion"], "continuous");
    let translated_sequence = translated.data["sequence"]
        .as_u64()
        .expect("continuous sequence");
    assert!(
        translated_sequence > initial_sequence,
        "continuous movement must follow the authoritative bind snapshot"
    );
    assert_eq!(translated.data["movementState"], "airborne-falling");

    let second = Envelope::new(
        "ocp.character.moved",
        "test",
        json!({
            "body_id": binding.body_id,
            "previous_position": Point2::new(20.0, 30.0),
            "position": Point2::new(21.0, 30.0),
            "velocity": Vector2::new(1.0, 0.0),
        }),
    )
    .expect("second movement");
    bus.publish(second).expect("publish second");

    let translated_second = moved
        .recv_timeout(Duration::from_millis(100))
        .expect("second translated event");
    let translated_second_sequence = translated_second.data["sequence"]
        .as_u64()
        .expect("second continuous sequence");
    assert!(
        translated_second_sequence > translated_sequence,
        "second continuous movement must follow the first continuous movement"
    );
    assert_eq!(translated_second.data["movementState"], "walking");

    let climbing = Envelope::new(
        "ocp.character.moved",
        "test",
        json!({
            "body_id": binding.body_id,
            "previous_position": Point2::new(21.0, 30.0),
            "position": Point2::new(21.0, 29.0),
            "velocity": Vector2::new(0.0, -120.0),
            "state": "climbing",
        }),
    )
    .expect("climbing movement");
    bus.publish(climbing).expect("publish climbing");

    let translated_climbing = moved
        .recv_timeout(Duration::from_millis(100))
        .expect("translated climbing event");
    assert_eq!(translated_climbing.data["bodyId"], json!(binding.body_id));
    assert_eq!(translated_climbing.data["movementState"], "climbing");
    assert_eq!(translated_climbing.data["attachmentState"], "attached");
    assert_eq!(translated_climbing.data["grounded"], false);

    let climb_endpoint = Envelope::new(
        "ocp.character.moved",
        "test",
        json!({
            "body_id": binding.body_id,
            "previous_position": Point2::new(21.0, 599.0),
            "position": Point2::new(21.0, 600.0),
            "velocity": Vector2::ZERO,
            "state": "climbing",
        }),
    )
    .expect("climb endpoint movement");
    bus.publish(climb_endpoint).expect("publish climb endpoint");

    let translated_endpoint = moved
        .recv_timeout(Duration::from_millis(100))
        .expect("translated climb endpoint event");
    assert_eq!(translated_endpoint.data["movementState"], "climb-ready");
    assert_eq!(translated_endpoint.data["attachmentState"], "attached");
    assert_eq!(translated_endpoint.data["grounded"], false);

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn repeated_walk_stop_walk_rebinds_without_rejection() {
    let bus = InProcessBus::new();
    let rejected = bus.subscribe("ocp.physics.command-rejected");
    let mut loop_owner = physics(bus.clone());
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());

    bindings.bind("aiko", None, &handle).expect("bind");
    for _ in 0..5 {
        bindings
            .enqueue(
                "aiko",
                CompanionMovementCommand::WalkRight {
                    edge_behavior: WalkEdgeBehavior::StopAtEdge,
                },
                &handle,
            )
            .expect("walk");
        std::thread::sleep(Duration::from_millis(20));
        bindings
            .enqueue("aiko", CompanionMovementCommand::Stop, &handle)
            .expect("stop");
        std::thread::sleep(Duration::from_millis(20));
    }

    assert!(
        rejected.try_recv().is_err(),
        "repeated movement must not reject"
    );
    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn bind_emits_initial_authoritative_visual_snapshot() {
    let bus = InProcessBus::new();
    let moved = bus.subscribe(COMPANION_MOVED);
    let mut loop_owner = physics(bus.clone());
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());

    let binding = bindings.bind("aiko", None, &handle).expect("bind");
    let event = moved
        .recv_timeout(Duration::from_millis(50))
        .expect("initial companion movement");

    assert_eq!(event.data["companionId"], "aiko");
    assert_eq!(event.data["bodyId"], json!(binding.body_id));
    assert_eq!(event.data["movementState"], "stationary");
    assert_eq!(event.data["motion"], "authoritative-snap");
    assert_eq!(event.data["grounded"], true);
    assert_eq!(event.data["position"]["anchor"], "character-feet");
    assert_eq!(event.data["position"]["y"], 700.0);

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn repeated_grounded_commands_preserve_body_identity() {
    let bus = InProcessBus::new();
    let mut loop_owner = physics(bus.clone());
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());

    let binding = bindings.bind("aiko", None, &handle).expect("bind");
    for _ in 0..5 {
        bindings
            .enqueue(
                "aiko",
                CompanionMovementCommand::WalkRight {
                    edge_behavior: WalkEdgeBehavior::StopAtEdge,
                },
                &handle,
            )
            .expect("walk");
        bindings
            .enqueue("aiko", CompanionMovementCommand::Stop, &handle)
            .expect("stop");
        assert_eq!(bindings.binding("aiko"), Some(binding));
    }

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn airborne_walk_does_not_replace_the_canonical_body() {
    let bus = InProcessBus::new();
    let mut loop_owner = physics(bus.clone());
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());

    let binding = bindings.bind("aiko", None, &handle).expect("bind");
    bindings
        .enqueue("aiko", CompanionMovementCommand::JumpVertical, &handle)
        .expect("jump");
    std::thread::sleep(Duration::from_millis(20));

    let result = bindings.enqueue(
        "aiko",
        CompanionMovementCommand::WalkRight {
            edge_behavior: WalkEdgeBehavior::StopAtEdge,
        },
        &handle,
    );

    if let Err(error) = result {
        assert!(matches!(
            error,
            ocp_kernel::companion_physics_binding::CompanionPhysicsBindingError::BodyAirborne { .. }
        ));
    }

    assert_eq!(
        bindings.binding("aiko"),
        Some(binding),
        "an airborne follow-up command must never replace the canonical body"
    );

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn authoritative_drag_commit_preserves_body_identity_and_publishes_snap() {
    let bus = InProcessBus::new();
    let moved = bus.subscribe(COMPANION_MOVED);
    let mut loop_owner = physics(bus.clone());
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());

    let original = bindings.bind("aiko", None, &handle).expect("bind");
    moved
        .recv_timeout(Duration::from_millis(50))
        .expect("initial movement");

    let committed = bindings
        .commit_authoritative_position("aiko", Point2::new(320.0, 640.0), &handle)
        .expect("drag commit");

    assert_eq!(bindings.binding("aiko"), Some(original));
    assert_eq!(committed.x, 320.0);
    assert_eq!(committed.y, 700.0);

    let snap = moved
        .recv_timeout(Duration::from_millis(50))
        .expect("authoritative snap");
    assert_eq!(snap.data["bodyId"], json!(original.body_id));
    assert_eq!(snap.data["motion"], "authoritative-snap");
    assert_eq!(snap.data["movementState"], "stationary");
    assert_eq!(snap.data["position"]["x"], 320.0);
    assert_eq!(snap.data["position"]["y"], 700.0);

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn drag_onto_active_window_top_publishes_sitting_and_preserves_body_identity() {
    let bus = InProcessBus::new();
    let presentation = bus.subscribe(COMPANION_PRESENTATION_STATE);
    let window_id = WindowId::new();
    let window_entity = WorldEntityId::new();
    let mut window_top = horizontal_surface_with_kind(
        200.0,
        800.0,
        500.0,
        "active-window-top",
        SurfaceKind::WindowTop,
    );
    window_top.owner_entity_id = Some(window_entity);
    let world = DesktopWorldSnapshot {
        windows: vec![Window {
            id: window_id,
            entity_id: window_entity,
            application_id: "notepad.exe".to_owned(),
            title_classification: Some("editor".to_owned()),
            bounds: Rect::new(200.0, 500.0, 600.0, 300.0),
            client_bounds: None,
            frame_bounds: None,
            z_order: 0,
            active: true,
            minimized: false,
            visible: true,
            occluded: false,
            workspace_id: None,
        }],
        active_window_id: Some(window_id),
        surfaces: vec![window_top, floor_surface()],
        ..empty_world()
    };
    let mut loop_owner = KernelDesktopPhysicsLoop::start(
        bus.clone(),
        KernelDesktopPhysicsConfig::default(),
        KernelDesktopPhysicsLoopConfig::default(),
        Arc::new(RwLock::new(Some(world))),
    )
    .expect("physics loop");
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());
    let original = bindings.bind("aiko", None, &handle).expect("bind");
    presentation
        .recv_timeout(Duration::from_millis(50))
        .expect("spawn presentation");

    let committed = bindings
        .commit_authoritative_position("aiko", Point2::new(400.0, 540.0), &handle)
        .expect("active window drag commit");
    let sitting = presentation
        .recv_timeout(Duration::from_millis(50))
        .expect("sitting presentation");

    assert_eq!(committed, Point2::new(400.0, 500.0));
    assert_eq!(sitting.data["bodyId"], json!(original.body_id));
    assert_eq!(sitting.data["movementState"], "sitting");
    assert_eq!(sitting.data["surfaceKind"], "window_top");
    assert_eq!(bindings.binding("aiko"), Some(original));

    let airborne = Envelope::new(
        "ocp.character.moved",
        "physics",
        json!({
            "body_id": original.body_id,
            "position": { "x": 400.0, "y": 400.0 },
            "velocity": { "x": 0.0, "y": 120.0 },
            "state": "airborne"
        }),
    )
    .expect("airborne event");
    let falling = bindings
        .translate_character_moved(&airborne, &handle)
        .expect("falling presentation");
    assert_eq!(falling.data["movementState"], "airborne-falling");

    let landed = Envelope::new(
        "ocp.character.moved",
        "physics",
        json!({
            "body_id": original.body_id,
            "position": { "x": 400.0, "y": 848.0 },
            "velocity": { "x": 0.0, "y": 0.0 },
            "state": "idle"
        }),
    )
    .expect("landed event");
    let stationary = bindings
        .translate_character_moved(&landed, &handle)
        .expect("stationary presentation");
    assert_eq!(stationary.data["movementState"], "stationary");

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn drag_within_practical_active_window_snap_band_publishes_sitting() {
    let bus = InProcessBus::new();
    let presentation = bus.subscribe(COMPANION_PRESENTATION_STATE);
    let window_id = WindowId::new();
    let window_entity = WorldEntityId::new();
    let mut window_top = horizontal_surface_with_kind(
        200.0,
        800.0,
        500.0,
        "active-window-top",
        SurfaceKind::WindowTop,
    );
    window_top.owner_entity_id = Some(window_entity);
    let world = DesktopWorldSnapshot {
        windows: vec![Window {
            id: window_id,
            entity_id: window_entity,
            application_id: "notepad.exe".to_owned(),
            title_classification: Some("editor".to_owned()),
            bounds: Rect::new(200.0, 500.0, 600.0, 180.0),
            client_bounds: None,
            frame_bounds: None,
            z_order: 0,
            active: true,
            minimized: false,
            visible: true,
            occluded: false,
            workspace_id: None,
        }],
        active_window_id: Some(window_id),
        surfaces: vec![window_top, floor_surface()],
        ..empty_world()
    };
    let mut loop_owner = KernelDesktopPhysicsLoop::start(
        bus.clone(),
        KernelDesktopPhysicsConfig::default(),
        KernelDesktopPhysicsLoopConfig::default(),
        Arc::new(RwLock::new(Some(world))),
    )
    .expect("physics loop");
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());
    bindings.bind("aiko", None, &handle).expect("bind");
    presentation
        .recv_timeout(Duration::from_millis(50))
        .expect("spawn presentation");

    let committed = bindings
        .commit_authoritative_position("aiko", Point2::new(400.0, 590.0), &handle)
        .expect("practical active window drag commit");
    let sitting = presentation
        .recv_timeout(Duration::from_millis(50))
        .expect("sitting presentation");

    assert_eq!(committed, Point2::new(400.0, 500.0));
    assert_eq!(sitting.data["movementState"], "sitting");

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn maximized_active_window_does_not_publish_sitting_even_with_stale_surface() {
    let bus = InProcessBus::new();
    let presentation = bus.subscribe(COMPANION_PRESENTATION_STATE);
    let window_id = WindowId::new();
    let window_entity = WorldEntityId::new();
    let mut stale_window_top = horizontal_surface_with_kind(
        0.0,
        1_000.0,
        0.0,
        "stale-maximized-window-top",
        SurfaceKind::WindowTop,
    );
    stale_window_top.owner_entity_id = Some(window_entity);
    let world = DesktopWorldSnapshot {
        monitors: vec![Monitor {
            id: MonitorId::new(),
            entity_id: WorldEntityId::new(),
            name: "Primary".to_owned(),
            bounds: Bounds(Rect::new(0.0, 0.0, 1_000.0, 760.0)),
            work_area: Bounds(Rect::new(0.0, 0.0, 1_000.0, 700.0)),
            scale_factor: 1.0,
            primary: true,
        }],
        windows: vec![Window {
            id: window_id,
            entity_id: window_entity,
            application_id: "notepad.exe".to_owned(),
            title_classification: Some("editor".to_owned()),
            bounds: Rect::new(0.0, 0.0, 1_000.0, 700.0),
            client_bounds: None,
            frame_bounds: None,
            z_order: 0,
            active: true,
            minimized: false,
            visible: true,
            occluded: false,
            workspace_id: None,
        }],
        active_window_id: Some(window_id),
        surfaces: vec![stale_window_top, floor_surface()],
        ..empty_world()
    };
    let mut loop_owner = KernelDesktopPhysicsLoop::start(
        bus.clone(),
        KernelDesktopPhysicsConfig::default(),
        KernelDesktopPhysicsLoopConfig::default(),
        Arc::new(RwLock::new(Some(world))),
    )
    .expect("physics loop");
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());
    bindings.bind("aiko", None, &handle).expect("bind");
    presentation
        .recv_timeout(Duration::from_millis(50))
        .expect("spawn presentation");

    let committed = bindings
        .commit_authoritative_position("aiko", Point2::new(400.0, 80.0), &handle)
        .expect("maximized window drag commit");
    let falling = presentation
        .recv_timeout(Duration::from_millis(50))
        .expect("falling presentation");

    assert_eq!(committed, Point2::new(400.0, 80.0));
    assert_eq!(falling.data["movementState"], "airborne-falling");

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn drag_inside_active_window_away_from_top_does_not_publish_sitting() {
    let bus = InProcessBus::new();
    let presentation = bus.subscribe(COMPANION_PRESENTATION_STATE);
    let window_id = WindowId::new();
    let window_entity = WorldEntityId::new();
    let mut window_top = horizontal_surface_with_kind(
        200.0,
        800.0,
        500.0,
        "active-window-top",
        SurfaceKind::WindowTop,
    );
    window_top.owner_entity_id = Some(window_entity);
    let world = DesktopWorldSnapshot {
        windows: vec![Window {
            id: window_id,
            entity_id: window_entity,
            application_id: "notepad.exe".to_owned(),
            title_classification: Some("editor".to_owned()),
            bounds: Rect::new(200.0, 500.0, 600.0, 300.0),
            client_bounds: None,
            frame_bounds: None,
            z_order: 0,
            active: true,
            minimized: false,
            visible: true,
            occluded: false,
            workspace_id: None,
        }],
        active_window_id: Some(window_id),
        surfaces: vec![window_top, floor_surface()],
        ..empty_world()
    };
    let mut loop_owner = KernelDesktopPhysicsLoop::start(
        bus.clone(),
        KernelDesktopPhysicsConfig::default(),
        KernelDesktopPhysicsLoopConfig::default(),
        Arc::new(RwLock::new(Some(world))),
    )
    .expect("physics loop");
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());
    bindings.bind("aiko", None, &handle).expect("bind");
    presentation
        .recv_timeout(Duration::from_millis(50))
        .expect("spawn presentation");

    let committed = bindings
        .commit_authoritative_position("aiko", Point2::new(400.0, 650.0), &handle)
        .expect("active window interior drag commit");
    let state = presentation
        .recv_timeout(Duration::from_millis(50))
        .expect("drag presentation");

    assert_eq!(committed, Point2::new(400.0, 700.0));
    assert_eq!(state.data["movementState"], "stationary");

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn drag_over_inactive_window_top_does_not_publish_sitting() {
    let bus = InProcessBus::new();
    let presentation = bus.subscribe(COMPANION_PRESENTATION_STATE);
    let window_entity = WorldEntityId::new();
    let mut window_top = horizontal_surface_with_kind(
        200.0,
        800.0,
        500.0,
        "inactive-window-top",
        SurfaceKind::WindowTop,
    );
    window_top.owner_entity_id = Some(window_entity);
    let world = DesktopWorldSnapshot {
        windows: vec![Window {
            id: WindowId::new(),
            entity_id: window_entity,
            application_id: "background.exe".to_owned(),
            title_classification: Some("background".to_owned()),
            bounds: Rect::new(200.0, 500.0, 600.0, 300.0),
            client_bounds: None,
            frame_bounds: None,
            z_order: 1,
            active: false,
            minimized: false,
            visible: true,
            occluded: false,
            workspace_id: None,
        }],
        active_window_id: None,
        surfaces: vec![window_top, floor_surface()],
        ..empty_world()
    };
    let mut loop_owner = KernelDesktopPhysicsLoop::start(
        bus.clone(),
        KernelDesktopPhysicsConfig::default(),
        KernelDesktopPhysicsLoopConfig::default(),
        Arc::new(RwLock::new(Some(world))),
    )
    .expect("physics loop");
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());
    bindings.bind("aiko", None, &handle).expect("bind");
    presentation
        .recv_timeout(Duration::from_millis(50))
        .expect("spawn presentation");

    let committed = bindings
        .commit_authoritative_position("aiko", Point2::new(400.0, 480.0), &handle)
        .expect("inactive window drag commit");
    let state = presentation
        .recv_timeout(Duration::from_millis(50))
        .expect("drag presentation");

    assert_eq!(committed, Point2::new(400.0, 480.0));
    assert_eq!(state.data["movementState"], "airborne-falling");

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn movement_after_drag_uses_committed_canonical_position_without_rebind() {
    let bus = InProcessBus::new();
    let mut loop_owner = physics(bus.clone());
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());

    let original = bindings.bind("aiko", None, &handle).expect("bind");
    bindings
        .commit_authoritative_position("aiko", Point2::new(320.0, 640.0), &handle)
        .expect("drag commit");

    bindings
        .enqueue(
            "aiko",
            CompanionMovementCommand::WalkRight {
                edge_behavior: WalkEdgeBehavior::StopAtEdge,
            },
            &handle,
        )
        .expect("walk after drag");

    let mut body = handle.body(original.body_id).expect("same body");
    for _ in 0..100 {
        if body.position.x > 320.0 {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
        body = handle.body(original.body_id).expect("same body");
    }
    assert_eq!(bindings.binding("aiko"), Some(original));
    assert!(body.position.x > 320.0);

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn binding_prefers_desktop_floor_over_wide_window_top() {
    let bus = InProcessBus::new();
    let window_top = horizontal_surface_with_kind(
        0.0,
        1_920.0,
        600.0,
        "wide-window-top",
        SurfaceKind::WindowTop,
    );
    let floor = horizontal_surface(0.0, 1_920.0, 900.0, "desktop-floor");
    let floor_id = floor.id;
    let world = DesktopWorldSnapshot {
        surfaces: vec![window_top, floor],
        virtual_desktop_bounds: Bounds(Rect::new(0.0, 0.0, 1_920.0, 1_080.0)),
        ..empty_world()
    };
    let mut loop_owner = KernelDesktopPhysicsLoop::start(
        bus.clone(),
        KernelDesktopPhysicsConfig {
            fixed_step: Duration::from_millis(10),
            ..KernelDesktopPhysicsConfig::default()
        },
        KernelDesktopPhysicsLoopConfig {
            tick_interval: Duration::from_millis(10),
        },
        Arc::new(RwLock::new(Some(world))),
    )
    .expect("physics loop");
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(
        bus.clone(),
        CompanionPhysicsBodyConfig {
            default_x: 640.0,
            default_y: 700.0,
            ..CompanionPhysicsBodyConfig::default()
        },
    );
    let bound = bus.subscribe(COMPANION_PHYSICS_BOUND);

    bindings.bind("aiko", None, &handle).expect("bind");
    let event = bound
        .recv_timeout(Duration::from_millis(50))
        .expect("bound event");

    assert_eq!(event.data["surfaceId"], json!(floor_id));
    assert_eq!(event.data["position"]["y"], 900.0);

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn binding_selects_floor_containing_requested_x_on_multi_monitor_desktop() {
    let bus = InProcessBus::new();
    let left_floor = horizontal_surface(-1_920.0, 0.0, 1_080.0, "left-monitor");
    let right_floor = horizontal_surface(0.0, 2_560.0, 1_440.0, "right-monitor");
    let right_id = right_floor.id;
    let world = DesktopWorldSnapshot {
        surfaces: vec![left_floor, right_floor],
        virtual_desktop_bounds: Bounds(Rect::new(-1_920.0, 0.0, 4_480.0, 1_440.0)),
        ..empty_world()
    };
    let mut loop_owner = KernelDesktopPhysicsLoop::start(
        bus.clone(),
        KernelDesktopPhysicsConfig {
            fixed_step: Duration::from_millis(10),
            ..KernelDesktopPhysicsConfig::default()
        },
        KernelDesktopPhysicsLoopConfig {
            tick_interval: Duration::from_millis(10),
        },
        Arc::new(RwLock::new(Some(world))),
    )
    .expect("physics loop");
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(
        bus.clone(),
        CompanionPhysicsBodyConfig {
            default_x: 1_200.0,
            default_y: 700.0,
            ..CompanionPhysicsBodyConfig::default()
        },
    );
    let bound = bus.subscribe(COMPANION_PHYSICS_BOUND);

    bindings.bind("aiko", None, &handle).expect("bind");
    let event = bound
        .recv_timeout(Duration::from_millis(50))
        .expect("bound event");

    assert_eq!(event.data["surfaceId"], json!(right_id));
    assert_eq!(event.data["position"]["x"], 1_200.0);
    assert_eq!(event.data["position"]["y"], 1_440.0);

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn bind_emits_revisioned_canonical_presentation_state() {
    let bus = InProcessBus::new();
    let presentation = bus.subscribe(COMPANION_PRESENTATION_STATE);
    let mut loop_owner = physics(bus.clone());
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());

    let binding = bindings.bind("aiko", None, &handle).expect("bind");
    let event = presentation
        .recv_timeout(Duration::from_millis(50))
        .expect("canonical presentation state");

    assert_eq!(event.data["schemaVersion"], 1);
    assert_eq!(event.data["companionId"], "aiko");
    assert_eq!(event.data["bodyId"], json!(binding.body_id));
    assert_eq!(event.data["desktopFeet"]["space"], "desktop-logical");
    assert_eq!(event.data["desktopFeet"]["anchor"], "character-feet");
    assert_eq!(event.data["movementState"], "stationary");
    assert_eq!(event.data["attachmentState"], "grounded");
    assert_eq!(event.data["surfaceKind"], "desktop_floor");
    assert_eq!(event.data["updateKind"], "spawn");
    assert_eq!(event.data["sequence"], 1);
    assert_eq!(event.data["revision"], 1);

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn drag_commit_emits_new_authoritative_revision() {
    let bus = InProcessBus::new();
    let presentation = bus.subscribe(COMPANION_PRESENTATION_STATE);
    let mut loop_owner = physics(bus.clone());
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());

    bindings.bind("aiko", None, &handle).expect("bind");
    let initial = presentation
        .recv_timeout(Duration::from_millis(50))
        .expect("initial presentation");

    bindings
        .commit_authoritative_position("aiko", Point2::new(320.0, 640.0), &handle)
        .expect("commit");
    let committed = presentation
        .recv_timeout(Duration::from_millis(50))
        .expect("committed presentation");

    assert_eq!(committed.data["updateKind"], "drag-commit");
    assert!(
        committed.data["revision"].as_u64().unwrap() > initial.data["revision"].as_u64().unwrap()
    );

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn drag_release_attaches_to_active_window_top_and_preserves_body_identity() {
    let bus = InProcessBus::new();
    let mut window =
        horizontal_surface_with_kind(300.0, 900.0, 500.0, "window-top", SurfaceKind::WindowTop);
    let window_id = window.id;
    let desktop_window_id = WindowId::new();
    let window_entity = WorldEntityId::new();
    window.owner_entity_id = Some(window_entity);
    let floor = horizontal_surface(0.0, 1_536.0, 1_024.0, "desktop-floor");
    let world = DesktopWorldSnapshot {
        windows: vec![Window {
            id: desktop_window_id,
            entity_id: window_entity,
            application_id: "notepad.exe".to_owned(),
            title_classification: Some("editor".to_owned()),
            bounds: Rect::new(300.0, 500.0, 600.0, 400.0),
            client_bounds: None,
            frame_bounds: None,
            z_order: 0,
            active: true,
            minimized: false,
            visible: true,
            occluded: false,
            workspace_id: None,
        }],
        active_window_id: Some(desktop_window_id),
        surfaces: vec![floor, window],
        virtual_desktop_bounds: Bounds(Rect::new(0.0, 0.0, 1_536.0, 1_024.0)),
        ..empty_world()
    };
    let mut loop_owner = KernelDesktopPhysicsLoop::start(
        bus.clone(),
        KernelDesktopPhysicsConfig {
            fixed_step: Duration::from_millis(10),
            ..KernelDesktopPhysicsConfig::default()
        },
        KernelDesktopPhysicsLoopConfig {
            tick_interval: Duration::from_millis(10),
        },
        Arc::new(RwLock::new(Some(world))),
    )
    .expect("physics loop");
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());
    let binding = bindings.bind("aiko", None, &handle).expect("bind");

    let resolved = bindings
        .commit_authoritative_position("aiko", Point2::new(600.0, 540.0), &handle)
        .expect("window release");
    let body = handle.body(binding.body_id).expect("preserved body");

    assert_eq!(resolved, Point2::new(600.0, 500.0));
    assert_eq!(bindings.binding("aiko"), Some(binding));
    assert_eq!(body.id, binding.body_id);
    assert_eq!(body.attachment.surface_id(), Some(window_id));
    assert!(body.attachment.is_grounded());

    loop_owner.shutdown().expect("shutdown");
}

#[test]
fn drag_release_without_surface_below_stays_airborne_until_solver_lands() {
    let bus = InProcessBus::new();
    let floor = horizontal_surface(0.0, 1_536.0, 1_024.0, "desktop-floor");
    let world = DesktopWorldSnapshot {
        surfaces: vec![floor],
        virtual_desktop_bounds: Bounds(Rect::new(0.0, 0.0, 1_536.0, 1_024.0)),
        ..empty_world()
    };
    let mut loop_owner = KernelDesktopPhysicsLoop::start(
        bus.clone(),
        KernelDesktopPhysicsConfig {
            fixed_step: Duration::from_millis(10),
            ..KernelDesktopPhysicsConfig::default()
        },
        KernelDesktopPhysicsLoopConfig {
            tick_interval: Duration::from_millis(10),
        },
        Arc::new(RwLock::new(Some(world))),
    )
    .expect("physics loop");
    let handle = loop_owner.handle();
    let bindings = CompanionPhysicsBindings::new(bus, CompanionPhysicsBodyConfig::default());
    let binding = bindings.bind("aiko", None, &handle).expect("bind");

    let resolved = bindings
        .commit_authoritative_position("aiko", Point2::new(1_700.0, 300.0), &handle)
        .expect("airborne release");
    let body = handle.body(binding.body_id).expect("body");

    assert_eq!(resolved, Point2::new(1_700.0, 300.0));
    assert_eq!(body.id, binding.body_id);
    assert!(!body.attachment.is_attached());

    loop_owner.shutdown().expect("shutdown");
}
