extends Reference

# Writes admitted battle samples as newline-delimited JSON. The recorder owns
# sampling policy and segment lifecycle.

const MOD_ID := "iplaylf2-autopilot"
const SAMPLE_DIRECTORY := "user://logs/mods/iplaylf2-autopilot"
const FLUSH_EVERY_SAMPLES := 16

var _file: File = null
var _writer_thread: Thread = null
var _writer_mutex: Mutex = Mutex.new()
var _writer_semaphore: Semaphore = Semaphore.new()
var _pending_writes := []
var _writer_stop_requested := false
var _battle_run_id := ""
var _segment_id := ""
var _run_directory := ""
var _wave_number := 0
var _control_source := ""
var _player_count := 0
var _samples_since_flush := 0
var _active := false
var _accepting_records := false
var _current_path := ""
var _wave_context_written := false
var _player_context_written := []


func start(
	player_count: int,
	battle_run_id: String,
	wave_number: int,
	control_source: String,
	sampling_policy: Dictionary
) -> void:
	_player_count = player_count
	_player_context_written.resize(player_count)
	for player_index in player_count:
		_player_context_written[player_index] = false
	_battle_run_id = battle_run_id
	_segment_id = _make_segment_id()
	_wave_number = wave_number
	_control_source = control_source
	_run_directory = "%s/%s" % [SAMPLE_DIRECTORY, _battle_run_id]
	var directory := Directory.new()
	var directory_error := directory.make_dir_recursive(_run_directory)
	if directory_error != OK and not directory.dir_exists(_run_directory):
		ModLoaderLog.error(
			(
				"Could not create the battle sample directory %s (error %s)."
				% [_run_directory, directory_error]
			),
			MOD_ID
		)
		return
	if not _open_file(sampling_policy):
		return
	_writer_thread = Thread.new()
	if _writer_thread.start(self, "_run_writer") != OK:
		_file.close()
		_file = null
		_writer_thread = null
		ModLoaderLog.error("Could not start the battle sample writer.", MOD_ID)
		return
	_writer_mutex.lock()
	_accepting_records = true
	_writer_mutex.unlock()
	_active = true
	ModLoaderLog.info(
		(
			"Writing battle samples to %s (%s)."
			% [_current_path, ProjectSettings.globalize_path(_current_path)]
		),
		MOD_ID
	)


func record_bot_sample(
	player_index: int,
	decision_index: int,
	sample_index: int,
	observation: Dictionary,
	plan: Dictionary,
	previous_movement: Vector2
) -> void:
	if not _is_accepting_records():
		return
	_enqueue_record(
		{
			"record_type": "decision_sample",
			"player_index": player_index,
			"decision_index": decision_index,
			"sample_index": sample_index,
			"physics_frame": observation.get("physics_frame"),
			"previous_movement": previous_movement,
			# Planning observations and plans are detached value graphs. Defer their
			# compaction with JSON conversion so the physics callback only enqueues.
			"observation": observation,
			"decision": plan,
		}
	)
	_samples_since_flush += 1
	if _samples_since_flush >= FLUSH_EVERY_SAMPLES:
		_samples_since_flush = 0
		_enqueue_flush()


func record_human_sample(player_index: int, sample_index: int, observation: Dictionary) -> void:
	if not _is_accepting_records():
		return
	var movement: Vector2 = observation.get("player_state", {}).get("movement", {}).get(
		"input_vector", Vector2.ZERO
	)
	_enqueue_record(
		{
			"record_type": "action_sample",
			"player_index": player_index,
			"sample_index": sample_index,
			"physics_frame": observation.get("physics_frame"),
			"action": {"movement": movement},
			"observation": observation,
		}
	)
	_samples_since_flush += 1
	if _samples_since_flush >= FLUSH_EVERY_SAMPLES:
		_samples_since_flush = 0
		_enqueue_flush()


func close(decision_counts: Array, sample_counts: Array, final_player_states: Array) -> void:
	if not _active:
		return
	if _is_accepting_records():
		_enqueue_record(
			{
				"record_type": "segment_end",
				"decision_counts": decision_counts,
				"sample_counts": sample_counts,
				"final_player_states": final_player_states,
			}
		)
	_writer_mutex.lock()
	_accepting_records = false
	_writer_stop_requested = true
	_writer_mutex.unlock()
	_writer_semaphore.post()
	_writer_thread.wait_to_finish()
	_writer_thread = null
	_pending_writes.clear()
	_active = false


