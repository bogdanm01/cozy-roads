class_name CozyCar
extends CharacterBody3D

# A calm, weighty old pickup: roughly 0-80 km/h in ten seconds and a modest
# top speed. Values are deliberately exposed as named constants for tuning.
const MAX_FORWARD_SPEED := 23.0
const MAX_REVERSE_SPEED := 6.0
const ENGINE_ACCELERATION := 3.1
const REVERSE_ACCELERATION := 2.0
const BRAKE_POWER := 8.5
const ROLLING_DRAG := 0.55
const AERO_DRAG := 0.0028
const GRAVITY := 24.0

const WHEELBASE := 3.15
const LOW_SPEED_STEERING_ANGLE := deg_to_rad(28.0)
const HIGH_SPEED_STEERING_ANGLE := deg_to_rad(9.0)
const STEERING_INPUT_RATE := 2.15
const STEERING_RETURN_RATE := 3.0
const MAX_YAW_RATE := 0.9

var speed := 0.0
var steering_input := 0.0
var steering_angle := 0.0
var spawn_transform := Transform3D.IDENTITY
var visual_root: Node3D
var wheel_pivots: Array[Node3D] = []
var wheel_meshes: Array[MeshInstance3D] = []


func _ready() -> void:
	spawn_transform = global_transform
	_build_pickup()


func _physics_process(delta: float) -> void:
	var throttle := _get_throttle()
	_update_speed(throttle, delta)
	_update_steering(delta)

	if absf(speed) > 0.05:
		var yaw_rate := speed * tan(steering_angle) / WHEELBASE
		yaw_rate = clampf(yaw_rate, -MAX_YAW_RATE, MAX_YAW_RATE)
		rotate_y(-yaw_rate * delta)

	var forward := -global_transform.basis.z
	var target_planar_velocity := forward * speed
	var current_planar_velocity := Vector3(velocity.x, 0.0, velocity.z)
	var speed_ratio := clampf(absf(speed) / MAX_FORWARD_SPEED, 0.0, 1.0)
	var tire_grip := lerpf(4.2, 6.5, speed_ratio)
	var planar_velocity := current_planar_velocity.lerp(target_planar_velocity, 1.0 - exp(-tire_grip * delta))
	velocity.x = planar_velocity.x
	velocity.z = planar_velocity.z
	if is_on_floor():
		velocity.y = -0.8
	else:
		velocity.y -= GRAVITY * delta

	move_and_slide()
	if get_slide_collision_count() > 0 and not is_on_floor():
		speed *= 0.72
	_animate_pickup(delta, speed_ratio)

	if Input.is_physical_key_pressed(KEY_R) or global_position.y < -12.0:
		reset_car()


func _update_speed(throttle: float, delta: float) -> void:
	if throttle > 0.0:
		if speed < -0.15:
			speed = move_toward(speed, 0.0, BRAKE_POWER * throttle * delta)
		else:
			var engine_falloff := lerpf(1.0, 0.42, clampf(speed / MAX_FORWARD_SPEED, 0.0, 1.0))
			speed = move_toward(speed, MAX_FORWARD_SPEED, ENGINE_ACCELERATION * engine_falloff * throttle * delta)
	elif throttle < 0.0:
		if speed > 0.15:
			speed = move_toward(speed, 0.0, BRAKE_POWER * -throttle * delta)
		else:
			speed = move_toward(speed, -MAX_REVERSE_SPEED, REVERSE_ACCELERATION * -throttle * delta)
	else:
		var drag := ROLLING_DRAG + AERO_DRAG * speed * speed
		speed = move_toward(speed, 0.0, drag * delta)


func _update_steering(delta: float) -> void:
	var requested_steering := _get_steering()
	var response := STEERING_INPUT_RATE if absf(requested_steering) > 0.01 else STEERING_RETURN_RATE
	steering_input = move_toward(steering_input, requested_steering, response * delta)
	var speed_ratio := clampf(absf(speed) / MAX_FORWARD_SPEED, 0.0, 1.0)
	var available_angle := lerpf(LOW_SPEED_STEERING_ANGLE, HIGH_SPEED_STEERING_ANGLE, smoothstep(0.15, 0.9, speed_ratio))
	steering_angle = steering_input * available_angle


func _get_throttle() -> float:
	var value := 0.0
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
		value += 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
		value -= 1.0
	if Input.get_connected_joypads().size() > 0:
		var controller := Input.get_connected_joypads()[0]
		var accelerate := (Input.get_joy_axis(controller, JOY_AXIS_TRIGGER_RIGHT) + 1.0) * 0.5
		var brake := (Input.get_joy_axis(controller, JOY_AXIS_TRIGGER_LEFT) + 1.0) * 0.5
		if accelerate > 0.1 or brake > 0.1:
			value = accelerate - brake
	return clampf(value, -1.0, 1.0)


