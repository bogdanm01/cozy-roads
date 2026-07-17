class_name CozyEndlessRoad
extends Node3D

const MeshFactory := preload("res://scripts/low_poly_mesh.gd")

const CHUNK_LENGTH := 48.0
const CURVE_SUBDIVISIONS := 24
const ROAD_WIDTH := 10.625
const SHOULDER_WIDTH := 14.75
const TERRAIN_WIDTH := 46.0
const INITIAL_CHUNKS := 8
const CHUNKS_AHEAD := 8
const CHUNKS_BEHIND := 2
const MAX_ACTIVE_CHUNKS := 12
const STREAM_DISTANCE := 105.0
const STREAM_SEED := 9012026

var target: Node3D
var start_point := Vector3.ZERO
var start_direction := Vector3.FORWARD

var _chunks: Array[Dictionary] = []
var _next_start := Vector3.ZERO
var _base_heading := 0.0
var _last_generated_index := -1
var _initialized := false

var _terrain_material: StandardMaterial3D
var _shoulder_material: StandardMaterial3D
var _road_material: StandardMaterial3D
var _line_material: StandardMaterial3D
var _reflector_material: StandardMaterial3D
var _trunk_material: StandardMaterial3D
var _foliage_material: StandardMaterial3D
var _foliage_dark_material: StandardMaterial3D
var _ambient_occlusion_material: StandardMaterial3D
var _rock_material: StandardMaterial3D
var _sign_post_material: StandardMaterial3D
var _wayfinding_material: StandardMaterial3D

var _marking_mesh: BoxMesh
var _reflector_mesh: ArrayMesh
var _trunk_mesh: CylinderMesh
var _lower_foliage_mesh: CylinderMesh
var _upper_foliage_mesh: CylinderMesh
var _tree_ao_mesh: ArrayMesh
var _rock_mesh: CylinderMesh


func _ready() -> void:
	_build_shared_resources()
	reset_stream()


func _process(_delta: float) -> void:
	if not _initialized or not is_instance_valid(target) or _chunks.is_empty():
		return
	var nearest_record := _nearest_chunk(target.global_position)
	if nearest_record.is_empty():
		return
	var nearest_distance := _distance_to_record(target.global_position, nearest_record)
	# Do no streaming work while the player is still exploring the handcrafted
	# route. The initial pool already waits beyond the gateway.
	if nearest_distance > STREAM_DISTANCE:
		return
	var nearest_index := int(nearest_record["index"])
	while _last_generated_index < nearest_index + CHUNKS_AHEAD:
		_append_chunk()
	_recycle_chunks(nearest_index)


func reset_stream() -> void:
	for record in _chunks:
		var chunk := record.get("node") as Node3D
		if is_instance_valid(chunk):
			chunk.queue_free()
	_chunks.clear()
	var flat_direction := Vector3(start_direction.x, 0.0, start_direction.z).normalized()
	if flat_direction.length_squared() < 0.5:
		flat_direction = Vector3.FORWARD
	_base_heading = atan2(flat_direction.x, flat_direction.z)
	_next_start = start_point
	_last_generated_index = -1
	for _index in INITIAL_CHUNKS:
		_append_chunk()
	_initialized = true


func distance_from_gateway(position_3d: Vector3) -> float:
	var projection := project_position(position_3d)
	return 0.0 if projection.is_empty() else float(projection["distance"])


func sample_distance(distance: float) -> Dictionary:
	if distance < 0.0 or _chunks.is_empty():
		return {}
	var logical_index := int(floor(distance / CHUNK_LENGTH))
	for record in _chunks:
		if int(record["index"]) != logical_index:
			continue
		var points: Array[Vector3] = record["points"]
		var local_distance := clampf(
			distance - float(logical_index) * CHUNK_LENGTH,
			0.0,
			CHUNK_LENGTH
		)
		var subdivision_length := CHUNK_LENGTH / float(CURVE_SUBDIVISIONS)
		var segment_index := mini(
			int(floor(local_distance / subdivision_length)),
			CURVE_SUBDIVISIONS - 1
		)
		var segment_start_distance := float(segment_index) * subdivision_length
		var t := clampf(
			(local_distance - segment_start_distance) / subdivision_length,
			0.0,
			1.0
		)
		var from := points[segment_index]
		var to := points[segment_index + 1]
		var direction := (to - from).normalized()
		return {
			"position": from.lerp(to, t),
			"direction": direction,
			"distance": distance,
			"chunk_index": logical_index,
		}
	return {}


