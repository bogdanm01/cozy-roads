class_name CozyTrafficManager
extends Node3D

const TrafficVehicleScript := preload("res://scripts/traffic_vehicle.gd")

const VEHICLE_COUNT := 5
const LANE_OFFSET := 1.82
const SAFE_FOLLOW_DISTANCE := 25.0
const PLAYER_BRAKE_DISTANCE := 15.0
const RECYCLE_BEHIND := 115.0
const RECYCLE_AHEAD := 235.0

var target: CozyCar
var endless_road: CozyEndlessRoad
var scenic_points: Array[Vector3] = []
var scenic_total_length := 0.0
var player_route_distance := 0.0
var player_signed_lateral := 0.0
var recycle_count := 0

var vehicles: Array[CozyTrafficVehicle] = []
var _random := RandomNumberGenerator.new()


func _ready() -> void:
	_random.seed = 17072026
	if scenic_total_length <= 0.0:
		scenic_total_length = _calculate_scenic_length()
	_build_pool()
	var initial_projection := _project_player()
	if not initial_projection.is_empty():
		player_route_distance = float(initial_projection["distance"])
		player_signed_lateral = float(initial_projection.get("signed_lateral", 0.0))
	for index in vehicles.size():
		_respawn_vehicle(vehicles[index])


func _physics_process(delta: float) -> void:
	if not is_instance_valid(target) or not is_instance_valid(endless_road):
		return
	var projection := _project_player()
	if projection.is_empty():
		return
	player_route_distance = float(projection["distance"])
	player_signed_lateral = float(projection.get("signed_lateral", 0.0))
	for vehicle in vehicles:
		_update_vehicle(vehicle, delta)


func active_vehicle_count() -> int:
	var count := 0
	for vehicle in vehicles:
		if vehicle.visible:
			count += 1
	return count


func reset_traffic() -> void:
	var projection := _project_player()
	if not projection.is_empty():
		player_route_distance = float(projection["distance"])
		player_signed_lateral = float(projection.get("signed_lateral", 0.0))
	for index in vehicles.size():
		_respawn_vehicle(vehicles[index])


func _build_pool() -> void:
	for index in VEHICLE_COUNT:
		var vehicle: CozyTrafficVehicle = TrafficVehicleScript.new()
		vehicle.configure(index)
		vehicle.travel_sign = 1.0 if index % 2 == 0 else -1.0
		vehicle.cruise_speed = 10.5 + float((index * 17) % 6)
		vehicle.current_speed = vehicle.cruise_speed * 0.82
		vehicles.append(vehicle)
		add_child(vehicle)


func _update_vehicle(vehicle: CozyTrafficVehicle, delta: float) -> void:
	var relative_distance := vehicle.route_distance - player_route_distance
	if (
		relative_distance < -RECYCLE_BEHIND
		or relative_distance > RECYCLE_AHEAD
		or vehicle.route_distance < 1.0
	):
		_respawn_vehicle(vehicle)
		return

	var target_speed := vehicle.cruise_speed
	for other in vehicles:
		if other == vehicle or not other.visible or other.travel_sign != vehicle.travel_sign:
			continue
		var traffic_gap := (other.route_distance - vehicle.route_distance) * vehicle.travel_sign
		if traffic_gap > 0.0 and traffic_gap < SAFE_FOLLOW_DISTANCE:
			var safe_speed := maxf(0.0, other.current_speed + (traffic_gap - 8.0) * 0.35)
			target_speed = minf(target_speed, safe_speed)

	# Same-direction traffic yields to a slower player ahead. A short spatial
	# emergency check also makes an oncoming car brake if the player blocks its lane.
	var vehicle_lane_lateral := -LANE_OFFSET * vehicle.travel_sign
	var player_lane_gap := absf(player_signed_lateral - vehicle_lane_lateral)
	if vehicle.travel_sign > 0.0 and player_lane_gap < 2.25:
		var player_gap := player_route_distance - vehicle.route_distance
		if player_gap > 0.0 and player_gap < SAFE_FOLLOW_DISTANCE:
			target_speed = minf(target_speed, maxf(0.0, (player_gap - 6.0) * 0.55))
	var player_separation := vehicle.global_position.distance_to(target.global_position)
	if player_lane_gap < 2.25 and player_separation < PLAYER_BRAKE_DISTANCE:
		target_speed = minf(target_speed, maxf(0.0, (player_separation - 4.8) * 0.82))

	var previous_speed := vehicle.current_speed
	var response := 4.2 if target_speed < vehicle.current_speed else 1.65
	vehicle.current_speed = move_toward(vehicle.current_speed, target_speed, response * delta)
	vehicle.route_distance += vehicle.travel_sign * vehicle.current_speed * delta
	var sample := _sample_route(vehicle.route_distance)
	if sample.is_empty():
		_respawn_vehicle(vehicle)
		return
	_place_at_sample(vehicle, sample, delta, false)
	var braking := clampf((previous_speed - vehicle.current_speed) / maxf(delta * 2.4, 0.01), 0.0, 1.0)
	vehicle.set_brake_level(braking)


