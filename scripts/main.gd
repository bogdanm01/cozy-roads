extends Node3D

const CarScript := preload("res://scripts/car.gd")
const CameraScript := preload("res://scripts/follow_camera.gd")
const MeshFactory := preload("res://scripts/low_poly_mesh.gd")
const EndlessRoadScript := preload("res://scripts/endless_road.gd")
const TrafficManagerScript := preload("res://scripts/traffic_manager.gd")
const SoundscapeScript := preload("res://scripts/cozy_soundscape.gd")
const SAVE_PATH := "user://cozy_roads.cfg"

const WHITE := Color("d8dadb")
const ROAD_WIDTH := 10.625
const ROAD_CURVE_SUBDIVISIONS := 16
const DAY_DURATION_SECONDS := 480.0
const SKY_UPDATE_INTERVAL := 0.25
const START_TIME_HOURS := 20.5
const DINER_POSITION := Vector3(43.0, 0.0, -281.0)
const OVERLOOK_POSITION := Vector3(-26.0, 0.0, -204.0)
const COVERED_BRIDGE_POSITION := Vector3(5.0, 0.0, -254.5)
const CABIN_POSITION := Vector3(-14.0, 0.0, -351.0)

var player_car: CozyCar
var endless_road: CozyEndlessRoad
var traffic_manager: Node3D
var soundscape: CozySoundscape
var speed_value_label: Label
var speed_detail_label: Label
var drive_status_label: Label
var objective_label: Label
var performance_label: Label
var route_progress_bar: ProgressBar
var controls_panel: PanelContainer
var toast_panel: PanelContainer
var toast_label: Label
var scene_environment: Environment
var sky_material: ShaderMaterial
var sun_light: DirectionalLight3D
var moon_light: DirectionalLight3D
var time_of_day_hours := START_TIME_HOURS
var sky_update_accumulator := 0.0
var vehicle_lights_enabled := true
var white_reflector_material: StandardMaterial3D
var amber_reflector_material: StandardMaterial3D
var road_reflector_mesh: ArrayMesh
var white_reflector_transforms: Array[Transform3D] = []
var amber_reflector_transforms: Array[Transform3D] = []
var curved_road_edge_transforms: Array[Transform3D] = []
var curved_road_dash_transforms: Array[Transform3D] = []
var curved_road_dash_index := 0
var scenic_hill_collision_body: StaticBody3D
var scenic_route_controls: Array[Vector3] = []
var scenic_route_points: Array[Vector3] = []
var scenic_route_segment_sources: Array[int] = []
var tree_trunk_material: StandardMaterial3D
var tree_foliage_material: StandardMaterial3D
var tree_foliage_dark_material: StandardMaterial3D
var pine_positions: Array[Vector3] = []
var pine_scales: Array[float] = []
var pine_dark_flags: Array[bool] = []
var guardrail_material: StandardMaterial3D
var utility_wood_material: StandardMaterial3D
var warm_window_material: StandardMaterial3D
var trip_distance := 0.0
var route_total_length := 0.0
var last_car_position := Vector3.ZERO
var diner_reached := false
var route_finished := false
var roadside_stamps := 0
var best_distance := 0.0
var audio_muted := false
var reset_was_pressed := false
var ui_elapsed := 0.0
var toast_timer := 0.0
const TOAST_DURATION := 4.0


func _ready() -> void:
	_load_progress()
	_build_environment()
	_build_drive_world()
	player_car = CozyCar.new()
	player_car.name = "PlayerCar"
	var spawn_index := 2
	var spawn_position := scenic_route_points[spawn_index]
	var spawn_direction := (
		scenic_route_points[spawn_index + 1]
		- scenic_route_points[spawn_index]
	).normalized()
	var flat_spawn_direction := Vector3(spawn_direction.x, 0.0, spawn_direction.z).normalized()
	player_car.transform = Transform3D(
		Basis.looking_at(flat_spawn_direction, Vector3.UP),
		spawn_position
	)
	add_child(player_car)
	last_car_position = player_car.global_position

	endless_road = EndlessRoadScript.new()
	endless_road.name = "EndlessRoad"
	endless_road.target = player_car
	endless_road.start_point = scenic_route_points[-1]
	endless_road.start_direction = (scenic_route_points[-1] - scenic_route_points[-2]).normalized()
	add_child(endless_road)

	traffic_manager = TrafficManagerScript.new()
	traffic_manager.name = "TrafficManager"
	traffic_manager.target = player_car
	traffic_manager.endless_road = endless_road
	traffic_manager.scenic_points = scenic_route_points.duplicate()
	traffic_manager.scenic_total_length = route_total_length
	add_child(traffic_manager)

	soundscape = SoundscapeScript.new()
	soundscape.name = "CozySoundscape"
	soundscape.target = player_car
	soundscape.set_time_of_day(time_of_day_hours)
	add_child(soundscape)

	var camera := CozyFollowCamera.new()
	camera.name = "FollowCamera"
	camera.target = player_car
	add_child(camera)
	camera.current = true
	_build_ui()


func _build_drive_world() -> void:
	scenic_hill_collision_body = StaticBody3D.new()
	scenic_hill_collision_body.name = "ScenicHillTerrainCollision"
	scenic_hill_collision_body.collision_layer = 1
	scenic_hill_collision_body.collision_mask = 0
	add_child(scenic_hill_collision_body)
	_build_scenic_route()
	_finish_curved_road_batches()
	_finish_road_reflectors()


func _process(delta: float) -> void:
	_update_day_night_cycle(delta)
	if is_instance_valid(player_car):
		_update_drive_progress()
		_update_hud(delta)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_O:
		if is_instance_valid(scene_environment):
			scene_environment.ssao_enabled = not scene_environment.ssao_enabled
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_M:
		audio_muted = not audio_muted
		AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), audio_muted)
		_show_toast("AUDIO MUTED" if audio_muted else "AUDIO RESTORED")
		if not audio_muted and is_instance_valid(soundscape):
			soundscape.play_progress_chime(520.0)
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_T:
		set_time_of_day(time_of_day_hours + 1.0)
		get_viewport().set_input_as_handled()


func _update_drive_progress() -> void:
	var movement := player_car.global_position - last_car_position
	var planar_distance := Vector2(movement.x, movement.z).length()
	var reset_pressed := Input.is_physical_key_pressed(KEY_R)
	var reset_started := reset_pressed and not reset_was_pressed
	if reset_started or planar_distance > 18.0:
		best_distance = maxf(best_distance, trip_distance)
		trip_distance = 0.0
		diner_reached = false
		route_finished = false
		if is_instance_valid(endless_road):
			endless_road.reset_stream()
		if is_instance_valid(traffic_manager):
			traffic_manager.reset_traffic()
		_save_progress()
	elif planar_distance < 2.0:
		trip_distance += planar_distance
		best_distance = maxf(best_distance, trip_distance)
	reset_was_pressed = reset_pressed
	last_car_position = player_car.global_position


func _update_hud(delta: float) -> void:
	if not (
		is_instance_valid(speed_value_label)
		and is_instance_valid(objective_label)
		and is_instance_valid(drive_status_label)
		and is_instance_valid(performance_label)
	):
		return
	var speed_kmh := absf(player_car.speed) * 3.6
	var gear := "P"
	if player_car.speed > 0.20:
		gear = "D"
	elif player_car.speed < -0.20:
		gear = "R"
	speed_value_label.text = "%s  %02d" % [gear, roundi(speed_kmh)]
	speed_detail_label.text = "KM/H   •   STEERING %+.0f°" % rad_to_deg(player_car.steering_angle)

	var route_progress := _calculate_route_progress(player_car.global_position)
	var route_percent := roundi(route_progress * 100.0)
	route_progress_bar.value = float(route_percent)
	drive_status_label.text = (
		"%s  %s   •   TRIP %.2f km   •   STAMPS %d"
		% [
			_format_time_of_day(),
			_day_phase_name(),
			trip_distance / 1000.0,
			roadside_stamps,
		]
	)
	if route_finished:
		var endless_distance := (
			endless_road.distance_from_gateway(player_car.global_position)
			if is_instance_valid(endless_road)
			else 0.0
		)
		objective_label.text = "OPEN ROAD   •   %.1f km FROM GATEWAY" % (
			endless_distance / 1000.0
		)
		route_progress_bar.value = 100.0
	elif diner_reached:
		var gateway_distance := player_car.global_position.distance_to(scenic_route_points[-1])
		objective_label.text = "OPEN-ROAD GATEWAY   •   %d m" % roundi(gateway_distance)
	else:
		var diner_distance := player_car.global_position.distance_to(DINER_POSITION)
		objective_label.text = "ROADSIDE DINER   •   %d m" % roundi(diner_distance)

	var ao_mode := (
		"SSAO"
		if is_instance_valid(scene_environment) and scene_environment.ssao_enabled
		else "FAST AO"
	)
	performance_label.text = "%d FPS   •   %s%s" % [
		Engine.get_frames_per_second(),
		ao_mode,
		"   •   MUTED" if audio_muted else "",
	]

	ui_elapsed += delta
	var controls_alpha_target := 1.0 if ui_elapsed < 12.0 else 0.28
	controls_panel.modulate.a = lerpf(
		controls_panel.modulate.a,
		controls_alpha_target,
		1.0 - exp(-2.2 * delta)
	)
	if toast_timer > 0.0:
		toast_timer = maxf(0.0, toast_timer - delta)
		toast_panel.visible = true
		var elapsed := TOAST_DURATION - toast_timer
		toast_panel.modulate.a = minf(
			clampf(elapsed / 0.22, 0.0, 1.0),
			clampf(toast_timer / 0.55, 0.0, 1.0)
		)
	else:
		toast_panel.visible = false


