use ocp_shared_types::WorldRevision;
use serde::{Deserialize, Serialize};

use super::{SurfaceRegistryId, SurfaceRegistrySnapshot};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "change_type")]
pub enum SurfaceChange {
    Added { surface_id: SurfaceRegistryId },
    Updated { surface_id: SurfaceRegistryId },
    Removed { surface_id: SurfaceRegistryId },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SurfaceRegistryDiff {
    pub previous_world_revision: WorldRevision,
    pub world_revision: WorldRevision,
    pub changes: Vec<SurfaceChange>,
}

impl SurfaceRegistryDiff {
    #[must_use]
    pub fn between(
        previous: Option<&SurfaceRegistrySnapshot>,
        current: &SurfaceRegistrySnapshot,
    ) -> Self {
        let mut changes = Vec::new();

        for (id, surface) in &current.surfaces {
            match previous.and_then(|snapshot| snapshot.surface(id)) {
                None => changes.push(SurfaceChange::Added {
                    surface_id: id.clone(),
                }),
                Some(old) if old.surface_revision != surface.surface_revision => {
                    changes.push(SurfaceChange::Updated {
                        surface_id: id.clone(),
                    });
                }
                Some(_) => {}
            }
        }

        if let Some(previous) = previous {
            for id in previous.surfaces.keys() {
                if !current.surfaces.contains_key(id) {
                    changes.push(SurfaceChange::Removed {
                        surface_id: id.clone(),
                    });
                }
            }
        }

        Self {
            previous_world_revision: previous
                .map_or(WorldRevision::new(0), |snapshot| snapshot.world_revision),
            world_revision: current.world_revision,
            changes,
        }
    }
}
