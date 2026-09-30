//! GDExtension bridge — the Rust half of the Godot reference runtime
//! (RUNTIME.md "Implementation notes I2", RUNTIME_API, ADR-0003/0005).
//!
//! Everything security/contract-relevant lives here, not in GDScript:
//! - the IPC connection to the Native Core Service (`ocp_ipc::transport`,
//!   SEC-040 token handshake);
//! - the §5 rendering rule (`ocp_runtime_api::sanitize_display_text`) — text
//!   crosses into GDScript only after sanitization;
//! - translating envelopes to/from Godot signals/calls.
//!
//! GDScript (`godot/scripts/companion.gd`) owns presentation only: it reacts
//! to signals and draws things. It never sees a raw envelope.
//!
//! SKELETON STATUS: written against the gdext 0.5 API surface as documented
//! at the time of writing (see Cargo.toml comment). gdext's signal-emission
//! API in particular has shifted across releases — expect to reconcile
//! `emit_signal` call sites against `cargo doc -p godot --open` on first
//! build, the same way the wasmtime-wasi module path needed one fix-up in I1.
//!
//! Networking simplification (revisit once wired end-to-end): inbound and
//! outbound traffic use two independent authenticated connections rather
//! than multiplexing one duplex stream, to avoid needing a nonblocking-read
//! or stream-splitting API whose availability we haven't verified for the
//! `interprocess` version pinned in `packages/ipc`.

use std::thread;
use std::time::Duration;
use std::{
    fs,
    io::Read,
    path::Path,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{channel, Receiver, Sender},
        Arc,
    },
};

use base64::Engine as _;
use godot::classes::display_server::WindowFlags;
use godot::classes::{ColorRect, DisplayServer, INode};
use godot::prelude::*;

use ed25519_dalek::VerifyingKey;
use ocp_character_package::{parse_character_entry, validate as validate_character_entry};
use ocp_llm_router::{CredentialStore, OsKeystoreCredentialStore};
use ocp_package_loader::{load as load_package, PackageType, TrustStore};
use rusqlite::{params, Connection};
use sha2::{Digest, Sha256};
use sysinfo::{ProcessesToUpdate, System};

use ocp_ipc::transport::{connect_authenticated_with_intent, set_receive_timeout};
use ocp_ipc::{recv_envelope, send_envelope, IpcError, INTENT_PUBLISH, INTENT_SUBSCRIBE};
use ocp_runtime_api::{
    sanitize_display_text, AnimationRequested, BubbleRequested, CompanionFollowRequested,
    CompanionRef, CompanionSleepRequested, CompanionSpawnRequested, EmotionChanged,
    LookAtCursorRequested, Position, SpeechRequested, WindowPolicy,
};
use ocp_shared_types::Envelope;
use ocp_voice::{VadConfig, VadState, VadTransition, VoiceActivityDetector};

mod credential_broker;

#[cfg(target_os = "windows")]
mod windows_app_identity {
    #[link(name = "shell32")]
    unsafe extern "system" {
        fn SetCurrentProcessExplicitAppUserModelID(app_id: *const u16) -> i32;
    }

    const OCP_RUNTIME_APP_ID: &str = "OpenCompanion.OCP.Runtime";

    pub fn apply() {
        let mut wide: Vec<u16> = OCP_RUNTIME_APP_ID.encode_utf16().collect();
        wide.push(0);
        let result = unsafe { SetCurrentProcessExplicitAppUserModelID(wide.as_ptr()) };
        if result < 0 {
            eprintln!("[OCP Runtime] failed to set Windows AppUserModelID hr=0x{result:08x}");
        } else {
            eprintln!("[OCP Runtime] Windows AppUserModelID={OCP_RUNTIME_APP_ID}");
        }
    }
}

#[cfg(target_os = "windows")]
mod native_mouse_capture {
    use std::ffi::c_void;
    type Hwnd = *mut c_void;

    #[link(name = "user32")]
    unsafe extern "system" {
        fn SetCapture(hwnd: Hwnd) -> Hwnd;
        fn GetCapture() -> Hwnd;
        fn ReleaseCapture() -> i32;
    }

    pub fn begin(hwnd_value: i64) -> bool {
        if hwnd_value == 0 {
            return false;
        }
        let hwnd = hwnd_value as usize as Hwnd;
        unsafe {
            SetCapture(hwnd);
            GetCapture() == hwnd
        }
    }

    pub fn end() -> bool {
        unsafe { ReleaseCapture() != 0 }
    }
}

#[cfg(not(target_os = "windows"))]
mod native_mouse_capture {
    pub fn begin(_hwnd_value: i64) -> bool {
        false
    }
    pub fn end() -> bool {
        false
    }
}

#[derive(Debug, Clone, PartialEq)]
struct CompanionMovedPresentation {
    companion_id: String,
    x: f64,
    y: f64,
    velocity_x: f64,
    velocity_y: f64,
    grounded: bool,
    movement_state: String,
    motion: String,
    sequence: u64,
}

fn parse_companion_moved(data: &serde_json::Value) -> Option<CompanionMovedPresentation> {
    let position = data.get("position")?;
    if position.get("space")?.as_str()? != "desktop-logical"
        || position.get("anchor")?.as_str()? != "character-feet"
    {
        return None;
    }

    let motion = data.get("motion")?.as_str()?;
    if !matches!(motion, "continuous" | "authoritative-snap" | "teleport") {
        return None;
    }

    let movement_state = data.get("movementState")?.as_str()?;
    if !matches!(
        movement_state,
        "stationary"
            | "sitting"
            | "walking"
            | "climbing"
            | "climb-ready"
            | "hanging"
            | "airborne-rising"
            | "airborne-falling"
    ) {
        return None;
    }

    let velocity = data.get("velocity")?;
    let x = position.get("x")?.as_f64()?;
    let y = position.get("y")?.as_f64()?;
    let velocity_x = velocity.get("x")?.as_f64()?;
    let velocity_y = velocity.get("y")?.as_f64()?;

    if !x.is_finite() || !y.is_finite() || !velocity_x.is_finite() || !velocity_y.is_finite() {
        return None;
    }

    Some(CompanionMovedPresentation {
        companion_id: data.get("companionId")?.as_str()?.to_owned(),
        x,
        y,
        velocity_x,
        velocity_y,
        grounded: data.get("grounded")?.as_bool()?,
        movement_state: movement_state.to_owned(),
        motion: motion.to_owned(),
        sequence: data.get("sequence")?.as_u64()?,
    })
}

#[derive(Debug, Clone, PartialEq)]
struct CompanionPresentationState {
    companion_id: String,
    body_id: u64,
    x: f64,
    y: f64,
    velocity_x: f64,
    velocity_y: f64,
    grounded: bool,
    movement_state: String,
    attachment_state: String,
    surface_kind: Option<String>,
    facing: String,
    update_kind: String,
    sequence: u64,
    revision: u64,
}

fn parse_companion_presentation_state(
    data: &serde_json::Value,
) -> Option<CompanionPresentationState> {
    if data.get("schemaVersion")?.as_u64()? != 1 {
        return None;
    }
    let feet = data.get("desktopFeet")?;
    if feet.get("space")?.as_str()? != "desktop-logical"
        || feet.get("anchor")?.as_str()? != "character-feet"
    {
        return None;
    }
    let velocity = data.get("velocity")?;
    let x = feet.get("x")?.as_f64()?;
    let y = feet.get("y")?.as_f64()?;
    let velocity_x = velocity.get("x")?.as_f64()?;
    let velocity_y = velocity.get("y")?.as_f64()?;
    if !x.is_finite() || !y.is_finite() || !velocity_x.is_finite() || !velocity_y.is_finite() {
        return None;
    }

    let movement_state = data.get("movementState")?.as_str()?;
    if !matches!(
        movement_state,
        "stationary"
            | "sitting"
            | "walking"
            | "climbing"
            | "climb-ready"
            | "hanging"
            | "airborne-rising"
            | "airborne-falling"
    ) {
        return None;
    }
    let attachment_state = data.get("attachmentState")?.as_str()?;
    if !matches!(
        attachment_state,
        "grounded" | "airborne" | "attached" | "hanging"
    ) {
        return None;
    }
    let surface_kind = data
        .get("surfaceKind")
        .and_then(serde_json::Value::as_str)
        .filter(|kind| {
            matches!(
                *kind,
                "desktop_floor"
                    | "taskbar_top"
                    | "dock_top"
                    | "window_top"
                    | "monitor_edge"
                    | "window_left"
                    | "window_right"
                    | "window_bottom"
                    | "widget_edge"
                    | "floating_panel_edge"
                    | "custom"
            )
        })
        .map(str::to_owned);
    let facing = data.get("facing")?.as_str()?;
    if !matches!(facing, "left" | "right" | "unchanged") {
        return None;
    }
    let update_kind = data.get("updateKind")?.as_str()?;
    if !matches!(
        update_kind,
        "continuous" | "spawn" | "drag-commit" | "correction" | "teleport"
    ) {
        return None;
    }

    Some(CompanionPresentationState {
        companion_id: data.get("companionId")?.as_str()?.to_owned(),
        body_id: data.get("bodyId")?.as_u64()?,
        x,
        y,
        velocity_x,
        velocity_y,
        grounded: data.get("grounded")?.as_bool()?,
        movement_state: movement_state.to_owned(),
        attachment_state: attachment_state.to_owned(),
        surface_kind,
        facing: facing.to_owned(),
        update_kind: update_kind.to_owned(),
        sequence: data.get("sequence")?.as_u64()?,
        revision: data.get("revision")?.as_u64()?,
    })
}

fn companion_position_request_envelope(companion_id: &str, x: f64, y: f64) -> Option<Envelope> {
    if companion_id.trim().is_empty() || !x.is_finite() || !y.is_finite() {
        return None;
    }
    Envelope::new(
        "ocp.runtime.companion-position-requested",
        "runtime",
        serde_json::json!({
            "companionId": companion_id,
            "position": {
                "space": "desktop-logical",
                "anchor": "character-feet",
                "x": x,
                "y": y,
            },
            "mode": "authoritative-snap",
        }),
    )
    .ok()
}

fn companion_movement_request_envelope(companion_id: &str, action: &str) -> Option<Envelope> {
    if companion_id.trim().is_empty()
        || !matches!(
            action,
            "walk-left"
                | "walk-right"
                | "climb-up"
                | "climb-down"
                | "hang-left"
                | "hang-right"
                | "hang-to-center"
                | "hang-to-far-edge"
                | "hang-to-climb-down-edge"
                | "detach"
                | "teleport-current-monitor"
                | "stop"
        )
    {
        return None;
    }
    Envelope::new(
        "ocp.runtime.companion-movement-requested",
        "runtime",
        serde_json::json!({
            "schemaVersion": 1,
            "companionId": companion_id,
            "action": action,
            "edgeBehavior": "stop-at-edge",
            "source": "offline-presence",
        }),
    )
    .ok()
}

/// POC-only publisher public key. This is the public half of the demo key
/// used by `pack_character`; Runtime never contains a signing/private key.
const POC_BIBLE_KEY_ID: &str = "ed25519:demo-1";
const POC_BIBLE_PUBLIC_KEY: [u8; 32] = [
    234, 74, 108, 99, 226, 156, 82, 10, 190, 245, 80, 123, 19, 46, 197, 249, 149, 71, 118, 174,
    190, 190, 123, 146, 66, 30, 234, 105, 20, 70, 210, 44,
];

fn poc_character_trust_store() -> Result<TrustStore, String> {
    let key = VerifyingKey::from_bytes(&POC_BIBLE_PUBLIC_KEY)
        .map_err(|_| "Runtime POC trust store is invalid".to_owned())?;
    let mut trust = TrustStore::new();
    trust.add_key(POC_BIBLE_KEY_ID, key);
    Ok(trust)
}

fn install_verified_character_archive(
    source: &Path,
    packages_root: &Path,
) -> Result<(String, String), String> {
    install_verified_character_archive_with_expectations(
        source,
        packages_root,
        poc_character_trust_store()?,
        None,
        None,
        None,
    )
}

