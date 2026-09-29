//! Headless reference runtime (RUNTIME_API §6 minimal set + §8 multi-companion).
//!
//! No window, no graphics — it "renders" by recording sanitized data. Its whole
//! purpose is the NFR-001 swap test: if CS-RT passes against both this stub and
//! the Godot runtime, the presentation contract is proven runtime-neutral.
//! Since I6.5 it also implements §8 (ADR-0013): companion lifecycle + addressed
//! §2 verbs, certified by `certify_multi_companion`.
//!
//! It holds no intelligence and mirrors companion state (RUNTIME.md): it turns
//! request facts into outcome facts and never decides behavior. All displayed
//! strings pass through [`sanitize_display_text`] (§5, THREAT_MODEL X4-I).
//!
//! Interpretive reading, flagged (same practice as prior engines): §2 verbs
//! addressed at a companion that was never spawned still render — §2 predates
//! spawn (single-companion mode has no spawn step), so requiring spawn-first
//! would break the §6 minimal set. The Companion Manager (kernel side) is the
//! layer that decides whether addressing an unknown companion is an error; the
//! runtime stays a truthful presentation surface either way.

#![forbid(unsafe_code)] // SEC-042

use std::collections::HashMap;

use ocp_runtime_api::{
    sanitize_display_text, BubbleRequested, CompanionFollowRequested, CompanionRef,
    CompanionSleepRequested, CompanionSpawnRequested, EmotionChanged, LookAtCursorRequested,
    Position, Runtime, SpeechRequested, WindowPolicy,
};
use ocp_shared_types::Envelope;
use serde_json::json;
use uuid::Uuid;

/// What this stub's "compositor" can honour. A real runtime discovers these
/// from the OS; the stub lets tests force degradation paths (RUNTIME_API §3.1).
#[derive(Debug, Clone, Copy)]
pub struct WindowCaps {
    pub transparent: bool,
    pub always_on_top: bool,
}

impl Default for WindowCaps {
    fn default() -> Self {
        Self {
            transparent: true,
            always_on_top: true,
        }
    }
}

/// Per-companion presentation state (§8). The stub tracks just enough to make
/// lifecycle outcomes truthful facts rather than blind echoes.
#[derive(Debug, Clone)]
pub struct CompanionVisual {
    pub character_package_id: String,
    pub position: Position,
    pub sleeping: bool,
    pub hidden: bool,
    pub focused: bool,
    /// `Some(leaderId)` while following another companion (§8.2 — a companion,
    /// never the cursor; cursor-following is §2.4's separate family).
    pub following: Option<String>,
}

#[derive(Default)]
pub struct StubRuntime {
    caps: WindowCaps,
    last_rendered: Option<String>,
    /// Mirrored companion state (RUNTIME.md: mirror, never own).
    pub mirrored_state: Option<String>,
    pub connected: bool,
    /// Spawned companions by id (§8).
    pub companions: HashMap<String, CompanionVisual>,
}

impl StubRuntime {
    #[must_use]
    pub fn new() -> Self {
        Self {
            caps: WindowCaps::default(),
            connected: true,
            ..Default::default()
        }
    }

    #[must_use]
    pub fn with_caps(caps: WindowCaps) -> Self {
        Self {
            caps,
            connected: true,
            ..Default::default()
        }
    }

    /// Runtime-originated input (RUNTIME_API §2.7). The runtime reports the
    /// fact; core decides meaning. Text is sanitized like any display string.
    /// `target` accepts §8.1's `companion:<companionId>` form as well as the
    /// original `companion | bubble:<bubbleId> | tray` values.
    pub fn capture_input(&self, modality: &str, text: Option<&str>, target: &str) -> Envelope {
        let clean = text.map(|t| sanitize_display_text(t).0);
        Envelope::new(
            "ocp.runtime.input-captured",
            "runtime",
            json!({
                "inputId": Uuid::now_v7(),
                "modality": modality,
                "text": clean,
                "target": target,
            }),
        )
        .expect("valid input-captured")
    }

