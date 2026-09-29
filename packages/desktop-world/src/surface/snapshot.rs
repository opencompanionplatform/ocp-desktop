use ocp_shared_types::WorldRevision;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

use super::{SurfaceRegistryDiff, SurfaceRegistryId, SurfaceSegment};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SurfaceRegistrySnapshot {
    pub world_revision: WorldRevision,
    pub surfaces: BTreeMap<SurfaceRegistryId, SurfaceSegment>,
}

impl SurfaceRegistrySnapshot {
    #[must_use]
    pub fn empty() -> Self {
        Self {
            world_revision: WorldRevision::new(0),
            surfaces: BTreeMap::new(),
        }
    }

    #[must_use]
    pub fn surface(&self, id: &SurfaceRegistryId) -> Option<&SurfaceSegment> {
        self.surfaces.get(id)
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.surfaces.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.surfaces.is_empty()
    }

    #[must_use]
    pub fn reconcile(
        previous: Option<&Self>,
        world_revision: WorldRevision,
        generated: impl IntoIterator<Item = SurfaceSegment>,
    ) -> (Self, SurfaceRegistryDiff) {
        let mut surfaces = BTreeMap::new();

        for mut surface in generated {
            surface.world_revision = world_revision;
            if let Some(old) = previous.and_then(|snapshot| snapshot.surface(&surface.id)) {
                if surface.semantic_eq(old) {
                    surface.surface_revision = old.surface_revision;
                } else {
                    surface.surface_revision = world_revision;
                }
            } else {
                surface.surface_revision = world_revision;
            }
            surfaces.insert(surface.id.clone(), surface);
        }

        let snapshot = Self {
            world_revision,
            surfaces,
        };
        let diff = SurfaceRegistryDiff::between(previous, &snapshot);
        (snapshot, diff)
    }
}
