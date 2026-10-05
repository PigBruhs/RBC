# ══════════════════════════════════════════════════════════════════════════════
# 单位表现层：三种职业的程序化建模 + 头顶「双半圆」指示器 + 名称标签
#
# 指示器（用户要求）：
#   · 一个圆被一条直线分成两半，该直线与水平方向夹角 60°
#   · 两个半圆各自沿"垂直于分界线"的方向填充：一侧蓝=护甲，一侧红=力量
#   · 数字直接写在两个半圆上（自绘 3x5 点阵字，不依赖任何字体文件）
#   · 圆会随数值变化实时重绘
# ══════════════════════════════════════════════════════════════════════════════
class_name UnitVisual
extends Node3D

const ORB_PX := 336                # 贴图宽（力量/护甲方块的宽度）
const ORB_PX_H := 388              # 贴图高（多出来的部分留给上方的精力条）
const ORB_WORLD := 1.05            # 指示器在世界里的边长（对齐方块宽度）
const ORB_HEIGHT := 1.62           # 悬浮高度（要高于最高职业的头顶）
const ORB_MARGIN := 0.35           # 条子离开"模型最高点"的余量
## 条子贴图在世界里的**半高** = 贴图高 × pixel_size ÷ 2（billboard 会按它撑开）
const ORB_HALF_H := ORB_PX_H * (ORB_WORLD / float(ORB_PX)) * 0.5
## 名字要抬到**条子贴图顶边之上**：条子最大会 scale 到 1.18（选中时），再留 0.18 间距
## 第 107 轮：再抬一点（用户：名称需要再高一点，现在挡到精力条上了）——
## 精力条是**同一张贴图的最上面那一截**（ORB_PX_H > ORB_PX），所以名字要躲开整个贴图顶边。
const LABEL_ABOVE_ORB := ORB_HALF_H * 1.18 + 0.35
## 条子贴图比方块高出来的那截的一半（原来在 _build_orb 里算的局部变量 extra_h）
const ORB_EXTRA_H := float(ORB_PX_H - ORB_PX) * (ORB_WORLD / float(ORB_PX)) * 0.5
const WALK_TILES_PER_SEC := 2.0    # 移动速度：每秒 2 格（匀速滑动）
const HELI_TILES_PER_SEC := 2.5    # 悬浮单位（直升机）2.5 格/秒（用户口径第 86 轮）
## 轮式齐射午餐盒：**8 格/秒**（用户口径第 110 轮「车的移动速度变为现在的四倍」= 2 × 4）
const CART_TILES_PER_SEC := 8.0
const GLYPH_ADV := 6               # 字距（像素/点）：3x5 点阵 + 3 点间隔

# 色系（用户指定"诡异"风）：力量/血量=洋红、护甲=青黄
const COL_MAGENTA := Color(1.00, 0.15, 0.72)     # 力量（生命）
const COL_CYAN_YELLOW := Color(0.78, 0.95, 0.18) # 护甲
const COL_EMPTY := Color(0.10, 0.08, 0.13)
const COL_RING := Color(0.04, 0.03, 0.06)
const COL_ENERGY := Color(1.00, 0.84, 0.12)     # 精力（黄）
const COL_TEXT := Color(1, 1, 1)

# 3x5 点阵数字
const GLYPHS := {
	"0": ["111", "101", "101", "101", "111"],
	"1": ["010", "110", "010", "010", "111"],
	"2": ["111", "001", "111", "100", "111"],
	"3": ["111", "001", "111", "001", "111"],
	"4": ["101", "101", "111", "001", "001"],
	"5": ["111", "100", "111", "001", "111"],
	"6": ["111", "100", "111", "101", "111"],
	"7": ["111", "001", "010", "010", "010"],
	"8": ["111", "101", "111", "101", "111"],
	"9": ["111", "101", "111", "001", "111"],
	"/": ["001", "001", "010", "100", "100"],
}

var unit: Unit
var _orb_sprite: Sprite3D
var _orb_image: Image
var _orb_texture: ImageTexture
var _label: Label3D
var _ring: MeshInstance3D
var _ring_mat: StandardMaterial3D
var _walk_tween: Tween = null
var _base_y: float = 0.0
var _idle_tween: Tween = null
var _cycling: bool = false               # 脚下环是否正在彩色流动（待确认状态）
## 这一位的移动速度（格/秒）。用户口径（第 86 轮）：**直升机 2.5 格/秒**，其余角色 2 格/秒。
var walk_speed: float = WALK_TILES_PER_SEC


