use ocp_desktop_world::{DesktopWorldError, DesktopWorldSnapshot, SurfaceProvider};
use ocp_shared_types::surface::{AttachmentPoint, SurfaceGeometry};
use ocp_shared_types::{
    MonitorId, Orientation, Point2, Rect, SurfaceCapabilities, SurfaceDescriptor, SurfaceId,
    SurfaceKind, SurfaceStability, Vector2, WindowId, WorldEntityId,
};
use std::collections::HashMap;
use std::sync::Mutex;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum WindowEdge {
    Top,
    Left,
    Right,
    Bottom,
}

/// Derives stable Window edge Surfaces from canonical World windows.
#[derive(Debug, Default)]
pub struct WindowSurfaceProvider {
    ids: Mutex<HashMap<(WindowId, WindowEdge), SurfaceId>>,
}

impl WindowSurfaceProvider {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    fn id_for(
        &self,
        window_id: WindowId,
        edge: WindowEdge,
    ) -> Result<SurfaceId, DesktopWorldError> {
        let mut ids = self
            .ids
            .lock()
            .map_err(|_| DesktopWorldError::SurfaceProviderFailure {
                provider_id: self.provider_id().to_owned(),
                message: "surface ID registry lock poisoned".to_owned(),
            })?;

        Ok(*ids.entry((window_id, edge)).or_default())
    }
}

impl SurfaceProvider for WindowSurfaceProvider {
    fn provider_id(&self) -> &'static str {
        "ocp.surface.windows"
    }

    fn collect_surfaces(
        &self,
        world: &DesktopWorldSnapshot,
    ) -> Result<Vec<SurfaceDescriptor>, DesktopWorldError> {
        let mut surfaces = Vec::new();

        for window in world
            .windows
            .iter()
            .filter(|window| window.visible && !window.minimized && !is_ocp_internal_window(window))
        {
            let rect = window.frame_bounds.unwrap_or(window.bounds);
            let virtual_bounds = world.virtual_desktop_bounds.0;
            let covers_monitor_work_area = world.monitors.iter().any(|monitor| {
                let area = monitor.work_area.0;
                rect.left() <= area.left()
                    && rect.top() <= area.top()
                    && rect.right() >= area.right()
                    && rect.bottom() >= area.bottom()
            });
            if rect.left() <= virtual_bounds.left()
                && rect.top() <= virtual_bounds.top()
                && rect.right() >= virtual_bounds.right()
                && rect.bottom() >= virtual_bounds.bottom()
            {
                // The transparent OCP overlay spans the virtual desktop. It
                // is a presentation host, never a character surface or an
                // active application target.
                continue;
            }
            if covers_monitor_work_area {
                // A maximized/full-work-area application has no usable top
                // ledge for a Shimeji. Removing WindowTop lets an attached
                // companion detach and fall to the canonical monitor floor.
                continue;
            }

            let is_active = world.active_window_id == Some(window.id) || window.active;
            let top_is_visible = world.monitors.is_empty()
                || world.monitors.iter().any(|monitor| {
                    let area = monitor.work_area.0;
                    rect.top() >= area.top()
                        && rect.top() <= area.bottom()
                        && rect.right() > area.left()
                        && rect.left() < area.right()
                });
            if top_is_visible {
                // Keep a stable top surface for every eligible window so an
                // already seated companion does not detach merely because
                // foreground focus changes. A visible inactive top is a
                // fall-only landing surface: this lets a companion that loses
                // its support land on the next visible window below instead
                // of skipping directly to the taskbar. It intentionally does
                // not receive WALKABLE or SITTABLE, so drag-to-sit and normal
                // window interactions remain active-window-only.
                let capabilities = if is_active {
                    SurfaceCapabilities::WALKABLE
                        .union(SurfaceCapabilities::RUNNABLE)
                        .union(SurfaceCapabilities::LANDABLE)
                        // The active window top is the horizontal continuation of
                        // the climbable window sides. It must be a hangable ledge;
                        // otherwise a climb can reach the window top but the physics
                        // solver has no canonical horizontal surface to attach to.
                        .union(SurfaceCapabilities::HANGABLE)
                        .union(SurfaceCapabilities::SITTABLE)
                        .union(SurfaceCapabilities::SLEEPABLE)
                        .union(SurfaceCapabilities::JUMP_ORIGIN)
                        .union(SurfaceCapabilities::JUMP_TARGET)
                        .union(SurfaceCapabilities::DYNAMIC)
                } else {
                    SurfaceCapabilities::LANDABLE.union(SurfaceCapabilities::DYNAMIC)
                };
                surfaces.push(self.horizontal_surface(
                    world,
                    window,
                    WindowEdge::Top,
                    SurfaceKind::WindowTop,
                    Point2::new(rect.left(), rect.top()),
                    Point2::new(rect.right(), rect.top()),
                    Vector2::new(0.0, -1.0),
                    capabilities,
                )?);
            }

            surfaces.push(self.vertical_surface(
                world,
                window,
                WindowEdge::Left,
                SurfaceKind::WindowLeft,
                Point2::new(rect.left(), rect.top()),
                Point2::new(rect.left(), rect.bottom()),
                Vector2::new(-1.0, 0.0),
            )?);

            surfaces.push(self.vertical_surface(
                world,
                window,
                WindowEdge::Right,
                SurfaceKind::WindowRight,
                Point2::new(rect.right(), rect.top()),
                Point2::new(rect.right(), rect.bottom()),
                Vector2::new(1.0, 0.0),
            )?);

            surfaces.push(self.horizontal_surface(
                world,
                window,
                WindowEdge::Bottom,
                SurfaceKind::WindowBottom,
                Point2::new(rect.left(), rect.bottom()),
                Point2::new(rect.right(), rect.bottom()),
                Vector2::new(0.0, 1.0),
                SurfaceCapabilities::HANGABLE.union(SurfaceCapabilities::DYNAMIC),
            )?);
        }

        Ok(surfaces)
    }
}

