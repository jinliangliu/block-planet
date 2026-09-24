extends Control
class_name VirtualJoystick
## 移动端左侧虚拟摇杆。返回归一化的 Vector2，+Y 表示向前（摇杆上推）。

signal value_changed(value: Vector2)

@export var radius := 60.0
@export var knob_radius := 22.0
@export var deadzone := 0.12

var _value := Vector2.ZERO
var _touch_index := -1
var _center := Vector2.ZERO
var _knob_pos := Vector2.ZERO


func _ready() -> void:
	custom_minimum_size = Vector2(radius * 2.0 + 24.0, radius * 2.0 + 24.0)
	_center = custom_minimum_size / 2.0
	_knob_pos = _center
	mouse_filter = Control.MOUSE_FILTER_STOP
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed and _touch_index == -1:
			_touch_index = event.index
			_update_from_screen_pos(event.position)
		elif not event.pressed and event.index == _touch_index:
			_touch_index = -1
			_set_value(Vector2.ZERO)
	elif event is InputEventScreenDrag and event.index == _touch_index:
		_update_from_screen_pos(event.position)


func _update_from_screen_pos(pos: Vector2) -> void:
	var clamped := (pos - _center).limit_length(radius)
	_knob_pos = _center + clamped
	_set_value(clamped / radius)
	queue_redraw()


func _set_value(value: Vector2) -> void:
	if value.length() < deadzone:
		value = Vector2.ZERO
	if value != _value:
		_value = value
		value_changed.emit(_value)


func _draw() -> void:
	draw_circle(_center, radius, Color(1.0, 1.0, 1.0, 0.12))
	draw_arc(_center, radius, 0.0, TAU, 48, Color(1.0, 1.0, 1.0, 0.35), 2.0)
	draw_circle(_knob_pos, knob_radius, Color(1.0, 1.0, 1.0, 0.5))

