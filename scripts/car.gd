class_name CozyCar
extends CharacterBody3D

const MeshFactory := preload("res://scripts/low_poly_mesh.gd")

# A calm, weighty old pickup: roughly 0-80 km/h in ten seconds and a modest
# top speed. Values are deliberately exposed as named constants for tuning.
const MAX_FORWARD_SPEED := 23.0
const MAX_REVERSE_SPEED := 6.0
const ENGINE_ACCELERATION := 3.1
const REVERSE_ACCELERATION := 2.0
const BRAKE_POWER := 9.2
const ROLLING_DRAG := 0.55
const AERO_DRAG := 0.0028
const GRAVITY := 24.0
const ROAD_GRAVITY := 9.81
const GRADE_EFFECT := 0.46

const WHEELBASE := 3.15
const LOW_SPEED_STEERING_ANGLE := deg_to_rad(31.0)
const HIGH_SPEED_STEERING_ANGLE := deg_to_rad(13.0)
const LOW_SPEED_STEERING_RATE := 3.65
const HIGH_SPEED_STEERING_RATE := 2.30
const STEERING_RETURN_RATE := 4.1
const MAX_YAW_RATE := 1.0

var speed := 0.0
var throttle_input := 0.0
var steering_input := 0.0
var steering_angle := 0.0
var spawn_transform := Transform3D.IDENTITY
var visual_root: Node3D
var body_root: Node3D
var wheel_pivots: Array[Node3D] = []
var wheel_meshes: Array[MeshInstance3D] = []

var previous_speed := 0.0
var smoothed_acceleration := 0.0
var body_pitch := 0.0
var body_pitch_velocity := 0.0
var body_roll := 0.0
var body_roll_velocity := 0.0
var body_heave := 0.0
var body_heave_velocity := 0.0
var wheel_rest_positions: Array[Vector3] = []
var wheel_suspension_offsets: Array[float] = []
var wheel_suspension_velocities: Array[float] = []
var brake_light_material: StandardMaterial3D
var brake_lights: Array[OmniLight3D] = []
var brake_light_level := 0.0
var contact_shadow: MeshInstance3D
var engine_audio: AudioStreamPlayer3D
var engine_playback: AudioStreamGeneratorPlayback
var engine_phase := 0.0


func _ready() -> void:
	spawn_transform = global_transform
	floor_snap_length = 0.5
	floor_max_angle = deg_to_rad(46.0)
	_build_pickup()
	_build_engine_audio()


func _exit_tree() -> void:
	if is_instance_valid(engine_audio):
		engine_audio.stop()
	engine_playback = null


func _physics_process(delta: float) -> void:
	var raw_throttle := _get_throttle()
	_update_throttle_input(raw_throttle, delta)
	var forward := -global_transform.basis.z
	_update_speed(throttle_input, forward, delta)
	_update_steering(delta)

	var yaw_rate := 0.0
	if absf(speed) > 0.05:
		yaw_rate = speed * tan(steering_angle) / WHEELBASE
		yaw_rate = clampf(yaw_rate, -MAX_YAW_RATE, MAX_YAW_RATE)
		rotate_y(-yaw_rate * delta)

	forward = -global_transform.basis.z
	var target_planar_velocity := forward * speed
	var current_planar_velocity := Vector3(velocity.x, 0.0, velocity.z)
	var speed_ratio := clampf(absf(speed) / MAX_FORWARD_SPEED, 0.0, 1.0)
	# Strong parking-speed grip makes the truck predictable; a little compliance
	# at road speed prevents the chassis from snapping instantly to a new heading.
	var tire_grip := lerpf(8.5, 6.2, smoothstep(0.12, 1.0, speed_ratio))
	var planar_velocity := current_planar_velocity.lerp(target_planar_velocity, 1.0 - exp(-tire_grip * delta))
	velocity.x = planar_velocity.x
	velocity.z = planar_velocity.z
	if is_on_floor():
		velocity.y = -0.8
	else:
		velocity.y -= GRAVITY * delta

	move_and_slide()
	_resolve_obstacle_collisions(forward)
	_update_contact_shadow()
	_update_brake_lights(raw_throttle, delta)
	_update_engine_audio()
	_animate_pickup(delta, speed_ratio, yaw_rate)

	if Input.is_physical_key_pressed(KEY_R) or global_position.y < -12.0:
		reset_car()
