extends "res://scripts/runtime_v3/controllers/runtime_controller.gd"
class_name RuntimeV3CharacterPickerController

const LOCAL_CHARACTER_STORE_URL := "http://127.0.0.1:3000"
const AnimationTileIconScript = preload("res://scripts/runtime_v3/ui/animation_tile_icon.gd")
const LibraryProjectionScript = preload("res://scripts/runtime_v3/services/character_library_projection.gd")

var panel: Control
var list_container: VBoxContainer
var file_dialog: FileDialog
var status_label: Label
var manager_window: Window
var uninstall_confirmation: ConfirmationDialog
var pending_uninstall: Dictionary = {}
var rename_dialog: ConfirmationDialog
var rename_input: LineEdit
var rename_package_id := ""
var rename_package_name := ""
var preview_sprite: AnimatedSprite2D
var animation_list: Container
var animation_search: LineEdit
var animation_category: OptionButton
var preview_status: Label
var preview_play_button: Button
var preview_loop: CheckButton
var preview_speed: OptionButton
var apply_button: Button
var store_button: Button
var installed_library_tab: Button
var cloud_library_tab: Button
var installed_library_view: Control
var cloud_library_view: Control
var cloud_library_list: VBoxContainer
var cloud_library_status: Label
var cloud_library_refresh: Button
var cloud_email_input: LineEdit
var cloud_password_input: LineEdit
var cloud_sign_in_button: Button
var cloud_sign_out_button: Button
var selected_character_title: Label
var selected_character_badges: Label
var selected_character_meta: Label
var selected_character_about: Label
var selected_preview_action: Button
var selected_secondary_action: Button
var selected_use_action: Button
var selected_uninstall_action: Button
var selected_package: Dictionary = {}
var selected_projection: Dictionary = {}
var preview_frames: SpriteFrames
var selected_animation := ""
var companion_host: Control
var companion_was_visible := true
var companion_preview_suppressed := false
var package_browser_overlay: PanelContainer
var package_browser_tree: Tree
var package_browser_path: LineEdit
var package_browser_status: Label
var package_browser_open_button: Button
var package_browser_filter: OptionButton
var package_browser_current_directory := ""
var package_browser_history: Array[String] = []
var package_browser_history_index := -1
var pending_install_origin := ""


func bind_picker(
	target_panel: Control,
	target_list: VBoxContainer,
	target_dialog: FileDialog,
	target_status: Label
) -> void:
	panel = target_panel
	list_container = target_list
	file_dialog = target_dialog
	status_label = target_status
	manager_window = panel.get_window()
	# The desktop companion's project-wide transparent-window default must never
	# leak into this asset-management surface. It becomes visible behind the
	# package dialog and must keep rendering its opaque shell after Cancel.
	if is_instance_valid(manager_window):
		manager_window.transparent = false
	# Keep FileDialog only as a compatibility fallback. It must never become a
	# child of Character Manager: Windows disables a native dialog's owner and
	# this transparent-runtime composition can leave that owner surface black.
	var theme_service := services.get_node_or_null("ThemeService") if is_instance_valid(services) else null
	if is_instance_valid(theme_service) and theme_service.has_method("register_window"):
		theme_service.register_window(manager_window)
	var localization_service := services.get_node_or_null("LocalizationService") if is_instance_valid(services) else null
	if is_instance_valid(localization_service) and localization_service.has_method("register_window"):
		localization_service.register_window(manager_window)
	_configure_uninstall_confirmation()
	_configure_rename_dialog()
	_configure_embedded_package_browser()
	_bind_library_tabs()
	_bind_character_details()

	if is_instance_valid(file_dialog):
		if "use_native_dialog" in file_dialog:
			file_dialog.use_native_dialog = false

		file_dialog.exclusive = false
		file_dialog.transient = false
		file_dialog.always_on_top = false
		# This legacy node remains inactive for scene compatibility. G15.12E uses
		# a Control-only browser inside Character Manager on every platform.
		file_dialog.transparent = false
		file_dialog.borderless = false
		file_dialog.force_native = false


func _bind_character_details() -> void:
	if not is_instance_valid(panel):
		return
	selected_character_title = panel.find_child("SelectedCharacterTitle", true, false) as Label
	selected_character_badges = panel.find_child("SelectedCharacterBadges", true, false) as Label
	selected_character_meta = panel.find_child("SelectedCharacterMeta", true, false) as Label
	selected_character_about = panel.find_child("SelectedCharacterAbout", true, false) as Label
	selected_preview_action = panel.find_child("SelectedPreviewAction", true, false) as Button
	selected_secondary_action = panel.find_child("SelectedSecondaryAction", true, false) as Button
	selected_use_action = panel.find_child("SelectedUseAction", true, false) as Button
	selected_uninstall_action = panel.find_child("SelectedUninstallAction", true, false) as Button
	if is_instance_valid(selected_preview_action) and not selected_preview_action.pressed.is_connected(_preview_selected_character):
		selected_preview_action.pressed.connect(_preview_selected_character)
	if is_instance_valid(selected_secondary_action) and not selected_secondary_action.pressed.is_connected(_run_selected_secondary_action):
		selected_secondary_action.pressed.connect(_run_selected_secondary_action)
	if is_instance_valid(selected_use_action) and not selected_use_action.pressed.is_connected(_apply_selected_package):
		selected_use_action.pressed.connect(_apply_selected_package)
	if is_instance_valid(selected_uninstall_action) and not selected_uninstall_action.pressed.is_connected(_request_selected_uninstall):
		selected_uninstall_action.pressed.connect(_request_selected_uninstall)


func _bind_library_tabs() -> void:
	if not is_instance_valid(panel):
		return
	installed_library_tab = panel.find_child("InstalledLibraryTab", true, false) as Button
	cloud_library_tab = panel.find_child("CloudLibraryTab", true, false) as Button
	installed_library_view = panel.find_child("InstalledLibraryView", true, false) as Control
	cloud_library_view = panel.find_child("CloudLibraryView", true, false) as Control
	cloud_library_list = panel.find_child("CloudLibraryList", true, false) as VBoxContainer
	cloud_library_status = panel.find_child("CloudLibraryStatus", true, false) as Label
	cloud_library_refresh = panel.find_child("RefreshCloudLibraryButton", true, false) as Button
	cloud_email_input = panel.find_child("CloudEmailInput", true, false) as LineEdit
	cloud_password_input = panel.find_child("CloudPasswordInput", true, false) as LineEdit
	cloud_sign_in_button = panel.find_child("CloudSignInButton", true, false) as Button
	cloud_sign_out_button = panel.find_child("CloudSignOutButton", true, false) as Button
	if is_instance_valid(installed_library_tab) and not installed_library_tab.pressed.is_connected(_show_installed_library):
		installed_library_tab.pressed.connect(_show_installed_library)
	if is_instance_valid(cloud_library_tab) and not cloud_library_tab.pressed.is_connected(_show_cloud_library):
		cloud_library_tab.pressed.connect(_show_cloud_library)
	if is_instance_valid(cloud_library_refresh) and not cloud_library_refresh.pressed.is_connected(_refresh_cloud_library):
		cloud_library_refresh.pressed.connect(_refresh_cloud_library)
	if is_instance_valid(cloud_sign_in_button) and not cloud_sign_in_button.pressed.is_connected(_sign_in_cloud_library):
		cloud_sign_in_button.pressed.connect(_sign_in_cloud_library)
	if is_instance_valid(cloud_sign_out_button) and not cloud_sign_out_button.pressed.is_connected(_sign_out_cloud_library):
		cloud_sign_out_button.pressed.connect(_sign_out_cloud_library)
	_sync_cloud_auth_controls()
	_show_installed_library()


func _cloud_library_service() -> Node:
	if not is_instance_valid(services):
		return null
	if "cloud_library_service" in services:
		var service: Variant = services.cloud_library_service
		if service is Node and is_instance_valid(service):
			return service as Node
	return null


func _cloud_auth_service() -> Node:
	if not is_instance_valid(services):
		return null
	if "cloud_auth_service" in services:
		var service: Variant = services.cloud_auth_service
		if service is Node and is_instance_valid(service):
			return service as Node
	return null


func _cloud_download_service() -> Node:
	if not is_instance_valid(services):
		return null
	if "cloud_download_service" in services:
		var service: Variant = services.cloud_download_service
		if service is Node and is_instance_valid(service):
			return service as Node
	return null


func _sign_in_cloud_library() -> void:
	var auth := _cloud_auth_service()
	if not is_instance_valid(auth) or not auth.has_method("sign_in_with_password"):
		_set_cloud_library_status("Cloud sign-in is unavailable in this runtime build.", false)
		return
	var email := cloud_email_input.text if is_instance_valid(cloud_email_input) else ""
	var password := cloud_password_input.text if is_instance_valid(cloud_password_input) else ""
	var result: Variant = auth.call("sign_in_with_password", email, password)
	if result is Dictionary:
		var status := str((result as Dictionary).get("status", ""))
		if status == "invalid-credentials":
			_set_cloud_library_status("Enter a valid email and password.", false)
		elif status == "not-configured":
			_set_cloud_library_status("OCP Cloud API is not configured yet.", false)
		elif status == "loading":
			_set_cloud_library_status("Signing in…", false)