func project_position(position_3d: Vector3) -> Dictionary:
	if _chunks.is_empty():
		return {}
	var record := _nearest_chunk(position_3d)
	if record.is_empty():
		return {}
	var projection := _closest_point_on_record(position_3d, record)
	var direction: Vector3 = projection["direction"]
	var closest: Vector3 = projection["position"]
	var perpendicular := Vector3(direction.z, 0.0, -direction.x)
	var flat_position := Vector3(position_3d.x, 0.0, position_3d.z)
	var flat_closest := Vector3(closest.x, 0.0, closest.z)
	var subdivision_length := CHUNK_LENGTH / float(CURVE_SUBDIVISIONS)
	var local_distance := (
		float(projection["segment_index"]) * subdivision_length
		+ float(projection["t"]) * subdivision_length
	)
	return {
		"position": closest,
		"direction": direction,
		"distance": float(record["index"]) * CHUNK_LENGTH + local_distance,
		"lateral_distance": flat_position.distance_to(flat_closest),
		"signed_lateral": (flat_position - flat_closest).dot(perpendicular),
		"chunk_index": int(record["index"]),
	}


func active_chunk_count() -> int:
	return _chunks.size()


func first_chunk_index() -> int:
	return -1 if _chunks.is_empty() else int(_chunks.front()["index"])


func last_chunk_index() -> int:
	return -1 if _chunks.is_empty() else int(_chunks.back()["index"])


func chunk_center(logical_index: int) -> Vector3:
	for record in _chunks:
		if int(record["index"]) == logical_index:
			var points: Array[Vector3] = record["points"]
			return points[int(CURVE_SUBDIVISIONS / 2)]
	return Vector3.ZERO


func _append_chunk() -> void:
	var logical_index := _last_generated_index + 1
	var from := _next_start
	var points: Array[Vector3] = [from]
	var subdivision_length := CHUNK_LENGTH / float(CURVE_SUBDIVISIONS)
	var start_heading := _heading_for_index(logical_index)
	var end_heading := _heading_for_index(logical_index + 1)
	for subdivision_index in CURVE_SUBDIVISIONS:
		var t := (float(subdivision_index) + 0.5) / float(CURVE_SUBDIVISIONS)
		var heading := lerp_angle(start_heading, end_heading, t)
		var subdivision_direction := Vector3(sin(heading), 0.0, cos(heading))
		var previous_point: Vector3 = points[points.size() - 1]
		var absolute_distance := (
			float(logical_index) * CHUNK_LENGTH
			+ float(subdivision_index + 1) * subdivision_length
		)
		var next_y := start_point.y + _elevation_offset(absolute_distance)
		var delta_y := next_y - previous_point.y
		# Keep the full 3D segment length at two metres. sample_distance() can
		# therefore continue treating route distance as real distance travelled.
		var horizontal_length := sqrt(
			maxf(0.01, subdivision_length * subdivision_length - delta_y * delta_y)
		)
		var next_point := previous_point + subdivision_direction * horizontal_length
		next_point.y = next_y
		points.append(next_point)
	var to: Vector3 = points[points.size() - 1]

	var chunk := Node3D.new()
	chunk.name = "EndlessRoadChunk%04d" % logical_index
	chunk.set_meta("logical_index", logical_index)
	add_child(chunk)
	_build_ground(chunk, points)
	_build_curved_surface(chunk, points)
	_build_markings(chunk, points)
	_build_trees(chunk, logical_index, points)
	_build_roadside_variation(chunk, logical_index, points)

	_chunks.append({
		"node": chunk,
		"index": logical_index,
		"from": from,
		"to": to,
		"points": points,
	})
	_next_start = to
	_last_generated_index = logical_index


