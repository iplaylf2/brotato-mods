extends Node

signal enabled_changed(enabled)
signal sampling_enabled_changed(enabled)

const MOD_ID := "iplaylf2-autopilot"
const MAIN_EXTENSION := "res://mods-unpacked/iplaylf2-autopilot/extensions/main.gd"
const RUN_DATA_EXTENSION := "res://mods-unpacked/iplaylf2-autopilot/extensions/run_data.gd"
const MOD_OPTIONS_PATH := "/root/ModLoader/dami-ModOptions/ModsConfigInterface"
const CUSTOM_CONFIG_NAME := "custom"
const ENABLED_SETTING := "enabled"
const SAMPLING_ENABLED_SETTING := "sampling_enabled"

var _enabled := false
var _sampling_enabled := false
var _mod_options: Node = null


func _init() -> void:
	ModLoaderMod.install_script_extension(MAIN_EXTENSION)
	ModLoaderMod.install_script_extension(RUN_DATA_EXTENSION)
	ModLoaderLog.info("Initialized.", MOD_ID)


func _ready() -> void:
	# ModLoader 6.3 updates existing user profiles in its own _ready(). Mod mains
	# are children of ModLoader, so their _ready() runs first. Defer config setup
	# until the profile contains this newly installed mod.
	call_deferred("_initialize_runtime")


func _initialize_runtime() -> void:
	var config: ModConfig = _get_or_repair_current_config()
	_apply_config(config)

	# The target game's Godot build cannot type-check a direct typed assignment
	# from Object.connect(), even though the method returns an Error code.
	var current_config_error: int
	current_config_error = ModLoader.connect(
		"current_config_changed", self, "_on_current_config_changed"
	)
	if current_config_error != OK:
		ModLoaderLog.error("Could not subscribe to ModLoader config changes.", MOD_ID)

	_mod_options = get_node_or_null(MOD_OPTIONS_PATH)
	if not is_instance_valid(_mod_options):
		ModLoaderLog.error("Required Mod Options interface was not found.", MOD_ID)
		return

	var setting_error: int
	setting_error = _mod_options.connect("setting_changed", self, "_on_mod_options_setting_changed")
	if setting_error != OK:
		ModLoaderLog.error("Could not subscribe to Mod Options setting changes.", MOD_ID)


func is_enabled() -> bool:
	return _enabled


func is_sampling_enabled() -> bool:
	return _sampling_enabled


func _on_current_config_changed(config: ModConfig) -> void:
	if config == null or config.mod_id != MOD_ID:
		return
	_apply_config(config)


func _on_mod_options_setting_changed(setting_name, value, mod_id) -> void:
	if (
		mod_id != MOD_ID
		or (setting_name != ENABLED_SETTING and setting_name != SAMPLING_ENABLED_SETTING)
	):
		return

	if _save_setting(setting_name, value):
		if setting_name == ENABLED_SETTING:
			_set_enabled(bool(value))
		else:
			_set_sampling_enabled(bool(value))


func _apply_config(config: ModConfig) -> void:
	if config == null or not config.is_valid:
		_set_enabled(false)
		_set_sampling_enabled(false)
		return

	_set_enabled(bool(config.data.get(ENABLED_SETTING, false)))
	_set_sampling_enabled(bool(config.data.get(SAMPLING_ENABLED_SETTING, false)))


func _get_or_repair_current_config() -> ModConfig:
	var config: ModConfig = ModLoaderConfig.get_current_config(MOD_ID)
	if config != null:
		return config

	config = ModLoaderConfig.get_default_config(MOD_ID)
	if config == null:
		ModLoaderLog.error(
			"No valid default configuration is available; control and sampling are disabled.",
			MOD_ID
		)
		return null

	# ModLoader 6.3 profiles created before a mod gained a config schema can lack
	# current_config. Selecting the generated default repairs and persists that
	# profile entry through ModData's current_config setter.
	ModLoaderConfig.set_current_config(config)
	ModLoaderLog.info(
		"Selected the default configuration because the current profile had no Autopilot configuration.",
		MOD_ID
	)
	return config


func _save_setting(setting_name: String, value) -> bool:
	var config: ModConfig = _get_or_repair_current_config()
	if config == null:
		return false

	if config.name == ModLoaderConfig.DEFAULT_CONFIG_NAME:
		var config_data: Dictionary = config.data.duplicate(true)
		config_data[setting_name] = value
		var configs: Dictionary = ModLoaderConfig.get_configs(MOD_ID)

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


func _set_sampling_enabled(value: bool) -> void:
	if _sampling_enabled == value:
		return

	_sampling_enabled = value
	emit_signal("sampling_enabled_changed", _sampling_enabled)