func setup(u: Unit) -> void:
	unit = u
	u.visual = self
	# 悬浮单位（直升机）基准高度就是悬浮高度：**不受重力影响**，
	# 只有俯冲/坠机才会改它的 y（改高度的代码走 HeliFx / battle_scene）
	var h: float = maxf(0.0, u.hover)
	position = Vector3(float(u.cell.x) + 0.5, h, float(u.cell.y) + 0.5)
	_base_y = h
	# 用户口径（第 86 轮）：直升机移动 2.5 格/秒（其余 2 格/秒）
	# 用户口径（第 110 轮）：**车的移动速度变成现在的四倍**（2 -> 8 格/秒）
	walk_speed = HELI_TILES_PER_SEC if h > 0.0 else WALK_TILES_PER_SEC
	if u.name == LunchboxModel.LUNCHBOX_NAME:
		walk_speed = CART_TILES_PER_SEC
	_build_model()
	_build_orb()
	_build_label()
	_build_selection_ring()
	update_orb()
	_start_idle()


## 待机浮动：呼吸感用的，走路时会自动让位（走路 Tween 会 kill 它）
## 用"播完再起一段"的方式循环，不用 set_loops()（Godot 4.7 会报 Infinite loop detected）
func _start_idle() -> void:
	_stop_idle()
	# 悬浮单位不播待机浮动：否则 Tween 每帧把 y 拉回 0，直升机就会"不断往下掉"
	if unit != null and unit.hover > 0.0:
		position.y = unit.hover
		return
	_idle_tween = _make_idle_tween()


func _make_idle_tween() -> Tween:
	var tw := create_tween()
	tw.tween_property(self, "position:y", _base_y + 0.05, 1.1) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(self, "position:y", _base_y, 1.1) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_callback(_restart_idle)
	return tw


func _restart_idle() -> void:
	if _idle_tween == null:
		return                              # 已被 _stop_idle 停掉
	_idle_tween = _make_idle_tween()


func _stop_idle() -> void:
	if _idle_tween != null and _idle_tween.is_valid():
		_idle_tween.kill()
	_idle_tween = null


# ── 建模 ──────────────────────────────────────────────────────────────────────
func _faction_color() -> Color:
	if unit.side == UnitData.Side.PLAYER:
		return Color(0.34, 0.58, 0.95)
	# 三个假人各给一个不同颜色，方便区分是哪一只
	match unit.name:
		"Dummy Melee": return Color(0.85, 0.35, 0.30)
		"Dummy Ranged": return Color(0.80, 0.45, 0.65)
		"Dummy Thrower": return Color(0.70, 0.55, 0.30)
	return Color(0.85, 0.35, 0.30)


func _mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.75
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return m


func _add_mesh(node: Node3D, mesh: Mesh, pos: Vector3, rot: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.rotation_degrees = rot
	mi.material_override = mat
	node.add_child(mi)
	return mi


## 萨尼铁塔的医疗拐杖：竖杆 + 腋下横托 + 底部圆垫，斜背在身后
func _build_crutch() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.78, 0.79, 0.82)
	mat.metallic = 0.5
	mat.roughness = 0.35
	var shaft := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.022
	cm.bottom_radius = 0.022
	cm.height = 0.86
	shaft.mesh = cm
	shaft.position = Vector3(-0.16, 0.55, -0.20)
	shaft.rotation_degrees = Vector3(0, 0, 16)
	shaft.material_override = mat
	add_child(shaft)
	var pad := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.16, 0.05, 0.09)
	pad.mesh = bm
	pad.position = Vector3(-0.28, 0.96, -0.20)
	pad.rotation_degrees = Vector3(0, 0, 16)
	pad.material_override = mat
	add_child(pad)
	var foot := MeshInstance3D.new()
	var fm := CylinderMesh.new()
	fm.top_radius = 0.045
	fm.bottom_radius = 0.045
	fm.height = 0.03
	foot.mesh = fm
	foot.position = Vector3(-0.04, 0.02, -0.20)
	foot.material_override = mat
	add_child(foot)


