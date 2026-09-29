use ocp_shared_types::{Point2, Vector2, WorldRevision};
use serde_json::Value;
use std::fmt;

use crate::DesktopWorldSnapshot;

use super::{
    SurfaceEligibilityPolicy, SurfaceKindV2, SurfaceOrientation, SurfaceOwnerV2, SurfaceRegistryId,
    SurfaceRegistrySnapshot, SurfaceSegment, SurfaceSupport,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SurfaceBuildError {
    Serialization(String),
    InvalidSnapshot(String),
}

impl fmt::Display for SurfaceBuildError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Serialization(message) => write!(formatter, "snapshot serialization: {message}"),
            Self::InvalidSnapshot(message) => write!(formatter, "invalid snapshot: {message}"),
        }
    }
}

impl std::error::Error for SurfaceBuildError {}

#[derive(Debug, Clone)]
pub struct SurfaceRegistryBuilder {
    policy: SurfaceEligibilityPolicy,
    minimum_window_width: f32,
}

impl Default for SurfaceRegistryBuilder {
    fn default() -> Self {
        Self {
            policy: SurfaceEligibilityPolicy::default(),
            minimum_window_width: 96.0,
        }
    }
}

impl SurfaceRegistryBuilder {
    #[must_use]
    pub fn new(policy: SurfaceEligibilityPolicy) -> Self {
        Self {
            policy,
            ..Self::default()
        }
    }

    #[must_use]
    pub fn with_minimum_window_width(mut self, width: f32) -> Self {
        self.minimum_window_width = width.max(1.0);
        self
    }

    pub fn build(
        &self,
        previous: Option<&SurfaceRegistrySnapshot>,
        world: &DesktopWorldSnapshot,
    ) -> Result<(SurfaceRegistrySnapshot, super::SurfaceRegistryDiff), SurfaceBuildError> {
        let value = serde_json::to_value(world)
            .map_err(|error| SurfaceBuildError::Serialization(error.to_string()))?;
        self.build_from_value(previous, world.revision, &value)
    }

    pub fn build_from_value(
        &self,
        previous: Option<&SurfaceRegistrySnapshot>,
        world_revision: WorldRevision,
        world: &Value,
    ) -> Result<(SurfaceRegistrySnapshot, super::SurfaceRegistryDiff), SurfaceBuildError> {
        if !world.is_object() {
            return Err(SurfaceBuildError::InvalidSnapshot(
                "root must be an object".to_owned(),
            ));
        }

        let mut surfaces = Vec::new();
        self.build_monitor_floors(world_revision, world, &mut surfaces);
        self.build_taskbar(world_revision, world, &mut surfaces);
        self.build_window_tops(world_revision, world, &mut surfaces);

        Ok(SurfaceRegistrySnapshot::reconcile(
            previous,
            world_revision,
            surfaces,
        ))
    }

    fn build_monitor_floors(
        &self,
        revision: WorldRevision,
        world: &Value,
        surfaces: &mut Vec<SurfaceSegment>,
    ) {
        for (index, monitor) in array(world, &["monitors"]).iter().enumerate() {
            let monitor_id = string(monitor, &["id", "monitorId", "monitor_id"])
                .unwrap_or_else(|| format!("index-{index}"));
            let bounds = object(monitor, &["workArea", "work_area", "bounds"])
                .and_then(rect)
                .or_else(|| object(monitor, &["bounds"]).and_then(rect));
            let Some((x, y, width, height)) = bounds else {
                continue;
            };
            if width <= 0.0 || height <= 0.0 {
                continue;
            }
            let floor_y = y + height;
            surfaces.push(segment(
                SurfaceRegistryId::monitor_floor(&monitor_id),
                SurfaceKindV2::MonitorFloor,
                Point2::new(x, floor_y),
                Point2::new(x + width, floor_y),
                SurfaceOwnerV2::Monitor { monitor_id },
                SurfaceSupport {
                    supports_walk: true,
                    supports_sit: true,
                    supports_climb: false,
                    supports_hang: false,
                },
                0,
                revision,
            ));
        }
    }

