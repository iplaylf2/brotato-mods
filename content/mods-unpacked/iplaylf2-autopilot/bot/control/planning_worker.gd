extends Reference

# Owns the Godot 3 on-demand worker lifecycle and the synchronized transfer of
# planning requests and pure-value results. The mutable planner graph is created,
# configured, executed, and released on this thread; callers retain scheduling
# and result application.

const MovementPlanner := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_planner.gd"
)

var _thread: Thread
var _mutex: Mutex = Mutex.new()
var _semaphore: Semaphore = Semaphore.new()
var _pending_requests := []
var _completed_results := []
var _results_ready := false
var _in_flight := false
var _stop_requested := false
var _player_count := 0
var _planners := []


func start(player_count: int) -> bool:
	if _thread != null:
		return true
	_stop_requested = false
	_player_count = player_count
	_thread = Thread.new()
	if _thread.start(self, "_run") == OK:
		return true
	_thread = null
	return false


func submit(requests: Array) -> bool:
	_mutex.lock()
	var accepted := _thread != null and not _stop_requested and not _in_flight
	if accepted:
		_pending_requests = requests
		_results_ready = false
		_in_flight = true
	_mutex.unlock()
	if accepted:
		_semaphore.post()
	return accepted


func is_busy() -> bool:
	_mutex.lock()
	var busy := _in_flight
	_mutex.unlock()
	return busy


func poll() -> Dictionary:
	_mutex.lock()
	if not _results_ready:
		_mutex.unlock()
		return {"ready": false, "results": []}
	var results: Array = _completed_results
	_completed_results = []
	_results_ready = false
	_in_flight = false
	_mutex.unlock()
	return {"ready": true, "results": results}


func shutdown() -> void:
	if _thread == null:
		return
	_mutex.lock()
	_stop_requested = true
	_pending_requests.clear()
	_mutex.unlock()
	_semaphore.post()
	# A Godot 3 Thread is joined exactly once, after its persistent worker loop
	# accepts the exit request. The joined instance is never restarted.
	_thread.wait_to_finish()
	_thread = null
	_in_flight = false
	_results_ready = false
	_completed_results.clear()


func _run(_unused) -> void:
	_planners.resize(_player_count)
	for player_index in _player_count:
		_planners[player_index] = MovementPlanner.new()
	while true:
		_semaphore.wait()
		_mutex.lock()
		var should_stop := _stop_requested
		var requests: Array = _pending_requests
		_pending_requests = []
		_mutex.unlock()
		if should_stop:
			_planners.clear()
			return
		var results := _compute(requests)
		_mutex.lock()
		_completed_results = results
		_results_ready = true
		_mutex.unlock()


func _compute(requests: Array) -> Array:
	var results := []
	for request in requests:
		var player_index: int = request.player_index
		var planner: Reference = _planners[player_index]
		planner.set_frame_budget_context(request.frame_budget_context)
		results.push_back(
			{
				"player_index": player_index,
				"observation": request.observation,
				"plan":
				planner.plan(
					request.observation, request.active_movement, request.request_created_usec
				),
			}
		)
	return results
