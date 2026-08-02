extends Reference

# Collects the physics-frame timing inputs used to budget synchronous movement
# planning. Godot owns the raw monitor; this object owns sampling, smoothing,
# and the context contract passed across the control -> planning boundary.

const PHYSICS_DURATION_ESTIMATE_TIME_CONSTANT_SECONDS := 0.5

var _baseline_physics_seconds_ema := 0.0
var _physics_duration_deviation_seconds_ema := 0.0
var _has_frame_time_sample := false


func observe_physics_duration(delta_seconds: float, previous_frame_included_planning: bool) -> void:
	# Performance monitors may update with a short delay. Excluding the sample
	# immediately after planning reduces the chance that the usual planning spike
	# enters the baseline estimate.
	if previous_frame_included_planning:
		return
	var observed_seconds := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	if observed_seconds <= 0.0:
		return
	if not _has_frame_time_sample:
		_baseline_physics_seconds_ema = observed_seconds
		_has_frame_time_sample = true
		return
	var sample_weight := (
		1.0
		- exp(-max(0.0, delta_seconds) / PHYSICS_DURATION_ESTIMATE_TIME_CONSTANT_SECONDS)
	)
	var absolute_deviation := abs(observed_seconds - _baseline_physics_seconds_ema)
	_baseline_physics_seconds_ema = lerp(
		_baseline_physics_seconds_ema, observed_seconds, sample_weight
	)
	_physics_duration_deviation_seconds_ema = lerp(
		_physics_duration_deviation_seconds_ema, absolute_deviation, sample_weight
	)


func build_context(scheduled_planner_count: int) -> Dictionary:
	var physics_fps := max(1.0, float(Engine.iterations_per_second))
	return {
		"physics_frame_capacity_usec": 1000000.0 / physics_fps,
		"baseline_physics_duration_usec_ema": _baseline_physics_seconds_ema * 1000000.0,
		"physics_duration_deviation_usec_ema": _physics_duration_deviation_seconds_ema * 1000000.0,
		"scheduled_planner_count": max(1, scheduled_planner_count),
		"has_frame_time_sample": _has_frame_time_sample,
	}
