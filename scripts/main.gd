extends Node3D

const CarScript := preload("res://scripts/car.gd")
const CameraScript := preload("res://scripts/follow_camera.gd")

const WHITE := Color("eeeeee")
const LIGHT_GRAY := Color("aeb2b4")
const MID_GRAY := Color("656a6d")
const DARK_GRAY := Color("25282a")
const BLACK := Color("0d0e0f")

var player_car: CozyCar
var telemetry_label: Label


func _ready() -> void:
	_build_environment()
	_build_test_field()
	player_car = CozyCar.new()
	player_car.name = "PlayerCar"
	player_car.position = Vector3(0.0, 0.0, 42.0)
	add_child(player_car)

	var camera := CozyFollowCamera.new()
	camera.name = "FollowCamera"
	camera.target = player_car
	add_child(camera)
	camera.current = true
	_build_ui()


func _process(_delta: float) -> void:
	if is_instance_valid(player_car) and is_instance_valid(telemetry_label):
		var speed_kmh := absf(player_car.speed) * 3.6
		var steering_degrees := rad_to_deg(player_car.steering_angle)
		telemetry_label.text = "HANDLING TEST FIELD\n%3.0f km/h  •  steering %+.0f°\nWASD / arrows to drive  •  R to reset" % [speed_kmh, steering_degrees]


func _build_environment() -> void:
	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = LIGHT_GRAY
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = WHITE
	environment.ambient_light_energy = 0.52
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	world_environment.environment = environment
	add_child(world_environment)

	var sun := DirectionalLight3D.new()
	sun.name = "NeutralLight"
	sun.light_color = WHITE
	sun.light_energy = 0.82
	sun.rotation_degrees = Vector3(-55.0, -30.0, 0.0)
	sun.shadow_enabled = true
	add_child(sun)


func _build_test_field() -> void:
	_add_static_box("Base", Vector3(220.0, 0.5, 240.0), Vector3(0.0, -0.25, -45.0), MID_GRAY, true)
	_add_static_box("DrivingPad", Vector3(104.0, 0.06, 180.0), Vector3(0.0, 0.03, -45.0), DARK_GRAY, false)

	# Ten-metre reference grid.
	for x in range(-50, 51, 10):
		_add_visual_box("GridLine", Vector3(0.055, 0.015, 180.0), Vector3(float(x), 0.065, -45.0), LIGHT_GRAY)
	for z in range(-130, 46, 10):
		_add_visual_box("GridLine", Vector3(104.0, 0.015, 0.055), Vector3(0.0, 0.065, float(z)), LIGHT_GRAY)

	# Main lane and center line.
	_add_visual_box("LaneLeft", Vector3(0.14, 0.02, 168.0), Vector3(-5.0, 0.075, -43.0), WHITE)
	_add_visual_box("LaneRight", Vector3(0.14, 0.02, 168.0), Vector3(5.0, 0.075, -43.0), WHITE)
	for z in range(-122, 40, 8):
		_add_visual_box("CenterDash", Vector3(0.11, 0.022, 3.8), Vector3(0.0, 0.078, float(z)), WHITE)

	# Slalom for low-speed steering tests.
	for index in 7:
		var marker_x := -2.6 if index % 2 == 0 else 2.6
		_add_marker(Vector3(marker_x, 0.0, 12.0 - index * 9.0), index)

	# Braking box and a broad turning circle.
	_add_outline_rect(Vector3(26.0, 0.08, -75.0), Vector2(16.0, 28.0))
	_add_turning_circle(Vector3(-28.0, 0.08, -82.0), 13.0)

	# Alternating boundary blocks make speed and camera motion easy to read.
	for index in 18:
		var z_position := 38.0 - index * 10.0
		var color := WHITE if index % 2 == 0 else BLACK
		_add_static_box("Boundary", Vector3(2.0, 0.8, 9.5), Vector3(-53.0, 0.2, z_position), color, true)
		_add_static_box("Boundary", Vector3(2.0, 0.8, 9.5), Vector3(53.0, 0.2, z_position), color, true)


func _add_marker(position_3d: Vector3, index: int) -> void:
	var marker := MeshInstance3D.new()
	marker.name = "SlalomMarker%d" % index
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.22
	cylinder.bottom_radius = 0.65
	cylinder.height = 1.2
	cylinder.radial_segments = 12
	marker.mesh = cylinder
	marker.material_override = _material(WHITE if index % 2 == 0 else BLACK)
	marker.position = position_3d + Vector3.UP * 0.6
	add_child(marker)


func _add_outline_rect(center: Vector3, size: Vector2) -> void:
	_add_visual_box("BrakeBox", Vector3(size.x, 0.025, 0.15), center + Vector3(0.0, 0.0, -size.y * 0.5), WHITE)
	_add_visual_box("BrakeBox", Vector3(size.x, 0.025, 0.15), center + Vector3(0.0, 0.0, size.y * 0.5), WHITE)
	_add_visual_box("BrakeBox", Vector3(0.15, 0.025, size.y), center + Vector3(-size.x * 0.5, 0.0, 0.0), WHITE)
	_add_visual_box("BrakeBox", Vector3(0.15, 0.025, size.y), center + Vector3(size.x * 0.5, 0.0, 0.0), WHITE)


func _add_turning_circle(center: Vector3, radius: float) -> void:
	var segments := 48
	for index in segments:
		if index % 2 == 0:
			continue
		var angle := TAU * float(index) / float(segments)
		var position_3d := center + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		var tangent_rotation := Vector3(0.0, -angle, 0.0)
		_add_visual_box("TurningCircle", Vector3(0.16, 0.025, 1.7), position_3d, WHITE, tangent_rotation)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(24.0, 24.0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.045, 0.05, 0.82)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	style.content_margin_left = 16.0
	style.content_margin_right = 16.0
	style.content_margin_top = 11.0
	style.content_margin_bottom = 11.0
	panel.add_theme_stylebox_override("panel", style)
	layer.add_child(panel)
	var label := Label.new()
	telemetry_label = label
	label.text = "HANDLING TEST FIELD\n0 km/h  •  steering 0°\nWASD / arrows to drive  •  R to reset"
	label.add_theme_font_size_override("font_size", 17)
	label.add_theme_color_override("font_color", WHITE)
	panel.add_child(label)


func _add_static_box(node_name: String, size: Vector3, position_3d: Vector3, color: Color, collision: bool) -> void:
	var body := StaticBody3D.new()
	body.name = node_name
	body.position = position_3d
	add_child(body)
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.material_override = _material(color)
	body.add_child(mesh)
	if collision:
		var collision_shape := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		collision_shape.shape = shape
		body.add_child(collision_shape)


func _add_visual_box(node_name: String, size: Vector3, position_3d: Vector3, color: Color, rotation_3d := Vector3.ZERO) -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = node_name
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.material_override = _material(color)
	mesh.position = position_3d
	mesh.rotation = rotation_3d
	add_child(mesh)


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.92
	return material