func _heading_for_index(logical_index: int) -> float:
	if logical_index <= 0:
		return _base_heading
	# A pair of low-frequency waves gives long, calm bends while keeping the
	# overall heading within roughly 25 degrees of the route's starting bearing.
	var index := float(logical_index)
	var offset := sin(index * 0.28) * 0.30
	offset += (sin(index * 0.105 + 1.2) - sin(1.2)) * 0.075
	return _base_heading + offset


func _elevation_offset(distance: float) -> float:
	# Two broad cosine waves create long climbs and rolling secondary hills
	# without exceeding a relaxed road grade. Both start with zero height and
	# zero grade, guaranteeing a seamless join at the scenic gateway.
	return (
		(1.0 - cos(distance * 0.018)) * 5.0
		+ (1.0 - cos(distance * 0.006)) * 2.0
	)


func _road_basis(direction: Vector3) -> Basis:
	var forward := direction.normalized()
	var right := Vector3.UP.cross(forward).normalized()
	if right.length_squared() < 0.001:
		right = Vector3.RIGHT
	var surface_normal := forward.cross(right).normalized()
	return Basis(right, surface_normal, forward)


func _build_ground(chunk: Node3D, points: Array[Vector3]) -> void:
	var ground := StaticBody3D.new()
	ground.name = "TerrainCollision"
	ground.collision_layer = 1
	ground.collision_mask = 0
	chunk.add_child(ground)

	var collision_shape := CollisionShape3D.new()
	var ground_shape := ConcavePolygonShape3D.new()
	ground_shape.set_faces(MeshFactory.ribbon_collision_faces(points, TERRAIN_WIDTH))
	collision_shape.shape = ground_shape
	ground.add_child(collision_shape)
	_add_ribbon_mesh(
		chunk,
		"ForestFloor",
		points,
		TERRAIN_WIDTH,
		0.0,
		_terrain_material,
		280.0
	)



func _build_curved_surface(chunk: Node3D, points: Array[Vector3]) -> void:
	_add_ribbon_mesh(
		chunk,
		"GravelShoulder",
		points,
		SHOULDER_WIDTH,
		0.030,
		_shoulder_material,
		260.0
	)
	_add_ribbon_mesh(
		chunk,
		"RoadSurface",
		points,
		ROAD_WIDTH,
		0.068,
		_road_material,
		260.0
	)


func _build_markings(chunk: Node3D, points: Array[Vector3]) -> void:
	var marking_transforms: Array[Transform3D] = []
	var reflector_transforms: Array[Transform3D] = []
	var marking_index := 0
	for segment_index in points.size() - 1:
		var from := points[segment_index]
		var to := points[segment_index + 1]
		var direction := (to - from).normalized()
		var basis := _road_basis(direction)
		var perpendicular := basis.x
		var surface_normal := basis.y
		var unit_count := maxi(1, int(ceil(from.distance_to(to) / 2.35)))
		for unit_index in unit_count:
			var t := (float(unit_index) + 0.5) / float(unit_count)
			var centerline: Vector3 = from.lerp(to, t)
			for side in [-1.0, 1.0]:
				var edge_position: Vector3 = (
					centerline
					+ perpendicular * ROAD_WIDTH * 0.43 * float(side)
					+ surface_normal * 0.084
				)
				marking_transforms.append(Transform3D(basis, edge_position))
			if marking_index % 2 == 0:
				marking_transforms.append(
					Transform3D(basis, centerline + surface_normal * 0.085)
				)
				for side in [-1.0, 1.0]:
					var reflector_position: Vector3 = (
						centerline
						+ perpendicular * ROAD_WIDTH * 0.43 * float(side)
						+ surface_normal * 0.115
					)
					reflector_transforms.append(Transform3D(basis, reflector_position))
			marking_index += 1

	_add_multimesh(chunk, "RoadMarkings", _marking_mesh, _line_material, marking_transforms, false, 230.0)
	_add_multimesh(chunk, "RoadReflectors", _reflector_mesh, _reflector_material, reflector_transforms, false, 210.0)


