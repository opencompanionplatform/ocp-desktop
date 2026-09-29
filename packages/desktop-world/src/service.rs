use ocp_shared_types::{WorldId, WorldRevision};

use crate::{
    DesktopObservationBatch, DesktopWorldChange, DesktopWorldDiff, DesktopWorldError,
    DesktopWorldSnapshot, SurfaceProvider, WindowChangeKind,
};

pub struct DesktopWorldService {
    world_id: WorldId,
    snapshot: Option<DesktopWorldSnapshot>,
    surface_providers: Vec<Box<dyn SurfaceProvider>>,
}

impl DesktopWorldService {
    #[must_use]
    pub fn new(world_id: WorldId) -> Self {
        Self {
            world_id,
            snapshot: None,
            surface_providers: Vec::new(),
        }
    }

    pub fn register_surface_provider(&mut self, provider: Box<dyn SurfaceProvider>) {
        self.surface_providers.push(provider);
    }

    #[must_use]
    pub fn snapshot(&self) -> Option<&DesktopWorldSnapshot> {
        self.snapshot.as_ref()
    }

    pub fn apply_observation(
        &mut self,
        observation: DesktopObservationBatch,
    ) -> Result<DesktopWorldDiff, DesktopWorldError> {
        let previous_revision = self
            .snapshot
            .as_ref()
            .map_or(WorldRevision::new(0), |snapshot| snapshot.revision);

        if observation.sequence <= previous_revision {
            return Err(DesktopWorldError::StaleObservation {
                current: previous_revision,
                incoming: observation.sequence,
            });
        }

        let mut next = DesktopWorldSnapshot {
            world_id: self.world_id,
            revision: observation.sequence,
            observed_at: observation.observed_at,
            coordinate_space: observation.coordinate_space,
            capabilities: observation.capabilities,
            virtual_desktop_bounds: observation.monitors.virtual_desktop_bounds,
            monitors: observation.monitors.monitors,
            workspaces: observation.workspaces,
            windows: observation.windows.windows,
            cursor: observation.cursor,
            taskbar_or_dock: observation.taskbar.taskbar_or_dock,
            surfaces: Vec::new(),
            obstacles: observation.obstacles,
            active_window_id: observation.windows.active_window_id,
            active_application: observation.windows.active_application,
        };

        for provider in &self.surface_providers {
            let surfaces = provider.collect_surfaces(&next).map_err(|error| {
                DesktopWorldError::SurfaceProviderFailure {
                    provider_id: provider.provider_id().to_owned(),
                    message: error.to_string(),
                }
            })?;

            next.surfaces.extend(surfaces);
        }

        if let Some(previous) = self.snapshot.as_ref() {
            preserve_unchanged_surface_revisions(previous, &mut next);
        }

        let diff = diff_snapshots(self.snapshot.as_ref(), &next);
        self.snapshot = Some(next);

        Ok(diff)
    }

    #[must_use]
    pub fn current_revision(&self) -> WorldRevision {
        self.snapshot
            .as_ref()
            .map_or(WorldRevision::new(0), |snapshot| snapshot.revision)
    }
}

/// Keep the revision at the last semantic Surface change.
///
/// Surface providers rebuild descriptors from every World observation. Their
/// generated `revision` naturally follows the World revision, but that field
/// alone must not turn an unchanged Surface into `SurfaceUpdated`.
fn preserve_unchanged_surface_revisions(
    previous: &DesktopWorldSnapshot,
    current: &mut DesktopWorldSnapshot,
) {
    for surface in &mut current.surfaces {
        let Some(old) = previous.surface(surface.id) else {
            continue;
        };

        let incoming_revision = surface.revision;
        surface.revision = old.revision;

        if surface != old {
            surface.revision = incoming_revision;
        }
    }
}

fn diff_snapshots(
    previous: Option<&DesktopWorldSnapshot>,
    current: &DesktopWorldSnapshot,
) -> DesktopWorldDiff {
    let previous_revision = previous.map_or(WorldRevision::new(0), |snapshot| snapshot.revision);

    let mut changes = Vec::new();

    if let Some(previous) = previous {
        diff_windows(previous, current, &mut changes);
        diff_surfaces(previous, current, &mut changes);

        if previous.active_window_id != current.active_window_id {
            changes.push(DesktopWorldChange::ActiveWindowChanged {
                previous: previous.active_window_id,
                current: current.active_window_id,
            });
        }

        if previous.monitors != current.monitors
            || previous.virtual_desktop_bounds != current.virtual_desktop_bounds
        {
            changes.push(DesktopWorldChange::MonitorLayoutChanged);
        }

        if previous.cursor != current.cursor {
            changes.push(DesktopWorldChange::CursorChanged);
        }

        if previous.taskbar_or_dock != current.taskbar_or_dock {
            changes.push(DesktopWorldChange::TaskbarChanged);
        }

        if previous.capabilities != current.capabilities {
            changes.push(DesktopWorldChange::CapabilitiesChanged);
        }
    } else {
        changes.extend(
            current
                .windows
                .iter()
                .map(|window| DesktopWorldChange::Window {
                    window_id: window.id,
                    kind: WindowChangeKind::Added,
                }),
        );

        changes.extend(
            current
                .surfaces
                .iter()
                .map(|surface| DesktopWorldChange::SurfaceCreated {
                    surface_id: surface.id,
                }),
        );

        if current.active_window_id.is_some() {
            changes.push(DesktopWorldChange::ActiveWindowChanged {
                previous: None,
                current: current.active_window_id,
            });
        }
    }

    DesktopWorldDiff {
        previous_revision,
        revision: current.revision,
        changes,
    }
}

fn diff_windows(
    previous: &DesktopWorldSnapshot,
    current: &DesktopWorldSnapshot,
    changes: &mut Vec<DesktopWorldChange>,
) {
    for window in &current.windows {
        match previous.window(window.id) {
            None => changes.push(DesktopWorldChange::Window {
                window_id: window.id,
                kind: WindowChangeKind::Added,
            }),
            Some(old) => {
                if old.bounds.origin != window.bounds.origin {
                    changes.push(DesktopWorldChange::Window {
                        window_id: window.id,
                        kind: WindowChangeKind::Moved,
                    });
                }

                if old.bounds.size != window.bounds.size {
                    changes.push(DesktopWorldChange::Window {
                        window_id: window.id,
                        kind: WindowChangeKind::Resized,
                    });
                }

                if old.minimized != window.minimized {
                    changes.push(DesktopWorldChange::Window {
                        window_id: window.id,
                        kind: if window.minimized {
                            WindowChangeKind::Minimized
                        } else {
                            WindowChangeKind::Restored
                        },
                    });
                }
            }
        }
    }

    for window in &previous.windows {
        if current.window(window.id).is_none() {
            changes.push(DesktopWorldChange::Window {
                window_id: window.id,
                kind: WindowChangeKind::Removed,
            });
        }
    }
}

fn diff_surfaces(
    previous: &DesktopWorldSnapshot,
    current: &DesktopWorldSnapshot,
    changes: &mut Vec<DesktopWorldChange>,
) {
    for surface in &current.surfaces {
        match previous.surface(surface.id) {
            None => changes.push(DesktopWorldChange::SurfaceCreated {
                surface_id: surface.id,
            }),
            Some(old) if old != surface => changes.push(DesktopWorldChange::SurfaceUpdated {
                surface_id: surface.id,
            }),
            Some(_) => {}
        }
    }

    for surface in &previous.surfaces {
        if current.surface(surface.id).is_none() {
            changes.push(DesktopWorldChange::SurfaceRemoved {
                surface_id: surface.id,
            });
        }
    }
}