    fn build_taskbar(
        &self,
        revision: WorldRevision,
        world: &Value,
        surfaces: &mut Vec<SurfaceSegment>,
    ) {
        let Some(taskbar) = object(world, &["taskbarOrDock", "taskbar_or_dock"]) else {
            return;
        };
        let Some((x, y, width, _height)) = object(taskbar, &["bounds"]).and_then(rect) else {
            return;
        };
        if width <= 0.0 {
            return;
        }
        let entity_id = string(taskbar, &["entityId", "entity_id", "id"])
            .unwrap_or_else(|| "default".to_owned());
        surfaces.push(segment(
            SurfaceRegistryId::taskbar_top(&entity_id),
            SurfaceKindV2::TaskbarTop,
            Point2::new(x, y),
            Point2::new(x + width, y),
            SurfaceOwnerV2::Taskbar { entity_id },
            SurfaceSupport {
                supports_walk: true,
                supports_sit: true,
                supports_climb: false,
                supports_hang: false,
            },
            i32::MAX - 1,
            revision,
        ));
    }

    fn build_window_tops(
        &self,
        revision: WorldRevision,
        world: &Value,
        surfaces: &mut Vec<SurfaceSegment>,
    ) {
        for (index, window) in array(world, &["windows"]).iter().enumerate() {
            let window_id = string(window, &["id", "windowId", "window_id"])
                .unwrap_or_else(|| format!("index-{index}"));
            let application_id =
                string(window, &["applicationId", "application_id"]).unwrap_or_default();
            let title = string(
                window,
                &["title", "titleClassification", "title_classification"],
            )
            .unwrap_or_default();
            let visible = boolean(window, &["visible"]).unwrap_or(true);
            let minimized = boolean(window, &["minimized"]).unwrap_or(false);
            let tool_window = boolean(window, &["toolWindow", "tool_window"]).unwrap_or(false);

            if !self
                .policy
                .permits_window(&application_id, &title, visible, minimized, tool_window)
            {
                continue;
            }

            let Some((x, y, width, height)) = object(window, &["bounds"]).and_then(rect) else {
                continue;
            };
            if width < self.minimum_window_width || height <= 0.0 {
                continue;
            }
            let z_order = integer(window, &["zOrder", "z_order"]).unwrap_or(0) as i32;

            surfaces.push(segment(
                SurfaceRegistryId::window_top(&window_id),
                SurfaceKindV2::WindowTop,
                Point2::new(x, y),
                Point2::new(x + width, y),
                SurfaceOwnerV2::Window {
                    window_id,
                    application_id,
                },
                SurfaceSupport {
                    supports_walk: true,
                    supports_sit: true,
                    supports_climb: false,
                    supports_hang: true,
                },
                z_order,
                revision,
            ));
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn segment(
    id: SurfaceRegistryId,
    kind: SurfaceKindV2,
    start: Point2,
    end: Point2,
    owner: SurfaceOwnerV2,
    support: SurfaceSupport,
    z_order: i32,
    revision: WorldRevision,
) -> SurfaceSegment {
    SurfaceSegment {
        id,
        kind,
        start,
        end,
        normal: Vector2::new(0.0, -1.0),
        thickness: 1.0,
        orientation: SurfaceOrientation::Horizontal,
        owner,
        support,
        z_order,
        eligible: true,
        visible: true,
        world_revision: revision,
        surface_revision: revision,
    }
}

fn array<'a>(value: &'a Value, keys: &[&str]) -> &'a [Value] {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(Value::as_array))
        .map_or(&[], Vec::as_slice)
}

fn object<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a Value> {
    keys.iter().find_map(|key| value.get(*key))
}

fn string(value: &Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| {
        value.get(*key).and_then(|candidate| match candidate {
            Value::String(text) => Some(text.clone()),
            Value::Number(number) => Some(number.to_string()),
            Value::Object(object) => object
                .get("0")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            _ => None,
        })
    })
}

fn boolean(value: &Value, keys: &[&str]) -> Option<bool> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(Value::as_bool))
}

fn integer(value: &Value, keys: &[&str]) -> Option<i64> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(Value::as_i64))
}

fn rect(value: &Value) -> Option<(f32, f32, f32, f32)> {
    let value = value.get("0").unwrap_or(value);
    let origin = value.get("origin")?;
    let size = value.get("size")?;
    Some((
        number(origin, "x")?,
        number(origin, "y")?,
        number(size, "width")?,
        number(size, "height")?,
    ))
}

fn number(value: &Value, key: &str) -> Option<f32> {
    value.get(key)?.as_f64().map(|number| number as f32)
}