func _build_trees(chunk: Node3D, logical_index: int, points: Array[Vector3]) -> void:
	var random := RandomNumberGenerator.new()
	random.seed = STREAM_SEED + logical_index * 7919
	var trunk_transforms: Array[Transform3D] = []
	var light_lower_transforms: Array[Transform3D] = []
	var light_upper_transforms: Array[Transform3D] = []
	var dark_lower_transforms: Array[Transform3D] = []
	var dark_upper_transforms: Array[Transform3D] = []
	var ao_transforms: Array[Transform3D] = []
	var rock_transforms: Array[Transform3D] = []

	for tree_index in 18:
		var side := -1.0 if tree_index % 2 == 0 else 1.0
		var t := random.randf_range(0.04, 0.96)
		var road_sample := _sample_polyline(points, t)
		var direction: Vector3 = road_sample["direction"]
		var perpendicular := Vector3(direction.z, 0.0, -direction.x)
		var offset := random.randf_range(8.4, TERRAIN_WIDTH * 0.45)
		var along_jitter := direction * random.randf_range(-2.1, 2.1)
		var position_3d: Vector3 = road_sample["position"] + perpendicular * offset * side + along_jitter
		var scale_value := random.randf_range(0.98, 1.55)
		var rotation := Basis(Vector3.UP, random.randf_range(0.0, TAU))
		var scale_basis := rotation.scaled(Vector3.ONE * scale_value)
		trunk_transforms.append(Transform3D(scale_basis, position_3d + Vector3.UP * 1.18 * scale_value))
		var lower_transform := Transform3D(scale_basis, position_3d + Vector3.UP * 3.12 * scale_value)
		var upper_transform := Transform3D(scale_basis, position_3d + Vector3.UP * 4.43 * scale_value)
		if tree_index % 3 == 0:
			dark_lower_transforms.append(lower_transform)
			dark_upper_transforms.append(upper_transform)
		else:
			light_lower_transforms.append(lower_transform)
			light_upper_transforms.append(upper_transform)
		ao_transforms.append(Transform3D(Basis.IDENTITY.scaled(Vector3(1.18, 1.0, 1.18) * scale_value), position_3d + Vector3.UP * 0.012))
		if tree_index % 5 == 0 and offset < 14.0:
			_add_tree_collider(chunk, position_3d, scale_value)
	for rock_index in 6:
		var rock_side := -1.0 if rock_index % 2 == 0 else 1.0
		var rock_t := random.randf_range(0.06, 0.94)
		var rock_road_sample := _sample_polyline(points, rock_t)
		var rock_direction: Vector3 = rock_road_sample["direction"]
		var rock_perpendicular := Vector3(rock_direction.z, 0.0, -rock_direction.x)
		var rock_offset := random.randf_range(6.6, TERRAIN_WIDTH * 0.43)
		var rock_position: Vector3 = (
			rock_road_sample["position"]
			+ rock_perpendicular * rock_offset * rock_side
		)
		var rock_scale := Vector3(
			random.randf_range(0.55, 1.35),
			random.randf_range(0.45, 1.05),
			random.randf_range(0.60, 1.45)
		)
		var rock_basis := Basis(Vector3.UP, random.randf_range(0.0, TAU)).scaled(rock_scale)
		rock_transforms.append(Transform3D(rock_basis, rock_position + Vector3.UP * 0.34 * rock_scale.y))

	_add_multimesh(chunk, "TreeTrunks", _trunk_mesh, _trunk_material, trunk_transforms, false, 235.0)
	_add_multimesh(chunk, "TreeFoliageLightLower", _lower_foliage_mesh, _foliage_material, light_lower_transforms, false, 235.0)
	_add_multimesh(chunk, "TreeFoliageLightUpper", _upper_foliage_mesh, _foliage_material, light_upper_transforms, false, 235.0)
	_add_multimesh(chunk, "TreeFoliageDarkLower", _lower_foliage_mesh, _foliage_dark_material, dark_lower_transforms, false, 235.0)
	_add_multimesh(chunk, "TreeFoliageDarkUpper", _upper_foliage_mesh, _foliage_dark_material, dark_upper_transforms, false, 235.0)
	_add_multimesh(chunk, "TreeBaseAO", _tree_ao_mesh, _ambient_occlusion_material, ao_transforms, false, 180.0)
	_add_multimesh(chunk, "RoadsideRocks", _rock_mesh, _rock_material, rock_transforms, false, 210.0)


