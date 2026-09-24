class_name UiKit
extends RefCounted

## 全代码 UI 的共用样式工具集。
##
## 为什么要有它：本工程所有面板（说明书 / 任务 / 图鉴 / 背包 / 合成台 / 储物箱 /
## 地图）都在 GDScript 里现场搭节点，之前每处各写一份关闭按钮配色与底图，
## 改一处就要记得改动另外六处（已经发生过两次「只有预览弹窗透明」的错位）。
## 这里把样式收成单一来源，改一次全局生效。
##
## 只放「跨面板复用」的样式；单个面板自己的调色板仍留在各自脚本里。


## 关闭字形 ✕ 的三态颜色：常规偏暗红、悬停提亮、按下压暗。
const CLOSE_COLOR := Color(0.85, 0.22, 0.20)
const CLOSE_HOVER_COLOR := Color(1.0, 0.35, 0.32)
const CLOSE_PRESSED_COLOR := Color(0.70, 0.15, 0.14)

## 关闭按钮默认字号。
const DEFAULT_CLOSE_SIZE := 22


## 造一枚 ✕ 关闭按钮：底色四态全透明，只留字形，视觉上像直接贴在窗面上。
##
## 调用方按需接线 pressed、再用 set_anchors_and_offsets_preset 或放进容器摆位。
## 想让 ✕ 跟随窗体的文字色（而非红色）时，用 add_theme_color_override 覆盖
## "font_color" 即可，底图仍是透明的。
static func make_close(font_size: int = DEFAULT_CLOSE_SIZE) -> Button:
	var btn := Button.new()
	btn.text = "✕"
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", font_size)
	btn.add_theme_color_override("font_color", CLOSE_COLOR)
	btn.add_theme_color_override("font_hover_color", CLOSE_HOVER_COLOR)
	btn.add_theme_color_override("font_pressed_color", CLOSE_PRESSED_COLOR)
	apply_transparent(btn)
	return btn


## 把按钮底图换成空 StyleBox：normal / hover / pressed / disabled / focus 全覆盖。
##
## focus 必须一并清——Godot 默认给聚焦态描一圈内边框，只改 normal~pressed 的话
## 键盘聚焦时仍会冒出一圈与窗体不同色的线。
static func apply_transparent(button: Button) -> void:
	var empty := StyleBoxEmpty.new()
	empty.content_margin_left = 8.0
	empty.content_margin_right = 8.0
	empty.content_margin_top = 2.0
	empty.content_margin_bottom = 2.0
	button.add_theme_stylebox_override("normal", empty)
	button.add_theme_stylebox_override("hover", empty)
	button.add_theme_stylebox_override("pressed", empty)
	button.add_theme_stylebox_override("disabled", empty)
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
