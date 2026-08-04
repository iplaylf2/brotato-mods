extends Reference

# Collects the physics-frame timing inputs used to budget synchronous movement
# planning. Godot owns the raw monitor; this object owns sampling, smoothing,
# and the context contract passed across the control -> planning boundary.

const PHYSICS_DURATION_ESTIMATE_TIME_CONSTANT_SECONDS := 0.5
var _baseline_physics_seconds_ema := 0.0
var _physics_duration_deviation_seconds_ema := 0.0
var _has_frame_time_sample := false
var _last_observed_idle_frame := -1
var _last_observed_physics_frame := -1
var _exclude_through_idle_frame := -1


func observe_physics_duration(delta_seconds: float) -> void:
	# Performance.TIME_PHYSICS_PROCESS is a rendered-frame monitor. During catch-up
	# Godot can run several physics callbacks while exposing the same value; sample
	# each completed rendered frame once rather than feeding duplicates to the EMA.
	var idle_frame := int(Engine.get_idle_frames())
	if idle_frame == _last_observed_idle_frame:
		return
	_last_observed_idle_frame = idle_frame
	var physics_frame := int(Engine.get_physics_frames())
	var completed_physics_ticks := 1
	if _last_observed_physics_frame >= 0:
		completed_physics_ticks = physics_frame - _last_observed_physics_frame
	_last_observed_physics_frame = physics_frame
	if completed_physics_ticks <= 0:
		return
	# A plan executed before the next rendered frame is part of that frame's
	# physics monitor. Excluding the corresponding monitor generation prevents the
	# planner from being learned as immutable base-game cost.
	if idle_frame <= _exclude_through_idle_frame:
		return
	# Godot reports the physics time accumulated by one rendered frame. A slow
	# rendered frame can contain several catch-up physics ticks, while the planning
	# deadline is a per-tick budget. Normalize both sides of that comparison to one
	# physics tick instead of treating catch-up work as one oversized base tick.
	var observed_seconds := (
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
		/ float(completed_physics_ticks)
	)
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
	_exclude_through_idle_frame = max(
		_exclude_through_idle_frame, int(Engine.get_idle_frames()) + 1
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
