//! WASM execution engine — implements PLUGIN_ABI v1 (Approved 2026-07-19)
//! on wasmtime. One instance per plugin, calls serialized (no reentrancy,
//! ABI §5). Fuel metering + memory cap per store; traps ⇒ `ocp.plugin.crashed`
//! → Suspended, host process unaffected (SEC-004, spike-verified).
//!
//! This slice loads modules whose imports are the `"ocp"` module only.
//! WASI wiring (preopens per filesystem grants) arrives with the SDK slice —
//! real `wasm32-wasip1` guests need it, WAT conformance modules do not.

use std::sync::{Arc, Mutex};

use ocp_shared_types::Envelope;
use wasmtime::{
    Caller, Config, Engine as WasmEngine, Extern, Linker, Module, Store, StoreLimits,
    StoreLimitsBuilder,
};
use wasmtime_wasi::p1::{self, WasiP1Ctx};
use wasmtime_wasi::WasiCtxBuilder;

use crate::{HostError, PluginHost, PluginState};

/// PLUGIN_ABI §1: negotiated at load, not per call.
pub const ABI_VERSION: i32 = 1;

/// PLUGIN_ABI §4 return codes.
pub mod code {
    pub const OK: i32 = 0;
    pub const CAPABILITY: i32 = -1;
    pub const QUOTA: i32 = -2;
    pub const ARGS: i32 = -3;
    pub const INTERNAL: i32 = -4;
}

/// Host-enforced execution ceilings (ABI §5).
#[derive(Debug, Clone)]
pub struct EngineConfig {
    pub fuel: u64,
    pub max_memory_bytes: usize,
}

impl Default for EngineConfig {
    fn default() -> Self {
        Self {
            fuel: 100_000_000,
            max_memory_bytes: 64 * 1024 * 1024,
        }
    }
}

#[derive(Debug)]
pub enum EngineError {
    NotActive,
    Compile(String),
    /// Required ABI export absent (module shape, ABI §1); plugin Rejected.
    MissingExport(String),
    /// `ocp_abi_version` outside the supported range; plugin Rejected.
    AbiMismatch(i32),
    Runtime(String),
}

impl core::fmt::Display for EngineError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::NotActive => write!(f, "plugin is not Active"),
            Self::Compile(e) => write!(f, "module failed to compile: {e}"),
            Self::MissingExport(n) => write!(f, "missing required ABI export: {n}"),
            Self::AbiMismatch(v) => write!(f, "unsupported ABI version: {v}"),
            Self::Runtime(e) => write!(f, "engine error: {e}"),
        }
    }
}

impl std::error::Error for EngineError {}

/// How a run ended. `Crashed` has already been reported to the host
/// (`ocp.plugin.crashed` → Suspended).
#[derive(Debug, PartialEq, Eq)]
pub enum RunOutcome {
    /// `ocp_start` returned this code.
    Completed(i32),
    Crashed,
}

struct GuestState {
    host: Arc<Mutex<PluginHost>>,
    plugin_id: String,
    limits: StoreLimits,
    /// WASI preview1 context. Alpha: no preopens, no env, no stdio inheritance;
    /// filesystem preopens per granted paths (PLUGIN_API §7, SEC-005) are wired
    /// in with the fs-grant slice.
    wasi: WasiP1Ctx,
}

fn map_host_err(e: &HostError) -> i32 {
    match e {
        HostError::Capability(_) => code::CAPABILITY,
        HostError::QuotaBreached => code::QUOTA,
        _ => code::INTERNAL,
    }
}

fn guest_memory(caller: &mut Caller<'_, GuestState>) -> Option<wasmtime::Memory> {
    match caller.get_export("memory") {
        Some(Extern::Memory(m)) => Some(m),
        _ => None,
    }
}

fn read_guest(caller: &mut Caller<'_, GuestState>, ptr: i32, len: i32) -> Result<Vec<u8>, i32> {
    let mem = guest_memory(caller).ok_or(code::INTERNAL)?;
    let start = usize::try_from(ptr).map_err(|_| code::ARGS)?;
    let n = usize::try_from(len).map_err(|_| code::ARGS)?;
    let end = start.checked_add(n).ok_or(code::ARGS)?;
    mem.data(&caller)
        .get(start..end)
        .map(<[u8]>::to_vec)
        .ok_or(code::ARGS)
}

fn read_guest_str(caller: &mut Caller<'_, GuestState>, ptr: i32, len: i32) -> Result<String, i32> {
    String::from_utf8(read_guest(caller, ptr, len)?).map_err(|_| code::ARGS)
}

