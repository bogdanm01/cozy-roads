class_name CozyFollowCamera
extends Camera3D

@export var target: Node3D

var follow_distance := 5.2
var follow_height := 2.8
var look_ahead := 2.4
var look_height := 0.85


func _ready() -> void:
	position = Vector3(0.0, follow_height, follow_distance)
	fov = 72.0


func _physics_process(delta: float) -> void:
	if not is_instance_valid(target):
		return
	var target_basis := target.global_transform.basis
	var desired_position := target.global_position + target_basis.z * follow_distance + Vector3.UP * follow_height
	global_position = global_position.lerp(desired_position, 1.0 - exp(-10.0 * delta))
	var look_target := target.global_position - target_basis.z * look_ahead + Vector3.UP * look_height
	look_at(look_target, Vector3.UP)
