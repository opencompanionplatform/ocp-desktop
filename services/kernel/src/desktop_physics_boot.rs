use crate::desktop_physics_host::{
    KernelDesktopPhysicsConfig, KernelDesktopPhysicsError, KernelDesktopPhysicsHealth,
    KernelDesktopPhysicsHost, KernelDesktopPhysicsState,
};
use ocp_desktop_physics::{PhysicsBody, PhysicsBodyId, PhysicsCommand};
use ocp_desktop_world::DesktopWorldSnapshot;
use ocp_event_bus::InProcessBus;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex, RwLock,
};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KernelDesktopPhysicsLoopConfig {
    pub tick_interval: Duration,
}

impl Default for KernelDesktopPhysicsLoopConfig {
    fn default() -> Self {
        Self {
            // Poll slightly faster than the 120 Hz fixed Physics step. The
            // accumulator remains authoritative while the native presentation
            // host can receive a fresh canonical position on every display
            // refresh instead of visibly stepping at ~60 Hz.
            tick_interval: Duration::from_millis(8),
        }
    }
}

impl KernelDesktopPhysicsLoopConfig {
    #[must_use]
    pub fn from_env() -> Self {
        let defaults = Self::default();

        Self {
            tick_interval: Duration::from_millis(env_u64(
                "OCP_DESKTOP_PHYSICS_TICK_MS",
                u64::try_from(defaults.tick_interval.as_millis()).unwrap_or(8),
            )),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KernelDesktopPhysicsLoopHealth {
    pub host: KernelDesktopPhysicsHealth,
    pub loop_iterations: u64,
    pub ticks_without_world: u64,
    pub failed_ticks: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct LoopCounters {
    loop_iterations: u64,
    ticks_without_world: u64,
    failed_ticks: u64,
}

#[derive(Clone)]
pub struct KernelDesktopPhysicsHandle {
    host: Arc<Mutex<KernelDesktopPhysicsHost>>,
    snapshot_store: Arc<RwLock<Option<DesktopWorldSnapshot>>>,
}

impl KernelDesktopPhysicsHandle {
    pub fn insert_body(
        &self,
        body: PhysicsBody,
    ) -> Result<PhysicsBodyId, KernelDesktopPhysicsError> {
        self.host
            .lock()
            .map_err(|_| KernelDesktopPhysicsError::MissingWorldSnapshot)?
            .insert_body(body)
    }

    pub fn remove_body(
        &self,
        body_id: PhysicsBodyId,
    ) -> Result<PhysicsBody, KernelDesktopPhysicsError> {
        self.host
            .lock()
            .map_err(|_| KernelDesktopPhysicsError::MissingWorldSnapshot)?
            .remove_body(body_id)
    }

    pub fn enqueue(
        &self,
        body_id: PhysicsBodyId,
        command: PhysicsCommand,
    ) -> Result<(), KernelDesktopPhysicsError> {
        self.host
            .lock()
            .map_err(|_| KernelDesktopPhysicsError::MissingWorldSnapshot)?
            .enqueue(body_id, command)
    }

    #[must_use]
    pub fn body(&self, body_id: PhysicsBodyId) -> Option<PhysicsBody> {
        self.host.lock().ok().and_then(|host| host.body(body_id))
    }

    pub fn replace_body(
        &self,
        body_id: PhysicsBodyId,
        body: PhysicsBody,
    ) -> Result<(), KernelDesktopPhysicsError> {
        self.host
            .lock()
            .map_err(|_| KernelDesktopPhysicsError::MissingWorldSnapshot)?
            .replace_body(body_id, body)
    }

    #[must_use]
    pub fn state(&self) -> KernelDesktopPhysicsState {
        self.host
            .lock()
            .map_or(KernelDesktopPhysicsState::Degraded, |host| host.state())
    }

    #[must_use]
    pub fn latest_world_snapshot(&self) -> Option<DesktopWorldSnapshot> {
        self.snapshot_store
            .read()
            .ok()
            .and_then(|snapshot| snapshot.clone())
    }

    #[must_use]
    pub fn health(&self) -> KernelDesktopPhysicsHealth {
        self.host.lock().map_or(
            KernelDesktopPhysicsHealth {
                state: KernelDesktopPhysicsState::Degraded,
                completed_ticks: 0,
                published_events: 0,
                rejected_commands: 0,
                body_count: 0,
            },
            |host| host.health(),
        )
    }
}

pub struct KernelDesktopPhysicsLoop {
    host: Arc<Mutex<KernelDesktopPhysicsHost>>,
    snapshot_store: Arc<RwLock<Option<DesktopWorldSnapshot>>>,
    counters: Arc<Mutex<LoopCounters>>,
    stop_requested: Arc<AtomicBool>,
    join: Option<JoinHandle<()>>,
}

impl KernelDesktopPhysicsLoop {
    #[must_use]
    pub fn handle(&self) -> KernelDesktopPhysicsHandle {
        KernelDesktopPhysicsHandle {
            host: Arc::clone(&self.host),
            snapshot_store: Arc::clone(&self.snapshot_store),
        }
    }

    pub fn start(
        bus: InProcessBus,
        host_config: KernelDesktopPhysicsConfig,
        loop_config: KernelDesktopPhysicsLoopConfig,
        snapshot_store: Arc<RwLock<Option<DesktopWorldSnapshot>>>,
    ) -> Result<Self, KernelDesktopPhysicsError> {
        let host = Arc::new(Mutex::new(KernelDesktopPhysicsHost::new(bus, host_config)?));
        let counters = Arc::new(Mutex::new(LoopCounters {
            loop_iterations: 0,
            ticks_without_world: 0,
            failed_ticks: 0,
        }));
        let stop_requested = Arc::new(AtomicBool::new(false));

        let thread_host = Arc::clone(&host);
        let thread_snapshot_store = Arc::clone(&snapshot_store);
        let thread_counters = Arc::clone(&counters);
        let thread_stop = Arc::clone(&stop_requested);

        let join = thread::spawn(move || {
            let mut previous_tick = Instant::now();

            while !thread_stop.load(Ordering::Acquire) {
                thread::sleep(loop_config.tick_interval);

                let now = Instant::now();
                let delta = now.saturating_duration_since(previous_tick);
                previous_tick = now;

                if let Ok(mut value) = thread_counters.lock() {
                    value.loop_iterations += 1;
                }

                let snapshot = match thread_snapshot_store.read() {
                    Ok(store) => store.clone(),
                    Err(_) => {
                        if let Ok(mut value) = thread_counters.lock() {
                            value.failed_ticks += 1;
                        }
                        continue;
                    }
                };

                let Some(snapshot) = snapshot else {
                    if let Ok(mut value) = thread_counters.lock() {
                        value.ticks_without_world += 1;
                    }
                    continue;
                };

                let result = match thread_host.lock() {
                    Ok(mut value) => {
                        if value.state() == KernelDesktopPhysicsState::Disabled {
                            break;
                        }
                        value.tick(delta, &snapshot)
                    }
                    Err(_) => break,
                };

                if result.is_err() {
                    if let Ok(mut value) = thread_counters.lock() {
                        value.failed_ticks += 1;
                    }
                }
            }
        });

        Ok(Self {
            host,
            snapshot_store,
            counters,
            stop_requested,
            join: Some(join),
        })
    }

    #[must_use]
    pub fn state(&self) -> KernelDesktopPhysicsState {
        self.host
            .lock()
            .map_or(KernelDesktopPhysicsState::Degraded, |host| host.state())
    }

    pub fn insert_body(
        &self,
        body: PhysicsBody,
    ) -> Result<PhysicsBodyId, KernelDesktopPhysicsError> {
        self.host
            .lock()
            .map_err(|_| KernelDesktopPhysicsError::MissingWorldSnapshot)?
            .insert_body(body)
    }

    pub fn remove_body(
        &self,
        body_id: PhysicsBodyId,
    ) -> Result<PhysicsBody, KernelDesktopPhysicsError> {
        self.host
            .lock()
            .map_err(|_| KernelDesktopPhysicsError::MissingWorldSnapshot)?
            .remove_body(body_id)
    }

    pub fn enqueue(
        &self,
        body_id: PhysicsBodyId,
        command: PhysicsCommand,
    ) -> Result<(), KernelDesktopPhysicsError> {
        self.host
            .lock()
            .map_err(|_| KernelDesktopPhysicsError::MissingWorldSnapshot)?
            .enqueue(body_id, command)
    }

    #[must_use]
    pub fn health(&self) -> KernelDesktopPhysicsLoopHealth {
        let host = self.host.lock().map_or(
            KernelDesktopPhysicsHealth {
                state: KernelDesktopPhysicsState::Degraded,
                completed_ticks: 0,
                published_events: 0,
                rejected_commands: 0,
                body_count: 0,
            },
            |host| host.health(),
        );
        let counters = self.counters.lock().map_or(
            LoopCounters {
                loop_iterations: 0,
                ticks_without_world: 0,
                failed_ticks: 1,
            },
            |value| *value,
        );

        KernelDesktopPhysicsLoopHealth {
            host,
            loop_iterations: counters.loop_iterations,
            ticks_without_world: counters.ticks_without_world,
            failed_ticks: counters.failed_ticks,
        }
    }

    pub fn shutdown(
        &mut self,
    ) -> Result<KernelDesktopPhysicsLoopHealth, KernelDesktopPhysicsError> {
        self.stop_requested.store(true, Ordering::Release);

        if let Some(join) = self.join.take() {
            let _ = join.join();
        }

        self.host
            .lock()
            .map_err(|_| KernelDesktopPhysicsError::MissingWorldSnapshot)?
            .shutdown()?;

        Ok(self.health())
    }
}

impl Drop for KernelDesktopPhysicsLoop {
    fn drop(&mut self) {
        self.stop_requested.store(true, Ordering::Release);
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
        if let Ok(mut host) = self.host.lock() {
            let _ = host.shutdown();
        }
    }
}

fn env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|value| value.trim().parse().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default)
}
