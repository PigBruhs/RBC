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

## 炮塔：车顶**左手边**（车头朝 +z 时，左手边 = -x），**一根棍子**支起炮管，
## 支点在棱柱的**前 2/3 处**（后 1/3）；枪口离地 1.3 格
## —— 这两个数与 `Lunchbox.PHI_MIN_DEG = -15°` 的推导是同一套（见 lunchbox.gd）。
## ⚠ 用户第 105 轮口径：
##   · 支架是**一根棍子**（不是方块底座）
##   · **六边形棱柱炮管长 0.7 格**
##   · 棱柱的**中轴线（顶面六边形中心 -> 底面六边形中心）= 瞄准方向**
##   · 支点在整个棱柱的 **2/3 处**：炮口那侧探出 2/3、后方留 1/3
## 用户口径（第 107 轮）：**把支架改到车正中间**（覆盖第 105 轮"车顶左手边"那条）。
## 实测（第 107 轮）：车顶面薄片的 x 范围只有 ±0.303（半径 ROOF_SHRINK=0.7 × HALF_W=0.5，再被
## 六边形顶点决定），而旧值 x=-0.6 **落在车顶面之外**整整 0.297 格 —— 支架下端 y 虽然等于 ROOF_Y(1.0)，
## 但那一点在**车顶之外**、下面是棱台侧面收进去的空气，所以看起来"没接上车体"。
## 挪到 x=0（车正中间）后，支架正好落在车顶面中心、下端 y=ROOF_Y 与顶面完全贴合。
## ⚠ 转塔支点（_turret.position）也用这个常量 -> 支架与炮管支点一起挪，不会错开。
const TURRET_X := 0.0
## 用户口径（第 106 轮）：**炮管离【车】高度一格** —— 是离**车顶**（ROOF_Y）一格，不是离地。
## 所以 TURRET_Y = ROOF_Y + 1.0 = 2.0（第 105 轮这里是"离地 1.3"，即离车顶只有 0.3）。
const TURRET_LIFT := 1.0                         # 炮管轴线离**车顶**的高度（格）
const TURRET_Y := ROOF_Y + TURRET_LIFT
## 用户口径：**中间用一根圆柱支撑**。第 105 轮的 0.045 太细、看不清（而且棍长只有 0.3），
## 现在棍长 = TURRET_LIFT = 1.0 格，半径加粗到 0.09 —— 明显可见，又远小于棱柱半径 0.34，不会挡住炮管。
const STICK_R := 0.09
## 用户口径（第 106 轮）：**炮管长度延伸至 1.2 格**（第 105 轮是 0.70）。
## 支点仍在"前 2/3 / 后 1/3"处（下一行的 BARREL_BACK_FRAC）-> 前端 0.80、尾端 0.40。
const BARREL_LEN := 1.20
const BARREL_BACK_FRAC := 1.0 / 3.0         # 支点之后的占比（= 前 2/3 探出）
const PRISM_R := 0.34                       # 棱柱半径（用户要求『比现在大』：0.24 -> 0.34）
## 炮管从 0.70 涨到 1.20（1.7 倍），嘴也跟着放大，否则 1.2 格炮管前面挂个过小的嘴
const MUZZLE_LEN := 0.24                    # 棱柱前端再探出的细管（纯装饰）
const MUZZLE_R := 0.11