func _build_model() -> void:
	var base := _faction_color()
	var body_mat := _mat(base)
	var dark_mat := _mat(base.darkened(0.4))
	var metal_mat := _mat(Color(0.75, 0.77, 0.82))
	# 假人没有职业：一律用「木桩」造型（圆桶 + 两根横臂），一眼看出不是正式角色
	if unit.name.begins_with("Dummy"):
		_build_dummy(body_mat, dark_mat, metal_mat)
		return
	var bname := Unit.base_name(unit.name)
	# 俯冲轰炸直升机（不要问那么多）：用独立模型文件 HeliModel 搭的机身 + 旋翼
	if bname.begins_with("俯冲轰炸直升机"):
		HeliModel.build(self, _faction_color())
		return
	# 大头目 Reaper（质量效应风的大鱿鱼）：独立模型文件 ReaperModel。
	# 视觉包围盒 = 碰撞圆柱（高 12 / 直径 6），蓝环离地 6 格 —— 见 reaper_model.gd
	if bname == "Reaper":
		ReaperModel.attach(self, _faction_color())
		return
	# 轮式齐射午餐盒（第 104 轮）：轮式战车（拉长的正六边形车体 + 8 轮胎 + 六边形棱柱炮塔
	# + 车顶右半边的巡飞弹发射器）。模型占 1×2 格，与它的两个碰撞圆柱对齐 —— 见 lunchbox_model.gd
	if bname == LunchboxModel.LUNCHBOX_NAME:
		LunchboxModel.attach(self, _faction_color())
		return
	# 萨尼铁塔：远程造型 + 背上背一根医疗拐杖（用户口径）
	if bname == "萨尼铁塔":
		_build_ranged(body_mat, dark_mat, metal_mat)
		_build_crutch()
		return
	# 老国王：披甲的人 + 王冠 + 身前一门悬空加农炮
	if bname == "老国王":
		_build_melee(body_mat, dark_mat, metal_mat)
		_build_crown(1.11)
		_build_cannon_body(metal_mat)
		return
	match unit.role:
		UnitData.Role.MELEE: _build_melee(body_mat, dark_mat, metal_mat)
		UnitData.Role.RANGED: _build_ranged(body_mat, dark_mat, metal_mat)
		UnitData.Role.THROWER: _build_thrower(body_mat, dark_mat, metal_mat)
	# 公主：换皮阿莱特 + 王冠
	if bname == "公主":
		_build_crown(1.30)


## 王冠：一圈金环 + 5 个尖角，戴在头顶。head_top = 头顶的世界高度
func _build_crown(head_top: float) -> void:
	var gold := _mat(Color(1.0, 0.84, 0.26))
	var band := CylinderMesh.new()
	band.top_radius = 0.20
	band.bottom_radius = 0.21
	band.height = 0.07
	_add_mesh(self, band, Vector3(0, head_top + 0.02, 0), Vector3.ZERO, gold)
	for i in 5:
		var ang := TAU * float(i) / 5.0
		var spike := CylinderMesh.new()
		spike.top_radius = 0.0
		spike.bottom_radius = 0.045
		spike.height = 0.13
		_add_mesh(self, spike,
			Vector3(sin(ang) * 0.17, head_top + 0.12, cos(ang) * 0.17), Vector3.ZERO, gold)


## 加农炮：削去两头的圆锥（炮口小 0.35 / 炮闩大 0.40）+ 炮闩半球，
## 水平悬空在身前约 0.5 格高，长度 0.5 格。炮口朝局部 +Z（= 角色的正面）。
func _build_cannon_body(metal_mat: Material) -> void:
	var barrel := CylinderMesh.new()
	barrel.top_radius = 0.175         # 炮口
	barrel.bottom_radius = 0.20       # 炮闩
	barrel.height = 0.50
	_add_mesh(self, barrel, Vector3(0, 0.50, 0.45), Vector3(90, 0, 0), metal_mat)
	var breech := SphereMesh.new()
	breech.radius = 0.20
	breech.height = 0.20
	breech.is_hemisphere = true
	_add_mesh(self, breech, Vector3(0, 0.50, 0.20), Vector3(-90, 0, 0), metal_mat)


## 假人：木桩 + 横臂 + 草靶头
func _build_dummy(body_mat: Material, dark_mat: Material, metal_mat: Material) -> void:
	var post := CylinderMesh.new()
	post.top_radius = 0.13
	post.bottom_radius = 0.16
	post.height = 1.05
	_add_mesh(self, post, Vector3(0, 0.52, 0), Vector3.ZERO, dark_mat)

	var arms := BoxMesh.new()
	arms.size = Vector3(0.92, 0.11, 0.11)
	_add_mesh(self, arms, Vector3(0, 0.82, 0), Vector3.ZERO, dark_mat)

	var head := SphereMesh.new()
	head.radius = 0.22
	head.height = 0.44
	_add_mesh(self, head, Vector3(0, 1.16, 0), Vector3.ZERO, body_mat)

	var band := CylinderMesh.new()
	band.top_radius = 0.165
	band.bottom_radius = 0.165
	band.height = 0.10
	_add_mesh(self, band, Vector3(0, 0.62, 0), Vector3.ZERO, metal_mat)


