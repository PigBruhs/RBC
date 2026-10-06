# 雷达连接友军的**闪动蓝色细光柱**（第 111 轮用户口径）
#
# 用户原话：「与保持连接的角色之间有一条**闪动的蓝色细光柱**」
#
# 实现：一根细圆柱（默认沿 +y），每帧把两端对齐"雷达 -> 友军"，
#       并用正弦**闪动**它的透明度与自发光亮度（"闪动"= 明暗脉动，不是变色）。
# ⚠ 不引入任何依赖：`update()` 由宿主每帧喂两个世界坐标 + 时间。
class_name RadarBeam
extends Node3D

const COLOR_BEAM := Color(0.35, 0.75, 1.0)     # 蓝色
const RADIUS := 0.045                           # **细**光柱
const PULSE_HZ := 2.2                           # 闪动频率（每秒脉动次数）
const ALPHA_MIN := 0.25
const ALPHA_MAX := 1.0

var _cyl: CylinderMesh = null
var _mi: MeshInstance3D = null
var _mat: StandardMaterial3D = null


static func make(host: Node3D) -> RadarBeam:
	var b := RadarBeam.new()
	b._build()
	host.add_child(b)
	return b


func _build() -> void:
	_cyl = CylinderMesh.new()
	_cyl.radial_segments = 8
	_cyl.top_radius = RADIUS
	_cyl.bottom_radius = RADIUS
	_cyl.height = 1.0
	_mi = MeshInstance3D.new()
	_mi.mesh = _cyl
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.albedo_color = COLOR_BEAM
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.no_depth_test = true
	_mat.emission_enabled = true
	_mat.emission = COLOR_BEAM
	_mi.material_override = _mat
	add_child(_mi)


## 每帧：把光柱摆到 a -> b，并按时间**闪动**。
## 圆柱默认沿本地 +y；所以我们先把节点放到中点、再让它的 +y 指向 (b-a)。
func update(a: Vector3, b: Vector3, t_sec: float) -> void:
	var d := b - a
	var len := d.length()
	if len < 0.001:
		_mi.visible = false
		return
	_mi.visible = true
	global_position = (a + b) * 0.5
	# 让本地 +y 对准 d（与 `Basis.looking_at` 同一套，但**轴是 y**）
	var up := d / len
	var ref := Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var x_axis := ref.cross(up).normalized()
	var z_axis := x_axis.cross(up).normalized()
	global_transform.basis = Basis(x_axis, up, z_axis)
	_cyl.height = len
	# 闪动：alpha 与自发光按正弦脉动
	var k := 0.5 + 0.5 * sin(t_sec * TAU * PULSE_HZ)
	var alpha := lerpf(ALPHA_MIN, ALPHA_MAX, k)
	_mat.albedo_color = Color(COLOR_BEAM.r, COLOR_BEAM.g, COLOR_BEAM.b, alpha)
	_mat.emission_energy_multiplier = lerpf(0.6, 2.4, k)


# ── 测试门面 ───────────────────────────────────────────────────────────────
func t_height() -> float: return _cyl.height

func t_alpha() -> float: return _mat.albedo_color.a