func _show_toast(message: String) -> void:
	if not is_instance_valid(toast_label):
		return
	toast_label.text = message
	toast_timer = TOAST_DURATION
	toast_panel.visible = true
	toast_panel.modulate.a = 0.0


func _calculate_route_progress(position_3d: Vector3) -> float:
	if scenic_route_points.size() < 2 or route_total_length <= 0.0:
		return 0.0
	var nearest_distance_squared := INF
	var nearest_route_distance := 0.0
	var accumulated_distance := 0.0
	for index in scenic_route_points.size() - 1:
		var from := scenic_route_points[index]
		var to := scenic_route_points[index + 1]
		var segment := to - from
		var segment_length := segment.length()
		var t := clampf((position_3d - from).dot(segment) / maxf(segment.length_squared(), 0.001), 0.0, 1.0)
		var closest := from + segment * t
		var distance_squared := position_3d.distance_squared_to(closest)
		if distance_squared < nearest_distance_squared:
			nearest_distance_squared = distance_squared
			nearest_route_distance = accumulated_distance + segment_length * t
		accumulated_distance += segment_length
	return clampf(nearest_route_distance / route_total_length, 0.0, 1.0)


func _build_environment() -> void:
	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	scene_environment = environment

	var sky := Sky.new()
	sky_material = _build_day_night_sky_material()
	sky.sky_material = sky_material
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	# Godot 4.7's Compatibility renderer supports a simplified SSAO pass.
	# Keep it tight and restrained so it adds contact depth without dirty halos.
	environment.ssao_enabled = false
	environment.ssao_radius = 0.72
	environment.ssao_intensity = 1.15

	environment.fog_enabled = true
	environment.fog_sky_affect = 0.52
	world_environment.environment = environment
	add_child(world_environment)

	sun_light = DirectionalLight3D.new()
	sun_light.name = "SunLight"
	sun_light.shadow_enabled = true
	sun_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun_light.directional_shadow_max_distance = 120.0
	add_child(sun_light)

	# The moon stays shadowless: it preserves readable silhouettes at night
	# without recreating the implausibly strong nighttime shadows removed earlier.
	moon_light = DirectionalLight3D.new()
	moon_light.name = "MoonFillLight"
	moon_light.light_color = Color("7799c8")
	moon_light.shadow_enabled = false
	add_child(moon_light)
	set_time_of_day(START_TIME_HOURS)


func _build_day_night_sky_material() -> ShaderMaterial:
	var sky_shader := Shader.new()
	sky_shader.code = """
shader_type sky;

uniform vec3 horizon_color = vec3(0.20, 0.22, 0.32);
uniform vec3 zenith_color = vec3(0.025, 0.055, 0.12);
uniform vec3 lower_horizon_color = vec3(0.10, 0.13, 0.18);
uniform vec3 lower_sky_color = vec3(0.018, 0.026, 0.04);
uniform vec3 sun_direction = vec3(0.0, -1.0, 0.0);
uniform vec3 sun_color = vec3(1.0, 0.82, 0.62);
uniform float sun_visibility = 0.0;
uniform float moon_visibility = 1.0;
uniform float star_visibility = 1.0;

float star_hash(vec2 point) {
	point = fract(point * vec2(123.34, 456.21));
	point += dot(point, point + 45.32);
	return fract(point.x * point.y);
}

void sky() {
	vec3 direction = normalize(EYEDIR);
	float above_horizon = max(direction.y, 0.0);
	vec3 color = mix(horizon_color, zenith_color, pow(above_horizon, 0.42));

	if (direction.y < 0.0) {
		float below_horizon = clamp(-direction.y, 0.0, 1.0);
		color = mix(lower_horizon_color, lower_sky_color, pow(below_horizon, 0.32));
	}

	vec2 spherical_uv = vec2(
		atan(direction.z, direction.x) / 6.2831853 + 0.5,
		asin(clamp(direction.y, -1.0, 1.0)) / 3.1415927 + 0.5
	);
	vec2 star_grid = spherical_uv * vec2(620.0, 280.0);
	vec2 cell = floor(star_grid);
	vec2 cell_position = fract(star_grid) - 0.5;
	float seed = star_hash(cell);
	vec2 jitter = vec2(star_hash(cell + 17.13), star_hash(cell + 93.71)) - 0.5;
	float star_size = mix(0.045, 0.14, star_hash(cell + 31.47));
	float star = 1.0 - smoothstep(star_size, star_size + 0.035, length(cell_position - jitter * 0.65));
	star *= step(0.992, seed);
	star *= smoothstep(0.025, 0.22, direction.y);
	float brightness = mix(0.55, 1.55, star_hash(cell + 71.83));
	vec3 star_tint = mix(vec3(0.68, 0.78, 1.0), vec3(1.0, 0.86, 0.68), star_hash(cell + 9.21));
	color += star * brightness * star_tint * star_visibility;

	float sun_alignment = dot(direction, normalize(sun_direction));
	float sun_disc = smoothstep(0.99935, 0.99978, sun_alignment);
	float sun_glow = pow(max(sun_alignment, 0.0), 48.0) * 0.20;
	color += sun_color * (sun_disc * 1.9 + sun_glow) * sun_visibility;

	float moon_alignment = dot(direction, normalize(-sun_direction));
	float moon_disc = smoothstep(0.99945, 0.99982, moon_alignment);
	float moon_glow = pow(max(moon_alignment, 0.0), 72.0) * 0.08;
	color += vec3(0.60, 0.72, 0.92) * (moon_disc * 0.95 + moon_glow) * moon_visibility;

	COLOR = color;
}
"""
	var material := ShaderMaterial.new()
	material.shader = sky_shader
	return material


func _update_day_night_cycle(delta: float) -> void:
	var hours_per_second := 24.0 / DAY_DURATION_SECONDS
	time_of_day_hours = fposmod(time_of_day_hours + delta * hours_per_second, 24.0)
	sky_update_accumulator += delta
	if sky_update_accumulator < SKY_UPDATE_INTERVAL:
		return
	sky_update_accumulator = fmod(sky_update_accumulator, SKY_UPDATE_INTERVAL)
	_apply_day_night_state()


func set_time_of_day(hours: float) -> void:
	time_of_day_hours = fposmod(hours, 24.0)
	sky_update_accumulator = 0.0
	_apply_day_night_state()