func _build_melee(body_mat: Material, dark_mat: Material, metal_mat: Material) -> void:
	var body := CapsuleMesh.new()
	body.radius = 0.30
	body.height = 0.78
	_add_mesh(self, body, Vector3(0, 0.44, 0), Vector3.ZERO, body_mat)
	var head := SphereMesh.new()
	head.radius = 0.19
	head.height = 0.38
	_add_mesh(self, head, Vector3(0, 0.92, 0), Vector3.ZERO, body_mat)
	for sx in [-0.15, 0.15]:
		var leg := CylinderMesh.new()
		leg.top_radius = 0.10
		leg.bottom_radius = 0.11
		leg.height = 0.24
		_add_mesh(self, leg, Vector3(sx, 0.12, 0), Vector3.ZERO, dark_mat)
	var shield := BoxMesh.new()
	shield.size = Vector3(0.10, 0.62, 0.46)
	_add_mesh(self, shield, Vector3(-0.36, 0.55, 0.04), Vector3(0, 0, -6), metal_mat)
	var sword := BoxMesh.new()
	sword.size = Vector3(0.07, 0.72, 0.07)
	_add_mesh(self, sword, Vector3(0.38, 0.62, 0.06), Vector3(0, 0, 22), metal_mat)


func _build_ranged(body_mat: Material, dark_mat: Material, metal_mat: Material) -> void:
	var body := CapsuleMesh.new()
	body.radius = 0.20
	body.height = 0.92
	_add_mesh(self, body, Vector3(0, 0.58, 0), Vector3.ZERO, body_mat)
	var head := SphereMesh.new()
	head.radius = 0.16
	head.height = 0.32
	_add_mesh(self, head, Vector3(0, 1.14, 0), Vector3.ZERO, body_mat)
	for sx in [-0.10, 0.10]:
		var leg := CylinderMesh.new()
		leg.top_radius = 0.07
		leg.bottom_radius = 0.07
		leg.height = 0.30
		_add_mesh(self, leg, Vector3(sx, 0.15, 0), Vector3.ZERO, dark_mat)
	var bow := CylinderMesh.new()
	bow.top_radius = 0.030
	bow.bottom_radius = 0.030
	bow.height = 1.05
	_add_mesh(self, bow, Vector3(0.30, 0.72, 0.02), Vector3(0, 0, 18), metal_mat)
	var string := CylinderMesh.new()
	string.top_radius = 0.008
	string.bottom_radius = 0.008
	string.height = 1.00
	_add_mesh(self, string, Vector3(0.22, 0.72, 0.02), Vector3(0, 0, 18), dark_mat)


func _build_thrower(body_mat: Material, dark_mat: Material, metal_mat: Material) -> void:
	var body := CapsuleMesh.new()
	body.radius = 0.26
	body.height = 0.72
	_add_mesh(self, body, Vector3(0, 0.40, 0), Vector3.ZERO, body_mat)
	var head := SphereMesh.new()
	head.radius = 0.17
	head.height = 0.34
	_add_mesh(self, head, Vector3(0, 0.85, 0.02), Vector3.ZERO, body_mat)
	for sx in [-0.13, 0.13]:
		var leg := CylinderMesh.new()
		leg.top_radius = 0.09
		leg.bottom_radius = 0.09
		leg.height = 0.22
		_add_mesh(self, leg, Vector3(sx, 0.11, 0), Vector3.ZERO, dark_mat)
	var ball := SphereMesh.new()
	ball.radius = 0.16
	ball.height = 0.32
	_add_mesh(self, ball, Vector3(0.34, 0.70, 0.20), Vector3.ZERO, metal_mat)
	var pack := CylinderMesh.new()
	pack.top_radius = 0.17
	pack.bottom_radius = 0.14
	pack.height = 0.38
	_add_mesh(self, pack, Vector3(-0.24, 0.62, -0.20), Vector3(12, 0, 0), dark_mat)


# ── 头顶指示器：上方黄色精力条 + 下方「力量/护甲」方块 + 数字 ──────────────────
## 大块头（Reaper 这类）要把头顶指示器抬到**模型之上**，否则力量/护甲条会被自己挡住。
## 口径：条底 = `body_h()`（身体底面高度）+ `body_height`（身高，来自数据行的 body_h）
##   + 0.35 余量，再减去原本的悬浮高度 ORB_HEIGHT。
## ⚠ **默认角色逐字不变**：一般单位 `body_h()`=0.30、`body_height`=1.00 -> top=1.30 < ORB_HEIGHT(1.62)
##   -> maxf 取 0，位置与改动前完全一致。只有 Reaper（body_height=12）这类才会被抬高。
func _body_lift() -> float:
	if unit == null:
		return 0.0
	var top := unit.body_h() + unit.body_height      # 数据口径（第 104 轮）
	var box := _model_top_y()                        # 实测模型最高点（含炮管/旋翼/轮胎，第 106 轮补）
	# 第 107 轮实测的**真正原因**：第 106 轮只把条子的**中心**抬到"模型顶 + 余量"，
	# 但条子贴图自己是**有半高**的（ORB_HALF_H = 0.606），于是条子的**下半截**仍然压在模型上 ——
	# 实测午餐盒：条子中心 2.771、下边 2.165，而模型顶 2.340 -> **下边比模型顶低 0.175**，正是"又挡住炮管"。
	# 修正：抬升量里再减去条子自身的半高，让**条子下边**高于模型顶 + 余量。
	return maxf(0.0, maxf(top, box) + ORB_MARGIN + ORB_HALF_H - (ORB_HEIGHT + ORB_EXTRA_H))


