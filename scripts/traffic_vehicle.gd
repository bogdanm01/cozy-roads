class_name CozyTrafficVehicle
extends AnimatableBody3D

const MeshFactory := preload("res://scripts/low_poly_mesh.gd")

var route_distance := 0.0
var travel_sign := 1.0
var cruise_speed := 12.0
var current_speed := 0.0
var pool_index := 0

var brake_light_material: StandardMaterial3D
var headlight: SpotLight3D
var _built := false


func configure(vehicle_index: int) -> void:
	pool_index = vehicle_index
	if _built:
		return
	_built = true
	name = "TrafficVehicle%d" % vehicle_index
	sync_to_physics = true
	collision_layer = 1
	collision_mask = 1
	_build_collision()
	_build_visual(vehicle_index)


func set_brake_level(level: float) -> void:
	if not is_instance_valid(brake_light_material):
		return
	var amount := clampf(level, 0.0, 1.0)
	brake_light_material.emission_energy_multiplier = lerpf(0.65, 3.4, amount)
	brake_light_material.albedo_color = Color("d33931").lerp(Color("ff5547"), amount)


func set_headlights_enabled(enabled: bool) -> void:
	if is_instance_valid(headlight):
		headlight.visible = enabled


func _build_collision() -> void:
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.78, 1.22, 4.18)
	collision.shape = shape
	collision.position = Vector3(0.0, 0.78, 0.0)
	add_child(collision)


func _build_visual(vehicle_index: int) -> void:
	var palettes: Array[Color] = [
		Color("55727d"),
		Color("9b6047"),
		Color("77735d"),
		Color("6d5f82"),
		Color("496858"),
	]
	var paint := _material(palettes[vehicle_index % palettes.size()], 0.84)
	var glass := _material(Color("17242b"), 0.34)
	var trim := _material(Color("343b40"), 0.72)
	var headlight_material := _emissive_material(Color("e8e1ce"), Color("ffd7a2"), 1.8, 0.35)
	brake_light_material = _emissive_material(Color("d33931"), Color("f04439"), 0.65, 0.42)

	_add_box_batch("PaintedBody", paint, [
		{"size": Vector3(1.82, 0.55, 4.28), "position": Vector3(0.0, 0.70, 0.0)},
		{"size": Vector3(1.72, 0.24, 1.28), "position": Vector3(0.0, 1.05, -1.37)},
		{"size": Vector3(1.62, 0.64, 1.94), "position": Vector3(0.0, 1.29, 0.27)},
		{"size": Vector3(1.48, 0.14, 1.62), "position": Vector3(0.0, 1.68, 0.27)},
	])
	_add_box_batch("TrafficGlass", glass, [
		{"size": Vector3(1.40, 0.42, 0.07), "position": Vector3(0.0, 1.42, -0.72)},
		{"size": Vector3(1.40, 0.42, 0.07), "position": Vector3(0.0, 1.42, 1.20)},
		{"size": Vector3(0.05, 0.42, 1.42), "position": Vector3(-0.825, 1.42, 0.27)},
		{"size": Vector3(0.05, 0.42, 1.42), "position": Vector3(0.825, 1.42, 0.27)},
	])
	_add_box_batch("TrafficTrim", trim, [
		{"size": Vector3(1.92, 0.20, 0.20), "position": Vector3(0.0, 0.52, -2.17)},
		{"size": Vector3(1.92, 0.20, 0.20), "position": Vector3(0.0, 0.52, 2.17)},
		{"size": Vector3(0.92, 0.23, 0.06), "position": Vector3(0.0, 0.83, -2.18)},
	])
	_add_box_batch("TrafficHeadlights", headlight_material, [
		{"size": Vector3(0.34, 0.24, 0.07), "position": Vector3(-0.60, 0.88, -2.19)},
		{"size": Vector3(0.34, 0.24, 0.07), "position": Vector3(0.60, 0.88, -2.19)},
	])
	_add_box_batch("TrafficBrakeLights", brake_light_material, [
		{"size": Vector3(0.34, 0.23, 0.07), "position": Vector3(-0.62, 0.88, 2.19)},
		{"size": Vector3(0.34, 0.23, 0.07), "position": Vector3(0.62, 0.88, 2.19)},
	])
	_add_wheel_batch(trim)

	headlight = SpotLight3D.new()
	headlight.name = "TrafficHeadlightBeam"
	headlight.light_color = Color("ffd5a0")
	headlight.light_energy = 1.35
	headlight.spot_range = 17.0
	headlight.spot_angle = 42.0
	headlight.spot_angle_attenuation = 0.78
	headlight.shadow_enabled = false
	headlight.position = Vector3(0.0, 0.90, -2.10)
	headlight.rotation.x = deg_to_rad(-3.0)
	add_child(headlight)


func _add_box_batch(node_name: String, material: Material, boxes: Array[Dictionary]) -> void:
	var mesh := MeshFactory.beveled_box(Vector3.ONE, 0.07)
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = boxes.size()
	for index in boxes.size():
		var size: Vector3 = boxes[index]["size"]
		var local_position: Vector3 = boxes[index]["position"]
		multimesh.set_instance_transform(index, Transform3D(Basis.IDENTITY.scaled(size), local_position))
	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = multimesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.visibility_range_end = 190.0
	add_child(instance)


func _add_wheel_batch(material: Material) -> void:
	var wheel_mesh := CylinderMesh.new()
	wheel_mesh.top_radius = 0.38
	wheel_mesh.bottom_radius = 0.38
	wheel_mesh.height = 0.22
	wheel_mesh.radial_segments = 10
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = wheel_mesh
	multimesh.instance_count = 4
	var wheel_basis := Basis.from_euler(Vector3(0.0, 0.0, PI * 0.5))
	var positions: Array[Vector3] = [
		Vector3(-0.91, 0.43, -1.38),
		Vector3(0.91, 0.43, -1.38),
		Vector3(-0.91, 0.43, 1.38),
		Vector3(0.91, 0.43, 1.38),
	]
	for index in positions.size():
		multimesh.set_instance_transform(index, Transform3D(wheel_basis, positions[index]))
	var instance := MultiMeshInstance3D.new()
	instance.name = "TrafficWheels"
	instance.multimesh = multimesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.visibility_range_end = 190.0
	add_child(instance)


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
