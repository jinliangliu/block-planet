extends Node
## 统一音效层（M9 音效/粒子反馈）：全工程唯一的一般性音效出口。
##
## 为什么程序化合成而不放音频资产：
##   · 包体 0 增量——本工程此前零音频文件，中低端 Android 的 APK 体积是硬约束；
##   · 音效是「操作有没有被听见」的反馈，不是音乐，正弦/方波/三角/噪声四族
##     加包络已足够区分事件；
##   · 沿用 D-034 AlertBeeper 已验证的容错范式：无头环境 / 无声卡时 AudioServer
##     为 dummy，play() 静默成功，绝不影响游戏逻辑与探针。
##
## 与 AlertBeeper 的分工（刻意不合并）：
##   · `scripts/flight/alert_beeper.gd` = **飞行告警码**：可变音高序列、由
##     FlightInstruments 的边沿/节奏驱动、带 user://voice 采样覆写接口；
##   · 本类 = **通用短音效**：预渲染成 AudioStreamWAV 后缓存，播放器池多路并发，
##     不受单缓冲队列的串行限制。
##   两者互不引用、互不改动。
##
## 三条设计约束：
##   1. **零侵入**：不往任何系统里插调用，只监听 Events 总线既有信号；
##   2. **无头安全**：渲染是纯内存运算，不依赖真实音频设备；
##   3. **不污染存档**（D-010）：读档缺省**不写盘**，只有玩家真的拨了开关
##      才落 user://audio.json。探针跑完不会多出这个文件。

## 输出采样率：音效最长的「胜利」也只有 0.5 s 量级，22.05 kHz 足够且省内存。
const MIX_RATE := 22050
## 播放器池大小：同帧可能并发（破坏方块 + 拾取 + 受击），8 路足够且极廉价。
const POOL_SIZE := 8
## 主音量缺省：儿童向偏轻，避免惊吓。
const VOLUME_DEFAULT := 0.7
const SAVE_PATH := "user://audio.json"
## 同一音效的最小重复间隔（秒）：连挖方块时防止音频糊成一片。
const MIN_GAP := 0.045
## 音符包络的起音长度（秒）：3 ms 淡入防爆音。
const FADE_SEC := 0.003
## 16 bit PCM 的满幅（留 2.5% 余量，防硬削波）。
const PEAK := 31200.0

const WAVE_SIN := "sin"
const WAVE_SQUARE := "square"
const WAVE_TRI := "tri"
const WAVE_NOISE := "noise"

## 音色表。每个条目：
##   notes —— 音符序列 [{freq, dur, wait?}]，wait 为本音符**之前**的静默秒数；
##   wave  —— WAVE_* 四族之一；
##   vol   —— 该音效的相对音量（0~1，已乘进波形，播放时只再乘主音量）。
## freq 对噪声无意义；dur 为发声时长（不含 wait）。
const CUES := {
	# —— 建造与生产 ——
	"block_break": {
		"notes": [{"freq": 150.0, "dur": 0.085}, {"freq": 96.0, "dur": 0.07, "wait": 0.018}],
		"wave": WAVE_NOISE, "vol": 0.55,
	},
	"block_place": {
		"notes": [{"freq": 210.0, "dur": 0.055}, {"freq": 148.0, "dur": 0.05, "wait": 0.012}],
		"wave": WAVE_TRI, "vol": 0.5,
	},
	"craft_done": {
		"notes": [{"freq": 660.0, "dur": 0.075}, {"freq": 990.0, "dur": 0.11, "wait": 0.055}],
		"wave": WAVE_SIN, "vol": 0.55,
	},
	"smelt_done": {
		"notes": [{"freq": 520.0, "dur": 0.05}, {"freq": 780.0, "dur": 0.16, "wait": 0.035}],
		"wave": WAVE_SIN, "vol": 0.5,
	},
	# —— 即时反馈 ——
	"pickup": {
		"notes": [{"freq": 880.0, "dur": 0.045}, {"freq": 1245.0, "dur": 0.055, "wait": 0.028}],
		"wave": WAVE_SIN, "vol": 0.38,
	},
	"hurt": {
		"notes": [{"freq": 132.0, "dur": 0.15}],
		"wave": WAVE_SQUARE, "vol": 0.5,
	},
	"mob_killed": {
		"notes": [{"freq": 430.0, "dur": 0.055}, {"freq": 262.0, "dur": 0.095, "wait": 0.02}],
		"wave": WAVE_TRI, "vol": 0.48,
	},
	"ui_click": {
		"notes": [{"freq": 1240.0, "dur": 0.028}],
		"wave": WAVE_SIN, "vol": 0.3,
	},
	# —— 垂钓（全游戏唯一「不听不看就会失败」的时刻，给双响提醒）——
	"fish_bite": {
		"notes": [
			{"freq": 660.0, "dur": 0.07},
			{"freq": 660.0, "dur": 0.07, "wait": 0.045},
			{"freq": 990.0, "dur": 0.1, "wait": 0.045},
		],
		"wave": WAVE_SIN, "vol": 0.62,
	},
	# —— 竞速 ——
	"race_beep": {
		"notes": [{"freq": 528.0, "dur": 0.12}],
		"wave": WAVE_SIN, "vol": 0.5,
	},
	"race_go": {
		"notes": [{"freq": 1056.0, "dur": 0.26}],
		"wave": WAVE_SIN, "vol": 0.6,
	},
	"race_checkpoint": {
		"notes": [{"freq": 1046.0, "dur": 0.05}],
		"wave": WAVE_SIN, "vol": 0.35,
	},
	"race_lap": {
		"notes": [{"freq": 784.0, "dur": 0.07}, {"freq": 1046.0, "dur": 0.12, "wait": 0.05}],
		"wave": WAVE_SIN, "vol": 0.55,
	},
	"race_win": {
		"notes": [
			{"freq": 523.0, "dur": 0.1},
			{"freq": 659.0, "dur": 0.1, "wait": 0.085},
			{"freq": 784.0, "dur": 0.1, "wait": 0.085},
			{"freq": 1046.0, "dur": 0.24, "wait": 0.085},
		],
		"wave": WAVE_SIN, "vol": 0.6,
	},
}

