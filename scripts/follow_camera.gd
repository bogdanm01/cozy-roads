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
var current_look_ahead := 0.0

const MOUSE_SENSITIVITY := 0.0038
const MIN_ORBIT_PITCH := deg_to_rad(-16.0)
const MAX_ORBIT_PITCH := deg_to_rad(48.0)
const RECENTER_SPEED := 2.8
const ORBIT_SMOOTH_SPEED := 9.0
const CAMERA_COLLISION_MARGIN := 0.28


func _ready() -> void:
	position = Vector3(0.0, follow_height, follow_distance)
	fov = 66.0
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
	var speed_ratio := 0.0
	if target is CozyCar:
		speed_ratio = clampf(absf((target as CozyCar).speed) / CozyCar.MAX_FORWARD_SPEED, 0.0, 1.0)
	var target_fov := lerpf(66.0, 70.0, smoothstep(0.18, 1.0, speed_ratio))
	fov = lerpf(fov, target_fov, 1.0 - exp(-3.8 * delta))
	var target_basis := target.global_transform.basis
	var target_look_ahead := 0.0 if orbiting else lerpf(0.12, 0.72, speed_ratio)
	current_look_ahead = lerpf(
		current_look_ahead,
		target_look_ahead,
		1.0 - exp(-4.0 * delta)
	)
	var orbit_center := (
		target.global_position
		+ Vector3.UP * look_height
		- target_basis.z * current_look_ahead
	)
	var relative_height := follow_height - look_height
	var active_follow_distance := follow_distance + lerpf(0.0, 0.45, speed_ratio)
	var orbit_radius := sqrt(active_follow_distance * active_follow_distance + relative_height * relative_height)
	var base_pitch := atan2(relative_height, active_follow_distance)
	var camera_pitch := base_pitch + orbit_pitch
	var horizontal_distance := cos(camera_pitch) * orbit_radius
	var vertical_distance := sin(camera_pitch) * orbit_radius
	var orbit_direction := target_basis.z.rotated(Vector3.UP, orbit_yaw)
	var desired_position := orbit_center + orbit_direction * horizontal_distance + Vector3.UP * vertical_distance
	desired_position = _collision_safe_position(orbit_center, desired_position)
	var smoothed_position := global_position.lerp(
		desired_position,
		1.0 - exp(-10.0 * delta)
	)
	global_position = _collision_safe_position(orbit_center, smoothed_position)
	look_at(orbit_center, Vector3.UP)


func _collision_safe_position(center: Vector3, candidate: Vector3) -> Vector3:
	if not target is CollisionObject3D:
		return candidate
	var query := PhysicsRayQueryParameters3D.create(
		center,
		candidate,
		1,
		[(target as CollisionObject3D).get_rid()]
	)
	query.collide_with_areas = false
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return candidate
	var ray_direction := (candidate - center).normalized()
	return (hit["position"] as Vector3) - ray_direction * CAMERA_COLLISION_MARGIN