func _respawn_vehicle(vehicle: CozyTrafficVehicle, extra_offset := 0.0) -> void:
	# Alternating travel directions plus a 34 m index interval leaves cars in
	# each individual lane roughly 68 m apart: present, but never a convoy.
	var base_offset := 72.0 + float(vehicle.pool_index) * 34.0 + extra_offset
	base_offset += _random.randf_range(-6.0, 8.0)
	var sample: Dictionary = {}
	for attempt in 5:
		vehicle.route_distance = player_route_distance + base_offset - float(attempt) * 24.0
		sample = _sample_route(vehicle.route_distance)
		if not sample.is_empty() and vehicle.route_distance > 2.0:
			break
	if sample.is_empty() or vehicle.route_distance <= 2.0:
		_set_vehicle_active(vehicle, false)
		return
	vehicle.current_speed = vehicle.cruise_speed * _random.randf_range(0.76, 0.94)
	vehicle.set_brake_level(0.0)
	_set_vehicle_active(vehicle, true)
	_place_at_sample(vehicle, sample, 0.0, true)
	recycle_count += 1


func _place_at_sample(vehicle: CozyTrafficVehicle, sample: Dictionary, delta: float, immediate: bool) -> void:
	var road_position: Vector3 = sample["position"]
	var road_direction: Vector3 = sample["direction"]
	var perpendicular := Vector3(road_direction.z, 0.0, -road_direction.x)
	var lane_position := road_position - perpendicular * LANE_OFFSET * vehicle.travel_sign
	lane_position.y += 0.015
	var travel_direction := road_direction * vehicle.travel_sign
	var target_yaw := atan2(-travel_direction.x, -travel_direction.z)
	var applied_yaw := target_yaw
	if immediate or delta <= 0.0:
		applied_yaw = target_yaw
	else:
		applied_yaw = lerp_angle(vehicle.global_rotation.y, target_yaw, 1.0 - exp(-7.0 * delta))
	# AnimatableBody3D synchronizes a single transform into the physics server.
	# Assigning position and rotation independently can make the second property
	# write restore the previous synchronized origin, collapsing cars to (0, 0, 0).
	vehicle.global_transform = Transform3D(Basis(Vector3.UP, applied_yaw), lane_position)


func _sample_route(distance: float) -> Dictionary:
	if distance < 0.0:
		return {}
	if distance <= scenic_total_length:
		return _sample_scenic(distance)
	return endless_road.sample_distance(distance - scenic_total_length)


func _sample_scenic(distance: float) -> Dictionary:
	if scenic_points.size() < 2:
		return {}
	var accumulated := 0.0
	for index in scenic_points.size() - 1:
		var from := scenic_points[index]
		var to := scenic_points[index + 1]
		var segment := to - from
		var length := segment.length()
		if distance <= accumulated + length or index == scenic_points.size() - 2:
			var t := clampf((distance - accumulated) / maxf(length, 0.001), 0.0, 1.0)
			return {
				"position": from.lerp(to, t),
				"direction": segment.normalized(),
				"distance": distance,
			}
		accumulated += length
	return {}


func _project_player() -> Dictionary:
	var scenic_projection := _project_scenic(target.global_position)
	var endless_projection := endless_road.project_position(target.global_position)
	if endless_projection.is_empty():
		return scenic_projection
	var endless_lateral := float(endless_projection["lateral_distance"])
	var scenic_lateral := INF if scenic_projection.is_empty() else float(scenic_projection["lateral_distance"])
	if endless_lateral < scenic_lateral:
		endless_projection["distance"] = scenic_total_length + float(endless_projection["distance"])
		return endless_projection
	return scenic_projection


func _project_scenic(position_3d: Vector3) -> Dictionary:
	if scenic_points.size() < 2:
		return {}
	var flat_position := Vector3(position_3d.x, 0.0, position_3d.z)
	var nearest: Dictionary = {}
	var nearest_distance := INF
	var accumulated := 0.0
	for index in scenic_points.size() - 1:
		var from := scenic_points[index]
		var to := scenic_points[index + 1]
		var segment := to - from
		var length := segment.length()
		var t := clampf((flat_position - from).dot(segment) / maxf(segment.length_squared(), 0.001), 0.0, 1.0)
		var closest := from + segment * t
		var lateral := flat_position.distance_to(closest)
		if lateral < nearest_distance:
			nearest_distance = lateral
			var direction := segment.normalized()
			var perpendicular := Vector3(direction.z, 0.0, -direction.x)
			nearest = {
				"position": closest,
				"direction": direction,
				"distance": accumulated + length * t,
				"lateral_distance": lateral,
				"signed_lateral": (flat_position - closest).dot(perpendicular),
			}
		accumulated += length
	return nearest


func _calculate_scenic_length() -> float:
	var total := 0.0
	for index in scenic_points.size() - 1:
		total += scenic_points[index].distance_to(scenic_points[index + 1])
	return total


func _set_vehicle_active(vehicle: CozyTrafficVehicle, active: bool) -> void:
	vehicle.visible = active
	vehicle.collision_layer = 1 if active else 0
	vehicle.collision_mask = 1 if active else 0
	if is_instance_valid(vehicle.headlight):
		vehicle.headlight.visible = active
