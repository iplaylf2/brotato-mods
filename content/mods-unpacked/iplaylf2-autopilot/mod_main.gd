extends Node

signal enabled_changed(enabled)

const MOD_ID := "iplaylf2-autopilot"
const MAIN_EXTENSION := "res://mods-unpacked/iplaylf2-autopilot/extensions/main.gd"
const MOD_OPTIONS_PATH := "/root/ModLoader/dami-ModOptions/ModsConfigInterface"
const CUSTOM_CONFIG_NAME := "custom"
const ENABLED_SETTING := "enabled"

var _enabled := false
var _mod_options: Node = null


func _init() -> void:
	ModLoaderMod.install_script_extension(MAIN_EXTENSION)
	ModLoaderLog.info("Initialized.", MOD_ID)


func _ready() -> void:
	var config: ModConfig = ModLoaderConfig.get_current_config(MOD_ID)
	_apply_config(config)

	var current_config_error := ModLoader.connect(
		"current_config_changed", self, "_on_current_config_changed"
	)
	if current_config_error != OK:
		ModLoaderLog.error("Could not subscribe to ModLoader config changes.", MOD_ID)

	_mod_options = get_node_or_null(MOD_OPTIONS_PATH)
	if not is_instance_valid(_mod_options):
		ModLoaderLog.error("Required Mod Options interface was not found.", MOD_ID)
		return

	var setting_error := _mod_options.connect(
		"setting_changed", self, "_on_mod_options_setting_changed"
	)
	if setting_error != OK:
		ModLoaderLog.error("Could not subscribe to Mod Options setting changes.", MOD_ID)


func is_enabled() -> bool:
	return _enabled


func _on_current_config_changed(config: ModConfig) -> void:
	if config.mod_id == MOD_ID:
		_apply_config(config)


func _on_mod_options_setting_changed(setting_name, value, mod_id) -> void:
	if mod_id != MOD_ID or setting_name != ENABLED_SETTING:
		return

	if _save_setting(setting_name, value):
		_set_enabled(bool(value))


func _apply_config(config: ModConfig) -> void:
	if config == null or not config.is_valid:
		_set_enabled(false)
		return

	_set_enabled(bool(config.data.get(ENABLED_SETTING, false)))


func _save_setting(setting_name: String, value) -> bool:
	var config: ModConfig = ModLoaderConfig.get_current_config(MOD_ID)
	if config == null:
		return false

	if config.name == ModLoaderConfig.DEFAULT_CONFIG_NAME:
		var config_data := config.data.duplicate(true)
		config_data[setting_name] = value
		var configs := ModLoaderConfig.get_configs(MOD_ID)

		if configs.has(CUSTOM_CONFIG_NAME):
			config = configs[CUSTOM_CONFIG_NAME]
			config.data = config_data
			if ModLoaderConfig.update_config(config) == null:
				return false
		else:
			config = ModLoaderConfig.create_config(MOD_ID, CUSTOM_CONFIG_NAME, config_data)
			if config == null:
				return false

		ModLoaderConfig.set_current_config(config)
	else:
		config.data[setting_name] = value
		if ModLoaderConfig.update_config(config) == null:
			return false

	if is_instance_valid(_mod_options):
		_mod_options.load_config(ModLoaderMod.get_mod_data(MOD_ID))

	return true


func _set_enabled(value: bool) -> void:
	if _enabled == value:
		return

	_enabled = value
	emit_signal("enabled_changed", _enabled)
