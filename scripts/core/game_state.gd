extends Node
## 全局游戏状态（Autoload 单例，随应用存续）。
## 维护生存/创造模式；后续可扩展存档与设置。

enum Mode {
	SURVIVAL,
	CREATIVE,
}

signal mode_changed(mode: int)

var mode: Mode = Mode.SURVIVAL


func is_creative() -> bool:
	return mode == Mode.CREATIVE


func is_survival() -> bool:
	return mode == Mode.SURVIVAL


func set_mode(value: Mode) -> void:
	if value == mode:
		return
	mode = value
	mode_changed.emit(mode)