func _resolve_obstacle_collisions(forward: Vector3) -> void:
	var hit_obstacle := false
	for index in get_slide_collision_count():
		var collision := get_slide_collision(index)
		# Floor contacts should not alter the stored driving speed. Normals with a
		# substantial horizontal component represent walls and other obstacles.
		if absf(collision.get_normal().y) < 0.65:
			hit_obstacle = true
			break
	if not hit_obstacle:
		return

	# move_and_slide() has already removed velocity going into the obstacle.
	# Synchronize the drivetrain with what physically remains so steering cannot
	# redirect pre-impact speed around a wall on the following frame.
	var remaining_planar_velocity := Vector3(velocity.x, 0.0, velocity.z)
	var remaining_forward_speed := remaining_planar_velocity.dot(forward)
	if signf(remaining_forward_speed) != signf(speed):
		remaining_forward_speed = 0.0
	speed = clampf(remaining_forward_speed, -MAX_REVERSE_SPEED, MAX_FORWARD_SPEED)
	if absf(speed) < 0.18:
		speed = 0.0


func _update_throttle_input(requested_throttle: float, delta: float) -> void:
	var braking := (
		(requested_throttle < -0.05 and speed > 0.15)
		or (requested_throttle > 0.05 and speed < -0.15)
	)
	var response_rate := 14.0 if braking else (4.2 if absf(requested_throttle) > absf(throttle_input) else 7.0)
	throttle_input = move_toward(throttle_input, requested_throttle, response_rate * delta)


func _update_speed(throttle: float, forward: Vector3, delta: float) -> void:
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

	# Gravity projected onto the current floor adds modest grade load. Climbs now
	# consume momentum and descents coast naturally without overpowering braking.
	if is_on_floor():
		var slope_gravity := (Vector3.DOWN * ROAD_GRAVITY).slide(get_floor_normal())
		var grade_acceleration := slope_gravity.dot(forward) * GRADE_EFFECT
		speed += grade_acceleration * delta
	speed = clampf(speed, -MAX_REVERSE_SPEED, MAX_FORWARD_SPEED)


func _update_steering(delta: float) -> void:
	var requested_steering := _get_steering()
	var speed_ratio := clampf(absf(speed) / MAX_FORWARD_SPEED, 0.0, 1.0)
	var response := lerpf(LOW_SPEED_STEERING_RATE, HIGH_SPEED_STEERING_RATE, speed_ratio) if absf(requested_steering) > 0.01 else STEERING_RETURN_RATE
	steering_input = move_toward(steering_input, requested_steering, response * delta)
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
	throttle_input = 0.0
	steering_input = 0.0
	steering_angle = 0.0
	previous_speed = 0.0
	smoothed_acceleration = 0.0
	body_pitch = 0.0
	body_pitch_velocity = 0.0
	body_roll = 0.0
	body_roll_velocity = 0.0
	body_heave = 0.0
	body_heave_velocity = 0.0
	brake_light_level = 0.0
	for index in wheel_suspension_offsets.size():
		wheel_suspension_offsets[index] = 0.0
		wheel_suspension_velocities[index] = 0.0
		wheel_pivots[index].position = wheel_rest_positions[index]


