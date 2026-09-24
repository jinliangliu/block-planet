class_name BestiaryModel
extends RefCounted

## 图鉴用的 3D 模型工厂：给任意一条图鉴条目造一个可渲染的 Node3D。
##
## 为什么要有它：图鉴收录 175 种，但游戏里只有 21 个 `Mob.MobType`（真·3D 模型）。
## 剩下的上百种（孟加拉虎、银杏、海带……）如果没有造型，卡片就只能掛一个色块，
## 那跟「这里有条数据」没区别——用户要的是「每条都有微缩图、悬停都能 3D 转起来」。
##
## 于是分两路：
##   ① 游戏内物种（BestiaryData.mob_of_entry >= 0）→ 直接实例化真 Mob 模型，
##      与世界里走的那一只是同一套造型代码，永远不会被画错。
##   ② 其余 → 按「界 + 类」走程序化替身（19 个类各一套构造），颜色取 manifest
##      里的类主色，再用条目 id 的哈希做个体差异（体型/色阶/层数/细节），
##      所以同类物种也不会长成一个样。
##
## 替身不追求「和照片一模一样」，追求的是**一眼看出这是个什么门类的东西**——
## 它与剪影盒的区别是：剪影只说「这里有条数据」，替身说「这大概是棵树/一只鸟」。
##
## 所有模型（真模型也好、替身也好）出厂前都过一次 `normalize()`：把整体缩放到
## 统一的包围盒并居中，相机因此可以用固定参数取景，不用为每个物种单独调。

## 归一化后的包围盒最长边。相机按这个尺寸一次调好，之后任何物种都不再动。
const FRAME_SIZE := 1.25

## 替身模型的默认主色（万一 manifest 没给颜色时的兜底）。
const FALLBACK_COLOR := Color(0.62, 0.47, 0.27)


