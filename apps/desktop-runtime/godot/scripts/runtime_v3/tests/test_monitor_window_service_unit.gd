extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const BusScript = preload("res://scripts/runtime_v3/core/runtime_event_bus.gd")
const ServiceScript = preload("res://scripts/runtime_v3/services/monitor_window_service.gd")


func _initialize() -> void:
	call_deferred("_run_test")


func _run_test() -> void:
	var display_name: String = DisplayServer.get_name()
	var screen_count: int = DisplayServer.get_screen_count()

	if display_name.to_lower() == "headless" or screen_count <= 0:
		print("[SKIP] monitor window descriptors: no display available in headless mode")
		await process_frame
		quit(0)
		return

	var holder := Node.new()
	get_root().add_child(holder)

	var context = ContextScript.new()
	var bus = BusScript.new()
	var service = ServiceScript.new()
	holder.add_child(context)
	holder.add_child(bus)
	holder.add_child(service)
	service.configure(context, bus)

	var descriptors: Dictionary = service.rebuild_descriptors()
	var ok: bool = not descriptors.is_empty()

	if ok:
		for descriptor_value in descriptors.values():
			var descriptor: Dictionary = descriptor_value
			if not descriptor.has("desktop_rect") \
			or not descriptor.has("scale") \
			or not descriptor.has("dpi"):
				ok = false
				break

	if ok:
		print("[PASS] monitor window descriptors: ", descriptors.size())
	else:
		push_error("[FAIL] invalid monitor descriptors")

	descriptors.clear()
	bus.clear()

	holder.remove_child(service)
	service.free()
	holder.remove_child(bus)
	bus.free()
	holder.remove_child(context)
	context.free()
	holder.free()

	await process_frame
	await process_frame
	quit(0 if ok else 1)