func _apply_day_night_state() -> void:
	if not (
		is_instance_valid(scene_environment)
		and is_instance_valid(sky_material)
		and is_instance_valid(sun_light)
		and is_instance_valid(moon_light)
	):
		return
	if is_instance_valid(soundscape):
		soundscape.set_time_of_day(time_of_day_hours)

	var solar_angle := (time_of_day_hours - 6.0) / 24.0 * TAU
	var sun_height := sin(solar_angle) * sin(deg_to_rad(65.0))
	var horizontal_length := sqrt(maxf(0.0, 1.0 - sun_height * sun_height))
	var azimuth := deg_to_rad(-115.0) + time_of_day_hours / 24.0 * TAU
	var sun_direction := Vector3(
		cos(azimuth) * horizontal_length,
		sun_height,
		sin(azimuth) * horizontal_length
	).normalized()

	var daylight := smoothstep(-0.10, 0.18, sun_height)
	var sunlight := smoothstep(-0.06, 0.16, sun_height)
	var star_visibility := 1.0 - smoothstep(-0.20, 0.05, sun_height)
	var twilight := 1.0 - smoothstep(0.0, 0.34, absf(sun_height))
	var night := 1.0 - daylight

	var night_horizon := Color("30384f")
	var day_horizon := Color("91c2df")
	var twilight_horizon := Color("e27852")
	var horizon_color := night_horizon.lerp(day_horizon, daylight)
	horizon_color = horizon_color.lerp(twilight_horizon, twilight * 0.82)

	var night_zenith := Color("07142d")
	var day_zenith := Color("296ba5")
	var twilight_zenith := Color("493f6f")
	var zenith_color := night_zenith.lerp(day_zenith, daylight)
	zenith_color = zenith_color.lerp(twilight_zenith, twilight * 0.42)

	var lower_horizon := Color("192332").lerp(Color("8eb4c6"), daylight)
	lower_horizon = lower_horizon.lerp(Color("b55c47"), twilight * 0.60)
	var lower_sky := Color("050a10").lerp(Color("536f76"), daylight)

	var warm_sun := Color("ff9a65")
	var noon_sun := Color("fff3d5")
	var sun_color := warm_sun.lerp(noon_sun, smoothstep(0.05, 0.62, sun_height))

	sky_material.set_shader_parameter("horizon_color", Vector3(horizon_color.r, horizon_color.g, horizon_color.b))
	sky_material.set_shader_parameter("zenith_color", Vector3(zenith_color.r, zenith_color.g, zenith_color.b))
	sky_material.set_shader_parameter("lower_horizon_color", Vector3(lower_horizon.r, lower_horizon.g, lower_horizon.b))
	sky_material.set_shader_parameter("lower_sky_color", Vector3(lower_sky.r, lower_sky.g, lower_sky.b))
	sky_material.set_shader_parameter("sun_direction", sun_direction)
	sky_material.set_shader_parameter("sun_color", Vector3(sun_color.r, sun_color.g, sun_color.b))
	sky_material.set_shader_parameter("sun_visibility", sunlight)
	sky_material.set_shader_parameter("moon_visibility", star_visibility * 0.82)
	sky_material.set_shader_parameter("star_visibility", star_visibility)

	scene_environment.ambient_light_color = Color("5d718d").lerp(Color("b9cccf"), daylight)
	scene_environment.ambient_light_color = scene_environment.ambient_light_color.lerp(
		Color("b88476"),
		twilight * 0.30
	)
	scene_environment.ambient_light_energy = lerpf(0.37, 0.68, daylight)
	scene_environment.fog_light_color = Color("354258").lerp(Color("aac2c8"), daylight)
	scene_environment.fog_light_color = scene_environment.fog_light_color.lerp(
		Color("a85b4d"),
		twilight * 0.34
	)
	scene_environment.fog_light_energy = lerpf(0.46, 0.68, daylight)
	scene_environment.fog_density = lerpf(0.0032, 0.0021, daylight)

	sun_light.light_color = sun_color
	sun_light.light_energy = sunlight * lerpf(0.24, 0.78, smoothstep(0.0, 0.58, sun_height))
	sun_light.visible = sunlight > 0.01
	sun_light.basis = Basis.looking_at(-sun_direction, Vector3.UP)
	moon_light.light_energy = night * star_visibility * 0.36
	moon_light.basis = Basis.looking_at(sun_direction, Vector3.UP)
	var should_enable_vehicle_lights := star_visibility > 0.16
	if should_enable_vehicle_lights != vehicle_lights_enabled:
		vehicle_lights_enabled = should_enable_vehicle_lights
		if is_instance_valid(player_car):
			player_car.set_headlights_enabled(vehicle_lights_enabled)
		if is_instance_valid(traffic_manager):
			traffic_manager.set_headlights_enabled(vehicle_lights_enabled)


func _format_time_of_day() -> String:
	var total_minutes := int(floor(time_of_day_hours * 60.0)) % (24 * 60)
	return "%02d:%02d" % [total_minutes / 60, total_minutes % 60]


func _day_phase_name() -> String:
	if time_of_day_hours >= 5.0 and time_of_day_hours < 8.0:
		return "DAWN"
	if time_of_day_hours >= 8.0 and time_of_day_hours < 17.0:
		return "DAY"
	if time_of_day_hours >= 17.0 and time_of_day_hours < 20.0:
		return "DUSK"
	return "NIGHT"


func _sample_catmull_rom_path(
	control_points: Array[Vector3],
	subdivisions: int,
	source_segments: Array[int] = []
) -> Array[Vector3]:
	source_segments.clear()
	var samples: Array[Vector3] = []
	if control_points.size() < 2:
		samples.assign(control_points)
		return samples
	var safe_subdivisions := maxi(1, subdivisions)
	samples.append(control_points[0])
	for segment_index in control_points.size() - 1:
		var p0 := control_points[maxi(segment_index - 1, 0)]
		var p1 := control_points[segment_index]
		var p2 := control_points[segment_index + 1]
		var p3 := control_points[mini(segment_index + 2, control_points.size() - 1)]
		for step in range(1, safe_subdivisions + 1):
			var t := float(step) / float(safe_subdivisions)
			var sample := _catmull_rom(p0, p1, p2, p3, t)
			# Catmull-Rom is ideal for the road's horizontal curve, but can dip
			# below level terrain after a hill. Monotonic smoothstep elevation
			# preserves level crests and valleys without overshoot.
			var elevation_t := t * t * (3.0 - 2.0 * t)
			sample.y = lerpf(p1.y, p2.y, elevation_t)
			samples.append(sample)
			source_segments.append(segment_index)
	return samples