## 造一条条目的模型。返回值请挂进 SubViewport 后再 normalize()（需要 global_transform）。
static func build(entry: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "BestiaryModel"
	var mob_type := BestiaryData.mob_of_entry(entry)
	if mob_type >= 0:
		var mob := Mob.new()
		mob.setup(mob_type as Mob.MobType, null, null)
		root.add_child(mob)
		root.set_meta("real_mob", true)
	else:
		root.add_child(_build_stand_in(entry))
		root.set_meta("real_mob", false)
	return root


## 是否游戏内真物种（= 用了真 Mob 模型）。
static func is_real_mob(root: Node3D) -> bool:
	return bool(root.get_meta("real_mob", false))


## 藏掉名牌 Label3D：世界里它显示「牛 8/8」，图鉴里不需要血量。
static func hide_labels(root: Node3D) -> void:
	for node in _walk(root):
		if node is Label3D:
			(node as Label3D).visible = false


## 整体归一化：缩放到 FRAME_SIZE 并居中到原点。
##
## 必须在 root 已经进入场景树之后调用（依赖 global_transform），否则各部件的
## 世界变换还没算出来，包围盒会算错。
static func normalize(root: Node3D) -> void:
	var boxes: Array[AABB] = []
	_collect_boxes(root, boxes)
	if boxes.is_empty():
		return
	var box := boxes[0]
	for i in range(1, boxes.size()):
		box = box.merge(boxes[i])
	var longest := maxf(maxf(box.size.x, box.size.y), box.size.z)
	if longest <= 0.0001:
		return
	var s := FRAME_SIZE / longest
	root.scale = Vector3.ONE * s
	# 缩放后局部中心也乘了 s，把它挪回原点。
	root.position = -box.get_center() * s


# ────────────────────────────── 替身构造 ──────────────────────────────

## 按「类」分派。未知类 → 界色多面体（至少看得出来有东西，不是空场景）。
static func _build_stand_in(entry: Dictionary) -> Node3D:
	var holder := Node3D.new()
	holder.name = "StandIn"
	var seed_value := _seed_of(String(entry.get("id", "")))
	var base := _base_color(entry)
	match String(entry.get("category", "")):
		"mammal":
			_build_mammal(holder, base, seed_value)
		"bird":
			_build_bird(holder, base, seed_value)
		"reptile":
			_build_reptile(holder, base, seed_value)
		"amphibian":
			_build_amphibian(holder, base, seed_value)
		"fish":
			_build_fish(holder, base, seed_value)
		"insect":
			_build_insect(holder, base, seed_value)
		"sea_animal":
			_build_sea_animal(holder, base, seed_value)
		"tree":
			_build_tree(holder, base, seed_value)
		"shrub":
			_build_shrub(holder, base, seed_value)
		"grass":
			_build_grass(holder, base, seed_value)
		"flower":
			_build_flower(holder, base, seed_value)
		"fern":
			_build_fern(holder, base, seed_value)
		"moss":
			_build_moss(holder, base, seed_value)
		"vine":
			_build_vine(holder, base, seed_value)
		"algae":
			_build_algae(holder, base, seed_value)
		"seagrass":
			_build_seagrass(holder, base, seed_value)
		"mushroom":
			_build_mushroom(holder, base, seed_value)
		"lichen":
			_build_lichen(holder, base, seed_value)
		"mold":
			_build_mold(holder, base, seed_value)
		_:
			_build_generic(holder, _kingdom_color(entry), seed_value)
	return holder


## 主色按条目类别分两路：
##   动物走「自然毛色板」+ 哈希选色——哺乳类全是类主色（红橙）会显得千篇一律，
##   而真实动物的毛色就集中在棕/灰/白/黄褐这几档，从这里选反而更像那么回事；
##   其余（鱼/虫/植物/真菌）从类主色派生，色相、饱和、明度都按条目 id 哈希
##   各自扰动一点——同类的物种能互相区分，类与类之间仍然一眼可辨。
static func _base_color(entry: Dictionary) -> Color:
	var seed_value := _seed_of(String(entry.get("id", "")))
	var category := String(entry.get("category", ""))
	if category in ["mammal", "bird", "reptile", "amphibian", "sea_animal"]:
		var coat: Color = ANIMAL_COATS[_absd(seed_value) % ANIMAL_COATS.size()]
		var shade := 0.86 + _rand(seed_value, 303) * 0.28
		return Color(coat.r * shade, coat.g * shade, coat.b * shade)
	var base := BestiaryData.category_color(category)
	if base == Color(0.0, 0.0, 0.0):
		base = _kingdom_color(entry)
	var hue := fposmod(base.h + (_rand(seed_value, 300) - 0.5) * 0.12, 1.0)
	var sat := clampf(base.s * (0.55 + _rand(seed_value, 301) * 0.35), 0.20, 0.78)
	var val := clampf(base.v * (0.85 + _rand(seed_value, 302) * 0.5), 0.38, 0.95)
	return Color.from_hsv(hue, sat, val)


## 动物替身用的自然毛色板：棕 / 灰褐 / 白 / 黄褐 / 深灰 / 沙。哈希取色后再乘
## 一个明度系数，六档底色 × 明度扰动，足够让同类物种互不相同。
const ANIMAL_COATS: Array[Color] = [
	Color(0.55, 0.40, 0.28),
	Color(0.72, 0.66, 0.58),
	Color(0.90, 0.87, 0.80),
	Color(0.82, 0.66, 0.34),
	Color(0.38, 0.35, 0.33),
	Color(0.64, 0.57, 0.45),
]


static func _kingdom_color(entry: Dictionary) -> Color:
	var color := BestiaryData.kingdom_color(String(entry.get("kingdom", "")))
	return color if color != Color(0.0, 0.0, 0.0) else FALLBACK_COLOR


## 条目 id → 稳定的伪随机整数。同一个物种每次打开图鉴长得一样。
static func _seed_of(entry_id: String) -> int:
	return absi(entry_id.hash())


## 0.0 ~ 1.0 的确定性小数：同一个 (seed, salt) 组合永远给同一个值。
static func _rand(v: int, salt: int) -> float:
	return float(_absd(v * 31 + salt * 7919) % 1000) / 1000.0


## absi 需要在极小值上不溢出：这里用自己的确定性混合，避免 hash 结果直接参与算术
## 时出现负数取模的歧义（GDScript 的 % 对负数返回负值）。
static func _absd(value: int) -> int:
	return value if value >= 0 else -value


# ── 动物 ──────────────────────────────────────────────

## 四足兽：躯干 + 头 + 四腿 + 尾。体型按哈希浮动（鼠象之别至少有点意思）。
static func _build_mammal(root: Node3D, base: Color, seed_value: int) -> void:
	var bulk := 0.85 + _rand(seed_value, 1) * 0.35
	var body := Vector3(0.86 * bulk, 0.58 * bulk, 0.52 * bulk)
	var top := body.y * 1.35
	_box(root, body, base, Vector3(0.0, top, 0.0))
	var head_size := body.x * 0.42
	_box(root, Vector3(head_size, head_size, head_size), base.lightened(0.12),
		Vector3(0.0, top + head_size * 0.25, body.z * 0.62))
	_ears(root, base, head_size, top + head_size * 0.25, body.z * 0.62)
	_legs(root, base.darkened(0.28), Vector3(body.x * 0.34, 0.0, body.z * 0.3), top - body.y * 0.5, 4)
	# 尾巴：斜插在臀部。
	var tail := _box(root, Vector3(0.09, 0.09, body.z * 0.7), base.darkened(0.15),
		Vector3(0.0, top + body.y * 0.1, -body.z * 0.55))
	tail.rotation_degrees = Vector3(35.0, 0.0, 0.0)


## 鸟：立卵形身 + 小头 + 喙 + 双翼 + 细腿。展翼与否由哈希决定。
static func _build_bird(root: Node3D, base: Color, seed_value: int) -> void:
	var bulk := 0.9 + _rand(seed_value, 2) * 0.3
	var body_y := 0.72 * bulk
	_box(root, Vector3(0.42 * bulk, 0.46 * bulk, 0.56 * bulk), base, Vector3(0.0, body_y, 0.0))
	_box(root, Vector3(0.28 * bulk, 0.28 * bulk, 0.28 * bulk), base.lightened(0.18),
		Vector3(0.0, body_y + 0.26 * bulk, 0.24 * bulk))
	# 喙
	var beak := _box(root, Vector3(0.08, 0.08, 0.24), Color(0.86, 0.66, 0.22),
		Vector3(0.0, body_y + 0.24 * bulk, 0.44 * bulk))
	beak.rotation_degrees = Vector3(-12.0, 0.0, 0.0)
	# 翼：张开（展翼）或贴身。
	var spread := _rand(seed_value, 3) > 0.45
	for side in [-1.0, 1.0]:
		var wing := _box(root, Vector3(0.10, 0.30 * bulk, 0.52 * bulk), base.darkened(0.18),
			Vector3(side * 0.24 * bulk, body_y + 0.04, 0.0))
		wing.rotation_degrees = Vector3(0.0, 0.0, side * (28.0 if spread else 6.0))
	# 尾羽
	var tail := _box(root, Vector3(0.26, 0.05, 0.34), base.darkened(0.25),
		Vector3(0.0, body_y - 0.02, -0.38 * bulk))
	tail.rotation_degrees = Vector3(-18.0, 0.0, 0.0)
	for side in [-1.0, 1.0]:
		_box(root, Vector3(0.06, 0.30 * bulk, 0.06), Color(0.86, 0.66, 0.22),
			Vector3(side * 0.12, body_y - 0.22 * bulk, 0.02))


## 爬行类：扁平躯干 + 四条外张短腿 + 长尾。
static func _build_reptile(root: Node3D, base: Color, seed_value: int) -> void:
	var bulk := 0.9 + _rand(seed_value, 4) * 0.3
	var y := 0.26 * bulk
	_box(root, Vector3(0.52 * bulk, 0.26 * bulk, 0.92 * bulk), base, Vector3(0.0, y, 0.0))
	_box(root, Vector3(0.30 * bulk, 0.22 * bulk, 0.34 * bulk), base.lightened(0.1),
		Vector3(0.0, y + 0.05, 0.58 * bulk))
	_eyes(root, 0.055, Vector3(0.0, y + 0.10 * bulk, 0.66 * bulk), 0.10 * bulk)
	# 背脊鳞板
	for i in 3:
		_box(root, Vector3(0.16, 0.08, 0.10), base.darkened(0.3),
			Vector3(0.0, y + 0.16 * bulk, (0.3 - float(i) * 0.3) * bulk))
	# 腿：向外撇
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var leg := _box(root, Vector3(0.30, 0.10, 0.10), base.darkened(0.25),
				Vector3(sx * 0.30 * bulk, y - 0.06, sz * 0.28 * bulk))
			leg.rotation_degrees = Vector3(0.0, sx * -35.0, 0.0)
	# 尾巴：三节渐细
	for i in 3:
		var t := float(i)
		_box(root, Vector3(0.24 - t * 0.06, 0.18 - t * 0.04, 0.28), base.darkened(0.12),
			Vector3(0.0, y - 0.02, (-0.62 - t * 0.26) * bulk))


## 两栖：蹲踞身 + 大眼 + 四条折腿。
static func _build_amphibian(root: Node3D, base: Color, seed_value: int) -> void:
	var bulk := 0.95 + _rand(seed_value, 5) * 0.25
	var y := 0.34 * bulk
	_box(root, Vector3(0.56 * bulk, 0.40 * bulk, 0.52 * bulk), base, Vector3(0.0, y, 0.0))
	_box(root, Vector3(0.50 * bulk, 0.26 * bulk, 0.44 * bulk), base.lightened(0.08),
		Vector3(0.0, y + 0.24 * bulk, 0.10 * bulk))
	_eyes(root, 0.10 * bulk, Vector3(0.0, y + 0.42 * bulk, 0.16 * bulk), 0.13 * bulk)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var leg := _box(root, Vector3(0.12, 0.30 * bulk, 0.12), base.darkened(0.2),
				Vector3(sx * 0.26 * bulk, y - 0.10 * bulk, sz * 0.20 * bulk))
			leg.rotation_degrees = Vector3(sz * 30.0, 0.0, sx * -20.0)


## 鱼：纺锤身 + 尾鳍 + 背鳍 各一对胸鳍。
static func _build_fish(root: Node3D, base: Color, seed_value: int) -> void:
	var bulk := 0.9 + _rand(seed_value, 6) * 0.35
	_sphere(root, 0.26 * bulk, base, Vector3(0.0, 0.0, 0.12 * bulk))
	_box(root, Vector3(0.40 * bulk, 0.34 * bulk, 0.52 * bulk), base, Vector3(0.0, 0.0, 0.28 * bulk))
	_box(root, Vector3(0.26 * bulk, 0.22 * bulk, 0.30 * bulk), base.lightened(0.06),
		Vector3(0.0, 0.0, -0.30 * bulk))
	# 尾鳍
	var tail := _box(root, Vector3(0.06, 0.42 * bulk, 0.34 * bulk), base.darkened(0.15),
		Vector3(0.0, 0.0, -0.56 * bulk))
	tail.rotation_degrees = Vector3(0.0, 35.0, 0.0)
	# 背鳍
	var dorsal := _box(root, Vector3(0.05, 0.24 * bulk, 0.30 * bulk), base.darkened(0.1),
		Vector3(0.0, 0.22 * bulk, 0.02))
	dorsal.rotation_degrees = Vector3(0.0, 0.0, -12.0)
	# 胸鳍
	for side in [-1.0, 1.0]:
		var fin := _box(root, Vector3(0.22 * bulk, 0.06, 0.16 * bulk), base.darkened(0.18),
			Vector3(side * 0.20 * bulk, -0.02, 0.24 * bulk))
		fin.rotation_degrees = Vector3(0.0, 0.0, side * -20.0)
	_eyes(root, 0.06 * bulk, Vector3(0.0, 0.08 * bulk, 0.40 * bulk), 0.10 * bulk)


## 昆虫：头胸腹三节 + 六足 + 触角 + 半透明翅（鞘翅/膜翅由哈希决定）。
static func _build_insect(root: Node3D, base: Color, seed_value: int) -> void:
	var bulk := 0.85 + _rand(seed_value, 7) * 0.4
	var y := 0.30 * bulk
	_box(root, Vector3(0.24 * bulk, 0.20 * bulk, 0.26 * bulk), base.darkened(0.1),
		Vector3(0.0, y, 0.20 * bulk))
	_sphere(root, 0.12 * bulk, base, Vector3(0.0, y, 0.0))
	_box(root, Vector3(0.22 * bulk, 0.20 * bulk, 0.46 * bulk), base.lightened(0.1),
		Vector3(0.0, y, -0.30 * bulk))
	_eyes(root, 0.05 * bulk, Vector3(0.0, y + 0.05 * bulk, 0.30 * bulk), 0.07 * bulk)
	# 触角
	for side in [-1.0, 1.0]:
		var ant := _box(root, Vector3(0.03, 0.22 * bulk, 0.03), base.darkened(0.4),
			Vector3(side * 0.07 * bulk, y + 0.16 * bulk, 0.32 * bulk))
		ant.rotation_degrees = Vector3(-20.0, 0.0, side * 25.0)
	# 六足
	for side in [-1.0, 1.0]:
		for i in 3:
			var leg := _box(root, Vector3(0.18 * bulk, 0.04, 0.04), base.darkened(0.5),
				Vector3(side * 0.16 * bulk, y - 0.12 * bulk, (0.12 - float(i) * 0.20) * bulk))
			leg.rotation_degrees = Vector3(0.0, 0.0, side * 35.0)
	# 翅
	if _rand(seed_value, 8) > 0.25:
		for side in [-1.0, 1.0]:
			var wing := _box_alpha(root, Vector3(0.40 * bulk, 0.02, 0.34 * bulk),
				base.lightened(0.45), Vector3(side * 0.26 * bulk, y + 0.12 * bulk, -0.10 * bulk), 0.55)
			wing.rotation_degrees = Vector3(0.0, 0.0, side * 12.0)


## 海洋动物：按哈希在 5 种体型里选一个（鲸 / 水母 / 章鱼 / 贝 / 海星）。
static func _build_sea_animal(root: Node3D, base: Color, seed_value: int) -> void:
	match _absd(seed_value) % 5:
		0:
			_build_whale(root, base, seed_value)
		1:
			_build_jellyfish(root, base, seed_value)
		2:
			_build_octopus(root, base, seed_value)
		3:
			_build_shell(root, base, seed_value)
		_:
			_build_starfish(root, base, seed_value)


static func _build_whale(root: Node3D, base: Color, seed_value: int) -> void:
	var bulk := 1.0 + _rand(seed_value, 9) * 0.4
	_sphere(root, 0.30 * bulk, base, Vector3(0.0, 0.0, 0.34 * bulk))
	_box(root, Vector3(0.44 * bulk, 0.40 * bulk, 0.66 * bulk), base, Vector3(0.0, 0.0, -0.10 * bulk))
	_box(root, Vector3(0.28 * bulk, 0.24 * bulk, 0.42 * bulk), base.darkened(0.08),
		Vector3(0.0, 0.0, -0.54 * bulk))
	var fluke := _box(root, Vector3(0.62 * bulk, 0.06, 0.24 * bulk), base.darkened(0.15),
		Vector3(0.0, 0.0, -0.82 * bulk))
	fluke.rotation_degrees = Vector3(0.0, 0.0, 0.0)
	var fin := _box(root, Vector3(0.06, 0.26 * bulk, 0.22 * bulk), base.darkened(0.2),
		Vector3(0.22 * bulk, -0.12 * bulk, 0.10 * bulk))
	fin.rotation_degrees = Vector3(0.0, 0.0, 25.0)
	_eyes(root, 0.04 * bulk, Vector3(0.0, 0.05 * bulk, 0.56 * bulk), 0.12 * bulk)


static func _build_jellyfish(root: Node3D, base: Color, seed_value: int) -> void:
	var bulk := 0.95 + _rand(seed_value, 10) * 0.3
	var bell := Color(base.r, base.g, base.b, 0.65)
	_box_alpha(root, Vector3(0.52 * bulk, 0.30 * bulk, 0.52 * bulk), bell.lightened(0.25),
		Vector3(0.0, 0.22 * bulk, 0.0), 0.7)
	for i in 6:
		var ang := float(i) * 60.0
		var arm := _box_alpha(root, Vector3(0.05, 0.60 * bulk, 0.05), bell.lightened(0.15),
			Vector3(cos(deg_to_rad(ang)) * 0.18 * bulk, -0.18 * bulk, sin(deg_to_rad(ang)) * 0.18 * bulk), 0.6)
		arm.rotation_degrees = Vector3(sin(deg_to_rad(ang)) * 12.0, 0.0, -cos(deg_to_rad(ang)) * 12.0)


static func _build_octopus(root: Node3D, base: Color, seed_value: int) -> void:
	var bulk := 0.9 + _rand(seed_value, 11) * 0.3
	_sphere(root, 0.30 * bulk, base, Vector3(0.0, 0.28 * bulk, 0.0))
	_box(root, Vector3(0.38 * bulk, 0.26 * bulk, 0.34 * bulk), base, Vector3(0.0, 0.10 * bulk, 0.0))
	_eyes(root, 0.07 * bulk, Vector3(0.0, 0.34 * bulk, 0.22 * bulk), 0.13 * bulk)
	for i in 8:
		var ang := float(i) * 45.0
		var arm := _box(root, Vector3(0.10, 0.52 * bulk, 0.10), base.darkened(0.12),
			Vector3(cos(deg_to_rad(ang)) * 0.22 * bulk, -0.22 * bulk, sin(deg_to_rad(ang)) * 0.22 * bulk))
		arm.rotation_degrees = Vector3(sin(deg_to_rad(ang)) * 18.0, 0.0, -cos(deg_to_rad(ang)) * 18.0)


static func _build_shell(root: Node3D, base: Color, seed_value: int) -> void:
	var bulk := 0.95 + _rand(seed_value, 12) * 0.3
	for side in [-1.0, 1.0]:
		var shell := _box(root, Vector3(0.52 * bulk, 0.12 * bulk, 0.44 * bulk),
			base.lightened(0.1 * side), Vector3(0.0, side * 0.10 * bulk, 0.0))
		shell.rotation_degrees = Vector3(side * 22.0, 0.0, 0.0)
	_box(root, Vector3(0.20 * bulk, 0.14 * bulk, 0.20 * bulk), base.darkened(0.2),
		Vector3(0.0, 0.0, -0.22 * bulk))


static func _build_starfish(root: Node3D, base: Color, seed_value: int) -> void:
	var bulk := 0.95 + _rand(seed_value, 13) * 0.3
	_sphere(root, 0.16 * bulk, base, Vector3(0.0, 0.0, 0.0))
	for i in 5:
		var ang := float(i) * 72.0
		var arm := _box(root, Vector3(0.20 * bulk, 0.10, 0.46 * bulk), base.lightened(0.08),
			Vector3(cos(deg_to_rad(ang)) * 0.28 * bulk, 0.0, sin(deg_to_rad(ang)) * 0.28 * bulk))
		arm.rotation_degrees = Vector3(0.0, -ang, 0.0)


# ── 植物 ──────────────────────────────────────────────

## 树：主干 + 2~3 层冠。锥形还是球形由哈希决定（针叶 vs 阔叶）。
static func _build_tree(root: Node3D, base: Color, seed_value: int) -> void:
	var bulk := 0.95 + _rand(seed_value, 14) * 0.35
	var trunk_h := 0.62 * bulk
	_box(root, Vector3(0.16 * bulk, trunk_h, 0.16 * bulk), Color(0.44, 0.30, 0.17),
		Vector3(0.0, trunk_h * 0.5 - 0.4 * bulk, 0.0))
	var conifer := _rand(seed_value, 15) > 0.5
	var layers := 3 if conifer else 2
	for i in layers:
		var t := float(i) / maxf(1.0, float(layers - 1))
		var y := trunk_h * 0.5 - 0.4 * bulk + trunk_h * 0.5 + 0.18 * bulk + float(i) * 0.30 * bulk
		var width := (0.86 - t * 0.20) * bulk
		var part := _box(root, Vector3(width, 0.30 * bulk, width), base.lightened(0.06 * t),
			Vector3(0.0, y, 0.0))
		part.rotation_degrees = Vector3(0.0, float(seed_value % 90), 0.0)


static func _build_shrub(root: Node3D, base: Color, seed_value: int) -> void:
	var bulk := 0.95 + _rand(seed_value, 16) * 0.3
	_box(root, Vector3(0.12, 0.34 * bulk, 0.12), Color(0.46, 0.34, 0.20),
		Vector3(0.0, -0.24 * bulk, 0.0))
	for i in 3:
		var ang := _rand(seed_value, 20 + i) * 360.0
		var r := 0.20 * bulk
		_sphere(root, (0.26 + _rand(seed_value, 30 + i) * 0.12) * bulk, base.lightened(0.08 * float(i)),
			Vector3(cos(deg_to_rad(ang)) * r, 0.10 * bulk + _rand(seed_value, 40 + i) * 0.22 * bulk,
				sin(deg_to_rad(ang)) * r))


static func _build_grass(root: Node3D, base: Color, seed_value: int) -> void:
	var blades := 5 + (_absd(seed_value) % 4)
	for i in blades:
		var ang := _rand(seed_value, 50 + i) * 360.0
		var lean := 18.0 + _rand(seed_value, 60 + i) * 26.0
		var h := (0.70 + _rand(seed_value, 70 + i) * 0.5)
		var blade := _box(root, Vector3(0.07, h, 0.05), base.lightened(0.08 * _rand(seed_value, 80 + i)),
			Vector3(cos(deg_to_rad(ang)) * 0.10, h * 0.5 - 0.4, sin(deg_to_rad(ang)) * 0.10))
		blade.rotation_degrees = Vector3(sin(deg_to_rad(ang)) * lean, -ang, -cos(deg_to_rad(ang)) * lean)


static func _build_flower(root: Node3D, base: Color, seed_value: int) -> void:
	var stem_h := 0.55 + _rand(seed_value, 90) * 0.35
	_box(root, Vector3(0.07, stem_h, 0.07), Color(0.36, 0.52, 0.24), Vector3(0.0, stem_h * 0.5 - 0.35, 0.0))
	# 两片叶
	for side in [-1.0, 1.0]:
		var leaf := _box(root, Vector3(0.26, 0.04, 0.12), Color(0.42, 0.58, 0.28),
			Vector3(side * 0.16, stem_h * 0.28 - 0.35, 0.0))
		leaf.rotation_degrees = Vector3(0.0, 0.0, side * -18.0)
	# 花瓣
	var petals := 4 + (_absd(seed_value) % 4)
	for i in petals:
		var ang := float(i) * (360.0 / float(petals))
		var petal := _box(root, Vector3(0.30, 0.05, 0.18), base,
			Vector3(cos(deg_to_rad(ang)) * 0.17, stem_h - 0.35, sin(deg_to_rad(ang)) * 0.17))
		petal.rotation_degrees = Vector3(0.0, -ang, 0.0)
	_sphere(root, 0.12, Color(0.94, 0.82, 0.34), Vector3(0.0, stem_h - 0.32, 0.0))


static func _build_fern(root: Node3D, base: Color, seed_value: int) -> void:
	_box(root, Vector3(0.06, 0.30, 0.06), Color(0.40, 0.50, 0.26), Vector3(0.0, -0.50, 0.0))
	var fronds := 5 + (_absd(seed_value) % 3)
	for i in fronds:
		var ang := float(i) * (360.0 / float(fronds)) + _rand(seed_value, 100 + i) * 30.0
		var frond := _box(root, Vector3(0.56, 0.05, 0.20), base.lightened(0.06 * float(i % 3)),
			Vector3(cos(deg_to_rad(ang)) * 0.26, 0.06, sin(deg_to_rad(ang)) * 0.26))
		frond.rotation_degrees = Vector3(sin(deg_to_rad(ang)) * 32.0, -ang, -cos(deg_to_rad(ang)) * 32.0)


static func _build_moss(root: Node3D, base: Color, seed_value: int) -> void:
	for i in 6:
		var ang := float(i) * 60.0 + _rand(seed_value, 110 + i) * 40.0
		var r := 0.22 + _rand(seed_value, 120 + i) * 0.16
		_sphere(root, 0.16 + _rand(seed_value, 130 + i) * 0.12, base.lightened(0.05 * float(i % 4)),
			Vector3(cos(deg_to_rad(ang)) * r, -0.32 + _rand(seed_value, 140 + i) * 0.14,
				sin(deg_to_rad(ang)) * r))


static func _build_vine(root: Node3D, base: Color, seed_value: int) -> void:
	var segs := 6
	for i in segs:
		var t := float(i)
		var seg := _box(root, Vector3(0.10, 0.26, 0.10), base.darkened(0.12),
			Vector3(sin(t * 0.9) * 0.16, t * 0.20 - 0.55, cos(t * 0.9) * 0.16))
		seg.rotation_degrees = Vector3(20.0, t * 40.0, -14.0)
		if i % 2 == 0:
			var leaf := _box(root, Vector3(0.24, 0.04, 0.16), base.lightened(0.16),
				Vector3(sin(t * 0.9) * 0.16 + 0.14, t * 0.20 - 0.50, cos(t * 0.9) * 0.16))
			leaf.rotation_degrees = Vector3(0.0, t * 30.0, 22.0)


static func _build_algae(root: Node3D, base: Color, seed_value: int) -> void:
	for i in 5:
		var t := float(i)
		var band := _box_alpha(root, Vector3(0.52, 0.26, 0.10), base.lightened(0.05 * t),
			Vector3(sin(t * 1.1) * 0.22, t * 0.26 - 0.42, cos(t * 1.1) * 0.22), 0.75)
		band.rotation_degrees = Vector3(sin(t * 1.1) * 24.0, t * 34.0, cos(t * 1.1) * 24.0)


static func _build_seagrass(root: Node3D, base: Color, seed_value: int) -> void:
	var blades := 6 + (_absd(seed_value) % 4)
	for i in blades:
		var ang := float(i) * (360.0 / float(blades))
		var h := 0.9 + _rand(seed_value, 150 + i) * 0.5
		var blade := _box(root, Vector3(0.10, h, 0.04), base.lightened(0.06 * float(i % 3)),
			Vector3(cos(deg_to_rad(ang)) * 0.16, h * 0.5 - 0.45, sin(deg_to_rad(ang)) * 0.16))
		blade.rotation_degrees = Vector3(sin(deg_to_rad(ang)) * 16.0, -ang, -cos(deg_to_rad(ang)) * 16.0)


# ── 真菌 ──────────────────────────────────────────────

static func _build_mushroom(root: Node3D, base: Color, seed_value: int) -> void:
	var bulk := 0.9 + _rand(seed_value, 160) * 0.4
	_box(root, Vector3(0.18 * bulk, 0.46 * bulk, 0.18 * bulk), Color(0.93, 0.90, 0.84),
		Vector3(0.0, -0.16 * bulk, 0.0))
	_box(root, Vector3(0.58 * bulk, 0.22 * bulk, 0.58 * bulk), base, Vector3(0.0, 0.16 * bulk, 0.0))
	# 菌盖斑点
	for i in 3:
		var ang := _rand(seed_value, 170 + i) * 360.0
		_sphere(root, 0.08 * bulk, base.darkened(0.35),
			Vector3(cos(deg_to_rad(ang)) * 0.18 * bulk, 0.26 * bulk, sin(deg_to_rad(ang)) * 0.18 * bulk))


static func _build_lichen(root: Node3D, base: Color, seed_value: int) -> void:
	_box(root, Vector3(0.52, 0.20, 0.44), Color(0.52, 0.50, 0.46), Vector3(0.0, -0.34, 0.0))
	for i in 5:
		var ang := _rand(seed_value, 180 + i) * 360.0
		_sphere(root, 0.14 + _rand(seed_value, 190 + i) * 0.08, base.lightened(0.06 * float(i % 3)),
			Vector3(cos(deg_to_rad(ang)) * 0.18, -0.20 + _rand(seed_value, 200 + i) * 0.10,
				sin(deg_to_rad(ang)) * 0.14))


static func _build_mold(root: Node3D, base: Color, seed_value: int) -> void:
	_box(root, Vector3(0.54, 0.12, 0.44), Color(0.78, 0.70, 0.55), Vector3(0.0, -0.38, 0.0))
	for i in 7:
		var ang := _rand(seed_value, 210 + i) * 360.0
		var r := _rand(seed_value, 220 + i) * 0.24
		_sphere(root, 0.08 + _rand(seed_value, 230 + i) * 0.09, base.lightened(0.05 * float(i % 4)),
			Vector3(cos(deg_to_rad(ang)) * r, -0.28 + _rand(seed_value, 240 + i) * 0.16,
				sin(deg_to_rad(ang)) * r))


## 兜底：界色多面体 + 顶芽，至少不像空场景。
static func _build_generic(root: Node3D, base: Color, seed_value: int) -> void:
	_box(root, Vector3(0.66, 0.66, 0.66), base, Vector3(0.0, 0.0, 0.0),
		Vector3(deg_to_rad(18.0), deg_to_rad(float(seed_value % 60)), 0.0))
	_sphere(root, 0.20, base.lightened(0.25), Vector3(0.0, 0.44, 0.0))


# ────────────────────────────── 零件 ──────────────────────────────

static func _box(parent: Node3D, size: Vector3, color: Color, pos: Vector3,
		rot := Vector3.ZERO) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	part.mesh = mesh
	part.material_override = _flat(color)
	part.position = pos
	part.rotation = rot
	parent.add_child(part)
	return part


static func _box_alpha(parent: Node3D, size: Vector3, color: Color, pos: Vector3,
		alpha: float) -> MeshInstance3D:
	var part := _box(parent, size, color, pos)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, alpha)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	part.material_override = mat
	return part