## 棱柱炮管那个网格节点的名字。⚠ 车顶**右侧的巡飞弹发射器也有一圈六边形光环**
## （同样 `radial_segments == 6`），所以探针/测试**不能靠"找六边形"来定位炮管**，
## 必须按名字找 —— 这里给它一个稳定名字。
const BARREL_PRISM_NAME := "TurretPrism"
const BODY_ROOT_NAME := "BodyRoot"          # 车体容器（测试按名字/门面定位）
const LOITER_ROOT_NAME := "LoiterLauncher"  # 巡飞弹发射器根（第 108 轮挪到车尾）
## ── 巡飞弹发射器（第 109 轮：**探出车尾** + **高于炮管最高点** + 支架托住）──────────────
## 用户口径：「我说探出车尾且比炮管顶部高」。
## ⚠ 高度依据是**实测**、不是常数：炮管仰到 PHI_MAX(60°) 时，炮塔子树的**实际最高点 = 2.956**
##   （不是"轴线 2.0 + 棱柱半径 0.34 = 2.34" —— 仰起后炮口/棱柱端起会更高）。
##   所以发射器底座取 3.10（底部 > 2.956，余量 0.144）。
## z 依据：车顶面 z∈±0.700、车体 z∈±1.000；发射器本地 z∈[-0.199,+0.150]，
##   中心放 -1.05 -> 世界 z∈[-1.249,-0.900]：**后沿探出车体 0.249 格** ✅ 且前半仍压在车尾上方。
const LOITER_Z := -1.05
const LOITER_Y := 3.10
const LOITER_POST_R := 0.060         # 支架立柱半径（从车体伸出来托住它，不能凭空浮）
const LOITER_ARM_R := 0.050          # 水平支臂半径
const LOITER_ARM_Z := -0.60          # 支臂起点 z（在车顶面 ±0.700 之内 -> "从车顶伸出来"）
const LOITER_ARM_Y := 1.05           # 支臂高度（贴着车顶面 y≈1.015 上方一点）

var _turret: Node3D = null                 # 方向机（绕 y 转）
var _barrel: Node3D = null                 # 高低机（绕 x 转）
var _prism_mesh: MeshInstance3D = null     # 六边形棱柱炮管（测试按名字/这个引用定位）
var _prism_mat: StandardMaterial3D = null  # 棱柱材质（发红用）
var _body_mat: StandardMaterial3D = null
var _dark_mat: StandardMaterial3D = null
var _metal_mat: StandardMaterial3D = null
## 车体容器（第 107 轮延续：**车体朝向与炮管解耦**）。
## 用户口径：「载具的精髓就是移动与瞄准方向不一致（战列舰：车体向前、炮管垂直车体向左）」。
## 只有【车体棱台/顶底板 + 8 轮 + 轮眉 + 车顶巡飞弹发射器】挂它下面；
## **支架 / 方向机 `_turret` / 高低机 `_barrel` / 棱柱炮管都不在它下面** ——
## 所以 `set_body_yaw()` 转不动炮管，`set_aim(theta, phi)` 的"世界方位角 theta"语义保持不变。
var _body_root: Node3D = null
var _body_yaw := 0.0

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
	# 车体容器必须在 _build_hull 之前建好（车体/轮子/发射器都挂它下面）
	_body_root = Node3D.new()
	_body_root.name = BODY_ROOT_NAME
	add_child(_body_root)
	_build_hull()
	_build_wheels()
	_build_turret()
	_build_loiter_launcher()
	# 初始朝向 = **网格 +y**（= 方位角 90°，与 1×2 占格的长轴一致；容器的 identity 变换就是它）。
	# 显式调一次，让 ody_yaw() 报出来的数**与实际几何一致**（否则默认报 0 但车头其实朝 +y）。
	set_body_yaw(90.0)


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
	_body_root.add_child(mi)


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
	_body_root.add_child(mi)


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
			_body_root.add_child(mi)
	# 轮眉：贴在斜面外侧的两条深色长条（一眼看出是轮式）
	for side in [-1.0, 1.0]:
		var box := BoxMesh.new()
		box.size = Vector3(0.06, 0.16, 1.5)
		var mi := MeshInstance3D.new()
		mi.mesh = box
		mi.material_override = _dark_mat
		mi.position = Vector3(side * (HALF_W * 0.98), WHEEL_Y + 0.04, 0.0)
		_body_root.add_child(mi)


# ── 炮塔：左手边 0.3 格支架 + 正六边形棱柱（方向机绕 y、高低机绕 x）──────────
func _build_turret() -> void:
	# ── 最低俯角 PHI_MIN_DEG 的重算（第 106 轮：炮管抬高后必须复核）────────────────