func _sign_out_cloud_library() -> void:
	var auth := _cloud_auth_service()
	if is_instance_valid(auth) and auth.has_method("sign_out"):
		auth.call("sign_out")
	if is_instance_valid(cloud_password_input):
		cloud_password_input.clear()
	_sync_cloud_auth_controls()


func _sync_cloud_auth_controls() -> void:
	var signed_in := false
	if is_instance_valid(services) and "cloud_session_service" in services \
	and is_instance_valid(services.cloud_session_service) and services.cloud_session_service.has_method("is_signed_in"):
		signed_in = bool(services.cloud_session_service.call("is_signed_in"))
	if is_instance_valid(cloud_email_input):
		cloud_email_input.visible = not signed_in
	if is_instance_valid(cloud_password_input):
		cloud_password_input.visible = not signed_in
	if is_instance_valid(cloud_sign_in_button):
		cloud_sign_in_button.visible = not signed_in
	if is_instance_valid(cloud_sign_out_button):
		cloud_sign_out_button.visible = signed_in


func _cloud_library_items() -> Array:
	var service := _cloud_library_service()
	if is_instance_valid(service) and service.has_method("cached_library"):
		var value: Variant = service.call("cached_library")
		return value if value is Array else []
	return []


func _cloud_catalog_items() -> Array:
	var service := _cloud_library_service()
	if is_instance_valid(service) and service.has_method("cached_catalog"):
		var value: Variant = service.call("cached_catalog")
		return value if value is Array else []
	return []


func _install_origins() -> Dictionary:
	if not is_instance_valid(context):
		return {}
	var value: Variant = context.settings.get("character_install_origins", {})
	return value.duplicate(true) if value is Dictionary else {}


func _character_projection(library_override: Variant = null) -> Array[Dictionary]:
	if not is_instance_valid(services) or not ("package_service" in services):
		return []
	var package_service: Variant = services.get("package_service")
	if package_service == null \
	or not package_service.has_method("list_installed") \
	or not package_service.has_method("get_active"):
		return []
	var library: Array = library_override if library_override is Array else _cloud_library_items()
	return LibraryProjectionScript.compose(
		package_service.call("list_installed"),
		library,
		_cloud_catalog_items(),
		package_service.call("get_active"),
		_install_origins()
	)


func _projection_for_package(package_id: String, version: String) -> Dictionary:
	for entry in _character_projection():
		if str(entry.get("package_id", "")) == package_id \
		and str(entry.get("version", "")) == version:
			return entry
	return {}


func _show_installed_library() -> void:
	if is_instance_valid(installed_library_view):
		installed_library_view.visible = true
	if is_instance_valid(cloud_library_view):
		cloud_library_view.visible = false
	if is_instance_valid(installed_library_tab):
		installed_library_tab.button_pressed = true
	if is_instance_valid(cloud_library_tab):
		cloud_library_tab.button_pressed = false


func _show_cloud_library() -> void:
	_sync_cloud_auth_controls()
	if is_instance_valid(installed_library_view):
		installed_library_view.visible = false
	if is_instance_valid(cloud_library_view):
		cloud_library_view.visible = true
	if is_instance_valid(installed_library_tab):
		installed_library_tab.button_pressed = false
	if is_instance_valid(cloud_library_tab):
		cloud_library_tab.button_pressed = true
	var service := _cloud_library_service()
	if not is_instance_valid(service):
		_set_cloud_library_status("Cloud library is unavailable in this runtime build.", false)
		_render_cloud_library([])
		return
	if service.has_method("refresh_catalog"):
		service.call("refresh_catalog")
	var signed_in := bool(service.call("is_signed_in")) if service.has_method("is_signed_in") else false
	if not signed_in:
		_set_cloud_library_status("Sign in to sync your cloud library.", false)
		_render_cloud_library([])
		return
	_render_cloud_library(service.call("cached_library") if service.has_method("cached_library") else [])
	_refresh_cloud_library()


func _refresh_cloud_library() -> void:
	var service := _cloud_library_service()
	if not is_instance_valid(service) or not service.has_method("refresh_library"):
		_set_cloud_library_status("Cloud library is unavailable in this runtime build.", false)
		return
	if service.has_method("refresh_catalog"):
		service.call("refresh_catalog")
	var result: Variant = service.call("refresh_library")
	if result is Dictionary:
		var status := str((result as Dictionary).get("status", ""))
		if status == "sign-in-required":
			_set_cloud_library_status("Sign in to sync your cloud library.", false)
		elif status == "not-configured":
			_set_cloud_library_status("OCP Cloud API is not configured yet.", false)
		elif status == "loading":
			_set_cloud_library_status("Syncing your library…", false)


func _on_cloud_library_session_changed(payload: Dictionary) -> void:
	_sync_cloud_auth_controls()
	if not is_instance_valid(cloud_library_view) or not cloud_library_view.visible:
		return
	if bool(payload.get("signed_in", false)):
		_refresh_cloud_library()
	else:
		_set_cloud_library_status("Sign in to sync your cloud library.", false)
		_render_cloud_library([])


func _on_cloud_library_updated(payload: Dictionary) -> void:
	var status := str(payload.get("status", "error"))
	var items: Array = payload.get("items", []) if payload.get("items", []) is Array else []
	match status:
		"loading":
			_set_cloud_library_status("Syncing your library…", false)
		"synced":
			_set_cloud_library_status("%d items in your cloud library" % items.size(), true)
			_render_cloud_library(items)
		"sign-in-required":
			_set_cloud_library_status("Sign in to sync your cloud library.", false)
			_render_cloud_library([])
		"not-configured":
			_set_cloud_library_status("OCP Cloud API is not configured yet.", false)
		"error":
			_set_cloud_library_status("Could not sync the cloud library. Try again.", true)
		_:
			_set_cloud_library_status("Cloud library status is unavailable.", true)


func _on_cloud_catalog_updated(payload: Dictionary) -> void:
	if str(payload.get("status", "")) == "synced" \
	and is_instance_valid(cloud_library_view) and cloud_library_view.visible:
		_render_cloud_library(_cloud_library_items())


func _on_cloud_auth_updated(payload: Dictionary) -> void:
	_sync_cloud_auth_controls()
	var status := str(payload.get("status", ""))
	match status:
		"signing-in":
			_set_cloud_library_status("Signing in…", false)
		"restoring":
			_set_cloud_library_status("Restoring your cloud session…", false)
		"signed-in", "signed-in-session-only":
			if is_instance_valid(cloud_password_input):
				cloud_password_input.clear()
			_set_cloud_library_status("Signed in. Registering this device…", false)
		"authentication-failed":
			_set_cloud_library_status("Sign-in failed. Check your email and password.", false)
		"signed-out":
			_set_cloud_library_status("Sign in to sync your cloud library.", false)
			_render_cloud_library([])
		"error":
			_set_cloud_library_status("Cloud sign-in could not be completed.", true)


func _download_cloud_character(package_id: String, version: String) -> void:
	var service := _cloud_download_service()
	if not is_instance_valid(service) or not service.has_method("download_and_install"):
		_set_cloud_library_status("Cloud download is unavailable in this runtime build.", true)
		return
	var result: Variant = service.call("download_and_install", package_id, version)
	if not (result is Dictionary):
		_set_cloud_library_status("Cloud download could not start.", true)
		return
	var status := str((result as Dictionary).get("status", ""))
	match status:
		"authorizing": _set_cloud_library_status("Checking your character entitlement…", false)
		"sign-in-required": _set_cloud_library_status("Sign in to download this character.", false)
		"device-registration-required": _set_cloud_library_status("This device is still being registered. Try again in a moment.", true)
		"invalid-package": _set_cloud_library_status("The Store returned an invalid character version.", true)
		"not-configured": _set_cloud_library_status("OCP Cloud API is not configured yet.", false)
		"busy": _set_cloud_library_status("Another cloud download is already running.", false)
		_:
			if not bool((result as Dictionary).get("ok", false)):
				_set_cloud_library_status("Cloud download could not start.", true)


func _on_cloud_download_updated(payload: Dictionary) -> void:
	var status := str(payload.get("status", ""))
	match status:
		"authorizing": _set_cloud_library_status("Checking your character entitlement…", false)
		"downloading": _set_cloud_library_status("Downloading signed character package…", false)
		"installed":
			_set_cloud_library_status("Character installed successfully ✓", true)
			_refresh_cloud_library()
		"package-verification-failed", "installed-package-mismatch", "native-trust-unavailable":
			_set_cloud_library_status("Character package failed security verification.", true)
		_:
			if status.ends_with("failed") or status in ["authorization-mismatch", "invalid-authorization-response"]:
				_set_cloud_library_status("Cloud download failed. Try again.", true)