fn write_guest(caller: &mut Caller<'_, GuestState>, ptr: i32, bytes: &[u8]) -> Result<(), i32> {
    let mem = guest_memory(caller).ok_or(code::INTERNAL)?;
    let start = usize::try_from(ptr).map_err(|_| code::ARGS)?;
    let end = start.checked_add(bytes.len()).ok_or(code::ARGS)?;
    mem.data_mut(caller)
        .get_mut(start..end)
        .ok_or(code::ARGS)?
        .copy_from_slice(bytes);
    Ok(())
}

fn host_and_id(caller: &Caller<'_, GuestState>) -> (Arc<Mutex<PluginHost>>, String) {
    (caller.data().host.clone(), caller.data().plugin_id.clone())
}

/// Buffer protocol shared by `event_next` / `memory_get` (ABI §3):
/// `0` = nothing, `n > 0` = bytes written, `-needed` = buffer too small
/// (payloads are always > 4 bytes, so `-needed` never collides with codes).
fn write_with_buffer_protocol(
    caller: &mut Caller<'_, GuestState>,
    buf_ptr: i32,
    buf_len: i32,
    bytes: &[u8],
) -> i32 {
    let needed = match i32::try_from(bytes.len()) {
        Ok(n) => n,
        Err(_) => return code::INTERNAL,
    };
    if needed > buf_len {
        return -needed;
    }
    match write_guest(caller, buf_ptr, bytes) {
        Ok(()) => needed,
        Err(c) => c,
    }
}

