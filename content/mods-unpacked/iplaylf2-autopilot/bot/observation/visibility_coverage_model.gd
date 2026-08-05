extends Reference

# Converts the ordinary-wave camera rectangle into conservative negative
# visibility evidence. Fog lights are not rectangular, so their coverage stays
# unknown until the observation boundary can expose their actual sensor domain.


func covers_reachable_circle(
	relative_position: Vector2,
	visual_radius: float,
	reachable_radius: float,
	visibility: Dictionary
) -> bool:
	if visibility.get("fog_active", false):
		return false
	var viewport_size: Vector2 = visibility.get("viewport_size", Vector2.ZERO)
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return false
	var viewport_offset: Vector2 = visibility.get(
		"viewport_offset_from_player", -viewport_size * 0.5
	)
	# VisibleWorldObserver accepts an entity whose center lies in the camera
	# rectangle expanded by its visual radius. Confirm absence only when every
	# center the entity could have reached remains inside that same domain.
	var visible_center_domain := Rect2(viewport_offset, viewport_size).grow(max(0.0, visual_radius))
	var reach: float = max(0.0, reachable_radius)
	if 2.0 * reach > min(visible_center_domain.size.x, visible_center_domain.size.y):
		return false
	return visible_center_domain.grow(-reach).has_point(relative_position)