func _set_cloud_library_status(message: String, can_refresh: bool) -> void:
	if is_instance_valid(cloud_library_status):
		cloud_library_status.text = message
	if is_instance_valid(cloud_library_refresh):
		cloud_library_refresh.disabled = not can_refresh


func _render_cloud_library(items: Array) -> void:
	if not is_instance_valid(cloud_library_list):
		return
	for child in cloud_library_list.get_children():
		child.queue_free()
	var visible_count := 0
	for entry in _character_projection(items):
		if not bool(entry.get("owned", false)):
			continue
		visible_count += 1
		_add_cloud_library_card(entry)
	if visible_count == 0:
		var empty := Label.new()
		empty.name = "CloudLibraryEmptyLabel"
		empty.text = "No cloud characters yet. Explore the Store to add one."
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		cloud_library_list.add_child(empty)


func _add_cloud_library_card(entry: Dictionary) -> void:
	var card := PanelContainer.new()
	card.name = "CloudLibraryCard"
	card.set_meta("ocp_library_entry", entry.duplicate(true))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	card.add_child(box)
	var title := Label.new()
	title.text = str(entry.get("display_name", entry.get("package_id", "")))
	title.tooltip_text = str(entry.get("package_id", ""))
	title.add_theme_font_size_override("font_size", 15)
	box.add_child(title)
	var ownership := Label.new()
	ownership.text = " · ".join(LibraryProjectionScript.status_labels(entry))
	box.add_child(ownership)
	var action := Button.new()
	if bool(entry.get("installed", false)):
		action.text = "Installed ✓"
		action.disabled = true
	else:
		var package_id := str(entry.get("package_id", ""))
		var version := str(entry.get("latest_version", entry.get("version", "")))
		var session_ready := false
		if is_instance_valid(services) and "cloud_session_service" in services \
		and is_instance_valid(services.cloud_session_service) \
		and services.cloud_session_service.has_method("is_signed_in") \
		and services.cloud_session_service.has_method("device_id"):
			session_ready = bool(services.cloud_session_service.call("is_signed_in")) \
				and not str(services.cloud_session_service.call("device_id")).strip_edges().is_empty()
		action.text = "Download" if not version.is_empty() else "Unavailable"
		action.disabled = version.is_empty() or not session_ready or not is_instance_valid(_cloud_download_service())
		if version.is_empty():
			action.tooltip_text = "Package metadata is still syncing."
		elif not session_ready:
			action.tooltip_text = "Sign in and wait for this device to register."
		else:
			action.tooltip_text = "Download, verify, and install this character."
		if not action.disabled:
			action.pressed.connect(func(): _download_cloud_character(package_id, version))
	box.add_child(action)
	cloud_library_list.add_child(card)


func bind_preview(
	target_sprite: AnimatedSprite2D,
	target_animation_list: Container,
	target_search: LineEdit,
	target_category: OptionButton,
	target_status: Label,
	target_play: Button,
	target_loop: CheckButton,
	target_speed: OptionButton,
	target_apply: Button,
	target_store: Button
) -> void:
	preview_sprite = target_sprite
	animation_list = target_animation_list
	animation_search = target_search
	animation_category = target_category
	preview_status = target_status
	preview_play_button = target_play
	preview_loop = target_loop
	preview_speed = target_speed
	apply_button = target_apply
	store_button = target_store
	if is_instance_valid(animation_search) and not animation_search.text_changed.is_connected(_rebuild_animation_list):
		animation_search.text_changed.connect(_rebuild_animation_list)
	if is_instance_valid(animation_category) and not animation_category.item_selected.is_connected(_on_animation_category_selected):
		animation_category.item_selected.connect(_on_animation_category_selected)
	if is_instance_valid(preview_play_button) and not preview_play_button.pressed.is_connected(_toggle_preview_playback):
		preview_play_button.pressed.connect(_toggle_preview_playback)
	if is_instance_valid(preview_loop) and not preview_loop.toggled.is_connected(_set_preview_loop):
		preview_loop.toggled.connect(_set_preview_loop)
	if is_instance_valid(preview_speed) and not preview_speed.item_selected.is_connected(_set_preview_speed):
		preview_speed.item_selected.connect(_set_preview_speed)
	if is_instance_valid(apply_button) and not apply_button.pressed.is_connected(_apply_selected_package):
		apply_button.pressed.connect(_apply_selected_package)
	_configure_store_action()


static func is_valid_store_url(value: String) -> bool:
	var uri := value.strip_edges()
	if uri in ["http://127.0.0.1:3000", "http://127.0.0.1:3000/", "http://localhost:3000", "http://localhost:3000/"]:
		return true
	if not uri.begins_with("https://") or uri.contains(" "):
		return false
	var host_and_path := uri.trim_prefix("https://")
	var host := host_and_path.get_slice("/", 0)
	return not host.is_empty() and host.contains(".") and not host.begins_with(".")


func _configure_store_action() -> void:
	if not is_instance_valid(store_button):
		return
	var configured_url := str(context.settings.get("character_store_url", LOCAL_CHARACTER_STORE_URL)) if is_instance_valid(context) else LOCAL_CHARACTER_STORE_URL
	store_button.disabled = not is_valid_store_url(configured_url)
	store_button.tooltip_text = "Open the Character Store in your browser" if not store_button.disabled else "Character Store URL has not been configured"
	if not store_button.disabled and not store_button.pressed.is_connected(_open_character_store):
		store_button.pressed.connect(_open_character_store)


func _open_character_store() -> void:
	var configured_url := str(context.settings.get("character_store_url", LOCAL_CHARACTER_STORE_URL)) if is_instance_valid(context) else LOCAL_CHARACTER_STORE_URL
	if not is_valid_store_url(configured_url):
		return
	OS.shell_open(configured_url.strip_edges())
	print("[CharacterManager] external-store-opened host-configured=true")


func start() -> void:
	event_bus.subscribe(&"character_picker.open_requested", Callable(self, "_on_open"))
	event_bus.subscribe(&"character_picker.close_requested", Callable(self, "_on_close"))
	event_bus.subscribe(&"character.changed", Callable(self, "_on_character_changed"))
	event_bus.subscribe(&"character.uninstalled", Callable(self, "_on_character_changed"))
	event_bus.subscribe(&"package.installed", Callable(self, "_on_package_installed"))
	event_bus.subscribe(&"package.install_failed", Callable(self, "_on_package_failed"))
	event_bus.subscribe(&"cloud.library.updated", Callable(self, "_on_cloud_library_updated"))
	event_bus.subscribe(&"cloud.catalog.updated", Callable(self, "_on_cloud_catalog_updated"))
	event_bus.subscribe(&"cloud.auth.updated", Callable(self, "_on_cloud_auth_updated"))
	event_bus.subscribe(&"cloud.download.updated", Callable(self, "_on_cloud_download_updated"))
	event_bus.subscribe(&"cloud.session.changed", Callable(self, "_on_cloud_library_session_changed"))
	event_bus.subscribe(&"character_picker.native_select_requested", Callable(self, "_on_native_select_requested"))
	# Window minimize/restore is OS-owned and does not emit Character Manager's
	# close event. Poll the small native window state so preview suppression is
	# released whenever the manager is no longer actually visible.
	set_process(true)


func stop() -> void:
	event_bus.unsubscribe(&"character_picker.open_requested", Callable(self, "_on_open"))
	event_bus.unsubscribe(&"character_picker.close_requested", Callable(self, "_on_close"))
	event_bus.unsubscribe(&"character.changed", Callable(self, "_on_character_changed"))
	event_bus.unsubscribe(&"character.uninstalled", Callable(self, "_on_character_changed"))
	event_bus.unsubscribe(&"package.installed", Callable(self, "_on_package_installed"))
	event_bus.unsubscribe(&"package.install_failed", Callable(self, "_on_package_failed"))
	event_bus.unsubscribe(&"cloud.library.updated", Callable(self, "_on_cloud_library_updated"))
	event_bus.unsubscribe(&"cloud.catalog.updated", Callable(self, "_on_cloud_catalog_updated"))
	event_bus.unsubscribe(&"cloud.auth.updated", Callable(self, "_on_cloud_auth_updated"))
	event_bus.unsubscribe(&"cloud.download.updated", Callable(self, "_on_cloud_download_updated"))
	event_bus.unsubscribe(&"cloud.session.changed", Callable(self, "_on_cloud_library_session_changed"))
	event_bus.unsubscribe(&"character_picker.native_select_requested", Callable(self, "_on_native_select_requested"))
	set_process(false)


