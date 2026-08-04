extends Reference

# Collects the physics-frame timing inputs used to budget background movement
# planning. Godot owns the raw monitor; this object owns sampling, smoothing,
# and the context contract passed across the control -> planning boundary.

const PHYSICS_PEAK_ESTIMATE_TIME_CONSTANT_SECONDS := 0.5
var _physics_process_peak_seconds_ema := 0.0
var _has_frame_time_sample := false
var _last_observed_idle_frame := -1


func observe_physics_duration(delta_seconds: float) -> void:
	# Godot 3 publishes the maximum physics-callback duration from its recent
	# reporting window. Several catch-up callbacks can observe the same published
	# value in one idle frame, so advance the held-value EMA at most once here.
	var idle_frame := int(Engine.get_idle_frames())
	if idle_frame == _last_observed_idle_frame:
		return
	_last_observed_idle_frame = idle_frame
	var observed_seconds := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	if observed_seconds <= 0.0:
		return
	if not _has_frame_time_sample:
		_physics_process_peak_seconds_ema = observed_seconds
		_has_frame_time_sample = true
		return
	var sample_weight := (
		1.0
		- exp(-max(0.0, delta_seconds) / PHYSICS_PEAK_ESTIMATE_TIME_CONSTANT_SECONDS)
	)
	_physics_process_peak_seconds_ema = lerp(
		_physics_process_peak_seconds_ema, observed_seconds, sample_weight
	)


func build_context(scheduled_planner_count: int, planning_window_seconds: float) -> Dictionary:
	var physics_fps := max(1.0, float(Engine.iterations_per_second))
	var planning_window_physics_frames := max(
		1, int(round(max(0.0, planning_window_seconds) * physics_fps))
	)
	return {
		"physics_frame_capacity_usec": 1000000.0 / physics_fps,
		"physics_process_peak_usec_ema": _physics_process_peak_seconds_ema * 1000000.0,
		"planning_window_usec": max(0.0, planning_window_seconds) * 1000000.0,
		"planning_window_physics_frames": planning_window_physics_frames,
		"scheduled_planner_count": max(1, scheduled_planner_count),
		"has_frame_time_sample": _has_frame_time_sample,
	}
