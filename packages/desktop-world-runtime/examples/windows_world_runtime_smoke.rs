use ocp_desktop_sensors::{DesktopSurfaceProvider, SensorWorldProvider, WindowSurfaceProvider};
use ocp_desktop_sensors_windows::WindowsDesktopSensors;
use ocp_desktop_world_runtime::{WorldRuntime, WorldRuntimeConfig};
use ocp_event_bus::InProcessBus;
use ocp_shared_types::WorldId;
use std::time::Duration;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let sensors = WindowsDesktopSensors::new();
    let provider = SensorWorldProvider::new("windows.desktop-world", sensors);
    let bus = InProcessBus::new();
    let events = bus.subscribe("ocp.world.");
    let mut runtime = WorldRuntime::new(
        WorldId::new(),
        provider,
        bus,
        WorldRuntimeConfig {
            poll_interval: Duration::from_millis(250),
            ..WorldRuntimeConfig::default()
        },
    );

    runtime.register_surface_provider(Box::new(WindowSurfaceProvider::default()));
    runtime.register_surface_provider(Box::new(DesktopSurfaceProvider::default()));

    let tick = runtime.tick()?;
    println!(
        "Desktop World revision {}: {} windows, {} surfaces, {} changes",
        tick.snapshot.revision.value(),
        tick.snapshot.windows.len(),
        tick.snapshot.surfaces.len(),
        tick.diff.changes.len(),
    );

    while let Ok(event) = events.try_recv() {
        println!("{}", event.event_type);
    }

    Ok(())
}