func _process(_delta: float) -> void:
	_sync_companion_preview_visibility()


func open_install_dialog() -> void:
	if not is_instance_valid(package_browser_overlay):
		_configure_embedded_package_browser()
	if not is_instance_valid(package_browser_overlay):
		return
	package_browser_overlay.visible = true
	var initial_directory := _default_package_browser_directory()
	if not package_browser_current_directory.is_empty() \
	and DirAccess.dir_exists_absolute(package_browser_current_directory):
		initial_directory = package_browser_current_directory
	_navigate_package_browser(initial_directory, package_browser_history.is_empty())
	package_browser_tree.grab_focus()
	print("[CharacterManager] embedded-package-browser-opened directory=%s" % package_browser_current_directory)


static func is_installable_package_path(path: String) -> bool:
	var extension := path.get_extension().to_lower()
	return extension == "ocp" or extension == "zip"


func _configure_embedded_package_browser() -> void:
	if not is_instance_valid(manager_window) or is_instance_valid(package_browser_overlay):
		return
	package_browser_overlay = PanelContainer.new()
	package_browser_overlay.name = "EmbeddedPackageBrowser"
	# Character Manager owns a stable dark presentation. Without this boundary a
	# later Liquid/Glass replay walks the overlay and replaces its authored dark
	# surfaces, producing the bright teal browser seen on mixed-theme sessions.
	package_browser_overlay.set_meta("ocp_mock_theme_locked", true)
	package_browser_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	package_browser_overlay.z_index = 500
	package_browser_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	package_browser_overlay.visible = false
	package_browser_overlay.add_theme_stylebox_override(
		"panel", _package_browser_style(Color("#020611"), Color("#27c7ff"), 18)
	)
	manager_window.add_child(package_browser_overlay)

	var outer_margin := MarginContainer.new()
	outer_margin.add_theme_constant_override("margin_left", 32)
	outer_margin.add_theme_constant_override("margin_top", 28)
	outer_margin.add_theme_constant_override("margin_right", 32)
	outer_margin.add_theme_constant_override("margin_bottom", 28)
	package_browser_overlay.add_child(outer_margin)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 14)
	outer_margin.add_child(layout)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	layout.add_child(header)
	var heading := Label.new()
	heading.text = "Install OCP Character Package"
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_theme_font_size_override("font_size", 24)
	heading.add_theme_color_override("font_color", Color("#f4f7ff"))
	header.add_child(heading)
	var close_button := _package_browser_button("Cancel")
	close_button.pressed.connect(_close_embedded_package_browser)
	header.add_child(close_button)

	var location_row := HBoxContainer.new()
	location_row.add_theme_constant_override("separation", 8)
	layout.add_child(location_row)
	var back_button := _package_browser_button("Back")
	back_button.tooltip_text = "Previous folder"
	back_button.pressed.connect(_package_browser_back)
	location_row.add_child(back_button)
	var up_button := _package_browser_button("Up")
	up_button.tooltip_text = "Parent folder"
	up_button.pressed.connect(_package_browser_up)
	location_row.add_child(up_button)
	package_browser_path = LineEdit.new()
	package_browser_path.name = "PackageBrowserPath"
	package_browser_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	package_browser_path.text_submitted.connect(
		func(value: String): _navigate_package_browser(value, true)
	)
	package_browser_path.add_theme_stylebox_override(
		"normal", _package_browser_style(Color("#07172d"), Color("#26517f"), 10)
	)
	package_browser_path.add_theme_stylebox_override(
		"focus", _package_browser_style(Color("#091c35"), Color("#27c7ff"), 10)
	)
	package_browser_path.add_theme_color_override("font_color", Color("#f4f7ff"))
	package_browser_path.add_theme_color_override("caret_color", Color("#27c7ff"))
	location_row.add_child(package_browser_path)
	var go_button := _package_browser_button("Go")
	go_button.pressed.connect(
		func(): _navigate_package_browser(package_browser_path.text, true)
	)
	location_row.add_child(go_button)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 14)
	layout.add_child(body)
	var locations_panel := PanelContainer.new()
	locations_panel.custom_minimum_size = Vector2(190, 0)
	locations_panel.add_theme_stylebox_override(
		"panel", _package_browser_style(Color("#07142a"), Color("#26517f"), 14)
	)
	body.add_child(locations_panel)
	var locations := VBoxContainer.new()
	locations.name = "PackageBrowserLocations"
	locations.add_theme_constant_override("separation", 7)
	locations_panel.add_child(locations)
	var locations_title := Label.new()
	locations_title.text = "Locations"
	locations_title.add_theme_font_size_override("font_size", 17)
	locations.add_child(locations_title)
	_add_package_browser_location(locations, "Documents", OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS))
	_add_package_browser_location(locations, "Downloads", OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS))
	_add_package_browser_location(locations, "Desktop", OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP))
	for drive_index in range(DirAccess.get_drive_count()):
		var drive_path := _normalize_package_browser_path(DirAccess.get_drive_name(drive_index))
		_add_package_browser_location(locations, drive_path, drive_path)

	var files_panel := PanelContainer.new()
	files_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	files_panel.add_theme_stylebox_override(
		"panel", _package_browser_style(Color("#061225"), Color("#26517f"), 14)
	)
	body.add_child(files_panel)
	package_browser_tree = Tree.new()
	package_browser_tree.name = "PackageBrowserTree"
	package_browser_tree.columns = 2
	package_browser_tree.column_titles_visible = true
	package_browser_tree.set_column_title(0, "Name")
	package_browser_tree.set_column_title(1, "Type")
	package_browser_tree.set_column_expand(0, true)
	package_browser_tree.set_column_custom_minimum_width(1, 120)
	package_browser_tree.hide_root = true
	package_browser_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	package_browser_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	package_browser_tree.add_theme_color_override("font_color", Color("#d9e7fb"))
	package_browser_tree.add_theme_color_override("font_selected_color", Color("#ffffff"))
	package_browser_tree.add_theme_color_override("title_button_color", Color("#d9e7fb"))
	package_browser_tree.add_theme_color_override("guide_color", Color("#173a61"))
	package_browser_tree.add_theme_stylebox_override(
		"panel", _package_browser_style(Color("#030a16"), Color("#26517f"), 10)
	)
	package_browser_tree.add_theme_stylebox_override(
		"focus", _package_browser_style(Color("#061225"), Color("#27c7ff"), 10)
	)
	package_browser_tree.add_theme_stylebox_override(
		"selected", _package_browser_style(Color("#12345c"), Color("#27c7ff"), 7)
	)
	package_browser_tree.add_theme_stylebox_override(
		"selected_focus", _package_browser_style(Color("#16436f"), Color("#27c7ff"), 7)
	)
	package_browser_tree.add_theme_stylebox_override(
		"title_button_normal", _package_browser_style(Color("#07172d"), Color("#173a61"), 4)
	)
	package_browser_tree.item_selected.connect(_on_package_browser_selection_changed)
	package_browser_tree.item_activated.connect(_activate_package_browser_selection)
	files_panel.add_child(package_browser_tree)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 10)
	layout.add_child(footer)
	package_browser_filter = OptionButton.new()
	package_browser_filter.name = "PackageBrowserFilter"
	package_browser_filter.add_item("All recognized (.ocp, .zip)")
	package_browser_filter.add_item("OCP packages (.ocp)")
	package_browser_filter.add_item("ZIP packages (.zip)")
	package_browser_filter.item_selected.connect(func(_index: int): _refresh_package_browser())
	package_browser_filter.add_theme_color_override("font_color", Color("#d9e7fb"))
	package_browser_filter.add_theme_stylebox_override(
		"normal", _package_browser_style(Color("#07172d"), Color("#26517f"), 10)
	)
	package_browser_filter.add_theme_stylebox_override(
		"hover", _package_browser_style(Color("#102b4e"), Color("#27c7ff"), 10)
	)
	footer.add_child(package_browser_filter)
	package_browser_status = Label.new()
	package_browser_status.name = "PackageBrowserStatus"
	package_browser_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	package_browser_status.add_theme_color_override("font_color", Color("#9aabc6"))
	footer.add_child(package_browser_status)
	var cancel_button := _package_browser_button("Cancel")
	cancel_button.pressed.connect(_close_embedded_package_browser)
	footer.add_child(cancel_button)
	package_browser_open_button = _package_browser_button("Install")
	package_browser_open_button.disabled = true
	package_browser_open_button.pressed.connect(_activate_package_browser_selection)
	footer.add_child(package_browser_open_button)


