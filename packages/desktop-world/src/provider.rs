use crate::{DesktopObservationBatch, DesktopWorldError, DesktopWorldSnapshot};
use ocp_shared_types::SurfaceDescriptor;

pub trait DesktopWorldProvider: Send + Sync {
    fn provider_id(&self) -> &'static str;

    fn observe(&mut self) -> Result<DesktopObservationBatch, DesktopWorldError>;
}

pub trait SurfaceProvider: Send + Sync {
    fn provider_id(&self) -> &'static str;

    fn collect_surfaces(
        &self,
        world: &DesktopWorldSnapshot,
    ) -> Result<Vec<SurfaceDescriptor>, DesktopWorldError>;
}
