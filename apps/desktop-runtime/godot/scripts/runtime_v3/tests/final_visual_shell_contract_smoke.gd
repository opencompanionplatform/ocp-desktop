extends SceneTree

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# Build only the presentation windows from the packed scene.  Do not add the
	# RuntimeApp root to SceneTree here: doing so would start kernel/native
	# lifecycle services and collide with an interactive Runtime already open
	# during visual development.
	var packed := load("res://scenes/runtime_v3/RuntimeApp.tscn") as PackedScene
	var app := packed.instantiate()
	var control_center := app.get_node_or_null("ApplicationWindow") as Window
	var chat_window := app.get_node_or_null("ChatWindow") as Window
	var character_window := app.get_node_or_null("CharacterManagerWindow") as Window
	if is_instance_valid(control_center):
		control_center.call("_build_shell")
	if is_instance_valid(character_window):
		character_window.call("_build_shell")

	var identity := app.get_node_or_null("ChatWindow/ChatRoot/Chat/ChatLayout/ChatIdentityCard") as PanelContainer
	var chat_badge := chat_window.find_child("ChatConnectionBadge", true, false) as PanelContainer if is_instance_valid(chat_window) else null
	var assistant_avatar := chat_window.find_child("AssistantAvatar", true, false) as PanelContainer if is_instance_valid(chat_window) else null
	var identity_avatar_texture := chat_window.find_child("ChatIdentityAvatarTexture", true, false) as TextureRect if is_instance_valid(chat_window) else null
	var assistant_avatar_texture := chat_window.find_child("AssistantAvatarTexture", true, false) as TextureRect if is_instance_valid(chat_window) else null
	var chat_model_option := chat_window.find_child("ChatModelOption", true, false) as OptionButton if is_instance_valid(chat_window) else null
	var composer_stack := chat_window.find_child("ComposerStack", true, false) as VBoxContainer if is_instance_valid(chat_window) else null
	var composer_actions := chat_window.find_child("ComposerActions", true, false) as HBoxContainer if is_instance_valid(chat_window) else null
	var chat_input := chat_window.find_child("ChatInput", true, false) as TextEdit if is_instance_valid(chat_window) else null
	var voice_button := chat_window.find_child("VoiceChatButton", true, false) as Button if is_instance_valid(chat_window) else null
	var send_button := chat_window.find_child("SendChatButton", true, false) as Button if is_instance_valid(chat_window) else null
	var settings_body := app.get_node_or_null("ApplicationWindow/ApplicationRoot/ApplicationLayout/ApplicationTabs/Settings/SettingsLayout/SettingsScroll/MockSettingsBody")
	var text_scale := control_center.find_child("TextScaleOption", true, false) as OptionButton if is_instance_valid(control_center) else null
	var update_status_card := control_center.find_child("UpdateStatusCard", true, false) as PanelContainer if is_instance_valid(control_center) else null
	var update_security_card := control_center.find_child("UpdateSecurityCard", true, false) as PanelContainer if is_instance_valid(control_center) else null
	var update_actions_card := control_center.find_child("UpdateActionsCard", true, false) as PanelContainer if is_instance_valid(control_center) else null
	var character_workspace := character_window.find_child("CharacterWorkspace", true, false) as VBoxContainer if is_instance_valid(character_window) else null
	var character_preview := character_window.find_child("PreviewSprite", true, false) as AnimatedSprite2D if is_instance_valid(character_window) else null
	var character_aura := character_window.find_child("PreviewAura", true, false) as Control if is_instance_valid(character_window) else null
	var character_catalog := character_window.find_child("AnimationCatalog", true, false) as GridContainer if is_instance_valid(character_window) else null
	var character_store := character_window.find_child("ExploreCharacterStoreButton", true, false) as Button if is_instance_valid(character_window) else null
	var character_rail := character_window.get_node_or_null("CharacterNavigationRail") as PanelContainer if is_instance_valid(character_window) else null
	var ok := (
		is_instance_valid(control_center)
		and is_instance_valid(chat_window)
		and is_instance_valid(character_window)
		and is_instance_valid(identity)
		and is_instance_valid(chat_badge)
		and is_instance_valid(assistant_avatar)
		and is_instance_valid(identity_avatar_texture)
		and is_instance_valid(assistant_avatar_texture)
		and is_instance_valid(chat_model_option)
		and is_instance_valid(composer_stack)
		and is_instance_valid(composer_actions)
		and is_instance_valid(chat_input)
		and is_instance_valid(voice_button)
		and is_instance_valid(send_button)
		and chat_input.get_parent() == composer_stack
		and chat_model_option.get_parent() == composer_actions
		and voice_button.get_parent() == composer_actions
		and send_button.get_parent() == composer_actions
		and chat_model_option.item_count == 1
		and chat_model_option.get_item_text(0) == "Local"
		and is_instance_valid(settings_body)
		and is_instance_valid(text_scale)
		and text_scale.item_count == 5
		and str(text_scale.get_item_text(0)) == "Normal"
		and is_equal_approx(float(text_scale.get_item_metadata(0)), 1.0)
		and is_equal_approx(float(text_scale.get_item_metadata(1)), 1.15)
		and is_equal_approx(float(text_scale.get_item_metadata(2)), 1.30)
		and is_equal_approx(float(text_scale.get_item_metadata(3)), 1.50)
		and is_equal_approx(float(text_scale.get_item_metadata(4)), 1.80)
		and is_instance_valid(update_status_card)
		and is_instance_valid(update_security_card)
		and is_instance_valid(update_actions_card)
		and is_instance_valid(character_workspace)
		and is_instance_valid(character_preview)
		and is_instance_valid(character_aura)
		and is_instance_valid(character_catalog)
		and is_instance_valid(character_store)
		and is_instance_valid(character_rail)
		and not character_rail.visible
	)
	print("[P3.4.11] final_visual_shell chat_identity=", is_instance_valid(identity),
		" chat_badge=", is_instance_valid(chat_badge),
		" assistant_avatar=", is_instance_valid(assistant_avatar),
		" unified_composer=", is_instance_valid(composer_stack) and is_instance_valid(composer_actions),
		" settings_components=", is_instance_valid(settings_body),
		" text_scale=", is_instance_valid(text_scale),
		" update_cards=", is_instance_valid(update_status_card) and is_instance_valid(update_security_card) and is_instance_valid(update_actions_card),
		" character_workspace=", is_instance_valid(character_workspace),
		" character_preview=", is_instance_valid(character_preview),
		" character_aura=", is_instance_valid(character_aura),
		" character_store=", is_instance_valid(character_store))

	app.free()
	quit(0 if ok else 1)
