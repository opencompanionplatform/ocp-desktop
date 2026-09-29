use crate::{
    event_type_for_window_change, surface_descriptor_for_event, window_descriptor_for_event,
    ActiveWindowChangedEventPayload, CapabilitiesChangedEventPayload, CursorChangedEventPayload,
    MonitorLayoutChangedEventPayload, RuntimeHealth, RuntimeHealthSnapshot, SurfaceEventKind,
    SurfaceEventPayload, TaskbarChangedEventPayload, WindowEventKind, WindowEventPayload,
    WorldLifecycleEventPayload, WorldObservationFailurePayload, WorldRuntimeConfig,
    WorldRuntimeError, WorldRuntimeSummary, ACTIVE_WINDOW_CHANGED, CAPABILITIES_CHANGED,
    CURSOR_CHANGED, MONITOR_LAYOUT_CHANGED, SURFACE_CREATED, SURFACE_REMOVED, SURFACE_UPDATED,
    TASKBAR_CHANGED, WORLD_CHANGED, WORLD_CREATED, WORLD_OBSERVATION_FAILED, WORLD_UPDATED,
};
use ocp_desktop_world::{
    DesktopWorldChange, DesktopWorldDiff, DesktopWorldProvider, DesktopWorldService,
    DesktopWorldSnapshot, SurfaceProvider,
};
use ocp_event_bus::InProcessBus;
use ocp_shared_types::{Envelope, WorldId};
use serde::Serialize;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, RwLock};
use std::thread::{self, JoinHandle};

#[derive(Debug, Clone)]
pub struct WorldRuntimeTick {
    pub snapshot: DesktopWorldSnapshot,
    pub diff: DesktopWorldDiff,
    pub published_events: usize,
}

pub struct WorldRuntime<P> {
    provider: P,
    service: DesktopWorldService,
    bus: InProcessBus,
    config: WorldRuntimeConfig,
    snapshot_store: Arc<RwLock<Option<DesktopWorldSnapshot>>>,
    health: Arc<RwLock<RuntimeHealthSnapshot>>,
    stop_requested: Arc<AtomicBool>,
}

