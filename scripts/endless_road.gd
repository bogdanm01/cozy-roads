class_name CozyEndlessRoad
extends Node3D

const MeshFactory := preload("res://scripts/low_poly_mesh.gd")

const CHUNK_LENGTH := 48.0
const ROAD_WIDTH := 8.5
const SHOULDER_WIDTH := 11.8
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

var _marking_mesh: BoxMesh
var _reflector_mesh: ArrayMesh
var _trunk_mesh: CylinderMesh
var _lower_foliage_mesh: CylinderMesh
var _upper_foliage_mesh: CylinderMesh
var _tree_ao_mesh: ArrayMesh


func _ready() -> void:
	_build_shared_resources()
	reset_stream()


func _process(_delta: float) -> void:
	if not _initialized or not is_instance_valid(target) or _chunks.is_empty():
		return
	var nearest_record := _nearest_chunk(target.global_position)
	if nearest_record.is_empty():
		return
	var nearest_distance := _distance_to_segment(
		target.global_position,
		nearest_record["from"],
		nearest_record["to"]
	)
	# Do no streaming work while the player is still exploring the proving ground
	# and handcrafted route. The initial pool already waits beyond the gateway.
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
	_next_start = Vector3(start_point.x, 0.0, start_point.z)
	_last_generated_index = -1
	for _index in INITIAL_CHUNKS:
		_append_chunk()
	_initialized = true


func distance_from_gateway(position_3d: Vector3) -> float:
	if _chunks.is_empty():
		return 0.0
	var record := _nearest_chunk(position_3d)
	if record.is_empty():
		return 0.0
	var from: Vector3 = record["from"]
	var to: Vector3 = record["to"]
	var segment := to - from
	var t := clampf((position_3d - from).dot(segment) / maxf(segment.length_squared(), 0.001), 0.0, 1.0)
	return (float(record["index"]) + t) * CHUNK_LENGTH


func active_chunk_count() -> int:
	return _chunks.size()


func first_chunk_index() -> int:
	return -1 if _chunks.is_empty() else int(_chunks.front()["index"])


func last_chunk_index() -> int:
	return -1 if _chunks.is_empty() else int(_chunks.back()["index"])


func chunk_center(logical_index: int) -> Vector3:
	for record in _chunks:
		if int(record["index"]) == logical_index:
			return (record["from"] + record["to"]) * 0.5
	return Vector3.ZERO


