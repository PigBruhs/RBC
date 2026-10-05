# ══════════════════════════════════════════════════════════════════════════════
# 雷达午餐盒 —— 建模（第 111 轮 · 用户原话照做，**纯视觉，不碰逻辑**）
#
# 用户原话（逐字）：
#   「新增角色：**雷达午餐盒** 建模：**一个午餐盒车身，顶部支架上一个旋转的雷达**
#     40护甲40力量 移动距离6 精力0」
#
# ── 为什么 `extends LunchboxModel`（关键决策）───────────────────────────────
# 用户口径要的是**同一个"午餐盒车身"**（第 104~110 轮打磨出来的六边形宝石车体 + 8 轮胎），
# 只是**没有炮塔 / 炮管 / 巡飞弹发射器**，车顶换成"立柱 + 旋转雷达"。
# 所以这里直接继承 `LunchboxModel`，**只复用它的车体那两层**：
#   · `_build_hull()` / `_add_hex_band()` / `_add_hex_plate()` / `_build_wheels()` —— 逐字复用
#   · `_mat()` / `_body_mat` / `_dark_mat` / `_metal_mat` —— 复用同一套配色
#   · `BODY_ROOT_NAME` / `_body_root` / `set_body_yaw()` —— 复用"车体层与瞄准解耦"的容器口径
#   · 坐标口径逐字继承：**车体长轴 = 本地 +z**、`attach()` 的 `position = Vector3(0,0,0.5)`
#     是 1×2 占格的锚点偏移（与数据行 `foot_y = 2` / `body_r = 0.5` 对齐）
# **不调用** `_build_turret()` 与 `_build_loiter_launcher()`，所以本模型
# **没有炮塔/高低机/炮管/棱柱/炮口/巡飞弹发射器**（`_turret` / `_barrel` 永远是 null）。
#
# 层次（⚠ 结构件全部挂 `BodyRoot`，转底盘时整体跟着转）：
#   雷达午餐盒 (RadarModel)
#    └ BodyRoot                       ← 车体层（`set_body_yaw` 转的就是它）
#       ├ 上/下六边形棱台 + 顶/底面板 + 8 轮胎 + 轮眉      ← 复用午餐盒车身
#       ├ RadarPost   立柱（车顶正中竖直上来）
#       └ RadarYaw    旋转部（绕 y）→ RadarBar 横杆 + RadarDish 碟面 + 馈源
#
# 局部坐标：+Z = 车头（= 网格 +y）、+Y = 上，车体 x∈[-0.5,0.5] z∈[-1,1]（1×2 格）。
# ══════════════════════════════════════════════════════════════════════════════
class_name RadarModel
extends LunchboxModel

## 单位基础名（`UnitVisual._build_model` 用它匹配；与 `Radar.NAME` / 数据行同名）
const RADAR_NAME := "雷达午餐盒"

# ── 顶部支架：一根立柱（照 `lunchbox_model.gd` 里 `LoiterPost` 的做法）──────────
## 立柱位置：**车顶正中**（x=0/z=0）——
## 依据同第 107 轮踩过的坑：车顶面薄片的 x 只有 ±0.303（六边形顶点决定），
## 立柱必须落在顶面**之内**才算"接在车顶上"，否则下端悬在空气中。
const POST_X := 0.0
const POST_Z := 0.0
const POST_R := 0.075                       # 立柱半径（比 LoiterPost 的 0.06 略粗，要托一个雷达）
const POST_BASE_R := 0.13                   # 立柱底座圆盘半径（"从车顶长出来"）
const POST_BASE_H := 0.04
## 立柱把雷达举到**车顶之上 0.80 格**（车顶 ROOF_Y = 1.0 -> 旋转轴 y = 1.80）
const POST_LIFT := 0.80
## 旋转雷达的轴心高度 = 车顶 + 立柱高。（写成常量而非算式，避免常量表达式跨类引用；
## `probe` 里断言 `RADAR_Y == ROOF_Y + POST_LIFT`。）
const RADAR_Y := 1.80