impl<P> WorldRuntime<P>
where
    P: DesktopWorldProvider,
{
    #[must_use]
    pub fn new(
        world_id: WorldId,
        provider: P,
        bus: InProcessBus,
        config: WorldRuntimeConfig,
    ) -> Self {
        Self {
            provider,
            service: DesktopWorldService::new(world_id),
            bus,
            config,
            snapshot_store: Arc::new(RwLock::new(None)),
            health: Arc::new(RwLock::new(RuntimeHealthSnapshot::default())),
            stop_requested: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn register_surface_provider(&mut self, provider: Box<dyn SurfaceProvider>) {
        self.service.register_surface_provider(provider);
    }

    #[must_use]
    pub fn bus(&self) -> InProcessBus {
        self.bus.clone()
    }

    #[must_use]
    pub fn snapshot_store(&self) -> Arc<RwLock<Option<DesktopWorldSnapshot>>> {
        Arc::clone(&self.snapshot_store)
    }

    #[must_use]
    pub fn health_store(&self) -> Arc<RwLock<RuntimeHealthSnapshot>> {
        Arc::clone(&self.health)
    }

    pub fn tick(&mut self) -> Result<WorldRuntimeTick, WorldRuntimeError> {
        let previous_snapshot = self.read_snapshot()?;
        let observation = self.provider.observe()?;
        let diff = self.service.apply_observation(observation)?;
        let snapshot = self
            .service
            .snapshot()
            .cloned()
            .ok_or(WorldRuntimeError::StatePoisoned(
                "world snapshot missing after apply",
            ))?;

        let first_snapshot = diff.previous_revision.value() == 0;
        let mut published_events = 0;

        if first_snapshot {
            published_events += self.publish(
                WORLD_CREATED,
                &WorldLifecycleEventPayload::from_diff(snapshot.world_id, &diff),
            )?;
        } else if self.config.publish_unchanged_updates || !diff.changes.is_empty() {
            published_events += self.publish(
                WORLD_UPDATED,
                &WorldLifecycleEventPayload::from_diff(snapshot.world_id, &diff),
            )?;
        }

        if !diff.changes.is_empty() {
            published_events += self.publish(
                WORLD_CHANGED,
                &WorldLifecycleEventPayload::from_diff(snapshot.world_id, &diff),
            )?;

            for change in &diff.changes {
                published_events +=
                    self.publish_change(&snapshot, previous_snapshot.as_ref(), change)?;
            }
        }

        self.store_snapshot(snapshot.clone())?;
        self.record_success(snapshot.revision)?;

        Ok(WorldRuntimeTick {
            snapshot,
            diff,
            published_events,
        })
    }

    fn publish_change(
        &self,
        snapshot: &DesktopWorldSnapshot,
        previous: Option<&DesktopWorldSnapshot>,
        change: &DesktopWorldChange,
    ) -> Result<usize, WorldRuntimeError> {
        match change {
            DesktopWorldChange::Window { window_id, kind } => self.publish(
                event_type_for_window_change(*kind),
                &WindowEventPayload {
                    world_id: snapshot.world_id,
                    revision: snapshot.revision,
                    window_id: *window_id,
                    event_kind: WindowEventKind::from(*kind),
                    window: window_descriptor_for_event(snapshot, previous, *window_id, *kind),
                },
            ),
            DesktopWorldChange::SurfaceCreated { surface_id } => self.publish(
                SURFACE_CREATED,
                &SurfaceEventPayload {
                    world_id: snapshot.world_id,
                    revision: snapshot.revision,
                    surface_id: *surface_id,
                    event_kind: SurfaceEventKind::Created,
                    surface: surface_descriptor_for_event(
                        snapshot,
                        previous,
                        *surface_id,
                        SurfaceEventKind::Created,
                    ),
                },
            ),
            DesktopWorldChange::SurfaceUpdated { surface_id } => self.publish(
                SURFACE_UPDATED,
                &SurfaceEventPayload {
                    world_id: snapshot.world_id,
                    revision: snapshot.revision,
                    surface_id: *surface_id,
                    event_kind: SurfaceEventKind::Updated,
                    surface: surface_descriptor_for_event(
                        snapshot,
                        previous,
                        *surface_id,
                        SurfaceEventKind::Updated,
                    ),
                },
            ),
            DesktopWorldChange::SurfaceRemoved { surface_id } => self.publish(
                SURFACE_REMOVED,
                &SurfaceEventPayload {
                    world_id: snapshot.world_id,
                    revision: snapshot.revision,
                    surface_id: *surface_id,
                    event_kind: SurfaceEventKind::Removed,
                    surface: surface_descriptor_for_event(
                        snapshot,
                        previous,
                        *surface_id,
                        SurfaceEventKind::Removed,
                    ),
                },
            ),
            DesktopWorldChange::ActiveWindowChanged { previous, current } => self.publish(
                ACTIVE_WINDOW_CHANGED,
                &ActiveWindowChangedEventPayload {
                    world_id: snapshot.world_id,
                    revision: snapshot.revision,
                    previous_window_id: *previous,
                    current_window_id: *current,
                },
            ),
            DesktopWorldChange::MonitorLayoutChanged => self.publish(
                MONITOR_LAYOUT_CHANGED,
                &MonitorLayoutChangedEventPayload {
                    world_id: snapshot.world_id,
                    revision: snapshot.revision,
                    virtual_desktop_bounds: snapshot.virtual_desktop_bounds,
                    monitors: snapshot.monitors.clone(),
                },
            ),
            DesktopWorldChange::CursorChanged => self.publish(
                CURSOR_CHANGED,
                &CursorChangedEventPayload {
                    world_id: snapshot.world_id,
                    revision: snapshot.revision,
                    cursor: snapshot.cursor.clone(),
                },
            ),
            DesktopWorldChange::TaskbarChanged => self.publish(
                TASKBAR_CHANGED,
                &TaskbarChangedEventPayload {
                    world_id: snapshot.world_id,
                    revision: snapshot.revision,
                    taskbar_or_dock: snapshot.taskbar_or_dock.clone(),
                },
            ),
            DesktopWorldChange::CapabilitiesChanged => self.publish(
                CAPABILITIES_CHANGED,
                &CapabilitiesChangedEventPayload {
                    world_id: snapshot.world_id,
                    revision: snapshot.revision,
                    capabilities: snapshot.capabilities,
                },
            ),
        }
    }

    fn publish<T: Serialize>(
        &self,
        event_type: &'static str,
        payload: &T,
    ) -> Result<usize, WorldRuntimeError> {
        let data = serde_json::to_value(payload)?;
        let mut envelope = Envelope::new(event_type, self.config.event_source.clone(), data)
            .map_err(|error| WorldRuntimeError::Event(ocp_event_bus::BusError::Invalid(error)))?;
        envelope.version = crate::WORLD_EVENT_SCHEMA_VERSION.to_owned();
        Ok(self.bus.publish(envelope)?)
    }

    fn publish_failure(
        &self,
        error: &WorldRuntimeError,
        consecutive_failures: u32,
    ) -> Result<usize, WorldRuntimeError> {
        self.publish(
            WORLD_OBSERVATION_FAILED,
            &WorldObservationFailurePayload {
                provider_id: self.provider.provider_id().to_owned(),
                consecutive_failures,
                message: error.to_string(),
            },
        )
    }

    fn read_snapshot(&self) -> Result<Option<DesktopWorldSnapshot>, WorldRuntimeError> {
        let store = self
            .snapshot_store
            .read()
            .map_err(|_| WorldRuntimeError::StatePoisoned("snapshot"))?;
        Ok(store.clone())
    }

    fn store_snapshot(&self, snapshot: DesktopWorldSnapshot) -> Result<(), WorldRuntimeError> {
        let mut store = self
            .snapshot_store
            .write()
            .map_err(|_| WorldRuntimeError::StatePoisoned("snapshot"))?;
        *store = Some(snapshot);
        Ok(())
    }

    fn record_success(
        &self,
        revision: ocp_shared_types::WorldRevision,
    ) -> Result<(), WorldRuntimeError> {
        let mut health = self
            .health
            .write()
            .map_err(|_| WorldRuntimeError::StatePoisoned("health"))?;
        health.status = RuntimeHealth::Running;
        health.completed_ticks = health.completed_ticks.saturating_add(1);
        health.successful_ticks = health.successful_ticks.saturating_add(1);
        health.consecutive_failures = 0;
        health.last_revision = revision;
        health.last_error = None;
        Ok(())
    }

    fn record_failure(&self, message: String) -> Result<u32, WorldRuntimeError> {
        let mut health = self
            .health
            .write()
            .map_err(|_| WorldRuntimeError::StatePoisoned("health"))?;
        health.status = RuntimeHealth::Degraded;
        health.completed_ticks = health.completed_ticks.saturating_add(1);
        health.failed_ticks = health.failed_ticks.saturating_add(1);
        health.consecutive_failures = health.consecutive_failures.saturating_add(1);
        health.last_error = Some(message);
        Ok(health.consecutive_failures)
    }

    fn mark_stopping(&self) -> Result<(), WorldRuntimeError> {
        let mut health = self
            .health
            .write()
            .map_err(|_| WorldRuntimeError::StatePoisoned("health"))?;
        health.status = RuntimeHealth::Stopping;
        Ok(())
    }

    fn mark_stopped(&self) -> Result<WorldRuntimeSummary, WorldRuntimeError> {
        let mut health = self
            .health
            .write()
            .map_err(|_| WorldRuntimeError::StatePoisoned("health"))?;
        health.status = RuntimeHealth::Stopped;
        Ok(WorldRuntimeSummary {
            completed_ticks: health.completed_ticks,
            successful_ticks: health.successful_ticks,
            failed_ticks: health.failed_ticks,
            final_revision: health.last_revision,
            stopped_by_request: self.stop_requested.load(Ordering::Acquire),
        })
    }
}

impl<P> WorldRuntime<P>
where
    P: DesktopWorldProvider + 'static,
{
    pub fn spawn(mut self) -> WorldRuntimeHandle {
        let stop_requested = Arc::clone(&self.stop_requested);
        let snapshot_store = Arc::clone(&self.snapshot_store);
        let health = Arc::clone(&self.health);

        let join = thread::spawn(move || {
            loop {
                if self.stop_requested.load(Ordering::Acquire) {
                    self.mark_stopping()?;
                    break;
                }

                match self.tick() {
                    Ok(_) => {}
                    Err(error) => {
                        let consecutive_failures = self.record_failure(error.to_string())?;
                        let _ = self.publish_failure(&error, consecutive_failures);

                        if self.config.max_consecutive_failures > 0
                            && consecutive_failures >= self.config.max_consecutive_failures
                        {
                            self.mark_stopping()?;
                            return Err(WorldRuntimeError::FailureLimitReached {
                                consecutive_failures,
                                last_error: error.to_string(),
                            });
                        }
                    }
                }

                thread::park_timeout(self.config.poll_interval);
            }

            self.mark_stopped()
        });

        WorldRuntimeHandle {
            stop_requested,
            snapshot_store,
            health,
            join: Some(join),
        }
    }
}

pub struct WorldRuntimeHandle {
    stop_requested: Arc<AtomicBool>,
    snapshot_store: Arc<RwLock<Option<DesktopWorldSnapshot>>>,
    health: Arc<RwLock<RuntimeHealthSnapshot>>,
    join: Option<JoinHandle<Result<WorldRuntimeSummary, WorldRuntimeError>>>,
}

impl WorldRuntimeHandle {
    #[must_use]
    pub fn snapshot_store(&self) -> Arc<RwLock<Option<DesktopWorldSnapshot>>> {
        Arc::clone(&self.snapshot_store)
    }

    pub fn request_stop(&self) {
        self.stop_requested.store(true, Ordering::Release);
    }

    pub fn snapshot(&self) -> Result<Option<DesktopWorldSnapshot>, WorldRuntimeError> {
        let snapshot = self
            .snapshot_store
            .read()
            .map_err(|_| WorldRuntimeError::StatePoisoned("snapshot"))?;
        Ok(snapshot.clone())
    }

    pub fn health(&self) -> Result<RuntimeHealthSnapshot, WorldRuntimeError> {
        let health = self
            .health
            .read()
            .map_err(|_| WorldRuntimeError::StatePoisoned("health"))?;
        Ok(health.clone())
    }

    pub fn wait(mut self) -> Result<WorldRuntimeSummary, WorldRuntimeError> {
        let join = self.join.take().ok_or(WorldRuntimeError::ThreadPanicked)?;
        join.join().map_err(|_| WorldRuntimeError::ThreadPanicked)?
    }

    pub fn stop_and_wait(self) -> Result<WorldRuntimeSummary, WorldRuntimeError> {
        self.request_stop();
        self.wait()
    }
}

impl Drop for WorldRuntimeHandle {
    fn drop(&mut self) {
        self.stop_requested.store(true, Ordering::Release);
    }
}
