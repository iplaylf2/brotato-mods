extends SceneTree

# Exercises the persistent Godot 3 worker through its initial and subsequent
# on-demand planning cycles. The planner is this script's pure plan() method;
# no scene API is used by the worker.

const CYCLE_TIMEOUT_USEC := 2000000
var _worker: Reference


func _init() -> void:
	var archive_path := _get_archive_path()
	if archive_path.empty() or not ProjectSettings.load_resource_pack(archive_path, false):
		printerr("Could not mount the planning-worker contract archive: %s" % archive_path)
		quit(1)
		return
	var worker_script: Script = load(
		"res://mods-unpacked/iplaylf2-autopilot/bot/control/planning_worker.gd"
	)
	_worker = worker_script.new()
	if not _worker.start():
		_fail("worker must start")
		return
	for cycle in 2:
		if not _worker.submit(
			[
				{
					"player_index": cycle,
					"observation": {"cycle": cycle},
					"planner": self,
				}
			]
		):
			_fail("worker must accept cycle %s" % cycle)
			return
		var deadline := OS.get_ticks_usec() + CYCLE_TIMEOUT_USEC
		while true:
			var completion: Dictionary = _worker.poll()
			if completion.ready:
				if completion.results.size() != 1:
					_fail("worker must return one result for cycle %s" % cycle)
					return
				var result: Dictionary = completion.results[0]
				if result.player_index != cycle or result.plan.cycle != cycle:
					_fail("worker returned the wrong result for cycle %s" % cycle)
					return
				break
			if OS.get_ticks_usec() >= deadline:
				_fail("worker timed out on cycle %s" % cycle)
				return
			OS.delay_usec(100)
	_worker.shutdown()
	quit(0)


func plan(observation: Dictionary) -> Dictionary:
	return {"cycle": observation.cycle}


func _fail(message: String) -> void:
	printerr("Autopilot planning-worker contract failed: %s" % message)
	if _worker != null:
		_worker.shutdown()
	quit(1)


func _get_archive_path() -> String:
	for argument in OS.get_cmdline_args():
		if argument.ends_with(".zip"):
			return argument
	return ""
