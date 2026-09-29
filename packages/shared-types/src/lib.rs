//! OCP canonical shared types.
//!
//! This crate preserves the approved EVENT_API envelope while adding the
//! canonical Runtime V4 domain vocabulary. Every package must reuse these
//! types rather than defining competing geometry, IDs, World or state types.
//!
//! Binding specs:
//! - ocp-architecture/06-api/EVENT_API.md
//! - ocp-architecture/03-domain/DESKTOP_WORLD_DOMAIN.md
//! - ocp-architecture/06-api/RUNTIME_EVENT_CATALOG.md

#![forbid(unsafe_code)] // SEC-042

pub mod behavior;
pub mod event;
pub mod geometry;
pub mod goal;
pub mod ids;
pub mod intent;
pub mod physics;
pub mod surface;
pub mod world;

// Preserve the existing public API used by event-bus, ipc, plugin-host,
// runtime-api and the desktop GDExtension.
pub use event::{validate_type_name, Envelope, EnvelopeError, CONTEXTS};

pub use behavior::{BehaviorId, BehaviorPriority, BehaviorState};
pub use geometry::{
    Bounds, Direction, HorizontalDirection, Orientation, Point2, Rect, Size2, Transform2, Vector2,
    VerticalDirection,
};
pub use goal::{Goal, GoalStatus, SurfacePlacement};
pub use ids::{
    BodyId, CharacterId, EventId, GoalId, IntentId, MonitorId, PathId, PlanId, SurfaceId, WindowId,
    WorkspaceId, WorldEntityId, WorldId, WorldRevision,
};
pub use intent::{CancellationPolicy, Intent, IntentResult, IntentSource, Interruptibility};
pub use physics::{Acceleration, AttachmentPoint, Collision, CollisionKind, Gravity, Velocity};
pub use surface::{SurfaceCapabilities, SurfaceDescriptor, SurfaceKind, SurfaceStability};
pub use world::{CoordinateSpace, Cursor, Desktop, Monitor, VirtualDesktop, Window, Workspace};