# 约束：**最低俯角时炮口不能低于车顶**（否则打到自己）。炮口距支点 = BARREL_LEN*(1-BACK)+MUZZLE = 0.80+0.24/2 = 0.92。
#   旧高度 h=1.3：1.3 - 0.92·tan15° = 1.3 - 0.246 = 1.054 > ROOF_Y(1.0)  —— 只余 0.05，很紧
#   新高度 h=2.0：2.0 - 0.92·tan15° = 2.0 - 0.246 = **1.754** > ROOF_Y(1.0) —— **余量 0.75** ✅
# 结论：**PHI_MIN_DEG = -15° 仍然安全，而且余量从 0.05 涨到 0.75**（本轮不需要改 lunchbox.gd）。
# 顺带：现在即便压到 -40°（2.0 - 0.92·tan40° = 1.228）也还在车顶之上 —— 以后想让它压得更低有空间。
# ────────────────────────────────────────────────────────────────────────────
# 支架 = **一根棍子**（用户第 105 轮口径："一根棍子支撑着一个水平放置的六边形棱柱炮管的 2/3 处"）。
	# 棍子从车顶竖直上来，支点在整个棱柱的 **前 2/3 / 后 1/3** 处
	# —— 即支点偏后、**炮口那侧探出 2/3**（`BARREL_BACK_FRAC` 是支点之后的那 1/3）。
	var stick_h: float = TURRET_Y - ROOF_Y
	var stick := CylinderMesh.new()
	stick.radial_segments = 8
	stick.top_radius = STICK_R
	stick.bottom_radius = STICK_R
	stick.height = stick_h
	var s := MeshInstance3D.new()
	s.mesh = stick
	s.material_override = _dark_mat
	s.position = Vector3(TURRET_X, ROOF_Y + stick_h * 0.5, 0.0)
	add_child(s)
	# 方向机（yaw）：整体绕 y
	_turret = Node3D.new()
	_turret.position = Vector3(TURRET_X, TURRET_Y, 0.0)
	add_child(_turret)
	# 高低机（pitch）：棱柱炮管绕 x
	_barrel = Node3D.new()
	_turret.add_child(_barrel)
	# 炮管 = **水平放置的正六边形棱柱**，长 0.7 格。
	# ⚠ 关键（用户口径）：**棱柱的中轴线 = 瞄准方向** ——
	#   `CylinderMesh` 的轴默认是**局部 +y**，所以这里把它转成**局部 +z**（= 瞄准轴），
	#   于是"顶面六边形中心 -> 底面六边形中心"这条线就指向炮口方向。
	#   同时把它**沿 -z 偏移**，让棍子的支点落在"前 2/3 / 后 1/3"处。
	var prism := CylinderMesh.new()
	prism.radial_segments = 6
	prism.top_radius = PRISM_R
	prism.bottom_radius = PRISM_R
	prism.height = BARREL_LEN
	var p := MeshInstance3D.new()
	p.mesh = prism
	p.material_override = _prism_mat
	p.name = BARREL_PRISM_NAME
	p.rotation_degrees = Vector3(90.0, 0.0, 0.0)      # 轴：局部 +y -> 局部 +z
	# 棱柱中心相对支点：朝炮口方向偏 (0.5 - 后段占比) × 全长
	p.position = Vector3(0.0, 0.0, BARREL_LEN * (0.5 - BARREL_BACK_FRAC))
	_barrel.add_child(p)
	_prism_mesh = p
	# 炮口：棱柱最前端再探出一小截细管（纯装饰，让"枪口"看得出来）
	var tube := CylinderMesh.new()
	tube.radial_segments = 10
	tube.top_radius = MUZZLE_R
	tube.bottom_radius = MUZZLE_R
	tube.height = MUZZLE_LEN
	var t := MeshInstance3D.new()
	t.mesh = tube
	t.material_override = _metal_mat
	t.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	t.position = Vector3(0.0, 0.0, BARREL_LEN * (1.0 - BARREL_BACK_FRAC) + MUZZLE_LEN * 0.5)
	_barrel.add_child(t)


