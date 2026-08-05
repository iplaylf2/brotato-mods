extends Reference

# Translates vanilla CollisionShape2D geometry into the circular support used by
# observation contracts. Callers choose a collision-centered support or an
# owner-centered enclosure; both include the complete world transform.


func adapt_owner_centered_radius(owner: Node2D, path: String) -> float:
	var collision: Node = owner.get_node(path)
	assert(collision is CollisionShape2D)
	assert(collision.shape != null)
	return (
		collision.global_position.distance_to(owner.global_position)
		+ adapt_collision_centered_radius(collision)
	)


func adapt_collision_centered_radius(collision: CollisionShape2D) -> float:
	assert(collision.shape != null)
	if collision.shape is CircleShape2D:
		var circle_radius: float = (
			collision.shape.radius
			* max(abs(collision.global_scale.x), abs(collision.global_scale.y))
		)
		assert(not is_nan(circle_radius) and not is_inf(circle_radius))
		return circle_radius
	assert(collision.shape is RectangleShape2D)
	var extents: Vector2 = collision.shape.extents
	var shape_rect := Rect2(-extents, extents * 2.0)
	var corners := [
		shape_rect.position,
		shape_rect.position + Vector2(shape_rect.size.x, 0.0),
		shape_rect.end,
		shape_rect.position + Vector2(0.0, shape_rect.size.y),
	]
	var result := 0.0
	for corner in corners:
		var transformed_corner: Vector2 = collision.global_transform.basis_xform(corner)
		result = max(result, transformed_corner.length())
	assert(not is_nan(result) and not is_inf(result))
	return result
