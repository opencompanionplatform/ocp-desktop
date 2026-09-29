//! OCP Runtime Kernel library surface.
//!
//! The production binary remains in `main.rs`. Reusable kernel-owned services
//! are exposed here so they can be tested headlessly without starting IPC,
//! stdin, voice or package loading.

#![forbid(unsafe_code)]

pub mod desktop_world_boot;

pub mod companion_physics_binding;
pub mod desktop_physics_boot;
pub mod desktop_physics_host;
pub mod drag_release_policy;
