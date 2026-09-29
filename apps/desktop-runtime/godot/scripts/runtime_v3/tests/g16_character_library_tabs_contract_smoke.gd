extends SceneTree

const ShellScript = preload("res://scripts/runtime_v3/ui/character_manager_shell.gd")

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var shell := ShellScript.new()
	var picker_vbox := VBoxContainer.new()
	var install := Button.new()
	install.name = "InstallPackageButton"
	picker_vbox.add_child(install)
	var status := Label.new()
	status.name = "PickerStatusLabel"
	picker_vbox.add_child(status)
	var scroll := ScrollContainer.new()
	scroll.name = "PickerScroll"
	picker_vbox.add_child(scroll)
	var installed_list := VBoxContainer.new()
	installed_list.name = "CharacterList"
	scroll.add_child(installed_list)

	shell._build_character_workspace(picker_vbox)
	var installed_tab := picker_vbox.find_child("InstalledLibraryTab", true, false) as Button
	var cloud_tab := picker_vbox.find_child("CloudLibraryTab", true, false) as Button
	var installed_view := picker_vbox.find_child("InstalledLibraryView", true, false) as Control
	var cloud_view := picker_vbox.find_child("CloudLibraryView", true, false) as Control
	var cloud_list := picker_vbox.find_child("CloudLibraryList", true, false) as VBoxContainer
	var cloud_status := picker_vbox.find_child("CloudLibraryStatus", true, false) as Label
	var store := picker_vbox.find_child("ExploreCharacterStoreButton", true, false) as Button
	var workspace_title := picker_vbox.find_child("CharacterWorkspaceTitle", true, false) as Label
	var workspace_subtitle := picker_vbox.find_child("CharacterWorkspaceSubtitle", true, false) as Label
	var selected_title := picker_vbox.find_child("SelectedCharacterTitle", true, false) as Label
	var selected_badges := picker_vbox.find_child("SelectedCharacterBadges", true, false) as Label
	var selected_about := picker_vbox.find_child("SelectedCharacterAbout", true, false) as Label
	var selected_preview := picker_vbox.find_child("SelectedPreviewAction", true, false) as Button
	var selected_secondary := picker_vbox.find_child("SelectedSecondaryAction", true, false) as Button
	var selected_use := picker_vbox.find_child("SelectedUseAction", true, false) as Button
	var selected_uninstall := picker_vbox.find_child("SelectedUninstallAction", true, false) as Button
	var animation_catalog := picker_vbox.find_child("AnimationCatalog", true, false) as GridContainer

	var structure_ok := is_instance_valid(installed_tab) \
		and is_instance_valid(cloud_tab) \
		and is_instance_valid(installed_view) \
		and is_instance_valid(cloud_view) \
		and is_instance_valid(cloud_list) \
		and is_instance_valid(cloud_status) \
		and is_instance_valid(store) \
		and is_instance_valid(workspace_title) \
		and is_instance_valid(workspace_subtitle) \
		and is_instance_valid(selected_title) \
		and is_instance_valid(selected_badges) \
		and is_instance_valid(selected_about) \
		and is_instance_valid(selected_preview) \
		and is_instance_valid(selected_secondary) \
		and is_instance_valid(selected_use) \
		and is_instance_valid(selected_uninstall) \
		and is_instance_valid(animation_catalog)
	var default_state_ok := structure_ok \
		and installed_view.visible \
		and not cloud_view.visible \
		and installed_tab.button_pressed \
		and not cloud_tab.button_pressed \
		and cloud_status.text.contains("Sign in") \
		and cloud_tab.text == "Library" \
		and install.text == "Install .ocp" \
		and workspace_title.text == "Characters" \
		and workspace_subtitle.text == "Manage your companions" \
		and selected_secondary.text == "Details" \
		and selected_uninstall.text == "Uninstall" \
		and animation_catalog.columns == 3
	var local_install_preserved := install.get_parent() == picker_vbox.find_child("CharacterWorkspaceHeader", true, false)

	var ok := structure_ok and default_state_ok and local_install_preserved
	print("[G16.3] ownership_ui=%s default_installed=%s local_install=%s" % [
		str(structure_ok).to_lower(), str(default_state_ok).to_lower(), str(local_install_preserved).to_lower(),
	])
	picker_vbox.free()
	shell.free()
	await process_frame
	quit(0 if ok else 1)