# ── 旋转雷达：一根横杆 + 一个碟面 + 馈源 ─────────────────────────────────────
const BAR_LEN := 0.80                       # 横杆长（沿本地 x；半长 0.40 < 车体半宽 0.433，不探出车外）
const BAR_T := 0.055                        # 横杆截面（BoxMesh 的 y/z 尺寸）
const HUB_T := 0.10                         # 横杆中心的轮毂方块边长
const DISH_R := 0.27                        # 碟面开口半径
const DISH_BACK_R := 0.11                   # 碟面背面（窄端）半径
const DISH_LEN := 0.14                      # 碟面纵深（锥台高）
const DISH_FWD := 0.10                      # 碟面中心相对旋转轴的 +z 偏移（开口朝前）
const FEED_R := 0.020                       # 馈源杆半径
const FEED_LEN := 0.20
const FEED_TIP_R := 0.035                   # 馈源头部小球

## 稳定节点名（探针/测试按名字定位，不靠"找六边形/找圆柱"）
## ⚠ 模型根节点的名字要**显式**设（Godot 不会自动用 class_name 当节点名）——
##   与 `ReaperModel.make()` 的 `m.name = "ReaperModel"` 同一套路，测试才找得到。
const MODEL_NAME := "RadarModel"
const RADAR_POST_NAME := "RadarPost"
const RADAR_YAW_NAME := "RadarYaw"
const RADAR_BAR_NAME := "RadarBar"
const RADAR_DISH_NAME := "RadarDish"
const RADAR_FEED_NAME := "RadarFeed"

## 自转角速度（度/秒）。用户口径只要求"一个**旋转的**雷达"，没有给速度；
## 取 120°/s = 3 秒一圈 —— 明显看得出来在转，又不至于糊成一团。
const SPIN_DEG_PER_SEC := 120.0

var _radar_yaw: Node3D = null               # 旋转部（绕 y 的节点，雷达全挂它下面）
var _radar_post: MeshInstance3D = null      # 立柱（测试门面用）
var _radar_bar: MeshInstance3D = null
var _radar_dish: MeshInstance3D = null
var _radar_feed: MeshInstance3D = null
var _dish_mat: StandardMaterial3D = null

var _spin_deg := 0.0                        # 当前自转角（度）
## 自转开关（默认开）。⚠ 只给测试/探针用来"冻住角度做确定性断言"，
## 生产路径不需要任何人来关它 —— 自转是模型自己 `_process` 干的。
var _spin_auto := true


static func make() -> RadarModel:
	var m := RadarModel.new()
	m.name = MODEL_NAME
	m.build()
	return m


## 挂到 `UnitVisual` 上（与 `LunchboxModel.attach` 逐字同一个套路）。
## ⚠ 位置：UnitVisual 在**锚点格**中心，而车占 1×2（锚点 + 沿 +y 一格），
##    所以模型要沿本地 +z 偏 0.5 格 —— 这样车体正好盖住那两个碰撞圆柱。
static func attach(parent: Node3D, tint: Color = Color(0.6, 0.6, 0.6)) -> RadarModel:
	var m := RadarModel.new()
	m.name = MODEL_NAME
	m.tint = tint
	m.build()
	m.position = Vector3(0.0, 0.0, 0.5)
	parent.add_child(m)
	return m


## ⚠ 覆盖父类 `build()`：**只搭车体 + 轮子 + 雷达**，
## **刻意不调** `_build_turret()` / `_build_loiter_launcher()`（用户口径：不要炮塔、不要炮管、
## 不要巡飞弹发射器）。
func build() -> void:
	var base := Color(0.62, 0.58, 0.42).lerp(tint, 0.25)     # 与午餐盒同一套沙漠涂装 + 阵营色
	_body_mat = _mat(base, 0.15)
	_dark_mat = _mat(base.darkened(0.45), 0.35)
	_metal_mat = _mat(Color(0.30, 0.32, 0.36), 0.55)
	_dish_mat = _mat(Color(0.78, 0.79, 0.72).lerp(tint, 0.20), 0.30)
	# 车体容器必须先建好（车体/轮子/雷达都挂它下面 -> 转底盘时一起转）
	_body_root = Node3D.new()
	_body_root.name = BODY_ROOT_NAME
	add_child(_body_root)
	_build_hull()
	_build_wheels()
	_build_radar()
	# 初始朝向 = **网格 +y**（= 方位角 90°，与 1×2 占格的长轴一致）——
	# 与午餐盒逐字一致，这样 `body_yaw()` 报出来的数与几何一致。
	set_body_yaw(90.0)
	# 自转：模型**自己**每帧转（不依赖外部每帧调用；`unit_visual` 整帧重建模型也不会漏转）
	set_process(true)