fn is_ocp_internal_window(window: &ocp_shared_types::Window) -> bool {
    window
        .application_id
        .split(':')
        .next()
        .is_some_and(|class_name| class_name.eq_ignore_ascii_case("OCPNativeSpike"))
}

impl WindowSurfaceProvider {
    #[allow(clippy::too_many_arguments)]
    fn horizontal_surface(
        &self,
        world: &DesktopWorldSnapshot,
        window: &ocp_shared_types::Window,
        edge: WindowEdge,
        kind: SurfaceKind,
        start: Point2,
        end: Point2,
        normal: Vector2,
        capabilities: SurfaceCapabilities,
    ) -> Result<SurfaceDescriptor, DesktopWorldError> {
        Ok(SurfaceDescriptor {
            id: self.id_for(window.id, edge)?,
            provider_id: self.provider_id().to_owned(),
            owner_entity_id: Some(window.entity_id),
            surface_kind: kind,
            geometry: SurfaceGeometry::Segment { start, end },
            orientation: Orientation::Horizontal,
            normal,
            capabilities,
            stability: SurfaceStability::Dynamic,
            motion_binding: None,
            attachment_points: vec![AttachmentPoint {
                position: Point2::new((start.x + end.x) * 0.5, (start.y + end.y) * 0.5),
                normal,
                tag: Some("center".to_owned()),
            }],
            tags: vec!["window".to_owned()],
            revision: world.revision.value(),
        })
    }

    #[allow(clippy::too_many_arguments)]
    fn vertical_surface(
        &self,
        world: &DesktopWorldSnapshot,
        window: &ocp_shared_types::Window,
        edge: WindowEdge,
        kind: SurfaceKind,
        start: Point2,
        end: Point2,
        normal: Vector2,
    ) -> Result<SurfaceDescriptor, DesktopWorldError> {
        Ok(SurfaceDescriptor {
            id: self.id_for(window.id, edge)?,
            provider_id: self.provider_id().to_owned(),
            owner_entity_id: Some(window.entity_id),
            surface_kind: kind,
            geometry: SurfaceGeometry::Segment { start, end },
            orientation: Orientation::Vertical,
            normal,
            capabilities: SurfaceCapabilities::CLIMBABLE
                .union(SurfaceCapabilities::HANGABLE)
                .union(SurfaceCapabilities::DYNAMIC),
            stability: SurfaceStability::Dynamic,
            motion_binding: None,
            attachment_points: Vec::new(),
            tags: vec!["window".to_owned()],
            revision: world.revision.value(),
        })
    }
}

