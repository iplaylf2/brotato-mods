extends Reference

# Persists calibration-oriented decision samples as newline-delimited JSON. Sampling
# owns storage policy only; planning remains the source of model inputs and
# diagnostics. Files rotate before a long run can create one unbounded artifact.

const MOD_ID := "iplaylf2-autopilot"
const SAMPLE_DIRECTORY := "user://logs/mods/iplaylf2-autopilot"
const SAMPLE_INTERVAL_SECONDS := 1.0
const MAX_FILE_BYTES := 32 * 1024 * 1024
const FLUSH_EVERY_SAMPLES := 16

var _file: File = null
var _writer_thread: Thread = null
var _writer_mutex: Mutex = Mutex.new()
var _writer_semaphore: Semaphore = Semaphore.new()
var _pending_writes := []
var _writer_stop_requested := false
var _session_id := ""
var _part_index := 0
var _player_count := 0
var _decision_counts := []
var _sample_counts := []
var _decisions_until_sample := []
var _samples_since_flush := 0
var _sample_every_decisions := 1
var _active := false
var _accepting_records := false
var _current_path := ""
var _control_interval_seconds := 0.0


func start(player_count: int, control_interval_seconds: float) -> void:
	_player_count = player_count
	_control_interval_seconds = control_interval_seconds
	_sample_every_decisions = max(
		1, int(round(SAMPLE_INTERVAL_SECONDS / max(0.001, control_interval_seconds)))
	)
	_decision_counts.resize(player_count)
	_sample_counts.resize(player_count)
	_decisions_until_sample.resize(player_count)
	for player_index in player_count:
		_decision_counts[player_index] = 0
		_sample_counts[player_index] = 0
		_decisions_until_sample[player_index] = 0

	_session_id = _make_session_id()
	var directory := Directory.new()
	var directory_error := directory.make_dir_recursive(SAMPLE_DIRECTORY)
	if directory_error != OK and not directory.dir_exists(SAMPLE_DIRECTORY):
		ModLoaderLog.error(
			(
				"Could not create the decision sample directory %s (error %s)."
				% [SAMPLE_DIRECTORY, directory_error]
			),
			MOD_ID
		)
		return
	if not _open_part(control_interval_seconds, false):
		return
	_writer_stop_requested = false
	_pending_writes.clear()
	_writer_thread = Thread.new()
	if _writer_thread.start(self, "_run_writer") != OK:
		_file.close()
		_file = null
		_writer_thread = null
		ModLoaderLog.error("Could not start the decision telemetry writer.", MOD_ID)
		return
	_writer_mutex.lock()
	_accepting_records = true
	_writer_mutex.unlock()
	_active = true
	if _active:
		ModLoaderLog.info(
			(
				"Writing decision samples to %s (%s)."
				% [_current_path, ProjectSettings.globalize_path(_current_path)]
			),
			MOD_ID
		)


func record_decision(
	player_index: int, observation: Dictionary, plan: Dictionary, previous_movement: Vector2
) -> void:
	if not _is_accepting_records() or player_index < 0 or player_index >= _player_count:
		return
	_decision_counts[player_index] += 1
	var should_sample: bool = _decisions_until_sample[player_index] <= 0
	if plan.get("status", "") != "ready":
		should_sample = true
	if not should_sample:
		_decisions_until_sample[player_index] -= 1
		return

	_decisions_until_sample[player_index] = _sample_every_decisions - 1
	_sample_counts[player_index] += 1
	_enqueue_record(
		{
			"record_type": "decision_sample",
			"session_id": _session_id,
			"player_index": player_index,
			"decision_index": _decision_counts[player_index],
			"sample_index": _sample_counts[player_index],
			"physics_frame": observation.get("physics_frame"),
			"previous_movement": previous_movement,
			# Planning observations and plans are detached value graphs. Defer their
			# compaction with JSON conversion so the physics callback only enqueues.
			"observation": observation,
			"decision": plan,
		}
	)
	_samples_since_flush += 1
	var flush_after_write := false
	# Flush each player's first recorded plan so an abnormal exit cannot leave an
	# otherwise completed first decision buffered behind the regular batch policy.
	if _sample_counts[player_index] == 1 or _samples_since_flush >= FLUSH_EVERY_SAMPLES:
		flush_after_write = true
		_samples_since_flush = 0
	if flush_after_write:
		_enqueue_flush()


func close(final_player_states := []) -> void:
	if not _active:
		return
	if _is_accepting_records():
		_enqueue_record(
			{
				"record_type": "session_end",
				"session_id": _session_id,
				"decision_counts": _decision_counts,
				"sample_counts": _sample_counts,
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
	_writer_mutex.lock()
	var path := _current_path
	_writer_mutex.unlock()
	return path


func _rotate(control_interval_seconds: float) -> bool:
	if not _write_record_now(
		{
			"record_type": "part_end",
			"session_id": _session_id,
			"part_index": _part_index,
		}
	):
		_file.close()
		_file = null
		return false
	if not _flush_now():
		_file.close()
		_file = null
		return false
	_file.close()
	_file = null
	_part_index += 1
	return _open_part(control_interval_seconds, true)


func _open_part(control_interval_seconds: float, continued: bool) -> bool:
	_writer_mutex.lock()
	_current_path = "%s/%s-part-%03d.jsonl" % [SAMPLE_DIRECTORY, _session_id, _part_index]
	var path := _current_path
	_writer_mutex.unlock()
	_file = File.new()
	var open_error := _file.open(path, File.WRITE)
	if open_error != OK:
		ModLoaderLog.error(
			"Could not open the decision sample file %s (error %s)." % [path, open_error], MOD_ID
		)
		_file = null
		return false
	if not _write_record_now(
		{
			"record_type": "session_start",
			"session_id": _session_id,
			"part_index": _part_index,
			"continued": continued,
			"target_game_version": "1.1.15.4",
			"player_count": _player_count,
			"sampling":
			{
				"interval_seconds": SAMPLE_INTERVAL_SECONDS,
				"control_interval_seconds": control_interval_seconds,
				"every_decisions": _sample_every_decisions,
				"maximum_part_bytes": MAX_FILE_BYTES,
			},
		}
	):
		_file.close()
		_file = null
		return false
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
			if _file.get_position() >= MAX_FILE_BYTES:
				if not _rotate(_control_interval_seconds):
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
	if _file != null:
		_file.close()
		_file = null


func _write_record_now(record: Dictionary) -> bool:
	var persisted_record := record
	if record.get("record_type", "") == "decision_sample":
		persisted_record = record.duplicate(false)
		persisted_record.observation = _compact_observation(record.observation)
		persisted_record.decision = _compact_plan(record.decision)
	_file.store_line(JSON.print(_to_json_value(persisted_record)))
	var write_error := _file.get_error()
	if write_error != OK:
		ModLoaderLog.error("Could not write decision telemetry (error %s)." % write_error, MOD_ID)
		return false
	return true


func _flush_now() -> bool:
	_file.flush()
	var flush_error := _file.get_error()
	if flush_error != OK:
		ModLoaderLog.error("Could not flush decision telemetry (error %s)." % flush_error, MOD_ID)
		return false
	return true


func _compact_observation(observation: Dictionary) -> Dictionary:
	var result: Dictionary = observation.duplicate(false)
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


func _compact_plan(plan: Dictionary) -> Dictionary:
	# JSON conversion constructs the detached persisted graph. A second deep copy
	# would only duplicate immutable planning state in the writer queue.
	return plan.duplicate(false)


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


func _make_session_id() -> String:
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