    fn emit(&self, cause: &Envelope, event_type: &str, data: serde_json::Value) -> Envelope {
        Envelope::new(event_type, "runtime", data)
            .expect("valid runtime outcome")
            .with_correlation(cause.id)
    }
}

impl Runtime for StubRuntime {
    #[allow(clippy::too_many_lines)] // one flat dispatch table per contract §2/§3/§8
    fn handle(&mut self, event: &Envelope) -> Vec<Envelope> {
        match event.event_type.as_str() {
            "ocp.behavior.bubble-requested" => {
                let Ok(req) = serde_json::from_value::<BubbleRequested>(event.data.clone()) else {
                    return vec![]; // malformed payload: drop (SEC-041 handled upstream)
                };
                let (text, truncated) = sanitize_display_text(&req.text);
                self.last_rendered = Some(text);
                vec![self.emit(
                    event,
                    "ocp.runtime.bubble-shown",
                    json!({
                        "bubbleId": req.bubble_id,
                        "companionId": req.companion_id,
                        "shownAt": chrono::Utc::now().to_rfc3339(),
                        "truncated": truncated,
                    }),
                )]
            }
            "ocp.behavior.speech-requested" => {
                let Ok(req) = serde_json::from_value::<SpeechRequested>(event.data.clone()) else {
                    return vec![];
                };
                if req.subtitle {
                    let (text, _) = sanitize_display_text(&req.text);
                    self.last_rendered = Some(text);
                }
                vec![
                    self.emit(
                        event,
                        "ocp.runtime.speech-started",
                        json!({ "speechId": req.speech_id, "companionId": req.companion_id }),
                    ),
                    self.emit(
                        event,
                        "ocp.runtime.speech-completed",
                        json!({
                            "speechId": req.speech_id,
                            "companionId": req.companion_id,
                            "outcome": "finished",
                        }),
                    ),
                ]
            }
            "ocp.behavior.emotion-changed" => {
                let Ok(req) = serde_json::from_value::<EmotionChanged>(event.data.clone()) else {
                    return vec![];
                };
                // The stub has no expression assets: everything is a fallback.
                vec![self.emit(
                    event,
                    "ocp.runtime.emotion-presented",
                    json!({
                        "companionId": req.companion_id,
                        "emotion": req.to,
                        "expressionSet": "stub",
                        "fallback": true,
                    }),
                )]
            }
            "ocp.companion.window-policy-changed" => {
                let Ok(policy) = serde_json::from_value::<WindowPolicy>(event.data.clone()) else {
                    return vec![];
                };
                let mut degraded = Vec::new();
                if policy.transparent && !self.caps.transparent {
                    degraded.push("transparent");
                }
                if policy.always_on_top && !self.caps.always_on_top {
                    degraded.push("alwaysOnTop");
                }
                vec![self.emit(
                    event,
                    "ocp.runtime.window-state-changed",
                    json!({ "applied": policy, "degraded": degraded }),
                )]
            }
            "ocp.companion.state-changed" => {
                // Mirror only (RUNTIME.md). No outbound fact required.
                if let Some(to) = event.data.get("to").and_then(|v| v.as_str()) {
                    self.mirrored_state = Some(to.to_owned());
                }
                vec![]
            }

            // --- §8.2 companion lifecycle (ADR-0013, I6.5) -------------------
            "ocp.behavior.companion-spawn-requested" => {
                let Ok(req) = serde_json::from_value::<CompanionSpawnRequested>(event.data.clone())
                else {
                    return vec![];
                };
                let position = req.initial_position.unwrap_or(Position {
                    x: 0,
                    y: 0,
                    monitor_id: None,
                });
                let outcome = json!({
                    "companionId": req.companion_id,
                    "position": &position, // borrow: `position` is stored below
                });
                self.companions.insert(
                    req.companion_id.clone(),
                    CompanionVisual {
                        character_package_id: req.character_package_id,
                        position,
                        sleeping: false,
                        hidden: false,
                        focused: false,
                        following: None,
                    },
                );
                vec![self.emit(event, "ocp.runtime.companion-spawned", outcome)]
            }
            "ocp.behavior.companion-despawn-requested" => {
                let Ok(req) = serde_json::from_value::<CompanionRef>(event.data.clone()) else {
                    return vec![];
                };
                self.companions.remove(&req.companion_id);
                vec![self.emit(
                    event,
                    "ocp.runtime.companion-despawned",
                    json!({ "companionId": req.companion_id }),
                )]
            }
            "ocp.behavior.companion-sleep-requested" => {
                let Ok(req) = serde_json::from_value::<CompanionSleepRequested>(event.data.clone())
                else {
                    return vec![];
                };
                if let Some(c) = self.companions.get_mut(&req.companion_id) {
                    c.sleeping = req.active;
                }
                let outcome_type = if req.active {
                    "ocp.runtime.companion-slept"
                } else {
                    "ocp.runtime.companion-woken"
                };
                vec![self.emit(
                    event,
                    outcome_type,
                    json!({ "companionId": req.companion_id }),
                )]
            }
            "ocp.behavior.companion-show-requested" => {
                let Ok(req) = serde_json::from_value::<CompanionRef>(event.data.clone()) else {
                    return vec![];
                };
                if let Some(c) = self.companions.get_mut(&req.companion_id) {
                    c.hidden = false;
                }
                vec![self.emit(
                    event,
                    "ocp.runtime.companion-shown",
                    json!({ "companionId": req.companion_id }),
                )]
            }
            "ocp.behavior.companion-hide-requested" => {
                let Ok(req) = serde_json::from_value::<CompanionRef>(event.data.clone()) else {
                    return vec![];
                };
                if let Some(c) = self.companions.get_mut(&req.companion_id) {
                    c.hidden = true;
                }
                vec![self.emit(
                    event,
                    "ocp.runtime.companion-hidden",
                    json!({ "companionId": req.companion_id }),
                )]
            }
            "ocp.behavior.companion-focus-requested" => {
                let Ok(req) = serde_json::from_value::<CompanionRef>(event.data.clone()) else {
                    return vec![];
                };
                for (id, c) in &mut self.companions {
                    c.focused = *id == req.companion_id;
                }
                vec![self.emit(
                    event,
                    "ocp.runtime.companion-focused",
                    json!({ "companionId": req.companion_id }),
                )]
            }
            "ocp.behavior.companion-follow-requested" => {
                let Ok(req) =
                    serde_json::from_value::<CompanionFollowRequested>(event.data.clone())
                else {
                    return vec![];
                };
                if let Some(c) = self.companions.get_mut(&req.companion_id) {
                    c.following = req.active.then(|| req.leader_companion_id.clone());
                }
                if req.active {
                    vec![self.emit(
                        event,
                        "ocp.runtime.companion-follow-started",
                        json!({
                            "companionId": req.companion_id,
                            "leaderCompanionId": req.leader_companion_id,
                        }),
                    )]
                } else {
                    vec![self.emit(
                        event,
                        "ocp.runtime.companion-follow-stopped",
                        json!({ "companionId": req.companion_id }),
                    )]
                }
            }
            "ocp.behavior.look-at-cursor-requested" => {
                let Ok(req) = serde_json::from_value::<LookAtCursorRequested>(event.data.clone())
                else {
                    return vec![];
                };
                // Headless: the glance "completes" immediately, same
                // immediate-fake-completion simplification as speech (I2 TODO).
                vec![self.emit(
                    event,
                    "ocp.runtime.look-at-cursor-completed",
                    json!({ "companionId": req.companion_id }),
                )]
            }

            _ => vec![], // not part of the implemented set: ignored, never errors
        }
    }

    fn last_rendered_text(&self) -> Option<&str> {
        self.last_rendered.as_deref()
    }
}
