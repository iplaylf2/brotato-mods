extends Reference

# Estimates the quantity represented by a visible vanilla material without reading its
# hidden runtime value. Vanilla enlarges pooled material by 0.05 per merged unit;
# bonus material starts at 1.25 scale with two units, so the lower envelope below
# remains valid for both visible mechanisms and after the size cap is reached.

const MERGED_UNIT_SCALE_INCREMENT := 0.05
const BONUS_MATERIAL_SCALE := 1.25
const BONUS_MATERIAL_MINIMUM_UNITS := 2.0
const SCALE_COMPARISON_EPSILON := 0.001


func estimate(material: Node2D) -> Dictionary:
	var rendered_scale: float = max(abs(material.scale.x), abs(material.scale.y))
	return {
		"minimum_units": _minimum_units_from_scale(rendered_scale),
		"evidence": "rendered_scale_lower_bound",
	}


func _minimum_units_from_scale(rendered_scale: float) -> float:
	if rendered_scale <= 1.0 + SCALE_COMPARISON_EPSILON:
		return 1.0
	if rendered_scale < BONUS_MATERIAL_SCALE - SCALE_COMPARISON_EPSILON:
		return (
			1.0
			+ floor((rendered_scale - 1.0 + SCALE_COMPARISON_EPSILON) / MERGED_UNIT_SCALE_INCREMENT)
		)
	return max(
		BONUS_MATERIAL_MINIMUM_UNITS,
		floor(
			(
				BONUS_MATERIAL_MINIMUM_UNITS
				+ (
					(rendered_scale - BONUS_MATERIAL_SCALE + SCALE_COMPARISON_EPSILON)
					/ MERGED_UNIT_SCALE_INCREMENT
				)
			)
		)
	)
