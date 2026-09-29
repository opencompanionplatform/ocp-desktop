use ocp_shared_types::WorldRevision;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeHealth {
    Starting,
    Running,
    Degraded,
    Stopping,
    Stopped,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RuntimeHealthSnapshot {
    pub status: RuntimeHealth,
    pub completed_ticks: u64,
    pub successful_ticks: u64,
    pub failed_ticks: u64,
    pub consecutive_failures: u32,
    pub last_revision: WorldRevision,
    pub last_error: Option<String>,
}

impl Default for RuntimeHealthSnapshot {
    fn default() -> Self {
        Self {
            status: RuntimeHealth::Starting,
            completed_ticks: 0,
            successful_ticks: 0,
            failed_ticks: 0,
            consecutive_failures: 0,
            last_revision: WorldRevision::new(0),
            last_error: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorldRuntimeSummary {
    pub completed_ticks: u64,
    pub successful_ticks: u64,
    pub failed_ticks: u64,
    pub final_revision: WorldRevision,
    pub stopped_by_request: bool,
}
