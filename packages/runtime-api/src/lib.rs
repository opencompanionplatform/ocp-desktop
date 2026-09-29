//! OCP Runtime contract types + conformance kit — RUNTIME_API.
//!
//! A runtime consumes *request facts* from the Behavior/Companion contexts and
//! emits *outcome facts* (RUNTIME_API §1). This crate provides:
//! - typed `data` payloads for the minimal conformance set (NFR-001 §6);
//! - typed payloads for §8 multi-companion addressing + lifecycle (ADR-0013);
//! - the [`Runtime`] trait a runtime implements;
//! - [`sanitize_display_text`] enforcing the rendering rule (§5): displayed
//!   strings are data — never markup or code (THREAT_MODEL X4-I);
//! - [`certify`], the CS-RT harness: passing it + CS-EVT certifies any runtime
//!   for the swap test (RUNTIME_API §6). The Godot runtime and the reference
//!   stub must both pass identically.
//! - [`certify_multi_companion`], the §8 extension harness (I6.5). Kept
//!   separate from [`certify`] deliberately: §6's *minimal* set is unchanged by
//!   the §8 addendum, and folding §8 into `certify` would instantly fail the
//!   already-proven Godot runtime before its I6.5 slice lands. When the Godot
//!   side implements §8, it must pass BOTH harnesses — that is the multi-
//!   companion swap test. (Interpretive reading, flagged for review: RUNTIME_API
//!   §6 does not say whether §8 joins the minimal set; this crate says "not
//!   yet" to keep NFR-001 continuously true for the single-companion contract.)

#![forbid(unsafe_code)] // SEC-042

use ocp_shared_types::Envelope;
use serde::{Deserialize, Serialize};

/// Max characters rendered in a bubble/subtitle before truncation (§5 length
/// limit). Conservative default; the real runtime may lower it per theme.
pub const MAX_DISPLAY_CHARS: usize = 500;

/// Companion id used by single-companion deployments (§8.1: "a single-companion
/// deployment simply always sends the same companionId"). Same literal as
/// `ocp-memory`'s `DEFAULT_COMPANION_ID` — kept in sync by convention, not by a
/// dependency (neither crate should depend on the other for one constant);
/// flagged in both crates' docs.
pub const DEFAULT_COMPANION_ID: &str = "default";

fn default_companion_id() -> String {
    DEFAULT_COMPANION_ID.to_owned()
}

// --- Payloads the minimal runtime consumes (RUNTIME_API §2–§3) ---------------
//
// §8.1 makes `companionId` required on every §2 payload going forward, while
// also promising backward compatibility for single-companion senders. This
// crate reconciles the two by defaulting a missing `companionId` to
// [`DEFAULT_COMPANION_ID`] on deserialization — an interpretive reading
// (flagged, same practice as every prior engine's interpretive additions):
// the runtime tolerates legacy payloads, but always *emits* the field.

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BubbleRequested {
    pub bubble_id: uuid::Uuid,
    #[serde(default = "default_companion_id")]
    pub companion_id: String,
    pub text: String,
    pub tone: String,
    #[serde(default)]
    pub duration_ms: Option<u64>,
}

