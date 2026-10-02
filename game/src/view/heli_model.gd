# ══════════════════════════════════════════════════════════════════════════════
# 俯冲轰炸直升机：程序化建模，零美术资源，全部用 BoxMesh / CylinderMesh /
# SphereMesh / PrismMesh 拼装。
#
# 局部坐标约定（重要）：
#   · +Z = 机头（前），−Z = 机尾；+Y = 上；±X = 左右
#   · 最低点（雪橇底面）落在 y = 0，悬浮高度由调用方负责，这里不加任何偏移
#   · 机身长 ≈ 1.2（z ∈ [−0.65, +0.47]），宽 ≈ 0.45，高 ≈ 0.40
#
# 自转预留节点（都是 root 的直接子节点，直接 get_node 即可驱动）：
#   · MainRotor —— 机顶旋翼总成，绕本地 Y 轴自转（正上方，中心在机身中线上）
#   · TailRotor —— 尾部小尾桨，绕本地 X 轴自转（桨盘在 YZ 竖直平面内）
# ══════════════════════════════════════════════════════════════════════════════
class_name HeliModel
extends RefCounted

const COL_METAL := Color(0.74, 0.76, 0.79)          # 浅灰金属件
const COL_DARK := Color(0.17, 0.18, 0.20)           # 桨叶/挂架配件的深色
const GLASS_TINT := Color(0.04, 0.07, 0.14, 0.62)   # 半透明蓝黑座舱玻璃
const BODY_DARK := 0.72                             # 机身主色压暗系数（棱角面）
const BODY_W := 0.45                                # 机身宽
const SKID_H := 0.055                               # 雪橇管高（全模型最低点 y=0 由它决定）
const BODY_BOTTOM := 0.10                           # 机身底面高度（雪橇/斜撑在它下面）


## 用基础网格搭一架"俯冲轰炸直升机"，返回根节点（已挂到 parent 下）
static func build(parent: Node3D, body_color: Color) -> Node3D:
	var root := Node3D.new()
	root.name = "HeliModel"
	if parent != null:
		parent.add_child(root)

	var m_body := _mat(body_color, 0.62, 0.10)
	var m_body_dark := _mat(body_color.darkened(BODY_DARK), 0.72, 0.06)
	var m_metal := _mat(COL_METAL, 0.34, 0.75)
	var m_dark := _mat(COL_DARK, 0.55, 0.30)
	var m_glass := _glass()

	_build_fuselage(root, m_body, m_body_dark, m_metal, m_glass)
	_build_main_rotor(root, m_metal, m_dark)
	_build_tail(root, m_body, m_metal, m_dark)
	_build_skids(root, m_metal)
	_build_weapons(root, m_metal, m_dark)
	return root