## 实测本单位所有 MeshInstance3D 包围盒的最高点（本地空间，含各自的局部位移/旋转/缩放）。
## **为什么需要它**（第 106 轮实测出来的真原因）：`body_h() + body_height` 是**数据行**口径，
## 跟真实模型对不上 —— 例如直升机 body_h()+body_height = 3.00，而它的**实测模型最高点是 4.03**，
## 于是条子（3.43）整个陷在模型里；午餐盒加了 1.2 格炮管之后同理。
## 默认角色不受影响：Gerald 数据口径 1.30 > 实测 1.11，取 1.30 -> 仍然是 0（第 104 轮保证不破）。
func _model_top_y() -> float:
	# ⚠ 第 109 轮：午餐盒这类**有可动部件**的模型要"报价最大高度"，不能只量建模型那一刻的姿态。
	#   原因：炮管仰起时炮口会更高（实测 phi=60° 时 2.956，比水平的 2.34 高 0.616），
	#   而 `_model_top_y` 只在建模型时被调一次（那时炮管水平）-> 仰起后可能顶到条子。
	#   见 `LunchboxModel.max_height()`。
	var mm := _movable_model()
	if mm != null:
		return mm.max_height()
	var top := 0.0
	for mi in _all_meshes(self):
		# 沿父链把变换累加到 self（UnitVisual 根）——模型网格可能是**嵌套**的
		# （实测教训：午餐盒的网格挂在一个子 Node3D 下，只看直接子节点会量成 0.025）
		var t := Transform3D.IDENTITY
		var n: Node = mi
		while n != null and n != self:
			t = (n as Node3D).transform * t
			n = n.get_parent()
		var aabb: AABB = (mi as MeshInstance3D).get_aabb()
		for i in 8:
			var y: float = (t * aabb.get_endpoint(i)).y
			if y > top:
				top = y
	return top


func _all_meshes(n: Node, out: Array = []) -> Array:
	for c in n.get_children():
		if c is MeshInstance3D:
			out.append(c)
		_all_meshes(c, out)
	return out


## 本单位那个"有可动部件"的模型（第 109 轮）。目前只有午餐盒：
##   它有炮塔（`set_aim` 能仰到 60°）与车体（`set_body_yaw`），所以"最高点"随姿态变化，
##   必须由模型自己报价（`max_height()`），不能只量建模型那一刻。
## 其它单位（含 Reaper）返回 null -> 走原来的静态包围盒路径，**行为逐字不变**。
func _movable_model() -> LunchboxModel:
	for c in get_children():
		if c is LunchboxModel:
			return c
	return null


## ── 条子几何报价（第 109 轮，供测试与断言用）────────────────────────────────
## 条子中心的世界 y —— **与 `update_orb()` 里摆放 `_orb_sprite` 的公式同源**，
## 所以断言的是"真实渲染位置"，不是另算一份。
## `orb_half_h()` 是条子贴图的半高（含选中时最大 1.18 倍），所以
## **下边 = 中心 - 半高** 就是"条子会不会压到模型"的判据。
func orb_center_y() -> float:
	if _orb_sprite == null:
		return 0.0
	return float(_orb_sprite.position.y)


func orb_half_h() -> float:
	return ORB_HALF_H * 1.18        # 1.18 = 选中时的最大放大（与 LABEL_ABOVE_ORB 同源）