func get_current_path() -> String:
	return _current_path


func _open_file(sampling_policy: Dictionary) -> bool:
	_current_path = (
		"%s/wave-%03d-%s-%s.jsonl"
		% [_run_directory, _wave_number, _control_source, _segment_id]
	)
	var path := _current_path
	_file = File.new()
	var open_error := _file.open(path, File.WRITE)
	if open_error != OK:
		ModLoaderLog.error(
			"Could not open the battle sample file %s (error %s)." % [path, open_error], MOD_ID
		)
		_file = null
		return false
	if not _write_record_now(
		{
			"record_type": "segment_start",
			"run_id": _battle_run_id,
			"segment_id": _segment_id,
			"wave_number": _wave_number,
			"control_source": _control_source,
			"target_game_version": "1.1.15.4",
			"player_count": _player_count,
			"sampling_policy": sampling_policy,
		}
	):
		_file.close()
		_file = null
		return false
	_wave_context_written = false
	if _flush_now():
		return true
	_file.close()
	_file = null
	return false


func _is_accepting_records() -> bool:
	_writer_mutex.lock()
	var accepting := _accepting_records
	_writer_mutex.unlock()
	return accepting


func _enqueue_record(record: Dictionary) -> void:
	_writer_mutex.lock()
	_pending_writes.push_back(record)
	_writer_mutex.unlock()
	_writer_semaphore.post()


func _enqueue_flush() -> void:
	_writer_mutex.lock()
	_pending_writes.push_back(null)
	_writer_mutex.unlock()
	_writer_semaphore.post()


func _run_writer(_unused) -> void:
	while true:
		_writer_semaphore.wait()
		_writer_mutex.lock()
		var writes: Array = _pending_writes
		_pending_writes = []
		var should_stop := _writer_stop_requested
		_writer_mutex.unlock()
		for record in writes:
			if record == null:
				if not _flush_now():
					_stop_accepting_after_writer_failure()
					return
				continue
			if not _write_record_now(record):
				_stop_accepting_after_writer_failure()
				return
		if should_stop:
			_flush_now()
			_file.close()
			_file = null
			return


func _stop_accepting_after_writer_failure() -> void:
	_writer_mutex.lock()
	_accepting_records = false
	_writer_mutex.unlock()
	_file.close()
	_file = null


func _write_record_now(record: Dictionary) -> bool:
	var persisted_record := record
	if record.get("record_type", "") in ["decision_sample", "action_sample"]:
		if not _wave_context_written:
			if not _write_wave_context_now(record.observation):
				return false
			_wave_context_written = true
		var player_index: int = record.player_index
		if not _player_context_written[player_index]:
			if not _write_player_context_now(player_index, record.observation):
				return false
			_player_context_written[player_index] = true
		persisted_record = record.duplicate(false)
		persisted_record.observation = _compact_observation(record.observation)
	return _store_record_now(persisted_record)


func _write_wave_context_now(observation: Dictionary) -> bool:
	var wave_state: Dictionary = observation.get("wave_state", {}).duplicate(false)
	wave_state.erase("seconds_remaining")
	return _store_record_now({"record_type": "wave_context", "wave_state": wave_state})


func _write_player_context_now(player_index: int, observation: Dictionary) -> bool:
	var player_state: Dictionary = observation.get("player_state", {})
	return _store_record_now(
		{
			"record_type": "player_context",
			"player_index": player_index,
			"character_id": observation.get("sampling_context", {}).get("character_id", ""),
			"stat_opportunity_profiles": player_state.get("stat_opportunity_profiles", {}),
		}
	)


func _store_record_now(record: Dictionary) -> bool:
	_file.store_line(JSON.print(_to_json_value(record)))
	var write_error := _file.get_error()
	if write_error != OK:
		ModLoaderLog.error("Could not write battle samples (error %s)." % write_error, MOD_ID)
		return false
	return true


func _flush_now() -> bool:
	_file.flush()
	var flush_error := _file.get_error()
	if flush_error != OK:
		ModLoaderLog.error("Could not flush battle samples (error %s)." % flush_error, MOD_ID)
		return false
	return true