func _catmull_rom(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t_squared := t * t
	var t_cubed := t_squared * t
	return 0.5 * (
		2.0 * p1
		+ (p2 - p0) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t_squared
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t_cubed
	)


func _build_scenic_route() -> void:
	# The proving-ground road now feeds directly into a short, representative
	# night drive. A broad hidden ground slab keeps the first art pass reliable.
	_add_static_box(
		"ScenicGround",
		Vector3(190.0, 0.5, 360.0),
		Vector3(0.0, -0.27, -260.0),
		Color("18241f"),
		true
	)
	scenic_route_controls = [
		Vector3(19.0, 0.0, -122.0),
		Vector3(18.0, 6.0, -151.0),
		Vector3(8.0, 0.0, -181.0),
		Vector3(-13.0, 0.0, -209.0),
		Vector3(-7.0, 0.0, -239.0),
		Vector3(17.0, 0.0, -270.0),
		Vector3(27.0, 0.0, -304.0),
		Vector3(17.0, 0.0, -338.0),
		Vector3(-4.0, 0.0, -372.0),
		Vector3(-3.0, 7.5, -408.0),
	]
	scenic_route_points = _sample_catmull_rom_path(
		scenic_route_controls,
		ROAD_CURVE_SUBDIVISIONS,
		scenic_route_segment_sources
	)
	route_total_length = 0.0
	for index in scenic_route_points.size() - 1:
		route_total_length += scenic_route_points[index].distance_to(scenic_route_points[index + 1])
		_add_scenic_road_segment(scenic_route_points[index], scenic_route_points[index + 1], ROAD_WIDTH)
	var collision_shape := CollisionShape3D.new()
	var terrain_shape := ConcavePolygonShape3D.new()
	terrain_shape.set_faces(
		MeshFactory.ribbon_collision_faces(scenic_route_points, 72.0)
	)
	collision_shape.shape = terrain_shape
	scenic_hill_collision_body.add_child(collision_shape)
	_build_scenic_forest()
	_build_scenic_guardrails()
	_build_utility_line()
	_build_roadside_diner()
	_build_scenic_overlook()
	_build_covered_bridge()
	_build_forest_cabin()
	_build_distant_hills()
	_build_route_finish()


func _add_scenic_road_segment(from: Vector3, to: Vector3, width: float) -> void:
	_add_road_test_segment(from, to, width)


func _road_basis(direction: Vector3) -> Basis:
	var forward := direction.normalized()
	var right := Vector3.UP.cross(forward).normalized()
	if right.length_squared() < 0.001:
		right = Vector3.RIGHT
	var surface_normal := forward.cross(right).normalized()
	return Basis(right, surface_normal, forward)


func _build_scenic_forest() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 27092026
	for segment_index in scenic_route_points.size() - 1:
		var from := scenic_route_points[segment_index]
		var to := scenic_route_points[segment_index + 1]
		var direction := to - from
		var distance := direction.length()
		var perpendicular := Vector3(direction.z, 0.0, -direction.x).normalized()
		var tree_count := maxi(1, roundi(distance / 7.0))
		for tree_index in tree_count:
			var t := (float(tree_index) + 0.45 + random.randf_range(-0.16, 0.16)) / float(tree_count)
			for side in [-1.0, 1.0]:
				var offset := 7.6 + random.randf_range(0.0, 8.5)
				var tree_position: Vector3 = from.lerp(to, clampf(t, 0.04, 0.96)) + perpendicular * offset * side
				# Leave deliberate clearings around each handcrafted roadside place.
				if (
					tree_position.distance_to(DINER_POSITION) < 30.0
					or tree_position.distance_to(OVERLOOK_POSITION) < 18.0
					or tree_position.distance_to(COVERED_BRIDGE_POSITION) < 17.0
					or tree_position.distance_to(CABIN_POSITION) < 19.0
				):
					continue
				# Mature roadside pines are an important scale reference beside the
				# full-size pickup; the old 4-7 m range made the truck read oversized.
				_queue_pine_tree(tree_position, random.randf_range(1.08, 1.62), random.randf() > 0.52)
	_finish_pine_tree_batches()


func _queue_pine_tree(position_3d: Vector3, tree_scale: float, darker: bool) -> void:
	if not is_instance_valid(tree_trunk_material):
		tree_trunk_material = _material(Color("49362d"))
		tree_foliage_material = _material(Color("244638"))
		tree_foliage_dark_material = _material(Color("18362f"))
	pine_positions.append(position_3d)
	pine_scales.append(tree_scale)
	pine_dark_flags.append(darker)

	# Keep one inexpensive trunk collision per tree while batching all visuals.
	var tree := StaticBody3D.new()
	tree.name = "PineTreeCollision"
	tree.position = position_3d
	tree.scale = Vector3.ONE * tree_scale
	tree.collision_layer = 1
	tree.collision_mask = 0
	add_child(tree)
	var collision_shape := CollisionShape3D.new()
	var collision := CylinderShape3D.new()
	collision.radius = 0.34
	collision.height = 2.5
	collision_shape.shape = collision
	collision_shape.position.y = 1.25
	tree.add_child(collision_shape)


func _finish_pine_tree_batches() -> void:
	var trunk_transforms: Array[Transform3D] = []
	var light_lower_transforms: Array[Transform3D] = []
	var light_upper_transforms: Array[Transform3D] = []
	var dark_lower_transforms: Array[Transform3D] = []
	var dark_upper_transforms: Array[Transform3D] = []
	var base_ao_transforms: Array[Transform3D] = []
	for index in pine_positions.size():
		var position_3d := pine_positions[index]
		var tree_scale := pine_scales[index]
		var scaled_basis := Basis.IDENTITY.scaled(Vector3.ONE * tree_scale)
		trunk_transforms.append(Transform3D(scaled_basis, position_3d + Vector3.UP * 1.2 * tree_scale))
		var lower_transform := Transform3D(scaled_basis, position_3d + Vector3.UP * 2.75 * tree_scale)
		var upper_transform := Transform3D(scaled_basis, position_3d + Vector3.UP * 4.18 * tree_scale)
		var ao_basis := Basis.IDENTITY.scaled(Vector3(1.22 * tree_scale, 1.0, 1.22 * tree_scale))
		base_ao_transforms.append(Transform3D(ao_basis, position_3d + Vector3.UP * 0.018))
		if pine_dark_flags[index]:
			dark_lower_transforms.append(lower_transform)
			dark_upper_transforms.append(upper_transform)
		else:
			light_lower_transforms.append(lower_transform)
			light_upper_transforms.append(upper_transform)

	var trunk_mesh := CylinderMesh.new()
	trunk_mesh.top_radius = 0.22
	trunk_mesh.bottom_radius = 0.34
	trunk_mesh.height = 2.4
	trunk_mesh.radial_segments = 7
	var lower_foliage_mesh := CylinderMesh.new()
	lower_foliage_mesh.top_radius = 0.0
	lower_foliage_mesh.bottom_radius = 1.72
	lower_foliage_mesh.height = 3.35
	lower_foliage_mesh.radial_segments = 8
	var upper_foliage_mesh := CylinderMesh.new()
	upper_foliage_mesh.top_radius = 0.0
	upper_foliage_mesh.bottom_radius = 1.28
	upper_foliage_mesh.height = 2.75
	upper_foliage_mesh.radial_segments = 8
	_add_tree_multimesh("PineTrunks", trunk_mesh, tree_trunk_material, trunk_transforms)
	_add_tree_multimesh("PineFoliageLightLower", lower_foliage_mesh, tree_foliage_material, light_lower_transforms)
	_add_tree_multimesh("PineFoliageLightUpper", upper_foliage_mesh, tree_foliage_material, light_upper_transforms)
	_add_tree_multimesh("PineFoliageDarkLower", lower_foliage_mesh, tree_foliage_dark_material, dark_lower_transforms)
	_add_tree_multimesh("PineFoliageDarkUpper", upper_foliage_mesh, tree_foliage_dark_material, dark_upper_transforms)
	var ao_material := StandardMaterial3D.new()
	ao_material.albedo_color = Color("080c0d")
	ao_material.vertex_color_use_as_albedo = true
	ao_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ao_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ao_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_add_tree_multimesh("PineBaseAmbientOcclusion", MeshFactory.soft_disc(20), ao_material, base_ao_transforms)


func _add_tree_multimesh(node_name: String, mesh: Mesh, material: Material, transforms: Array[Transform3D]) -> void:
	if transforms.is_empty():
		return
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for index in transforms.size():
		multimesh.set_instance_transform(index, transforms[index])
	# All batches share the same broad route bounds, avoiding per-tree draw calls.
	multimesh.custom_aabb = AABB(Vector3(-100.0, -3.0, -430.0), Vector3(200.0, 18.0, 330.0))
	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = multimesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.visibility_range_end = 300.0
	add_child(instance)


func _build_distant_hills() -> void:
	for hill_data in [
		[-67.0, -190.0, 20.0, 11.0], [73.0, -205.0, 25.0, 13.0],
		[-76.0, -275.0, 29.0, 15.0], [78.0, -326.0, 23.0, 12.0],
		[-62.0, -390.0, 24.0, 13.0], [55.0, -415.0, 31.0, 16.0],
	]:
		_add_low_poly_hill(
			Vector3(hill_data[0], 0.0, hill_data[1]),
			hill_data[2],
			hill_data[3]
		)


func _add_low_poly_hill(position_3d: Vector3, radius: float, height: float) -> void:
	var hill := MeshInstance3D.new()
	hill.name = "DistantHill"
	var cone := CylinderMesh.new()
	cone.top_radius = radius * 0.12
	cone.bottom_radius = radius
	cone.height = height
	cone.radial_segments = 9
	hill.mesh = cone
	hill.material_override = _material(Color("152a29"))
	hill.position = position_3d + Vector3.UP * height * 0.5
	add_child(hill)


func _build_scenic_guardrails() -> void:
	_add_guardrail_segment(1, -1.0)
	_add_guardrail_segment(2, 1.0)
	_add_guardrail_segment(5, -1.0)
	_add_guardrail_segment(7, 1.0)
	for bend_index in [2, 4, 6, 8]:
		_add_chevron_marker(bend_index)


func _add_guardrail_segment(segment_index: int, side: float) -> void:
	if not is_instance_valid(guardrail_material):
		guardrail_material = _material(Color("737b81"))
	var piece_index := 0
	var last_to := Vector3.ZERO
	var last_perpendicular := Vector3.ZERO
	var last_yaw := 0.0
	for sample_index in scenic_route_segment_sources.size():
		if scenic_route_segment_sources[sample_index] != segment_index:
			continue
		var from := scenic_route_points[sample_index]
		var to := scenic_route_points[sample_index + 1]
		var direction := to - from
		var distance := direction.length()
		var perpendicular := Vector3(direction.z, 0.0, -direction.x).normalized()
		var rail_rotation := _road_basis(direction).get_euler()
		var yaw := rail_rotation.y
		var rail_center := (from + to) * 0.5 + perpendicular * 6.5 * side + Vector3.UP * 0.76
		_add_static_box_rotated(
			"Guardrail",
			Vector3(0.18, 0.28, distance + 0.18),
			rail_center,
			rail_rotation,
			Color("737b81"),
			true,
			0.045
		)
		var post_position := from + perpendicular * 6.5 * side + Vector3.UP * 0.45
		_add_visual_box(
			"GuardrailPost",
			Vector3(0.18, 0.90, 0.18),
			post_position,
			Color("5f676c"),
			Vector3(0.0, yaw, 0.0)
		)
		if piece_index % 2 == 0:
			_add_road_reflector(post_position + Vector3.UP * 0.44, Vector3(0.0, yaw, 0.0), true)
		piece_index += 1
		last_to = to
		last_perpendicular = perpendicular
		last_yaw = yaw
	if piece_index > 0:
		var final_post := last_to + last_perpendicular * 6.5 * side + Vector3.UP * 0.45
		_add_visual_box(
			"GuardrailPost",
			Vector3(0.18, 0.90, 0.18),
			final_post,
			Color("5f676c"),
			Vector3(0.0, last_yaw, 0.0)
		)


func _add_chevron_marker(point_index: int) -> void:
	var previous := scenic_route_controls[point_index - 1]
	var point := scenic_route_controls[point_index]
	var following := scenic_route_controls[point_index + 1]
	var incoming := (point - previous).normalized()
	var outgoing := (following - point).normalized()
	var tangent := (incoming + outgoing).normalized()
	var perpendicular := Vector3(tangent.z, 0.0, -tangent.x)
	var turn_cross := incoming.x * outgoing.z - incoming.z * outgoing.x
	var outside_side := 1.0 if turn_cross > 0.0 else -1.0
	var marker_position := point + perpendicular * outside_side * 7.0
	var yaw := atan2(incoming.x, incoming.z)
	_add_visual_box("ChevronPole", Vector3(0.13, 1.55, 0.13), marker_position + Vector3.UP * 0.78, Color("4b5054"))
	_add_emissive_box(
		"ChevronMarker",
		Vector3(1.30, 0.62, 0.10),
		marker_position + Vector3.UP * 1.72,
		Vector3(0.0, yaw, 0.0),
		Color("c58b3d"),
		Color("ffc164"),
		0.72
	)


func _build_utility_line() -> void:
	var pole_positions: Array[Vector3] = []
	for index in scenic_route_controls.size() - 1:
		if index % 2 != 0:
			continue
		var point := scenic_route_controls[index]
		var direction := scenic_route_controls[index + 1] - point
		var perpendicular := Vector3(direction.z, 0.0, -direction.x).normalized()
		var pole_position := point - perpendicular * 11.0
		pole_positions.append(pole_position)
		var warm_lamp := pole_position.distance_to(Vector3(44.0, 0.0, -280.0)) < 75.0
		_add_utility_pole(pole_position, warm_lamp)
	for index in pole_positions.size() - 1:
		_add_cylinder_between(
			"UtilityWire",
			pole_positions[index] + Vector3.UP * 7.85,
			pole_positions[index + 1] + Vector3.UP * 7.85,
			0.035,
			_material(Color("11171b"))
		)


func _add_utility_pole(position_3d: Vector3, warm_lamp: bool) -> void:
	if not is_instance_valid(utility_wood_material):
		utility_wood_material = _material(Color("594337"))
	var pole := StaticBody3D.new()
	pole.name = "UtilityPole"
	pole.position = position_3d
	pole.collision_layer = 1
	pole.collision_mask = 0
	add_child(pole)
	var pole_mesh := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.17
	cylinder.bottom_radius = 0.25
	cylinder.height = 8.2
	cylinder.radial_segments = 8
	pole_mesh.mesh = cylinder
	pole_mesh.material_override = utility_wood_material
	pole_mesh.position.y = 4.1
	pole.add_child(pole_mesh)
	_add_mesh_box_child(pole, "Crossbar", Vector3(3.0, 0.14, 0.17), Vector3(0.0, 7.55, 0.0), utility_wood_material, 0.035)
	var collision_shape := CollisionShape3D.new()
	var collision := CylinderShape3D.new()
	collision.radius = 0.25
	collision.height = 5.0
	collision_shape.shape = collision
	collision_shape.position.y = 2.5
	pole.add_child(collision_shape)
	if warm_lamp:
		var bulb := OmniLight3D.new()
		bulb.name = "RoadsideLamp"
		bulb.light_color = Color("ffc47c")
		bulb.light_energy = 0.82
		bulb.omni_range = 10.5
		bulb.omni_attenuation = 1.45
		bulb.shadow_enabled = false
		bulb.position = Vector3(0.0, 6.85, 0.0)
		pole.add_child(bulb)
		_add_mesh_box_child(pole, "LampGlow", Vector3(0.34, 0.22, 0.34), Vector3(0.0, 6.85, 0.0), _emissive_material(Color("d89c55"), Color("ffd48d"), 1.15, 0.35), 0.055)


func _add_cylinder_between(node_name: String, from: Vector3, to: Vector3, radius: float, material: Material) -> void:
	var direction := to - from
	var length := direction.length()
	if length < 0.01:
		return
	var y_axis := direction / length
	var reference := Vector3.FORWARD if absf(y_axis.dot(Vector3.FORWARD)) < 0.96 else Vector3.RIGHT
	var x_axis := reference.cross(y_axis).normalized()
	var z_axis := x_axis.cross(y_axis).normalized()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = node_name
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = length
	cylinder.radial_segments = 6
	mesh_instance.mesh = cylinder
	mesh_instance.material_override = material
	mesh_instance.global_transform = Transform3D(Basis(x_axis, y_axis, z_axis), (from + to) * 0.5)
	add_child(mesh_instance)


func _build_roadside_diner() -> void:
	var lot_center := Vector3(42.0, 0.075, -281.0)
	_add_visual_box("DinerParkingLot", Vector3(31.0, 0.08, 23.0), lot_center, Color("252a2d"))
	# Pale parking stripes lead naturally off the road shoulder.
	for stripe_index in 5:
		_add_visual_box(
			"ParkingStripe",
			Vector3(0.10, 0.025, 6.0),
			Vector3(31.5 + stripe_index * 3.25, 0.13, -283.0),
			Color("858889")
		)

	_add_static_box_rotated(
		"RoadsideDiner",
		Vector3(14.0, 4.4, 10.0),
		Vector3(51.0, 2.2, -281.0),
		Vector3.ZERO,
		Color("a4795f"),
		true,
		0.12
	)
	_add_visual_box("DinerRoof", Vector3(15.2, 0.38, 11.2), Vector3(51.0, 4.54, -281.0), Color("64382f"))
	_add_visual_box("DinerCanopy", Vector3(7.0, 0.24, 10.8), Vector3(40.5, 3.15, -281.0), Color("7b4437"))
	for z in [-285.2, -276.8]:
		_add_visual_box("CanopyPost", Vector3(0.22, 3.0, 0.22), Vector3(37.2, 1.55, z), Color("6b6f70"))

	if not is_instance_valid(warm_window_material):
		warm_window_material = _emissive_material(Color("dca76c"), Color("ffbd72"), 1.25, 0.32)
	for z in [-284.4, -279.8, -276.9]:
		_add_mesh_box_world(
			"WarmDinerWindow",
			Vector3(0.08, 1.45, 2.35),
			Vector3(43.96, 2.15, z),
			Vector3.ZERO,
			warm_window_material,
			0.018
		)
	_add_visual_box("DinerDoor", Vector3(0.09, 2.25, 1.25), Vector3(43.93, 1.24, -282.2), Color("293239"))

	# Two simple fuel pumps make the stop readable from the road at a glance.
	for z in [-283.1, -278.9]:
		_add_static_box_rotated(
			"FuelPump",
			Vector3(0.75, 1.45, 0.72),
			Vector3(38.8, 0.78, z),
			Vector3.ZERO,
			Color("a9503c"),
			true,
			0.08
		)
		_add_emissive_box(
			"PumpDisplay",
			Vector3(0.05, 0.36, 0.42),
			Vector3(38.40, 1.02, z),
			Vector3.ZERO,
			Color("7c9c94"),
			Color("a8e2cf"),
			0.60
		)

	for lamp_position in [Vector3(39.5, 2.92, -285.0), Vector3(39.5, 2.92, -277.0), Vector3(47.0, 4.25, -281.0)]:
		var lamp := OmniLight3D.new()
		lamp.name = "DinerWarmLight"
		lamp.light_color = Color("ffc27a")
		lamp.light_energy = 1.05
		lamp.omni_range = 11.5
		lamp.omni_attenuation = 1.35
		lamp.shadow_enabled = false
		lamp.position = lamp_position
		add_child(lamp)

	# A tall glowing sign works as the route's visual destination from afar.
	_add_static_box_rotated(
		"DinerSignPole",
		Vector3(0.24, 5.4, 0.24),
		Vector3(31.5, 2.7, -263.0),
		Vector3.ZERO,
		Color("555b5e"),
		true,
		0.05
	)
	_add_emissive_box(
		"DinerSign",
		Vector3(0.25, 1.75, 3.8),
		Vector3(31.5, 5.8, -263.0),
		Vector3.ZERO,
		Color("a44e3e"),
		Color("f28a55"),
		1.05
	)
	_add_drive_trigger("DinerArrival", DINER_POSITION + Vector3.UP * 1.5, Vector3(22.0, 3.0, 18.0), &"_on_diner_entered")


func _build_scenic_overlook() -> void:
	# A quiet pull-off on the outside of the first forest bend. Human-scale
	# furniture and a telescope reinforce the world scale without another task.
	var lot_rotation := Vector3(0.0, deg_to_rad(-12.0), 0.0)
	_add_visual_box(
		"OverlookGravel",
		Vector3(18.0, 0.07, 11.0),
		OVERLOOK_POSITION + Vector3.UP * 0.045,
		Color("4c443d"),
		lot_rotation
	)
	_add_static_box_rotated(
		"OverlookSafetyRail",
		Vector3(0.20, 0.76, 10.5),
		OVERLOOK_POSITION + Vector3(-8.2, 0.48, 0.0),
		Vector3.ZERO,
		Color("697278"),
		true,
		0.045
	)
	var bench_wood := _material(Color("72513e"))
	_add_mesh_box_world("OverlookBenchSeat", Vector3(0.72, 0.16, 2.8), OVERLOOK_POSITION + Vector3(-3.8, 0.58, -0.7), Vector3.ZERO, bench_wood, 0.035)
	_add_mesh_box_world("OverlookBenchBack", Vector3(0.16, 0.82, 2.8), OVERLOOK_POSITION + Vector3(-4.12, 0.96, -0.7), Vector3(0.0, 0.0, deg_to_rad(-8.0)), bench_wood, 0.035)
	for z_offset in [-1.0, 1.0]:
		_add_visual_box("OverlookBenchLeg", Vector3(0.15, 0.55, 0.16), OVERLOOK_POSITION + Vector3(-3.8, 0.29, -0.7 + z_offset), Color("4a3d35"))
	_add_static_box_rotated("TelescopePedestal", Vector3(0.22, 1.35, 0.22), OVERLOOK_POSITION + Vector3(-5.8, 0.72, 2.4), Vector3.ZERO, Color("555e64"), true, 0.045)
	_add_mesh_box_world("OverlookTelescope", Vector3(0.36, 0.34, 1.25), OVERLOOK_POSITION + Vector3(-6.0, 1.55, 2.4), Vector3(0.0, deg_to_rad(90.0), deg_to_rad(-8.0)), _material(Color("303a40")), 0.06)
	_add_emissive_box("OverlookMap", Vector3(0.10, 1.05, 2.1), OVERLOOK_POSITION + Vector3(-2.6, 1.16, 3.6), Vector3.ZERO, Color("8a7659"), Color("d7bd82"), 0.34)
	_add_static_box_rotated("OverlookLampPole", Vector3(0.16, 3.0, 0.16), OVERLOOK_POSITION + Vector3(-1.4, 1.5, -3.8), Vector3.ZERO, Color("41484d"), true, 0.035)
	_add_emissive_box("OverlookLampGlow", Vector3(0.34, 0.28, 0.34), OVERLOOK_POSITION + Vector3(-1.4, 2.88, -3.8), Vector3.ZERO, Color("cb8c4f"), Color("ffd08a"), 1.2)
	var lamp := OmniLight3D.new()
	lamp.name = "OverlookWarmLight"
	lamp.light_color = Color("ffc27a")
	lamp.light_energy = 0.82
	lamp.omni_range = 9.0
	lamp.omni_attenuation = 1.5
	lamp.shadow_enabled = false
	lamp.position = OVERLOOK_POSITION + Vector3(-1.4, 2.88, -3.8)
	add_child(lamp)


func _build_covered_bridge() -> void:
	var direction := _nearest_scenic_route_direction(COVERED_BRIDGE_POSITION)
	var perpendicular := Vector3(direction.z, 0.0, -direction.x)
	var yaw := atan2(direction.x, direction.z)
	var rotation_3d := Vector3(0.0, yaw, 0.0)
	var wood := Color("55392e")
	var dark_wood := Color("342824")
	for side in [-1.0, 1.0]:
		_add_static_box_rotated(
			"BridgeSideRail",
			Vector3(0.28, 0.82, 14.4),
			COVERED_BRIDGE_POSITION + perpendicular * 5.90 * side + Vector3.UP * 0.58,
			rotation_3d,
			wood,
			true,
			0.05
		)
		_add_visual_box("BridgeUpperRail", Vector3(0.24, 0.28, 14.5), COVERED_BRIDGE_POSITION + perpendicular * 5.90 * side + Vector3.UP * 3.25, dark_wood, rotation_3d)
		for along in [-6.6, 0.0, 6.6]:
			_add_static_box_rotated(
				"BridgePost",
				Vector3(0.38, 3.65, 0.38),
				COVERED_BRIDGE_POSITION + perpendicular * 5.90 * side + direction * along + Vector3.UP * 2.05,
				rotation_3d,
				wood,
				true,
				0.055
			)
	_add_visual_box("BridgeRoof", Vector3(12.875, 0.48, 14.9), COVERED_BRIDGE_POSITION + Vector3.UP * 4.12, Color("432b27"), rotation_3d)
	_add_visual_box("BridgeRoofRidge", Vector3(0.34, 0.32, 15.1), COVERED_BRIDGE_POSITION + Vector3.UP * 4.48, Color("2c2221"), rotation_3d)
	for along in [-6.8, 6.8]:
		_add_visual_box("BridgeCrossbeam", Vector3(12.125, 0.34, 0.36), COVERED_BRIDGE_POSITION + direction * along + Vector3.UP * 3.64, dark_wood, rotation_3d)
	for along in [-3.8, 3.8]:
		var lantern_position: Vector3 = COVERED_BRIDGE_POSITION + direction * float(along) + Vector3.UP * 3.28
		_add_emissive_box("BridgeLantern", Vector3(0.30, 0.34, 0.30), lantern_position, rotation_3d, Color("bd8146"), Color("ffd08a"), 1.25)
		var lantern := OmniLight3D.new()
		lantern.name = "BridgeWarmLight"
		lantern.light_color = Color("ffc078")
		lantern.light_energy = 0.68
		lantern.omni_range = 7.5
		lantern.omni_attenuation = 1.52
		lantern.shadow_enabled = false
		lantern.position = lantern_position
		add_child(lantern)


func _nearest_scenic_route_direction(position_3d: Vector3) -> Vector3:
	var nearest_direction := Vector3.FORWARD
	var nearest_distance := INF
	for index in scenic_route_points.size() - 1:
		var from := scenic_route_points[index]
		var to := scenic_route_points[index + 1]
		var segment := to - from
		var segment_length_squared := segment.length_squared()
		if segment_length_squared < 0.001:
			continue
		var t := clampf((position_3d - from).dot(segment) / segment_length_squared, 0.0, 1.0)
		var distance := position_3d.distance_squared_to(from + segment * t)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest_direction = segment.normalized()
	return nearest_direction


func _build_forest_cabin() -> void:
	var cabin_body := _add_static_box_rotated(
		"ForestCabin",
		Vector3(8.0, 3.7, 6.2),
		CABIN_POSITION + Vector3.UP * 1.85,
		Vector3.ZERO,
		Color("6a4937"),
		true,
		0.10
	)
	cabin_body.collision_layer = 1
	var roof_material := _material(Color("412d2a"))
	_add_mesh_box_world("CabinRoofLeft", Vector3(4.8, 0.34, 7.1), CABIN_POSITION + Vector3(-1.8, 4.06, 0.0), Vector3(0.0, 0.0, deg_to_rad(-13.0)), roof_material, 0.065)
	_add_mesh_box_world("CabinRoofRight", Vector3(4.8, 0.34, 7.1), CABIN_POSITION + Vector3(1.8, 4.06, 0.0), Vector3(0.0, 0.0, deg_to_rad(13.0)), roof_material, 0.065)
	_add_visual_box("CabinPorch", Vector3(2.8, 0.18, 6.0), CABIN_POSITION + Vector3(5.25, 0.18, 0.0), Color("594133"))
	_add_visual_box("CabinDoor", Vector3(0.10, 2.35, 1.25), CABIN_POSITION + Vector3(4.03, 1.24, 0.0), Color("342b28"))
	for z_offset in [-2.0, 2.0]:
		_add_emissive_box("CabinWindow", Vector3(0.10, 1.18, 1.35), CABIN_POSITION + Vector3(4.05, 2.15, z_offset), Vector3.ZERO, Color("c3935c"), Color("ffbd70"), 1.18)
	_add_static_box_rotated("CabinChimney", Vector3(0.72, 2.2, 0.72), CABIN_POSITION + Vector3(-2.2, 4.42, 1.4), Vector3.ZERO, Color("49413d"), true, 0.065)

	var fire_position := CABIN_POSITION + Vector3(8.5, 0.0, 4.4)
	for log_angle in [0.0, 60.0, -60.0]:
		_add_visual_box("CampfireLog", Vector3(0.28, 0.24, 1.65), fire_position + Vector3.UP * 0.18, Color("443129"), Vector3(0.0, deg_to_rad(log_angle), 0.0))
	_add_emissive_box("CampfireGlow", Vector3(0.62, 0.82, 0.62), fire_position + Vector3.UP * 0.72, Vector3(0.0, deg_to_rad(45.0), 0.0), Color("d06135"), Color("ff9c52"), 1.6)
	var fire_light := OmniLight3D.new()
	fire_light.name = "CampfireLight"
	fire_light.light_color = Color("ff9e59")
	fire_light.light_energy = 1.0
	fire_light.omni_range = 9.5
	fire_light.omni_attenuation = 1.42
	fire_light.shadow_enabled = false
	fire_light.position = fire_position + Vector3.UP * 1.0
	add_child(fire_light)

	# A mailbox near the shoulder adds another immediately recognizable scale cue.
	var mailbox_position := CABIN_POSITION + Vector3(15.5, 0.0, 1.5)
	_add_static_box_rotated("CabinMailboxPost", Vector3(0.16, 1.25, 0.16), mailbox_position + Vector3.UP * 0.63, Vector3.ZERO, Color("4b4038"), true, 0.035)
	_add_mesh_box_world("CabinMailbox", Vector3(0.56, 0.48, 1.05), mailbox_position + Vector3.UP * 1.34, Vector3.ZERO, _material(Color("7b5143")), 0.08)


func _build_route_finish() -> void:
	var finish_position := scenic_route_points[-1]
	var approach := finish_position - scenic_route_points[-2]
	var perpendicular := Vector3(approach.z, 0.0, -approach.x).normalized()
	var yaw := atan2(approach.x, approach.z)
	for side in [-1.0, 1.0]:
		_add_emissive_box(
			"RouteFinishMarker",
			Vector3(0.24, 1.45, 0.24),
			finish_position + perpendicular * 5.625 * side + Vector3.UP * 0.73,
			Vector3(0.0, yaw, 0.0),
			Color("5e7f83"),
			Color("8de4d7"),
			0.72
		)
	_add_drive_trigger("RouteFinish", finish_position + Vector3.UP * 1.5, Vector3(15.0, 3.0, 16.0), &"_on_route_finished")


func _add_drive_trigger(node_name: String, position_3d: Vector3, size: Vector3, callback: StringName) -> void:
	var area := Area3D.new()
	area.name = node_name
	area.position = position_3d
	area.collision_layer = 0
	area.collision_mask = 1
	area.monitoring = true
	var collision_shape := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision_shape.shape = shape
	area.add_child(collision_shape)
	area.body_entered.connect(Callable(self, callback))
	add_child(area)


func _on_diner_entered(body: Node3D) -> void:
	if body != player_car or diner_reached:
		return
	diner_reached = true
	roadside_stamps += 1
	_show_toast("ROADSIDE STAMP COLLECTED   •   +1")
	if is_instance_valid(soundscape):
		soundscape.play_progress_chime(660.0)
	_save_progress()


func _on_route_finished(body: Node3D) -> void:
	if body == player_car:
		if not route_finished:
			_show_toast("OPEN ROAD UNLOCKED   •   DRIVE AS FAR AS YOU LIKE")
			if is_instance_valid(soundscape):
				soundscape.play_progress_chime(520.0)
		route_finished = true
		_save_progress()


func _load_progress() -> void:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		return
	roadside_stamps = maxi(0, int(config.get_value("progress", "roadside_stamps", 0)))
	best_distance = maxf(0.0, float(config.get_value("progress", "best_distance", 0.0)))


func _save_progress() -> void:
	var config := ConfigFile.new()
	config.set_value("progress", "roadside_stamps", roadside_stamps)
	config.set_value("progress", "best_distance", maxf(best_distance, trip_distance))
	var error := config.save(SAVE_PATH)
	if error != OK:
		push_warning("Could not save Cozy Roads progress: %s" % error_string(error))


func _exit_tree() -> void:
	_save_progress()


func _add_road_test_segment(from: Vector3, to: Vector3, width: float) -> void:
	var direction := to - from
	var distance := direction.length()
	var rotation := _road_basis(direction)
	var surface_normal := rotation.y
	var perpendicular := rotation.x
	var midpoint := (from + to) * 0.5 + surface_normal * 0.09

	for side in [-1.0, 1.0]:
		var edge_position: Vector3 = (
			midpoint
			+ perpendicular * width * 0.43 * side
			+ surface_normal * 0.035
		)
		var edge_basis := rotation * Basis.from_scale(Vector3(0.12, 0.025, distance + 0.08))
		curved_road_edge_transforms.append(Transform3D(edge_basis, edge_position))
	if curved_road_dash_index % 2 == 0:
		var dash_position := midpoint + surface_normal * 0.045
		var dash_basis := (
			rotation
			* Basis.from_scale(Vector3(0.10, 0.026, minf(2.5, distance * 0.72)))
		)
		curved_road_dash_transforms.append(Transform3D(dash_basis, dash_position))
	curved_road_dash_index += 1

	# Small emissive studs suggest retroreflectors catching the headlights.
	var stud_count := maxi(2, int(distance / 3.2))
	for stud_index in stud_count + 1:
		var t := float(stud_index) / float(stud_count)
		for side in [-1.0, 1.0]:
			var stud_position: Vector3 = (
				from.lerp(to, t)
				+ perpendicular * width * 0.43 * side
				+ surface_normal * 0.15
			)
			_add_road_reflector(stud_position, rotation.get_euler(), false)


func _finish_curved_road_batches() -> void:
	var unit_box := BoxMesh.new()
	unit_box.size = Vector3.ONE
	_add_route_ribbon(
		"ScenicHillTerrain",
		72.0,
		0.0,
		_material(Color("18241f"))
	)
	_add_route_ribbon(
		"CurvedRoadShoulders",
		ROAD_WIDTH + 2.4,
		0.100,
		_material(Color("493f37"))
	)
	_add_route_ribbon(
		"CurvedRoadSurface",
		ROAD_WIDTH,
		0.115,
		_material(Color("363a3c"))
	)
	_add_road_multimesh("CurvedRoadEdges", unit_box, curved_road_edge_transforms, _material(WHITE))
	_add_road_multimesh("CurvedRoadDashes", unit_box, curved_road_dash_transforms, _material(WHITE))


func _add_route_ribbon(
	node_name: String,
	width: float,
	normal_offset: float,
	material: Material
) -> void:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = MeshFactory.ribbon(
		scenic_route_points,
		width,
		normal_offset
	)
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)