func _build_pickup() -> void:
	# Rounded axle contacts let the kinematic truck roll over ramp lips instead of
	# presenting a square, floor-level chassis edge. The rigid body colliders begin
	# at the visible underside, preserving useful ground and bumper clearance.
	_add_axle_contact_collider("FrontAxleContact", Vector3(0.0, 0.61, -1.72))
	_add_axle_contact_collider("RearAxleContact", Vector3(0.0, 0.61, 1.72))
	_add_box_collider("ChassisCollider", Vector3(2.18, 0.96, 3.55), Vector3(0.0, 0.95, 0.0))
	_add_box_collider("FrontOverhangCollider", Vector3(2.20, 0.82, 1.32), Vector3(0.0, 0.83, -2.40))
	_add_box_collider("RearOverhangCollider", Vector3(2.20, 0.82, 1.32), Vector3(0.0, 0.83, 2.40))
	_add_box_collider("CabCollider", Vector3(2.08, 0.90, 1.68), Vector3(0.0, 1.78, -0.30))

	visual_root = Node3D.new()
	visual_root.name = "PickupVisual"
	visual_root.scale.x = 1.09
	add_child(visual_root)
	_build_contact_shadow()
	body_root = Node3D.new()
	body_root.name = "SuspendedBody"
	visual_root.add_child(body_root)

	var paint := _material(Color("a95034"))
	var paint_light := _material(Color("bd7655"))
	var paint_dark := _material(Color("6f2d21"))
	var charcoal := _material(Color("17191b"))
	var bumper := _material(Color("555c65"))
	var chrome := _material(Color("aab0b4"), 0.55)
	var glass := _glass_material(Color(0.18, 0.27, 0.29, 0.78))
	var lamp := _material(Color("eee9d9"), 0.35)
	var headlight_material := _emissive_material(Color("f3ebd2"), Color("ffd7a0"), 1.8, 0.28)
	var amber := _material(Color("e98b20"), 0.4)
	brake_light_material = _emissive_material(Color("c84438"), Color("e53528"), 0.65, 0.4)
	var seat := _material(Color("4a352e"))

	# Main body, hood and squared-off cab.
	_add_box(visual_root, "LowerBody", Vector3(2.02, 0.72, 5.45), Vector3(0.0, 0.82, 0.0), paint_light)
	_add_box(visual_root, "Rocker", Vector3(2.08, 0.22, 5.1), Vector3(0.0, 0.49, 0.0), paint_dark)
	_add_box(visual_root, "Hood", Vector3(1.92, 0.22, 1.72), Vector3(0.0, 1.27, -1.78), paint)
	_add_box(visual_root, "CabLower", Vector3(1.96, 0.72, 1.58), Vector3(0.0, 1.36, -0.30), paint)
	_add_box(visual_root, "Roof", Vector3(2.02, 0.18, 1.66), Vector3(0.0, 2.23, -0.28), paint)

	# Cab glazing, pillars and a visible simple interior.
	_add_box(visual_root, "WindshieldFrame", Vector3(1.84, 0.78, 0.12), Vector3(0.0, 1.82, -1.08), charcoal, Vector3(deg_to_rad(-10.0), 0.0, 0.0))
	# Surface details get a small, deliberate air gap from their backing panel.
	# Intersecting thin beveled boxes can alternate in the depth buffer as the
	# chase camera moves, which reads as flickering paint or glass.
	_add_box(visual_root, "Windshield", Vector3(1.65, 0.64, 0.045), Vector3(0.0, 1.803, -1.174), glass, Vector3(deg_to_rad(-10.0), 0.0, 0.0))
	_add_box(visual_root, "RearWindowFrame", Vector3(1.84, 0.76, 0.10), Vector3(0.0, 1.82, 0.53), charcoal)
	_add_box(visual_root, "RearWindow", Vector3(1.62, 0.60, 0.04), Vector3(0.0, 1.82, 0.61), glass)
	for side in [-1.0, 1.0]:
		_add_box(visual_root, "SideWindow", Vector3(0.055, 0.62, 1.15), Vector3(side * 1.015, 1.83, -0.28), glass)
		_add_box(visual_root, "FrontPillar", Vector3(0.13, 0.84, 0.13), Vector3(side * 0.94, 1.84, -1.02), paint, Vector3(deg_to_rad(-10.0), 0.0, 0.0))
		_add_box(visual_root, "RearPillar", Vector3(0.13, 0.84, 0.13), Vector3(side * 0.94, 1.84, 0.47), paint)
		_add_box(visual_root, "Door", Vector3(0.035, 0.88, 1.24), Vector3(side * 1.04, 1.12, -0.30), paint_light)
		_add_box(visual_root, "BeltStripe", Vector3(0.035, 0.22, 2.30), Vector3(side * 1.085, 1.48, -0.75), paint_dark)
		_add_box(visual_root, "DoorHandle", Vector3(0.05, 0.07, 0.30), Vector3(side * 1.135, 1.45, 0.06), charcoal)
		_add_box(visual_root, "MirrorArm", Vector3(0.20, 0.08, 0.08), Vector3(side * 1.10, 1.68, -0.90), charcoal)
		_add_box(visual_root, "Mirror", Vector3(0.18, 0.28, 0.35), Vector3(side * 1.24, 1.72, -0.90), charcoal)
	_add_box(visual_root, "BenchSeat", Vector3(1.50, 0.46, 0.62), Vector3(0.0, 1.40, -0.12), seat)
	_add_box(visual_root, "SeatBack", Vector3(1.50, 0.72, 0.24), Vector3(0.0, 1.68, 0.16), seat)
	_add_box(visual_root, "Dashboard", Vector3(1.58, 0.22, 0.42), Vector3(0.0, 1.48, -0.76), charcoal)

	# Open pickup bed with dark interior and chunky rails.
	_add_box(visual_root, "BedFloor", Vector3(1.72, 0.10, 2.36), Vector3(0.0, 1.06, 1.53), charcoal)
	for side in [-1.0, 1.0]:
		# The bed walls sit proud of the lower body. Keeping their outer faces on
		# the old 1.01 m body plane produced visible material z-fighting.
		_add_box(visual_root, "BedSide", Vector3(0.18, 0.72, 2.48), Vector3(side * 0.945, 1.39, 1.52), paint)
		_add_box(visual_root, "BedStripe", Vector3(0.035, 0.20, 2.48), Vector3(side * 1.075, 1.50, 1.52), paint_dark)
	_add_box(visual_root, "Tailgate", Vector3(1.84, 0.72, 0.17), Vector3(0.0, 1.39, 2.72), paint_light)
	_add_box(visual_root, "TailgateInset", Vector3(1.52, 0.38, 0.035), Vector3(0.0, 1.39, 2.84), paint)

	# Front and rear trim.
	_add_box(visual_root, "FrontGrille", Vector3(1.38, 0.58, 0.12), Vector3(0.0, 0.92, -2.78), charcoal)
	for grille_x in [-0.45, -0.15, 0.15, 0.45]:
		_add_box(visual_root, "GrilleSlat", Vector3(0.055, 0.46, 0.025), Vector3(grille_x, 0.92, -2.86), bumper)
	_add_box(visual_root, "FrontBumper", Vector3(2.16, 0.28, 0.28), Vector3(0.0, 0.55, -2.91), bumper)
	_add_box(visual_root, "RearBumper", Vector3(2.12, 0.30, 0.28), Vector3(0.0, 0.55, 2.91), bumper)
	for side in [-1.0, 1.0]:
		_add_box(visual_root, "Headlight", Vector3(0.43, 0.38, 0.08), Vector3(side * 0.74, 0.98, -2.86), headlight_material)
		_add_box(visual_root, "Indicator", Vector3(0.36, 0.16, 0.08), Vector3(side * 0.75, 0.69, -2.86), amber)
		_add_box(visual_root, "TailLightRed", Vector3(0.22, 0.24, 0.05), Vector3(side * 0.83, 1.55, 2.86), brake_light_material)
		_add_box(visual_root, "TailLightAmber", Vector3(0.22, 0.16, 0.05), Vector3(side * 0.83, 1.34, 2.86), amber)
		_add_box(visual_root, "TailLightWhite", Vector3(0.22, 0.13, 0.05), Vector3(side * 0.83, 1.18, 2.86), lamp)

		var brake_glow := OmniLight3D.new()
		brake_glow.name = "BrakeGlowLeft" if side < 0.0 else "BrakeGlowRight"
		brake_glow.light_color = Color("ef3b2f")
		brake_glow.light_energy = 0.08
		brake_glow.omni_range = 2.4
		brake_glow.omni_attenuation = 1.7
		brake_glow.shadow_enabled = false
		brake_glow.position = Vector3(side * 0.83, 1.55, 2.94)
		body_root.add_child(brake_glow)
		brake_lights.append(brake_glow)

		var headlight_beam := SpotLight3D.new()
		headlight_beam.name = "HeadlightBeamLeft" if side < 0.0 else "HeadlightBeamRight"
		headlight_beam.light_color = Color("ffd8a6")
		headlight_beam.light_energy = 3.8
		headlight_beam.spot_range = 24.0
		headlight_beam.spot_angle = 31.0
		headlight_beam.spot_angle_attenuation = 0.72
		headlight_beam.shadow_enabled = false
		headlight_beam.position = Vector3(side * 0.74, 0.98, -2.94)
		headlight_beam.rotation.x = deg_to_rad(-4.0)
		body_root.add_child(headlight_beam)

	_build_wheels(charcoal, chrome)


