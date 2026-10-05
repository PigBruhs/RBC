# ══════════════════════════════════════════════════════════════════════════════
# 轮式齐射午餐盒 —— 建模（第 104 轮 · 用户原话照做）
#
# 用户口径（逐字）：
#   "建模你就参考**意大利的那种轮式战车**，车体类似一个**皇室战争里面的宝石**，
#    **全车左右对称前后对称**，**顶面是一个正六边形但是被拉长**，
#    **左右两个斜侧面是长方形**，**俯视图轮廓也是个被拉长的正六边形但是比顶面大一圈**，
#    **侧面的 6 个面（左右两个斜长方形、前后四个斜梯形）都是斜的**，**顶面是水平的**，
#    **上下也对称但是下面左右侧斜长方形上各装了四个轮胎（共 8 个）**"
#   "车顶**左手边**是一个 **0.3 格高**的支架支起来的**正六边形棱柱**"
#   "车体**顶部右半边**还有一个**巡飞弹发射器**（套沙盒元素的模型）"
#
# 实现要点（怎么把"拉长的正六边形"做出来）：
#   · Godot 的 `CylinderMesh` 设 `radial_segments = 6` 就是**正六边形棱柱**；
#     再把节点 `scale` 成 (半宽, 1, 半长) 就得到**被拉长的正六边形**（这就是宝石轮廓）。
#   · 车体 = 上下两个**六边形棱台**（腰最宽 = 俯视轮廓，顶/底各缩一圈 = 上下对称）：
#     顶面那条棱台的 6 个侧面就是用户说的"左右两个斜长方形 + 前后四个斜梯形"，全是斜的 ✅
#     顶面/底面各盖一片**水平**的六边形薄片 ✅
#   · 8 个轮胎装在**下面那条棱台**的左右斜面上（每侧 4 个，沿车长均匀排）✅
#
# 局部坐标约定（与全项目一致）：+Z = 车头方向（= 格坐标的 +y）、+Y = 上、
# 车体中心在原点、占格范围 x∈[-0.5,0.5] z∈[-1,1]（= 1×2 格，与两个碰撞圆柱对齐）。
# ══════════════════════════════════════════════════════════════════════════════
class_name LunchboxModel
extends Node3D

## 单位基础名（`UnitVisual._build_model` 与 `AttackProfile.BY_PREFIX` 都用它匹配）
const LUNCHBOX_NAME := "轮式齐射午餐盒"

const HALF_W := 0.5            # 车体半宽（格）—— 与数据行 body_r 一致（直径 1 格）
const HALF_L := 1.0            # 车体半长（格）—— 1×2 的那两格
const ROOF_Y := 1.0            # 顶面高度（水平面）
const MID_Y := 0.5             # 腰线高度（俯视轮廓最大处；上下对称的对称面）
const ROOF_SHRINK := 0.70      # 顶面比俯视轮廓小一圈

const WHEEL_R := 0.20
const WHEEL_W := 0.16
const WHEEL_Z := [-0.75, -0.25, 0.25, 0.75]     # 每侧 4 个
const WHEEL_Y := 0.20

## 炮塔：车顶**左手边**（车头朝 +z 时，左手边 = -x），支架 0.3 格高，枪口离地 1.3 格
## —— 这两个数与 `Lunchbox.PHI_MIN_DEG = -15°` 的推导是同一套（见 lunchbox.gd）。
const BRACKET_H := 0.3
const TURRET_X := -0.6
const TURRET_Y := 1.3
const PRISM_R := 0.24
const PRISM_H := 0.30
const BARREL_LEN := 0.62
const BARREL_R := 0.055

var _turret: Node3D = null                 # 方向机（绕 y 转）
var _barrel: Node3D = null                 # 高低机（绕 x 转）
var _prism_mat: StandardMaterial3D = null  # 棱柱材质（发红用）
var _body_mat: StandardMaterial3D = null
var _dark_mat: StandardMaterial3D = null
var _metal_mat: StandardMaterial3D = null
var _heat := 0.0
var _theta := 0.0
var _phi := 0.0


static func make() -> LunchboxModel:
	var m := LunchboxModel.new()
	m.build()
	return m


## 挂到 `UnitVisual` 上（与 `ReaperModel.attach` 同一个套路）。
## ⚠ 位置：UnitVisual 在**锚点格**中心，而车占 1×2（锚点 + 沿 +y 一格），
##    所以模型要沿本地 +z 偏 0.5 格 —— 这样车体正好盖住那两个碰撞圆柱。
static func attach(parent: Node3D, tint: Color = Color(0.6, 0.6, 0.6)) -> LunchboxModel:
	var m := LunchboxModel.new()
	m.tint = tint
	m.build()
	m.position = Vector3(0.0, 0.0, 0.5)
	parent.add_child(m)
	return m


## 阵营色（只微微染一下车体，保持"军用涂装"的观感）
var tint: Color = Color(0.6, 0.6, 0.6)


