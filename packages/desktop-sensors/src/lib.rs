//! Desktop sensor contracts, safe adapters and World provider composition.
//!
//! Dependency direction:
//!
//! ```text
//! platform sensors
//! → normalized sensor samples
//! → SensorWorldProvider
//! → DesktopObservationBatch
//! → DesktopWorldService
//! ```
//!
//! Planner, Physics, Navigation and AI consume Desktop World snapshots. They
//! must not query sensors directly.

#![forbid(unsafe_code)]

pub mod adapter;
pub mod error;
pub mod identity;
pub mod sample;
pub mod surface_providers;
pub mod traits;
pub mod world_provider;

pub use adapter::LegacyOsSensorsAdapter;
pub use error::DesktopSensorError;
pub use identity::NativeEntityRegistry;
pub use sample::{
    CursorSample, ForegroundWindowSample, MonitorSample, MouseIdleSample, SensorAvailability,
    SensorKind, SensorSource, SensorSuiteSample, TaskbarSample, WindowListSample,
};
pub use surface_providers::{
    DesktopSurfaceProvider, TaskbarSurfaceProvider, WindowSurfaceProvider,
};
pub use traits::{
    CursorSensor, DesktopSensorSuite, ForegroundWindowSensor, MonitorSensor, MouseIdleSensor,
    TaskbarSensor, WindowSensor,
};
pub use world_provider::SensorWorldProvider;
