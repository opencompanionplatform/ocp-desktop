//! Authoritative Desktop World contracts.
//!
//! This crate owns immutable World snapshots, reconciliation inputs, Surface
//! provider contracts, query APIs and World diffs. It contains no platform
//! API calls, no Godot dependency and no Physics or Navigation implementation.

#![forbid(unsafe_code)]

pub mod diff;
pub mod error;
pub mod observation;
pub mod provider;
pub mod query;
pub mod service;
pub mod snapshot;
pub mod surface;

pub use diff::{DesktopWorldChange, DesktopWorldDiff, WindowChangeKind};
pub use error::DesktopWorldError;
pub use observation::{
    DesktopObservationBatch, MonitorObservation, ObservationSource, TaskbarObservation,
    WindowObservation,
};
pub use provider::{DesktopWorldProvider, SurfaceProvider};
pub use query::{SurfaceQuery, WindowQuery};
pub use service::DesktopWorldService;
pub use snapshot::{
    ActiveApplication, DesktopWorldCapabilities, DesktopWorldSnapshot, ObstacleDescriptor,
    TaskbarDescriptor,
};

pub use surface::{
    SurfaceBuildError, SurfaceChange, SurfaceEligibilityPolicy, SurfaceFilter,
    SurfaceGeometryQuery, SurfaceKindV2, SurfaceOrientation, SurfaceOwnerV2, SurfaceProjection,
    SurfaceRegistryBuilder, SurfaceRegistryDiff, SurfaceRegistryId, SurfaceRegistrySnapshot,
    SurfaceSegment, SurfaceSupport,
};