func _get_steering() -> float:
	var value := 0.0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		value -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		value += 1.0
	if Input.get_connected_joypads().size() > 0:
		var controller := Input.get_connected_joypads()[0]
		var stick := Input.get_joy_axis(controller, JOY_AXIS_LEFT_X)
		if absf(stick) > 0.12:
			value = stick
	return clampf(value, -1.0, 1.0)


func reset_car() -> void:
	global_transform = spawn_transform
	velocity = Vector3.ZERO
	speed = 0.0
	steering_input = 0.0
	steering_angle = 0.0


func _build_pickup() -> void:
	var collider := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(2.02, 1.55, 5.55)
	collider.shape = shape
	collider.position.y = 0.84
	add_child(collider)

	visual_root = Node3D.new()
	visual_root.name = "PickupVisual"
	add_child(visual_root)

	var paint := _material(Color("a95034"))
	var paint_light := _material(Color("bd7655"))
	var paint_dark := _material(Color("6f2d21"))
	var charcoal := _material(Color("17191b"))
	var bumper := _material(Color("555c65"))
	var chrome := _material(Color("aab0b4"), 0.55)
	var glass := _glass_material(Color(0.18, 0.27, 0.29, 0.78))
	var lamp := _material(Color("eee9d9"), 0.35)
	var amber := _material(Color("e98b20"), 0.4)
	var red := _material(Color("c84438"), 0.4)
	var seat := _material(Color("4a352e"))

	# Main body, hood and squared-off cab.
	_add_box(visual_root, "LowerBody", Vector3(2.02, 0.72, 5.45), Vector3(0.0, 0.82, 0.0), paint_light)
	_add_box(visual_root, "Rocker", Vector3(2.08, 0.22, 5.1), Vector3(0.0, 0.49, 0.0), paint_dark)
	_add_box(visual_root, "Hood", Vector3(1.92, 0.22, 1.72), Vector3(0.0, 1.27, -1.78), paint)
	_add_box(visual_root, "CabLower", Vector3(1.96, 0.72, 1.58), Vector3(0.0, 1.36, -0.30), paint)
	_add_box(visual_root, "Roof", Vector3(2.02, 0.18, 1.66), Vector3(0.0, 2.23, -0.28), paint)

	# Cab glazing, pillars and a visible simple interior.
	_add_box(visual_root, "WindshieldFrame", Vector3(1.84, 0.78, 0.12), Vector3(0.0, 1.82, -1.08), charcoal, Vector3(deg_to_rad(-10.0), 0.0, 0.0))
	_add_box(visual_root, "Windshield", Vector3(1.65, 0.64, 0.055), Vector3(0.0, 1.82, -1.145), glass, Vector3(deg_to_rad(-10.0), 0.0, 0.0))
	_add_box(visual_root, "RearWindowFrame", Vector3(1.84, 0.76, 0.10), Vector3(0.0, 1.82, 0.53), charcoal)
	_add_box(visual_root, "RearWindow", Vector3(1.62, 0.60, 0.05), Vector3(0.0, 1.82, 0.585), glass)
	for side in [-1.0, 1.0]:
		_add_box(visual_root, "SideWindow", Vector3(0.055, 0.62, 1.15), Vector3(side * 1.015, 1.83, -0.28), glass)
		_add_box(visual_root, "FrontPillar", Vector3(0.13, 0.84, 0.13), Vector3(side * 0.94, 1.84, -1.02), paint, Vector3(deg_to_rad(-10.0), 0.0, 0.0))
		_add_box(visual_root, "RearPillar", Vector3(0.13, 0.84, 0.13), Vector3(side * 0.94, 1.84, 0.47), paint)
		_add_box(visual_root, "Door", Vector3(0.055, 0.88, 1.24), Vector3(side * 1.025, 1.12, -0.30), paint_light)
		_add_box(visual_root, "BeltStripe", Vector3(0.065, 0.22, 2.30), Vector3(side * 1.035, 1.48, -0.75), paint_dark)
		_add_box(visual_root, "DoorHandle", Vector3(0.08, 0.07, 0.30), Vector3(side * 1.075, 1.45, 0.06), charcoal)
		_add_box(visual_root, "MirrorArm", Vector3(0.20, 0.08, 0.08), Vector3(side * 1.10, 1.68, -0.90), charcoal)
		_add_box(visual_root, "Mirror", Vector3(0.18, 0.28, 0.35), Vector3(side * 1.24, 1.72, -0.90), charcoal)
	_add_box(visual_root, "BenchSeat", Vector3(1.50, 0.46, 0.62), Vector3(0.0, 1.40, -0.12), seat)
	_add_box(visual_root, "SeatBack", Vector3(1.50, 0.72, 0.24), Vector3(0.0, 1.68, 0.16), seat)
	_add_box(visual_root, "Dashboard", Vector3(1.58, 0.22, 0.42), Vector3(0.0, 1.48, -0.76), charcoal)

	# Open pickup bed with dark interior and chunky rails.
	_add_box(visual_root, "BedFloor", Vector3(1.72, 0.10, 2.36), Vector3(0.0, 1.06, 1.53), charcoal)
	for side in [-1.0, 1.0]:
		_add_box(visual_root, "BedSide", Vector3(0.18, 0.72, 2.48), Vector3(side * 0.92, 1.39, 1.52), paint)
		_add_box(visual_root, "BedStripe", Vector3(0.055, 0.20, 2.48), Vector3(side * 1.02, 1.50, 1.52), paint_dark)
	_add_box(visual_root, "Tailgate", Vector3(1.84, 0.72, 0.17), Vector3(0.0, 1.39, 2.72), paint_light)
	_add_box(visual_root, "TailgateInset", Vector3(1.52, 0.38, 0.055), Vector3(0.0, 1.39, 2.82), paint)

	# Front and rear trim.
	_add_box(visual_root, "FrontGrille", Vector3(1.38, 0.58, 0.12), Vector3(0.0, 0.92, -2.78), charcoal)
	for grille_x in [-0.45, -0.15, 0.15, 0.45]:
		_add_box(visual_root, "GrilleSlat", Vector3(0.055, 0.46, 0.04), Vector3(grille_x, 0.92, -2.855), bumper)
	_add_box(visual_root, "FrontBumper", Vector3(2.16, 0.28, 0.28), Vector3(0.0, 0.55, -2.91), bumper)
	_add_box(visual_root, "RearBumper", Vector3(2.12, 0.30, 0.28), Vector3(0.0, 0.55, 2.91), bumper)
	for side in [-1.0, 1.0]:
		_add_box(visual_root, "Headlight", Vector3(0.43, 0.38, 0.08), Vector3(side * 0.74, 0.98, -2.86), lamp)
		_add_box(visual_root, "Indicator", Vector3(0.36, 0.16, 0.08), Vector3(side * 0.75, 0.69, -2.86), amber)
		_add_box(visual_root, "TailLightRed", Vector3(0.22, 0.24, 0.07), Vector3(side * 0.83, 1.55, 2.84), red)
		_add_box(visual_root, "TailLightAmber", Vector3(0.22, 0.16, 0.07), Vector3(side * 0.83, 1.34, 2.84), amber)
		_add_box(visual_root, "TailLightWhite", Vector3(0.22, 0.13, 0.07), Vector3(side * 0.83, 1.18, 2.84), lamp)

	_build_wheels(charcoal, chrome)