var _pool: Array[AudioStreamPlayer] = []
var _pool_cursor := 0
var _cache: Dictionary = {}
var _last_play: Dictionary = {}
var _enabled := true
var _volume := VOLUME_DEFAULT


func _ready() -> void:
	_load()
	_build_pool()
	_connect_events()


## 播放一条音效。cue 为 CUES 的键；未收录的键静默忽略（不报错，便于渐进接入）。
## pitch 可做微小随机化避免重复音听出机械感（1.0 = 原调）。
func play(cue: String, pitch: float = 1.0) -> void:
	if not _enabled or _volume <= 0.0:
		return
	var stream: AudioStreamWAV = _cache.get(cue)
	if stream == null:
		var def: Dictionary = CUES.get(cue, {})
		if def.is_empty():
			return
		stream = _render(def)
		if stream == null:
			return
		_cache[cue] = stream
	# 同一音效连发节流（连挖方块 / 连捡掉落物时防止糊成一片）。
	var now := Time.get_ticks_msec()
	var last := int(_last_play.get(cue, -100000))
	if now - last < int(MIN_GAP * 1000.0):
		return
	_last_play[cue] = now
	if _pool.is_empty():
		return
	_pool_cursor = (_pool_cursor + 1) % _pool.size()
	var player := _pool[_pool_cursor]
	player.stream = stream
	player.pitch_scale = pitch
	player.volume_db = linear_to_db(maxf(_volume, 0.001))
	player.play()


## 主开关（设置面板「音效」行）。
func set_enabled(on: bool) -> void:
	if _enabled == on:
		return
	_enabled = on
	_save()


func is_enabled() -> bool:
	return _enabled


## 主音量（0~1）。
func set_volume(v: float) -> void:
	var clamped := clampf(v, 0.0, 1.0)
	if is_equal_approx(_volume, clamped):
		return
	_volume = clamped
	_save()


func volume() -> float:
	return _volume


## 已收录的音效键（探针/设置面板可枚举，不依赖硬编码字符串表）。
func cue_names() -> Array[String]:
	var out: Array[String] = []
	for key: Variant in CUES.keys():
		out.append(String(key))
	return out


func _build_pool() -> void:
	for i in POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.bus = "Master"
		add_child(player)
		_pool.append(player)


## 监听 Events 总线上**已有**的信号——这是本层零侵入的关键：
## 各系统一行都不用改，只要它已经在发信号，就自动有声音。
func _connect_events() -> void:
	Events.block_broken.connect(_on_block_broken)
	Events.block_placed.connect(_on_block_placed)
	Events.craft_done.connect(_on_craft_done)
	Events.smelt_done.connect(_on_smelt_done)
	Events.mob_killed.connect(_on_mob_killed)
	Events.race_record_beaten.connect(_on_race_record_beaten)
	Events.race_finished.connect(_on_race_finished)
	Events.item_picked.connect(_on_item_picked)
	Events.player_hurt.connect(_on_player_hurt)
	Events.fish_hooked.connect(_on_fish_hooked)