fn install_verified_character_archive_with_expectations(
    source: &Path,
    packages_root: &Path,
    trust: TrustStore,
    expected_sha256: Option<&str>,
    expected_signature_key_id: Option<&str>,
    expected_signature: Option<&str>,
) -> Result<(String, String), String> {
    let bytes = fs::read(source).map_err(|_| "Cannot read package file".to_owned())?;

    if let Some(expected) = expected_sha256 {
        let expected = expected.trim().to_ascii_lowercase();
        if expected.len() != 64 || !expected.chars().all(|ch| ch.is_ascii_hexdigit()) {
            return Err("Cloud package SHA-256 is invalid".to_owned());
        }
        let actual = format!("{:x}", Sha256::digest(&bytes));
        if actual != expected {
            return Err("Cloud package SHA-256 mismatch".to_owned());
        }
    }

    let package = load_package(&bytes, &trust)
        .map_err(|_| "Package signature, manifest, or asset digest was rejected".to_owned())?;

    if let Some(expected_key_id) = expected_signature_key_id {
        if expected_key_id.trim() != package.manifest.signature.key_id {
            return Err("Cloud signature key does not match the verified package".to_owned());
        }
    }
    if let Some(expected_value) = expected_signature {
        if expected_value.trim() != package.manifest.signature.value {
            return Err("Cloud signature metadata does not match the verified package".to_owned());
        }
    }
    if !matches!(package.manifest.package_type, PackageType::Character) {
        return Err("Only character packages can be installed here".to_owned());
    }

    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(&package.archive_bytes))
        .map_err(|_| "Verified package could not be read".to_owned())?;
    let mut entry_bytes = Vec::new();
    archive
        .by_name(&package.manifest.entry)
        .map_err(|_| "Verified package entry is missing".to_owned())?
        .read_to_end(&mut entry_bytes)
        .map_err(|_| "Verified package entry could not be read".to_owned())?;
    let entry = parse_character_entry(&entry_bytes)
        .map_err(|_| "Character entry was rejected".to_owned())?;
    let declared: Vec<&str> = package
        .manifest
        .assets
        .iter()
        .map(|asset| asset.path.as_str())
        .collect();
    validate_character_entry(&entry, &declared)
        .map_err(|_| "Character assets were rejected".to_owned())?;
    let target = packages_root
        .join(&package.manifest.id)
        .join(&package.manifest.version);
    if target.exists() {
        return Err("This character version is already installed".to_owned());
    }
    let staging = packages_root.join(format!(
        ".staging-{}-{}",
        package.manifest.id, package.manifest.version
    ));
    if staging.exists() {
        return Err("A previous installation needs recovery".to_owned());
    }
    fs::create_dir_all(&staging).map_err(|_| "Cannot create install directory".to_owned())?;
    let mut files = vec![(
        "manifest.json".to_owned(),
        serde_json::to_vec(&package.manifest)
            .map_err(|_| "Verified manifest could not be serialized".to_owned())?,
    )];
    for asset in &package.manifest.assets {
        let mut data = Vec::new();
        archive
            .by_name(&asset.path)
            .map_err(|_| "Verified asset is missing".to_owned())?
            .read_to_end(&mut data)
            .map_err(|_| "Verified asset could not be read".to_owned())?;
        files.push((asset.path.clone(), data));
    }
    for (relative, data) in files {
        let output = staging.join(relative);
        let parent = output
            .parent()
            .ok_or_else(|| "Invalid package destination".to_owned())?;
        fs::create_dir_all(parent).map_err(|_| "Cannot create asset directory".to_owned())?;
        fs::write(output, data).map_err(|_| "Cannot write verified asset".to_owned())?;
    }
    fs::create_dir_all(
        target
            .parent()
            .ok_or_else(|| "Invalid character destination".to_owned())?,
    )
    .map_err(|_| "Cannot create character directory".to_owned())?;
    fs::rename(staging, target).map_err(|_| "Cannot finalize character installation".to_owned())?;
    Ok((package.manifest.id, package.manifest.version))
}

mod cloud_package;

struct OcpExtension;

#[gdextension]
unsafe impl ExtensionLibrary for OcpExtension {
    fn on_stage_init(stage: InitStage) {
        #[cfg(target_os = "windows")]
        if stage == InitStage::Scene {
            windows_app_identity::apply();
        }
    }
}

/// One item handed from a background thread to the main-thread `process()`.
enum Inbound {
    Envelope(Envelope),
    Disconnected,
    Reconnected,
}

/// Reconnect backoff (RUNTIME_API §4.4: retry with backoff, re-auth on
/// reconnect, no decisions queued while disconnected).
const RECONNECT_BACKOFF: Duration = Duration::from_secs(2);

#[derive(GodotClass)]
#[class(base=Node)]
pub struct OcpRuntimeBridge {
    base: Base<Node>,
    inbox: Option<Receiver<Inbound>>,
    outbox: Option<Sender<Envelope>>,
    connected: bool,
    /// I7 V1 slice 4b: `speech-completed` is no longer faked at dispatch time —
    /// it fires when GDScript reports playback done. This maps each in-flight
    /// `speechId` to its causing `speech-requested` envelope id so the deferred
    /// outcome stays correlated (NFR-004). Cleared on completion.
    pending_speech: std::collections::HashMap<uuid::Uuid, uuid::Uuid>,
    /// I8A slice 1: `animation-completed` is likewise no longer faked at
    /// dispatch — it fires when GDScript reports the animation actually ended.
    /// `animation-requested` carries no per-request id (unlike `speechId`), so
    /// the bridge mints an **animation instance token** per request, passes it
    /// to the signal, and maps it here to the causing envelope id for the
    /// deferred, correlated `animation-completed`. Cleared on completion.
    pending_animation: std::collections::HashMap<uuid::Uuid, uuid::Uuid>,
    /// I8A slice 2b: `emotion-presented`'s `expressionSet`/`fallback` are no
    /// longer hardcoded at dispatch — only GDScript (the Expression module,
    /// RFC-0008 §4.1) knows which expression it actually rendered. Same
    /// instance-token bridge as animations: mint per emotion-changed, map to
    /// the cause envelope, emit the honest outcome on GDScript's report.
    pending_emotion: std::collections::HashMap<uuid::Uuid, uuid::Uuid>,
    /// G8 opt-in render-host lifecycle. This bridge only reports lifecycle;
    /// native HWND ownership remains outside Godot until production G8 passes.
    render_host_attached: bool,
    worker_stop: Arc<AtomicBool>,
    worker_threads: Vec<thread::JoinHandle<()>>,
    resource_system: System,
    credential_broker: Option<credential_broker::CredentialBroker>,
    voice_vad: VoiceActivityDetector,
}

/// The local WAV path for an `audioRef` id (I7 V1 slice 4b, file-backed audio
/// store). `OCP_AUDIO_DIR` overrides the default temp location; the kernel's
/// audio store and this runtime must agree on it (they are co-located).
fn audio_clip_path(id: uuid::Uuid) -> std::path::PathBuf {
    let dir = std::env::var_os("OCP_AUDIO_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("ocp-audio"));
    dir.join(format!("{id}.wav"))
}

fn progression_event_id(event_json: &str) -> Result<String, String> {
    let value: serde_json::Value = serde_json::from_str(event_json)
        .map_err(|_| "Progression event is not valid JSON".to_owned())?;
    let event_id = value
        .get("id")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| "Progression event id is required".to_owned())?;
    uuid::Uuid::parse_str(event_id).map_err(|_| "Progression event id is not a UUID".to_owned())?;
    Ok(event_id.to_owned())
}

fn open_progression_queue(database_path: &Path) -> Result<Connection, String> {
    if database_path.as_os_str().is_empty() {
        return Err("Progression queue database path is required".to_owned());
    }
    if let Some(parent) = database_path.parent() {
        fs::create_dir_all(parent)
            .map_err(|_| "Cannot create progression queue directory".to_owned())?;
    }
    let connection = Connection::open(database_path)
        .map_err(|_| "Cannot open progression queue database".to_owned())?;
    connection
        .busy_timeout(Duration::from_secs(2))
        .map_err(|_| "Cannot configure progression queue database".to_owned())?;
    connection
        .execute_batch(
            "PRAGMA journal_mode=WAL;\n\
             CREATE TABLE IF NOT EXISTS progression_pending_events (\n\
               event_id TEXT PRIMARY KEY NOT NULL,\n\
               event_json TEXT NOT NULL,\n\
               created_at_ms INTEGER NOT NULL\n\
             );\n\
             CREATE INDEX IF NOT EXISTS idx_progression_pending_created\n\
               ON progression_pending_events(created_at_ms, event_id);\n\
             CREATE TABLE IF NOT EXISTS progression_projection_cache (\n\
               user_id TEXT PRIMARY KEY NOT NULL,\n\
               projection_json TEXT NOT NULL,\n\
               updated_at_ms INTEGER NOT NULL\n\
             );",
        )
        .map_err(|_| "Cannot initialize progression queue database".to_owned())?;
    Ok(connection)
}

fn progression_queue_enqueue_db(database_path: &Path, event_json: &str) -> Result<bool, String> {
    let event_id = progression_event_id(event_json)?;
    let connection = open_progression_queue(database_path)?;
    let inserted = connection
        .execute(
            "INSERT OR IGNORE INTO progression_pending_events(event_id, event_json, created_at_ms) VALUES (?1, ?2, ?3)",
            params![event_id, event_json, chrono::Utc::now().timestamp_millis()],
        )
        .map_err(|_| "Cannot enqueue progression event".to_owned())?;
    Ok(inserted == 1)
}

fn progression_queue_list_db(database_path: &Path, limit: usize) -> Result<Vec<String>, String> {
    let connection = open_progression_queue(database_path)?;
    let safe_limit = limit.clamp(1, 100);
    let mut statement = connection
        .prepare(
            "SELECT event_json FROM progression_pending_events ORDER BY created_at_ms ASC, event_id ASC LIMIT ?1",
        )
        .map_err(|_| "Cannot read progression queue".to_owned())?;
    let rows = statement
        .query_map(params![safe_limit as i64], |row| row.get::<_, String>(0))
        .map_err(|_| "Cannot read progression queue".to_owned())?;
    let mut events = Vec::new();
    for row in rows {
        events.push(row.map_err(|_| "Cannot decode progression queue row".to_owned())?);
    }
    Ok(events)
}

fn progression_queue_ack_db(database_path: &Path, event_ids_json: &str) -> Result<usize, String> {
    let raw_ids: Vec<String> = serde_json::from_str(event_ids_json)
        .map_err(|_| "Progression acknowledgement ids are not valid JSON".to_owned())?;
    if raw_ids.is_empty() || raw_ids.len() > 100 {
        return Err("Progression acknowledgement batch must contain 1 to 100 ids".to_owned());
    }
    for event_id in &raw_ids {
        uuid::Uuid::parse_str(event_id)
            .map_err(|_| "Progression acknowledgement contains an invalid UUID".to_owned())?;
    }
    let mut connection = open_progression_queue(database_path)?;
    let transaction = connection
        .transaction()
        .map_err(|_| "Cannot start progression acknowledgement".to_owned())?;
    let mut removed = 0usize;
    for event_id in raw_ids {
        removed += transaction
            .execute(
                "DELETE FROM progression_pending_events WHERE event_id = ?1",
                params![event_id],
            )
            .map_err(|_| "Cannot acknowledge progression event".to_owned())?;
    }
    transaction
        .commit()
        .map_err(|_| "Cannot commit progression acknowledgement".to_owned())?;
    Ok(removed)
}

fn progression_projection_store_db(
    database_path: &Path,
    user_id: &str,
    projection_json: &str,
) -> Result<(), String> {
    uuid::Uuid::parse_str(user_id)
        .map_err(|_| "Progression projection user id is not a UUID".to_owned())?;
    let value: serde_json::Value = serde_json::from_str(projection_json)
        .map_err(|_| "Progression projection is not valid JSON".to_owned())?;
    let revision = value
        .get("revision")
        .and_then(serde_json::Value::as_i64)
        .ok_or_else(|| "Progression projection revision is required".to_owned())?;
    if revision < 0
        || !value
            .get("companions")
            .is_some_and(serde_json::Value::is_array)
    {
        return Err("Progression projection shape is invalid".to_owned());
    }

    let connection = open_progression_queue(database_path)?;
    connection
        .execute(
            "INSERT INTO progression_projection_cache(user_id, projection_json, updated_at_ms) \
             VALUES (?1, ?2, ?3) \
             ON CONFLICT(user_id) DO UPDATE SET \
               projection_json = excluded.projection_json, \
               updated_at_ms = excluded.updated_at_ms",
            params![
                user_id,
                projection_json,
                chrono::Utc::now().timestamp_millis()
            ],
        )
        .map_err(|_| "Cannot cache progression projection".to_owned())?;
    Ok(())
}

fn progression_projection_load_db(
    database_path: &Path,
    user_id: &str,
) -> Result<Option<String>, String> {
    uuid::Uuid::parse_str(user_id)
        .map_err(|_| "Progression projection user id is not a UUID".to_owned())?;
    let connection = open_progression_queue(database_path)?;
    let mut statement = connection
        .prepare("SELECT projection_json FROM progression_projection_cache WHERE user_id = ?1")
        .map_err(|_| "Cannot read progression projection cache".to_owned())?;
    let mut rows = statement
        .query(params![user_id])
        .map_err(|_| "Cannot read progression projection cache".to_owned())?;
    let Some(row) = rows
        .next()
        .map_err(|_| "Cannot read progression projection cache".to_owned())?
    else {
        return Ok(None);
    };
    let projection_json: String = row
        .get(0)
        .map_err(|_| "Cannot decode progression projection cache".to_owned())?;
    Ok(Some(projection_json))
}

impl OcpRuntimeBridge {
    fn shutdown_ipc_workers(&mut self) {
        self.worker_stop.store(true, Ordering::Release);
        // Closing the final Sender wakes the writer's blocking recv().
        self.outbox.take();
        // Dropping the main-thread receiver makes the reader return as soon as
        // its bounded socket read wakes.
        self.inbox.take();
        for worker in self.worker_threads.drain(..) {
            let _ = worker.join();
        }
    }
}

#[godot_api]
impl INode for OcpRuntimeBridge {
    fn init(base: Base<Node>) -> Self {
        Self {
            base,
            inbox: None,
            outbox: None,
            connected: false,
            pending_speech: std::collections::HashMap::new(),
            pending_animation: std::collections::HashMap::new(),
            pending_emotion: std::collections::HashMap::new(),
            render_host_attached: false,
            worker_stop: Arc::new(AtomicBool::new(false)),
            worker_threads: Vec::new(),
            resource_system: System::new(),
            credential_broker: None,
            voice_vad: VoiceActivityDetector::new(VadConfig::default()),
        }
    }