func _build_wheels(tire_material: Material, rim_material: Material) -> void:
	for wheel_data in [
		[Vector3(-1.04, 0.61, -1.72), true], [Vector3(1.04, 0.61, -1.72), true],
		[Vector3(-1.04, 0.61, 1.72), false], [Vector3(1.04, 0.61, 1.72), false]
	]:
		var pivot := Node3D.new()
		pivot.name = "FrontWheelPivot" if wheel_data[1] else "RearWheelPivot"
		pivot.position = wheel_data[0]
		visual_root.add_child(pivot)
		wheel_pivots.append(pivot)

		var wheel := MeshInstance3D.new()
		var tire := CylinderMesh.new()
		tire.top_radius = 0.54
		tire.bottom_radius = 0.54
		tire.height = 0.34
		tire.radial_segments = 14
		wheel.mesh = tire
		wheel.material_override = tire_material
		wheel.rotation.z = PI * 0.5
		pivot.add_child(wheel)
		wheel_meshes.append(wheel)

		var rim := MeshInstance3D.new()
		var rim_mesh := CylinderMesh.new()
		rim_mesh.top_radius = 0.29
		rim_mesh.bottom_radius = 0.29
		rim_mesh.height = 0.355
		rim_mesh.radial_segments = 10
		rim.mesh = rim_mesh
		rim.material_override = rim_material
		rim.rotation.z = PI * 0.5
		pivot.add_child(rim)


func _animate_pickup(delta: float, speed_ratio: float) -> void:
	var spin := speed * delta / 0.54
	for index in wheel_meshes.size():
		wheel_meshes[index].rotate_object_local(Vector3.UP, spin)
		if index < 2:
			wheel_pivots[index].rotation.y = steering_angle
	var target_roll := -steering_input * speed_ratio * 0.045
	visual_root.rotation.z = lerp_angle(visual_root.rotation.z, target_roll, 1.0 - exp(-4.0 * delta))


func _add_box(parent: Node3D, node_name: String, size: Vector3, local_position: Vector3, material: Material, local_rotation := Vector3.ZERO) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = node_name
	var box := BoxMesh.new()
	box.size = size
	mesh_instance.mesh = box
	mesh_instance.material_override = material
	mesh_instance.position = local_position
	mesh_instance.rotation = local_rotation
	parent.add_child(mesh_instance)
	return mesh_instance


func _material(color: Color, roughness := 0.88) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material


func _glass_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.22
	material.metallic = 0.08
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material