func _build_roadside_variation(
	chunk: Node3D,
	logical_index: int,
	points: Array[Vector3]
) -> void:
	if logical_index % 5 != 2:
		return
	var road_sample := _sample_polyline(points, 0.66)
	var direction: Vector3 = road_sample["direction"]
	var perpendicular := Vector3(direction.z, 0.0, -direction.x)
	var side := -1.0 if logical_index % 10 == 2 else 1.0
	var sign_position: Vector3 = road_sample["position"] + perpendicular * 7.125 * side
	var yaw := atan2(direction.x, direction.z)
	_add_box_mesh(chunk, "WayfindingPost", Vector3(0.14, 1.75, 0.14), sign_position + Vector3.UP * 0.88, _sign_post_material, yaw)
	_add_box_mesh(chunk, "ReflectiveWayfindingSign", Vector3(1.28, 0.62, 0.10), sign_position + Vector3.UP * 1.72, _wayfinding_material, yaw)


func _sample_polyline(points: Array[Vector3], normalized_distance: float) -> Dictionary:
	var scaled_distance := clampf(normalized_distance, 0.0, 1.0) * float(CURVE_SUBDIVISIONS)
	var segment_index := mini(int(floor(scaled_distance)), CURVE_SUBDIVISIONS - 1)
	var t := clampf(scaled_distance - float(segment_index), 0.0, 1.0)
	var from := points[segment_index]
	var to := points[segment_index + 1]
	return {
		"position": from.lerp(to, t),
		"direction": (to - from).normalized(),
	}


func _add_tree_collider(chunk: Node3D, position_3d: Vector3, scale_value: float) -> void:
	var body := StaticBody3D.new()
	body.name = "TreeCollider"
	body.position = position_3d + Vector3.UP * 1.45 * scale_value
	body.collision_layer = 1
	body.collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.34 * scale_value
	shape.height = 2.9 * scale_value
	collision.shape = shape
	body.add_child(collision)
	chunk.add_child(body)


func _add_multimesh(
	parent: Node3D,
	node_name: String,
	mesh: Mesh,
	material: Material,
	transforms: Array[Transform3D],
	cast_shadows: bool,
	visibility_end: float
) -> void:
	if transforms.is_empty():
		return
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for index in transforms.size():
		multimesh.set_instance_transform(index, transforms[index])
	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = multimesh
	instance.material_override = material
	instance.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if cast_shadows
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	instance.visibility_range_end = visibility_end
	parent.add_child(instance)


func _add_ribbon_mesh(
	parent: Node3D,
	node_name: String,
	points: Array[Vector3],
	width: float,
	normal_offset: float,
	material: Material,
	visibility_end: float
) -> void:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = MeshFactory.ribbon(points, width, normal_offset)
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.visibility_range_end = visibility_end
	parent.add_child(instance)


func _add_box_mesh(
	parent: Node3D,
	node_name: String,
	size: Vector3,
	position_3d: Vector3,
	material: Material,
	yaw: float
) -> void:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	var mesh := BoxMesh.new()
	mesh.size = size
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position_3d
	instance.rotation.y = yaw
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)


func _nearest_chunk(position_3d: Vector3) -> Dictionary:
	var nearest: Dictionary = {}
	var nearest_distance := INF
	for record in _chunks:
		var distance := _distance_to_record(position_3d, record)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = record
	return nearest


func _closest_point_on_record(position_3d: Vector3, record: Dictionary) -> Dictionary:
	var points: Array[Vector3] = record["points"]
	var flat_position := Vector3(position_3d.x, 0.0, position_3d.z)
	var closest_position := points[0]
	var closest_direction := Vector3.FORWARD
	var closest_distance_squared := INF
	var closest_segment_index := 0
	var closest_t := 0.0
	for segment_index in points.size() - 1:
		var from := points[segment_index]
		var to := points[segment_index + 1]
		var flat_from := Vector3(from.x, 0.0, from.z)
		var flat_to := Vector3(to.x, 0.0, to.z)
		var flat_segment := flat_to - flat_from
		var t := clampf(
			(flat_position - flat_from).dot(flat_segment)
			/ maxf(flat_segment.length_squared(), 0.001),
			0.0,
			1.0
		)
		var candidate := from.lerp(to, t)
		var flat_candidate := Vector3(candidate.x, 0.0, candidate.z)
		var distance_squared := flat_position.distance_squared_to(flat_candidate)
		if distance_squared < closest_distance_squared:
			closest_distance_squared = distance_squared
			closest_position = candidate
			closest_direction = (to - from).normalized()
			closest_segment_index = segment_index
			closest_t = t
	return {
		"position": closest_position,
		"direction": closest_direction,
		"distance_squared": closest_distance_squared,
		"segment_index": closest_segment_index,
		"t": closest_t,
	}