func _build_orb() -> void:
	_orb_image = Image.create(ORB_PX, ORB_PX_H, false, Image.FORMAT_RGBA8)
	_orb_texture = ImageTexture.create_from_image(_orb_image)
	_orb_sprite = Sprite3D.new()
	_orb_sprite.texture = _orb_texture
	# 用同一个 pixel_size 保持纵横比：宽 ORB_WORLD，高按贴图比例放大
	_orb_sprite.pixel_size = ORB_WORLD / float(ORB_PX)
	_orb_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_orb_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	# 第 106 轮排查③：条子原来是**参与深度测试**的 -> 会被高模型挡住（实测直升机条子陷在模型里）。
	# 名字早就开了 no_depth_test，条子也跟上，两者行为一致。
	_orb_sprite.no_depth_test = true
	_orb_sprite.render_priority = 1
	# 贴图比方块高（上面多了精力条），所以整体上移半条的高度，
	# 让方块的视觉位置与原来一致、精力条出现在它正上方。
	var extra_h := float(ORB_PX_H - ORB_PX) * _orb_sprite.pixel_size * 0.5
	# 戴王冠的角色把指示器整体抬高，否则王冠会被力量/护甲方块挡住（用户要看得到王冠）
	var crown_lift := 0.50 if _is_crowned() else 0.0
	_orb_sprite.position = Vector3(0, ORB_HEIGHT + extra_h + crown_lift + _body_lift(), 0)
	add_child(_orb_sprite)


func _build_label() -> void:
	_label = Label3D.new()
	_label.text = unit.name
	_label.font_size = 64
	_label.pixel_size = 0.0032
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.modulate = Color(1, 1, 1, 0.85)
	_label.outline_size = 14
	_label.outline_modulate = Color(0, 0, 0, 0.9)
	# 第 106 轮实测：原来写死的 +0.42 让名字落在**条子贴图内部**（名字 y=2.04，条子顶边 2.31）
	# -> 19 个单位**全部**被条子盖住，这就是用户说的"绝大部分都看不见"。
	# 现在按条子的真实半高来抬：名字 y = 条子中心 + 条子半高(按最大 1.18 倍) + 0.18。
	_label.position = Vector3(0, ORB_HEIGHT + ORB_EXTRA_H
		+ (0.50 if _is_crowned() else 0.0) + _body_lift() + LABEL_ABOVE_ORB, 0)
	_label.no_depth_test = true
	_label.render_priority = 2          # 名字永远画在条子之上（排查①的兜底）
	add_child(_label)


## 这个单位戴不戴王冠（老国王 / 公主）—— 建模和指示器高度都要用
func _is_crowned() -> bool:
	if unit == null:
		return false
	var b := Unit.base_name(unit.name)
	return b == "老国王" or b == "公主"


## 指示器布局（贴图内，y 向下）：
##   ┌──────────────┐  y = BAR_TOP .. BAR_BOT   精力条（黄色小长方形）
##   │ 精力数字      │
##   ├──────┬───────┤  y = PANEL_TOP .. BAR_BOT 力量/护甲方块
##   │ 护甲 │ 力量  │
##   └──────┴───────┘
## 精力条在正上方，精力减少时**从左边开始变黑**（左边先空）。
const PANEL_SIZE := 336           # 方块边长
const PANEL_TOP := 52             # 方块顶边（贴图 y）：底边 = PANEL_TOP+PANEL_SIZE = 388
const BAR_H := 44                 # 精力条高度（要放得下数字）
const BAR_TOP := 8                # 精力条顶边
const BAR_GAP := 6                # 条与方块之间的空隙
const BAR_LEFT := 6
const BAR_RIGHT := 330


