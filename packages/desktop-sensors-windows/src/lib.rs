//! Native Windows Desktop World sensors.
//!
//! This package owns the Windows API boundary and converts native HWND and
//! HMONITOR identities into canonical OCP IDs before data leaves the crate.

#![deny(unsafe_op_in_unsafe_fn)]

mod provider;

#[cfg(windows)]
mod windows_native;

pub use provider::{WindowsCursorMonitorSensors, WindowsDesktopSensors};