func build() -> void:
	var base := Color(0.62, 0.58, 0.42).lerp(tint, 0.25)     # 沙漠涂装 + 一点阵营色
	_body_mat = _mat(base, 0.15)
	_dark_mat = _mat(base.darkened(0.45), 0.35)
	_metal_mat = _mat(Color(0.30, 0.32, 0.36), 0.55)
	_prism_mat = _mat(Color(0.05, 0.05, 0.06), 0.25)
	_build_hull()
	_build_wheels()
	_build_turret()
	_build_loiter_launcher()


# ── 车体：上下两个六边形棱台（腰最宽）+ 顶面/底面水平六边形 ────────────────────
func _build_hull() -> void:
	var band := (ROOF_Y - MID_Y)                            # 0.5 格：顶->腰 / 腰->底
	# 上棱台：顶面缩一圈 -> 腰最宽（6 个侧面全斜）
	_add_hex_band(ROOF_SHRINK, 1.0, band, MID_Y, _body_mat)
	# 下棱台：腰最宽 -> 底面缩一圈（上下对称）
	_add_hex_band(1.0, ROOF_SHRINK, band, 0.0, _body_mat)
	# 顶面：**水平**的拉长正六边形薄片（比俯视轮廓小一圈）
	_add_hex_plate(ROOF_SHRINK, ROOF_Y, _metal_mat)
	# 底面：同样一片（上下对称）
	_add_hex_plate(ROOF_SHRINK, 0.0, _dark_mat)


## 一片六边形棱台（radial_segments = 6 = 正六边形，scale 拉长 -> 宝石轮廓）
func _add_hex_band(r_top: float, r_bottom: float, h: float, y_bottom: float,
		mat: Material) -> void:
	var cyl := CylinderMesh.new()
	cyl.radial_segments = 6
	cyl.top_radius = r_top
	cyl.bottom_radius = r_bottom
	cyl.height = h
	var mi := MeshInstance3D.new()
	mi.mesh = cyl
	mi.material_override = mat
	mi.position = Vector3(0.0, y_bottom + h * 0.5, 0.0)
	mi.scale = Vector3(HALF_W, 1.0, HALF_L)
	add_child(mi)


## 一片水平的六边形薄片（顶面/底面）
func _add_hex_plate(r: float, y: float, mat: Material) -> void:
	var cyl := CylinderMesh.new()
	cyl.radial_segments = 6
	cyl.top_radius = r
	cyl.bottom_radius = r
	cyl.height = 0.03
	var mi := MeshInstance3D.new()
	mi.mesh = cyl
	mi.material_override = mat
	mi.position = Vector3(0.0, y, 0.0)
	mi.scale = Vector3(HALF_W, 1.0, HALF_L)
	add_child(mi)


# ── 8 个轮胎：装在**下面**那条棱台的左右斜面上（每侧 4 个）─────────────────────
func _build_wheels() -> void:
	var tyre := _mat(Color(0.09, 0.09, 0.10), 0.85)
	for side in [-1.0, 1.0]:
		for z in WHEEL_Z:
			var cyl := CylinderMesh.new()
			cyl.radial_segments = 14
			cyl.top_radius = WHEEL_R
			cyl.bottom_radius = WHEEL_R
			cyl.height = WHEEL_W
			var mi := MeshInstance3D.new()
			mi.mesh = cyl
			mi.material_override = tyre
			# 轮轴沿 x（车宽方向）-> 绕 z 转 90°；略微探出车体（"装在斜面上"）
			mi.rotation_degrees = Vector3(0.0, 0.0, 90.0)
			mi.position = Vector3(side * (HALF_W * 0.92), WHEEL_Y, z)
			add_child(mi)
	# 轮眉：贴在斜面外侧的两条深色长条（一眼看出是轮式）
	for side in [-1.0, 1.0]:
		var box := BoxMesh.new()
		box.size = Vector3(0.06, 0.16, 1.5)
		var mi := MeshInstance3D.new()
		mi.mesh = box
		mi.material_override = _dark_mat
		mi.position = Vector3(side * (HALF_W * 0.98), WHEEL_Y + 0.04, 0.0)
		add_child(mi)


