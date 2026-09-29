extends Node
class_name ClickThroughController

signal polygon_updated(point_count: int)

@export var enabled: bool = false
@export var physical_scale: float = 2.0
@export var padding: float = 10.0

var window: Window
var _interactive_rects: Array[Rect2] = []
var _last_polygon := PackedVector2Array()

func bind(target_window: Window = null) -> void:
    window = target_window if target_window != null else get_window()
    apply()

func set_enabled(value: bool) -> void:
    enabled = value
    apply()

func set_interactive_rects(rects: Array[Rect2]) -> void:
    _interactive_rects = rects.duplicate()
    apply()

func update_from_controls(controls: Array[Control], extra_rects: Array[Rect2] = []) -> void:
    var rects: Array[Rect2] = []
    for control in controls:
        if control != null and control.visible:
            rects.append(control.get_global_rect())
    rects.append_array(extra_rects)
    set_interactive_rects(rects)

func apply() -> void:
    if window == null:
        return
    if not enabled:
        window.mouse_passthrough_polygon = PackedVector2Array()
        _last_polygon = PackedVector2Array()
        return
    var merged: Array[Rect2] = _merge_rects(_interactive_rects)
    if merged.size() == 0:
        window.mouse_passthrough_polygon = PackedVector2Array()
        return
    # Godot accepts one polygon. Use the union bounding rectangle deliberately;
    # this is stable and is updated only after explicit events, never every frame.
    var union_rect: Rect2 = merged[0]
    for index in range(1, merged.size()):
        union_rect = union_rect.merge(merged[index])
    union_rect = union_rect.grow(padding)
    var scale_value: float = maxf(physical_scale, 1.0)
    var polygon: PackedVector2Array = PackedVector2Array([
        union_rect.position * scale_value,
        Vector2(union_rect.end.x, union_rect.position.y) * scale_value,
        union_rect.end * scale_value,
        Vector2(union_rect.position.x, union_rect.end.y) * scale_value,
    ])
    if polygon == _last_polygon:
        return
    _last_polygon = polygon
    window.mouse_passthrough_polygon = polygon
    polygon_updated.emit(polygon.size())

func _merge_rects(source: Array[Rect2]) -> Array[Rect2]:
    var result: Array[Rect2] = []
    for rect in source:
        if rect.size.x <= 0.0 or rect.size.y <= 0.0:
            continue
        var current: Rect2 = rect
        var merged_any := true
        while merged_any:
            merged_any = false
            for index in range(result.size() - 1, -1, -1):
                if result[index].intersects(current, true) or result[index].grow(padding).intersects(current, true):
                    current = current.merge(result[index])
                    result.remove_at(index)
                    merged_any = true
        result.append(current)
    return result