func _add_box_collider(node_name: String, size: Vector3, local_position: Vector3) -> void:
	var collider := CollisionShape3D.new()
	collider.name = node_name
	var shape := BoxShape3D.new()
	shape.size = size
	collider.shape = shape
	collider.position = local_position
	add_child(collider)


func _add_axle_contact_collider(node_name: String, local_position: Vector3) -> void:
	var collider := CollisionShape3D.new()
	collider.name = node_name
	var shape := SphereShape3D.new()
	shape.radius = 0.54
	collider.shape = shape
	collider.position = local_position
	add_child(collider)


func _build_contact_shadow() -> void:
	contact_shadow = MeshInstance3D.new()
	contact_shadow.name = "SoftContactShadow"
	contact_shadow.mesh = MeshFactory.soft_disc(36)
	contact_shadow.top_level = true
	contact_shadow.visible = false
	contact_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("080b10")
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	contact_shadow.material_override = material
	add_child(contact_shadow)


func _update_contact_shadow() -> void:
	if not is_instance_valid(contact_shadow):
		return
	var query := PhysicsRayQueryParameters3D.create(
		global_position + Vector3.UP * 1.2,
		global_position - Vector3.UP * 2.2,
		3,
		[get_rid()]
	)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		contact_shadow.visible = false
		return
	var ground_normal: Vector3 = hit["normal"]
	var ground_forward := (-global_transform.basis.z).slide(ground_normal).normalized()
	if ground_forward.length_squared() < 0.001:
		ground_forward = Vector3.FORWARD
	var ground_right := ground_forward.cross(ground_normal).normalized()
	var shadow_basis := Basis(ground_right, ground_normal, -ground_forward).orthonormalized()
	contact_shadow.global_transform = Transform3D(shadow_basis, hit["position"] + ground_normal * 0.018)
	contact_shadow.scale = Vector3(1.08, 1.0, 2.42)
	contact_shadow.visible = true