    fn ready(&mut self) {
        // Provisioning is out-of-band per packages/ipc::transport docs; the
        // skeleton reads env vars set by whatever launches the editor/build.
        // TODO(I2 follow-up): real secure token delivery from the kernel
        // launcher (DEPLOYMENT.md), not a bare env var.
        let socket_name =
            std::env::var("OCP_IPC_SOCKET").unwrap_or_else(|_| "ocp-runtime".to_owned());
        let token = std::env::var("OCP_IPC_TOKEN").unwrap_or_default();
        if token.is_empty() {
            godot_warn!(
                "OcpRuntimeBridge: OCP_IPC_TOKEN is not set — the kernel will reject the handshake (SEC-040)"
            );
        }

        let (in_tx, in_rx) = channel::<Inbound>();
        let (out_tx, out_rx) = channel::<Envelope>();
        self.inbox = Some(in_rx);
        self.outbox = Some(out_tx);

        self.worker_stop.store(false, Ordering::Release);
        let read_socket = socket_name.clone();
        let read_token = token.clone();
        let read_stop = Arc::clone(&self.worker_stop);
        self.worker_threads.push(thread::spawn(move || {
            read_loop(read_socket, read_token, in_tx, read_stop)
        }));
        self.worker_threads.push(thread::spawn(move || {
            write_loop(socket_name, token, out_rx)
        }));
    }

    fn process(&mut self, _delta: f64) {
        let mut items = Vec::new();
        if let Some(rx) = &self.inbox {
            while let Ok(item) = rx.try_recv() {
                items.push(item);
            }
        }
        for item in items {
            match item {
                Inbound::Envelope(env) => self.dispatch(&env),
                Inbound::Disconnected => {
                    self.connected = false;
                    self.base_mut().emit_signal("connection_lost", &[]);
                }
                Inbound::Reconnected => {
                    self.connected = true;
                    self.base_mut().emit_signal("connection_restored", &[]);
                }
            }
        }
    }

    fn exit_tree(&mut self) {
        self.shutdown_ipc_workers();
    }
}

#[godot_api]
impl OcpRuntimeBridge {
    /// Lazily start the ADR-0042 Windows-only credential broker. The returned
    /// launch arguments are passed directly to Electron main by trusted Runtime
    /// code; renderer code never receives the pipe name or capability.
    #[func]
    fn start_credential_broker(&mut self, capability: GString) -> PackedStringArray {
        if self.credential_broker.is_none() {
            let capability = capability.to_string();
            let mut hasher = Sha256::new();
            hasher.update(capability.as_bytes());
            hasher.update(std::process::id().to_le_bytes());
            hasher.update(
                chrono::Utc::now()
                    .timestamp_nanos_opt()
                    .unwrap_or_default()
                    .to_le_bytes(),
            );
            let digest = hasher.finalize();
            let suffix = digest[..16]
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<String>();
            self.credential_broker = credential_broker::CredentialBroker::start(
                format!("ocp-credential-{suffix}"),
                capability,
            );
        }
        let mut result = PackedStringArray::new();
        if let Some(broker) = &self.credential_broker {
            for argument in broker.launch_arguments() {
                let argument = GString::from(argument.as_str());
                result.push(&argument);
            }
        }
        result
    }

    /// Return a read-only resource snapshot for the Runtime widget.
    ///
    /// System pressure and OCP-owned memory are intentionally separate. The
    /// previous contract exposed whole-machine RAM as "memory_percent", which
    /// made the UI look as if OCP itself consumed that percentage. Keep the
    /// system percentages for pressure policy, but also report a bounded
    /// process-family breakdown so Settings can show the actual OCP footprint.
    #[func]
    fn resource_usage(&mut self) -> Dictionary<Variant, Variant> {
        self.resource_system.refresh_cpu_usage();
        self.resource_system.refresh_memory();
        self.resource_system
            .refresh_processes(ProcessesToUpdate::All, true);

        let total_memory = self.resource_system.total_memory();
        let used_memory = self.resource_system.used_memory();
        let system_memory_percent = if total_memory == 0 {
            0.0
        } else {
            (used_memory as f64 / total_memory as f64) * 100.0
        };

        let current_pid = std::process::id();
        let mut runtime_memory_bytes = 0_u64;
        let mut desktop_shell_memory_bytes = 0_u64;
        let mut kernel_memory_bytes = 0_u64;
        let mut native_host_memory_bytes = 0_u64;
        let mut ai_memory_bytes = 0_u64;

        for (pid, process) in self.resource_system.processes() {
            let memory_bytes = process.memory();
            let name = process.name().to_string_lossy().to_ascii_lowercase();
            let command = process
                .cmd()
                .iter()
                .map(|part| part.to_string_lossy())
                .collect::<Vec<_>>()
                .join(" ")
                .to_ascii_lowercase();

            if pid.as_u32() == current_pid {
                runtime_memory_bytes = runtime_memory_bytes.saturating_add(memory_bytes);
                continue;
            }
            if name == "ocp.exe"
                || name == "ocp-desktop-dev.exe"
                || (name == "electron.exe"
                    && (command.contains("apps\\desktop-shell")
                        || command.contains("apps/desktop-shell")
                        || command.contains("dist-electron")))
            {
                desktop_shell_memory_bytes =
                    desktop_shell_memory_bytes.saturating_add(memory_bytes);
                continue;
            }
            if name == "ocp-kernel.exe" {
                kernel_memory_bytes = kernel_memory_bytes.saturating_add(memory_bytes);
                continue;
            }
            if name == "ocp-native-companion-window.exe"
                || name == "ocp-native-companion-window-spike.exe"
            {
                native_host_memory_bytes = native_host_memory_bytes.saturating_add(memory_bytes);
                continue;
            }
            if name.starts_with("ollama") {
                ai_memory_bytes = ai_memory_bytes.saturating_add(memory_bytes);
            }
        }

        let ocp_memory_bytes = runtime_memory_bytes
            .saturating_add(desktop_shell_memory_bytes)
            .saturating_add(kernel_memory_bytes)
            .saturating_add(native_host_memory_bytes);

        let mut usage: Dictionary<Variant, Variant> = Dictionary::new();
        usage.set("available", true);
        usage.set(
            "system_cpu_percent",
            f64::from(self.resource_system.global_cpu_usage()),
        );
        usage.set("system_memory_percent", system_memory_percent);
        usage.set("ocp_memory_bytes", ocp_memory_bytes as i64);
        usage.set("runtime_memory_bytes", runtime_memory_bytes as i64);
        usage.set(
            "desktop_shell_memory_bytes",
            desktop_shell_memory_bytes as i64,
        );
        usage.set("kernel_memory_bytes", kernel_memory_bytes as i64);
        usage.set("native_host_memory_bytes", native_host_memory_bytes as i64);
        usage.set("ai_memory_bytes", ai_memory_bytes as i64);
        usage.set("sampled_at_ms", chrono::Utc::now().timestamp_millis());
        usage
    }

    /// Store one AI-provider credential in the OS keystore. The secret is never
    /// written to Godot settings, IPC envelopes, logs, or return values.
    #[func]
    fn store_provider_credential(
        &mut self,
        provider_id: GString,
        credential: GString,
    ) -> Dictionary<Variant, Variant> {
        let provider_id = provider_id.to_string().trim().to_owned();
        let credential = credential.to_string();
        let mut result: Dictionary<Variant, Variant> = Dictionary::new();
        if provider_id.is_empty() || credential.trim().is_empty() {
            result.set("ok", false);
            result.set("error", "Provider id and credential are required");
            return result;
        }

        let store = OsKeystoreCredentialStore::new("ocp-ai-provider");
        match store.set(&provider_id, &credential) {
            Ok(()) => {
                result.set("ok", true);
                result.set("provider_id", provider_id);
                result.set("present", true);
            }
            Err(_) => {
                result.set("ok", false);
                result.set("error", "OS credential store unavailable");
            }
        }
        result
    }

    /// Query credential presence without exposing the secret back to GDScript.
    #[func]
    fn provider_credential_present(&mut self, provider_id: GString) -> bool {
        let provider_id = provider_id.to_string().trim().to_owned();
        if provider_id.is_empty() {
            return false;
        }
        OsKeystoreCredentialStore::new("ocp-ai-provider")
            .get(&provider_id)
            .is_some()
    }

    /// Remove a provider credential from the same OS-keystore namespace used
    /// by the kernel AI Router.
    #[func]
    fn delete_provider_credential(&mut self, provider_id: GString) -> Dictionary<Variant, Variant> {
        let provider_id = provider_id.to_string().trim().to_owned();
        let mut result: Dictionary<Variant, Variant> = Dictionary::new();
        if provider_id.is_empty() {
            result.set("ok", false);
            result.set("error", "Provider id is required");
            return result;
        }

        let store = OsKeystoreCredentialStore::new("ocp-ai-provider");
        match store.delete(&provider_id) {
            Ok(()) => {
                result.set("ok", true);
                result.set("provider_id", provider_id);
                result.set("present", false);
            }
            Err(_) => {
                result.set("ok", false);
                result.set("error", "OS credential store unavailable");
            }
        }
        result
    }

    /// Persist the hosted-cloud refresh token in an OS-keystore namespace that
    /// is separate from AI provider credentials. The token is never written to
    /// Godot settings, SQLite, IPC, or logs.
    #[func]
    fn store_cloud_refresh_token(
        &mut self,
        refresh_token: GString,
    ) -> Dictionary<Variant, Variant> {
        let token = refresh_token.to_string();
        let mut result: Dictionary<Variant, Variant> = Dictionary::new();
        if token.trim().is_empty() {
            result.set("ok", false);
            result.set("error", "Refresh token is required");
            return result;
        }
        let store = OsKeystoreCredentialStore::new("ocp-cloud-session");
        match store.set("refresh-token", &token) {
            Ok(()) => {
                result.set("ok", true);
                result.set("present", true);
            }
            Err(_) => {
                result.set("ok", false);
                result.set("error", "OS credential store unavailable");
            }
        }
        result
    }

    /// Read the refresh token only for immediate Cloud Auth rotation. Callers
    /// must not persist, log, or publish the returned value.
    #[func]
    fn load_cloud_refresh_token(&mut self) -> Dictionary<Variant, Variant> {
        let mut result: Dictionary<Variant, Variant> = Dictionary::new();
        let store = OsKeystoreCredentialStore::new("ocp-cloud-session");
        match store.get("refresh-token") {
            Some(token) if !token.trim().is_empty() => {
                result.set("ok", true);
                result.set("refresh_token", token);
            }
            _ => {
                result.set("ok", false);
                result.set("error", "Cloud refresh token unavailable");
            }
        }
        result
    }

    #[func]
    fn delete_cloud_refresh_token(&mut self) -> Dictionary<Variant, Variant> {
        let mut result: Dictionary<Variant, Variant> = Dictionary::new();
        let store = OsKeystoreCredentialStore::new("ocp-cloud-session");
        match store.delete("refresh-token") {
            Ok(()) => {
                result.set("ok", true);
                result.set("present", false);
            }
            Err(_) => {
                result.set("ok", false);
                result.set("error", "OS credential store unavailable");
            }
        }
        result
    }

    #[func]
    fn new_uuid_v7(&self) -> GString {
        let value = uuid::Uuid::now_v7().to_string();
        GString::from(value.as_str())
    }

    #[func]
    fn begin_native_mouse_capture(&mut self, native_window_handle: i64) -> bool {
        native_mouse_capture::begin(native_window_handle)
    }

    #[func]
    fn end_native_mouse_capture(&mut self) -> bool {
        native_mouse_capture::end()
    }

    /// G8 opt-in lifecycle bridge. The token is opaque to Godot and must be
    /// non-empty; this does not move or resize any native window.
    #[func]
    fn attach_render_surface(&mut self, companion_id: GString, host_token: GString) -> bool {
        if companion_id.to_string().trim().is_empty() || host_token.to_string().trim().is_empty() {
            return false;
        }
        self.render_host_attached = true;
        self.base_mut().emit_signal(
            "render_host_ready",
            &[companion_id.to_variant(), host_token.to_variant()],
        );
        true
    }

    #[func]
    fn set_render_client_size(&mut self, width: i64, height: i64) -> bool {
        if !self.render_host_attached || width <= 0 || height <= 0 {
            return false;
        }
        self.base_mut().emit_signal(
            "render_host_resized",
            &[width.to_variant(), height.to_variant()],
        );
        true
    }

    #[func]
    fn detach_render_surface(&mut self, companion_id: GString) -> bool {
        if !self.render_host_attached || companion_id.to_string().trim().is_empty() {
            return false;
        }
        self.render_host_attached = false;
        self.base_mut()
            .emit_signal("render_host_detached", &[companion_id.to_variant()]);
        true
    }

    /// Publish an authoritative desktop-feet drag commit to Kernel.
    /// Returning true means the validated envelope was queued to the IPC
    /// writer; Kernel remains the authority that resolves the final surface.
    #[func]
    fn commit_companion_position(&mut self, companion_id: GString, x: f64, y: f64) -> bool {
        let companion_id = companion_id.to_string();
        if companion_id.trim().is_empty() || !x.is_finite() || !y.is_finite() {
            return false;
        }

        let Some(env) = companion_position_request_envelope(&companion_id, x, y) else {
            return false;
        };

        self.outbox
            .as_ref()
            .is_some_and(|sender| sender.send(env).is_ok())
    }

