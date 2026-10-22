extends Control
class_name SpawnLoading
## 出生加载屏（D-064，128 km 大世界 P2）。
##
## 为什么需要它：高模环半径 4（9×9 = 81 区块），冷启动实测单块 41 ms、整环
## ≈3.3 s。这段时间如果直接把玩家丢进世界，会看到地面一块块蹦出来、帧率个位数。
## 加载屏期间 World 走 bootstrap 预算（每帧 4 块），把环尽快填满——屏幕上只有
## 一块进度条，帧率低也看不出来。
##
## 自驱动：自己 `_process` 轮询 `World.ring_fill_ratio()`，填满（或超时兜底）后
## 淡出并自毁，不占用 Main 的帧回调。鼠标穿透，不拦截任何输入。
## 无头环境由 Main 直接不创建（探针不会看到它）。

const FADE_TIME := 0.35
## 兜底上限：万一某个区域的地形生成异常慢，也不能让玩家永远卡在黑屏上。
const MAX_WAIT := 8.0
const BAR_W := 520.0
const BAR_H := 12.0

## 与设置面板同一套纸质配色（D-057），保持 UI 语言一致。
const PANEL_BG := Color(0.95, 0.92, 0.84)
const PANEL_BORDER := Color(0.62, 0.47, 0.27)
const TITLE_COLOR := Color(0.24, 0.18, 0.11)
const BODY_COLOR := Color(0.42, 0.35, 0.24)
const BAR_TRACK := Color(0.78, 0.73, 0.62)
const BAR_FILL := Color(0.36, 0.66, 0.32)

var _world: World
var _title_label: Label
var _status_label: Label
var _fill: ColorRect
var _elapsed := 0.0
var _done := false


## 挂到 HUD（CanvasLayer）下并开始轮询。region_title 只是显示用。
func begin(world: World, region_title: String) -> void:
	_world = world
	name = "SpawnLoading"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# 遮住世界：填满之前玩家不该看到半成品地形。
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.06, 0.09)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var card := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(4)
	style.set_corner_radius_all(10)
	style.content_margin_left = 36.0
	style.content_margin_right = 36.0
	style.content_margin_top = 26.0
	style.content_margin_bottom = 26.0
	card.add_theme_stylebox_override("panel", style)
	center.add_child(card)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	card.add_child(box)

	_title_label = Label.new()
	_title_label.text = region_title
	_title_label.add_theme_color_override("font_color", TITLE_COLOR)
	_title_label.add_theme_font_size_override("font_size", 30)
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_title_label)

	# 进度条：轨道 + 填充两块 ColorRect，宽度自己算——ProgressBar 的默认主题
	# 在深色遮罩上不像纸质 UI，重做主题反而更啰嗦。
	var bar_holder := Control.new()
	bar_holder.custom_minimum_size = Vector2(BAR_W, BAR_H)
	bar_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(bar_holder)

	var track := ColorRect.new()
	track.color = BAR_TRACK
	track.size = Vector2(BAR_W, BAR_H)
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_holder.add_child(track)

	_fill = ColorRect.new()
	_fill.color = BAR_FILL
	_fill.size = Vector2(0.0, BAR_H)
	_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_holder.add_child(_fill)

	_status_label = Label.new()
	_status_label.text = "正在生成地形… 0%"
	_status_label.add_theme_color_override("font_color", BODY_COLOR)
	_status_label.add_theme_font_size_override("font_size", 18)
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_status_label)


func _process(delta: float) -> void:
	if _done:
		return
	_elapsed += delta
	var ratio := 1.0 if _world == null or not is_instance_valid(_world) \
		else _world.ring_fill_ratio()
	ratio = clampf(ratio, 0.0, 1.0)
	_fill.size = Vector2(BAR_W * ratio, BAR_H)
	_status_label.text = "正在生成地形… %d%%" % int(ratio * 100.0)
	if (ratio >= 1.0) or _elapsed >= MAX_WAIT:
		_dismiss()


func _dismiss() -> void:
	_done = true
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, FADE_TIME)
	tween.tween_callback(queue_free)
