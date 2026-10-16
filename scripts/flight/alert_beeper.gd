class_name AlertBeeper
extends Node
## 警告蜂鸣码播放器（D-034）：儿童友好的「语音提示」落地形式——Godot 无
## 跨平台 TTS、工程亦无语音资产，故用程序生成音：每种警告一段固定音色
## （音高/节奏）的蜂鸣码，配屏幕文字呼号，听感可区分、零资产依赖。
##
## 预留资产接口：user:// 或 res:// 下放置 voice/<id>.wav 时优先播放采样
## （后续录制儿童友好语音后无需改代码）。
##
## 容错：无头环境 / 无声卡时 AudioServer 为 dummy，push 静默成功；
## 任何异常只关闭本节点，绝不影响飞行逻辑。

const VOICE_DIR := "user://voice"
## 主音量：蜂鸣是提示不是警报，压低音量避免惊到儿童。
const MASTER_GAIN := 0.22
## 单声道缓冲帧数：一次 push 的粒度（约 23 ms @48k）。
const CHUNK_FRAMES := 1024
## 待播队列上限：警告连发时丢弃最旧，防止缓冲区堆积。
const MAX_QUEUE := 4

var _player: AudioStreamPlayer
var _gen: AudioStreamGenerator
var _playback: AudioStreamGeneratorPlayback
var _queue: Array[PackedVector2Array] = []
var _enabled := true


func _ready() -> void:
	_player = AudioStreamPlayer.new()
	_gen = AudioStreamGenerator.new()
	_gen.mix_rate = AudioServer.get_mix_rate()
	_player.stream = _gen
	_player.volume_db = linear_to_db(MASTER_GAIN)
	add_child(_player)
	_player.play()
	_playback = _gen.instantiate_playback()
	if _playback == null:
		_enabled = false


func _process(_delta: float) -> void:
	if not _enabled or _playback == null or _queue.is_empty():
		return
	var avail := _playback.get_frames_available()
	while avail >= CHUNK_FRAMES and not _queue.is_empty():
		var buf: PackedVector2Array = _queue.pop_front()
		_playback.push_buffer(buf)
		avail -= CHUNK_FRAMES


## 播放一条蜂鸣码。beep 为 FlightInstruments.BEEP_CODES 的条目：
## {freq, dur, gap, count, alt_freq?, replay?}。重复警告由调用方去重
## （FlightInstruments.take_voice_cues 的边沿 + replay cadence）。
## beep 带 id / voice_id 时，user://voice/<id>.wav 或 res://voice/<id>.wav
## 存在则优先播放采样（后续录制儿童友好语音后无需改代码）。
func play_cue(beep: Dictionary) -> void:
	if not _enabled or _gen == null:
		return
	var id := String(beep.get("voice_id", beep.get("id", "")))
	if id != "" and _has_sample(id):
		_play_sample(id)
		return
	var samples := _render_beep(beep)
	if samples.is_empty():
		return
	if _queue.size() >= MAX_QUEUE:
		_queue.pop_front()
	_queue.append(samples)


## 把一段蜂鸣码渲染成 PackedVector2Array（每帧一个立体声 Vector2，Godot 4.6 的
## AudioStreamGeneratorPlayback.push_buffer 接口），正弦 + 10 ms 淡入淡出防爆音。
## alt_freq 存在时奇数位响声用交替音高（失速 880/620、超速 660/520 双音循环）。
func _render_beep(beep: Dictionary) -> PackedVector2Array:
	var freq := float(beep.get("freq", 600.0))
	var alt_freq := float(beep.get("alt_freq", 0.0))
	var dur := float(beep.get("dur", 0.1))
	var gap := float(beep.get("gap", 0.1))
	var count := int(beep.get("count", 1))
	var mix_rate := float(_gen.mix_rate)
	var fade := maxi(int(mix_rate * 0.01), 1)
	var on_frames := int(dur * mix_rate)
	var cycle := int((dur + gap) * mix_rate)
	var frames := cycle * count
	if frames <= 0 or on_frames <= 0:
		return PackedVector2Array()
	var buf := PackedVector2Array()
	buf.resize(frames)
	for n in count:
		var f := alt_freq if (n % 2 == 1 and alt_freq > 0.0) else freq
		var phase := 0.0
		var phase_inc := TAU * f / mix_rate
		for j in on_frames:
			var v := sin(phase)
			phase = fposmod(phase + phase_inc, TAU)
			# 淡入淡出防爆音（每响首尾各 10 ms）。
			if j < fade:
				v *= float(j) / float(fade)
			elif j > on_frames - fade:
				v *= float(maxi(on_frames - j, 0)) / float(fade)
			var i := n * cycle + j
			buf[i] = Vector2(v, v)
	return buf


func _has_sample(id: String) -> bool:
	for base in [VOICE_DIR + "/" + id + ".wav", "res://voice/" + id + ".wav"]:
		if ResourceLoader.exists(base):
			return true
	return false


func _play_sample(id: String) -> void:
	# 采样路径：独立一次性播放器，避免与蜂鸣码争用同一生成器。
	var res: Variant = load(VOICE_DIR + "/" + id + ".wav")
	if res == null:
		res = load("res://voice/" + id + ".wav")
	if res is AudioStream:
		var one := AudioStreamPlayer.new()
		one.stream = res
		one.volume_db = linear_to_db(MASTER_GAIN)
		add_child(one)
		one.play()
		one.finished.connect(one.queue_free)