    /// Request a bounded, allowlisted autonomous movement. Kernel validates
    /// the request and remains the sole Physics/coordinate authority.
    #[func]
    fn request_companion_movement(&mut self, companion_id: GString, action: GString) -> bool {
        let Some(env) =
            companion_movement_request_envelope(&companion_id.to_string(), &action.to_string())
        else {
            return false;
        };
        self.outbox
            .as_ref()
            .is_some_and(|sender| sender.send(env).is_ok())
    }

    /// Request one serialized chat TTS chunk from the kernel voice router.
    /// Secrets and provider transport stay kernel-side; Runtime sends only the
    /// stable voice preference plus display-safe text.
    // Godot ABI surface: keeping these scalar arguments explicit avoids a
    // Dictionary/Variant bag at the script boundary and preserves the v1 wire contract.
    #[allow(clippy::too_many_arguments)]
    #[func]
    fn request_tts(
        &mut self,
        message_id: GString,
        chunk_index: i64,
        text: GString,
        voice: GString,
        provider_id: GString,
        model_id: GString,
        final_chunk: bool,
    ) -> bool {
        let (clean, _) = sanitize_display_text(&text.to_string());
        if clean.trim().is_empty() {
            return false;
        }
        let data = serde_json::json!({
            "schemaVersion": 1,
            "messageId": message_id.to_string(),
            "chunkIndex": chunk_index,
            "text": clean,
            "voice": voice.to_string(),
            "providerId": provider_id.to_string(),
            "modelId": model_id.to_string(),
            "final": final_chunk,
            "companionId": "default",
        });
        let Ok(env) = Envelope::new("ocp.runtime.tts-requested", "runtime", data) else {
            return false;
        };
        self.outbox
            .as_ref()
            .is_some_and(|sender| sender.send(env).is_ok())
    }

    /// Request one low-latency streaming chat TTS chunk from the kernel voice
    /// router. Kernel falls back to the normal whole-clip router when the
    /// selected provider cannot stream or the streaming credential is absent.
    #[allow(clippy::too_many_arguments)]
    #[func]
    fn request_tts_streaming(
        &mut self,
        message_id: GString,
        chunk_index: i64,
        text: GString,
        voice: GString,
        provider_id: GString,
        model_id: GString,
        final_chunk: bool,
    ) -> bool {
        let (clean, _) = sanitize_display_text(&text.to_string());
        if clean.trim().is_empty() {
            return false;
        }
        let data = serde_json::json!({
            "schemaVersion": 1,
            "messageId": message_id.to_string(),
            "chunkIndex": chunk_index,
            "text": clean,
            "voice": voice.to_string(),
            "providerId": provider_id.to_string(),
            "modelId": model_id.to_string(),
            "deliveryMode": "streaming",
            "final": final_chunk,
            "companionId": "default",
        });
        let Ok(env) = Envelope::new("ocp.runtime.tts-requested", "runtime", data) else {
            return false;
        };
        self.outbox
            .as_ref()
            .is_some_and(|sender| sender.send(env).is_ok())
    }

    /// Reset the allocation-free client-side voice activity detector.
    #[func]
    fn voice_vad_reset(&mut self) {
        self.voice_vad.reset();
    }

    /// Process one PCM16 little-endian mono frame locally. Return codes are
    /// intentionally scalar for cheap Godot calls: -1 invalid, 0 silence,
    /// 1 speech-started, 2 speech-active, 3 speech-ended.
    #[func]
    fn voice_vad_process_pcm16(&mut self, pcm: PackedByteArray) -> i64 {
        let bytes = pcm.as_slice();
        if bytes.is_empty() || bytes.len() > 64 * 1024 || bytes.len() % 2 != 0 {
            return -1;
        }
        let decision = self.voice_vad.process_pcm16_le_bytes(bytes);
        match decision.transition {
            Some(VadTransition::SpeechStarted) => 1,
            Some(VadTransition::SpeechEnded) => 3,
            None if decision.state == VadState::Speech => 2,
            None => 0,
        }
    }

