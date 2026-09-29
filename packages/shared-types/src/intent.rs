//! Canonical Intent and arbitration types.

use crate::{Goal, IntentId};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum IntentSource {
    Idle,
    Auto,
    Ai,
    Api,
    Manual,
    UserDrag,
    Safety,
}

impl IntentSource {
    #[must_use]
    pub const fn default_priority(self) -> u8 {
        match self {
            Self::Safety => 100,
            Self::UserDrag => 95,
            Self::Manual => 90,
            Self::Api => 70,
            Self::Ai => 60,
            Self::Auto => 20,
            Self::Idle => 0,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Interruptibility {
    Interruptible,
    Deferred,
    NonInterruptible,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CancellationPolicy {
    CancelImmediately,
    FinishCurrentStep,
    ReturnToSafeSurface,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Intent {
    pub id: IntentId,
    pub source: IntentSource,
    pub priority: u8,
    pub goal: Goal,
    pub created_at_ms: u64,
    pub expires_at_ms: Option<u64>,
    pub interruptibility: Interruptibility,
    pub cancellation_policy: CancellationPolicy,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "result")]
pub enum IntentResult {
    Accepted,
    Rejected { reason: String },
    Cancelled { reason: String },
}