func _add_road_multimesh(
	node_name: String,
	mesh: Mesh,
	transforms: Array[Transform3D],
	material: Material
) -> void:
	if transforms.is_empty():
		return
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for index in transforms.size():
		multimesh.set_instance_transform(index, transforms[index])
	multimesh.custom_aabb = AABB(Vector3(-75.0, -3.0, -430.0), Vector3(150.0, 18.0, 475.0))
	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = multimesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)


func _add_road_reflector(position_3d: Vector3, rotation_3d: Vector3, amber: bool) -> void:
	if not is_instance_valid(white_reflector_material):
		white_reflector_material = _emissive_material(Color("bcc9cb"), Color("d8f3ff"), 0.72, 0.42)
		amber_reflector_material = _emissive_material(Color("b77b3d"), Color("ffb65f"), 0.64, 0.46)
	if not is_instance_valid(road_reflector_mesh):
		road_reflector_mesh = MeshFactory.beveled_box(Vector3(0.15, 0.055, 0.24), 0.018)
	var reflector_transform := Transform3D(Basis.from_euler(rotation_3d), position_3d)
	if amber:
		amber_reflector_transforms.append(reflector_transform)
	else:
		white_reflector_transforms.append(reflector_transform)


func _finish_road_reflectors() -> void:
	_add_reflector_multimesh("WhiteRoadStuds", white_reflector_transforms, white_reflector_material)
	_add_reflector_multimesh("AmberRoadStuds", amber_reflector_transforms, amber_reflector_material)


