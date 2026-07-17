class_name CozySoundscape
extends Node

var target: CozyCar
var time_of_day_hours := 20.5

var road_mix := 0.0
var wind_mix := 0.0
var night_mix := 0.0
var day_mix := 0.0

var audio_player: AudioStreamPlayer
var playback: AudioStreamGeneratorPlayback
var _random := RandomNumberGenerator.new()
var _road_low := 0.0
var _wind_low_left := 0.0
var _wind_low_right := 0.0
var _wind_mid_left := 0.0
var _wind_mid_right := 0.0
var _insect_carrier_phase := 0.0
var _insect_pulse_phase := 0.0
var _insect_cluster_phase := 0.0
var _bird_timer := 2.0
var _bird_age := 0.0
var _bird_duration := 0.0
var _bird_phase := 0.0
var _chime_age := 2.0
var _chime_frequency := 620.0
var _chime_phase := 0.0
var _chime_upper_phase := 0.0

const MIX_RATE := 22050.0


func _ready() -> void:
	_random.seed = 24071987
	audio_player = AudioStreamPlayer.new()
	audio_player.name = "ProceduralRoadAndNature"
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = MIX_RATE
	generator.buffer_length = 0.28
	audio_player.stream = generator
	audio_player.volume_db = -4.5
	add_child(audio_player)
	audio_player.play()
	playback = audio_player.get_stream_playback() as AudioStreamGeneratorPlayback


func _exit_tree() -> void:
	playback = null
	if is_instance_valid(audio_player):
		audio_player.stop()
		audio_player.stream = null


func _process(delta: float) -> void:
	var speed_ratio := 0.0
	if is_instance_valid(target):
		speed_ratio = clampf(absf(target.speed) / CozyCar.MAX_FORWARD_SPEED, 0.0, 1.0)
	var road_target := pow(speed_ratio, 0.82)
	if is_instance_valid(target) and not target.is_on_floor():
		road_target *= 0.15
	var wind_target := smoothstep(0.20, 1.0, speed_ratio)
	road_mix = lerpf(road_mix, road_target, 1.0 - exp(-4.8 * delta))
	wind_mix = lerpf(wind_mix, wind_target, 1.0 - exp(-2.4 * delta))

	var evening := smoothstep(18.4, 20.6, time_of_day_hours)
	var morning := 1.0 - smoothstep(4.8, 7.2, time_of_day_hours)
	var night_target := maxf(evening, morning)
	night_mix = lerpf(night_mix, night_target, 1.0 - exp(-1.4 * delta))
	day_mix = lerpf(day_mix, 1.0 - night_target, 1.0 - exp(-1.0 * delta))
	_fill_audio_buffer()


func set_time_of_day(hours: float) -> void:
	time_of_day_hours = fposmod(hours, 24.0)


func play_progress_chime(frequency := 620.0) -> void:
	_chime_frequency = frequency
	_chime_age = 0.0
	_chime_phase = 0.0
	_chime_upper_phase = 0.0


func _fill_audio_buffer() -> void:
	if not is_instance_valid(playback):
		return
	var frames_available := playback.get_frames_available()
	var sample_delta := 1.0 / MIX_RATE
	for _frame in frames_available:
		var road_noise := _random.randf_range(-1.0, 1.0)
		_road_low = lerpf(_road_low, road_noise, 0.18)
		var road_texture := (road_noise - _road_low) * 0.018 * road_mix
		road_texture += _road_low * 0.008 * road_mix

		var wind_noise_left := _random.randf_range(-1.0, 1.0)
		var wind_noise_right := _random.randf_range(-1.0, 1.0)
		_wind_low_left = lerpf(_wind_low_left, wind_noise_left, 0.006)
		_wind_low_right = lerpf(_wind_low_right, wind_noise_right, 0.006)
		_wind_mid_left = lerpf(_wind_mid_left, wind_noise_left, 0.045)
		_wind_mid_right = lerpf(_wind_mid_right, wind_noise_right, 0.045)
		var wind_left := (_wind_mid_left - _wind_low_left) * 0.024 * wind_mix
		var wind_right := (_wind_mid_right - _wind_low_right) * 0.024 * wind_mix

		_insect_carrier_phase = fmod(
			_insect_carrier_phase + TAU * 3650.0 * sample_delta,
			TAU
		)
		_insect_pulse_phase = fmod(_insect_pulse_phase + TAU * 7.2 * sample_delta, TAU)
		_insect_cluster_phase = fmod(_insect_cluster_phase + TAU * 0.19 * sample_delta, TAU)
		var insect_gate := pow(maxf(0.0, sin(_insect_pulse_phase)), 12.0)
		var cluster := lerpf(0.22, 1.0, smoothstep(-0.35, 0.7, sin(_insect_cluster_phase)))
		var insects := sin(_insect_carrier_phase) * insect_gate * cluster * 0.0042 * night_mix

		var bird := _next_bird_sample(sample_delta) * day_mix
		var chime := _next_chime_sample(sample_delta)
		var center := road_texture + insects + bird + chime
		playback.push_frame(
			Vector2(
				clampf(center + wind_left, -0.22, 0.22),
				clampf(center + wind_right, -0.22, 0.22)
			)
		)


func _next_bird_sample(sample_delta: float) -> float:
	if _bird_duration <= 0.0:
		_bird_timer -= sample_delta
		if _bird_timer <= 0.0:
			_bird_duration = _random.randf_range(0.28, 0.48)
			_bird_age = 0.0
			_bird_phase = 0.0
			_bird_timer = _random.randf_range(3.8, 7.2)
		return 0.0

	_bird_age += sample_delta
	var progress := clampf(_bird_age / _bird_duration, 0.0, 1.0)
	var envelope := pow(sin(progress * PI), 2.0)
	var frequency := lerpf(1450.0, 2250.0, sin(progress * PI))
	_bird_phase = fmod(_bird_phase + TAU * frequency * sample_delta, TAU)
	if _bird_age >= _bird_duration:
		_bird_duration = 0.0
	return sin(_bird_phase) * envelope * 0.0065


func _next_chime_sample(sample_delta: float) -> float:
	if _chime_age >= 1.25:
		return 0.0
	_chime_age += sample_delta
	var release := clampf((1.25 - _chime_age) / 0.18, 0.0, 1.0)
	var envelope := exp(-3.5 * _chime_age) * minf(_chime_age / 0.025, 1.0) * release
	_chime_phase = fmod(_chime_phase + TAU * _chime_frequency * sample_delta, TAU)
	_chime_upper_phase = fmod(
		_chime_upper_phase + TAU * _chime_frequency * 1.5 * sample_delta,
		TAU
	)
	var primary := sin(_chime_phase)
	var upper := sin(_chime_upper_phase) * 0.42
	return (primary + upper) * envelope * 0.024
