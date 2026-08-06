extends "res://singletons/run_data.gd"

const BATTLE_SAMPLE_RUN_ID_STATE_KEY := "iplaylf2_autopilot_battle_sample_run_id"

var _battle_sample_run_id := ""


func reset(restart: bool = false) -> void:
	.reset(restart)
	_battle_sample_run_id = _make_battle_sample_run_id()


func get_state() -> Dictionary:
	var state: Dictionary = .get_state()
	state[BATTLE_SAMPLE_RUN_ID_STATE_KEY] = get_battle_sample_run_id()
	return state


func resume_from_state(state: Dictionary) -> void:
	.resume_from_state(state)
	_battle_sample_run_id = str(state.get(BATTLE_SAMPLE_RUN_ID_STATE_KEY, ""))
	if _battle_sample_run_id.empty():
		_battle_sample_run_id = _make_battle_sample_run_id()


func get_battle_sample_run_id() -> String:
	if _battle_sample_run_id.empty():
		_battle_sample_run_id = _make_battle_sample_run_id()
	return _battle_sample_run_id


func _make_battle_sample_run_id() -> String:
	var now := OS.get_datetime()
	return (
		"%04d%02d%02d-%02d%02d%02d-%s"
		% [
			now.year,
			now.month,
			now.day,
			now.hour,
			now.minute,
			now.second,
			OS.get_ticks_msec(),
		]
	)