fn add_ocp_imports(linker: &mut Linker<GuestState>) -> Result<(), EngineError> {
    let rt = |e: wasmtime::Error| EngineError::Runtime(e.to_string());

    linker
        .func_wrap(
            "ocp",
            "log",
            |mut caller: Caller<'_, GuestState>, level: i32, ptr: i32, len: i32| -> i32 {
                let msg = match read_guest_str(&mut caller, ptr, len) {
                    Ok(s) => s,
                    Err(c) => return c,
                };
                let (host, id) = host_and_id(&caller);
                let mut h = host.lock().expect("host lock");
                let rc = match h.host_log(&id, level, &msg) {
                    Ok(()) => code::OK,
                    Err(e) => map_host_err(&e),
                };
                drop(h);
                rc
            },
        )
        .map_err(rt)?;

    linker
        .func_wrap(
            "ocp",
            "event_publish",
            |mut caller: Caller<'_, GuestState>,
             topic_ptr: i32,
             topic_len: i32,
             payload_ptr: i32,
             payload_len: i32|
             -> i32 {
                let topic = match read_guest_str(&mut caller, topic_ptr, topic_len) {
                    Ok(s) => s,
                    Err(c) => return c,
                };
                let payload = match read_guest(&mut caller, payload_ptr, payload_len) {
                    Ok(b) => b,
                    Err(c) => return c,
                };
                let data: serde_json::Value = match serde_json::from_slice(&payload) {
                    Ok(v) => v,
                    Err(_) => return code::ARGS,
                };
                let (host, id) = host_and_id(&caller);
                let mut h = host.lock().expect("host lock");
                let rc = match h.host_publish(&id, &topic, data, None) {
                    Ok(()) => code::OK,
                    Err(e) => map_host_err(&e),
                };
                drop(h);
                rc
            },
        )
        .map_err(rt)?;

    linker
        .func_wrap(
            "ocp",
            "event_next",
            |mut caller: Caller<'_, GuestState>, buf_ptr: i32, buf_len: i32| -> i32 {
                let (host, id) = host_and_id(&caller);
                let env: Option<Envelope> =
                    match host.lock().expect("host lock").host_event_next(&id) {
                        Ok(e) => e,
                        Err(e) => return map_host_err(&e),
                    };
                let Some(env) = env else { return 0 };
                let bytes = match serde_json::to_vec(&env) {
                    Ok(b) => b,
                    Err(_) => return code::INTERNAL,
                };
                let needed = match i32::try_from(bytes.len()) {
                    Ok(n) => n,
                    Err(_) => return code::INTERNAL,
                };
                if needed > buf_len {
                    // `host_event_next` pops destructively (mpsc `try_recv`)
                    // — without handing the envelope back, the guest's retry
                    // call (bigger buffer) would pop the *next* queue item
                    // instead of re-receiving this one, silently losing it
                    // (I4 slice 3 finding: the first plugin to actually
                    // subscribe to something and receive an envelope bigger
                    // than the SDK's default 256-byte buffer).
                    host.lock().expect("host lock").host_event_requeue(&id, env);
                    return -needed;
                }
                match write_guest(&mut caller, buf_ptr, &bytes) {
                    Ok(()) => needed,
                    Err(c) => c,
                }
            },
        )
        .map_err(rt)?;

    linker
        .func_wrap(
            "ocp",
            "memory_get",
            |mut caller: Caller<'_, GuestState>,
             key_ptr: i32,
             key_len: i32,
             buf_ptr: i32,
             buf_len: i32|
             -> i32 {
                let key = match read_guest_str(&mut caller, key_ptr, key_len) {
                    Ok(s) => s,
                    Err(c) => return c,
                };
                let (host, id) = host_and_id(&caller);
                let value = match host.lock().expect("host lock").host_memory_get(&id, &key) {
                    Ok(v) => v,
                    Err(e) => return map_host_err(&e),
                };
                let Some(value) = value else { return 0 };
                write_with_buffer_protocol(&mut caller, buf_ptr, buf_len, &value)
            },
        )
        .map_err(rt)?;

    linker
        .func_wrap(
            "ocp",
            "memory_set",
            |mut caller: Caller<'_, GuestState>,
             key_ptr: i32,
             key_len: i32,
             val_ptr: i32,
             val_len: i32|
             -> i32 {
                let key = match read_guest_str(&mut caller, key_ptr, key_len) {
                    Ok(s) => s,
                    Err(c) => return c,
                };
                let value = match read_guest(&mut caller, val_ptr, val_len) {
                    Ok(b) => b,
                    Err(c) => return c,
                };
                let (host, id) = host_and_id(&caller);
                let mut h = host.lock().expect("host lock");
                let rc = match h.host_memory_set(&id, &key, value) {
                    Ok(()) => code::OK,
                    Err(e) => map_host_err(&e),
                };
                drop(h);
                rc
            },
        )
        .map_err(rt)?;

    linker
        .func_wrap(
            "ocp",
            "memory_delete",
            |mut caller: Caller<'_, GuestState>, key_ptr: i32, key_len: i32| -> i32 {
                let key = match read_guest_str(&mut caller, key_ptr, key_len) {
                    Ok(s) => s,
                    Err(c) => return c,
                };
                let (host, id) = host_and_id(&caller);
                let mut h = host.lock().expect("host lock");
                let rc = match h.host_memory_delete(&id, &key) {
                    Ok(()) => code::OK,
                    Err(e) => map_host_err(&e),
                };
                drop(h);
                rc
            },
        )
        .map_err(rt)?;

    linker
        .func_wrap(
            "ocp",
            "net_connect",
            |mut caller: Caller<'_, GuestState>,
             host_ptr: i32,
             host_len: i32,
             port: i32,
             proto_ptr: i32,
             proto_len: i32|
             -> i32 {
                let target = match read_guest_str(&mut caller, host_ptr, host_len) {
                    Ok(s) => s,
                    Err(c) => return c,
                };
                let protocol = match read_guest_str(&mut caller, proto_ptr, proto_len) {
                    Ok(s) => s,
                    Err(c) => return c,
                };
                let Ok(port) = u16::try_from(port) else {
                    return code::ARGS;
                };
                let (host, id) = host_and_id(&caller);
                let req = crate::capability::CapabilityRequest::Net {
                    host: target,
                    port,
                    protocol,
                };
                let mut h = host.lock().expect("host lock");
                let rc = match h.check_capability(&id, &req) {
                    // Handle 0; real I/O verbs are ABI v2 (§3).
                    Ok(()) => 0,
                    Err(e) => map_host_err(&e),
                };
                drop(h);
                rc
            },
        )
        .map_err(rt)?;

    linker
        .func_wrap(
            "ocp",
            "telemetry_config",
            |mut caller: Caller<'_, GuestState>,
             kind_ptr: i32,
             kind_len: i32,
             _mode: i32,
             _value: i64|
             -> i32 {
                let kind_str = match read_guest_str(&mut caller, kind_ptr, kind_len) {
                    Ok(s) => s,
                    Err(c) => return c,
                };
                let kind = match kind_str.as_str() {
                    "cpu" => crate::manifest::TelemetryKind::Cpu,
                    "memory" => crate::manifest::TelemetryKind::Memory,
                    "battery" => crate::manifest::TelemetryKind::Battery,
                    "foreground" => crate::manifest::TelemetryKind::Foreground,
                    "mouse" => crate::manifest::TelemetryKind::Mouse,
                    _ => return code::ARGS,
                };
                let (host, id) = host_and_id(&caller);
                let mut h = host.lock().expect("host lock");
                let rc = match h.host_telemetry_config(&id, kind) {
                    Ok(()) => code::OK,
                    Err(e) => map_host_err(&e),
                };
                drop(h);
                rc
            },
        )
        .map_err(rt)?;

    Ok(())
}