# ── 车顶右半边：巡飞弹发射器（套沙盒那台的造型：底座箱 + 上仰发射管 + 青色光环）──
func _build_loiter_launcher() -> void:
	var root := Node3D.new()
	root.name = LOITER_ROOT_NAME
	# 用户口径（第 108 轮）：「巡飞弹发射器现在被藏在了炮管底下；请把它挪到车的尾部
	#   （即现在是 x 方向，我需要它在 z 方向）」。
	# 车头 = 本地 +z（第 107 轮车体容器口径），所以**车尾 = 本地 -z**。
	# 位置依据（实测，见任务报告的包围盒）：
	#   · 车顶面薄片本地 z 跨度 = ±0.700、x 跨度 = ±0.303（六边形顶点决定）
	#   · 发射器底座箱 0.30×0.30 -> 居中放在 z=-0.50 时占 z[-0.65,-0.35]、x[-0.15,0.15]
	#     => 完整落在车顶面**之内**（z 余量 0.05、x 余量 0.15），不悬空
	#   · x = 0 居中；与炮塔轴线（TURRET_X=0，在本地 z=0）**在 z 上分离 0.50 格**
	root.position = Vector3(0.0, LOITER_Y, LOITER_Z)
	_body_root.add_child(root)          # 车顶设备：跟着**车体**转（不属于炮塔）
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
	# 朝向（第 109 轮决定）：**朝车头(+z)上仰 25°**，即"从车尾越过车体向前发射"。
	# 理由：车头=本地 +z（第 107 轮车体口径），车本来就是朝 +z 推进、朝 +z 打敌人的；
	#   发射器已经在车尾外侧，若朝后上方就等于"朝背离敌人的方向发射"，读起来是反的。
	#   朝前越过车体也与真实车载发射巢一致（车尾发射、越过驾驶室）。仰角仍是 25°。
	t.rotation_degrees = Vector3(25.0, 0.0, 0.0)
	t.position = Vector3(0.0, 0.20, 0.05)
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
	r.rotation_degrees = Vector3(25.0, 0.0, 0.0)
	r.position = Vector3(0.0, 0.27, 0.12)
	r.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(r)

	# ── 支架（第 109 轮）：**立柱 + 水平支臂**，让探出车尾的高位发射器"看起来连着车体" ──
	# 支臂：从车顶面内 (z=LOITER_ARM_Z, y=LOITER_ARM_Y) 水平伸到立柱脚下 -> 视觉上从车顶长出来
	var arm_len: float = absf(LOITER_Z - LOITER_ARM_Z)
	var arm_cyl := CylinderMesh.new()
	arm_cyl.radial_segments = 8
	arm_cyl.top_radius = LOITER_ARM_R
	arm_cyl.bottom_radius = LOITER_ARM_R
	arm_cyl.height = arm_len
	var arm := MeshInstance3D.new()
	arm.mesh = arm_cyl
	arm.material_override = _dark_mat
	arm.name = "LoiterArm"
	arm.rotation_degrees = Vector3(90.0, 0.0, 0.0)            # 圆柱轴 +y -> +z（水平）
	arm.position = Vector3(0.0, LOITER_ARM_Y, (LOITER_ARM_Z + LOITER_Z) * 0.5)
	_body_root.add_child(arm)          # 结构件：坐标是**模型本地**，所以挂车体容器（不是 root）
	# 立柱：从支臂一路顶到发射器底座
	var post_h: float = LOITER_Y - LOITER_ARM_Y
	var post_cyl := CylinderMesh.new()
	post_cyl.radial_segments = 8
	post_cyl.top_radius = LOITER_POST_R
	post_cyl.bottom_radius = LOITER_POST_R
	post_cyl.height = post_h
	var post := MeshInstance3D.new()
	post.mesh = post_cyl
	post.material_override = _dark_mat
	post.name = "LoiterPost"
	post.position = Vector3(0.0, LOITER_ARM_Y + post_h * 0.5, LOITER_Z)
	_body_root.add_child(post)         # 同上：挂在立柱所在的 z（模型本地）


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


