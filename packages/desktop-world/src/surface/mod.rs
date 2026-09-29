//! Revisioned Surface Registry derived from an authoritative Desktop World snapshot.
//!
//! RC27 intentionally stops at geometry and registry semantics. It does not own
//! attachment, navigation, behavior, or visual authority.

mod builder;
mod diff;
mod id;
mod kind;
mod owner;
mod policy;
mod query;
mod segment;
mod snapshot;

pub use builder::{SurfaceBuildError, SurfaceRegistryBuilder};
pub use diff::{SurfaceChange, SurfaceRegistryDiff};
pub use id::SurfaceRegistryId;
pub use kind::{SurfaceKindV2, SurfaceOrientation};
pub use owner::SurfaceOwnerV2;
pub use policy::SurfaceEligibilityPolicy;
pub use query::{SurfaceFilter, SurfaceGeometryQuery, SurfaceProjection};
pub use segment::{SurfaceSegment, SurfaceSupport};
pub use snapshot::SurfaceRegistrySnapshot;
