# ══════════════════════════════════════════════════════════════════════════════
# 箭矢弹反 QTE（杰拉尔德的被动）
#
# 用户口径：
#   · 箭矢命中杰拉尔德时，GameMaster 先不结算伤害，而是【暂停时间】（动画/弹道全停）
#   · 在杰拉尔德旁边弹按键提示：每次从 qweasd 里随机取一个键，
#     第一个窗口 0.5 秒，之后两个都是 0.2 秒
#   · 按错一次立刻结算伤害；连续三次在窗口内按对 -> 反弹箭矢
#
# 为什么是 2D UI 而不是 3D 牌子：
#   · 2D 天然"正对摄像机、不会斜"（用户明确要求），也不会有 3D 文字的朝向问题
#   · 暂停（get_tree().paused = true）时 3D Label 的网格刷新会被卡住，实测不显示
#   · 版式用和 HUD 一样的面板，字最清楚
#
# 活着的方式：process_mode = ALWAYS —— 全场暂停时它必须继续跑、
# 继续收按键、继续走窗口计时。按键用【轮询 Input】而不是输入事件，
# 暂停时事件不一定会派发过来。
# ══════════════════════════════════════════════════════════════════════════════
class_name ArrowQTE
extends Control

signal finished(success: bool)

const KEY_CODES := {
	KEY_Q: "q", KEY_W: "w", KEY_E: "e",
	KEY_A: "a", KEY_S: "s", KEY_D: "d",
}
const PROMPTS := 3
const RESULT_SEC := 0.35              # 结果（OK / X）停留时间
const PANEL_SIZE := Vector2(168, 132)
const GAP := Vector2(52.0, -34.0)     # 相对角色屏幕位置的偏移（放他旁边）
const BAR_W := 132.0

var keys: Array[String] = []
var windows: Array = []
var index := 0
var left := 0.0
var running := false

var _ok := false
var _result_left := 0.0
var _anchor := Vector3.ZERO           # 被命中角色的世界坐标
var _cam: Camera3D = null
var _label: Label = null
var _bar: ColorRect = null
var _dots: Array = []
var _held: Dictionary = {}            # 上一帧的按键状态（边沿检测）


## 开始判定。victim = 被命中的角色（提示牌出现在他旁边）
func start(victim: Unit, def: Dictionary, rng: RngService, cam: Camera3D = null) -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pool: Array = def.get("keys", ["q", "w", "e", "a", "s", "d"])
	keys.clear()
	for i in PROMPTS:
		keys.append(String(pool[rng.next_int(pool.size())]))
	windows = def.get("windows", [0.5, 0.2, 0.2])
	if victim != null:
		_anchor = Vector3(float(victim.cell.x) + 0.5, 1.0, float(victim.cell.y) + 0.5)
	_cam = cam
	_build()
	index = 0
	left = float(windows[0])
	running = true
	_refresh_prompt()


## 模拟/真实的一次按键：对了就进下一个窗口，错了立刻结束（用户口径：按错一次即结算）
func press(letter: String) -> void:
	if not running:
		return
	if index < keys.size() and letter == keys[index]:
		index += 1
		if index >= keys.size():
			_finish(true)
			return
		left = float(windows[index])
		_refresh_prompt()
	else:
		_finish(false)


func _process(delta: float) -> void:
	_follow_target()
	if not running:
		_result_left -= delta
		if _result_left <= 0.0:
			finished.emit(_ok)
			queue_free()
		return
	_poll_keys()
	if not running:
		return
	left -= delta
	var total: float = maxf(0.001, float(windows[index]))
	var frac: float = clampf(left / total, 0.0, 1.0)
	_bar.size.x = maxf(2.0, BAR_W * frac)
	_bar.color = Color(0.35, 0.85, 1.0) if frac > 0.34 else Color(1.0, 0.52, 0.20)
	if left <= 0.0:
		_finish(false)


## 暂停期间也要能收到按键：直接轮询 Input（不依赖事件派发）
func _poll_keys() -> void:
	for code in KEY_CODES:
		var down: bool = Input.is_key_pressed(code)
		var was: bool = _held.get(code, false)
		_held[code] = down
		if down and not was:
			press(String(KEY_CODES[code]))
			return


## 贴在角色旁边（每帧按相机投影更新，相机怎么动都跟得上）
func _follow_target() -> void:
	if _cam == null or not is_instance_valid(_cam):
		_cam = get_viewport().get_camera_3d() if is_inside_tree() else null
	if _cam == null:
		return
	var sp: Vector2 = _cam.unproject_position(_anchor)
	var vp: Vector2 = get_viewport().get_visible_rect().size
	if vp.x <= 1.0 or vp.y <= 1.0:
		position = Vector2(40, 120)          # 无头环境：给个固定位置
		return
	position = Vector2(
		clampf(sp.x + GAP.x, 8.0, maxf(8.0, vp.x - PANEL_SIZE.x - 8.0)),
		clampf(sp.y + GAP.y, 8.0, maxf(8.0, vp.y - PANEL_SIZE.y - 8.0)))


func _finish(success: bool) -> void:
	running = false
	_ok = success
	_result_left = RESULT_SEC
	_label.text = "OK" if success else "X"
	_label.add_theme_color_override("font_color",
		Color(0.45, 1.0, 0.5) if success else Color(1.0, 0.35, 0.35))
	_bar.visible = false
	for d in _dots:
		d.color = Color(0.45, 1.0, 0.5) if success else Color(0.55, 0.25, 0.25)


func _refresh_prompt() -> void:
	_label.text = keys[index].to_upper()
	_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.35))
	_bar.visible = true
	_bar.color = Color(0.35, 0.85, 1.0)
	for i in _dots.size():
		_dots[i].color = Color(0.45, 1.0, 0.5) if i < index else Color(0.30, 0.33, 0.40)


func _build() -> void:
	custom_minimum_size = PANEL_SIZE
	size = PANEL_SIZE
	var bg := PanelContainer.new()
	bg.position = Vector2.ZERO
	bg.size = PANEL_SIZE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.11, 0.96)
	sb.border_color = Color(1.0, 0.84, 0.28, 1.0)
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(4)
	bg.add_theme_stylebox_override("panel", sb)
	add_child(bg)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	bg.add_child(vb)

	var tip := Label.new()
	tip.text = "弹反！"
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tip.add_theme_font_size_override("font_size", 15)
	tip.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	vb.add_child(tip)

	_label = Label.new()
	_label.text = "-"
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 58)
	_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.35))
	vb.add_child(_label)

	var bar_bg := ColorRect.new()
	bar_bg.color = Color(0.18, 0.19, 0.24, 1.0)
	bar_bg.custom_minimum_size = Vector2(BAR_W, 8)
	vb.add_child(bar_bg)
	_bar = ColorRect.new()
	_bar.color = Color(0.35, 0.85, 1.0)
	_bar.size = Vector2(BAR_W, 8)
	_bar.position = Vector2.ZERO
	bar_bg.add_child(_bar)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 6)
	vb.add_child(row)
	for i in PROMPTS:
		var d := ColorRect.new()
		d.color = Color(0.30, 0.33, 0.40)
		d.custom_minimum_size = Vector2(12, 12)
		row.add_child(d)
		_dots.append(d)
