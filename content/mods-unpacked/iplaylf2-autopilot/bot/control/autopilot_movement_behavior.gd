extends MovementBehavior

# The only control boundary: a movement vector consumed by Unit.get_movement().
# Keep weapon, aim, attack, target, cooldown, damage, and other combat-state
# mutation out of this adapter and the rest of the control layer.

var _movement := Vector2.ZERO


func set_movement(value: Vector2) -> void:
	_movement = value.clamped(1.0)


func get_movement() -> Vector2:
	return _movement


func get_target_position():
	return null