func _distance_to_record(position_3d: Vector3, record: Dictionary) -> float:
	var projection := _closest_point_on_record(position_3d, record)
	return sqrt(float(projection["distance_squared"]))


func _recycle_chunks(nearest_index: int) -> void:
	var oldest_allowed := maxi(0, nearest_index - CHUNKS_BEHIND)
	while not _chunks.is_empty() and (
		int(_chunks.front()["index"]) < oldest_allowed
		or _chunks.size() > MAX_ACTIVE_CHUNKS
	):
		var record: Dictionary = _chunks.pop_front()
		var chunk := record.get("node") as Node3D
		if is_instance_valid(chunk):
			chunk.queue_free()


func _build_shared_resources() -> void:
	_terrain_material = _material(Color("14201d"), 0.98)
	_shoulder_material = _material(Color("473d36"), 0.96)
	_road_material = _material(Color("252b30"), 0.91)
	_line_material = _material(Color("c8cbca"), 0.78)
	_reflector_material = _emissive_material(Color("bec9ca"), Color("d9f3ff"), 0.68, 0.48)
	_trunk_material = _material(Color("382c27"), 0.96)
	_foliage_material = _material(Color("17312d"), 0.97)
	_foliage_dark_material = _material(Color("102622"), 0.98)
	_rock_material = _material(Color("465052"), 0.98)
	_sign_post_material = _material(Color("505a60"), 0.88)
	_wayfinding_material = _emissive_material(Color("a57437"), Color("ffc36c"), 0.52, 0.54)
	_ambient_occlusion_material = _material(Color("070b0c"), 1.0)
	_ambient_occlusion_material.vertex_color_use_as_albedo = true
	_ambient_occlusion_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ambient_occlusion_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ambient_occlusion_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	_marking_mesh = BoxMesh.new()
	_marking_mesh.size = Vector3(0.115, 0.018, 2.35)
	_reflector_mesh = MeshFactory.beveled_box(Vector3(0.15, 0.055, 0.24), 0.016)
	_trunk_mesh = CylinderMesh.new()
	_trunk_mesh.top_radius = 0.21
	_trunk_mesh.bottom_radius = 0.33
	_trunk_mesh.height = 2.36
	_trunk_mesh.radial_segments = 7
	_lower_foliage_mesh = CylinderMesh.new()
	_lower_foliage_mesh.top_radius = 0.0
	_lower_foliage_mesh.bottom_radius = 1.72
	_lower_foliage_mesh.height = 3.35
	_lower_foliage_mesh.radial_segments = 8
	_upper_foliage_mesh = CylinderMesh.new()
	_upper_foliage_mesh.top_radius = 0.0
	_upper_foliage_mesh.bottom_radius = 1.25
	_upper_foliage_mesh.height = 2.72
	_upper_foliage_mesh.radial_segments = 8
	_tree_ao_mesh = MeshFactory.soft_disc(18)
	_rock_mesh = CylinderMesh.new()
	_rock_mesh.top_radius = 0.28
	_rock_mesh.bottom_radius = 0.68
	_rock_mesh.height = 0.72
	_rock_mesh.radial_segments = 7


func _material(color: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material


func _emissive_material(
	color: Color,
	emission_color: Color,
	emission_energy: float,
	roughness: float
) -> StandardMaterial3D:
	var material := _material(color, roughness)
	material.emission_enabled = true
	material.emission = emission_color
	material.emission_energy_multiplier = emission_energy
	return material