func _package_browser_button(label: String) -> Button:
	var button := Button.new()
	button.text = label
	button.custom_minimum_size = Vector2(92, 40)
	button.add_theme_stylebox_override(
		"normal", _package_browser_style(Color("#0a1b33"), Color("#26517f"), 10)
	)
	button.add_theme_stylebox_override(
		"hover", _package_browser_style(Color("#102b4e"), Color("#27c7ff"), 10)
	)
	button.add_theme_stylebox_override(
		"pressed", _package_browser_style(Color("#123b68"), Color("#27c7ff"), 10)
	)
	button.add_theme_stylebox_override(
		"disabled", _package_browser_style(Color("#061020"), Color("#173a61"), 10)
	)
	button.add_theme_color_override("font_color", Color("#d9e7fb"))
	button.add_theme_color_override("font_hover_color", Color("#ffffff"))
	button.add_theme_color_override("font_disabled_color", Color("#607693"))
	return button


func _package_browser_style(background: Color, border: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 12
	style.content_margin_top = 10
	style.content_margin_right = 12
	style.content_margin_bottom = 10
	return style


func _add_package_browser_location(container: VBoxContainer, label: String, path: String) -> void:
	if path.is_empty() or not DirAccess.dir_exists_absolute(path):
		return
	var button := _package_browser_button(label)
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.pressed.connect(Callable(self, "_navigate_package_browser").bind(path, true))
	container.add_child(button)


func _default_package_browser_directory() -> String:
	if is_instance_valid(context):
		var saved := str(context.settings.get("lastCharacterPackageFolder", ""))
		if not saved.is_empty() and DirAccess.dir_exists_absolute(saved):
			return saved
	for system_directory in [OS.SYSTEM_DIR_DOCUMENTS, OS.SYSTEM_DIR_DOWNLOADS, OS.SYSTEM_DIR_DESKTOP]:
		var candidate := OS.get_system_dir(system_directory)
		if not candidate.is_empty() and DirAccess.dir_exists_absolute(candidate):
			return candidate
	return ProjectSettings.globalize_path("res://")


func _normalize_package_browser_path(path: String) -> String:
	var normalized := path.strip_edges().replace("\\", "/")
	if normalized.length() == 2 and normalized.ends_with(":"):
		normalized += "/"
	return normalized.simplify_path()


func _navigate_package_browser(path: String, record_history: bool = true) -> bool:
	var normalized := _normalize_package_browser_path(path)
	if not DirAccess.dir_exists_absolute(normalized):
		package_browser_status.text = "Folder not found: " + normalized
		return false
	package_browser_current_directory = normalized
	package_browser_path.text = normalized
	if record_history:
		while package_browser_history.size() > package_browser_history_index + 1:
			package_browser_history.pop_back()
		if package_browser_history.is_empty() or package_browser_history[-1] != normalized:
			package_browser_history.append(normalized)
		package_browser_history_index = package_browser_history.size() - 1
	_refresh_package_browser()
	return true


func _refresh_package_browser() -> void:
	if not is_instance_valid(package_browser_tree) or package_browser_current_directory.is_empty():
		return
	package_browser_tree.clear()
	var root := package_browser_tree.create_item()
	var directory := DirAccess.open(package_browser_current_directory)
	if directory == null:
		package_browser_status.text = "Cannot open this folder."
		return
	var directories := directory.get_directories()
	directories.sort()
	var files := directory.get_files()
	files.sort()
	var visible_files := 0
	for directory_name in directories:
		if str(directory_name).begins_with("."):
			continue
		var directory_path := package_browser_current_directory.path_join(directory_name)
		var item := package_browser_tree.create_item(root)
		item.set_text(0, str(directory_name))
		item.set_text(1, "Folder")
		item.set_metadata(0, {"path": directory_path, "directory": true})
	for file_name in files:
		var file_path := package_browser_current_directory.path_join(file_name)
		if not _package_browser_filter_accepts(file_path):
			continue
		var item := package_browser_tree.create_item(root)
		item.set_text(0, str(file_name))
		item.set_text(1, file_path.get_extension().to_upper() + " package")
		item.set_metadata(0, {"path": file_path, "directory": false})
		visible_files += 1
	package_browser_open_button.disabled = true
	package_browser_open_button.text = "Install"
	package_browser_status.text = "%d package file(s)" % visible_files


func _package_browser_filter_accepts(path: String) -> bool:
	var extension := path.get_extension().to_lower()
	match package_browser_filter.selected if is_instance_valid(package_browser_filter) else 0:
		1:
			return extension == "ocp"
		2:
			return extension == "zip"
		_:
			return is_installable_package_path(path)


func _on_package_browser_selection_changed() -> void:
	var selection := _selected_package_browser_entry()
	if selection.is_empty():
		package_browser_open_button.disabled = true
		return
	package_browser_open_button.disabled = false
	package_browser_open_button.text = "Open folder" if bool(selection.get("directory", false)) else "Install"
	package_browser_status.text = str(selection.get("path", ""))


func _selected_package_browser_entry() -> Dictionary:
	if not is_instance_valid(package_browser_tree):
		return {}
	var selected := package_browser_tree.get_selected()
	if selected == null:
		return {}
	var metadata: Variant = selected.get_metadata(0)
	return metadata as Dictionary if metadata is Dictionary else {}


func _activate_package_browser_selection() -> void:
	var selection := _selected_package_browser_entry()
	if selection.is_empty():
		return
	var selected_path := str(selection.get("path", ""))
	if bool(selection.get("directory", false)):
		_navigate_package_browser(selected_path, true)
		return
	if not is_installable_package_path(selected_path) or not FileAccess.file_exists(selected_path):
		package_browser_status.text = "Select a valid .ocp or .zip package."
		return
	package_browser_overlay.visible = false
	_on_file_selected(selected_path)


func _package_browser_back() -> void:
	if package_browser_history_index <= 0:
		return
	package_browser_history_index -= 1
	_navigate_package_browser(package_browser_history[package_browser_history_index], false)


func _package_browser_up() -> void:
	if package_browser_current_directory.is_empty():
		return
	var parent_directory := package_browser_current_directory.get_base_dir()
	if parent_directory == package_browser_current_directory or parent_directory.is_empty():
		return
	_navigate_package_browser(parent_directory, true)


func _close_embedded_package_browser() -> void:
	if is_instance_valid(package_browser_overlay):
		package_browser_overlay.visible = false
	if is_instance_valid(status_label):
		status_label.text = ""
	print("[CharacterManager] embedded-package-browser-closed")


func _on_open(_payload: Dictionary) -> void:
	if _try_open_desktop_shell():
		return
	# RuntimeAppDesktopShell does not instantiate the legacy Godot Character
	# Manager panel. If the optional Electron launcher is unavailable, fail
	# closed instead of dereferencing a missing legacy UI tree.
	if not is_instance_valid(panel):
		return
	_rebuild()
	panel.visible = true
	if is_instance_valid(manager_window):
		_position_manager_window()
		manager_window.transparent = false
		# The companion's native surface is always-on-top. Keep the manager above
		# it while it is actively being used so the desktop character cannot draw
		# across the installed-character library.
		manager_window.always_on_top = true
		manager_window.show()
		manager_window.grab_focus()
	_sync_companion_preview_visibility()
	state_machine.transition(&"character_picker", {}, true)
	event_bus.publish(&"click_through.refresh_requested", {})


func _try_open_desktop_shell() -> bool:
	# Do not construct the optional Shell adapter during Runtime startup. The
	# Character Manager loads it only after an explicit user request.
	if OS.get_environment("OCP_DESKTOP_SHELL_ENABLED") != "1":
		return false
	var launcher_script := load("res://scripts/runtime_v3/services/desktop_shell_launcher.gd")
	if launcher_script == null:
		return false
	var launcher: Variant = launcher_script.new()
	var opened: bool = launcher != null and launcher.has_method("try_open") and bool(launcher.call("try_open", &"characters"))
	if launcher is Object and is_instance_valid(launcher):
		launcher.free()
	return opened


func _on_close(_payload: Dictionary) -> void:
	if is_instance_valid(manager_window):
		manager_window.always_on_top = false
		manager_window.hide()
	elif is_instance_valid(panel):
		panel.visible = false
	_set_companion_preview_visibility(true)
	state_machine.transition(&"ready", {}, true)
	event_bus.publish(&"click_through.refresh_requested", {})


func _position_manager_window() -> void:
	if not is_instance_valid(manager_window):
		return
	var screen := DisplayServer.window_get_current_screen(DisplayServer.MAIN_WINDOW_ID)
	if screen < 0:
		screen = DisplayServer.get_primary_screen()
	var usable_rect := DisplayServer.screen_get_usable_rect(screen)
	manager_window.position = usable_rect.position + Vector2i(
		maxi(0, (usable_rect.size.x - manager_window.size.x) / 2),
		maxi(0, (usable_rect.size.y - manager_window.size.y) / 2)
	)


func _set_companion_preview_visibility(visible: bool) -> void:
	if not is_instance_valid(companion_host) and is_instance_valid(manager_window):
		var runtime_root := manager_window.get_parent()
		if is_instance_valid(runtime_root):
			companion_host = runtime_root.get_node_or_null(
				"RuntimeUI/CompanionLayer/CompanionHost"
			) as Control
	if not is_instance_valid(companion_host):
		return
	if not visible:
		if companion_preview_suppressed:
			return
		companion_was_visible = companion_host.visible
		companion_host.visible = false
		companion_preview_suppressed = true
		return
	if not companion_preview_suppressed:
		return
	companion_host.visible = companion_was_visible
	companion_preview_suppressed = false


func _sync_companion_preview_visibility() -> void:
	var manager_preview_visible := is_instance_valid(panel) and panel.visible
	if manager_preview_visible and is_instance_valid(manager_window):
		manager_preview_visible = manager_window.visible \
			and manager_window.mode != Window.MODE_MINIMIZED
	_set_companion_preview_visibility(not manager_preview_visible)


func _on_native_select_requested(payload: Dictionary) -> void:
	var package_id := str(payload.get("package_id", ""))
	for package_info in services.package_service.list_installed():
		if str(package_info.get("packageId", "")) == package_id:
			event_bus.publish(&"character.activate_requested", {
				"package_id": package_id,
				"version": str(package_info.get("version", "")),
			})
			return




func _on_character_changed(_payload: Dictionary) -> void:
	if is_instance_valid(panel) and panel.visible:
		_rebuild()
	if is_instance_valid(cloud_library_view) and cloud_library_view.visible:
		_render_cloud_library(_cloud_library_items())


func _on_file_selected(path: String) -> void:
	var folder: String = path.get_base_dir()
	services.settings_service.save_settings({
		"lastCharacterPackageFolder": folder,
	})
	if is_instance_valid(status_label):
		status_label.text = "Installing: " + path.get_file()
	pending_install_origin = "local-import"
	event_bus.publish(&"package.install_requested", {"path": path})


func _on_package_installed(payload: Dictionary) -> void:
	if is_instance_valid(status_label):
		status_label.text = "Installed: %s@%s" % [
			payload.get("packageId", ""),
			payload.get("version", ""),
		]
	if not pending_install_origin.is_empty():
		var package_id := str(payload.get("packageId", ""))
		var version := str(payload.get("version", ""))
		if not package_id.is_empty() and not version.is_empty():
			var origins := _install_origins()
			origins[LibraryProjectionScript.origin_key(package_id, version)] = pending_install_origin
			services.settings_service.save_settings({"character_install_origins": origins})
	pending_install_origin = ""
	if is_instance_valid(panel):
		panel.visible = true
		if is_instance_valid(manager_window):
			manager_window.show()
		_sync_companion_preview_visibility()
		_rebuild()
	event_bus.publish(&"click_through.refresh_requested", {})


func _on_package_failed(payload: Dictionary) -> void:
	pending_install_origin = ""
	if is_instance_valid(status_label):
		status_label.text = "Install failed: " + str(
			payload.get("error", "Unknown error")
		)
	if is_instance_valid(panel):
		panel.visible = true
		if is_instance_valid(manager_window):
			manager_window.show()
		_sync_companion_preview_visibility()
	event_bus.publish(&"click_through.refresh_requested", {})


func _configure_uninstall_confirmation() -> void:
	if not is_instance_valid(manager_window) or is_instance_valid(uninstall_confirmation):
		return
	uninstall_confirmation = ConfirmationDialog.new()
	uninstall_confirmation.title = "Uninstall character"
	uninstall_confirmation.ok_button_text = "Uninstall"
	uninstall_confirmation.cancel_button_text = "Cancel"
	uninstall_confirmation.exclusive = true
	manager_window.add_child(uninstall_confirmation)
	uninstall_confirmation.confirmed.connect(_confirm_uninstall)
	uninstall_confirmation.canceled.connect(func(): pending_uninstall.clear())


func _configure_rename_dialog() -> void:
	if not is_instance_valid(manager_window) or is_instance_valid(rename_dialog):
		return
	rename_dialog = ConfirmationDialog.new()
	rename_dialog.title = _localized_text("character.customize_title", "Customize companion")
	rename_dialog.ok_button_text = _localized_text("common.save", "Save")
	rename_dialog.cancel_button_text = _localized_text("common.cancel", "Cancel")
	rename_dialog.exclusive = true
	manager_window.add_child(rename_dialog)

	var content := VBoxContainer.new()
	content.name = "RenameContent"
	content.position = Vector2(24, 54)
	content.size = Vector2(470, 164)
	content.add_theme_constant_override("separation", 8)
	var package_label := Label.new()
	package_label.name = "RenamePackageNameLabel"
	content.add_child(package_label)
	var prompt := Label.new()
	prompt.name = "RenamePromptLabel"
	prompt.text = _localized_text("character.display_name", "Display name")
	content.add_child(prompt)
	rename_input = LineEdit.new()
	rename_input.name = "RenameCompanionInput"
	rename_input.placeholder_text = _localized_text("character.display_name_placeholder", "Enter a name")
	rename_input.custom_minimum_size = Vector2(430, 42)
	content.add_child(rename_input)
	var hint := Label.new()
	hint.name = "RenameHintLabel"
	hint.text = _localized_text("character.rename_hint", "Leave blank to use the package name.")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(hint)
	var reset := Button.new()
	reset.name = "RenameResetButton"
	reset.text = _localized_text("character.reset_name", "Use package name")
	reset.pressed.connect(_reset_rename_input)
	content.add_child(reset)
	rename_dialog.add_child(content)
	rename_dialog.confirmed.connect(_confirm_rename)


func _request_rename(package_id: String, package_name: String) -> void:
	if not is_instance_valid(rename_dialog) or not is_instance_valid(rename_input):
		return
	rename_package_id = package_id
	rename_package_name = package_name
	var aliases_value: Variant = context.settings.get("character_aliases", {}) if is_instance_valid(context) else {}
	var aliases: Dictionary = aliases_value.duplicate(true) if aliases_value is Dictionary else {}
	rename_input.text = str(aliases.get(package_id, ""))
	var package_label := rename_dialog.find_child("RenamePackageNameLabel", true, false) as Label
	if is_instance_valid(package_label):
		package_label.text = "%s: %s" % [
			_localized_text("character.package_name", "Package name"),
			package_name,
		]
	var prompt := rename_dialog.find_child("RenamePromptLabel", true, false) as Label
	if is_instance_valid(prompt):
		prompt.text = _localized_text("character.display_name", "Display name")
	var hint := rename_dialog.find_child("RenameHintLabel", true, false) as Label
	if is_instance_valid(hint):
		hint.text = _localized_text("character.rename_hint", "Leave blank to use the package name.")
	var reset := rename_dialog.find_child("RenameResetButton", true, false) as Button
	if is_instance_valid(reset):
		reset.text = _localized_text("character.reset_name", "Use package name")
	rename_dialog.title = _localized_text("character.customize_title", "Customize companion")
	rename_dialog.ok_button_text = _localized_text("common.save", "Save")
	rename_dialog.cancel_button_text = _localized_text("common.cancel", "Cancel")
	rename_dialog.popup_centered(Vector2i(520, 300))
	rename_input.grab_focus()


func _reset_rename_input() -> void:
	if is_instance_valid(rename_input):
		rename_input.text = ""


func _confirm_rename() -> void:
	if rename_package_id.is_empty() or not is_instance_valid(rename_input):
		return
	var aliases_value: Variant = context.settings.get("character_aliases", {}) if is_instance_valid(context) else {}
	var aliases: Dictionary = aliases_value.duplicate(true) if aliases_value is Dictionary else {}
	var desired := rename_input.text.strip_edges()
	if desired.is_empty() or desired == rename_package_name:
		aliases.erase(rename_package_id)
	else:
		aliases[rename_package_id] = desired
	if services.settings_service.save_settings({"character_aliases": aliases}):
		if is_instance_valid(status_label):
			status_label.text = _localized_text("character.name_saved", "Display name saved.")
		event_bus.publish(&"character.display_name_changed", {
			"package_id": rename_package_id,
			"display_name": desired if not desired.is_empty() else rename_package_name,
		})
		_rebuild()
	else:
		if is_instance_valid(status_label):
			status_label.text = _localized_text("character.name_save_failed", "Could not save display name.")


func _request_uninstall(
	package_id: String,
	version: String,
	display_name: String,
	is_active: bool,
	is_owned: bool = false
) -> void:
	if not is_instance_valid(uninstall_confirmation):
		return
	pending_uninstall = {
		"package_id": package_id,
		"version": version,
	}
	var active_warning := "\n\nAnother installed character will be activated automatically." if is_active else ""
	var ownership_note := "\n\nYour purchase and progression will remain in your Library." if is_owned else ""
	uninstall_confirmation.dialog_text = "Uninstall %s?\n%s@%s%s%s" % [
		display_name,
		package_id,
		version,
		ownership_note,
		active_warning,
	]
	uninstall_confirmation.popup_centered(Vector2i(520, 220))


func _confirm_uninstall() -> void:
	if pending_uninstall.is_empty():
		return
	event_bus.publish(&"character.uninstall_requested", pending_uninstall.duplicate(true))
	pending_uninstall.clear()


func _activate_package(package_id: String, version: String) -> void:
	event_bus.publish(&"character.activate_requested", {
		"package_id": package_id,
		"version": version,
	})


func _apply_selected_package() -> void:
	if selected_package.is_empty():
		return
	_activate_package(str(selected_package.get("packageId", "")), str(selected_package.get("version", "")))


func _preview_selected_character() -> void:
	if preview_frames == null:
		return
	if preview_frames.has_animation("idle"):
		selected_animation = "idle"
	_play_selected_animation()
	_rebuild_animation_list("")


func _run_selected_secondary_action() -> void:
	if selected_projection.is_empty():
		return
	if str(selected_projection.get("secondary_action", "Details")) == "Edit":
		_request_rename(
			str(selected_projection.get("package_id", "")),
			str(selected_projection.get("display_name", ""))
		)
	elif is_instance_valid(status_label):
		status_label.text = "Package details are shown in About."


func _request_selected_uninstall() -> void:
	if selected_projection.is_empty() or not bool(selected_projection.get("installed", false)):
		return
	_request_uninstall(
		str(selected_projection.get("package_id", "")),
		str(selected_projection.get("version", "")),
		str(selected_projection.get("display_name", "")),
		bool(selected_projection.get("active", false)),
		bool(selected_projection.get("owned", false))
	)


func _select_preview_package(package_info: Dictionary) -> void:
	selected_package = package_info.duplicate(true)
	selected_projection = _projection_for_package(
		str(selected_package.get("packageId", "")),
		str(selected_package.get("version", ""))
	)
	_refresh_selected_details()
	preview_frames = null
	selected_animation = ""
	# A newly selected character must expose its complete catalogue first. Users
	# can still filter afterwards, but a stale Movement/Surface filter should not
	# make the new package appear to have no icon tiles.
	if is_instance_valid(animation_category):
		animation_category.select(0)
	if is_instance_valid(preview_sprite):
		preview_sprite.stop()
		preview_sprite.sprite_frames = null
	var character_service: Variant = services.get("character_service") if is_instance_valid(services) else null
	if character_service == null or not character_service.has_method("build_preview_frames"):
		_set_preview_status("Preview unavailable.")
		_rebuild_animation_list("")
		return
	var result: Dictionary = character_service.call("build_preview_frames", selected_package)
	if not bool(result.get("ok", false)):
		_set_preview_status("Preview unavailable: " + str(result.get("error", "Unknown error")))
		_rebuild_animation_list("")
		return
	preview_frames = result.get("frames") as SpriteFrames
	if preview_frames == null:
		_set_preview_status("Preview unavailable.")
		_rebuild_animation_list("")
		return
	var names: Array = []
	for animation_name in preview_frames.get_animation_names():
		names.append(str(animation_name))
	names.sort()
	selected_animation = "idle" if names.has("idle") else (str(names[0]) if not names.is_empty() else "")
	_set_preview_status("Selected: %s (%d animations)" % [selected_animation, names.size()])
	_rebuild_animation_list("")
	_play_selected_animation()


func _refresh_selected_details() -> void:
	if selected_projection.is_empty():
		return
	var package_id := str(selected_projection.get("package_id", ""))
	var display_name := str(selected_projection.get("display_name", package_id))
	var aliases_value: Variant = context.settings.get("character_aliases", {}) if is_instance_valid(context) else {}
	var aliases: Dictionary = aliases_value if aliases_value is Dictionary else {}
	var alias := str(aliases.get(package_id, "")).strip_edges()
	if not alias.is_empty():
		display_name = alias
	if is_instance_valid(selected_character_title):
		selected_character_title.text = display_name
	if is_instance_valid(selected_character_badges):
		selected_character_badges.text = "  ·  ".join(LibraryProjectionScript.status_labels(selected_projection))
	if is_instance_valid(selected_character_meta):
		var publisher := str(selected_projection.get("publisher", "")).strip_edges()
		selected_character_meta.text = "%s  ·  v%s" % [
			publisher if not publisher.is_empty() else package_id,
			str(selected_projection.get("version", "—")),
		]
	if is_instance_valid(selected_character_about):
		var manifest: Dictionary = selected_projection.get("manifest", {})
		var license := str(manifest.get("license", "Not specified"))
		selected_character_about.text = "Package ID\n%s\n\nPublisher\n%s\n\nVersion\n%s\n\nLicense\n%s" % [
			package_id,
			str(selected_projection.get("publisher", "Not specified")),
			str(selected_projection.get("version", "—")),
			license,
		]
	if is_instance_valid(selected_secondary_action):
		selected_secondary_action.text = str(selected_projection.get("secondary_action", "Details"))
	if is_instance_valid(selected_use_action):
		selected_use_action.text = "Active" if bool(selected_projection.get("active", false)) else "Use This Character"
		selected_use_action.disabled = bool(selected_projection.get("active", false)) or not bool(selected_projection.get("installed", false))
	if is_instance_valid(selected_uninstall_action):
		selected_uninstall_action.text = "Uninstall"
		selected_uninstall_action.disabled = not bool(selected_projection.get("installed", false))


func _rebuild_animation_list(_ignored: Variant = null) -> void:
	if not is_instance_valid(animation_list):
		return
	for child in animation_list.get_children():
		animation_list.remove_child(child)
		child.queue_free()
	if preview_frames == null:
		return
	var query := animation_search.text.strip_edges().to_lower() if is_instance_valid(animation_search) else ""
	var category := animation_category.get_item_text(animation_category.selected) if is_instance_valid(animation_category) else "All"
	var names: Array[String] = []
	for animation_name in preview_frames.get_animation_names():
		var name := str(animation_name)
		if not query.is_empty() and not name.to_lower().contains(query):
			continue
		if category != "All" and _animation_category(name) != category:
			continue
		names.append(name)
	names.sort()
	_set_animation_gallery_label(names.size(), preview_frames.get_animation_names().size())
	for name in names:
		var button := Button.new()
		button.name = "AnimationItem_" + name
		button.tooltip_text = name
		button.text = ""
		button.alignment = HORIZONTAL_ALIGNMENT_CENTER
		button.toggle_mode = true
		button.button_pressed = name == selected_animation
		button.custom_minimum_size = Vector2(82, 88)
		button.add_theme_color_override("font_color", Color("#f4f7ff"))
		button.add_theme_stylebox_override("normal", _animation_button_style(name == selected_animation, false))
		button.add_theme_stylebox_override("hover", _animation_button_style(name == selected_animation, true))
		button.add_theme_stylebox_override("pressed", _animation_button_style(true, true))
		var content := VBoxContainer.new()
		content.mouse_filter = Control.MOUSE_FILTER_IGNORE
		content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 7)
		content.add_theme_constant_override("separation", 2)
		button.add_child(content)
		var icon := AnimationTileIconScript.new()
		icon.name = "AnimationTileIcon"
		icon.animation_name = name
		icon.custom_minimum_size = Vector2(0, 45)
		icon.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		content.add_child(icon)
		var label := Label.new()
		label.text = _animation_display_name(name)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_font_size_override("font_size", 10)
		label.add_theme_color_override("font_color", Color("#dce9ff"))
		content.add_child(label)
		button.pressed.connect(Callable(self, "_choose_preview_animation").bind(name))
		animation_list.add_child(button)
	if names.is_empty():
		var empty := Label.new()
		empty.text = "No matching animations."
		animation_list.add_child(empty)
	elif is_instance_valid(animation_list):
		animation_list.tooltip_text = "Showing %d animation tiles" % names.size()