# ── 顶部支架 + 旋转雷达 ───────────────────────────────────────────────────────
func _build_radar() -> void:
	# ① 立柱：车顶正中竖直上来（照 LoiterPost 的做法，**挂 BodyRoot** = 车体层）
	var post_h := RADAR_Y - ROOF_Y
	var post := MeshInstance3D.new()
	var pcyl := CylinderMesh.new()
	pcyl.radial_segments = 10
	pcyl.top_radius = POST_R
	pcyl.bottom_radius = POST_R
	pcyl.height = post_h
	post.mesh = pcyl
	post.material_override = _dark_mat
	post.name = RADAR_POST_NAME
	post.position = Vector3(POST_X, ROOF_Y + post_h * 0.5, POST_Z)
	_body_root.add_child(post)
	_radar_post = post
	# ② 底座圆盘：让立柱"从车顶长出来"（下端 y 与车顶面重合）
	var base_cyl := CylinderMesh.new()
	base_cyl.radial_segments = 10
	base_cyl.top_radius = POST_BASE_R
	base_cyl.bottom_radius = POST_BASE_R
	base_cyl.height = POST_BASE_H
	var b := MeshInstance3D.new()
	b.mesh = base_cyl
	b.material_override = _metal_mat
	b.name = "RadarPostBase"
	b.position = Vector3(POST_X, ROOF_Y + POST_BASE_H * 0.5, POST_Z)
	_body_root.add_child(b)
	# ③ 旋转部：绕 y 的节点（雷达全挂它下面 -> 自转 + 转底盘都跟着转）
	_radar_yaw = Node3D.new()
	_radar_yaw.name = RADAR_YAW_NAME
	_radar_yaw.position = Vector3(POST_X, RADAR_Y, POST_Z)
	_body_root.add_child(_radar_yaw)
	# ④ 横杆：沿本地 x 的水平杆（雷达的"肩膀"）
	var bar_box := BoxMesh.new()
	bar_box.size = Vector3(BAR_LEN, BAR_T, BAR_T)
	var bar := MeshInstance3D.new()
	bar.mesh = bar_box
	bar.material_override = _metal_mat
	bar.name = RADAR_BAR_NAME
	_radar_yaw.add_child(bar)
	_radar_bar = bar
	# ④b 轮毂：横杆中心的方块，遮住杆与碟面的接缝
	var hub_box := BoxMesh.new()
	hub_box.size = Vector3(HUB_T, HUB_T, HUB_T)
	var hub := MeshInstance3D.new()
	hub.mesh = hub_box
	hub.material_override = _dark_mat
	hub.name = "RadarHub"
	hub.position = Vector3(0.0, 0.0, DISH_FWD * 0.5)
	_radar_yaw.add_child(hub)
	# ⑤ 碟面：一个锥台（宽端开口朝本地 +z）。
	#    `CylinderMesh` 轴默认 +y；绕 x 转 -90° 后 +y -> -z，
	#    于是"窄端(top_radius)"朝后、"宽端(bottom_radius)"朝前 = 一个朝 +z 张口的碟面。
	var dish_cyl := CylinderMesh.new()
	dish_cyl.radial_segments = 18
	dish_cyl.top_radius = DISH_BACK_R
	dish_cyl.bottom_radius = DISH_R
	dish_cyl.height = DISH_LEN
	var dish := MeshInstance3D.new()
	dish.mesh = dish_cyl
	dish.material_override = _dish_mat
	dish.name = RADAR_DISH_NAME
	dish.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	dish.position = Vector3(0.0, 0.0, DISH_FWD)
	_radar_yaw.add_child(dish)
	_radar_dish = dish
	# ⑥ 馈源：碟面正前方一根细杆 + 头部小球（一眼看出是雷达天线而不是盘子）
	var feed_cyl := CylinderMesh.new()
	feed_cyl.radial_segments = 8
	feed_cyl.top_radius = FEED_R
	feed_cyl.bottom_radius = FEED_R
	feed_cyl.height = FEED_LEN
	var feed := MeshInstance3D.new()
	feed.mesh = feed_cyl
	feed.material_override = _dark_mat
	feed.name = RADAR_FEED_NAME
	feed.rotation_degrees = Vector3(90.0, 0.0, 0.0)           # 轴 +y -> +z（沿雷达朝向）
	var feed_z := DISH_FWD + DISH_LEN * 0.5 + FEED_LEN * 0.5
	feed.position = Vector3(0.0, 0.0, feed_z)
	_radar_yaw.add_child(feed)
	_radar_feed = feed
	var tip := SphereMesh.new()
	tip.radius = FEED_TIP_R
	tip.height = FEED_TIP_R * 2.0
	var t := MeshInstance3D.new()
	t.mesh = tip
	t.material_override = _dish_mat
	t.name = "RadarFeedTip"
	t.position = Vector3(0.0, 0.0, feed_z + FEED_LEN * 0.5)
	_radar_yaw.add_child(t)
	# 初始角度归零（让 `radar_spin()` 与几何一致）
	set_radar_spin(0.0)


