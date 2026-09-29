//! EVENT_API envelope contract.
//!
//! This module is the original `ocp-shared-types` contract moved from
//! `lib.rs`. Top-level re-exports preserve source compatibility.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Bounded contexts allowed in event type names.
///
/// Existing contexts remain unchanged. Runtime V4 contexts are additive.
/// Keep this list synchronized with EVENT_CATALOG and
/// RUNTIME_EVENT_CATALOG.
pub const CONTEXTS: [&str; 18] = [
    "companion",
    "behavior",
    "ai-routing",
    "memory",
    "plugin",
    "character",
    "marketplace",
    "runtime",
    "review",
    "activity",
    "world",
    "surface",
    "navigation",
    "goal",
    "intent",
    "planner",
    "scheduler",
    "physics",
];

/// The transport-neutral event envelope (EVENT_API).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Envelope {
    /// Unique, time-ordered UUIDv7.
    pub id: Uuid,
    /// `ocp.<context>.<subject>-<past-tense-verb>`.
    #[serde(rename = "type")]
    pub event_type: String,
    /// Schema version of `data`, `major.minor`.
    pub version: String,
    /// Emitting component.
    pub source: String,
    /// Event time, RFC 3339 / ISO 8601, UTC.
    pub time: DateTime<Utc>,
    /// Required for caused events.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub correlation_id: Option<Uuid>,
    /// Canonical spelling `contentType`.
    pub content_type: String,
    /// Event-specific payload.
    pub data: serde_json::Value,
}

/// Envelope validation failures.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EnvelopeError {
    EmptyField(&'static str),
    BadTypeName(String),
    UnknownContext(String),
    BadVersion(String),
    BadContentType(String),
}

impl core::fmt::Display for EnvelopeError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::EmptyField(name) => {
                write!(f, "empty required field: {name}")
            }
            Self::BadTypeName(value) => {
                write!(f, "type name violates EVENT_API naming rules: {value}")
            }
            Self::UnknownContext(context) => {
                write!(f, "unknown bounded context in type name: {context}")
            }
            Self::BadVersion(version) => {
                write!(f, "version must be `major.minor`: {version}")
            }
            Self::BadContentType(content_type) => {
                write!(f, "unsupported contentType: {content_type}")
            }
        }
    }
}

impl std::error::Error for EnvelopeError {}

impl Envelope {
    /// Build a valid envelope with UUIDv7 ID and current UTC time.
    pub fn new(
        event_type: impl Into<String>,
        source: impl Into<String>,
        data: serde_json::Value,
    ) -> Result<Self, EnvelopeError> {
        let envelope = Self {
            id: Uuid::now_v7(),
            event_type: event_type.into(),
            version: "1.0".to_owned(),
            source: source.into(),
            time: Utc::now(),
            correlation_id: None,
            content_type: "application/json".to_owned(),
            data,
        };

        envelope.validate()?;
        Ok(envelope)
    }

    /// Attach the causing event/request ID.
    #[must_use]
    pub fn with_correlation(mut self, correlation_id: Uuid) -> Self {
        self.correlation_id = Some(correlation_id);
        self
    }

    /// Validate against EVENT_API rules.
    pub fn validate(&self) -> Result<(), EnvelopeError> {
        if self.event_type.is_empty() {
            return Err(EnvelopeError::EmptyField("type"));
        }

        if self.source.is_empty() {
            return Err(EnvelopeError::EmptyField("source"));
        }

        validate_type_name(&self.event_type)?;
        validate_version(&self.version)?;

        if self.content_type != "application/json" {
            return Err(EnvelopeError::BadContentType(self.content_type.clone()));
        }

        Ok(())
    }
}

/// Validate `ocp.<context>.<kebab-case-subject>`.
pub fn validate_type_name(name: &str) -> Result<(), EnvelopeError> {
    let parts: Vec<&str> = name.split('.').collect();

    if parts.len() != 3 || parts[0] != "ocp" {
        return Err(EnvelopeError::BadTypeName(name.to_owned()));
    }

    if !CONTEXTS.contains(&parts[1]) {
        return Err(EnvelopeError::UnknownContext(parts[1].to_owned()));
    }

    let subject = parts[2];
    let kebab_ok = !subject.is_empty()
        && !subject.starts_with('-')
        && !subject.ends_with('-')
        && subject.chars().all(|character| {
            character.is_ascii_lowercase() || character.is_ascii_digit() || character == '-'
        });

    if !kebab_ok {
        return Err(EnvelopeError::BadTypeName(name.to_owned()));
    }

    Ok(())
}

fn validate_version(version: &str) -> Result<(), EnvelopeError> {
    let mut components = version.split('.');

    let valid = matches!(
        (
            components.next(),
            components.next(),
            components.next(),
        ),
        (Some(major), Some(minor), None)
            if !major.is_empty()
                && !minor.is_empty()
                && major.chars().all(|value| value.is_ascii_digit())
                && minor.chars().all(|value| value.is_ascii_digit())
    );

    if valid {
        Ok(())
    } else {
        Err(EnvelopeError::BadVersion(version.to_owned()))
    }
}