# ── 炮塔：左手边 0.3 格支架 + 正六边形棱柱（方向机绕 y、高低机绕 x）──────────
func _build_turret() -> void:
	# 支架（0.3 格高）
	var bracket := BoxMesh.new()
	bracket.size = Vector3(0.30, BRACKET_H, 0.30)
	var b := MeshInstance3D.new()
	b.mesh = bracket
	b.material_override = _dark_mat
	b.position = Vector3(TURRET_X, ROOF_Y + BRACKET_H * 0.5, 0.0)
	add_child(b)
	# 方向机（yaw）：整体绕 y
	_turret = Node3D.new()
	_turret.position = Vector3(TURRET_X, TURRET_Y, 0.0)
	add_child(_turret)
	# 高低机（pitch）：炮管 + 棱柱一起绕 x
	_barrel = Node3D.new()
	_turret.add_child(_barrel)
	# 正六边形棱柱（发红的就是它）
	var prism := CylinderMesh.new()
	prism.radial_segments = 6
	prism.top_radius = PRISM_R
	prism.bottom_radius = PRISM_R
	prism.height = PRISM_H
	var p := MeshInstance3D.new()
	p.mesh = prism
	p.material_override = _prism_mat
	p.position = Vector3(0.0, 0.0, 0.0)
	_barrel.add_child(p)
	# 炮管：从棱柱中心朝 +z 伸出去（枪口离地 TURRET_Y = 1.3 格）
	var tube := CylinderMesh.new()
	tube.radial_segments = 10
	tube.top_radius = BARREL_R
	tube.bottom_radius = BARREL_R
	tube.height = BARREL_LEN
	var t := MeshInstance3D.new()
	t.mesh = tube
	t.material_override = _metal_mat
	t.rotation_degrees = Vector3(90.0, 0.0, 0.0)          # 圆柱默认沿 y -> 转成沿 z
	t.position = Vector3(0.0, 0.0, BARREL_LEN * 0.5)
	_barrel.add_child(t)


# ── 车顶右半边：巡飞弹发射器（套沙盒那台的造型：底座箱 + 上仰发射管 + 青色光环）──
func _build_loiter_launcher() -> void:
	var root := Node3D.new()
	root.position = Vector3(0.30, ROOF_Y, 0.30)
	add_child(root)
	var box := BoxMesh.new()
	box.size = Vector3(0.30, 0.10, 0.30)
	var b := MeshInstance3D.new()
	b.mesh = box
	b.material_override = _dark_mat
	b.position = Vector3(0.0, 0.05, 0.0)
	root.add_child(b)
	var tube := CylinderMesh.new()
	tube.radial_segments = 10
	tube.top_radius = 0.075
	tube.bottom_radius = 0.085
	tube.height = 0.34
	var t := MeshInstance3D.new()
	t.mesh = tube
	t.material_override = _metal_mat
	t.rotation_degrees = Vector3(-25.0, 0.0, 0.0)          # 上仰 25°（与沙盒那台一致）
	t.position = Vector3(0.0, 0.20, -0.05)
	root.add_child(t)
	var mouth := TorusMesh.new()
	mouth.inner_radius = 0.05
	mouth.outer_radius = 0.078
	var ring_mat := StandardMaterial3D.new()
	ring_mat.albedo_color = Color(0.35, 0.95, 0.95, 0.85)
	ring_mat.emission_enabled = true
	ring_mat.emission = Color(0.30, 0.90, 1.0)
	ring_mat.emission_energy_multiplier = 2.0
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var r := MeshInstance3D.new()
	r.mesh = mouth
	r.material_override = ring_mat
	r.rotation_degrees = Vector3(-25.0, 0.0, 0.0)
	r.position = Vector3(0.0, 0.27, -0.12)
	r.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(r)


# ── 对外接口（battle_scene 每帧调）──────────────────────────────────────────
## 双机角度（度）：theta = 世界方位角（0° = +z / 格坐标 +y，顺时针为正，
## 与 `Vector2.angle()` 同一套），phi = 俯仰（正 = 抬）。
## 角度**保留**（不归位）—— 用户口径："每次射击完毕后角度都保留在最后一次射击时的角度"。
func set_aim(theta_deg: float, phi_deg: float) -> void:
	_theta = theta_deg
	_phi = phi_deg
	if _turret != null:
		# 世界方位角 theta -> 绕 y 的欧拉角：局部 +z 要指向 (cosθ, sinθ) 的格坐标方向
		_turret.rotation_degrees = Vector3(0.0, 90.0 - theta_deg, 0.0)
	if _barrel != null:
		_barrel.rotation_degrees = Vector3(-phi_deg, 0.0, 0.0)


func aim() -> Vector2:
	return Vector2(_theta, _phi)


## 棱柱发红：0 = 黑（冷却后），1 = 最红（第 12 波）。
func set_heat_ratio(r: float) -> void:
	_heat = clampf(r, 0.0, 1.0)
	if _prism_mat == null:
		return
	var c := Color(0.05, 0.05, 0.06).lerp(Color(1.0, 0.12, 0.06), _heat)
	_prism_mat.albedo_color = c
	_prism_mat.emission_enabled = _heat > 0.02
	_prism_mat.emission = c
	_prism_mat.emission_energy_multiplier = 3.0 * _heat


func heat_ratio() -> float:
	return _heat


## 枪口在**本地坐标**里的位置（探针核对"枪口离地 1.3 格 / 横向偏 0.6 格 / 朝向 theta,phi"用）
func muzzle_local() -> Vector3:
	var th := deg_to_rad(_theta)
	var ph := deg_to_rad(_phi)
	# 格坐标方向 (cosθ, sinθ) 在本模型里映射到世界 (x, z)
	var dir := Vector3(cos(ph) * cos(th), sin(ph), cos(ph) * sin(th))
	return Vector3(TURRET_X, TURRET_Y, 0.0) + dir * BARREL_LEN


func _mat(c: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m