func _add_reflector_multimesh(node_name: String, transforms: Array[Transform3D], material: Material) -> void:
	if transforms.is_empty():
		return
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = road_reflector_mesh
	multimesh.instance_count = transforms.size()
	for index in transforms.size():
		multimesh.set_instance_transform(index, transforms[index])
	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = multimesh
	instance.material_override = material
	add_child(instance)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var objective_panel := PanelContainer.new()
	objective_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	objective_panel.offset_left = 20.0
	objective_panel.offset_top = 20.0
	objective_panel.offset_right = 470.0
	objective_panel.offset_bottom = 112.0
	objective_panel.add_theme_stylebox_override("panel", _hud_panel_style())
	layer.add_child(objective_panel)
	var objective_stack := VBoxContainer.new()
	objective_stack.add_theme_constant_override("separation", 5)
	objective_panel.add_child(objective_stack)
	drive_status_label = Label.new()
	drive_status_label.text = "20:30  NIGHT   •   TRIP 0.00 km   •   STAMPS 0"
	drive_status_label.add_theme_font_size_override("font_size", 13)
	drive_status_label.add_theme_color_override("font_color", Color("aab5b7"))
	objective_stack.add_child(drive_status_label)
	objective_label = Label.new()
	objective_label.text = "ROADSIDE DINER"
	objective_label.add_theme_font_size_override("font_size", 19)
	objective_label.add_theme_color_override("font_color", Color("f2d09a"))
	objective_stack.add_child(objective_label)
	route_progress_bar = ProgressBar.new()
	route_progress_bar.custom_minimum_size = Vector2(410.0, 7.0)
	route_progress_bar.max_value = 100.0
	route_progress_bar.show_percentage = false
	var progress_background := StyleBoxFlat.new()
	progress_background.bg_color = Color("252d31")
	progress_background.corner_radius_top_left = 3
	progress_background.corner_radius_top_right = 3
	progress_background.corner_radius_bottom_left = 3
	progress_background.corner_radius_bottom_right = 3
	var progress_fill := StyleBoxFlat.new()
	progress_fill.bg_color = Color("d7945e")
	progress_fill.corner_radius_top_left = 3
	progress_fill.corner_radius_top_right = 3
	progress_fill.corner_radius_bottom_left = 3
	progress_fill.corner_radius_bottom_right = 3
	route_progress_bar.add_theme_stylebox_override("background", progress_background)
	route_progress_bar.add_theme_stylebox_override("fill", progress_fill)
	objective_stack.add_child(route_progress_bar)

	var speed_panel := PanelContainer.new()
	speed_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	speed_panel.offset_left = 20.0
	speed_panel.offset_top = -105.0
	speed_panel.offset_right = 190.0
	speed_panel.offset_bottom = -20.0
	speed_panel.add_theme_stylebox_override("panel", _hud_panel_style(Color(0.035, 0.04, 0.045, 0.86)))
	layer.add_child(speed_panel)
	var speed_stack := VBoxContainer.new()
	speed_stack.add_theme_constant_override("separation", -2)
	speed_panel.add_child(speed_stack)
	speed_value_label = Label.new()
	speed_value_label.text = "P  00"
	speed_value_label.add_theme_font_size_override("font_size", 34)
	speed_value_label.add_theme_color_override("font_color", WHITE)
	speed_stack.add_child(speed_value_label)
	speed_detail_label = Label.new()
	speed_detail_label.text = "KM/H   •   STEERING +0°"
	speed_detail_label.add_theme_font_size_override("font_size", 11)
	speed_detail_label.add_theme_color_override("font_color", Color("aab5b7"))
	speed_stack.add_child(speed_detail_label)

	var performance_panel := PanelContainer.new()
	performance_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	performance_panel.offset_left = -205.0
	performance_panel.offset_top = 20.0
	performance_panel.offset_right = -20.0
	performance_panel.offset_bottom = 55.0
	performance_panel.add_theme_stylebox_override(
		"panel",
		_hud_panel_style(Color(0.035, 0.04, 0.045, 0.68), 8.0, 10.0, 6.0)
	)
	layer.add_child(performance_panel)
	performance_label = Label.new()
	performance_label.text = "-- FPS   •   FAST AO"
	performance_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	performance_label.add_theme_font_size_override("font_size", 12)
	performance_label.add_theme_color_override("font_color", Color("aab5b7"))
	performance_panel.add_child(performance_label)

	controls_panel = PanelContainer.new()
	controls_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	controls_panel.offset_left = -280.0
	controls_panel.offset_top = -47.0
	controls_panel.offset_right = 280.0
	controls_panel.offset_bottom = -16.0
	controls_panel.add_theme_stylebox_override(
		"panel",
		_hud_panel_style(Color(0.035, 0.04, 0.045, 0.62), 8.0, 10.0, 4.0)
	)
	layer.add_child(controls_panel)
	var controls_label := Label.new()
	controls_label.text = "WASD DRIVE   •   LMB ORBIT   •   R RESET   •   T TIME   •   M AUDIO"
	controls_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	controls_label.add_theme_font_size_override("font_size", 12)
	controls_label.add_theme_color_override("font_color", Color("c3cbca"))
	controls_panel.add_child(controls_label)

	toast_panel = PanelContainer.new()
	toast_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	toast_panel.offset_left = -275.0
	toast_panel.offset_top = 116.0
	toast_panel.offset_right = 275.0
	toast_panel.offset_bottom = 158.0
	toast_panel.add_theme_stylebox_override(
		"panel",
		_hud_panel_style(Color(0.12, 0.085, 0.055, 0.92), 10.0, 14.0, 8.0)
	)
	toast_panel.visible = false
	layer.add_child(toast_panel)
	toast_label = Label.new()
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.add_theme_font_size_override("font_size", 15)
	toast_label.add_theme_color_override("font_color", Color("ffe2aa"))
	toast_panel.add_child(toast_label)


