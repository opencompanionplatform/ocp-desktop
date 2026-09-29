//! Capability grants — PLUGIN_API §4.
//! Built from an approved manifest; checked on **every** host-function call
//! (SEC-002), revocable at runtime (SEC-001).

use std::collections::HashSet;

use crate::manifest::{Access, Capabilities, TelemetryKind};

/// A single host-function access attempt, checked per call.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CapabilityRequest {
    FsRead(String),
    FsWrite(String),
    Net {
        host: String,
        port: u16,
        protocol: String,
    },
    Publish(String),
    Subscribe(String),
    MemRead(String),
    MemWrite(String),
    /// `ocp_telemetry_config` (PLUGIN_API §7a): one sensor kind, independently
    /// grantable/revocable from the others (THREAT_MODEL companion-risk-3).
    TelemetryConfig(TelemetryKind),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CapabilityError(pub String);

impl core::fmt::Display for CapabilityError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(f, "call outside granted capabilities (SEC-002): {}", self.0)
    }
}

impl std::error::Error for CapabilityError {}

#[derive(Debug, Clone, PartialEq)]
struct FsRule {
    root: String,
    write: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct NetRule {
    host: String,
    port: u16,
    protocol: String,
}

/// The enforced grant set for one Active plugin.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct GrantSet {
    fs: Vec<FsRule>,
    net: HashSet<NetRule>,
    publish: HashSet<String>,
    subscribe: HashSet<String>,
    mem_scopes: HashSet<String>,
    mem_write: HashSet<String>,
    telemetry: HashSet<TelemetryKind>,
}

/// `path` equals the granted root or sits beneath it on a `/` boundary
/// (same segment-boundary rule as event family patterns). Any `.` / `..`
/// segment is rejected outright: logic-level defense in depth on top of the
/// WASI preopen enforcement (SEC-005; spike-verified at the runtime level).
fn under_root(root: &str, path: &str) -> bool {
    if path.split(['/', '\\']).any(|seg| seg == ".." || seg == ".") {
        return false;
    }
    path == root
        || (path.len() > root.len()
            && path.starts_with(root)
            && path.as_bytes()[root.len()] == b'/')
}

impl GrantSet {
    /// Build from approved manifest capabilities (activation step, §4.3).
    #[must_use]
    pub fn from_capabilities(caps: &Capabilities) -> Self {
        let mut g = Self::default();
        for fs in &caps.filesystem {
            g.fs.push(FsRule {
                root: fs.path.clone(),
                write: fs.access == Access::ReadWrite,
            });
        }
        for net in &caps.network {
            g.net.insert(NetRule {
                host: net.host.clone(),
                port: net.port,
                protocol: net.protocol.clone(),
            });
        }
        g.publish.extend(caps.events.publish.iter().cloned());
        g.subscribe.extend(caps.events.subscribe.iter().cloned());
        for mem in &caps.memory {
            g.mem_scopes.insert(mem.scope.clone());
            if mem.access == Access::ReadWrite {
                g.mem_write.insert(mem.scope.clone());
            }
        }
        g.telemetry.extend(caps.telemetry.iter().copied());
        g
    }

    /// Per-call check (SEC-002). Denial carries the attempted access for the
    /// audit log (X1-R); it never reaches the kernel.
    pub fn check(&self, req: &CapabilityRequest) -> Result<(), CapabilityError> {
        let ok = match req {
            CapabilityRequest::FsRead(p) => self.fs.iter().any(|r| under_root(&r.root, p)),
            CapabilityRequest::FsWrite(p) => {
                self.fs.iter().any(|r| r.write && under_root(&r.root, p))
            }
            CapabilityRequest::Net {
                host,
                port,
                protocol,
            } => self.net.contains(&NetRule {
                host: host.clone(),
                port: *port,
                protocol: protocol.clone(),
            }),
            CapabilityRequest::Publish(t) => self.publish.contains(t),
            CapabilityRequest::Subscribe(t) => self.subscribe.contains(t),
            CapabilityRequest::MemRead(s) => self.mem_scopes.contains(s),
            CapabilityRequest::MemWrite(s) => self.mem_write.contains(s),
            CapabilityRequest::TelemetryConfig(k) => self.telemetry.contains(k),
        };
        if ok {
            Ok(())
        } else {
            Err(CapabilityError(format!("{req:?}")))
        }
    }

    /// Runtime revocation (SEC-001): applies on the next call.
    /// Returns `true` when something was actually removed.
    pub fn revoke(&mut self, req: &CapabilityRequest) -> bool {
        match req {
            CapabilityRequest::FsRead(p) | CapabilityRequest::FsWrite(p) => {
                let before = self.fs.len();
                self.fs.retain(|r| r.root != *p);
                self.fs.len() != before
            }
            CapabilityRequest::Net {
                host,
                port,
                protocol,
            } => self.net.remove(&NetRule {
                host: host.clone(),
                port: *port,
                protocol: protocol.clone(),
            }),
            CapabilityRequest::Publish(t) => self.publish.remove(t),
            CapabilityRequest::Subscribe(t) => self.subscribe.remove(t),
            CapabilityRequest::MemRead(s) | CapabilityRequest::MemWrite(s) => {
                self.mem_write.remove(s);
                self.mem_scopes.remove(s)
            }
            CapabilityRequest::TelemetryConfig(k) => self.telemetry.remove(k),
        }
    }
}