# ── 材质 ──────────────────────────────────────────────────────────────────────
static func _mat(c: Color, rough: float = 0.7, metal: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m


## 座舱玻璃：蓝黑、半透明、带一点反光
static func _glass() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = GLASS_TINT
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.metallic = 0.35
	m.roughness = 0.12
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


# ── 通用挂件 ──────────────────────────────────────────────────────────────────
static func _add(parent: Node3D, mesh: Mesh, pos: Vector3, rot_deg: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.rotation_degrees = rot_deg
	mi.material_override = mat
	parent.add_child(mi)
	return mi


static func _box(w: float, h: float, d: float) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = Vector3(w, h, d)
	return b


static func _box_at(parent: Node3D, pos: Vector3, rot_deg: Vector3, size: Vector3, mat: Material) -> MeshInstance3D:
	return _add(parent, _box(size.x, size.y, size.z), pos, rot_deg, mat)


static func _cyl(r: float, h: float, seg: int = 12) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = r
	c.bottom_radius = r
	c.height = h
	c.radial_segments = seg
	c.rings = 0
	return c


# ── 机身 ──────────────────────────────────────────────────────────────────────
## 短粗略带棱角的机身：主机匣 + 收缩的机头 + 机背发动机罩 + 前下方俯冲观察窗
static func _build_fuselage(root: Node3D, m_body: Material, m_dark: Material, m_metal: Material, m_glass: Material) -> void:
	var fus := Node3D.new()
	fus.name = "Fuselage"
	root.add_child(fus)

	# 主机匣：长 0.80（z ∈ [−0.40, +0.40]）、宽 0.45、高 0.40（y ∈ [0.10, 0.50]）
	_box_at(fus, Vector3(0, BODY_BOTTOM + 0.20, 0.0), Vector3.ZERO, Vector3(BODY_W, 0.40, 0.80), m_body)
	# 机头：向前收窄，做出"俯冲"的尖鼻子（前缘 z ≈ 0.42）
	_box_at(fus, Vector3(0, 0.295, 0.29), Vector3.ZERO, Vector3(0.34, 0.30, 0.20), m_dark)
	# 机颏（前下方观察窗）：半透明蓝黑，向下俯视用
	_box_at(fus, Vector3(0, 0.195, 0.355), Vector3(-34, 0, 0), Vector3(0.21, 0.055, 0.16), m_glass)
	# 棱角面：机背两侧的倾斜装甲板（PrismMesh 三角棱柱做出斜切感）
	for sx in [-1.0, 1.0]:
		var wedge := PrismMesh.new()
		wedge.size = Vector3(0.13, 0.13, 0.60)
		wedge.left_to_right = sx > 0.0
		_add(fus, wedge, Vector3(sx * 0.185, 0.475, 0.0), Vector3.ZERO, m_dark)
	# 机背发动机罩 + 排气口
	_box_at(fus, Vector3(0, 0.535, 0.0), Vector3.ZERO, Vector3(0.30, 0.10, 0.44), m_body)
	_add(fus, _cyl(0.045, 0.09, 10), Vector3(0, 0.615, -0.10), Vector3(90, 0, 0), m_metal)
	# 座舱：前倾的角状舱盖
	var canopy := PrismMesh.new()
	canopy.size = Vector3(0.32, 0.19, 0.30)
	_add(fus, canopy, Vector3(0, 0.325, 0.215), Vector3(55, 0, 0), m_glass)


# ── 主旋翼（可自转子节点）────────────────────────────────────────────────────
## MainRotor 是 root 直接子节点，中心 (0, 0.585, 0) —— 机身正上方中线上。
## 整体绕本地 Y 轴自转即为桨盘旋转。
static func _build_main_rotor(root: Node3D, m_metal: Material, m_dark: Material) -> void:
	var rotor := Node3D.new()
	rotor.name = "MainRotor"
	rotor.position = Vector3(0, 0.585, 0.0)
	root.add_child(rotor)

	# 旋翼主轴：穿过机背的细柱
	_add(rotor, _cyl(0.026, 0.10, 10), Vector3(0, 0.045, 0), Vector3.ZERO, m_metal)
	# 桨毂
	_add(rotor, _cyl(0.055, 0.035, 12), Vector3(0, 0.085, 0), Vector3.ZERO, m_metal)
	# 4 片细长水平桨叶（十字布置），旋转中心即 rotor 原点
	for i in 4:
		var yaw := float(i) * 90.0
		var blade := _box_at(rotor, Vector3(0, 0.085, 0), Vector3(0, yaw, 0),
			Vector3(0.68, 0.018, 0.062), m_dark)
		blade.name = "Blade%d" % (i + 1)


# ── 尾梁 / 垂直尾翼 / 尾桨 ────────────────────────────────────────────────────
static func _build_tail(root: Node3D, m_body: Material, m_metal: Material, m_dark: Material) -> void:
	var tail := Node3D.new()
	tail.name = "Tail"
	root.add_child(tail)

	# 尾梁：向后伸出的细长条，一直顶到 z = −0.63
	_box_at(tail, Vector3(0, 0.345, -0.505), Vector3.ZERO, Vector3(0.085, 0.085, 0.25), m_body)
	# 尾端垂直尾翼：后掠 25°。中心高度按"旋转后下角恰好落在 y=0"反算，避免扎到地面以下
	_box_at(tail, Vector3(0, 0.50341, -0.615), Vector3(25, 0, 0), Vector3(0.05, 0.32, 0.16), m_metal)
	_box_at(tail, Vector3(0, 0.63341, -0.675), Vector3(25, 0, 0), Vector3(0.055, 0.10, 0.13), m_dark)

	# 尾桨：root 直接子节点，装在尾梁右侧，桨盘竖直（YZ 平面），绕本地 X 轴自转
	var trotor := Node3D.new()
	trotor.name = "TailRotor"
	trotor.position = Vector3(0.115, 0.415, -0.60)
	root.add_child(trotor)
	_add(trotor, _cyl(0.028, 0.045, 10), Vector3(0, 0, 0), Vector3(0, 0, 90), m_metal)
	for i in 3:
		var roll := float(i) * 60.0
		var bl := _box_at(trotor, Vector3(0, 0, 0), Vector3(roll, 0, 0),
			Vector3(0.014, 0.15, 0.026), m_dark)
		bl.name = "TailBlade%d" % (i + 1)


# ── 起落架：两侧斜撑 + 雪橇（雪橇底面 = 局部 y 0，即全模型最低点）──────────────
static func _build_skids(root: Node3D, m_metal: Material) -> void:
	var gear := Node3D.new()
	gear.name = "LandingGear"
	root.add_child(gear)
	for sx in [-1.0, 1.0]:
		# 雪橇：底面 y = 0，顶面 y = SKID_H
		_box_at(gear, Vector3(sx * 0.285, SKID_H * 0.5, 0.0), Vector3.ZERO, Vector3(0.075, SKID_H, 0.86), m_metal)
		# 两根斜撑：从机身底外侧斜撑到雪橇上表面。
		# 中心高度按"倾斜 30° 后下角恰好落在 y=0"反算，与雪橇底面对齐
		for z in [-0.20, 0.20]:
			_box_at(gear, Vector3(sx * 0.222, 0.07837, z), Vector3(0, 0, -sx * 30.0), Vector3(0.045, 0.155, 0.055), m_metal)


# ── 武器挂架：左右各一个朝前的短圆柱（37mm 火箭巢）────────────────────────────
static func _build_weapons(root: Node3D, m_metal: Material, m_dark: Material) -> void:
	var arms := Node3D.new()
	arms.name = "Ordnance"
	root.add_child(arms)
	for sx in [-1.0, 1.0]:
		# 短圆柱火箭巢：轴转到 Z 方向 → 朝前（前端 z ≈ 0.41）
		_add(arms, _cyl(0.072, 0.34, 12), Vector3(sx * 0.275, 0.315, 0.24), Vector3(90, 0, 0), m_metal)