    /// Start one client-VAD-controlled live ASR turn. The Gemini credential
    /// remains Kernel-side; Runtime sends only a bounded session id and optional
    /// BCP-47 language hints.
    #[func]
    fn request_asr_start(
        &mut self,
        session_id: GString,
        language_codes: PackedStringArray,
    ) -> bool {
        let session_id = session_id.to_string();
        let session_id = session_id.trim();
        if session_id.is_empty() || session_id.len() > 128 {
            return false;
        }
        let languages: Vec<String> = language_codes
            .as_slice()
            .iter()
            .map(ToString::to_string)
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty() && value.len() <= 32)
            .take(4)
            .collect();
        let Ok(env) = Envelope::new(
            "ocp.runtime.asr-start",
            "runtime",
            serde_json::json!({
                "schemaVersion": 1,
                "sessionId": session_id,
                "languageCodes": languages,
            }),
        ) else {
            return false;
        };
        self.outbox
            .as_ref()
            .is_some_and(|sender| sender.send(env).is_ok())
    }

    /// Send one mono PCM16 audio chunk to the active ASR turn. Chunks are
    /// bounded before base64 encoding to keep IPC envelopes small and prevent
    /// accidental retention of long microphone buffers.
    #[func]
    fn request_asr_audio(
        &mut self,
        session_id: GString,
        pcm: PackedByteArray,
        sample_rate: i64,
    ) -> bool {
        let session_id = session_id.to_string();
        let session_id = session_id.trim();
        let bytes = pcm.as_slice();
        if session_id.is_empty()
            || session_id.len() > 128
            || sample_rate != 16_000
            || bytes.is_empty()
            || bytes.len() > 64 * 1024
            || bytes.len() % 2 != 0
        {
            return false;
        }
        let encoded = base64::engine::general_purpose::STANDARD.encode(bytes);
        let Ok(env) = Envelope::new(
            "ocp.runtime.asr-audio",
            "runtime",
            serde_json::json!({
                "schemaVersion": 1,
                "sessionId": session_id,
                "sampleRate": sample_rate,
                "pcmBase64": encoded,
            }),
        ) else {
            return false;
        };
        self.outbox
            .as_ref()
            .is_some_and(|sender| sender.send(env).is_ok())
    }

    #[func]
    fn request_asr_end(&mut self, session_id: GString) -> bool {
        let session_id = session_id.to_string();
        let session_id = session_id.trim();
        if session_id.is_empty() || session_id.len() > 128 {
            return false;
        }
        let Ok(env) = Envelope::new(
            "ocp.runtime.asr-end",
            "runtime",
            serde_json::json!({
                "schemaVersion": 1,
                "sessionId": session_id,
            }),
        ) else {
            return false;
        };
        self.outbox
            .as_ref()
            .is_some_and(|sender| sender.send(env).is_ok())
    }

    /// Submit one non-streaming cloud chat turn to Kernel. Provider credentials
    /// stay in the OS keystore; Godot sends only display-safe prompt/config.
    // Godot ABI surface: explicit scalar parameters keep the script contract
    // typed and versioned instead of hiding required fields inside Variant data.
    #[allow(clippy::too_many_arguments)]
    #[func]
    fn request_cloud_ai(
        &mut self,
        message_id: GString,
        prompt: GString,
        system_prompt: GString,
        provider_id: GString,
        base_url: GString,
        model: GString,
        timeout_seconds: i64,
    ) -> bool {
        let (clean_prompt, _) = sanitize_display_text(&prompt.to_string());
        let (clean_system_prompt, _) = sanitize_display_text(&system_prompt.to_string());
        if clean_prompt.trim().is_empty() {
            return false;
        }
        let timeout_seconds = timeout_seconds.clamp(5, 300);
        let data = serde_json::json!({
            "schemaVersion": 1,
            "messageId": message_id.to_string(),
            "prompt": clean_prompt,
            "systemPrompt": clean_system_prompt,
            "providerId": provider_id.to_string(),
            "baseUrl": base_url.to_string(),
            "model": model.to_string(),
            "timeoutSeconds": timeout_seconds,
            "maxOutputTokens": 1024,
            "companionId": "default",
        });
        let Ok(env) = Envelope::new("ocp.runtime.ai-requested", "runtime", data) else {
            return false;
        };
        self.outbox
            .as_ref()
            .is_some_and(|sender| sender.send(env).is_ok())
    }

    // --- Signals: request-facts translated for GDScript (RUNTIME_API §2) ---
    // `text` arguments are already sanitized (§5) before the signal fires.

    // §8.1 (I6.5 slice 4): every per-companion presentation signal now leads
    // with `companion_id` so GDScript can address the right node. Single-
    // companion payloads default to DEFAULT_COMPANION_ID upstream in
    // ocp-runtime-api, so legacy senders keep working unchanged.

    #[signal]
    fn bubble_requested(
        companion_id: GString,
        bubble_id: GString,
        text: GString,
        tone: GString,
        duration_ms: i64,
        truncated: bool,
    );

    // `audio_path` (I7 V1 slice 4b): the local WAV file to play, or "" when TTS
    // was unavailable (GDScript then shows the subtitle / speaks `text` itself).
    #[signal]
    fn speech_requested(
        companion_id: GString,
        speech_id: GString,
        text: GString,
        subtitle: bool,
        audio_path: GString,
    );

    #[signal]
    fn speech_route_diagnostic(speech_id: GString, reason_code: GString);

    /// Voice Realtime V2 input transcription lifecycle. These signals contain
    /// only session ids, transcript text and route metadata; provider
    /// credentials never cross the Kernel/Runtime boundary.
    #[signal]
    fn asr_ready(session_id: GString, provider_id: GString, model_id: GString, sample_rate: i64);

    #[signal]
    fn asr_interim(session_id: GString, text: GString);

    #[signal]
    fn asr_final(session_id: GString, text: GString);

    #[signal]
    fn asr_turn_complete(session_id: GString);

    #[signal]
    fn asr_interrupted(session_id: GString);

    #[signal]
    fn asr_error(session_id: GString, reason_code: GString);

    #[signal]
    fn asr_closed(session_id: GString);

    /// Internal bridge lifecycle used by RuntimeV3TTSService. `speech_started`
    /// fires before the existing `speech_requested` presentation signal so the
    /// Chat lifecycle is armed before any synchronous tts-unavailable finish.
    #[signal]
    fn speech_started(companion_id: GString, speech_id: GString, text: GString);

    /// Voice Realtime V2 correlation-preserving lifecycle. Legacy signals stay
    /// available for older Runtime scripts, while V2 consumers receive the
    /// originating Chat message/chunk identity directly instead of matching by
    /// display text.
    #[signal]
    fn speech_started_v2(
        companion_id: GString,
        speech_id: GString,
        message_id: GString,
        chunk_index: i64,
        final_chunk: bool,
        text: GString,
    );

    /// Gemini streaming lifecycle. Chunks are raw PCM encoded as base64 in the
    /// kernel envelope and decoded once at the Rust/Godot boundary.
    #[signal]
    fn speech_stream_started(
        companion_id: GString,
        speech_id: GString,
        text: GString,
        sample_rate: i64,
        channels: i64,
        sample_width: i64,
    );

    #[signal]
    fn speech_stream_started_v2(
        companion_id: GString,
        speech_id: GString,
        message_id: GString,
        chunk_index: i64,
        final_chunk: bool,
        text: GString,
        sample_rate: i64,
        channels: i64,
        sample_width: i64,
    );

    #[signal]
    fn speech_audio_chunk(speech_id: GString, audio: PackedByteArray);

    #[signal]
    fn speech_stream_finished(speech_id: GString, companion_id: GString, outcome: GString);

    #[signal]
    fn speech_finished(speech_id: GString, companion_id: GString, outcome: GString);

    #[signal]
    fn ai_response_received(
        message_id: GString,
        text: GString,
        provider_id: GString,
        model: GString,
    );

    #[signal]
    fn ai_response_failed(message_id: GString, error: GString, provider_id: GString);

    #[signal]
    fn emotion_changed(companion_id: GString, emotion: GString, emotion_instance: GString);

    #[signal]
    fn animation_requested(
        companion_id: GString,
        animation_id: GString,
        looped: bool,
        priority: GString,
        blend_ms: i64,
        animation_instance: GString,
    );

    // --- §8.2 companion lifecycle (ADR-0013, I6.5 slice 4) ---

    #[signal]
    fn companion_spawn_requested(
        companion_id: GString,
        character_package_id: GString,
        x: i64,
        y: i64,
    );

    #[signal]
    fn companion_despawn_requested(companion_id: GString);

    #[signal]
    fn companion_sleep_requested(companion_id: GString, active: bool);

    #[signal]
    fn companion_visibility_requested(companion_id: GString, visible: bool);

    #[signal]
    fn companion_focus_requested(companion_id: GString);

    #[signal]
    fn companion_follow_requested(
        companion_id: GString,
        leader_companion_id: GString,
        active: bool,
        distance_px: i64,
    );

    #[signal]
    fn look_at_cursor_requested(companion_id: GString, duration_ms: i64);

    #[signal]
    fn window_policy_changed(transparent: bool, always_on_top: bool, click_through: GString);

    #[signal]
    fn state_changed(from_state: GString, to_state: GString);

    #[signal]
    fn connection_lost();

    #[signal]
    fn connection_restored();

    #[signal]
    fn world_event_received(event_type: GString, payload_json: GString);

    // Rust validates the complete movement contract before exposing one
    // Godot-safe Dictionary payload. The signal ABI stays stable as the
    // contract gains optional fields.
    #[signal]
    fn companion_moved(payload: Dictionary<Variant, Variant>);

    #[signal]
    fn companion_presentation_state(payload: Dictionary<Variant, Variant>);

    #[signal]
    fn render_host_ready(companion_id: GString, host_token: GString);

    #[signal]
    fn render_host_resized(width: i64, height: i64);

    #[signal]
    fn render_host_detached(companion_id: GString);

    /// Local, non-authoritative progression event queue. The database is only
    /// a retry/cache boundary; hosted C4 remains the sole XP/level authority.
    #[func]
    fn progression_queue_enqueue(
        &self,
        database_path: GString,
        event_json: GString,
    ) -> Dictionary<Variant, Variant> {
        let mut result = Dictionary::new();
        match progression_queue_enqueue_db(
            Path::new(&database_path.to_string()),
            &event_json.to_string(),
        ) {
            Ok(inserted) => {
                result.set("ok", true);
                result.set("inserted", inserted);
            }
            Err(message) => {
                result.set("ok", false);
                result.set("error", message);
            }
        }
        result
    }

    #[func]
    fn progression_queue_list(
        &self,
        database_path: GString,
        limit: i64,
    ) -> Dictionary<Variant, Variant> {
        let mut result = Dictionary::new();
        let safe_limit = usize::try_from(limit).unwrap_or(0);
        match progression_queue_list_db(Path::new(&database_path.to_string()), safe_limit) {
            Ok(events) => {
                result.set("ok", true);
                result.set(
                    "events_json",
                    serde_json::to_string(&events).unwrap_or_else(|_| "[]".to_owned()),
                );
            }
            Err(message) => {
                result.set("ok", false);
                result.set("error", message);
            }
        }
        result
    }

    #[func]
    fn progression_queue_ack(
        &self,
        database_path: GString,
        event_ids_json: GString,
    ) -> Dictionary<Variant, Variant> {
        let mut result = Dictionary::new();
        match progression_queue_ack_db(
            Path::new(&database_path.to_string()),
            &event_ids_json.to_string(),
        ) {
            Ok(removed) => {
                result.set("ok", true);
                result.set("removed", removed as i64);
            }
            Err(message) => {
                result.set("ok", false);
                result.set("error", message);
            }
        }
        result
    }

    #[func]
    fn progression_projection_store(
        &self,
        database_path: GString,
        user_id: GString,
        projection_json: GString,
    ) -> Dictionary<Variant, Variant> {
        let mut result = Dictionary::new();
        match progression_projection_store_db(
            Path::new(&database_path.to_string()),
            &user_id.to_string(),
            &projection_json.to_string(),
        ) {
            Ok(()) => {
                result.set("ok", true);
            }
            Err(message) => {
                result.set("ok", false);
                result.set("error", message);
            }
        }
        result
    }

    #[func]
    fn progression_projection_load(
        &self,
        database_path: GString,
        user_id: GString,
    ) -> Dictionary<Variant, Variant> {
        let mut result = Dictionary::new();
        match progression_projection_load_db(
            Path::new(&database_path.to_string()),
            &user_id.to_string(),
        ) {
            Ok(projection) => {
                result.set("ok", true);
                result.set("projection_json", projection.unwrap_or_default());
            }
            Err(message) => {
                result.set("ok", false);
                result.set("error", message);
            }
        }
        result
    }

    /// Security boundary for the Bible POC installer. `packages_root` is a
    /// Godot-globalized `user://packages/characters` path supplied by the host.
    #[func]
    fn install_character_package(
        &mut self,
        archive_path: GString,
        packages_root: GString,
    ) -> Dictionary<Variant, Variant> {
        let mut result = Dictionary::new();
        match install_verified_character_archive(
            Path::new(&archive_path.to_string()),
            Path::new(&packages_root.to_string()),
        ) {
            Ok((package_id, version)) => {
                result.set("ok", true);
                result.set("package_id", package_id);
                result.set("version", version);
            }
            Err(message) => {
                result.set("ok", false);
                result.set("error", message);
            }
        }
        result
    }

    /// Cloud-marketplace install boundary. The R2 object must match the immutable
    /// Cloud API SHA/signature metadata and still pass the runtime trust store.
    /// This keeps the browser/Cloud API from being able to bypass package trust.
    #[func]
    fn install_cloud_package(
        &mut self,
        archive_path: GString,
        packages_root: GString,
        expected_sha256: GString,
        expected_signature_key_id: GString,
        expected_signature: GString,
        marketplace_trust_bundle: GString,
    ) -> Dictionary<Variant, Variant> {
        let mut result = Dictionary::new();
        let archive_path = archive_path.to_string();
        let packages_root = packages_root.to_string();
        let expected_sha256 = expected_sha256.to_string();
        let expected_signature_key_id = expected_signature_key_id.to_string();
        let expected_signature = expected_signature.to_string();
        let marketplace_trust_bundle = marketplace_trust_bundle.to_string();
        match cloud_package::install(
            Path::new(&archive_path),
            Path::new(&packages_root),
            &expected_sha256,
            &expected_signature_key_id,
            &expected_signature,
            &marketplace_trust_bundle,
        ) {
            Ok((installed, evidence)) => {
                result.set("ok", true);
                result.set("package_id", installed.id);
                result.set("version", installed.version);
                result.set("package_type", installed.package_type);
                result.set("already_installed", installed.already_installed);
                result.set("revocation_stale", evidence.revocation_stale);
                result.set("trust_mode", evidence.mode);
                result.set(
                    "trust_sequence",
                    i64::try_from(evidence.sequence).unwrap_or(i64::MAX),
                );
                result.set(
                    "trusted_publishers",
                    i64::try_from(evidence.publisher_count).unwrap_or(i64::MAX),
                );
            }
            Err(message) => {
                result.set("ok", false);
                result.set("error", message);
            }
        }
        result
    }

    /// Backward-compatible character install entrypoint. New marketplace
    /// clients should use install_cloud_package so effect-pack can share the
    /// same immutable archive and trust boundary.
    #[func]
    fn install_cloud_character_package(
        &mut self,
        archive_path: GString,
        packages_root: GString,
        expected_sha256: GString,
        expected_signature_key_id: GString,
        expected_signature: GString,
        marketplace_trust_bundle: GString,
    ) -> Dictionary<Variant, Variant> {
        self.install_cloud_package(
            archive_path,
            packages_root,
            expected_sha256,
            expected_signature_key_id,
            expected_signature,
            marketplace_trust_bundle,
        )
    }

    /// Stateless filesystem verification; safe to use without opening IPC.
    #[func]
    fn verify_installed_cloud_package(package_path: GString) -> Dictionary<Variant, Variant> {
        let mut result = Dictionary::new();
        match cloud_package::verify_installed(Path::new(&package_path.to_string())) {
            Ok(package) => {
                result.set("ok", true);
                result.set("managed", package.is_some());
                if let Some(package) = package {
                    match cloud_package::member(&package, &package.manifest.entry).and_then(
                        |bytes| {
                            String::from_utf8(bytes)
                                .map_err(|_| "Invalid package entry JSON encoding".to_owned())
                        },
                    ) {
                        Ok(entry) => {
                            result.set("entry_json", entry);
                            result.set(
                                "manifest_json",
                                serde_json::to_string(&package.manifest)
                                    .expect("serializable manifest"),
                            );
                        }
                        Err(error) => {
                            result.set("ok", false);
                            result.set("error", error);
                        }
                    }
                }
            }
            Err(error) => {
                result.set("ok", false);
                result.set("error", error);
            }
        }
        result
    }

    /// Backward-compatible verifier used by the existing character repository.
    #[func]
    fn verify_installed_cloud_character(package_path: GString) -> Dictionary<Variant, Variant> {
        Self::verify_installed_cloud_package(package_path)
    }

    /// Called by GDScript to report input (RUNTIME_API §2.7). The runtime
    /// reports the fact; core decides what it means. Text is sanitized like
    /// any other display-adjacent string before it leaves this process.
    #[func]
    fn capture_input(&mut self, modality: GString, text: GString, target: GString) {
        let (clean, _) = sanitize_display_text(&text.to_string());
        let data = serde_json::json!({
            "inputId": uuid::Uuid::now_v7(),
            "modality": modality.to_string(),
            "text": if clean.is_empty() { serde_json::Value::Null } else { clean.into() },
            "target": target.to_string(),
        });
        if let Ok(env) = Envelope::new("ocp.runtime.input-captured", "runtime", data) {
            if let Some(tx) = &self.outbox {
                let _ = tx.send(env);
            }
        }
    }

    /// Called by GDScript when a speech clip finishes (or is interrupted, or
    /// had no audio to play), so the **real** `speech-completed` fires with
    /// true timing (I7 V1 slice 4b) — retiring I2's fake-immediate completion.
    /// `outcome` is `finished` | `interrupted` | `tts-unavailable`
    /// (RUNTIME_API §2.6). A report for an unknown/expired `speechId` is
    /// dropped (idempotent — a double-report can't emit twice).
    #[func]
    fn report_speech_finished(
        &mut self,
        speech_id: GString,
        companion_id: GString,
        outcome: GString,
    ) {
        let Ok(speech_uuid) = uuid::Uuid::parse_str(&speech_id.to_string()) else {
            return;
        };
        let Some(cause_id) = self.pending_speech.remove(&speech_uuid) else {
            return;
        };
        self.base_mut().emit_signal(
            "speech_finished",
            &[
                speech_id.to_variant(),
                companion_id.to_variant(),
                outcome.to_variant(),
            ],
        );
        self.emit_outcome_correlated(
            "ocp.runtime.speech-completed",
            serde_json::json!({
                "speechId": speech_id.to_string(),
                "companionId": companion_id.to_string(),
                "outcome": outcome.to_string(),
            }),
            cause_id,
        );
    }

    /// Called by GDScript when an animation actually ends, so the **real**
    /// `animation-completed` fires with true §7 timing (I8A slice 1) — retiring
    /// I2's fake-immediate completion. `outcome` is `finished` | `cancelled` |
    /// `missing-asset` (RUNTIME_API §2.2). `animation_instance` is the token the
    /// `animation_requested` signal carried; a report for an unknown/expired
    /// token is dropped (idempotent — a double-report can't emit twice).
    #[func]
    fn report_animation_finished(
        &mut self,
        animation_instance: GString,
        companion_id: GString,
        animation_id: GString,
        outcome: GString,
    ) {
        let Ok(instance) = uuid::Uuid::parse_str(&animation_instance.to_string()) else {
            return;
        };
        let Some(cause_id) = self.pending_animation.remove(&instance) else {
            return;
        };
        self.emit_outcome_correlated(
            "ocp.runtime.animation-completed",
            serde_json::json!({
                "animationId": animation_id.to_string(),
                "companionId": companion_id.to_string(),
                "outcome": outcome.to_string(),
            }),
            cause_id,
        );
    }

    /// Called by GDScript's Expression module after it renders `emotion-changed`,
    /// so `emotion-presented` carries the **real** `expressionSet` and `fallback`
    /// (RUNTIME_API §2.5) instead of the bridge's old hardcoded guess (I8A slice
    /// 2b — the last fake runtime outcome retired). A report for an
    /// unknown/expired token is dropped.
    #[func]
    fn report_emotion_presented(
        &mut self,
        emotion_instance: GString,
        companion_id: GString,
        emotion: GString,
        expression_set: GString,
        fallback: bool,
    ) {
        let Ok(instance) = uuid::Uuid::parse_str(&emotion_instance.to_string()) else {
            return;
        };
        let Some(cause_id) = self.pending_emotion.remove(&instance) else {
            return;
        };
        self.emit_outcome_correlated(
            "ocp.runtime.emotion-presented",
            serde_json::json!({
                "companionId": companion_id.to_string(),
                "emotion": emotion.to_string(),
                "expressionSet": expression_set.to_string(),
                "fallback": fallback,
            }),
            cause_id,
        );
    }

    /// Like [`Self::emit_outcome`] but correlates to a remembered cause id
    /// rather than a live `&Envelope` — for outcomes that fire later than their
    /// trigger (the deferred `speech-completed`, I7 V1 slice 4b).
    fn emit_outcome_correlated(
        &self,
        event_type: &str,
        data: serde_json::Value,
        correlation_id: uuid::Uuid,
    ) {
        if let Ok(env) = Envelope::new(event_type, "runtime", data) {
            let env = env.with_correlation(correlation_id);
            if let Some(tx) = &self.outbox {
                let _ = tx.send(env);
            }
        }
    }

    /// Send one outcome fact back over IPC, correlated to its cause (NFR-004).
    fn emit_outcome(&self, event_type: &str, data: serde_json::Value, cause: &Envelope) {
        if let Ok(env) = Envelope::new(event_type, "runtime", data) {
            let env = env.with_correlation(cause.id);
            if let Some(tx) = &self.outbox {
                let _ = tx.send(env);
            }
        }
    }

    /// Apply a window policy at the OS/compositor level and report what
    /// actually stuck (RUNTIME_API §3.1: degrade, never fail silently). This
    /// lives in Rust, not GDScript, because truthful degradation reporting is
    /// a contract obligation (§1), not presentation.
    ///
    /// SKELETON STATUS: written against the DisplayServer API surface as
    /// documented in Godot 4's window-transparency/mouse-passthrough guides
    /// (project setting `display/window/per_pixel_transparency/allowed` must
    /// also be enabled in `godot/project.godot`, done). Per-pixel transparency
    /// is known to be finicky across Godot 4.x point releases/renderers/
    /// resolutions (e.g. godotengine/godot#99903) — if the window renders
    /// solid black instead of transparent despite `degraded` coming back
    /// empty (flag read-back says it took), that is this known engine-level
    /// issue, not a contract violation; the fix there is disabling "Embed
    /// Game" in the editor and/or confirming the Compatibility renderer is
    /// active (already the project default). `window_set_flag`'s exact
    /// default-window-id calling convention in gdext 0.5 may need a one-line
    /// fix-up on first build, same pattern as every other GDExtension API
    /// surface in this crate so far.
    fn apply_window_policy(&mut self, policy: &WindowPolicy) -> Vec<String> {
        let mut degraded = Vec::new();
        let mut ds = DisplayServer::singleton();

        // §3.1 Transparency: both the flag and the viewport's own opt-in are
        // required (Godot 4 quirk — the flag alone renders solid black).
        ds.window_set_flag(WindowFlags::TRANSPARENT, policy.transparent);
        self.base()
            .get_tree()
            .get_root()
            .expect("main window root always present while the runtime is live")
            .set_transparent_background(policy.transparent);
        if policy.transparent && !ds.window_get_flag(WindowFlags::TRANSPARENT) {
            degraded.push("transparent".to_owned());
        }

        // §3.2 Always-on-top.
        ds.window_set_flag(WindowFlags::ALWAYS_ON_TOP, policy.always_on_top);
        if policy.always_on_top && !ds.window_get_flag(WindowFlags::ALWAYS_ON_TOP) {
            degraded.push("alwaysOnTop".to_owned());
        }

        // §3.3 Click-through. `always` = whole window ignores clicks.
        // `outside-sprite` bounds the passthrough region to the placeholder
        // `CompanionSprite` ColorRect's own rect (I3 slice 4) — a real alpha
        // mask still belongs to the character package (later increment), but
        // a rectangular region is a real, honest bound rather than a guess.
        // If the node isn't found (e.g. a scene without a sprite), fall back
        // to `never` and report the gap instead of silently over/under-
        // passing clicks.
        //
        // SKELETON STATUS: `window_set_mouse_passthrough`'s exact region
        // convention (window-local coords, winding order) is written against
        // the Godot 4 docs, unverified against gdext 0.5's binding — expect a
        // possible one-line fix-up on first build, same as other DisplayServer
        // call sites in this file.
        match policy.click_through.as_str() {
            "always" => ds.window_set_flag(WindowFlags::MOUSE_PASSTHROUGH, true),
            "never" => ds.window_set_flag(WindowFlags::MOUSE_PASSTHROUGH, false),
            "outside-sprite" => {
                let sprite = self
                    .base()
                    .try_get_node_as::<ColorRect>("../CompanionSprite");
                if let Some(sprite) = sprite {
                    let rect = sprite.get_global_rect();
                    let top_left = rect.position;
                    let top_right = Vector2::new(rect.position.x + rect.size.x, rect.position.y);
                    let bottom_right = rect.position + rect.size;
                    let bottom_left = Vector2::new(rect.position.x, rect.position.y + rect.size.y);
                    let region = PackedVector2Array::from(
                        &[top_left, top_right, bottom_right, bottom_left][..],
                    );
                    ds.window_set_mouse_passthrough(&region);
                } else {
                    ds.window_set_flag(WindowFlags::MOUSE_PASSTHROUGH, false);
                    degraded.push("clickThrough".to_owned());
                }
            }
            _ => {}
        }

        degraded
    }

    /// Translate one inbound request-fact into a Godot signal + the matching
    /// outcome fact. Mirrors `ocp_runtime_stub::StubRuntime::handle` — same
    /// enforcement, different presentation surface.
    fn dispatch(&mut self, env: &Envelope) {
        if env.event_type == "ocp.runtime.companion-presentation-state" {
            let Some(state) = parse_companion_presentation_state(&env.data) else {
                return;
            };
            let mut payload: Dictionary<Variant, Variant> = Dictionary::new();
            payload.set("schemaVersion", 1_i64);
            payload.set("companionId", state.companion_id);
            payload.set("bodyId", i64::try_from(state.body_id).unwrap_or(i64::MAX));
            payload.set("desktopFeet", Vector2::new(state.x as f32, state.y as f32));
            payload.set(
                "velocity",
                Vector2::new(state.velocity_x as f32, state.velocity_y as f32),
            );
            payload.set("grounded", state.grounded);
            payload.set("movementState", state.movement_state);
            payload.set("attachmentState", state.attachment_state);
            if let Some(surface_kind) = state.surface_kind {
                payload.set("surfaceKind", surface_kind);
            }
            payload.set("facing", state.facing);
            payload.set("updateKind", state.update_kind);
            payload.set(
                "sequence",
                i64::try_from(state.sequence).unwrap_or(i64::MAX),
            );
            payload.set(
                "revision",
                i64::try_from(state.revision).unwrap_or(i64::MAX),
            );

            self.base_mut()
                .emit_signal("companion_presentation_state", &[payload.to_variant()]);
            return;
        }

        if env.event_type == "ocp.runtime.companion-moved" {
            let Some(moved) = parse_companion_moved(&env.data) else {
                return;
            };
            let sequence = i64::try_from(moved.sequence).unwrap_or(i64::MAX);
            let mut payload: Dictionary<Variant, Variant> = Dictionary::new();
            payload.set("companionId", moved.companion_id);
            payload.set("position", Vector2::new(moved.x as f32, moved.y as f32));
            payload.set(
                "velocity",
                Vector2::new(moved.velocity_x as f32, moved.velocity_y as f32),
            );
            payload.set("grounded", moved.grounded);
            payload.set("movementState", moved.movement_state);
            payload.set("motion", moved.motion);
            payload.set("sequence", sequence);

            self.base_mut()
                .emit_signal("companion_moved", &[payload.to_variant()]);
            return;
        }

        if env.event_type.starts_with("ocp.world.")
            || env.event_type.starts_with("ocp.surface.")
            || env.event_type.starts_with("ocp.runtime.desktop-world-")
        {
            let payload_json = serde_json::to_string(&env.data).unwrap_or_else(|_| "{}".to_owned());
            self.base_mut().emit_signal(
                "world_event_received",
                &[env.event_type.to_variant(), payload_json.to_variant()],
            );
            return;
        }

        match env.event_type.as_str() {
            "ocp.runtime.ai-response" => {
                let message_id = env
                    .data
                    .get("messageId")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default();
                let provider_id = env
                    .data
                    .get("providerId")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("openai-compatible");
                if env.data.get("ok").and_then(serde_json::Value::as_bool) == Some(true) {
                    let text = env
                        .data
                        .get("text")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or_default();
                    let (clean_text, _) = sanitize_display_text(text);
                    let model = env
                        .data
                        .get("model")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or_default();
                    self.base_mut().emit_signal(
                        "ai_response_received",
                        &[
                            message_id.to_variant(),
                            clean_text.to_variant(),
                            provider_id.to_variant(),
                            model.to_variant(),
                        ],
                    );
                } else {
                    let error = env
                        .data
                        .get("error")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("Cloud AI request failed");
                    let (clean_error, _) = sanitize_display_text(error);
                    self.base_mut().emit_signal(
                        "ai_response_failed",
                        &[
                            message_id.to_variant(),
                            clean_error.to_variant(),
                            provider_id.to_variant(),
                        ],
                    );
                }
            }
            "ocp.voice.asr-ready" => {
                let session_id = env
                    .data
                    .get("sessionId")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default();
                let provider_id = env
                    .data
                    .get("providerId")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("gemini-live");
                let model_id = env
                    .data
                    .get("modelId")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default();
                let sample_rate = env
                    .data
                    .get("sampleRate")
                    .and_then(serde_json::Value::as_i64)
                    .unwrap_or(16_000);
                self.base_mut().emit_signal(
                    "asr_ready",
                    &[
                        session_id.to_variant(),
                        provider_id.to_variant(),
                        model_id.to_variant(),
                        sample_rate.to_variant(),
                    ],
                );
            }
            "ocp.voice.asr-interim" => {
                let session_id = env
                    .data
                    .get("sessionId")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default();
                let text = env
                    .data
                    .get("text")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default();
                let (clean, _) = sanitize_display_text(text);
                self.base_mut().emit_signal(
                    "asr_interim",
                    &[session_id.to_variant(), clean.to_variant()],
                );
            }
            "ocp.voice.asr-final" => {
                let session_id = env
                    .data
                    .get("sessionId")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default();
                let text = env
                    .data
                    .get("text")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default();
                let (clean, _) = sanitize_display_text(text);
                self.base_mut()
                    .emit_signal("asr_final", &[session_id.to_variant(), clean.to_variant()]);
            }
            "ocp.voice.asr-turn-complete" => {
                let session_id = env
                    .data
                    .get("sessionId")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default();
                self.base_mut()
                    .emit_signal("asr_turn_complete", &[session_id.to_variant()]);
            }
            "ocp.voice.asr-interrupted" => {
                let session_id = env
                    .data
                    .get("sessionId")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default();
                self.base_mut()
                    .emit_signal("asr_interrupted", &[session_id.to_variant()]);
            }
            "ocp.voice.asr-error" => {
                let session_id = env
                    .data
                    .get("sessionId")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default();
                let reason = env
                    .data
                    .get("reasonCode")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("asr-unavailable");
                self.base_mut()
                    .emit_signal("asr_error", &[session_id.to_variant(), reason.to_variant()]);
            }
            "ocp.voice.asr-closed" => {
                let session_id = env
                    .data
                    .get("sessionId")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default();
                self.base_mut()
                    .emit_signal("asr_closed", &[session_id.to_variant()]);
            }
            "ocp.behavior.bubble-requested" => {
                let Ok(req) = serde_json::from_value::<BubbleRequested>(env.data.clone()) else {
                    return; // malformed payload: drop (SEC-041 already gated at ocp-ipc)
                };
                let (text, truncated) = sanitize_display_text(&req.text);
                let duration_ms = req.duration_ms.map_or(-1, |d| d as i64); // -1 = until dismissed
                self.base_mut().emit_signal(
                    "bubble_requested",
                    &[
                        req.companion_id.to_variant(),
                        req.bubble_id.to_string().to_variant(),
                        text.to_variant(),
                        req.tone.to_variant(),
                        duration_ms.to_variant(),
                        truncated.to_variant(),
                    ],
                );
                self.emit_outcome(
                    "ocp.runtime.bubble-shown",
                    serde_json::json!({
                        "bubbleId": req.bubble_id,
                        "companionId": req.companion_id,
                        "shownAt": chrono::Utc::now().to_rfc3339(),
                        "truncated": truncated,
                    }),
                    env,
                );
            }
            "ocp.behavior.speech-requested" => {
                let Ok(req) = serde_json::from_value::<SpeechRequested>(env.data.clone()) else {
                    return;
                };
                let (text, _) = sanitize_display_text(&req.text);
                let streaming = env
                    .data
                    .get("streaming")
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(false);
                let message_id = env
                    .data
                    .get("messageId")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default();
                let chunk_index = env
                    .data
                    .get("chunkIndex")
                    .and_then(serde_json::Value::as_i64)
                    .unwrap_or(0);
                let final_chunk = env
                    .data
                    .get("final")
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(false);
                self.pending_speech.insert(req.speech_id, env.id);
                if streaming {
                    self.base_mut().emit_signal(
                        "speech_stream_started",
                        &[
                            req.companion_id.to_variant(),
                            req.speech_id.to_string().to_variant(),
                            text.to_variant(),
                            24_000_i64.to_variant(),
                            1_i64.to_variant(),
                            2_i64.to_variant(),
                        ],
                    );
                    self.base_mut().emit_signal(
                        "speech_stream_started_v2",
                        &[
                            req.companion_id.to_variant(),
                            req.speech_id.to_string().to_variant(),
                            message_id.to_variant(),
                            chunk_index.to_variant(),
                            final_chunk.to_variant(),
                            text.to_variant(),
                            24_000_i64.to_variant(),
                            1_i64.to_variant(),
                            2_i64.to_variant(),
                        ],
                    );
                } else {
                    let audio_path = req
                        .audio_ref
                        .as_ref()
                        .map(|a| audio_clip_path(a.id).to_string_lossy().into_owned())
                        .unwrap_or_default();
                    self.base_mut().emit_signal(
                        "speech_started",
                        &[
                            req.companion_id.to_variant(),
                            req.speech_id.to_string().to_variant(),
                            text.to_variant(),
                        ],
                    );
                    self.base_mut().emit_signal(
                        "speech_started_v2",
                        &[
                            req.companion_id.to_variant(),
                            req.speech_id.to_string().to_variant(),
                            message_id.to_variant(),
                            chunk_index.to_variant(),
                            final_chunk.to_variant(),
                            text.to_variant(),
                        ],
                    );
                    if !req.route_reason.is_empty() {
                        self.base_mut().emit_signal(
                            "speech_route_diagnostic",
                            &[
                                req.speech_id.to_string().to_variant(),
                                req.route_reason.to_variant(),
                            ],
                        );
                    }
                    self.base_mut().emit_signal(
                        "speech_requested",
                        &[
                            req.companion_id.to_variant(),
                            req.speech_id.to_string().to_variant(),
                            text.to_variant(),
                            req.subtitle.to_variant(),
                            audio_path.to_variant(),
                        ],
                    );
                }
                self.emit_outcome(
                    "ocp.runtime.speech-started",
                    serde_json::json!({ "speechId": req.speech_id, "companionId": req.companion_id }),
                    env,
                );
            }
            "ocp.behavior.speech-audio-chunk" => {
                let speech_id = env
                    .data
                    .get("speechId")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default();
                let encoded = env
                    .data
                    .get("audioBase64")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default();
                if speech_id.is_empty() || encoded.is_empty() {
                    return;
                }
                let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(encoded) else {
                    return;
                };
                self.base_mut().emit_signal(
                    "speech_audio_chunk",
                    &[
                        speech_id.to_variant(),
                        PackedByteArray::from(bytes.as_slice()).to_variant(),
                    ],
                );
            }
            "ocp.behavior.speech-audio-finished" => {
                let speech_id = env
                    .data
                    .get("speechId")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or_default();
                let companion_id = env
                    .data
                    .get("companionId")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("default");
                let outcome = env
                    .data
                    .get("outcome")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("stream-error");
                self.base_mut().emit_signal(
                    "speech_stream_finished",
                    &[
                        speech_id.to_variant(),
                        companion_id.to_variant(),
                        outcome.to_variant(),
                    ],
                );
            }
            "ocp.behavior.emotion-changed" => {
                let Ok(req) = serde_json::from_value::<EmotionChanged>(env.data.clone()) else {
                    return;
                };
                // I8A slice 2b: mint a token so GDScript's Expression module can
                // report the real expressionSet/fallback back for a correlated
                // emotion-presented — no more hardcoded "default"/true here.
                let instance = uuid::Uuid::now_v7();
                self.base_mut().emit_signal(
                    "emotion_changed",
                    &[
                        req.companion_id.to_variant(),
                        req.to.to_variant(),
                        instance.to_string().to_variant(),
                    ],
                );
                self.pending_emotion.insert(instance, env.id);
            }
            "ocp.behavior.animation-requested" => {
                let Ok(req) = serde_json::from_value::<AnimationRequested>(env.data.clone()) else {
                    return;
                };
                // I8A slice 1: mint an instance token so the deferred
                // animation-completed (reported by GDScript when playback ends)
                // stays correlated to this request's envelope.
                let instance = uuid::Uuid::now_v7();
                self.base_mut().emit_signal(
                    "animation_requested",
                    &[
                        req.companion_id.to_variant(),
                        req.animation_id.clone().to_variant(),
                        req.looped.to_variant(),
                        req.priority.clone().to_variant(),
                        (req.blend_ms as i64).to_variant(),
                        instance.to_string().to_variant(),
                    ],
                );
                self.emit_outcome(
                    "ocp.runtime.animation-started",
                    serde_json::json!({ "animationId": req.animation_id, "companionId": req.companion_id }),
                    env,
                );
                // No more fake-immediate completion (I2's simplification, the
                // same one I7 retired for speech): remember the cause and wait
                // for GDScript's `report_animation_finished` when the animation
                // actually ends (real §7 timing).
                self.pending_animation.insert(instance, env.id);
            }
            "ocp.companion.window-policy-changed" => {
                let Ok(policy) = serde_json::from_value::<WindowPolicy>(env.data.clone()) else {
                    return;
                };
                let degraded = self.apply_window_policy(&policy);
                self.base_mut().emit_signal(
                    "window_policy_changed",
                    &[
                        policy.transparent.to_variant(),
                        policy.always_on_top.to_variant(),
                        policy.click_through.to_variant(),
                    ],
                );
                self.emit_outcome(
                    "ocp.runtime.window-state-changed",
                    serde_json::json!({ "applied": policy, "degraded": degraded }),
                    env,
                );
            }
            "ocp.companion.state-changed" => {
                // Mirror only (RUNTIME.md) — no outbound fact.
                let from = env.data.get("from").and_then(|v| v.as_str()).unwrap_or("");
                let to = env.data.get("to").and_then(|v| v.as_str()).unwrap_or("");
                self.base_mut()
                    .emit_signal("state_changed", &[from.to_variant(), to.to_variant()]);
            }

            // --- §8.2 companion lifecycle (ADR-0013, I6.5 slice 4). Outcome
            // facts fire immediately after the signal — the same immediate-
            // completion simplification as speech/animation above (GDScript
            // node creation is same-frame, so this is close to truthful; a
            // real async asset-loading pipeline should move these to fire on
            // actual completion — flagged, not hidden). Semantics mirror
            // `ocp_runtime_stub::StubRuntime` so the Godot side can pass the
            // identical `certify_multi_companion` harness later.
            "ocp.behavior.companion-spawn-requested" => {
                let Ok(req) = serde_json::from_value::<CompanionSpawnRequested>(env.data.clone())
                else {
                    return;
                };
                let position = req.initial_position.clone().unwrap_or(Position {
                    x: 0,
                    y: 0,
                    monitor_id: None,
                });
                self.base_mut().emit_signal(
                    "companion_spawn_requested",
                    &[
                        req.companion_id.to_variant(),
                        req.character_package_id.to_variant(),
                        position.x.to_variant(),
                        position.y.to_variant(),
                    ],
                );
                self.emit_outcome(
                    "ocp.runtime.companion-spawned",
                    serde_json::json!({ "companionId": req.companion_id, "position": &position }),
                    env,
                );
            }
            "ocp.behavior.companion-despawn-requested" => {
                let Ok(req) = serde_json::from_value::<CompanionRef>(env.data.clone()) else {
                    return;
                };
                self.base_mut().emit_signal(
                    "companion_despawn_requested",
                    &[req.companion_id.to_variant()],
                );
                self.emit_outcome(
                    "ocp.runtime.companion-despawned",
                    serde_json::json!({ "companionId": req.companion_id }),
                    env,
                );
            }
            "ocp.behavior.companion-sleep-requested" => {
                let Ok(req) = serde_json::from_value::<CompanionSleepRequested>(env.data.clone())
                else {
                    return;
                };
                self.base_mut().emit_signal(
                    "companion_sleep_requested",
                    &[req.companion_id.to_variant(), req.active.to_variant()],
                );
                let outcome_type = if req.active {
                    "ocp.runtime.companion-slept"
                } else {
                    "ocp.runtime.companion-woken"
                };
                self.emit_outcome(
                    outcome_type,
                    serde_json::json!({ "companionId": req.companion_id }),
                    env,
                );
            }
            "ocp.behavior.companion-show-requested" => {
                let Ok(req) = serde_json::from_value::<CompanionRef>(env.data.clone()) else {
                    return;
                };
                self.base_mut().emit_signal(
                    "companion_visibility_requested",
                    &[req.companion_id.to_variant(), true.to_variant()],
                );
                self.emit_outcome(
                    "ocp.runtime.companion-shown",
                    serde_json::json!({ "companionId": req.companion_id }),
                    env,
                );
            }
            "ocp.behavior.companion-hide-requested" => {
                let Ok(req) = serde_json::from_value::<CompanionRef>(env.data.clone()) else {
                    return;
                };
                self.base_mut().emit_signal(
                    "companion_visibility_requested",
                    &[req.companion_id.to_variant(), false.to_variant()],
                );
                self.emit_outcome(
                    "ocp.runtime.companion-hidden",
                    serde_json::json!({ "companionId": req.companion_id }),
                    env,
                );
            }
            "ocp.behavior.companion-focus-requested" => {
                let Ok(req) = serde_json::from_value::<CompanionRef>(env.data.clone()) else {
                    return;
                };
                self.base_mut().emit_signal(
                    "companion_focus_requested",
                    &[req.companion_id.to_variant()],
                );
                self.emit_outcome(
                    "ocp.runtime.companion-focused",
                    serde_json::json!({ "companionId": req.companion_id }),
                    env,
                );
            }
            "ocp.behavior.companion-follow-requested" => {
                let Ok(req) = serde_json::from_value::<CompanionFollowRequested>(env.data.clone())
                else {
                    return;
                };
                let distance_px = req.distance_px.map_or(64, |d| d as i64);
                self.base_mut().emit_signal(
                    "companion_follow_requested",
                    &[
                        req.companion_id.to_variant(),
                        req.leader_companion_id.to_variant(),
                        req.active.to_variant(),
                        distance_px.to_variant(),
                    ],
                );
                if req.active {
                    self.emit_outcome(
                        "ocp.runtime.companion-follow-started",
                        serde_json::json!({
                            "companionId": req.companion_id,
                            "leaderCompanionId": req.leader_companion_id,
                        }),
                        env,
                    );
                } else {
                    self.emit_outcome(
                        "ocp.runtime.companion-follow-stopped",
                        serde_json::json!({ "companionId": req.companion_id }),
                        env,
                    );
                }
            }
            "ocp.behavior.look-at-cursor-requested" => {
                let Ok(req) = serde_json::from_value::<LookAtCursorRequested>(env.data.clone())
                else {
                    return;
                };
                let duration_ms = req.duration_ms.map_or(800, |d| d as i64);
                self.base_mut().emit_signal(
                    "look_at_cursor_requested",
                    &[req.companion_id.to_variant(), duration_ms.to_variant()],
                );
                self.emit_outcome(
                    "ocp.runtime.look-at-cursor-completed",
                    serde_json::json!({ "companionId": req.companion_id }),
                    env,
                );
            }

            _ => {} // not part of the minimal set: ignored, never errors
        }
    }
}

