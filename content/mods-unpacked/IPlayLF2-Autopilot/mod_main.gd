extends Node

const MOD_ID := "IPlayLF2-Autopilot"
const MAIN_EXTENSION := "res://mods-unpacked/IPlayLF2-Autopilot/extensions/main.gd"


func _init() -> void:
	ModLoaderMod.install_script_extension(MAIN_EXTENSION)
	ModLoaderLog.info("Initialized.", MOD_ID)
