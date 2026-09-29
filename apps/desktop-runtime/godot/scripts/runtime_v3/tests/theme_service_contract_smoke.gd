extends SceneTree

const ServiceScript = preload(
	"res://scripts/runtime_v3/services/theme_service.gd"
)


class FakeContext:
	extends Node
	signal context_changed(section: StringName)
	var settings: Dictionary = {}
	var runtime_config: Dictionary = {}

	func update_runtime_config(values: Dictionary) -> void:
		runtime_config.merge(values, true)
		context_changed.emit(&"runtime_config")


class FakeBus:
	extends Node
	var events: Array = []

	func publish(topic: StringName, payload: Dictionary = {}) -> void:
		events.append({"topic": topic, "payload": payload.duplicate(true)})


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var holder := Node.new()
	get_root().add_child(holder)
	var context := FakeContext.new()
	var bus := FakeBus.new()
	var service = ServiceScript.new()
	holder.add_child(context)
	holder.add_child(bus)
	holder.add_child(service)
	service.configure(context, bus)
	service.start()
	var names: PackedStringArray = service.theme_names()
	var solid_ok := service.tokens().has("accent") and str(context.runtime_config.get("theme_preset", "")) == "solid"
	var glass_ok := service.select_theme("glass") and str(context.runtime_config.get("theme_preset", "")) == "glass"
	var surface_window := Window.new()
	var surface_panel := PanelContainer.new()
	surface_window.add_child(surface_panel)
	holder.add_child(surface_window)
	service.apply_to_window(surface_window)
	var glass_shader_ok := surface_panel.material is ShaderMaterial
	var liquid_ok := service.select_theme("liquid") and service.tokens().has("surface_alt")
	service.apply_to_window(surface_window)
	var liquid_shader_ok := surface_panel.material is ShaderMaterial
	var fallback_ok := service.select_theme("unknown") and str(context.runtime_config.get("theme_preset", "")) == "solid"
	service.apply_to_window(surface_window)
	var solid_fallback_ok := surface_panel.material == null
	var restarted_context := FakeContext.new()
	restarted_context.settings = {"theme_preset": "liquid"}
	var restarted_bus := FakeBus.new()
	var restarted_service = ServiceScript.new()
	holder.add_child(restarted_context)
	holder.add_child(restarted_bus)
	holder.add_child(restarted_service)
	restarted_service.configure(restarted_context, restarted_bus)
	restarted_service.start()
	var restart_ok: bool = restarted_service.current_name == "liquid"
	var ok: bool = names == PackedStringArray(["solid", "glass", "liquid"]) \
		and solid_ok and glass_ok and liquid_ok and fallback_ok \
		and glass_shader_ok and liquid_shader_ok and solid_fallback_ok and restart_ok \
		and bus.events.size() >= 3
	print("[P3.2] themes=", names, " events=", bus.events.size(), " fallback=", fallback_ok, " shaders=", glass_shader_ok and liquid_shader_ok, " restart=", restart_ok)
	print("[P3.2] global theme service contract %s" % ("passed" if ok else "failed"))
	holder.free()
	await process_frame
	quit(0 if ok else 1)
