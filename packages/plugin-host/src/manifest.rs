//! Plugin manifest — PLUGIN_API §2. The single declaration of identity,
//! capabilities, and commercial terms. Strict on the wire (unknown fields
//! rejected, mirroring the envelope rule).

use std::collections::BTreeMap;

use ocp_shared_types::validate_type_name;
use serde::{Deserialize, Serialize};

/// Lifecycle event names owned by the Plugin Host (PLUGIN_API §2.2, TD-004):
/// manifests may not declare publish topics in this set.
pub const RESERVED_LIFECYCLE: [&str; 10] = [
    "discovered",
    "installed",
    "rejected",
    "activated",
    "suspended",
    "crashed",
    "resumed",
    "removed",
    "capability-granted",
    "capability-revoked",
];

/// OS telemetry event names owned by the Plugin Host (PLUGIN_API §7a, I4):
/// the host samples the OS and publishes these on a plugin's behalf; a
/// manifest declaring one of these as its own publish topic would let it
/// forge readings, so they're reserved the same way lifecycle names are.
pub const RESERVED_TELEMETRY: [&str; 5] = [
    "os-telemetry-cpu-changed",
    "os-telemetry-memory-changed",
    "os-telemetry-battery-changed",
    "os-telemetry-foreground-changed",
    "os-telemetry-mouse-changed",
];

