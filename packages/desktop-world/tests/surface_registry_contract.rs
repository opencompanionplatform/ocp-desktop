use ocp_desktop_world::{
    SurfaceChange, SurfaceEligibilityPolicy, SurfaceFilter, SurfaceGeometryQuery, SurfaceKindV2,
    SurfaceRegistryBuilder, SurfaceRegistryId,
};
use ocp_shared_types::{Point2, WorldRevision};
use serde_json::{json, Value};

fn world(windows: Value) -> Value {
    json!({
        "revision": 1,
        "monitors": [{
            "id": "primary",
            "bounds": {
                "origin": {"x": -1920.0, "y": 0.0},
                "size": {"width": 3840.0, "height": 1080.0}
            },
            "workArea": {
                "origin": {"x": -1920.0, "y": 0.0},
                "size": {"width": 3840.0, "height": 1040.0}
            }
        }],
        "windows": windows,
        "taskbarOrDock": {
            "entityId": "taskbar-primary",
            "bounds": {
                "origin": {"x": -1920.0, "y": 1040.0},
                "size": {"width": 3840.0, "height": 40.0}
            }
        }
    })
}

fn app_window(id: &str, x: f32, y: f32, width: f32) -> Value {
    json!({
        "id": id,
        "applicationId": "com.example.editor",
        "title": "Editor",
        "visible": true,
        "minimized": false,
        "zOrder": 7,
        "bounds": {
            "origin": {"x": x, "y": y},
            "size": {"width": width, "height": 600.0}
        }
    })
}

#[test]
fn creates_monitor_floor_window_top_and_taskbar_top() {
    let builder = SurfaceRegistryBuilder::default();
    let (snapshot, diff) = builder
        .build_from_value(
            None,
            WorldRevision::new(1),
            &world(json!([app_window("window-a", 100.0, 200.0, 900.0)])),
        )
        .unwrap();

    assert!(snapshot
        .surface(&SurfaceRegistryId::monitor_floor("primary"))
        .is_some());
    assert!(snapshot
        .surface(&SurfaceRegistryId::window_top("window-a"))
        .is_some());
    assert!(snapshot
        .surface(&SurfaceRegistryId::taskbar_top("taskbar-primary"))
        .is_some());
    assert_eq!(diff.changes.len(), 3);
}

#[test]
fn unchanged_window_preserves_surface_revision() {
    let builder = SurfaceRegistryBuilder::default();
    let source = world(json!([app_window("window-a", 100.0, 200.0, 900.0)]));
    let (first, _) = builder
        .build_from_value(None, WorldRevision::new(1), &source)
        .unwrap();
    let (second, diff) = builder
        .build_from_value(Some(&first), WorldRevision::new(2), &source)
        .unwrap();

    let id = SurfaceRegistryId::window_top("window-a");
    assert_eq!(
        first.surface(&id).unwrap().surface_revision,
        second.surface(&id).unwrap().surface_revision
    );
    assert!(diff.changes.is_empty());
}

#[test]
fn moved_window_keeps_id_and_updates_geometry() {
    let builder = SurfaceRegistryBuilder::default();
    let (first, _) = builder
        .build_from_value(
            None,
            WorldRevision::new(1),
            &world(json!([app_window("window-a", 100.0, 200.0, 900.0)])),
        )
        .unwrap();
    let (second, diff) = builder
        .build_from_value(
            Some(&first),
            WorldRevision::new(2),
            &world(json!([app_window("window-a", 400.0, 250.0, 900.0)])),
        )
        .unwrap();

    let id = SurfaceRegistryId::window_top("window-a");
    assert_eq!(
        second.surface(&id).unwrap().start,
        Point2::new(400.0, 250.0)
    );
    assert!(diff
        .changes
        .contains(&SurfaceChange::Updated { surface_id: id }));
}

#[test]
fn resized_window_updates_endpoint_without_changing_id() {
    let builder = SurfaceRegistryBuilder::default();
    let (first, _) = builder
        .build_from_value(
            None,
            WorldRevision::new(1),
            &world(json!([app_window("window-a", 100.0, 200.0, 900.0)])),
        )
        .unwrap();
    let (second, _) = builder
        .build_from_value(
            Some(&first),
            WorldRevision::new(2),
            &world(json!([app_window("window-a", 100.0, 200.0, 1200.0)])),
        )
        .unwrap();

    let id = SurfaceRegistryId::window_top("window-a");
    assert_eq!(second.surface(&id).unwrap().end.x, 1300.0);
}

