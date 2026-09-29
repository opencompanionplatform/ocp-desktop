extends SceneTree

func _initialize() -> void:
	var archive := ProjectSettings.globalize_path("user://downloads/cloud/character_sabai-sompoo-1.0.1.ocp")
	var root := ProjectSettings.globalize_path("user://packages/staging-verify-smoke")
	var trust_path := ProjectSettings.globalize_path("res://../../../config/marketplace-trust/staging/marketplace-bundle.json")
	var trust := FileAccess.get_file_as_string(trust_path)
	if trust.is_empty():
		push_error("staging trust bundle is missing")
		quit(3)
		return
	var bridge := OcpRuntimeBridge.new()
	get_root().add_child(bridge)
	var result: Dictionary = bridge.install_cloud_package(
		archive,
		root,
		"fd18e1773b8b58571a4b1bad1b8ebc051026f0df1efc1c52b035086763d62863",
		"ed25519:ocp-official-8624ea86710baaded5eedd08",
		"base64:9MdfpmT/Q1ob/0AGyIxc1vathSCuU5aoqCc4gzDwkBsAjF6uTqhQzq2w35yDaQFTkektgizh4EmahpHntHSKCQ==",
		trust
	)
	print("[STAGING-CLOUD-VERIFY] ", JSON.stringify(result))
	quit(0 if bool(result.get("ok", false)) else 2)
