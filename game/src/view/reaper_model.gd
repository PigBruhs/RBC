# ══════════════════════════════════════════════════════════════════════════════
# 大头目 Reaper（质量效应风）：程序化建模，零美术资源，全用 CylinderMesh /
# SphereMesh / TorusMesh 拼装。
#
# 用户原话（造型的唯一依据）：
#   「参考质量效应里面的 Reaper，如果你不知道那个长什么样就是一个大鱿鱼，
#     触须部分接地，然后纺锤型大脑袋，大脑袋中央有一个发光蓝色环，
#     激光攻击时环会先变成红色两秒钟然后再攻击，攻击结束环变回蓝色；
#     注意蓝色环离地高度 6 格」
#
# 局部坐标约定：
#   · +Y = 上，y = 0 = 地面（触须末端真的踩在地上）
#   · 整体高 12.0 格（= body_h）、横向直径 6.0 格（= body_r × 2）
#     ⚠ **视觉包围盒必须与碰撞圆柱一致** —— 否则打起来会"看着打到了却没伤害"
#       （碰撞圆柱在 core：Targeting.unit_body_r / unit_body_h 读 Unit.body_r / body_height）
#   · 蓝环中心离地 **正好 6.0 格**（= Laser.BASE_HEIGHT，激光从环里打出来）
#
# 挂法（与 heli_model.gd 同一个套路）：UnitVisual._build_model() 里
#   ReaperModel.attach(self, _faction_color())  -> 作为 UnitVisual 的子节点挂上去，
#   这样头顶血条/护甲环/走路补间那套 UnitVisual 机制全部照常工作。
# 测试也可以直接 ReaperModel.make() 造一个独立的（probe_reaper.gd 就是这么验的）。
# ══════════════════════════════════════════════════════════════════════════════
class_name ReaperModel
extends Node3D

## 蓝环中心离地高度（格）。= 激光基准高度，**不能改**（用户口径 + 探针断言）。
const RING_Y := 6.0
## 环的中心线半径 / 径向厚度：比 y=6 处的大脑袋半径（≈1.70）略大，看起来是"嵌在头上"。
const RING_R := 1.85
const RING_THICK := 0.30

## 与 UnitData 里 Reaper 那一行的 body_r / body_h 对齐（改数据行要同步改这里）。
const MODEL_R := 3.0           # 横向半径 -> 直径 6.0
const MODEL_H := 12.0          # 总高

const LEGS := 10               # 触须条数（用户要求"像鱿鱼腿"，不是一圈柱子）
const LEG_ATTACH_R := 1.05     # 触须根部离中轴的距离
const LEG_ATTACH_Y := 4.20     # 触须根部高度（接在大脑袋下缘）
const LEG_ELBOW_R := 2.05      # 中段拐点（做出"腿"的弧度）
const LEG_ELBOW_Y := 2.00
const LEG_FOOT_R := 2.90       # 末端中心（+ 脚爪球半径 0.10 -> 最大半径正好 3.00）
const LEG_FOOT_Y := 0.10

const HEAD_BOTTOM := 3.50      # 纺锤头下尖
const HEAD_FAT_R := 1.70       # 最粗处半径（在 y = 6.0，与蓝环同高）
const HEAD_TOP := 12.0         # 上尖（= 总高）

const COL_CARAPACE := Color(0.26, 0.28, 0.34)        # 甲壳主色（冷灰蓝）
const COL_CARAPACE_DK := Color(0.14, 0.15, 0.19)     # 触须（更深，压出层次）
const COL_BLUE := Color(0.20, 0.62, 1.00)            # 蓝环（常态）
const COL_RED := Color(1.00, 0.16, 0.12)             # 蓝环（激光预警）

var _ring: MeshInstance3D = null
var _ring_mat: StandardMaterial3D = null


## 造一个建好模的 Reaper（独立节点，没爹）。测试/探针用这个。
static func make() -> ReaperModel:
	var m := ReaperModel.new()
	m.name = "ReaperModel"
	m.build()
	return m


## 照 heli_model 的接法：挂到 parent（通常是一个 UnitVisual）底下。
static func attach(parent: Node3D, _faction_color: Color = COL_BLUE) -> ReaperModel:
	var m := make()
	if parent != null:
		parent.add_child(m)
	return m


## 建出触须（接地）+ 纺锤型大脑袋 + 中央发光蓝环。
func build() -> void:
	for c in get_children():
		c.queue_free()
	_build_legs()
	_build_head()
	_build_ring()