func _update_brake_lights(throttle: float, delta: float) -> void:
	var braking_forward := throttle < -0.05 and speed > 0.12
	var braking_reverse := throttle > 0.05 and speed < -0.12
	var target_level := 1.0 if braking_forward or braking_reverse else 0.0
	var response_speed := 18.0 if target_level > brake_light_level else 6.5
	brake_light_level = move_toward(brake_light_level, target_level, response_speed * delta)

	if is_instance_valid(brake_light_material):
		brake_light_material.emission_energy_multiplier = lerpf(0.65, 4.0, brake_light_level)
	for light in brake_lights:
		light.light_energy = lerpf(0.08, 1.85, brake_light_level)


func _build_engine_audio() -> void:
	engine_audio = AudioStreamPlayer3D.new()
	engine_audio.name = "ProceduralEngineAudio"
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = 22050.0
	generator.buffer_length = 0.24
	engine_audio.stream = generator
	engine_audio.volume_db = -7.5
	engine_audio.unit_size = 5.0
	engine_audio.max_distance = 45.0
	add_child(engine_audio)
	engine_audio.play()
	engine_playback = engine_audio.get_stream_playback() as AudioStreamGeneratorPlayback


func _update_engine_audio() -> void:
	if not is_instance_valid(engine_playback):
		return
	var speed_ratio := clampf(absf(speed) / MAX_FORWARD_SPEED, 0.0, 1.0)
	var load := absf(throttle_input)
	var frequency := lerpf(47.0, 118.0, pow(speed_ratio, 0.72)) + load * 10.0
	var amplitude := lerpf(0.030, 0.072, speed_ratio) + load * 0.014
	var frames_available := engine_playback.get_frames_available()
	for frame in frames_available:
		engine_phase = fmod(engine_phase + TAU * frequency / 22050.0, TAU)
		var sample := sin(engine_phase) * amplitude
		sample += sin(engine_phase * 2.01) * amplitude * 0.31
		sample += sin(engine_phase * 3.03) * amplitude * 0.12
		engine_playback.push_frame(Vector2(sample, sample))


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
		wheel_rest_positions.append(wheel_data[0])
		wheel_suspension_offsets.append(0.0)
		wheel_suspension_velocities.append(0.0)

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


