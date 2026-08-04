extends Reference

# Owns the Godot 3 on-demand worker lifecycle and the synchronized transfer of
# planning requests and pure-value results. Callers retain scheduling and result
# application; planners retain all decision semantics.

var _thread: Thread
var _mutex: Mutex = Mutex.new()
var _semaphore: Semaphore = Semaphore.new()
var _pending_requests := []
var _completed_results := []
var _results_ready := false
var _in_flight := false
var _stop_requested := false


func start() -> bool:
	if _thread != null:
		return true
	_stop_requested = false
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
	while true:
		_semaphore.wait()
		_mutex.lock()
		var should_stop := _stop_requested
		var requests: Array = _pending_requests
		_pending_requests = []
		_mutex.unlock()
		if should_stop:
			return
		var results := _compute(requests)
		_mutex.lock()
		_completed_results = results
		_results_ready = true
		_mutex.unlock()


func _compute(requests: Array) -> Array:
	var results := []
	for request in requests:
		results.push_back(
			{
				"player_index": request.player_index,
				"observation": request.observation,
				"plan": request.planner.plan(request.observation),
			}
		)
	return results
