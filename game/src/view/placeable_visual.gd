# ══════════════════════════════════════════════════════════════════════════════
# 可放置物的表现层：程序化建模，零美术资源。
#   · 木刺（拒马）：三组 X 形交叉木桩，高端削尖，指向左右斜上
#   · 土堆：一坨土黄色圆包 + 几块碎石
# 还带：放置阶段的占位方框、头顶的血量指示器（和角色同款"左护甲/右力量"方块）
# ══════════════════════════════════════════════════════════════════════════════
class_name PlaceableView
extends Node3D

const PREVIEW_OK := Color(0.30, 1.00, 0.45, 0.45)      # 可放置：绿
const PREVIEW_BAD := Color(1.00, 0.25, 0.25, 0.45)     # 不可放置：红

# 血量指示器（比角色的小一圈）
const ORB_PX := 168
const ORB_WORLD := 0.66
const ORB_H := 1.05
const COL_RING := Color(0.04, 0.03, 0.06)
const COL_EMPTY := Color(0.10, 0.08, 0.13)
const COL_POWER := Color(1.00, 0.15, 0.72)             # 力量（洋红）
const COL_ARMOR := Color(0.78, 0.95, 0.18)             # 护甲（青黄）

const GLYPHS := {
	"0": ["111", "101", "101", "101", "111"], "1": ["010", "110", "010", "010", "111"],
	"2": ["111", "001", "111", "100", "111"], "3": ["111", "001", "111", "001", "111"],
	"4": ["101", "101", "111", "001", "001"], "5": ["111", "100", "111", "001", "111"],
	"6": ["111", "100", "111", "101", "111"], "7": ["111", "001", "010", "010", "010"],
	"8": ["111", "101", "111", "101", "111"], "9": ["111", "101", "111", "001", "111"],
}

var placeable: Placeable
var _preview: MeshInstance3D
var _preview_mat: StandardMaterial3D
var _body: Node3D
var _die_tween: Tween
var _orb_sprite: Sprite3D
var _orb_image: Image
var _orb_texture: ImageTexture


func setup(p: Placeable) -> void:
	placeable = p
	p.visual = self
	position = Vector3(float(p.cell.x) + 0.5, 0.0, float(p.cell.y) + 0.5)
	_body = Node3D.new()
	add_child(_body)
	match p.name:
		"木刺":
			_build_spikes()
		"巡飞弹发射器":
			_build_launcher()
		_:
			_build_mound()
	_build_preview()
	set_preview(false, true)


func _mat(c: Color, rough: float = 0.85) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m