/// Derives one stable desktop-floor Surface per monitor work area.
///
/// A single floor built from `virtual_desktop_bounds` is invalid on mixed-height
/// monitor layouts: its Y coordinate is the bottom of the tallest monitor and
/// can place a companion below shorter monitors. Per-monitor floors keep each
/// monitor's usable bottom authoritative and preserve stable Surface identity.
#[derive(Debug, Default)]
pub struct DesktopSurfaceProvider {
    surface_ids: Mutex<HashMap<(MonitorId, MonitorEdge), SurfaceId>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum MonitorEdge {
    Floor,
    Left,
    Top,
    Right,
}

impl DesktopSurfaceProvider {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }
}

impl SurfaceProvider for DesktopSurfaceProvider {
    fn provider_id(&self) -> &'static str {
        "ocp.surface.desktop"
    }

    fn collect_surfaces(
        &self,
        world: &DesktopWorldSnapshot,
    ) -> Result<Vec<SurfaceDescriptor>, DesktopWorldError> {
        let mut ids =
            self.surface_ids
                .lock()
                .map_err(|_| DesktopWorldError::SurfaceProviderFailure {
                    provider_id: self.provider_id().to_owned(),
                    message: "desktop surface ID lock poisoned".to_owned(),
                })?;

        let capabilities = SurfaceCapabilities::WALKABLE
            .union(SurfaceCapabilities::RUNNABLE)
            .union(SurfaceCapabilities::LANDABLE)
            .union(SurfaceCapabilities::SITTABLE)
            .union(SurfaceCapabilities::SLEEPABLE)
            .union(SurfaceCapabilities::JUMP_ORIGIN)
            .union(SurfaceCapabilities::JUMP_TARGET);

        let mut surfaces = Vec::with_capacity(world.monitors.len() * 4);

        for monitor in &world.monitors {
            let rect =
                if monitor.work_area.0.size.width > 0.0 && monitor.work_area.0.size.height > 0.0 {
                    monitor.work_area.0
                } else {
                    monitor.bounds.0
                };

            if rect.size.width <= 0.0 || rect.size.height <= 0.0 {
                continue;
            }

            let floor_id = *ids
                .entry((monitor.id, MonitorEdge::Floor))
                .or_insert_with(SurfaceId::new);
            let y = resolved_monitor_floor_y(world, rect, monitor.bounds.0);

            surfaces.push(SurfaceDescriptor {
                id: floor_id,
                provider_id: self.provider_id().to_owned(),
                owner_entity_id: Some(monitor.entity_id),
                surface_kind: SurfaceKind::DesktopFloor,
                geometry: SurfaceGeometry::Segment {
                    start: Point2::new(rect.left(), y),
                    end: Point2::new(rect.right(), y),
                },
                orientation: Orientation::Horizontal,
                normal: Vector2::new(0.0, -1.0),
                capabilities,
                stability: SurfaceStability::Static,
                motion_binding: None,
                attachment_points: Vec::new(),
                tags: vec![
                    "desktop".to_owned(),
                    "monitor-floor".to_owned(),
                    monitor.id.to_string(),
                ],
                revision: world.revision.value(),
            });

            for (edge, start, end, orientation, normal, tag, edge_capabilities) in [
                (
                    MonitorEdge::Left,
                    Point2::new(rect.left(), rect.top()),
                    Point2::new(rect.left(), y),
                    Orientation::Vertical,
                    Vector2::new(1.0, 0.0),
                    "monitor-left",
                    SurfaceCapabilities::CLIMBABLE.union(SurfaceCapabilities::HANGABLE),
                ),
                (
                    MonitorEdge::Top,
                    Point2::new(rect.left(), rect.top()),
                    Point2::new(rect.right(), rect.top()),
                    Orientation::Horizontal,
                    Vector2::new(0.0, 1.0),
                    "monitor-top",
                    SurfaceCapabilities::HANGABLE,
                ),
                (
                    MonitorEdge::Right,
                    Point2::new(rect.right(), rect.top()),
                    Point2::new(rect.right(), y),
                    Orientation::Vertical,
                    Vector2::new(-1.0, 0.0),
                    "monitor-right",
                    SurfaceCapabilities::CLIMBABLE.union(SurfaceCapabilities::HANGABLE),
                ),
            ] {
                let id = *ids.entry((monitor.id, edge)).or_insert_with(SurfaceId::new);
                surfaces.push(SurfaceDescriptor {
                    id,
                    provider_id: self.provider_id().to_owned(),
                    owner_entity_id: Some(monitor.entity_id),
                    surface_kind: SurfaceKind::MonitorEdge,
                    geometry: SurfaceGeometry::Segment { start, end },
                    orientation,
                    normal,
                    capabilities: edge_capabilities,
                    stability: SurfaceStability::Static,
                    motion_binding: None,
                    attachment_points: Vec::new(),
                    tags: vec![
                        "desktop".to_owned(),
                        "monitor-edge".to_owned(),
                        tag.to_owned(),
                        monitor.id.to_string(),
                    ],
                    revision: world.revision.value(),
                });
            }
        }

        Ok(surfaces)
    }
}

