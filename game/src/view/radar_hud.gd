# 雷达午餐盒的**锁定 HUD**（第 111 轮用户口径）—— 挂在"被锁定的敌人"身上。
#
# 用户原话：
#   · 一个**荧光绿正（长）方形**，**面向摄像机**（法线方向与摄像机方向相同）
#   · **大小与被锁定目标碰撞体积有关**（普通角色 1x1 以此类推）
#   · **左上角**显示**仍需回合数**，**右上角**显示**锁定中 / 已锁定**
#   · 字的颜色为 **HUD 同款荧光绿**
#
# 实现要点：
#   · 矩形做成**边框**（上/下/左/右 4 条细长 BoxMesh），不遮住单位本身
#   · **每帧**把自己的朝向对齐相机（正交固定角相机，所以"面向相机"= 与该相机同朝向）
#   · 两个 `Label3D` 各自 `billboard`，放在边框的左上/右上角
#   · `size_for(u)`：宽 = max(1, 2·体半径)、高 = max(1, 2·体高) —— 普通角色得到 1×1
class_name RadarHud
extends Node3D

const COLOR_HUD := Color(0.25, 1.0, 0.32)      # 荧光绿
const THICK := 0.045                            # 边框粗细（格）
const LABEL_PX := 46                            # Label3D 的字号
const MIN_SIZE := 1.0                           # 最小 1×1（普通角色）


## 按目标的**碰撞体积**算矩形尺寸（用户口径：普通角色 1x1 以此类推）。
static func size_for(u: Unit) -> Vector2:
	var r: float = maxf(MIN_SIZE * 0.5, Targeting.unit_body_r(u))
	var h: float = r * 2.0
	# 体高只用来"至少不低于宽度的一半"，避免 Reaper 那种超高体把框拉成长条
	return Vector2(r * 2.0, maxf(h, MIN_SIZE * 0.6))


var _frame: Node3D = null
var _lab_left: Label3D = null
var _lab_right: Label3D = null
var _size := Vector2.ONE


static func make(host: Node3D, u: Unit) -> RadarHud:
	var h := RadarHud.new()
	h._build(size_for(u))
	host.add_child(h)
	return h


func _build(size: Vector2) -> void:
	_size = size
	_frame = Node3D.new()
	add_child(_frame)
	var w: float = size.x
	var ht: float = size.y
	# 4 条边框（半高 = THICK/2）；放在 +y 抬到单位中部高度，避免压在脚下
	_bar(Vector3(0, ht * 0.5, 0), Vector3(w + THICK, THICK, THICK))
	_bar(Vector3(0, -ht * 0.5, 0), Vector3(w + THICK, THICK, THICK))
	_bar(Vector3(-w * 0.5, 0, 0), Vector3(THICK, ht, THICK))
	_bar(Vector3(w * 0.5, 0, 0), Vector3(THICK, ht, THICK))

	_lab_left = _label(HORIZONTAL_ALIGNMENT_LEFT)
	# ⚠ 第 111 轮用户口径（第二版）：角标要放在**框外**、**紧贴矩形上边**。
	#   （第一版在外侧被头顶血条挤住 -> 我改到内侧；用户看到后要求改回**框外并在上边之上**，
	#    所以这里放到 `+ht/2` 之上一小段，两个角标都贴着上边。）
	_lab_left.position = Vector3(-w * 0.5, ht * 0.5 + 0.16, 0)
	_lab_right = _label(HORIZONTAL_ALIGNMENT_RIGHT)
	_lab_right.position = Vector3(w * 0.5, ht * 0.5 + 0.16, 0)


func _bar(pos: Vector3, box: Vector3) -> void:
	var m := BoxMesh.new()
	m.size = box
	var mi := MeshInstance3D.new()
	mi.mesh = m
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = COLOR_HUD
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true                      # 与条子/名字同一套：永远画在最上层
	mi.material_override = mat
	var parent: Node3D = _frame if _frame != null else self
	parent.add_child(mi)
	mi.position = Vector3(pos.x, pos.y, pos.z)


func _label(align: int) -> Label3D:
	var l := Label3D.new()
	l.text = ""
	l.font_size = LABEL_PX
	l.pixel_size = 0.0035
	l.modulate = COLOR_HUD
	l.outline_modulate = Color(0.0, 0.0, 0.0, 0.85)
	l.outline_size = 8
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED        # 自己就面向相机
	l.no_depth_test = true
	l.horizontal_alignment = align
	l.render_priority = 3
	add_child(l)
	return l


## 每帧：把整个 HUD 的朝向对齐相机（"法线方向与摄像机方向相同"）。
## 位置由调用方摆（= 被锁定目标的视觉位置 + 抬到中部）。
func face_camera(cam: Camera3D) -> void:
	if cam == null:
		return
	# 与相机**同朝向** -> 矩形平面正对相机（正交相机下就是"面向屏幕"）
	global_transform.basis = cam.global_transform.basis


func set_size(size: Vector2) -> void:
	if size.is_equal_approx(_size):
		return
	for c in _frame.get_children():
		c.queue_free()
	for c in [_lab_left, _lab_right]:
		if c != null:
			c.queue_free()
	_build(size)


## 刷新文字：左上 = 仍需回合数，右上 = 锁定中 / 已锁定
func update_text(turns_left: int, locked: bool) -> void:
	if _lab_left == null:
		return
	if locked:
		_lab_left.text = "0"
		_lab_right.text = "已锁定"
	else:
		_lab_left.text = str(maxi(0, turns_left))
		_lab_right.text = "锁定中"
	set_visible_labels(true)


func set_visible_labels(v: bool) -> void:
	for c in [_lab_left, _lab_right]:
		if c != null:
			c.visible = v


# ── 测试门面 ───────────────────────────────────────────────────────────────
func t_left_text() -> String: return "" if _lab_left == null else _lab_left.text

func t_right_text() -> String: return "" if _lab_right == null else _lab_right.text

func t_size() -> Vector2: return _size
