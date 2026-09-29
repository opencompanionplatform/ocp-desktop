extends Node
class_name RuntimeV3Services

var character_service: Node
var package_service: Node
var effect_pack_service: Node
var registry_service: Node
var settings_service: Node
var ai_service: Node
var tts_service: Node
var memory_service: Node
var credential_service: Node
var cloud_session_service: Node
var cloud_auth_service: Node
var cloud_device_service: Node
var cloud_library_service: Node
var cloud_download_service: Node
var cloud_deep_link_service: Node
var progression_queue_service: Node
var cloud_progression_service: Node
var progression_event_service: Node
var cloud_operations_service: Node
var bridge_adapter: Node
var tray_service: Node
var monitor_window_service: Node
var world_debug: Node
var native_presentation: Node
var native_host_lifecycle: Node
var update_service: Node
var resource_monitor_service: Node
var theme_service: Node
var localization_service: Node
var startup_registration_service: Node
var desktop_shell_adapter: Node


func register_service(service_name: StringName, service: Node) -> void:
	match service_name:
		&"character": character_service = service
		&"package": package_service = service
		&"effect_pack": effect_pack_service = service
		&"registry": registry_service = service
		&"settings": settings_service = service
		&"ai": ai_service = service
		&"tts": tts_service = service
		&"memory": memory_service = service
		&"credentials": credential_service = service
		&"cloud_session": cloud_session_service = service
		&"cloud_auth": cloud_auth_service = service
		&"cloud_device": cloud_device_service = service
		&"cloud_library": cloud_library_service = service
		&"cloud_download": cloud_download_service = service
		&"cloud_deep_link": cloud_deep_link_service = service
		&"progression_queue": progression_queue_service = service
		&"cloud_progression": cloud_progression_service = service
		&"progression_events": progression_event_service = service
		&"cloud_operations": cloud_operations_service = service
		&"bridge": bridge_adapter = service
		&"tray": tray_service = service
		&"monitor_windows": monitor_window_service = service
		&"world_debug": world_debug = service
		&"native_presentation": native_presentation = service
		&"native_host_lifecycle": native_host_lifecycle = service
		&"update": update_service = service
		&"resource_monitor": resource_monitor_service = service
		&"theme": theme_service = service
		&"localization": localization_service = service
		&"startup_registration": startup_registration_service = service
		&"desktop_shell_adapter": desktop_shell_adapter = service
		_: push_warning(
			"RuntimeV3Services: unknown service %s" % service_name
		)


func all_ready() -> bool:
	return is_instance_valid(character_service) \
		and is_instance_valid(package_service) \
		and is_instance_valid(registry_service) \
		and is_instance_valid(settings_service) \
		and is_instance_valid(ai_service) \
		and is_instance_valid(tts_service) \
		and is_instance_valid(memory_service) \
		and is_instance_valid(credential_service)