## 正方形指示器：左半 = 护甲（青黄），右半 = 力量（洋红）；正上方一条黄色精力条。
## 填充规则：数值满时整块涂满；一旦减少，**损失的部分从上方空出来**（颜色留在下半部）。
## 精力条：减少时**从左边开始变黑**。
func update_orb() -> void:
	if _orb_image == null or unit == null:
		return
	var n := ORB_PX
	var px0 := 4                                   # 方块左边界
	var py0 := PANEL_TOP
	var size := PANEL_SIZE
	var mid := px0 + size / 2
	var armor_frac := 0.0 if unit.armor_max <= 0 else clampf(unit.armor_cur / float(unit.armor_max), 0.0, 1.0)
	var power_frac := 0.0 if unit.power_max <= 0 else clampf(unit.power_cur / float(unit.power_max), 0.0, 1.0)
	var en_frac := 0.0 if unit.energy_max <= 0 else clampf(unit.energy / float(unit.energy_max), 0.0, 1.0)

	_orb_image.fill(Color(0, 0, 0, 0))

	# ── ① 力量 / 护甲方块 ──
	var W: int = _orb_image.get_width()
	var H: int = _orb_image.get_height()
	for y in range(maxi(0, py0), mini(H, py0 + size)):
		for x in range(maxi(0, px0), mini(W, px0 + size)):
			# 边框（外圈 3 像素）
			if x < px0 + 3 or y < py0 + 3 or x >= px0 + size - 3 or y >= py0 + size - 3:
				_orb_image.set_pixel(x, y, COL_RING)
				continue
			# 中缝
			if x >= mid - 2 and x <= mid + 1:
				_orb_image.set_pixel(x, y, COL_RING)
				continue
			var armor_side := x < mid
			var frac := armor_frac if armor_side else power_frac
			var want := COL_CYAN_YELLOW if armor_side else COL_MAGENTA
			# t 从上往下 0→1；颜色贴下边，数值下降时上方空出黑色
			var t := float(y - (py0 + 3)) / float(size - 6)
			_orb_image.set_pixel(x, y, want if t >= (1.0 - frac) else COL_EMPTY)

	# ── ② 精力条：分段式，每 1 点精力点亮一段（用户反馈填充式显示不对）──
	var bar_y0 := BAR_TOP
	var bar_y1 := BAR_TOP + BAR_H
	var bar_x0 := BAR_LEFT
	var bar_x1 := BAR_RIGHT
	var inner_x0 := bar_x0 + 3
	var inner_x1 := bar_x1 - 3
	var inner_w := inner_x1 - inner_x0
	var n_seg: int = maxi(1, unit.energy_max_points())
	var have: int = unit.energy_points()
	for y in range(bar_y0, bar_y1):
		for x in range(bar_x0, bar_x1):
			if x < inner_x0 or y < bar_y0 + 3 or x >= inner_x1 or y >= bar_y1 - 3:
				_orb_image.set_pixel(x, y, COL_RING)
				continue
			# 这一段属于第几点精力（0..n_seg-1）
			var seg := int(float(x - inner_x0) / float(inner_w) * n_seg)
			seg = clampi(seg, 0, n_seg - 1)
			var gap := (inner_w % n_seg)
			_orb_image.set_pixel(x, y, COL_ENERGY if seg < have else COL_EMPTY)

	# ── ③ 数字 ──
	var armor_txt := _fmt_num(unit.armor_cur)
	var power_txt := _fmt_num(unit.power_cur)
	_draw_number_fit(mid / 2 + px0 / 2, py0 + size / 2, armor_txt)
	_draw_number_fit(mid + mid / 2 - px0 / 2, py0 + size / 2, power_txt)
	# 精力数字写在小长方形上
	var en_txt := "%d/%d" % [unit.energy_points(), unit.energy_max_points()]
	_draw_text_centered_bar((bar_x0 + bar_x1) / 2, (bar_y0 + bar_y1) / 2, en_txt)

	_orb_texture.update(_orb_image)


static func _fmt_num(milli: int) -> String:
	return str(int(round(milli / 1000.0)))


## 把数字画到方格里，尽量占满：两半内部各 118x250 像素，所以
##   1~2 位数 -> 字号 8（每点 8 像素，数字高 40px 宽 ~56px，非常醒目）
##   3 位数   -> 字号 6
##   4 位数   -> 字号 4
func _draw_number_fit(cx: int, cy: int, text: String) -> void:
	var half_w := int(PANEL_SIZE * 0.46)
	var scale := 8
	while scale > 2 and (text.length() * GLYPH_ADV * scale - 3 * scale) > half_w:
		scale -= 1
	_draw_text_centered(cx, cy, text, scale)


## 精力条上的数字：条比较矮（54px），所以字号按高度算，保证不糊出条外
func _draw_text_centered_bar(cx: int, cy: int, text: String) -> void:
	var avail_h := BAR_H - 12
	var scale := int(avail_h / 5)
	var avail_w := (BAR_RIGHT - BAR_LEFT) - 16
	while scale > 1 and (text.length() * GLYPH_ADV * scale - 3 * scale) > avail_w:
		scale -= 1
	if scale < 1:
		scale = 1
	_draw_text_centered(cx, cy, text, scale)


## 自绘 3x5 点阵文字（居中）。只写"亮"的点，不再给每个点加黑框
## （之前用黑框描边，多个字之间会互相盖住，看起来像"数字被啃掉一块"）。
func _draw_text_centered(cx: int, cy: int, text: String, scale: int) -> void:
	var adv := GLYPH_ADV * scale
	var w := text.length() * adv - 3 * scale
	var h := 5 * scale
	var x0 := cx - w / 2
	var y0 := cy - h / 2
	for i in text.length():
		var glyph: Array = GLYPHS.get(text[i], GLYPHS["/"])
		for row in 5:
			var line: String = glyph[row]
			for col in 3:
				if line[col] == "1":
					_put(x0 + i * adv + col * scale, y0 + row * scale, scale, scale, COL_TEXT)


func _put(x: int, y: int, w: int, h: int, col: Color) -> void:
	for yy in range(y, y + h):
		for xx in range(x, x + w):
			if xx < 0 or yy < 0 or xx >= ORB_PX or yy >= ORB_PX_H:
				continue
			_orb_image.set_pixel(xx, yy, col)


