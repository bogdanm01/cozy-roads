class_name CozyFollowCamera
extends Camera3D

@export var target: Node3D

var follow_distance := 7.35
var follow_height := 3.45
var look_height := 1.20
var orbit_yaw := 0.0
var orbit_pitch := 0.0
var target_orbit_yaw := 0.0
var target_orbit_pitch := 0.0
var orbiting := false

const MOUSE_SENSITIVITY := 0.0038
const MIN_ORBIT_PITCH := deg_to_rad(-16.0)
const MAX_ORBIT_PITCH := deg_to_rad(48.0)
const RECENTER_SPEED := 2.8
const ORBIT_SMOOTH_SPEED := 9.0


func _ready() -> void:
	position = Vector3(0.0, follow_height, follow_distance)
	fov = 68.0
	far = 520.0


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		orbiting = event.pressed
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if orbiting else Input.MOUSE_MODE_VISIBLE
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and orbiting:
		# Horizontal orbit follows view-drag convention; vertical keeps the more
		# natural camera-height direction selected during handling tests.
		target_orbit_yaw -= event.relative.x * MOUSE_SENSITIVITY
		target_orbit_pitch = clampf(
			target_orbit_pitch + event.relative.y * MOUSE_SENSITIVITY,
			MIN_ORBIT_PITCH,
			MAX_ORBIT_PITCH
		)
		get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT and orbiting:
		orbiting = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _physics_process(delta: float) -> void:
	if not is_instance_valid(target):
		return
	if not orbiting:
		var recenter_weight := 1.0 - exp(-RECENTER_SPEED * delta)
		target_orbit_yaw = lerp_angle(target_orbit_yaw, 0.0, recenter_weight)
		target_orbit_pitch = lerpf(target_orbit_pitch, 0.0, recenter_weight)
	var orbit_weight := 1.0 - exp(-ORBIT_SMOOTH_SPEED * delta)
	orbit_yaw = lerp_angle(orbit_yaw, target_orbit_yaw, orbit_weight)
	orbit_pitch = lerpf(orbit_pitch, target_orbit_pitch, orbit_weight)
	var target_basis := target.global_transform.basis
	var orbit_center := target.global_position + Vector3.UP * look_height
	var relative_height := follow_height - look_height
	var orbit_radius := sqrt(follow_distance * follow_distance + relative_height * relative_height)
	var base_pitch := atan2(relative_height, follow_distance)
	var camera_pitch := base_pitch + orbit_pitch
	var horizontal_distance := cos(camera_pitch) * orbit_radius
	var vertical_distance := sin(camera_pitch) * orbit_radius
	var orbit_direction := target_basis.z.rotated(Vector3.UP, orbit_yaw)
	var desired_position := orbit_center + orbit_direction * horizontal_distance + Vector3.UP * vertical_distance
	global_position = global_position.lerp(desired_position, 1.0 - exp(-10.0 * delta))
	look_at(orbit_center, Vector3.UP)