/// One OS telemetry sensor (PLUGIN_API §7a). Each kind is its own
/// independently-consentable manifest capability (THREAT_MODEL
/// companion-risk-3, SEC-011) — granting `cpu` never implies `foreground`.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum TelemetryKind {
    Cpu,
    Memory,
    Battery,
    Foreground,
    Mouse,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Manifest {
    pub manifest_version: String,
    /// Reverse-DNS id; the host derives memory scope `plugin:<id>` from this.
    pub id: String,
    pub name: String,
    /// Semver `major.minor.patch`.
    pub version: String,
    pub publisher: Publisher,
    /// SPDX identifier or `marketplace:lic-<id>` (mandatory).
    pub license: String,
    /// Mandatory; carried, never processed, by the core.
    pub entitlement: Entitlement,
    #[serde(default)]
    pub tier: Tier,
    pub entry: String,
    pub signature: SignatureBlock,
    pub capabilities: Capabilities,
    #[serde(default)]
    pub event_schema_versions: BTreeMap<String, String>,
    #[serde(default)]
    pub quotas: Quotas,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Publisher {
    pub id: String,
    pub name: String,
    /// References the publisher signing key (ADR-0011).
    pub key_id: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Entitlement {
    Free,
    Paid,
    Subscription,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "lowercase")]
pub enum Tier {
    #[default]
    Wasm,
    /// Escape hatch (§6, SEC-003): signature + unsandboxed consent + review tier.
    Native,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SignatureBlock {
    /// Must be `ed25519` (ADR-0011).
    pub algorithm: String,
    pub key_id: String,
    /// `sha256:<hex>` over the package bytes.
    pub digest: String,
    /// `base64:<signature>` over the raw 32-byte digest.
    pub value: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Capabilities {
    #[serde(default)]
    pub filesystem: Vec<FsGrant>,
    #[serde(default)]
    pub network: Vec<NetGrant>,
    #[serde(default)]
    pub events: EventGrants,
    #[serde(default)]
    pub memory: Vec<MemGrant>,
    /// OS telemetry sensors granted (PLUGIN_API §7a, I4).
    #[serde(default)]
    pub telemetry: Vec<TelemetryKind>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FsGrant {
    /// Explicit path; `${plugin_data}` expands to the host-assigned directory.
    pub path: String,
    pub access: Access,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum Access {
    #[serde(rename = "read")]
    Read,
    #[serde(rename = "read-write")]
    ReadWrite,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct NetGrant {
    pub host: String,
    pub port: u16,
    pub protocol: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EventGrants {
    #[serde(default)]
    pub publish: Vec<String>,
    #[serde(default)]
    pub subscribe: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MemGrant {
    pub scope: String,
    pub access: Access,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Quotas {
    /// Requested limit; the host ceiling always wins (§5).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_memory_mb: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ManifestError {
    BadField(&'static str, String),
    WildcardGrant(String),
    ReservedLifecycleTopic(String),
    BadTopic(String),
    /// Cross-scope memory requires the (post-alpha) explicit approval flow;
    /// in the alpha only `plugin:<id>` is accepted (SEC-020).
    CrossScopeMemory(String),
}

impl core::fmt::Display for ManifestError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::BadField(name, v) => write!(f, "invalid manifest field {name}: {v}"),
            Self::WildcardGrant(g) => write!(f, "wildcard grants are forbidden (SEC-005): {g}"),
            Self::ReservedLifecycleTopic(t) => {
                write!(
                    f,
                    "publish topic is a reserved host-owned name (lifecycle TD-004 or os-telemetry §7a): {t}"
                )
            }
            Self::BadTopic(t) => write!(f, "topic violates EVENT_API naming: {t}"),
            Self::CrossScopeMemory(s) => {
                write!(
                    f,
                    "memory scope outside plugin:<id> requires approval flow (SEC-020): {s}"
                )
            }
        }
    }
}

impl std::error::Error for ManifestError {}

fn is_semver(v: &str) -> bool {
    let parts: Vec<&str> = v.split('.').collect();
    parts.len() == 3
        && parts
            .iter()
            .all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()))
}

fn is_reverse_dns(id: &str) -> bool {
    id.contains('.')
        && id.split('.').all(|seg| {
            !seg.is_empty()
                && seg
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        })
}

impl Manifest {
    /// PLUGIN_API §2.2 validation. Any failure ⇒ the package is Rejected.
    pub fn validate(&self) -> Result<(), ManifestError> {
        if self.manifest_version.split('.').next() != Some("1") {
            return Err(ManifestError::BadField(
                "manifestVersion",
                self.manifest_version.clone(),
            ));
        }
        if !is_reverse_dns(&self.id) {
            return Err(ManifestError::BadField("id", self.id.clone()));
        }
        if !is_semver(&self.version) {
            return Err(ManifestError::BadField("version", self.version.clone()));
        }
        if self.license.trim().is_empty() {
            return Err(ManifestError::BadField("license", self.license.clone()));
        }
        if self.entry.trim().is_empty() {
            return Err(ManifestError::BadField("entry", self.entry.clone()));
        }
        if self.signature.algorithm != "ed25519" {
            return Err(ManifestError::BadField(
                "signature.algorithm",
                self.signature.algorithm.clone(),
            ));
        }

        for fs in &self.capabilities.filesystem {
            if fs.path.trim().is_empty() {
                return Err(ManifestError::BadField("filesystem.path", fs.path.clone()));
            }
            if fs.path.contains('*') {
                return Err(ManifestError::WildcardGrant(fs.path.clone()));
            }
        }
        for net in &self.capabilities.network {
            if net.host.trim().is_empty() || net.protocol.trim().is_empty() {
                return Err(ManifestError::BadField("network", net.host.clone()));
            }
            if net.host.contains('*') {
                return Err(ManifestError::WildcardGrant(net.host.clone()));
            }
        }
        for topic in &self.capabilities.events.publish {
            if topic.contains('*') {
                return Err(ManifestError::WildcardGrant(topic.clone()));
            }
            if validate_type_name(topic).is_err() {
                return Err(ManifestError::BadTopic(topic.clone()));
            }
            if let Some(subject) = topic.strip_prefix("ocp.plugin.") {
                if RESERVED_LIFECYCLE.contains(&subject) || RESERVED_TELEMETRY.contains(&subject) {
                    return Err(ManifestError::ReservedLifecycleTopic(topic.clone()));
                }
            }
        }
        for topic in &self.capabilities.events.subscribe {
            if topic.contains('*') {
                return Err(ManifestError::WildcardGrant(topic.clone()));
            }
            if validate_type_name(topic).is_err() {
                return Err(ManifestError::BadTopic(topic.clone()));
            }
        }
        let own_scope = format!("plugin:{}", self.id);
        for mem in &self.capabilities.memory {
            if mem.scope != own_scope {
                return Err(ManifestError::CrossScopeMemory(mem.scope.clone()));
            }
        }
        Ok(())
    }
}