# ── 脚下选中环 ────────────────────────────────────────────────────────────────
func _build_selection_ring() -> void:
	_ring = MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 0.44
	disc.bottom_radius = 0.44
	disc.height = 0.02
	_ring.mesh = disc
	_ring.position = Vector3(0, 0.015, 0)
	_ring_mat = StandardMaterial3D.new()
	_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_mat.albedo_color = Color(1, 1, 1, 0.0)
	_ring.material_override = _ring_mat
	add_child(_ring)


func set_selected(on: bool) -> void:
	if _ring_mat:
		if on:
			_ring_mat.albedo_color = Color(1.0, 0.92, 0.35, 0.60)
		else:
			var spent: bool = unit != null and (unit.has_moved or unit.has_acted)
			_ring_mat.albedo_color = Color(1, 1, 1, 0.10 if spent else 0.22)


## 挨打的瞬时白闪。
## 关键：**基准色只记一次**（第一次闪的时候），每次都回到那个基准色。
## 以前是每次闪都把"当前颜色"当基准色，连吃几发（比如地毯式轰炸）就会
## 一次比一次白，最后彻底回不来 —— 用户看到的"受击之后变白不恢复"。
var _base_cols: Dictionary = {}
var _flash_tw: Tween = null

func flash_hit() -> void:
	for child in get_children():
		if not (child is MeshInstance3D):
			continue
		var mi := child as MeshInstance3D
		if not (mi.material_override is StandardMaterial3D):
			continue
		var sm := mi.material_override as StandardMaterial3D
		if not _base_cols.has(sm):
			_base_cols[sm] = sm.albedo_color
		sm.albedo_color = Color(1, 1, 1)
	if _flash_tw != null and _flash_tw.is_valid():
		_flash_tw.kill()
	_flash_tw = create_tween()
	_flash_tw.set_parallel(true)
	for key in _base_cols.keys():
		var mat = key
		if is_instance_valid(mat):
			_flash_tw.tween_property(mat, "albedo_color", _base_cols[key], 0.30)


## 彩色流动环：用于"待确认"（正在移动的人 / 被选为攻击目标的敌人）。
## 传 null 表示恢复常规的选中/待机配色。
func set_cycle_ring(col: Variant) -> void:
	if _ring_mat == null:
		return
	if col == null:
		_cycling = false
		return
	_cycling = true
	_ring_mat.albedo_color = col


func is_cycling() -> bool:
	return _cycling


## 轮到它行动时：脚下高亮 + 头顶圆放大一点，方便一眼找到
func set_active(on: bool) -> void:
	if _ring_mat and on:
		_ring_mat.albedo_color = Color(0.45, 1.0, 0.55, 0.70)
	if _orb_sprite:
		_orb_sprite.scale = Vector3.ONE * (1.18 if on else 1.0)


func set_orb_visible(v: bool) -> void:
	if _orb_sprite:
		_orb_sprite.visible = v
	if _label:
		_label.visible = v


# ── 走路动画 ──────────────────────────────────────────────────────────────────
## 匀速滑动（用户口径）：沿整条路径一口气平滑滑过去，**不在一格一格停**，
## 也没有抬腿/跳动。速度恒定 = WALK_TILES_PER_SEC 格/秒。
## 做法：整条折线参数化成 k∈[0,1]，每段长度都是 1 格，段内线性插值
## -> 每段时间相同、段内匀速，合起来就是全程匀速。
func walk_path(path: Array[Vector2i]) -> void:
	if path.size() < 2:
		return
	_stop_idle()
	if _walk_tween != null and _walk_tween.is_valid():
		_walk_tween.kill()
	var base_y := _base_y
	var pts: Array[Vector3] = []
	for c in path:
		pts.append(Vector3(float(c.x) + 0.5, base_y, float(c.y) + 0.5))
	var segs := pts.size() - 1
	if segs <= 0:
		_start_idle()
		return
	# 朝向取第一段的行进方向（旧代码的角度约定：atan2(dz, dx)）
	var d0: Vector3 = pts[1] - pts[0]
	rotation.y = atan2(d0.z, d0.x)
	var tw := create_tween()
	_walk_tween = tw
	tw.tween_method(func(k: float) -> void:
		var u: float = clampf(k, 0.0, 1.0) * float(segs)
		var i: int = mini(int(floor(u)), segs - 1)
		var f: float = u - float(i)
		position = (pts[i] as Vector3).lerp(pts[i + 1], f)
		, 0.0, 1.0, float(segs) / maxf(0.1, walk_speed))
	# 走完恢复待机浮动
	tw.tween_callback(Callable(self, "_start_idle"))


func is_walking() -> bool:
	return _walk_tween != null and _walk_tween.is_valid() and _walk_tween.is_running()