func _animation_category(name: String) -> String:
	var value := name.to_lower()
	if value.contains("walk") or value.contains("run") or value.contains("move"):
		return "Movement"
	if value.contains("climb") or value.contains("hang") or value.contains("fall") or value.contains("land"):
		return "Surface"
	if value.contains("appear") or value.contains("disappear") or value.contains("teleport") or value.contains("transition"):
		return "Transitions"
	return "Other"


func _animation_button_style(selected: bool, hovered: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("#102f58") if selected else (Color("#0c2442") if hovered else Color("#07172b"))
	style.border_color = Color("#27c7ff") if selected else Color("#21496f")
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	return style


func _animation_display_name(name: String) -> String:
	var words := name.replace("_", " ").capitalize()
	return words.replace("Teleport ", "Teleport\n") if words.length() > 12 else words


func _set_animation_gallery_label(shown: int, total: int) -> void:
	if not is_instance_valid(animation_list):
		return
	var scroll: Node = animation_list.get_parent()
	var controls: Node = scroll.get_parent() if is_instance_valid(scroll) else null
	if not is_instance_valid(controls):
		return
	var label := controls.find_child("AnimationGalleryLabel", true, false) as Label
	if is_instance_valid(label):
		label.text = "Animation library — %d of %d clips" % [shown, total]


func _on_animation_category_selected(_index: int) -> void:
	_rebuild_animation_list("")


func _choose_preview_animation(name: String) -> void:
	selected_animation = name
	_play_selected_animation()
	_set_preview_status("Selected: %s (%d animations)" % [
		selected_animation,
		preview_frames.get_animation_names().size() if preview_frames != null else 0,
	])
	_rebuild_animation_list("")


func _play_selected_animation() -> void:
	if preview_frames == null or selected_animation.is_empty() or not preview_frames.has_animation(selected_animation):
		return
	if is_instance_valid(preview_sprite):
		preview_sprite.sprite_frames = preview_frames
		preview_sprite.animation = StringName(selected_animation)
		preview_sprite.play()
	if is_instance_valid(preview_play_button):
		preview_play_button.text = "II"
		preview_play_button.tooltip_text = "Pause animation"


func _toggle_preview_playback() -> void:
	if not is_instance_valid(preview_sprite) or preview_frames == null:
		return
	if preview_sprite.is_playing():
		preview_sprite.pause()
		if is_instance_valid(preview_play_button):
			preview_play_button.text = ">"
			preview_play_button.tooltip_text = "Play animation"
	else:
		_play_selected_animation()


func _set_preview_loop(enabled: bool) -> void:
	if preview_frames != null and not selected_animation.is_empty() and preview_frames.has_animation(selected_animation):
		preview_frames.set_animation_loop(selected_animation, enabled)


func _set_preview_speed(index: int) -> void:
	if is_instance_valid(preview_sprite) and is_instance_valid(preview_speed):
		preview_sprite.speed_scale = float(preview_speed.get_item_metadata(index))


func _set_preview_status(message: String) -> void:
	if is_instance_valid(preview_status):
		preview_status.text = message


func _center_picker_if_needed() -> void:
	if not is_instance_valid(panel):
		return

	var viewport_size: Vector2 = panel.get_viewport_rect().size
	var position_is_invalid: bool = (
		panel.position.x < 0.0
		or panel.position.y < 0.0
		or panel.position.x + panel.size.x > viewport_size.x
		or panel.position.y + panel.size.y > viewport_size.y
	)

	if position_is_invalid:
		panel.position = Vector2(
			maxf(12.0, (viewport_size.x - panel.size.x) * 0.5),
			maxf(12.0, (viewport_size.y - panel.size.y) * 0.5)
		)


func _localized_text(key: String, fallback: String) -> String:
	var localization_service := services.get_node_or_null("LocalizationService") if is_instance_valid(services) else null
	if is_instance_valid(localization_service) and localization_service.has_method("text"):
		return str(localization_service.call("text", key, fallback))
	return fallback


func _rebuild() -> void:
	for child in list_container.get_children():
		child.queue_free()

	var entries := _character_projection()
	var installed_entries: Array[Dictionary] = []
	for entry in entries:
		if bool(entry.get("installed", false)):
			installed_entries.append(entry)
	if installed_entries.is_empty():
		var empty_label := Label.new()
		empty_label.text = _localized_text("character.empty", "No installed characters.")
		list_container.add_child(empty_label)
		return

	var selected_found := false
	var active_package: Dictionary = {}
	for entry in installed_entries:
		var package_info: Dictionary = entry.get("package", {})
		var package_id := str(entry.get("package_id", ""))
		var version := str(entry.get("version", ""))
		var package_name := str(entry.get("display_name", package_id))
		var is_active := bool(entry.get("active", false))
		var aliases_value: Variant = context.settings.get("character_aliases", {}) if is_instance_valid(context) else {}
		var aliases: Dictionary = aliases_value if aliases_value is Dictionary else {}
		var alias := str(aliases.get(package_id, "")).strip_edges()
		var display_name := alias if not alias.is_empty() else package_name

		var card := PanelContainer.new()
		card.name = "CharacterCard"
		card.tooltip_text = "Preview %s" % display_name
		card.set_meta("ocp_library_entry", entry.duplicate(true))
		card.set_meta("ocp_selected", str(selected_package.get("packageId", "")) == package_id)
		var row := VBoxContainer.new()
		row.name = "CharacterCardContent"
		row.add_theme_constant_override("separation", 8)
		card.add_child(row)
		var summary := HBoxContainer.new()
		summary.name = "CharacterCardSummary"
		summary.add_theme_constant_override("separation", 10)
		row.add_child(summary)
		var thumbnail := TextureRect.new()
		thumbnail.name = "CharacterThumbnail"
		thumbnail.custom_minimum_size = Vector2(76, 94)
		thumbnail.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumbnail.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		thumbnail.texture = _package_thumbnail(package_info)
		thumbnail.mouse_filter = Control.MOUSE_FILTER_IGNORE
		summary.add_child(thumbnail)
		var copy := VBoxContainer.new()
		copy.name = "CharacterCardCopy"
		copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		copy.alignment = BoxContainer.ALIGNMENT_CENTER
		copy.add_theme_constant_override("separation", 4)
		summary.add_child(copy)
		var name_label := Label.new()
		name_label.name = "CharacterName"
		name_label.text = display_name
		name_label.add_theme_font_size_override("font_size", 16)
		copy.add_child(name_label)
		var status := Label.new()
		status.name = "CharacterStatus"
		status.text = " · ".join(LibraryProjectionScript.status_labels(entry))
		status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		copy.add_child(status)
		var version_label := Label.new()
		version_label.name = "CharacterVersion"
		version_label.text = "v%s  ·  %s" % [version, package_id]
		version_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		copy.add_child(version_label)
		if is_active:
			active_package = package_info.duplicate(true)
		if str(selected_package.get("packageId", "")) == package_id \
		and str(selected_package.get("version", "")) == version:
			selected_found = true
		var actions := HBoxContainer.new()
		actions.name = "CharacterCardActions"
		actions.add_theme_constant_override("separation", 5)
		actions.visible = not is_instance_valid(selected_preview_action)
		row.add_child(actions)
		var preview_button := Button.new()
		preview_button.name = "PreviewButton"
		preview_button.text = "Preview"
		preview_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		preview_button.pressed.connect(
			Callable(self, "_select_preview_package").bind(package_info.duplicate(true))
		)
		actions.add_child(preview_button)

		var customize_button := Button.new()
		customize_button.name = "CustomizeButton"
		customize_button.text = str(entry.get("secondary_action", "Details"))
		if customize_button.text == "Edit":
			customize_button.pressed.connect(
				Callable(self, "_request_rename").bind(package_id, package_name)
			)
		else:
			customize_button.pressed.connect(func(): _select_preview_package(package_info.duplicate(true)))
		actions.add_child(customize_button)

		var activate_button := Button.new()
		activate_button.name = "ActivateButton"
		activate_button.text = "Active" if is_active else "Use"
		activate_button.disabled = is_active
		activate_button.pressed.connect(
			Callable(self, "_activate_package").bind(package_id, version)
		)
		actions.add_child(activate_button)

		var uninstall_button := Button.new()
		uninstall_button.name = "UninstallButton"
		uninstall_button.text = "Uninstall"
		uninstall_button.pressed.connect(
			Callable(self, "_request_uninstall").bind(
				package_id,
				version,
				display_name,
				is_active,
				bool(entry.get("owned", false))
			)
		)
		actions.add_child(uninstall_button)
		list_container.add_child(card)
	if not selected_found:
		_select_preview_package(active_package if not active_package.is_empty() else installed_entries[0].get("package", {}))


func _package_thumbnail(package_info: Dictionary) -> Texture2D:
	var character_service: Variant = services.get("character_service") if is_instance_valid(services) else null
	if character_service != null and character_service.has_method("build_preview_thumbnail"):
		var thumbnail_result: Dictionary = character_service.call("build_preview_thumbnail", package_info)
		var thumbnail := thumbnail_result.get("texture") as Texture2D if bool(thumbnail_result.get("ok", false)) else null
		if thumbnail != null:
			return thumbnail
	if character_service != null and character_service.has_method("build_preview_frames"):
		var result: Dictionary = character_service.call("build_preview_frames", package_info)
		var frames := result.get("frames") as SpriteFrames if bool(result.get("ok", false)) else null
		if frames != null:
			var animation: StringName = &"idle" if frames.has_animation(&"idle") else (
				frames.get_animation_names()[0] if not frames.get_animation_names().is_empty() else &""
			)
			if animation != &"" and frames.get_frame_count(animation) > 0:
				var texture: Texture2D = frames.get_frame_texture(animation, 0)
				if texture != null:
					return texture
	return load("res://assets/icons/ocp.svg") as Texture2D