## ── 车体朝向（底盘 yaw）与炮管**解耦**（第 107 轮延续）────────────────────────
## 用户口径：
##   · 车体**只在移动时**转向、**没有延迟**（瞬间转）、停下保持最后朝向；
##   · 炮管**随时可转**（10°/s、5°/s 的延迟照旧），**移动中哨兵照样生效**；
##   · 「载具的精髓就是移动与瞄准方向不一致」（战列舰：车体向前、炮管垂直向左）。
##
## **角度约定与 `set_aim(theta)` 完全一致**：0° = 网格 +x（世界 +x）、90° = 网格 +y（世界 +z）、
## 顺时针为正（`Vector2.angle()` 同一套）。所以调用方可以用**同一个方位角**分别喂两个接口：
##   移动方向 -> `set_body_yaw(deg)`；瞄准方向 -> `set_aim(deg, phi)`，两者互不影响。
##
## ⚠ 实现（方案 a）：只转 `_body_root`（车体+轮子+轮眉+车顶发射器），
##   **不碰 `_turret` / `_barrel`** —— 所以炮管的 theta/phi 语义零变化。
##   公式与 `set_aim` 里的方向机一致（本地 +z 是车头，转 (90-deg) 让它指向方位角 deg）。
##
## 调用方（`battle_scene`，**由 Lead 接线**）应当在**移动指令下达/移动开始那一刻**调用一次：
##   `model.set_body_yaw(rad_to_deg((目标格 - 当前格).angle()))` —— 不要插值、不要每帧调。
## **停下不要回正**（用户口径）；炮管的瞄准由既有的 `set_aim` 那条链自己走。
func set_body_yaw(deg: float) -> void:
	_body_yaw = deg
	if _body_root != null:
		_body_root.rotation_degrees = Vector3(0.0, 90.0 - deg, 0.0)


func body_yaw() -> float:
	return _body_yaw


## ── 最大高度（第 109 轮，根治"条子被仰起的炮管顶到"的脆弱性）─────────────────
## **问题**：`UnitVisual._model_top_y()` 是**建模型那一刻**量包围盒 —— 那时炮管是水平的
##   （`phi = 0`，顶 2.34）。而现在模型顶由**车尾发射器**决定（3.49），恰好 > 炮管在
##   `PHI_MAX` 的实顶（2.956），所以"条子抬到 3.49 以上"**顺带**覆盖了仰起的炮管。
##   但这是**巧合**：谁把发射器降到 2.956 以下，仰起的炮管就会重新顶到条子，而公式不知道。
##
## **根治**：让模型**主动报价**"我这辈子能长到的最高点" = max(当前姿态实测, 炮管扫掠顶)。
##   `UnitVisual` 用它代替 `_model_top_y()` 的结果。
##
## ⚠ **必须在"基准姿态"下量**：调用方（`_model_top_y`）先把炮管归零再调这里，
##   所以实测那一项是可信的；否则会把"已经仰起的炮管"当成静态顶重复计入。
## · **遍历全部 theta**：炮管绕 y 扫掠时，同一个 `phi` 下的最高点与 theta 无关
##   （绕 y 转不改变高度）—— 但**棱柱有半径**，转动时它的外沿会画出一个圆盘，
##   所以稳妥起见还是扫一圈（8 个方位足够，量的是 AABB 端点，误差可忽略）。
func max_height() -> float:
	var cur := _measure_top()
	if _turret == null or _barrel == null:
		return cur
	var saved_t := _turret.rotation_degrees
	var saved_b := _barrel.rotation_degrees
	var top := cur
	# phi 取正的最大仰角（负值是压炮口，一定更低）
	for i in 8:
		var th := 45.0 * float(i)
		_turret.rotation_degrees = Vector3(0.0, 90.0 - th, 0.0)
		_barrel.rotation_degrees = Vector3(-PHI_MAX_DEG_REF, 0.0, 0.0)
		top = maxf(top, _measure_top())
	_turret.rotation_degrees = saved_t
	_barrel.rotation_degrees = saved_b
	return top


## 炮管在最高仰角时的度数（与 `Lunchbox.PHI_MAX_DEG` 同值）。
## ⚠ 这里**自己写一份常量**而不是 import `Lunchbox`：`lunchbox_model.gd` 是**表现层**，
##   不该依赖 `core/lunchbox.gd` 的机制常量；两处都有断言锁（`probe_turret`）。
const PHI_MAX_DEG_REF := 60.0


