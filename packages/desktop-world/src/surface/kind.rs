use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SurfaceKindV2 {
    MonitorFloor,
    WindowTop,
    TaskbarTop,
    WindowLeftBoundary,
    WindowRightBoundary,
    WindowBottomBoundary,
    MonitorBoundary,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SurfaceOrientation {
    Horizontal,
    Vertical,
}