func _compact_observation(observation: Dictionary) -> Dictionary:
	var result: Dictionary = observation.duplicate(false)
	result.erase("sampling_context")
	var wave_state: Dictionary = result.get("wave_state", {}).duplicate(false)
	for fixed_field in ["number", "final_number", "endless", "is_horde", "duration_seconds"]:
		wave_state.erase(fixed_field)
	result.wave_state = wave_state
	var player_state: Dictionary = result.get("player_state", {}).duplicate(false)
	player_state.erase("stat_opportunity_profiles")
	result.player_state = player_state
	# behavior_profile is the planner contract. The evidence and stable profile
	# nested under last_measurement duplicate that same compiled mechanic for every
	# tracked enemy, so persisting both would inflate sample size and writer work.
	var tracks := []
	for observed_track in result.get("enemy_tracks", []):
		var track: Dictionary = observed_track.duplicate(false)
		track.erase("behavior_evidence")
		track.behavior_profile = _compact_behavior_profile(track.get("behavior_profile", {}))
		var measurement: Dictionary = track.get("last_measurement", {}).duplicate(false)
		measurement.erase("stable_mechanic_profile")
		measurement.erase("next_volley_window")
		track.last_measurement = measurement
		tracks.push_back(track)
	result.enemy_tracks = tracks
	return result


func _compact_behavior_profile(profile: Dictionary) -> Dictionary:
	# Most stable attack configuration repeats across samples. Keep the current
	# timing window and the causal fields needed to explain path risk; omit
	# unrelated attack configuration and rule evidence from persisted samples.
	var projectile_attack: Dictionary = profile.get("projectile_attack", {})
	var charge_attack: Dictionary = profile.get("charge_attack", {})
	var target_response: Dictionary = profile.get("target_position_response", {})
	return {
		"durability": profile.get("durability", {}),
		"contact_damage": profile.get("contact_damage", 0.0),
		"contact_radius": profile.get("contact_radius", 0.0),
		"death_rewards": profile.get("death_rewards", {}),
		"projectile_attack":
		{
			"kind": projectile_attack.get("kind", "unconfirmed"),
			"confidence": projectile_attack.get("confidence", 0.0),
			"creates_projectile_pressure":
			projectile_attack.get("creates_projectile_pressure", false),
			"pressure_intensity": projectile_attack.get("pressure_intensity", 0.0),
			"minimum_range": projectile_attack.get("minimum_range", 0.0),
			"maximum_range": projectile_attack.get("maximum_range", 0.0),
			"maximum_projectile_speed": projectile_attack.get("maximum_projectile_speed", 0.0),
			"delivery_modes": projectile_attack.get("delivery_modes", []).duplicate(),
			"launch_randomness": projectile_attack.get("launch_randomness", {}).duplicate(false),
		},
		"next_volley_window": profile.get("next_volley_window", {}).duplicate(false),
		"charge_attack":
		{
			"active": charge_attack.get("active", false),
			"confidence": charge_attack.get("confidence", 0.0),
		},
		"target_position_response":
		{
			"responds_to_target_position":
			target_response.get("responds_to_target_position", false),
			"preferred_distance": target_response.get("preferred_distance", 0.0),
			"moves_away_inside_preferred_distance":
			target_response.get("moves_away_inside_preferred_distance", false),
			"movement_speed": target_response.get("movement_speed", 0.0),
			"confidence": target_response.get("confidence", 0.0),
		},
		"battlefield_effects": profile.get("battlefield_effects", {}),
		"removal_effects": profile.get("removal_effects", {}),
	}


func _to_json_value(value):
	match typeof(value):
		TYPE_DICTIONARY:
			var dictionary := {}
			for key in value:
				dictionary[str(key)] = _to_json_value(value[key])
			return dictionary
		TYPE_ARRAY:
			var array := []
			for entry in value:
				array.push_back(_to_json_value(entry))
			return array
		TYPE_VECTOR2:
			return {"x": value.x, "y": value.y}
		TYPE_REAL:
			if is_nan(value):
				return "NaN"
			if is_inf(value):
				return "-Infinity" if value < 0.0 else "Infinity"
			return value
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return value
		_:
			return str(value)


func _make_segment_id() -> String:
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