func _animate_pickup(delta: float, speed_ratio: float, yaw_rate: float) -> void:
	var spin := speed * delta / 0.54
	for index in wheel_meshes.size():
		wheel_meshes[index].rotate_object_local(Vector3.UP, spin)
		if index < 2:
			wheel_pivots[index].rotation.y = -steering_angle

	var raw_acceleration := (speed - previous_speed) / maxf(delta, 0.001)
	previous_speed = speed
	smoothed_acceleration = lerpf(smoothed_acceleration, raw_acceleration, 1.0 - exp(-9.0 * delta))
	var lateral_acceleration := yaw_rate * speed
	var terrain_attitude := _sample_wheel_suspension(delta)
	# Acceleration and cornering movement stays quiet at walking pace. Terrain
	# alignment is handled separately so a slowly climbing truck still matches
	# the road angle instead of remaining unnaturally horizontal.
	var motion_scale := lerpf(0.22, 1.0, smoothstep(0.0, 17.0, absf(speed)))

	# Positive pitch raises the nose; negative pitch produces brake dive.
	var target_pitch := clampf(smoothed_acceleration / 8.0, -1.0, 1.0) * deg_to_rad(4.2) * motion_scale
	target_pitch += terrain_attitude.x
	# Roll follows lateral acceleration, leaning away from the inside of a turn.
	var target_roll := clampf(lateral_acceleration / 10.0, -1.0, 1.0) * deg_to_rad(4.5) * motion_scale
	target_roll += terrain_attitude.z
	var target_heave := -clampf(absf(smoothed_acceleration) / 10.0, 0.0, 1.0) * 0.045 * motion_scale
	target_heave -= clampf(absf(lateral_acceleration) / 14.0, 0.0, 1.0) * 0.025 * motion_scale
	target_heave += terrain_attitude.y * motion_scale

	# Lightly underdamped springs create one small, natural settling bounce.
	body_pitch_velocity += ((target_pitch - body_pitch) * 50.0 - body_pitch_velocity * 9.5) * delta
	body_pitch += body_pitch_velocity * delta
	body_roll_velocity += ((target_roll - body_roll) * 42.0 - body_roll_velocity * 8.6) * delta
	body_roll += body_roll_velocity * delta
	body_heave_velocity += ((target_heave - body_heave) * 58.0 - body_heave_velocity * 10.0) * delta
	body_heave += body_heave_velocity * delta

	body_root.rotation.x = body_pitch
	body_root.rotation.z = body_roll
	body_root.position.y = body_heave