## 量当前姿态下、以 self 为根的子树最高点（与 `UnitVisual._model_top_y` 同一套算法：
## 沿父链累加变换到 self，再取 8 个 AABB 端点）。
func _measure_top() -> float:
	var top := 0.0
	for mi in _meshes(self):
		var t := Transform3D.IDENTITY
		var n: Node = mi
		while n != null and n != self:
			t = (n as Node3D).transform * t
			n = n.get_parent()
		var aabb: AABB = (mi as MeshInstance3D).get_aabb()
		for k in 8:
			var y: float = (t * aabb.get_endpoint(k)).y
			if y > top:
				top = y
	return top


func _meshes(n: Node, out: Array = []) -> Array:
	for c in n.get_children():
		if c is MeshInstance3D:
			out.append(c)
		_meshes(c, out)
	return out


## 棱柱发红 + 变亮（用户第 105 轮口径）：
##   · **整根棱柱一起变红**（同一个 `_prism_mat` 覆盖整个六边形棱柱的每一面，所以天然一致）
##   · **变红的同时要变亮** —— 在"热量 -> 颜色"之外**再加一条"热量 -> 亮度"映射**
##   · **冷却时逐渐变黑**（`r` 是连续值，所以插值是**平滑**的，不是阶梯）
##   · 0 = 黑（冷却后），1 = 最红最亮（第 12 波）
const HEAT_COLD := Color(0.05, 0.05, 0.06)      # 冷却后的深色
const HEAT_HOT := Color(1.0, 0.12, 0.06)        # 最红
const HEAT_EMIT_MIN := 0.35                     # 亮度下限（热量 0 也留一点自发光，避免"跳黑"）
const HEAT_EMIT_MAX := 6.0                      # 亮度上限（热量 1 时明显更亮）

func set_heat_ratio(r: float) -> void:
	_heat = clampf(r, 0.0, 1.0)
	if _prism_mat == null:
		return
	# ① 热量 -> 颜色（平滑 lerp）
	var c := HEAT_COLD.lerp(HEAT_HOT, _heat)
	_prism_mat.albedo_color = c
	# ② 热量 -> 亮度（独立的一条映射；**始终开启自发光**，靠倍率连续变化，
	#    这样热量从 1 掉到 0 的过程是逐渐变暗 -> 变黑，不会在中途跳一下）
	_prism_mat.emission_enabled = true
	_prism_mat.emission = c
	_prism_mat.emission_energy_multiplier = lerpf(HEAT_EMIT_MIN, HEAT_EMIT_MAX, _heat)


func heat_ratio() -> float:
	return _heat


## ── 测试门面（第 105 轮）────────────────────────────────────────────────
## ⚠ 车顶右侧的巡飞弹发射器也有一圈六边形光环（同样 `radial_segments == 6`），
## 所以测试**不能靠"找六边形"定位炮管** —— 这几个访问器就是为此存在的。
func t_prism() -> MeshInstance3D:
	return _prism_mesh


func t_body_root() -> Node3D:
	return _body_root


func t_loiter_root() -> Node3D:
	return _body_root.get_node_or_null(LOITER_ROOT_NAME) as Node3D


func t_elevation() -> Node3D:
	return _barrel


func t_traverse() -> Node3D:
	return _turret


## 炮口在**本地坐标**里的位置（= 支点 + 朝向 × 炮管长）。
## ⚠ 这是炮口位置的**唯一实现** —— `battle_scene._lb_muzzle` 通过它取炮口，
##   不要再各写一份（第 106 轮踩过：两份实现并存，用了漏掉炮管长度的那份）。
func muzzle_local_at(theta_deg: float, phi_deg: float) -> Vector3:
	var th := deg_to_rad(theta_deg)
	var ph := deg_to_rad(phi_deg)
	# 格坐标方向 (cosθ, sinθ) 在本模型里映射到世界 (x, z)
	var dir := Vector3(cos(ph) * cos(th), sin(ph), cos(ph) * sin(th))
	return Vector3(TURRET_X, TURRET_Y, 0.0) + dir * BARREL_LEN


## 当前朝向下的炮口（用模块自己记的 theta/phi）
func muzzle_local() -> Vector3:
	return muzzle_local_at(_theta, _phi)


func _mat(c: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m