static func _sphere(parent: Node3D, radius: float, color: Color, pos: Vector3) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 12
	mesh.rings = 6
	part.mesh = mesh
	part.material_override = _flat(color)
	part.position = pos
	parent.add_child(part)
	return part


## 四条腿：pos_y 是腿顶高度，count 为 4 时按四角分布。
static func _legs(parent: Node3D, color: Color, half_extent: Vector3, pos_y: float, count: int) -> void:
	var rows := 2 if count >= 4 else 1
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			if rows == 1 and sz > 0.0:
				continue
			_box(parent, Vector3(0.14, pos_y, 0.14), color,
				Vector3(sx * half_extent.x, pos_y * 0.5, sz * half_extent.z))


static func _ears(parent: Node3D, base: Color, head: float, y: float, z: float) -> void:
	for side in [-1.0, 1.0]:
		_box(parent, Vector3(head * 0.34, head * 0.34, head * 0.16), base.darkened(0.2),
			Vector3(side * head * 0.36, y + head * 0.34, z - head * 0.05))


## 一对眼睛：黑亮小球，让替身看起来「活着」。
static func _eyes(parent: Node3D, radius: float, pos: Vector3, spread: float) -> void:
	for side in [-1.0, 1.0]:
		_sphere(parent, radius, Color(0.95, 0.95, 0.94), pos + Vector3(side * spread, 0.0, 0.0))
		_sphere(parent, radius * 0.55, Color(0.05, 0.05, 0.08),
			pos + Vector3(side * spread, 0.0, radius * 0.7))


static func _flat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	return mat


# ────────────────────────────── 包围盒 ──────────────────────────────

## 收集所有 MeshInstance3D 的包围盒。
##
## 这里沿 local transform 逐级相乘，而不是取 global_transform：刚 add_child 的
## 模型，其全局变换要等到下一次 NOTIFICATION_TRANSFORM_CHANGED 才算好，
## 直接用会得到旧的（通常是单位矩阵）结果，悬停预览就会来不及居中。
static func _collect_boxes(node: Node, out: Array[AABB],
		parent_xform := Transform3D.IDENTITY) -> void:
	var xform := parent_xform
	if node is Node3D:
		xform = parent_xform * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append(xform * (node as MeshInstance3D).mesh.get_aabb())
	for child in node.get_children():
		_collect_boxes(child, out, xform)


static func _walk(node: Node) -> Array[Node]:
	var found: Array[Node] = []
	_collect_nodes(node, found)
	return found


static func _collect_nodes(node: Node, out: Array[Node]) -> void:
	for child in node.get_children():
		out.append(child)
		_collect_nodes(child, out)