# ── 触须：下宽上窄的裙摆，末端真的贴地 ────────────────────────────────────────
func _build_legs() -> void:
	var mat := _mat(COL_CARAPACE_DK, 0.85, 0.05)
	var mat_tip := _mat(COL_CARAPACE, 0.75, 0.10)
	for i in LEGS:
		# 每条腿略微错开（长度/粗细/张开角都有小幅差异）—— 看起来才像鱿鱼腿
		var a := TAU * float(i) / float(LEGS)
		# 确定性抖动，不用随机数。**只往内收（<= 1.0）**，并且第 0 条腿不抖 ——
		# 这样"最大半径"恰好是 LEG_FOOT_R + 爪球半径 = 3.00，视觉包围盒与碰撞圆柱严格对齐。
		var wob := 1.0 if i == 0 else 1.0 - 0.06 * (0.5 + 0.5 * sin(float(i) * 2.399))
		var foot_r := LEG_FOOT_R * wob
		var elbow_r := LEG_ELBOW_R * wob
		var top := Vector3(cos(a) * LEG_ATTACH_R, LEG_ATTACH_Y, sin(a) * LEG_ATTACH_R)
		var elbow := Vector3(cos(a) * elbow_r, LEG_ELBOW_Y, sin(a) * elbow_r)
		var foot := Vector3(cos(a) * foot_r, LEG_FOOT_Y, sin(a) * foot_r)
		# 上段（粗，从根部斜向外下）
		_seg(top, elbow, 0.19, 0.13, mat)
		# 下段（细，继续外张到地面）
		_seg(elbow, foot, 0.13, 0.075, mat)
		# 脚爪球（贴地；中心 0.10 + 半径 0.10 -> 最低点正好 y = 0）
		var claw := MeshInstance3D.new()
		claw.mesh = _sphere(0.10)
		claw.position = foot
		claw.material_override = mat_tip
		add_child(claw)


# ── 纺锤型大脑袋：下尖 -> y=6 最粗 -> 上尖，竖直拉长 ──────────────────────────
func _build_head() -> void:
	var mat := _mat(COL_CARAPACE, 0.72, 0.18)
	# 下半：从下尖张开到最粗处
	var lower := MeshInstance3D.new()
	lower.mesh = _cone(HEAD_FAT_R, 0.22, RING_Y - HEAD_BOTTOM)
	lower.position = Vector3(0.0, (HEAD_BOTTOM + RING_Y) * 0.5, 0.0)
	lower.material_override = mat
	add_child(lower)
	# 上半：从最粗处收到上尖（更长 -> 纺锤感）
	var upper := MeshInstance3D.new()
	upper.mesh = _cone(0.10, HEAD_FAT_R, HEAD_TOP - RING_Y)
	upper.position = Vector3(0.0, (RING_Y + HEAD_TOP) * 0.5, 0.0)
	upper.material_override = mat
	add_child(upper)
	# 最粗处那一圈"肚子"：把两段锥体接缝抹圆，同时也是蓝环的底座
	var belly := MeshInstance3D.new()
	var sm := _sphere(HEAD_FAT_R)
	belly.mesh = sm
	belly.scale = Vector3(1.0, 0.34, 1.0)
	belly.position = Vector3(0.0, RING_Y, 0.0)
	belly.material_override = mat
	add_child(belly)


# ── 中央发光蓝环（离地正好 RING_Y）────────────────────────────────────────────
func _build_ring() -> void:
	_ring = MeshInstance3D.new()
	_ring.name = "Ring"
	var t := TorusMesh.new()
	t.inner_radius = RING_R - RING_THICK * 0.5
	t.outer_radius = RING_R + RING_THICK * 0.5
	t.rings = 48
	t.ring_segments = 14
	_ring.mesh = t
	_ring.position = Vector3(0.0, RING_Y, 0.0)     # ← 离地正好 6 格
	_ring_mat = _glow(COL_BLUE)
	_ring.material_override = _ring_mat
	add_child(_ring)


## 蓝 <-> 红：激光预警那 2 秒由 AI 调成红，打完调回蓝。立刻生效。
func set_ring_color(c: Color) -> void:
	if _ring_mat == null:
		return
	_ring_mat.albedo_color = c
	_ring_mat.emission = c
	if _ring != null:
		_ring.visible = true          # 预警时哪怕被遮住也要看得见


func ring_color() -> Color:
	return COL_BLUE if _ring_mat == null else _ring_mat.albedo_color


## 蓝环节点的局部高度（探针断言它 == RING_Y）
func ring_y() -> float:
	return RING_Y if _ring == null else _ring.position.y


# ── 图元helpers ──────────────────────────────────────────────────────────────
func _seg(a: Vector3, b: Vector3, r_top: float, r_bot: float, mat: Material) -> void:
	var mid := (a + b) * 0.5
	var d := b - a
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r_top
	cm.bottom_radius = r_bot
	cm.height = maxf(0.01, d.length())
	cm.radial_segments = 8
	mi.mesh = cm
	# 圆柱默认沿本地 +Y：把 +Y 旋到 a->b 方向
	mi.transform = Transform3D(_basis_y(d.normalized()), mid)
	mi.material_override = mat
	add_child(mi)


func _basis_y(y: Vector3) -> Basis:
	var up := y
	if up.length_squared() < 0.000001:
		up = Vector3.UP
	up = up.normalized()
	var ref := Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var x := ref.cross(up).normalized()
	var z := x.cross(up).normalized()
	return Basis(x, up, z)


func _cone(r_top: float, r_bot: float, h: float) -> CylinderMesh:
	var cm := CylinderMesh.new()
	cm.top_radius = r_top
	cm.bottom_radius = r_bot
	cm.height = h
	cm.radial_segments = 24
	return cm


func _sphere(r: float) -> SphereMesh:
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	sm.radial_segments = 20
	sm.rings = 10
	return sm


func _mat(c: Color, rough: float = 0.7, metal: float = 0.1) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m


## 自发光材质（蓝环）：颜色可随时改（红/蓝预警）
func _glow(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = 2.4
	m.roughness = 0.25
	return m