/// Read side: connect, stream envelopes to the main thread, retry with
/// backoff on disconnect (RUNTIME_API §4.4). Malformed/invalid envelopes are
/// dropped and the loop continues (SEC-041) — only an I/O failure ends the
/// session.
fn read_loop(socket_name: String, token: String, in_tx: Sender<Inbound>, stop: Arc<AtomicBool>) {
    while !stop.load(Ordering::Acquire) {
        match connect_authenticated_with_intent(&socket_name, &token, INTENT_SUBSCRIBE) {
            Ok(mut conn) => {
                // Never let this worker remain blocked forever during Godot
                // teardown. A short timeout gives exit_tree() a deterministic
                // point to observe the stop flag before the DLL unloads.
                let _ = set_receive_timeout(&conn, Some(Duration::from_millis(250)));
                if in_tx.send(Inbound::Reconnected).is_err() {
                    return;
                }
                loop {
                    if stop.load(Ordering::Acquire) {
                        return;
                    }
                    match recv_envelope(&mut conn) {
                        Ok(env) => {
                            if in_tx.send(Inbound::Envelope(env)).is_err() {
                                return; // main thread gone
                            }
                        }
                        Err(IpcError::Io(error))
                            if matches!(
                                error.kind(),
                                std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
                            ) =>
                        {
                            continue;
                        }
                        Err(IpcError::Io(_)) => break, // connection dead: reconnect unless stopping
                        Err(_) => continue,            // malformed: drop + continue (SEC-041)
                    }
                }
                if stop.load(Ordering::Acquire) {
                    return;
                }
                if in_tx.send(Inbound::Disconnected).is_err() {
                    return;
                }
            }
            Err(_) => { /* handshake/connect failed; fall through to backoff */ }
        }

        // Interruptible reconnect backoff so shutdown is bounded to roughly
        // one socket receive timeout rather than the old two-second sleep.
        let mut slept = Duration::ZERO;
        while slept < RECONNECT_BACKOFF && !stop.load(Ordering::Acquire) {
            let slice = Duration::from_millis(100);
            thread::sleep(slice);
            slept += slice;
        }
    }
}

