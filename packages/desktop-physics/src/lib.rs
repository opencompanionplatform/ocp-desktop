//! Deterministic, headless Desktop Physics foundation.
//!
//! This package owns simulation contracts and fixed-step solvers. It reads
//! immutable Desktop World snapshots and never calls platform or Godot APIs.

#![forbid(unsafe_code)]

pub mod attachment;
pub mod body;
pub mod climb;
pub mod collider;
pub mod config;
pub mod contact;
pub mod events;
pub mod jump;
pub mod ledge;
pub mod runtime;
pub mod solver;
pub mod walk;
pub mod world_query;

pub use attachment::{AttachmentState, AttachmentTransition, SurfaceAttachment};
pub use body::{PhysicsBody, PhysicsBodyId};
pub use climb::{
    AttachmentError, ClimbConfig, ClimbDirection, ClimbStepResult, SurfaceAttachmentSolver,
};
pub use collider::AabbCollider;
pub use config::PhysicsConfig;
pub use contact::{Contact, ContactKind};
pub use events::{
    PhysicsAttachmentMode, PhysicsEventPayload, PhysicsEventProjector, PhysicsRuntimeEvent,
    CHARACTER_MOVED, PHYSICS_ATTACHED, PHYSICS_COMMAND_REJECTED, PHYSICS_DETACHED,
    PHYSICS_EVENT_CATALOG, PHYSICS_EVENT_VERSION, PHYSICS_FALLING, PHYSICS_GROUNDED,
    PHYSICS_LANDED,
};
pub use jump::{
    AirborneController, AirbornePhase, AirborneStepResult, JumpConfig, JumpDirection, JumpError,
    JumpMotor, JumpStartResult,
};
pub use ledge::{
    LedgeTransferConfig, LedgeTransferError, LedgeTransferResult, LedgeTransferSolver,
};
pub use runtime::{
    DesktopPhysicsRuntime, FixedStepConfig, PhysicsCommand, PhysicsFrameResult,
    PhysicsRuntimeError, RuntimeBodySnapshot, RuntimeBodyState, RuntimeTransition,
};
pub use solver::{DesktopPhysicsSolver, PhysicsStepResult, PhysicsStepState};
pub use walk::{
    WalkConfig, WalkDirection, WalkEdgeBehavior, WalkError, WalkMotor, WalkStepResult,
    WalkStepState,
};
pub use world_query::{DesktopWorldPhysicsQuery, PhysicsSurface, PhysicsWorldQuery};