func _on_block_broken(_block_id: int, _cell: Vector3i) -> void:
	# 轻微随机音高：同一把镐连挖 20 下不会听成机械循环。
	play("block_break", randf_range(0.92, 1.08))


func _on_block_placed(_block_id: int, _cell: Vector3i) -> void:
	play("block_place", randf_range(0.94, 1.06))


func _on_craft_done(_item_id: int) -> void:
	play("craft_done")


func _on_smelt_done(_item_id: int) -> void:
	play("smelt_done")


func _on_mob_killed(_mob_type: int) -> void:
	play("mob_killed", randf_range(0.95, 1.05))


func _on_race_record_beaten(_track_id: String, _record_type: String) -> void:
	play("race_win")


func _on_race_finished(_track_id: String, _vehicle_id: String, rank: int, _laps: int,
		_best_lap: float, _total_time: float, _clean: bool) -> void:
	# 夺冠吹号角；其余名次给完圈双音——**任何一种名次都有正向收尾音**，
	# 失败不惩罚是儿童向的硬要求（不能让最后一名听到「失败音」）。
	if rank == 1:
		play("race_win")
	else:
		play("race_lap")


func _on_item_picked(_item_id: int, _count: int) -> void:
	# 拾取是高频事件（挖一片石头会连捡），音高微升让连捡听成上行小琶音而非噪音。
	play("pickup", randf_range(1.0, 1.12))


func _on_player_hurt(_amount: int) -> void:
	play("hurt")


func _on_fish_hooked() -> void:
	play("fish_bite")


## 把一条 cue 渲染成 AudioStreamWAV（16 bit 单声道）。结果被 play() 缓存，
## 每条音效全生命周期只渲染一次。
func _render(def: Dictionary) -> AudioStreamWAV:
	var notes: Array = def.get("notes", [])
	if notes.is_empty():
		return null
	var wave := String(def.get("wave", WAVE_SIN))
	var vol := float(def.get("vol", 0.5))
	var mix := float(MIX_RATE)
	var total := 0.0
	for note: Dictionary in notes:
		total += float(note.get("wait", 0.0)) + float(note.get("dur", 0.08))
	var frames := int(ceil(total * mix))
	if frames <= 0:
		return null
	var acc := PackedFloat32Array()
	acc.resize(frames)
	var cursor := 0
	var fade := maxi(int(mix * FADE_SEC), 1)
	var rng := RandomNumberGenerator.new()
	# 固定种子：同一条音效每次都完全一致（探针可比对，听感也稳定）。
	rng.seed = 20261031
	for note: Dictionary in notes:
		cursor += int(float(note.get("wait", 0.0)) * mix)
		var freq := float(note.get("freq", 600.0))
		var n := int(float(note.get("dur", 0.08)) * mix)
		if n <= 0:
			continue
		var phase := 0.0
		var inc := TAU * freq / mix
		for j in n:
			var idx := cursor + j
			if idx < 0 or idx >= frames:
				break
			var t := float(j) / float(n)
			var env := _envelope(t, j, n, fade)
			var v := 0.0
			match wave:
				WAVE_SQUARE:
					v = 1.0 if sin(phase) >= 0.0 else -1.0
				WAVE_TRI:
					v = 4.0 * absf(phase / TAU - 0.5) - 1.0
				WAVE_NOISE:
					v = rng.randf_range(-1.0, 1.0)
				_:
					v = sin(phase)
			acc[idx] = v * env * vol
			phase = fposmod(phase + inc, TAU)
		cursor += n
	var data := PackedByteArray()
	data.resize(frames * 2)
	for i in frames:
		data.encode_s16(i * 2, int(round(clampf(acc[i], -1.0, 1.0) * PEAK)))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = MIX_RATE
	stream.stereo = false
	stream.data = data
	return stream


## 简包络：起音线性淡入 + 指数衰减到 0（避免方波/噪声尾巴突然截断的「咔」）。
func _envelope(t: float, j: int, n: int, fade: int) -> float:
	var attack := 1.0
	if j < fade:
		attack = float(j) / float(fade)
	elif j > n - fade:
		attack = float(maxi(n - j, 0)) / float(fade)
	return attack * pow(1.0 - t, 1.6)


## 读档：缺省即默认值，**不写盘**（D-010：探针不能留下新文件）。
func _load() -> void:
	_enabled = true
	_volume = VOLUME_DEFAULT
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return
	var raw := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		return
	var data: Dictionary = parsed
	_enabled = bool(data.get("enabled", true))
	_volume = clampf(float(data.get("volume", VOLUME_DEFAULT)), 0.0, 1.0)


func _save() -> void:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({"enabled": _enabled, "volume": _volume}, "\t"))
	file.close()