const REQUIRED_EXPORTS: [&str; 5] = [
    "memory",
    "ocp_abi_version",
    "ocp_alloc",
    "ocp_free",
    "ocp_start",
];

/// Load, ABI-check, and run one Active plugin to `ocp_start` completion.
/// ABI failures reject the plugin (§1); traps report a crash (SEC-004).
pub fn load_and_start(
    host: Arc<Mutex<PluginHost>>,
    plugin_id: &str,
    wasm: &[u8],
    cfg: &EngineConfig,
) -> Result<RunOutcome, EngineError> {
    if host.lock().expect("host lock").state(plugin_id) != Some(PluginState::Active) {
        return Err(EngineError::NotActive);
    }

    let mut wt_config = Config::new();
    wt_config.consume_fuel(true);
    let engine = WasmEngine::new(&wt_config).map_err(|e| EngineError::Runtime(e.to_string()))?;

    let module = match Module::new(&engine, wasm) {
        Ok(m) => m,
        Err(e) => {
            let _ = host.lock().expect("host lock").reject(
                plugin_id,
                "abi: module failed to compile",
                None,
            );
            return Err(EngineError::Compile(e.to_string()));
        }
    };

    for name in REQUIRED_EXPORTS {
        if module.get_export(name).is_none() {
            let _ = host.lock().expect("host lock").reject(
                plugin_id,
                &format!("abi: missing export {name}"),
                None,
            );
            return Err(EngineError::MissingExport(name.to_owned()));
        }
    }

    let mut linker: Linker<GuestState> = Linker::new(&engine);
    // WASI preview1 (ABI §1 target wasm32-wasip1). No preopens/env/stdio in
    // the alpha; per-grant preopens land with the fs slice (SEC-005).
    p1::add_to_linker_sync(&mut linker, |s: &mut GuestState| &mut s.wasi)
        .map_err(|e| EngineError::Runtime(e.to_string()))?;
    add_ocp_imports(&mut linker)?;

    let state = GuestState {
        host: host.clone(),
        plugin_id: plugin_id.to_owned(),
        limits: StoreLimitsBuilder::new()
            .memory_size(cfg.max_memory_bytes)
            .build(),
        wasi: WasiCtxBuilder::new().build_p1(),
    };
    let mut store = Store::new(&engine, state);
    store.limiter(|s| &mut s.limits);
    // Instantiation (data/memory init) is fueled separately from the guest's
    // run quota — SEC-004 governs execution, not loading.
    const INSTANTIATION_FUEL: u64 = 1_000_000_000;
    store
        .set_fuel(INSTANTIATION_FUEL)
        .map_err(|e| EngineError::Runtime(e.to_string()))?;

    let instance = match linker.instantiate(&mut store, &module) {
        Ok(i) => i,
        Err(e) => {
            let _ = host.lock().expect("host lock").reject(
                plugin_id,
                "abi: instantiation failed (unknown import?)",
                None,
            );
            return Err(EngineError::Runtime(e.to_string()));
        }
    };

    let abi_fn = instance
        .get_typed_func::<(), i32>(&mut store, "ocp_abi_version")
        .map_err(|e| EngineError::Runtime(e.to_string()))?;
    match abi_fn.call(&mut store, ()) {
        Ok(v) if v == ABI_VERSION => {}
        Ok(v) => {
            let _ = host.lock().expect("host lock").reject(
                plugin_id,
                &format!("abi: unsupported version {v}"),
                None,
            );
            return Err(EngineError::AbiMismatch(v));
        }
        Err(_) => {
            let _ = host
                .lock()
                .expect("host lock")
                .report_crash(plugin_id, None);
            return Ok(RunOutcome::Crashed);
        }
    }

    let start = instance
        .get_typed_func::<(), i32>(&mut store, "ocp_start")
        .map_err(|e| EngineError::Runtime(e.to_string()))?;
    // The run quota starts here (SEC-004).
    store
        .set_fuel(cfg.fuel)
        .map_err(|e| EngineError::Runtime(e.to_string()))?;
    match start.call(&mut store, ()) {
        Ok(rc) => Ok(RunOutcome::Completed(rc)),
        Err(_trap) => {
            // Fuel/OOM/unreachable: contained; the plugin dies, the host does not.
            let _ = host
                .lock()
                .expect("host lock")
                .report_crash(plugin_id, None);
            Ok(RunOutcome::Crashed)
        }
    }
}