/// Write side: one persistent authenticated publish connection. Keeping all
/// outbound facts on one stream preserves queue order at Kernel; opening one
/// connection per fact lets independently spawned server readers race.
fn write_loop(socket_name: String, token: String, out_rx: Receiver<Envelope>) {
    let mut connection = None;
    while let Ok(env) = out_rx.recv() {
        if connection.is_none() {
            connection =
                connect_authenticated_with_intent(&socket_name, &token, INTENT_PUBLISH).ok();
        }

        let send_failed = connection
            .as_mut()
            .is_none_or(|conn| send_envelope(conn, &env).is_err());
        if send_failed {
            connection = None;
        }
        // A send failure here is silently dropped for now — outcome facts
        // The current fact is not retried; the next fact reconnects.
    }
}

#[cfg(test)]
mod outbound_transport_tests {
    use super::*;
    use ocp_ipc::transport::Listener;
    use serde_json::json;

    fn unique_socket_name() -> String {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock")
            .as_nanos();
        format!("ocp-runtime-outbound-order-{nanos}")
    }

    fn ordered_envelope(sequence: u64) -> Envelope {
        Envelope::new(
            "ocp.runtime.companion-position-requested",
            "runtime-test",
            json!({
                "companionId": "default",
                "sequence": sequence,
                "position": {
                    "space": "desktop-logical",
                    "anchor": "character-feet",
                    "x": sequence as f64,
                    "y": 100.0,
                },
                "mode": "authoritative-snap",
            }),
        )
        .expect("valid ordered envelope")
    }

