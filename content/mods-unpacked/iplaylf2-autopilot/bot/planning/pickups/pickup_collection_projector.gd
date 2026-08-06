extends Reference

# Projects the observation memory and a candidate player path into weighted
# pickup collection events. Remembered entities are the planning source of truth:
# they contain visible pickups too, while preserving legal off-screen knowledge
# and the observation layer's existence evidence. Solo consumable records remain
# certain until collection is proved; multiplayer teammate uncertainty may give
# an event a fractional weight.

const PickupCollectionGeometryModel := preload("pickup_collection_geometry_model.gd")

var _collection_geometry: Reference = PickupCollectionGeometryModel.new()


func project(observation: Dictionary, samples: Array) -> Dictionary:
	var events := {"material": [], "consumable": []}
	var collection_radius: float = observation.player_state.pickup.collection_radius
	for pickup in observation.get("remembered_entities", []):
		var kind: String = pickup.get("kind", "")
		if not events.has(kind):
			continue
		var existence_confidence: float = clamp(
			float(pickup.get("existence_confidence", 0.0)), 0.0, 1.0
		)
		if existence_confidence <= 0.0:
			continue
		var event: Dictionary = _collection_geometry.first_collection(
			pickup, samples, collection_radius
		)
		if event.empty():
			continue
		event.event_weight = existence_confidence
		events[kind].push_back(event)
	return events
