extends Node

const MOD_ID := "IPlayLF2-Demo"


func _init() -> void:
	ModLoaderLog.info("Demo mod initialized.", MOD_ID)


func _ready() -> void:
	ModLoaderLog.info("Demo mod ready.", MOD_ID)