func _sample_wheel_suspension(delta: float) -> Vector3:
	if wheel_pivots.size() != 4:
		return Vector3.ZERO
	var space_state := get_world_3d().direct_space_state
	var ground_heights: Array[float] = [0.0, 0.0, 0.0, 0.0]
	for index in wheel_pivots.size():
		var wheel_world_position := visual_root.to_global(wheel_rest_positions[index])
		var query := PhysicsRayQueryParameters3D.create(
			wheel_world_position + Vector3.UP * 0.85,
			wheel_world_position - Vector3.UP * 1.25,
			3,
			[get_rid()]
		)
		var hit := space_state.intersect_ray(query)
		var target_offset := 0.0
		if not hit.is_empty():
			var ground_height: float = hit.position.y - global_position.y
			ground_heights[index] = ground_height
			target_offset = clampf(ground_height, -0.16, 0.24)
		wheel_suspension_velocities[index] += (
			(target_offset - wheel_suspension_offsets[index]) * 82.0
			- wheel_suspension_velocities[index] * 13.5
		) * delta
		wheel_suspension_offsets[index] += wheel_suspension_velocities[index] * delta
		wheel_pivots[index].position = wheel_rest_positions[index] + Vector3.UP * wheel_suspension_offsets[index]

	# Use unclamped ground samples for body attitude. Suspension travel remains
	# limited above, but a 10-degree ramp must still produce a 10-degree body tilt.
	var front_height := (ground_heights[0] + ground_heights[1]) * 0.5
	var rear_height := (ground_heights[2] + ground_heights[3]) * 0.5
	var left_height := (ground_heights[0] + ground_heights[2]) * 0.5
	var right_height := (ground_heights[1] + ground_heights[3]) * 0.5
	var average_height := (
		wheel_suspension_offsets[0] + wheel_suspension_offsets[1]
		+ wheel_suspension_offsets[2] + wheel_suspension_offsets[3]
	) * 0.25
	var track_width := absf(wheel_rest_positions[1].x - wheel_rest_positions[0].x) * visual_root.scale.x
	var terrain_pitch := clampf(atan2(front_height - rear_height, WHEELBASE), deg_to_rad(-14.0), deg_to_rad(14.0))
	var terrain_roll := clampf(atan2(right_height - left_height, track_width), deg_to_rad(-10.0), deg_to_rad(10.0))
	# x = pitch, y = heave, z = roll.
	return Vector3(terrain_pitch, average_height * 0.72, terrain_roll)


func _add_box(parent: Node3D, node_name: String, size: Vector3, local_position: Vector3, material: Material, local_rotation := Vector3.ZERO) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = node_name
	var minimum_dimension := minf(size.x, minf(size.y, size.z))
	var bevel := minf(0.055, minimum_dimension * 0.18)
	mesh_instance.mesh = MeshFactory.beveled_box(size, bevel)
	mesh_instance.material_override = material
	mesh_instance.position = local_position
	mesh_instance.rotation = local_rotation
	var actual_parent := parent
	if parent == visual_root and is_instance_valid(body_root):
		actual_parent = body_root
	actual_parent.add_child(mesh_instance)
	return mesh_instance


func _material(color: Color, roughness := 0.88) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material


func _emissive_material(color: Color, emission_color: Color, emission_energy: float, roughness := 0.88) -> StandardMaterial3D:
	var material := _material(color, roughness)
	material.emission_enabled = true
	material.emission = emission_color
	material.emission_energy_multiplier = emission_energy
	return material


func _glass_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.22
	material.metallic = 0.08
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material