func _hud_panel_style(
	background := Color(0.035, 0.04, 0.045, 0.78),
	radius := 10.0,
	horizontal_margin := 14.0,
	vertical_margin := 10.0
) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	var rounded := roundi(radius)
	style.corner_radius_top_left = rounded
	style.corner_radius_top_right = rounded
	style.corner_radius_bottom_left = rounded
	style.corner_radius_bottom_right = rounded
	style.content_margin_left = horizontal_margin
	style.content_margin_right = horizontal_margin
	style.content_margin_top = vertical_margin
	style.content_margin_bottom = vertical_margin
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = Color(0.72, 0.78, 0.77, 0.10)
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.24)
	style.shadow_size = 5
	return style


func _add_static_box(node_name: String, size: Vector3, position_3d: Vector3, color: Color, collision: bool) -> void:
	var body := StaticBody3D.new()
	body.name = node_name
	body.position = position_3d
	add_child(body)
	var mesh := MeshInstance3D.new()
	if node_name == "Boundary":
		mesh.mesh = MeshFactory.beveled_box(size, 0.075)
	else:
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


func _add_static_box_rotated(
	node_name: String,
	size: Vector3,
	position_3d: Vector3,
	rotation_3d: Vector3,
	color: Color,
	collision: bool,
	bevel: float
) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.position = position_3d
	body.rotation = rotation_3d
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	_add_mesh_box_child(body, node_name + "Visual", size, Vector3.ZERO, _material(color), bevel)
	if collision:
		var collision_shape := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		collision_shape.shape = shape
		body.add_child(collision_shape)
	return body


