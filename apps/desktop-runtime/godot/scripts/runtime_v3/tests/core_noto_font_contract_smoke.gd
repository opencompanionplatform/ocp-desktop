extends SceneTree

const ContextScript = preload("res://scripts/runtime_v3/core/runtime_context.gd")
const ThemeServiceScript = preload("res://scripts/runtime_v3/services/theme_service.gd")
const BundledNoto = preload("res://assets/fonts/NotoSansThai-VF.ttf")


func _initialize() -> void:
	var context = ContextScript.new()
	root.add_child(context)
	var theme = ThemeServiceScript.new()
	root.add_child(theme)
	theme.context = context

	var bundled_ok := BundledNoto is Font
	var default_context_ok := str(context.settings.get("font_family", "")) == "Noto Sans Thai"
	var resolved: Font = theme._font_resource("Noto Sans Thai")
	var resolved_ok := resolved == BundledNoto
	var fallback: Font = theme._font_resource("Segoe UI")
	var fallback_ok := fallback is SystemFont
	var ok := bundled_ok and default_context_ok and resolved_ok and fallback_ok
	print("[CORE-NOTO-FONT] bundled=", bundled_ok,
		" default_context=", default_context_ok,
		" resolved=", resolved_ok,
		" system_fallback=", fallback_ok,
		" ok=", ok)
	quit(0 if ok else 1)