func _add(mesh: Mesh, pos: Vector3, rot_deg: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.rotation_degrees = rot_deg
	mi.material_override = mat
	_body.add_child(mi)
	return mi


## 木刺（拒马）：三组 X 形交叉木桩并排。每组两根短木分别"左斜向上 / 右斜向上"，
## 高端削尖；底部横撑把 X 架住。木头要短，否则三组会连成斜坡。
func _build_spikes() -> void:
	var wood := _mat(Color(0.46, 0.31, 0.16))
	var wood_tip := _mat(Color(0.86, 0.78, 0.62), 0.5)
	var log_len := 0.50
	var thick := 0.040
	var ang := 46.0
	var center_y := 0.24
	var group_x := [-0.26, 0.0, 0.26]
	var half := log_len * 0.5
	var dx: float = half * cos(deg_to_rad(ang))
	var dy: float = half * sin(deg_to_rad(ang))
	for gx in group_x:
		for sgn in [1.0, -1.0]:
			var sy: float = sgn
			var cyl := CylinderMesh.new()
			cyl.top_radius = thick * 0.45
			cyl.bottom_radius = thick
			cyl.height = log_len
			_add(cyl, Vector3(gx, center_y, 0.0), Vector3(0, 0, sy * ang), wood)
			var tip := CylinderMesh.new()
			tip.top_radius = 0.0
			tip.bottom_radius = thick * 0.45
			tip.height = 0.16
			_add(tip, Vector3(gx + sy * (dx + 0.045), center_y + dy + 0.055, 0.0),
				Vector3(0, 0, sy * ang), wood_tip)
		var bar := BoxMesh.new()
		bar.size = Vector3(0.30, 0.06, 0.11)
		_add(bar, Vector3(gx, 0.030, 0.0), Vector3.ZERO, wood)
	for z in [-0.13, 0.13]:
		var rail := BoxMesh.new()
		rail.size = Vector3(0.62, 0.05, 0.07)
		_add(rail, Vector3(0.0, 0.030, z), Vector3.ZERO, wood)


## 巡飞弹发射器（第 90 轮）：底座箱 + 一根上仰的发射管 + 管口的青色光环（一眼认出能发射）
func _build_launcher() -> void:
	var metal := _mat(Color(0.30, 0.33, 0.38), 0.5)
	var dark := _mat(Color(0.18, 0.20, 0.24), 0.7)
	var base := BoxMesh.new()
	base.size = Vector3(0.62, 0.16, 0.62)
	_add(base, Vector3(0, 0.08, 0), Vector3.ZERO, dark)
	var leg := BoxMesh.new()
	leg.size = Vector3(0.34, 0.26, 0.16)
	_add(leg, Vector3(0, 0.27, 0), Vector3.ZERO, metal)
	var tube := CylinderMesh.new()
	tube.top_radius = 0.15
	tube.bottom_radius = 0.17
	tube.height = 0.72
	# 管口朝 -Z 上方 25°（和模型"机头 = -Z"的约定一致）
	_add(tube, Vector3(0, 0.52, -0.08), Vector3(-25, 0, 0), metal)
	var mouth := TorusMesh.new()
	mouth.inner_radius = 0.10
	mouth.outer_radius = 0.155
	var ring_mat := StandardMaterial3D.new()
	ring_mat.albedo_color = Color(0.35, 0.95, 0.95, 0.85)
	ring_mat.emission_enabled = true
	ring_mat.emission = Color(0.30, 0.90, 1.0)
	ring_mat.emission_energy_multiplier = 2.0
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var ring := _add(mouth, Vector3(0, 0.80, -0.26), Vector3(-25, 0, 0), ring_mat)
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## 土堆：一坨压扁的球 + 三块石头
func _build_mound() -> void:
	var soil := _mat(Color(0.42, 0.31, 0.19))
	var soil2 := _mat(Color(0.34, 0.25, 0.15))
	var rock := _mat(Color(0.42, 0.40, 0.38), 0.95)
	var base := SphereMesh.new()
	base.radius = 0.46
	base.height = 0.58
	_add(base, Vector3(0, 0.13, 0), Vector3.ZERO, soil)
	var hump := SphereMesh.new()
	hump.radius = 0.30
	hump.height = 0.42
	_add(hump, Vector3(-0.16, 0.34, 0.10), Vector3(0, 20, -12), soil2)
	_add(hump, Vector3(0.20, 0.28, -0.12), Vector3(0, -35, 8), soil2)
	for r in [Vector3(0.30, 0.16, 0.24), Vector3(-0.28, 0.13, -0.22), Vector3(0.02, 0.44, 0.04)]:
		var b := BoxMesh.new()
		b.size = Vector3(0.16, 0.13, 0.15)
		_add(b, r, Vector3(randf_range(-25, 25), randf_range(0, 90), randf_range(-25, 25)), rock)


func _build_preview() -> void:
	_preview = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.96, 0.03, 0.96)
	_preview.mesh = bm
	_preview_mat = StandardMaterial3D.new()
	_preview_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_preview_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_preview_mat.albedo_color = PREVIEW_OK
	_preview.material_override = _preview_mat
	_preview.position = Vector3(0, 0.02, 0)
	add_child(_preview)


# ── 血量指示器 ────────────────────────────────────────────────────────────────
## 用户要求：沙盒道具不再显示头顶血条，数值只在属性栏里看
func update_orb() -> void:
	pass


## 放置阶段：显示占位方框并按合法/非法变色
func set_preview(on: bool, ok: bool) -> void:
	if _preview == null:
		return
	_preview.visible = on
	_preview_mat.albedo_color = PREVIEW_OK if ok else PREVIEW_BAD


## 被摧毁：缩小 + 淡出后隐藏
func play_destroy() -> void:
	if _die_tween != null and _die_tween.is_valid():
		_die_tween.kill()
	if _orb_sprite != null:
		_orb_sprite.visible = false
	_die_tween = create_tween()
	_die_tween.set_parallel(true)
	_die_tween.tween_property(self, "scale", Vector3(0.1, 0.1, 0.1), 0.30) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	_die_tween.chain().tween_callback(func() -> void: visible = false)