# ── 自转（模型自己的 `_process`）──────────────────────────────────────────────
## ⚠ 为什么不用"外部每帧调 `set_radar_spin`"：`unit_visual` 可能整帧重建模型，
##   那样自转就依赖调用方的时序。这里由**模型自己**推进角度，谁构造它都自动在转。
func _process(delta: float) -> void:
	if not _spin_auto:
		return
	set_radar_spin(_spin_deg + SPIN_DEG_PER_SEC * delta)


## 门面：把雷达转到 `deg`（度，绕 y；0° = 碟面开口朝本地 +z = 车头方向）。
## 生产路径由 `_process` 每帧推进；测试可以连调它来**确定性地**摆角度。
func set_radar_spin(deg: float) -> void:
	_spin_deg = fposmod(deg, 360.0)
	if _radar_yaw != null:
		_radar_yaw.rotation_degrees = Vector3(0.0, _spin_deg, 0.0)


func radar_spin() -> float:
	return _spin_deg


## 冻结/恢复自转（**只给测试用**：冻住之后 `set_radar_spin` 的角度不会被 `_process` 冲掉）
func set_radar_auto_spin(on: bool) -> void:
	_spin_auto = on


func radar_auto_spin() -> bool:
	return _spin_auto


# ── 测试门面 ─────────────────────────────────────────────────────────────────
func t_radar_yaw() -> Node3D:
	return _radar_yaw


func t_radar_post() -> MeshInstance3D:
	return _radar_post


func t_radar_bar() -> MeshInstance3D:
	return _radar_bar


func t_radar_dish() -> MeshInstance3D:
	return _radar_dish


func t_radar_feed() -> MeshInstance3D:
	return _radar_feed


## 雷达朝向（**世界**单位向量）：碟面开口方向 = 旋转部的本地 +z。
## 测试用"朝向在变"来证明自转 / 转底盘真的生效（`transform` 相对父节点，量不出车体旋转，
## 必须走 `global_transform` —— 第 105 轮探针在炮管上踩过同一个坑）。
func radar_dir_world() -> Vector3:
	if _radar_yaw == null:
		return Vector3.ZERO
	return (_radar_yaw.global_transform.basis * Vector3(0.0, 0.0, 1.0)).normalized()


## 雷达旋转轴心在**世界**里的位置（= 立柱顶部）
func radar_origin_world() -> Vector3:
	if _radar_yaw == null:
		return Vector3.ZERO
	return _radar_yaw.global_position


## 横杆左端（本地 -x）在**世界**里的位置 —— 一个**离旋转轴 0.40 格**的点，
## 转底盘/自转时它一定会动（用来证明雷达真的挂在车体层、跟着车体转）。
func radar_bar_tip_world() -> Vector3:
	if _radar_yaw == null:
		return Vector3.ZERO
	return _radar_yaw.global_transform * Vector3(-BAR_LEN * 0.5, 0.0, 0.0)
