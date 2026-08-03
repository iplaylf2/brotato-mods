extends Reference

# Collects the physics-frame timing inputs used to budget synchronous movement
# planning. Godot owns the raw monitor; this object owns sampling, smoothing,
# and the context contract passed across the control -> planning boundary.

const PHYSICS_DURATION_ESTIMATE_TIME_CONSTANT_SECONDS := 0.5
const POST_PLANNING_EXCLUDED_SAMPLES := 3

var _baseline_physics_seconds_ema := 0.0
var _physics_duration_deviation_seconds_ema := 0.0
var _has_frame_time_sample := false
var _excluded_samples_remaining := 0


func observe_physics_duration(delta_seconds: float) -> void:
	# Godot's performance monitor is updated after physics work and can expose a
	# planning spike for more than one subsequent callback. Keep that delayed work
	# out of the baseline instead of teaching the budget that a missed frame is
	# ordinary game cost.
	if _excluded_samples_remaining > 0:
		_excluded_samples_remaining -= 1
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


func mark_planning_completed() -> void:
	_excluded_samples_remaining = POST_PLANNING_EXCLUDED_SAMPLES


func build_context(scheduled_planner_count: int) -> Dictionary:
	var physics_fps := max(1.0, float(Engine.iterations_per_second))
	return {
		"physics_frame_capacity_usec": 1000000.0 / physics_fps,
		"baseline_physics_duration_usec_ema": _baseline_physics_seconds_ema * 1000000.0,
		"physics_duration_deviation_usec_ema": _physics_duration_deviation_seconds_ema * 1000000.0,
		"scheduled_planner_count": max(1, scheduled_planner_count),
		"has_frame_time_sample": _has_frame_time_sample,
	}
