extends Reference

# Derives the enemy domain that can change a local action outcome. A track remains
# when its reachable set can threaten the player's reachable set, or, while
# visible, can enter an automatic weapon's target range. This is a spatial broad
# phase, not a search-fidelity policy.

const MovementGeometryModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/movement_geometry_model.gd"
)
const BattlefieldInfluenceModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/battlefield_influence_model.gd"
)
const EnemyReachEnvelopeModel := preload(
	"res://mods-unpacked/iplaylf2-autopilot/bot/planning/motion/enemy_reach_envelope_model.gd"
)

var _movement_geometry: Reference = MovementGeometryModel.new()
var _enemy_reach_envelope_model: Reference = EnemyReachEnvelopeModel.new()


func project(observation: Dictionary, forecast_seconds: float) -> Dictionary:
	var projected := observation.duplicate(false)
	var relevant_tracks := []
	var excluded_track_count := 0
	var geometry: Dictionary = _movement_geometry.derive(observation)
	var player_reach: float = (
		geometry.command_speed * max(0.0, forecast_seconds)
		+ observation.player_state.movement.knockback_velocity.length() * max(0.0, forecast_seconds)
	)
	var maximum_weapon_targeting_range := _maximum_weapon_targeting_range(
		observation.player_state.weapons
	)
	for track in observation.enemy_tracks:
		if _can_interact_with_local_forecast(
			track, forecast_seconds, player_reach, maximum_weapon_targeting_range, geometry
		):
			relevant_tracks.push_back(track)
		else:
			excluded_track_count += 1
	projected.enemy_tracks = relevant_tracks
	return {
		"observation": projected,
		"input_enemy_track_count": observation.enemy_tracks.size(),
		"relevant_enemy_track_count": relevant_tracks.size(),
		"excluded_enemy_track_count": excluded_track_count,
	}


func _can_interact_with_local_forecast(
	track: Dictionary,
	forecast_seconds: float,
	player_reach: float,
	maximum_weapon_targeting_range: float,
	geometry: Dictionary
) -> bool:
	if _can_threaten_player(track, forecast_seconds, player_reach, geometry):
		return true
	if not track.visible or maximum_weapon_targeting_range <= 0.0:
		return false
	var weapon_support_radius: float = (
		player_reach
		+ _enemy_reach_envelope_model.maximum_displacement(track, forecast_seconds)
		+ track.uncertainty_radius
		+ maximum_weapon_targeting_range
	)
	return track.relative_position.length() <= weapon_support_radius


func _can_threaten_player(
	track: Dictionary, forecast_seconds: float, player_reach: float, geometry: Dictionary
) -> bool:
	var profile: Dictionary = track.behavior_profile
	var charge_attack: Dictionary = profile.get("charge_attack", {})
	var influence_radius: float = geometry.enemy_pressure_distance
	var projectile_attack: Dictionary = profile.get("projectile_attack", {})
	if projectile_attack.get("creates_projectile_pressure", false):
		influence_radius = max(
			influence_radius,
			projectile_attack.get(
				"maximum_range", BattlefieldInfluenceModel.RANGED_SOURCE_PRESSURE_DISTANCE
			)
		)
	if charge_attack.get("active", false):
		influence_radius = max(
			influence_radius,
			min(
				charge_attack.get("maximum_range", 0.0),
				charge_attack.get("maximum_travel_distance", 0.0)
			)
		)
	var threat_support_radius: float = (
		_enemy_reach_envelope_model.contact_support_radius(
			track, forecast_seconds, player_reach, geometry.player_radius
		)
		+ influence_radius
	)
	return track.relative_position.length() <= threat_support_radius


func _maximum_weapon_targeting_range(weapons: Array) -> float:
	var result := 0.0
	for weapon in weapons:
		result = max(result, weapon.attack_model.delivery.maximum_targeting_distance)
	return result