/// Some Windows sensor combinations report a work-area bottom below the
/// separately observed taskbar top (for example 912 versus 888 logical px).
/// Treat a visible horizontal taskbar in the lower half of this monitor as the
/// usable floor boundary so canonical character feet meet the visible taskbar.
fn resolved_monitor_floor_y(
    world: &DesktopWorldSnapshot,
    work_area: Rect,
    monitor_bounds: Rect,
) -> f32 {
    let fallback = work_area.bottom();
    let Some(taskbar) = world.taskbar_or_dock.as_ref() else {
        return fallback;
    };
    if taskbar.auto_hidden {
        return fallback;
    }
    let taskbar = taskbar.bounds.0;
    let horizontal_overlap =
        work_area.right().min(taskbar.right()) - work_area.left().max(taskbar.left());
    let horizontal_bar = taskbar.size.width >= taskbar.size.height * 2.0;
    let lower_half = taskbar.top() >= monitor_bounds.top() + monitor_bounds.size.height * 0.5;
    if horizontal_overlap > 0.0
        && horizontal_bar
        && lower_half
        && taskbar.top() < fallback
        && taskbar.top() >= work_area.top()
    {
        taskbar.top()
    } else {
        fallback
    }
}

/// Derives the visible taskbar or dock top edge as a walkable surface.
///
/// The world currently models one taskbar/dock descriptor. Its surface ID is
/// stable for the owning native entity, so physics attachments survive normal
/// observation updates without replacing the body.
#[derive(Debug, Default)]
pub struct TaskbarSurfaceProvider {
    surface_ids: Mutex<HashMap<WorldEntityId, SurfaceId>>,
}

impl TaskbarSurfaceProvider {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }
}

impl SurfaceProvider for TaskbarSurfaceProvider {
    fn provider_id(&self) -> &'static str {
        "ocp.surface.taskbar"
    }

    fn collect_surfaces(
        &self,
        world: &DesktopWorldSnapshot,
    ) -> Result<Vec<SurfaceDescriptor>, DesktopWorldError> {
        let Some(taskbar) = world.taskbar_or_dock.as_ref() else {
            return Ok(Vec::new());
        };

        if taskbar.auto_hidden
            || taskbar.bounds.0.size.width <= 0.0
            || taskbar.bounds.0.size.height <= 0.0
        {
            return Ok(Vec::new());
        }

        let mut ids =
            self.surface_ids
                .lock()
                .map_err(|_| DesktopWorldError::SurfaceProviderFailure {
                    provider_id: self.provider_id().to_owned(),
                    message: "taskbar surface ID lock poisoned".to_owned(),
                })?;
        let rect = taskbar.bounds.0;
        let id = *ids.entry(taskbar.entity_id).or_insert_with(SurfaceId::new);
        let capabilities = SurfaceCapabilities::WALKABLE
            .union(SurfaceCapabilities::RUNNABLE)
            .union(SurfaceCapabilities::LANDABLE)
            .union(SurfaceCapabilities::SITTABLE)
            .union(SurfaceCapabilities::SLEEPABLE)
            .union(SurfaceCapabilities::JUMP_ORIGIN)
            .union(SurfaceCapabilities::JUMP_TARGET);

        Ok(vec![SurfaceDescriptor {
            id,
            provider_id: self.provider_id().to_owned(),
            owner_entity_id: Some(taskbar.entity_id),
            surface_kind: SurfaceKind::TaskbarTop,
            geometry: SurfaceGeometry::Segment {
                start: Point2::new(rect.left(), rect.top()),
                end: Point2::new(rect.right(), rect.top()),
            },
            orientation: Orientation::Horizontal,
            normal: Vector2::new(0.0, -1.0),
            capabilities,
            stability: SurfaceStability::Dynamic,
            motion_binding: None,
            attachment_points: Vec::new(),
            tags: vec!["taskbar".to_owned(), taskbar.platform_kind.clone()],
            revision: world.revision.value(),
        }])
    }
}