/// The `audioRef` shared type (EVENT_CATALOG.md, I7 gap 1): a reference to a
/// synthesized speech clip the runtime resolves and plays. For V1 the clip is
/// a file-backed WAV — the runtime reads `<audio-dir>/<id>.wav` (kernel and
/// runtime are co-located; the audio store writes there). `format`/`sha256`
/// are carried for completeness; V1 playback uses `id` (path) + `duration_ms`.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioRefPayload {
    pub id: uuid::Uuid,
    #[serde(default)]
    pub format: String,
    #[serde(default)]
    pub duration_ms: u32,
    #[serde(default)]
    pub sha256: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpeechRequested {
    pub speech_id: uuid::Uuid,
    #[serde(default = "default_companion_id")]
    pub companion_id: String,
    pub text: String,
    #[serde(default)]
    pub subtitle: bool,
    /// Present when the AI Router synthesized audio (I7 gap 1). Absent → the
    /// runtime speaks `text` itself or shows the subtitle only
    /// (`tts-unavailable`), never silence.
    #[serde(default)]
    pub audio_ref: Option<AudioRefPayload>,
    /// Safe bounded route diagnostic; never contains provider bodies, paths,
    /// installed voice names, credentials or user text.
    #[serde(default)]
    pub route_reason: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EmotionChanged {
    #[serde(default = "default_companion_id")]
    pub companion_id: String,
    pub to: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AnimationRequested {
    pub animation_id: String,
    #[serde(default = "default_companion_id")]
    pub companion_id: String,
    #[serde(rename = "loop", default)]
    pub looped: bool,
    /// `idle | reactive | interrupt` (RUNTIME_API §2.2).
    pub priority: String,
    #[serde(default)]
    pub blend_ms: u64,
}

/// Window policy (RUNTIME_API §3, shared type `windowPolicy`; §8.4 adds the two
/// optional window-level UI-surface fields — window-level, not per-companion).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowPolicy {
    pub transparent: bool,
    pub always_on_top: bool,
    pub click_through: String,
    #[serde(default)]
    pub preferred_monitor_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dock_visible: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub toolbar_visible: Option<bool>,
}

// --- §8.2 companion lifecycle payloads (ADR-0013) ----------------------------

/// A screen position (§8.2). Pixel coordinates; `monitorId` names the target
/// monitor where known.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Position {
    pub x: i64,
    pub y: i64,
    #[serde(default)]
    pub monitor_id: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompanionSpawnRequested {
    pub companion_id: String,
    pub character_package_id: String,
    #[serde(default)]
    pub initial_position: Option<Position>,
}

/// Shared payload for the `{ "companionId": "..." }`-only lifecycle requests:
/// despawn, show, hide, focus (§8.2).
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompanionRef {
    pub companion_id: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompanionSleepRequested {
    pub companion_id: String,
    /// `true` = sleep (unload resources), `false` = wake (§8.2 — distinct from
    /// despawn: a sleeping companion still exists).
    pub active: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompanionFollowRequested {
    pub companion_id: String,
    /// The companion being followed — a *companion*, not the cursor (§8.2:
    /// never conflate with §2.4's `cursor-follow-requested`).
    pub leader_companion_id: String,
    pub active: bool,
    #[serde(default)]
    pub distance_px: Option<u64>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LookAtCursorRequested {
    pub companion_id: String,
    #[serde(default)]
    pub duration_ms: Option<u64>,
}

// --- The rendering rule (§5) --------------------------------------------------

/// Turn an untrusted string into safe display data (§5, THREAT_MODEL X4-I):
/// control characters are stripped, length is capped. No markup/BBCode/HTML is
/// ever interpreted — the text is returned as literal data. Returns the
/// sanitized text and whether it was truncated.
#[must_use]
pub fn sanitize_display_text(input: &str) -> (String, bool) {
    // Strip control chars (keep normal whitespace: space, but drop \n\r\t and
    // other control codes that could confuse a renderer).
    let cleaned: String = input
        .chars()
        .filter(|c| !c.is_control() || *c == ' ')
        .collect();
    let mut out: String = cleaned.chars().take(MAX_DISPLAY_CHARS).collect();
    let truncated = cleaned.chars().count() > MAX_DISPLAY_CHARS;
    if truncated {
        // Keep exactly the cap; no ellipsis markup added.
        out = cleaned.chars().take(MAX_DISPLAY_CHARS).collect();
    }
    (out, truncated)
}

// --- The runtime contract -----------------------------------------------------

/// A runtime presentation surface. Given one inbound envelope it returns the
/// outcome fact(s) it emits (RUNTIME_API §1). Events it does not handle return
/// an empty vec (e.g. a minimal runtime mirroring `state-changed`). Outcome
/// envelopes must carry the causing event's `id` as `correlationId` (NFR-004).
pub trait Runtime {
    /// Handle one inbound event, returning emitted outcome facts.
    fn handle(&mut self, event: &Envelope) -> Vec<Envelope>;

    /// Last text the runtime rendered (bubble/subtitle), for §5 certification.
    /// `None` if nothing has been displayed yet.
    fn last_rendered_text(&self) -> Option<&str>;
}

// --- CS-RT conformance harness (RUNTIME_API §6) ------------------------------

/// A single expectation: an inbound event and the outcome event types the
/// runtime must emit in response (order-independent).
struct Step {
    input: Envelope,
    expected: &'static [&'static str],
}

fn ev(event_type: &str, source: &str, data: serde_json::Value) -> Envelope {
    Envelope::new(event_type, source, data).expect("valid conformance envelope")
}

/// Shared per-step outcome checks: envelope validity (CS-EVT), correlation
/// (NFR-004), host-verified source, and — when the input addressed a specific
/// companion — §8.1 companionId propagation on every outcome that carries one.
fn check_step<R: Runtime>(runtime: &mut R, step: &Step) -> Result<(), String> {
    let out = runtime.handle(&step.input);

    let requested_companion = step
        .input
        .data
        .get("companionId")
        .and_then(|v| v.as_str())
        .map(str::to_owned);

    for e in &out {
        e.validate().map_err(|err| {
            format!(
                "emitted invalid envelope for {}: {err}",
                step.input.event_type
            )
        })?;
        if e.correlation_id != Some(step.input.id) {
            return Err(format!(
                "outcome {} missing correlationId of its cause {} (NFR-004)",
                e.event_type, step.input.event_type
            ));
        }
        if e.source != "runtime" {
            return Err(format!(
                "outcome {} has source {}, expected `runtime`",
                e.event_type, e.source
            ));
        }
        if let (Some(want), Some(got)) = (
            requested_companion.as_deref(),
            e.data.get("companionId").and_then(|v| v.as_str()),
        ) {
            if want != got {
                return Err(format!(
                    "outcome {} carries companionId {got}, expected {want} (§8.1 addressing)",
                    e.event_type
                ));
            }
        }
    }

    let got: Vec<&str> = out.iter().map(|e| e.event_type.as_str()).collect();
    for want in step.expected {
        if !got.contains(want) {
            return Err(format!(
                "input {} expected to emit {want}, got {got:?}",
                step.input.event_type
            ));
        }
    }
    Ok(())
}

/// Run the minimal-conformance script against a runtime. `Ok(())` means it
/// passes CS-RT's verb round-trip + rendering rule; combined with CS-EVT this
/// certifies the runtime for the NFR-001 swap test.
pub fn certify<R: Runtime>(runtime: &mut R) -> Result<(), String> {
    let bubble_id = uuid::Uuid::now_v7();
    let speech_id = uuid::Uuid::now_v7();

    let script = [
        Step {
            input: ev(
                "ocp.behavior.bubble-requested",
                "behavior",
                serde_json::json!({
                    "bubbleId": bubble_id, "text": "hello", "tone": "happy", "anchor": "companion"
                }),
            ),
            expected: &["ocp.runtime.bubble-shown"],
        },
        Step {
            input: ev(
                "ocp.behavior.speech-requested",
                "behavior",
                serde_json::json!({ "speechId": speech_id, "text": "hi there", "subtitle": true }),
            ),
            expected: &["ocp.runtime.speech-started", "ocp.runtime.speech-completed"],
        },
        Step {
            input: ev(
                "ocp.behavior.emotion-changed",
                "behavior",
                serde_json::json!({ "companionId": DEFAULT_COMPANION_ID, "from": "neutral", "to": "happy" }),
            ),
            expected: &["ocp.runtime.emotion-presented"],
        },
        Step {
            input: ev(
                "ocp.companion.window-policy-changed",
                "companion",
                serde_json::json!({
                    "transparent": true, "alwaysOnTop": true, "clickThrough": "outside-sprite"
                }),
            ),
            expected: &["ocp.runtime.window-state-changed"],
        },
        Step {
            input: ev(
                "ocp.companion.state-changed",
                "companion",
                serde_json::json!({
                    "companionId": DEFAULT_COMPANION_ID, "from": "Idle", "to": "Speaking"
                }),
            ),
            expected: &[], // mirrored; no outbound fact required, must not error
        },
    ];

    for step in &script {
        check_step(runtime, step)?;
    }

    Ok(())
}

/// Run the §8 multi-companion addressing + lifecycle script (I6.5, ADR-0013).
/// Spawns two companions, drives every §8.2 lifecycle verb, and checks §8.1
/// companionId propagation on addressed §2 verbs. A multi-companion-capable
/// runtime must pass BOTH this and [`certify`].
pub fn certify_multi_companion<R: Runtime>(runtime: &mut R) -> Result<(), String> {
    let a = "companion-a";
    let b = "companion-b";

    let script = [
        Step {
            input: ev(
                "ocp.behavior.companion-spawn-requested",
                "behavior",
                serde_json::json!({
                    "companionId": a, "characterPackageId": "character.test",
                    "initialPosition": { "x": 10, "y": 20, "monitorId": "m1" }
                }),
            ),
            expected: &["ocp.runtime.companion-spawned"],
        },
        Step {
            input: ev(
                "ocp.behavior.companion-spawn-requested",
                "behavior",
                serde_json::json!({ "companionId": b, "characterPackageId": "character.test", "initialPosition": null }),
            ),
            expected: &["ocp.runtime.companion-spawned"],
        },
        // §8.1: an addressed §2 verb's outcome carries the same companionId
        // (check_step enforces the id match on every outcome that has one).
        Step {
            input: ev(
                "ocp.behavior.bubble-requested",
                "behavior",
                serde_json::json!({
                    "bubbleId": uuid::Uuid::now_v7(), "companionId": a,
                    "text": "hello from a", "tone": "happy", "anchor": "companion"
                }),
            ),
            expected: &["ocp.runtime.bubble-shown"],
        },
        Step {
            input: ev(
                "ocp.behavior.companion-sleep-requested",
                "behavior",
                serde_json::json!({ "companionId": a, "active": true }),
            ),
            expected: &["ocp.runtime.companion-slept"],
        },
        Step {
            input: ev(
                "ocp.behavior.companion-sleep-requested",
                "behavior",
                serde_json::json!({ "companionId": a, "active": false }),
            ),
            expected: &["ocp.runtime.companion-woken"],
        },
        Step {
            input: ev(
                "ocp.behavior.companion-hide-requested",
                "behavior",
                serde_json::json!({ "companionId": a }),
            ),
            expected: &["ocp.runtime.companion-hidden"],
        },
        Step {
            input: ev(
                "ocp.behavior.companion-show-requested",
                "behavior",
                serde_json::json!({ "companionId": a }),
            ),
            expected: &["ocp.runtime.companion-shown"],
        },
        Step {
            input: ev(
                "ocp.behavior.companion-focus-requested",
                "behavior",
                serde_json::json!({ "companionId": b }),
            ),
            expected: &["ocp.runtime.companion-focused"],
        },
        Step {
            input: ev(
                "ocp.behavior.companion-follow-requested",
                "behavior",
                serde_json::json!({
                    "companionId": b, "leaderCompanionId": a, "active": true, "distancePx": 64
                }),
            ),
            expected: &["ocp.runtime.companion-follow-started"],
        },
        Step {
            input: ev(
                "ocp.behavior.companion-follow-requested",
                "behavior",
                serde_json::json!({ "companionId": b, "leaderCompanionId": a, "active": false }),
            ),
            expected: &["ocp.runtime.companion-follow-stopped"],
        },
        Step {
            input: ev(
                "ocp.behavior.look-at-cursor-requested",
                "behavior",
                serde_json::json!({ "companionId": a, "durationMs": 800 }),
            ),
            expected: &["ocp.runtime.look-at-cursor-completed"],
        },
        Step {
            input: ev(
                "ocp.behavior.companion-despawn-requested",
                "behavior",
                serde_json::json!({ "companionId": a }),
            ),
            expected: &["ocp.runtime.companion-despawned"],
        },
        Step {
            input: ev(
                "ocp.behavior.companion-despawn-requested",
                "behavior",
                serde_json::json!({ "companionId": b }),
            ),
            expected: &["ocp.runtime.companion-despawned"],
        },
    ];

    for step in &script {
        check_step(runtime, step)?;
    }

    Ok(())
}