func _add_mesh_box_child(
	parent: Node3D,
	node_name: String,
	size: Vector3,
	local_position: Vector3,
	material: Material,
	bevel: float,
	local_rotation := Vector3.ZERO
) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.name = node_name
	mesh.mesh = MeshFactory.beveled_box(size, bevel)
	mesh.material_override = material
	mesh.position = local_position
	mesh.rotation = local_rotation
	parent.add_child(mesh)
	return mesh


func _add_mesh_box_world(
	node_name: String,
	size: Vector3,
	position_3d: Vector3,
	rotation_3d: Vector3,
	material: Material,
	bevel: float
) -> MeshInstance3D:
	return _add_mesh_box_child(self, node_name, size, position_3d, material, bevel, rotation_3d)


func _add_emissive_box(
	node_name: String,
	size: Vector3,
	position_3d: Vector3,
	rotation_3d: Vector3,
	color: Color,
	emission_color: Color,
	emission_energy: float
) -> MeshInstance3D:
	return _add_mesh_box_world(
		node_name,
		size,
		position_3d,
		rotation_3d,
		_emissive_material(color, emission_color, emission_energy, 0.38),
		minf(0.055, minf(size.x, minf(size.y, size.z)) * 0.18)
	)


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.92
	return material


func _emissive_material(color: Color, emission_color: Color, emission_energy: float, roughness: float) -> StandardMaterial3D:
	var material := _material(color)
	material.roughness = roughness
	material.emission_enabled = true
	material.emission = emission_color
	material.emission_energy_multiplier = emission_energy
	return material