#[test]
fn closed_window_removes_surface() {
    let builder = SurfaceRegistryBuilder::default();
    let (first, _) = builder
        .build_from_value(
            None,
            WorldRevision::new(1),
            &world(json!([app_window("window-a", 100.0, 200.0, 900.0)])),
        )
        .unwrap();
    let (_second, diff) = builder
        .build_from_value(Some(&first), WorldRevision::new(2), &world(json!([])))
        .unwrap();

    assert!(diff.changes.contains(&SurfaceChange::Removed {
        surface_id: SurfaceRegistryId::window_top("window-a")
    }));
}

#[test]
fn minimized_window_is_not_eligible() {
    let mut window = app_window("window-a", 100.0, 200.0, 900.0);
    window["minimized"] = json!(true);
    let (snapshot, _) = SurfaceRegistryBuilder::default()
        .build_from_value(None, WorldRevision::new(1), &world(json!([window])))
        .unwrap();
    assert!(snapshot
        .surface(&SurfaceRegistryId::window_top("window-a"))
        .is_none());
}

#[test]
fn ocp_runtime_windows_are_excluded() {
    let runtime = json!({
        "id": "ocp-overlay",
        "applicationId": "ocp-desktop-runtime",
        "title": "OCP Desktop Runtime",
        "visible": true,
        "minimized": false,
        "bounds": {
            "origin": {"x": 0.0, "y": 0.0},
            "size": {"width": 1280.0, "height": 800.0}
        }
    });
    let (snapshot, _) = SurfaceRegistryBuilder::default()
        .build_from_value(None, WorldRevision::new(1), &world(json!([runtime])))
        .unwrap();
    assert!(snapshot
        .surface(&SurfaceRegistryId::window_top("ocp-overlay"))
        .is_none());
}

#[test]
fn duplicate_observation_does_not_duplicate_surface() {
    let source = world(json!([app_window("window-a", 100.0, 200.0, 900.0)]));
    let builder = SurfaceRegistryBuilder::default();
    let (first, _) = builder
        .build_from_value(None, WorldRevision::new(1), &source)
        .unwrap();
    let (second, _) = builder
        .build_from_value(Some(&first), WorldRevision::new(2), &source)
        .unwrap();
    assert_eq!(first.len(), second.len());
}

#[test]
fn geometry_query_projects_onto_segment_not_midpoint() {
    let (snapshot, _) = SurfaceRegistryBuilder::default()
        .build_from_value(
            None,
            WorldRevision::new(1),
            &world(json!([app_window("window-a", 100.0, 200.0, 900.0)])),
        )
        .unwrap();
    let query = SurfaceGeometryQuery::new(&snapshot);
    let projection = query
        .nearest_surface(
            Point2::new(850.0, 180.0),
            &SurfaceFilter {
                kinds: vec![SurfaceKindV2::WindowTop],
                eligible_only: true,
                ..SurfaceFilter::default()
            },
        )
        .unwrap();
    assert_eq!(projection.point, Point2::new(850.0, 200.0));
    assert_eq!(projection.distance, 20.0);
}

#[test]
fn surface_below_respects_negative_monitor_coordinates() {
    let (snapshot, _) = SurfaceRegistryBuilder::default()
        .build_from_value(None, WorldRevision::new(1), &world(json!([])))
        .unwrap();
    let projection = SurfaceGeometryQuery::new(&snapshot)
        .surface_below(
            Point2::new(-1000.0, 1000.0),
            100.0,
            &SurfaceFilter {
                kinds: vec![SurfaceKindV2::MonitorFloor],
                eligible_only: true,
                ..SurfaceFilter::default()
            },
        )
        .unwrap();
    assert_eq!(projection.point.y, 1040.0);
}

#[test]
fn policy_is_configurable_without_changing_geometry_model() {
    let mut policy = SurfaceEligibilityPolicy::default();
    policy.excluded_application_prefixes.clear();
    policy.excluded_title_fragments.clear();
    let runtime = json!({
        "id": "ocp-overlay",
        "applicationId": "ocp-desktop-runtime",
        "title": "OCP Desktop Runtime",
        "visible": true,
        "minimized": false,
        "bounds": {
            "origin": {"x": 0.0, "y": 0.0},
            "size": {"width": 1280.0, "height": 800.0}
        }
    });
    let (snapshot, _) = SurfaceRegistryBuilder::new(policy)
        .build_from_value(None, WorldRevision::new(1), &world(json!([runtime])))
        .unwrap();
    assert!(snapshot
        .surface(&SurfaceRegistryId::window_top("ocp-overlay"))
        .is_some());
}