func _append_chunk() -> void:
	var logical_index := _last_generated_index + 1
	var heading := _heading_for_index(logical_index)
	var direction := Vector3(sin(heading), 0.0, cos(heading))
	var from := _next_start
	var to := from + direction * CHUNK_LENGTH
	var center := (from + to) * 0.5
	var yaw := atan2(direction.x, direction.z)

	var chunk := Node3D.new()
	chunk.name = "EndlessRoadChunk%04d" % logical_index
	chunk.set_meta("logical_index", logical_index)
	add_child(chunk)
	_build_ground(chunk, center, yaw)
	_build_markings(chunk, from, to, direction, yaw)
	_build_trees(chunk, logical_index, from, to, direction)

	_chunks.append({
		"node": chunk,
		"index": logical_index,
		"from": from,
		"to": to,
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


func _build_ground(chunk: Node3D, center: Vector3, yaw: float) -> void:
	var terrain_size := Vector3(TERRAIN_WIDTH, 0.50, CHUNK_LENGTH + 2.2)
	var ground := StaticBody3D.new()
	ground.name = "TerrainCollision"
	ground.position = center + Vector3.DOWN * 0.29
	ground.rotation.y = yaw
	ground.collision_layer = 1
	ground.collision_mask = 0
	chunk.add_child(ground)

	var terrain_mesh := MeshInstance3D.new()
	terrain_mesh.name = "ForestFloor"
	var terrain_box := BoxMesh.new()
	terrain_box.size = terrain_size
	terrain_mesh.mesh = terrain_box
	terrain_mesh.material_override = _terrain_material
	terrain_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ground.add_child(terrain_mesh)

	var collision_shape := CollisionShape3D.new()
	var ground_shape := BoxShape3D.new()
	ground_shape.size = terrain_size
	collision_shape.shape = ground_shape
	ground.add_child(collision_shape)

	_add_box_mesh(
		chunk,
		"GravelShoulder",
		Vector3(SHOULDER_WIDTH, 0.055, CHUNK_LENGTH + 1.5),
		center + Vector3.UP * 0.002,
		_shoulder_material,
		yaw
	)
	_add_box_mesh(
		chunk,
		"RoadSurface",
		Vector3(ROAD_WIDTH, 0.055, CHUNK_LENGTH + 1.6),
		center + Vector3.UP * 0.040,
		_road_material,
		yaw
	)


func _build_markings(chunk: Node3D, from: Vector3, to: Vector3, direction: Vector3, yaw: float) -> void:
	var perpendicular := Vector3(direction.z, 0.0, -direction.x)
	var marking_transforms: Array[Transform3D] = []
	var reflector_transforms: Array[Transform3D] = []
	var basis := Basis.from_euler(Vector3(0.0, yaw, 0.0))
	var unit_count := int(ceil(CHUNK_LENGTH / 2.35))
	for unit_index in unit_count:
		var t := (float(unit_index) + 0.5) / float(unit_count)
		var centerline: Vector3 = from.lerp(to, t)
		for side in [-1.0, 1.0]:
			var edge_position: Vector3 = centerline + perpendicular * ROAD_WIDTH * 0.43 * float(side) + Vector3.UP * 0.084
			marking_transforms.append(Transform3D(basis, edge_position))
		if unit_index % 2 == 0:
			marking_transforms.append(Transform3D(basis, centerline + Vector3.UP * 0.085))
		if unit_index % 2 == 0:
			for side in [-1.0, 1.0]:
				var reflector_position: Vector3 = centerline + perpendicular * ROAD_WIDTH * 0.43 * float(side) + Vector3.UP * 0.115
				reflector_transforms.append(Transform3D(basis, reflector_position))

	_add_multimesh(chunk, "RoadMarkings", _marking_mesh, _line_material, marking_transforms, false, 230.0)
	_add_multimesh(chunk, "RoadReflectors", _reflector_mesh, _reflector_material, reflector_transforms, false, 210.0)


func _build_trees(chunk: Node3D, logical_index: int, from: Vector3, to: Vector3, direction: Vector3) -> void:
	var random := RandomNumberGenerator.new()
	random.seed = STREAM_SEED + logical_index * 7919
	var perpendicular := Vector3(direction.z, 0.0, -direction.x)
	var trunk_transforms: Array[Transform3D] = []
	var light_lower_transforms: Array[Transform3D] = []
	var light_upper_transforms: Array[Transform3D] = []
	var dark_lower_transforms: Array[Transform3D] = []
	var dark_upper_transforms: Array[Transform3D] = []
	var ao_transforms: Array[Transform3D] = []

	for tree_index in 18:
		var side := -1.0 if tree_index % 2 == 0 else 1.0
		var t := random.randf_range(0.04, 0.96)
		var offset := random.randf_range(8.4, TERRAIN_WIDTH * 0.45)
		var along_jitter := direction * random.randf_range(-2.1, 2.1)
		var position_3d := from.lerp(to, t) + perpendicular * offset * side + along_jitter
		var scale_value := random.randf_range(0.72, 1.23)
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

	_add_multimesh(chunk, "TreeTrunks", _trunk_mesh, _trunk_material, trunk_transforms, false, 235.0)
	_add_multimesh(chunk, "TreeFoliageLightLower", _lower_foliage_mesh, _foliage_material, light_lower_transforms, false, 235.0)
	_add_multimesh(chunk, "TreeFoliageLightUpper", _upper_foliage_mesh, _foliage_material, light_upper_transforms, false, 235.0)
	_add_multimesh(chunk, "TreeFoliageDarkLower", _lower_foliage_mesh, _foliage_dark_material, dark_lower_transforms, false, 235.0)
	_add_multimesh(chunk, "TreeFoliageDarkUpper", _upper_foliage_mesh, _foliage_dark_material, dark_upper_transforms, false, 235.0)
	_add_multimesh(chunk, "TreeBaseAO", _tree_ao_mesh, _ambient_occlusion_material, ao_transforms, false, 180.0)


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
		var distance := _distance_to_segment(position_3d, record["from"], record["to"])
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = record
	return nearest


func _distance_to_segment(position_3d: Vector3, from: Vector3, to: Vector3) -> float:
	var flat_position := Vector3(position_3d.x, 0.0, position_3d.z)
	var segment := to - from
	var t := clampf((flat_position - from).dot(segment) / maxf(segment.length_squared(), 0.001), 0.0, 1.0)
	return flat_position.distance_to(from + segment * t)


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
