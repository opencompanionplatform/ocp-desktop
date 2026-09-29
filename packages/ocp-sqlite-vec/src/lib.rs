//! The single scoped-`unsafe` boundary for the sqlite-vec extension (ADR-0010
//! vector search).
//!
//! sqlite-vec is a loadable SQLite extension: it does not link `sqlite3`
//! symbols directly, it is handed the `sqlite3_api_routines` pointer at init
//! time. The only way to make it available to every rusqlite `Connection` in
//! the process is to register its C entrypoint with SQLite's
//! `sqlite3_auto_extension` — one `unsafe` FFI call, exactly as sqlite-vec's
//! own Rust docs prescribe.
//!
//! That one call is wrapped in the safe [`register`] here so that
//! `ocp-memory` (and anything else) can use vector search while staying
//! `#![forbid(unsafe_code)]` — the same boundary role `packages/os-sensors`
//! plays for I4's raw Win32 FFI. This crate is therefore deliberately *not*
//! `forbid(unsafe_code)`; it is the designated exception, and its unsafe is a
//! single, documented, upstream-prescribed line.

#![deny(unsafe_op_in_unsafe_fn)]

use std::sync::Once;

static REGISTER_ONCE: Once = Once::new();

/// Registers sqlite-vec as a SQLite auto-extension for the current process, so
/// every rusqlite `Connection` opened *after* this call has the `vec_*`
/// scalar functions and `vec0` virtual table available. Idempotent — safe to
/// call from many places; the underlying registration happens exactly once
/// (guarded by a [`Once`]), which also sidesteps the process-wide
/// double-registration question entirely.
///
/// Call this before opening the connection(s) that will use vector search.
pub fn register() {
    REGISTER_ONCE.call_once(|| {
        // SAFETY: `sqlite_vec::sqlite3_vec_init` is the standard SQLite
        // extension entrypoint with the C ABI `int(sqlite3*, char**,
        // const sqlite3_api_routines*)`. `sqlite3_auto_extension` stores this
        // function pointer and invokes it — with a valid api-routines pointer —
        // on each new database connection. The transmute erases the concrete
        // fn type to the untyped `xEntryPoint` that `sqlite3_auto_extension`
        // expects; this exact pattern is what sqlite-vec's official rusqlite
        // documentation specifies. No Rust value crosses the boundary here, so
        // there are no lifetime/aliasing concerns beyond the function pointer
        // itself, which is `'static`.
        unsafe {
            rusqlite::ffi::sqlite3_auto_extension(Some(std::mem::transmute::<
                *const (),
                unsafe extern "C" fn(
                    *mut rusqlite::ffi::sqlite3,
                    *mut *mut i8,
                    *const rusqlite::ffi::sqlite3_api_routines,
                ) -> i32,
            >(
                sqlite_vec::sqlite3_vec_init as *const (),
            )));
        }
    });
}