    #[test]
    fn outbound_facts_share_one_connection_and_arrive_in_queue_order() {
        let socket_name = unique_socket_name();
        let token = "runtime-outbound-order-token";
        let listener = Listener::bind(&socket_name).expect("bind test socket");
        let server = thread::spawn(move || {
            let (mut conn, hello) = listener
                .accept_authenticated_hello(token)
                .expect("accept publish connection");
            assert_eq!(hello.intent.as_deref(), Some(INTENT_PUBLISH));
            (0..3)
                .map(|_| recv_envelope(&mut conn).expect("receive ordered fact"))
                .map(|env| env.data["sequence"].as_u64().expect("sequence"))
                .collect::<Vec<_>>()
        });

        let (out_tx, out_rx) = channel();
        let writer_socket = socket_name.clone();
        let writer = thread::spawn(move || {
            write_loop(writer_socket, token.to_owned(), out_rx);
        });
        for sequence in 1..=3 {
            out_tx
                .send(ordered_envelope(sequence))
                .expect("queue outbound fact");
        }
        drop(out_tx);

        writer.join().expect("writer shutdown");
        assert_eq!(server.join().expect("server shutdown"), vec![1, 2, 3]);
    }
}

#[cfg(test)]
mod installer_tests {
    use super::*;

    fn local_bible_fixture() -> Option<Vec<u8>> {
        let path =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../poc-assets/bible/bible.ocp");
        std::fs::read(path).ok()
    }

    #[test]
    fn drag_commit_envelope_matches_kernel_contract() {
        let env = companion_position_request_envelope("default", 849.6, 492.8)
            .expect("valid drag commit envelope");
        assert_eq!(env.event_type, "ocp.runtime.companion-position-requested");
        assert_eq!(env.data["companionId"], "default");
        assert_eq!(env.data["position"]["space"], "desktop-logical");
        assert_eq!(env.data["position"]["anchor"], "character-feet");
        assert_eq!(env.data["mode"], "authoritative-snap");
    }

    #[test]
    fn drag_commit_envelope_rejects_invalid_values() {
        assert!(companion_position_request_envelope("", 1.0, 2.0).is_none());
        assert!(companion_position_request_envelope("default", f64::NAN, 2.0,).is_none());
    }

    #[test]
    fn autonomous_movement_envelope_is_allowlisted() {
        let env = companion_movement_request_envelope("default", "walk-left")
            .expect("valid autonomous walk request");
        assert_eq!(env.event_type, "ocp.runtime.companion-movement-requested");
        assert_eq!(env.data["schemaVersion"], 1);
        assert_eq!(env.data["action"], "walk-left");
        assert_eq!(env.data["edgeBehavior"], "stop-at-edge");
        assert_eq!(env.data["source"], "offline-presence");
        assert!(companion_movement_request_envelope("", "walk-left").is_none());
        assert!(companion_movement_request_envelope("default", "climb-up").is_some());
        assert!(companion_movement_request_envelope("default", "hang-right").is_some());
        assert!(companion_movement_request_envelope("default", "hang-to-center").is_some());
        assert!(companion_movement_request_envelope("default", "hang-to-far-edge").is_some());
        assert!(
            companion_movement_request_envelope("default", "hang-to-climb-down-edge").is_some()
        );
        assert!(companion_movement_request_envelope("default", "climb-down").is_some());
        assert!(companion_movement_request_envelope("default", "detach").is_some());
        assert!(
            companion_movement_request_envelope("default", "teleport-current-monitor").is_some()
        );
        assert!(companion_movement_request_envelope("default", "transfer-ledge").is_none());
    }

    #[test]
    fn companion_movement_contract_accepts_valid_payload() {
        let parsed = parse_companion_moved(&serde_json::json!({
            "companionId": "default",
            "position": {
                "space": "desktop-logical",
                "anchor": "character-feet",
                "x": -120.0,
                "y": 720.0
            },
            "velocity": { "x": -80.0, "y": 0.0 },
            "grounded": true,
            "movementState": "walking",
            "motion": "continuous",
            "sequence": 42
        }))
        .expect("valid movement");

        assert_eq!(parsed.companion_id, "default");
        assert_eq!(parsed.sequence, 42);
        assert_eq!(parsed.x, -120.0);
    }

    #[test]
    fn companion_movement_contract_rejects_invalid_boundary_values() {
        let wrong_space = serde_json::json!({
            "companionId": "default",
            "position": {
                "space": "node-local",
                "anchor": "character-feet",
                "x": 0.0,
                "y": 0.0
            },
            "velocity": { "x": 0.0, "y": 0.0 },
            "grounded": true,
            "movementState": "stationary",
            "motion": "continuous",
            "sequence": 1
        });
        assert!(parse_companion_moved(&wrong_space).is_none());
    }

    #[test]
    fn canonical_presentation_contract_requires_body_identity() {
        let payload = serde_json::json!({
            "schemaVersion": 1,
            "companionId": "default",
            "desktopFeet": {
                "space": "desktop-logical",
                "anchor": "character-feet",
                "x": 320.0,
                "y": 640.0
            },
            "velocity": { "x": 0.0, "y": 0.0 },
            "grounded": true,
            "movementState": "stationary",
            "attachmentState": "grounded",
            "surfaceKind": "desktop_floor",
            "facing": "unchanged",
            "updateKind": "continuous",
            "sequence": 1,
            "revision": 1
        });
        assert!(parse_companion_presentation_state(&payload).is_none());
    }

    #[test]
    fn canonical_presentation_contract_accepts_revisioned_payload() {
        let parsed = parse_companion_presentation_state(&serde_json::json!({
            "schemaVersion": 1,
            "companionId": "default",
            "bodyId": 1,
            "desktopFeet": {
                "space": "desktop-logical",
                "anchor": "character-feet",
                "x": 320.0,
                "y": 640.0
            },
            "velocity": { "x": 0.0, "y": 0.0 },
            "grounded": true,
            "movementState": "stationary",
            "attachmentState": "grounded",
            "surfaceKind": "window_top",
            "facing": "unchanged",
            "updateKind": "drag-commit",
            "sequence": 8,
            "revision": 3
        }))
        .expect("valid presentation state");

        assert_eq!(parsed.companion_id, "default");
        assert_eq!(parsed.body_id, 1);
        assert_eq!(parsed.sequence, 8);
        assert_eq!(parsed.revision, 3);
        assert_eq!(parsed.update_kind, "drag-commit");
        assert_eq!(parsed.surface_kind.as_deref(), Some("window_top"));
    }

    #[test]
    fn canonical_presentation_contract_accepts_stationary_landing_correction() {
        let parsed = parse_companion_presentation_state(&serde_json::json!({
            "schemaVersion": 1,
            "companionId": "default",
            "bodyId": 1,
            "desktopFeet": {
                "space": "desktop-logical",
                "anchor": "character-feet",
                "x": 320.0,
                "y": 640.0
            },
            "velocity": { "x": 0.0, "y": 0.0 },
            "grounded": true,
            "movementState": "stationary",
            "attachmentState": "grounded",
            "surfaceKind": "desktop_floor",
            "facing": "unchanged",
            "updateKind": "correction",
            "sequence": 9,
            "revision": 4
        }))
        .expect("valid autonomous landing correction");

        assert_eq!(parsed.movement_state, "stationary");
        assert_eq!(parsed.update_kind, "correction");
        assert_eq!(parsed.surface_kind.as_deref(), Some("desktop_floor"));
    }

    #[test]
    fn progression_queue_is_idempotent_and_acknowledges_only_confirmed_ids() {
        let temp = tempfile::tempdir().expect("temporary directory");
        let database = temp.path().join("ocp-local.db");
        let first_id = uuid::Uuid::now_v7();
        let second_id = uuid::Uuid::now_v7();
        let first = serde_json::json!({
            "id": first_id,
            "type": "ocp.companion.created",
            "version": "1.0",
            "source": "runtime",
            "time": "2026-08-26T10:00:00Z",
            "correlationId": uuid::Uuid::now_v7(),
            "contentType": "application/json",
            "data": {"companionId": "default", "characterId": "character.sabai"}
        })
        .to_string();
        let second = serde_json::json!({
            "id": second_id,
            "type": "ocp.runtime.ai-response",
            "version": "1.0",
            "source": "runtime",
            "time": "2026-08-26T10:01:00Z",
            "correlationId": uuid::Uuid::now_v7(),
            "contentType": "application/json",
            "data": {"messageId": "m1"}
        })
        .to_string();

        assert!(progression_queue_enqueue_db(&database, &first).expect("first enqueue"));
        assert!(!progression_queue_enqueue_db(&database, &first).expect("duplicate enqueue"));
        assert!(progression_queue_enqueue_db(&database, &second).expect("second enqueue"));
        let pending = progression_queue_list_db(&database, 100).expect("list pending");
        assert_eq!(pending.len(), 2);
        let removed = progression_queue_ack_db(
            &database,
            &serde_json::json!([first_id.to_string()]).to_string(),
        )
        .expect("ack first");
        assert_eq!(removed, 1);
        let remaining = progression_queue_list_db(&database, 100).expect("list remaining");
        assert_eq!(remaining, vec![second]);
    }

    #[test]
    fn progression_queue_rejects_non_uuid_event_ids_and_invalid_ack_batches() {
        let temp = tempfile::tempdir().expect("temporary directory");
        let database = temp.path().join("ocp-local.db");
        assert!(progression_queue_enqueue_db(&database, r#"{"id":"forged"}"#).is_err());
        assert!(progression_queue_ack_db(&database, "[]").is_err());
        assert!(progression_queue_ack_db(&database, r#"["forged"]"#).is_err());
    }

    #[test]
    fn progression_projection_cache_is_account_scoped_and_replaces_revision() {
        let temp = tempfile::tempdir().expect("temporary directory");
        let database = temp.path().join("ocp-local.db");
        let first_user = uuid::Uuid::now_v7();
        let second_user = uuid::Uuid::now_v7();
        let first = serde_json::json!({"revision": 1, "companions": []}).to_string();
        let updated = serde_json::json!({"revision": 2, "companions": []}).to_string();
        let second = serde_json::json!({"revision": 7, "companions": []}).to_string();

        progression_projection_store_db(&database, &first_user.to_string(), &first)
            .expect("first projection store");
        progression_projection_store_db(&database, &first_user.to_string(), &updated)
            .expect("projection replacement");
        progression_projection_store_db(&database, &second_user.to_string(), &second)
            .expect("second account projection store");

        assert_eq!(
            progression_projection_load_db(&database, &first_user.to_string())
                .expect("first projection load"),
            Some(updated)
        );
        assert_eq!(
            progression_projection_load_db(&database, &second_user.to_string())
                .expect("second projection load"),
            Some(second)
        );
        assert!(
            progression_projection_load_db(&database, &uuid::Uuid::now_v7().to_string())
                .expect("missing projection load")
                .is_none()
        );
    }

    #[test]
    fn progression_projection_cache_rejects_invalid_identity_and_shape() {
        let temp = tempfile::tempdir().expect("temporary directory");
        let database = temp.path().join("ocp-local.db");
        let user = uuid::Uuid::now_v7();
        assert!(progression_projection_store_db(
            &database,
            "not-a-user",
            r#"{"revision":1,"companions":[]}"#,
        )
        .is_err());
        assert!(progression_projection_store_db(
            &database,
            &user.to_string(),
            r#"{"revision":-1,"companions":[]}"#,
        )
        .is_err());
        assert!(progression_projection_store_db(
            &database,
            &user.to_string(),
            r#"{"revision":1,"companions":{}}"#,
        )
        .is_err());
    }

    #[test]
    fn cloud_install_requires_matching_object_hash_and_signature_metadata() {
        let Some(bytes) = local_bible_fixture() else {
            eprintln!(
                "skipping local Bible fixture test: poc-assets are intentionally not tracked"
            );
            return;
        };
        let temp = tempfile::tempdir().expect("temporary directory");
        let source = temp.path().join("bible-cloud.ocp");
        let destination = temp.path().join("characters");
        fs::write(&source, &bytes).expect("cloud package fixture writes");
        let actual_sha = format!("{:x}", Sha256::digest(&bytes));

        assert!(install_verified_character_archive_with_expectations(
            &source,
            &destination,
            poc_character_trust_store().expect("poc trust"),
            Some(&"0".repeat(64)),
            Some(POC_BIBLE_KEY_ID),
            None,
        )
        .is_err());
        assert!(install_verified_character_archive_with_expectations(
            &source,
            &destination,
            poc_character_trust_store().expect("poc trust"),
            Some(&actual_sha),
            Some("ed25519:forged"),
            None,
        )
        .is_err());
        assert!(install_verified_character_archive_with_expectations(
            &source,
            &destination,
            poc_character_trust_store().expect("poc trust"),
            Some(&actual_sha),
            Some(POC_BIBLE_KEY_ID),
            Some("base64:forged"),
        )
        .is_err());
        assert!(
            !destination.exists(),
            "failed cloud trust checks must not extract files"
        );
    }

    #[test]
    fn tampered_bible_package_is_rejected_before_projection() {
        let Some(mut bytes) = local_bible_fixture() else {
            eprintln!(
                "skipping local Bible fixture test: poc-assets are intentionally not tracked"
            );
            return;
        };
        let temp = tempfile::tempdir().expect("temporary directory");
        let source = temp.path().join("bible-tampered.ocp");
        let destination = temp.path().join("characters");
        let last = bytes.len().checked_sub(1).expect("non-empty package");
        bytes[last] ^= 0x01;
        fs::write(&source, bytes).expect("tampered fixture writes");

        assert!(install_verified_character_archive(&source, &destination).is_err());
        assert!(
            !destination.exists(),
            "rejected bytes must not be extracted"
        );
    }
}
