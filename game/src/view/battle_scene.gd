# ══════════════════════════════════════════════════════════════════════════════
# 战场场景：状态 + 场景搭建 + UI + 输入 + 回合机 + 伤害/技能收尾
#
# 说明：这个文件仍然偏大（约 3300 行）。拆分方案（继承链：状态/场景/UI 归父类）
# 已经验证可行，但父类里对子类方法的引用必须逐处改成 self.call(...)，
# 需要一次完整的、非正则的改写，留作单独一轮处理。
# ══════════════════════════════════════════════════════════════════════════════
extends Node3D

signal turn_started(u: Unit)

signal round_started(round_no: int)

signal unit_died(u: Unit)

## 炮击落点半径（格）。红圈的半径就是这个值，命中判定也用同一个值 —— 保证"看到的=判定的"。
## 用户口径：只要**红圈沾到该角色所在格**就算命中（不是比"爆心到格中心"的距离）。

const BLAST_RADIUS := 1.5

## 地图尺寸 / 相机偏航都来自【当前关卡】（Level.current），所以这里是变量不是常量
var GW := 48

var GH := 48

const TILE := 1.0

const CAM_PITCH := -42.0

var _cam_yaw := 45.0                 # 俯视方向（关卡决定：竞技场垂直于宽面）

const CAM_DIST := 46.0

enum Phase { IDLE, MENU, CHOOSE_TARGET, AIMING, PLACE, MOVE_CONFIRM }

var units: Array[Unit] = []

var placeables: Array[Placeable] = []     # 沙盒道具（木刺/土堆）

var place_left: Dictionary = {}           # 道具名 -> 还剩几个可放

var _place_kind: String = ""              # 当前选中的要放的道具名

var queue: TurnQueue

var active: Unit = null              # 当前该行动的单位

var phase: int = Phase.IDLE

var selected: Unit = null            # 玩家点开菜单的那个单位（= active）

var rng := RngService.new(20260930)

var reachable: Dictionary = {}

var attackable: Dictionary = {}

var round_no: int = 0

var _camera: Camera3D

var _hint_layer: Node3D

var _zoom: float = 15.0

var _cam_focus: Vector3 = Vector3.ZERO      # 相机注视的地面点（WASD 平移）

var _cam_height: float = 0.0               # 相机抬高（QE）

# 瞄准

var _aim_active := false

var _aim_valid := false              # 是否已经算出一个有效落点（防止在 (0,0) 误开火）

var _aim_kind: String = "throw"      # "throw" = 投掷手普攻；"skill" = 技能瞄准

var _aim_float_pos: Vector2 = Vector2.ZERO  # 浮点落点（不做格子吸附）

var _aim_origin := Vector2.ZERO      # 屏幕坐标

var _aim_now := Vector2.ZERO

var _arrow_root: Node3D

var _shaft: MeshInstance3D

var _head: MeshInstance3D

var _projectile: MeshInstance3D

var _impact_ring: MeshInstance3D

var _impact_tw: Tween = null                  # 红圈淡出动画（重开时必须 kill 掉旧的）

var _planned_cell := Vector2i(-1, -1)

# UI

var _detail: RichTextLabel

var _status: Label

var _hint_label: Label

var _queue_label: Label

var _upgrade_box: HFlowContainer

var _attack_hint: Label

var _btn_rest_menu: Button

var _btn_end_turn: Button

var _turn_just_finished: Unit = null      # 幂等保护：防止一个回合被结束两次
# 沙盒

var _ui_layer: CanvasLayer

var _btn_next: Button                     # 右下角 >> 按钮（结束放置 / 结束回合）
# 日志（Debug 面板里显示）

const DEBUG_LOG_MAX := 300

var _debug_log: Array[String] = []

# 彩色流动（待确认可视化）

var _cycle_time: float = 0.0

var _pending_marks: Array = []            # [PendingMark]

var _pending_actor: Unit = null           # 待确认时被染色的角色

var _pending_actor_on: bool = false

var _pending_kind: String = ""            # 待确认操作类型

var _pending_cell: Vector2i = Vector2i(-1, -1)

var _panel: PanelContainer

var _action_menu: PanelContainer

var _zoom_slider: HSlider
# 攻击二级菜单（点敌人后弹出：打力量 / 破甲）

var _attack_menu: PanelContainer

var _btn_power: Button

var _btn_break: Button

var _attack_target: Unit = null


var gm := GameMaster.new()                    # 游戏主持：持有不属于任何角色的场上状态

var _orbital_marks: Array[Vector2] = []       # 已落下的标记点（浮点坐标，不做吸附）

var _orbital_pylons: Array[Node3D] = []       # 紫色光柱

var _orbital_busy := false                    # 炮击动画进行中（挡住回合推进）

var _gm_busy := false                         # GameMaster 演出中：锁住一切角色操作
## 弹道物：每一条是 {p: Projectile, node: Node3D, ...}

var ui: BattleUI = null
var field: ProjectileField = null            # 弹道物场（模型/推进/碰撞都在它里面）

var _proj_groups: Dictionary = {}             # 编组 id -> 还剩几发没落地

var _result_box: PanelContainer = null

var _result_label: Label = null

var _result_sub: Label = null

## 哨兵射界高亮（蓝色描边），一个哨兵一个节点
var sentry_range: SentryRange = null

var _revive_timers: Dictionary = {}           # Unit -> SceneTreeTimer（同一单位只保留一个）

var uid_dead: Dictionary = {}                 # Unit -> true（已经播报过阵亡，防止重复）

var _aim_skill_id: String = ""                # 正在瞄准的技能 id（空 = 投掷手普攻）

var _skill_info_text: String = ""
var _placeable_info_text: String = ""             # 瞄准时显示在属性栏的技能说明

var _btn_skill: Button                        # 二级菜单里的「技能」按钮

var _skill_menu: PanelContainer               # 多技能时的选择列表

var _menu_anchor: Unit = null                 # 二级菜单跟随的角色
# 待确认标记（常驻节点，避免每帧重建导致"看不见"）

var _pending_root: Node3D = null

var _pending_mats: Array = []

var _pulse_t: float = 0.0

## 待确认的黄勾（3D，永远正对摄像机；只画描边不填充格子）
var _check_root: Node3D = null

var _check_mats: Array = []

## 箭矢弹反 QTE：进行中 = 全局暂停，且不推进回合
var _qte_active := false

## 当前活着的 QTE 面板（测试/探针要读它）
var arrow_qte: ArrowQTE = null

var _pending_turn_end := false            # QTE 期间攒下的"该结束回合了"
var _ai_turn := false                     # 正在跑 AI 回合（不弹菜单、不锁操作）
const KING_FIRE_TURNS := 5                # 老国王每 5 个回合边界开一炮（GM 计时）
const SENTRY_AIM_BALL_R := 1.0           # 哨兵瞄准球半径（用户口径：1 格）
const HELI_PREFIX := "俯冲轰炸直升机"     # 悬浮 + 火箭齐射 + 坠机/俯冲都按这个名字前缀识别
const SANI_NAME := "萨尼铁塔"                # 三连发 + 玩家侧线性散布的角色
const VOLLEY_COUNT := 3                      # 三连发
const VOLLEY_GAP := 0.1                      # 每发间隔 100ms（用户口径）                # 老国王每 5 个回合边界开一炮（GM 计时）
var game_over := false                    # 分出胜负了（自动演算用）
var _last_win := false
var _last_turn_side := -1                 # 上一个结束的回合属于哪一方（防"同方连走两回合")

const AI_QTE_CHANCE := 0.6            # AI 阵营的弹反成功率（不弹 2D 面板）

## 进入技能瞄准（目前套用投掷手那一整套瞄准）

const UNIT_BODY_R := 0.30            # 角色脚下的判定半径

const CARPET_BLAST_R := 1.0          # 地毯式轰炸的爆炸半径 = 轨道炮击同款（比普攻 1.5 小）

## 相机相关：WASD 平移 / 滚轮缩放 / QE 高度
## 处理相机输入，同时把日志刷进 Debug 面板（每帧最多刷一次）

class PendingMark extends RefCounted:
	var fill: MeshInstance3D
	var edge: MeshInstance3D
	var phase: float = 0.0


## 造一个"彩色流动"的格子高亮：里面半透明填充 + 一圈亮描边。
## 用户要求：等待确认时不用图标，改用颜色连续渐变，并且**高亮边缘**。

const DBG_FIELDS := [
["power_max", "力量", 0, 99999, false],
["power_cur", "当前力量", 0, 99999, false],
["armor_max", "护甲", 0, 99999, false],
["armor_cur", "当前护甲", 0, 99999, false],
["armor_break", "破甲伤害", 0, 99999, false],
["energy_max", "精力上限", 0, 99, false],
["move", "移动力", 0, 99, false],
["rng_max", "射击距离", 0, 99, false],
["rest_power", "休息恢复力量", 0, 9999, false],
["rest_armor", "休息恢复护甲", 0, 9999, false],
["rest_energy", "休息恢复精力", 0, 99, false],
["pr", "物抗(%)", 0, 100, false],
["mr", "魔抗(%)", 0, 100, false],
]

func _build_env() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.07, 0.08, 0.11)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.66, 0.70, 0.80)
	env.ambient_light_energy = 0.85
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -40, 0)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	add_child(sun)

func _build_terrain() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var c1 := Color(0.26, 0.34, 0.31)
	var c2 := Color(0.22, 0.29, 0.27)
	# 河面（不含桥）：深蓝偏绿；桥面：金色（用户口径）
	var w1 := Color(0.10, 0.22, 0.34)
	var w2 := Color(0.08, 0.19, 0.30)
	var b1 := Color(0.62, 0.50, 0.14)
	var b2 := Color(0.54, 0.43, 0.11)
	var water := Level.river_cells()
	for y in GH:
		for x in GW:
			var c := Vector2i(x, y)
			var col: Color
			if water.has(c):
				col = w1 if (x + y) % 2 == 0 else w2
			elif Level.is_bridge(c):
				col = b1 if (x + y) % 2 == 0 else b2
			else:
				col = c1 if (x + y) % 2 == 0 else c2
			var x0 := float(x); var z0 := float(y)
			_add_quad(st, Vector3(x0, 0, z0 + TILE), Vector3(x0 + TILE, 0, z0 + TILE),
				Vector3(x0 + TILE, 0, z0), Vector3(x0, 0, z0), col)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	mi.name = "Floor"
	add_child(mi)

func _add_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
	st.set_color(col); st.add_vertex(a); st.add_vertex(b); st.add_vertex(c)
	st.set_color(col); st.add_vertex(a); st.add_vertex(c); st.add_vertex(d)


## 相机：不再固定。WASD 平移、滚轮缩放、QE 调高度（用户要求）

func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.name = "Cam"
	add_child(_camera)
	_cam_focus = Vector3(GW * 0.5, 0.0, GH * 0.5)
	_update_camera()

func _update_camera() -> void:
	if _camera == null:
		return
	_camera.size = _zoom
	var pitch := deg_to_rad(CAM_PITCH)
	var yaw := deg_to_rad(_cam_yaw)
	var dir := Vector3(cos(pitch) * cos(yaw), -sin(pitch), cos(pitch) * sin(yaw))
	_camera.position = _cam_focus + dir * CAM_DIST + Vector3(0, _cam_height, 0)
	_camera.look_at(_cam_focus + Vector3(0, _cam_height, 0), Vector3.UP)

func _build_aim_helpers() -> void:
	# 箭头 = 杆 + 三角锥头（明显比一根圆柱像箭头），整体挂在枢轴节点下，沿局部 Y 拉伸
	_arrow_root = Node3D.new()
	add_child(_arrow_root)

	var am := StandardMaterial3D.new()
	am.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	am.albedo_color = Color(1.0, 0.16, 0.16)
	am.cull_mode = BaseMaterial3D.CULL_DISABLED

	_shaft = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.055
	cyl.bottom_radius = 0.055
	cyl.height = 1.0
	_shaft.mesh = cyl
	_shaft.material_override = am
	_arrow_root.add_child(_shaft)

	_head = MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0            # 顶端收成尖 -> 圆锥
	cone.bottom_radius = 0.17
	cone.height = 1.0
	_head.mesh = cone
	_head.material_override = am
	_arrow_root.add_child(_head)

	_arrow_root.visible = false

	# 弹丸（投掷物）
	_projectile = MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = 0.26
	ball.height = 0.52
	_projectile.mesh = ball
	var bm := StandardMaterial3D.new()
	bm.albedo_color = Color(0.24, 0.22, 0.26)
	bm.roughness = 0.4
	# 自发光：炮弹在深色地面上必须一眼看得见（用户反馈"没有飞行的球"）
	bm.emission_enabled = true
	bm.emission = Color(1.0, 0.62, 0.22)
	bm.emission_energy_multiplier = 1.5
	_projectile.material_override = bm
	_projectile.visible = false
	add_child(_projectile)

	# 落点范围圈（落地后才出现，表示 impact 范围）
	_impact_ring = MeshInstance3D.new()
	var disc := CylinderMesh.new()
	# 半径与命中判定完全一致（BLAST_RADIUS），所以"红圈沾到格子 = 命中"是真的
	disc.top_radius = BLAST_RADIUS
	disc.bottom_radius = BLAST_RADIUS
	disc.height = 0.04
	_impact_ring.mesh = disc
	var im := StandardMaterial3D.new()
	im.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	im.albedo_color = Color(1.0, 0.22, 0.20, 0.45)
	im.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_impact_ring.material_override = im
	_impact_ring.visible = false
	add_child(_impact_ring)

	_hint_layer = Node3D.new()
	_hint_layer.name = "Hints"
	add_child(_hint_layer)

## 二级菜单绑定到角色：放在该角色屏幕位置的右下方。
## 用【当前相机】的投影，所以相机移动/缩放时菜单跟着角色走，而不是钉在屏幕上。

func _place_menu_near(u: Unit) -> void:
	if _ai_turn:
		return                              # AI 回合不弹菜单
	if ui != null:
		ui.show_action_menu(u)


func _sync_menu_position() -> void:
	if ui != null:
		ui.sync_menu_position()


## 队列条动画计时：到点就收尾；期间攒下的刷新请求在这里补做（最小间隔 0.5 秒）

func _tick_queue_anim(delta: float) -> void:
	if ui != null:
		ui.tick_queue_anim(delta)
	if ui != null and ui.is_debug_open():
		ui.refresh_debug()


func _camera_process(delta: float) -> void:
	var move := Vector2.ZERO
	if Input.is_key_pressed(KEY_W): move.y -= 1.0
	if Input.is_key_pressed(KEY_S): move.y += 1.0
	if Input.is_key_pressed(KEY_A): move.x -= 1.0
	if Input.is_key_pressed(KEY_D): move.x += 1.0
	var height := 0.0
	if Input.is_key_pressed(KEY_Q): height += 1.0
	if Input.is_key_pressed(KEY_E): height -= 1.0
	if move == Vector2.ZERO and is_zero_approx(height):
		return
	# 平移方向取自相机自身的朝向（投影到地面），所以按 W 就是"画面上方"，
	# 不会像之前那样按固定 45° 轴换算导致上下左右反向。
	var speed := _zoom * 0.9 * delta
	var basis := _camera.global_transform.basis
	var fwd := Vector3(basis.z.x, 0.0, basis.z.z)      # 相机看向的反方向 = 画面里的"上"
	var right := Vector3(basis.x.x, 0.0, basis.x.z)
	if fwd.length() > 0.001:
		fwd = fwd.normalized()
	if right.length() > 0.001:
		right = right.normalized()
	_cam_focus += (fwd * move.y + right * move.x) * speed
	_cam_height = clampf(_cam_height + height * 6.0 * delta, -8.0, 24.0)
	_cam_focus.x = clampf(_cam_focus.x, -8.0, float(GW) + 8.0)
	_cam_focus.z = clampf(_cam_focus.z, -8.0, float(GH) + 8.0)
	_update_camera()

## 阵营显示名：敌方阵营里"玩家可控"的角色要标出来，否则玩家分不清谁能操作

static func _faction_cn(u: Unit) -> String:
	if u == null:
		return "-"
	if u.side == UnitData.Side.PLAYER:
		return "我方"
	return "敌方·可控" if u.controllable else "敌方"

func _build_ui() -> void:
	ui = BattleUI.new()
	ui.build(self)
	# 把 UI 控件引用拷回场景，输入层与刷新层照旧使用
	_action_menu = ui.action_menu
	_attack_menu = ui.attack_menu
	_skill_menu = ui.skill_menu
	_btn_next = ui.btn_next
	_panel = ui.panel
	_detail = ui.detail
	_status = ui.status
	_btn_rest_menu = ui.btn_rest
	_btn_skill = ui.btn_skill
	_btn_power = ui.btn_power
	_btn_break = ui.btn_break
	_zoom_slider = ui.zoom_slider


func _refresh_all() -> void:
	if ui != null:
		ui.refresh_all()


func _refresh_detail() -> void:
	if ui != null:
		ui.refresh_detail()


func _refresh_upgrades() -> void:
	if ui != null:
		ui.refresh_upgrades(selected)


func _ready() -> void:
	# 先按当前关卡定尺寸与相机角度，再建一切
	GW = Level.gw()
	GH = Level.gh()
	_cam_yaw = Level.cam_yaw()
	_log("[关卡] %s（%d×%d）" % [Level.name_of(), GW, GH])
	# 弹道物场：只做物理与上报，后果由 _on_projectile_event 处理
	field = ProjectileField.new()
	field.setup(self, gm, _arrow_hit_check)
	field.log_fn = _log
	field.grid_w = GW
	field.grid_h = GH
	gm.on_projectile_event = _on_projectile_event
	# 哨兵射界高亮：只画描边，判定仍然走 Sentry.in_range
	sentry_range = SentryRange.new()
	sentry_range.setup(self)
	sentry_range.grid_w = GW
	sentry_range.grid_h = GH
	_build_env()
	_build_terrain()
	_build_camera()
	_build_aim_helpers()
	_spawn_units()
	_build_ui()
	_build_sandbox()
	_enter_placement()      # 战斗开始前先进入放置阶段，玩家点 >> 才开打
	_refresh_all()


# ══════════════════════════════════════════════════════════════════════════════
# 沙盒：可放置物（木刺 / 土堆）
#   · 数量来自 bc_stat.md 的「可放置物」表，每关自带（默认 0 = 不能放）
#   · 只能在【放置阶段】放；玩家点右下角 >> 结束放置，开打
#   · 放置物无回合、不进队列、不会行动
# ══════════════════════════════════════════════════════════════════════════════

## 建立沙盒数据，并把"道具箱"按钮填进底边栏预留的位置

func _build_sandbox() -> void:
	# 沙盒数据在这里准备；按钮由 BattleUI 负责建（它自己按 place_left 刷新）
	placeables.clear()
	place_left.clear()
	for d in UnitData.PLACEABLES:
		place_left[d["name"]] = d["count"]
	if ui != null:
		ui.refresh_sandbox()


func _enter_placement() -> void:
	phase = Phase.PLACE
	active = null
	selected = null
	_place_kind = ""
	if ui != null:
		ui.refresh_sandbox()
	if _btn_next != null:
		_btn_next.visible = true
		_btn_next.text = ">>"
	if _action_menu != null:
		_action_menu.visible = false
	_refresh_all()

func _pick_place_kind(nm: String) -> void:
	if phase != Phase.PLACE:
		return
	if place_left.get(nm, 0) <= 0:
		if ui != null:
			ui.refresh_sandbox()
		return
	_place_kind = nm if _place_kind != nm else ""
	if ui != null:
		ui.refresh_sandbox()

## 该格能不能放：在界内、不在河里、不压单位、不压已有道具

func _can_place_at(c: Vector2i) -> bool:
	if c.x < 0 or c.y < 0 or c.x >= GW or c.y >= GH:
		return false
	if Level.is_river(c):
		return false
	for u in units:
		if u.is_alive() and u.cell == c:
			return false
	for p in placeables:
		if p.is_alive() and p.covers(c):
			return false
	return true


## 放一个道具

func _place_at(c: Vector2i) -> void:
	if _place_kind == "":
		return
	if place_left.get(_place_kind, 0) <= 0:
		pass
		return
	if not _can_place_at(c):
		pass
		return
	var data := _placeable_data(_place_kind)
	if data.is_empty():
		return
	var p := Placeable.from_data(data, c)
	placeables.append(p)
	var v := PlaceableView.new()
	add_child(v)
	v.setup(p)
	v.set_preview(false, true)
	place_left[_place_kind] = int(place_left.get(_place_kind, 0)) - 1
	_log("放置 %s 于 (%d, %d)，剩余 %d" % [_place_kind, c.x, c.y, place_left[_place_kind]])
	if place_left[_place_kind] <= 0:
		_place_kind = ""
	if ui != null:
		ui.refresh_sandbox()

func _placeable_data(nm: String) -> Dictionary:
	for d in UnitData.PLACEABLES:
		if d["name"] == nm:
			return d
	return {}


## 结束放置 -> 正式开始第 1 回合

func _finish_placement() -> void:
	if phase != Phase.PLACE:
		return
	phase = Phase.IDLE
	_place_kind = ""
	if ui != null:
		ui.refresh_sandbox()
	_start_round()


# ══════════════════════════════════════════════════════════════════════════════
# 二次确认（两段式操作）
#   用户要求：所有操作第一次点 = 进入"待确认"（目标格显示黄色 √），
#             再点同一处 = 真正执行。点别处 = 取消待确认。
# ══════════════════════════════════════════════════════════════════════════════
## 设置待确认操作。kind: "move" / "attack" / "place" / "aim"
## actor：这次操作要一起染色的角色（移动 = 自己；攻击 = 目标；放置 = 无）

func _set_pending(kind: String, cell: Vector2i, actor: Unit = null) -> void:
	_pending_kind = kind
	_pending_cell = cell
	_set_pending_actor(actor)
	_update_pending_visual()          # 立刻刷新：不然调用方忘了 _draw_hints 就看不见黄勾

func _clear_pending() -> void:
	_pending_kind = ""
	_pending_cell = Vector2i(-1, -1)
	_set_pending_actor(null)
	_update_pending_visual()

func _same_pending(kind: String, cell: Vector2i) -> bool:
	return _pending_kind == kind and _pending_cell == cell


# ══════════════════════════════════════════════════════════════════════════════
# 移动 / 阻挡查询
# ══════════════════════════════════════════════════════════════════════════════
## 走不进去的格子：阻挡移动的道具 + 河面（不含桥）
func _blocked_cells() -> Dictionary:
	var out := Level.river_cells()          # 河：角色无法移动进去（桥是普通地板，已排除）
	for p in placeables:
		if p.is_alive() and p.block_move:
			for c in p.occupied_cells():
				out[c] = true
	return out


## 远程弹道是否被该格的道具挡住（投掷手无视阻挡远程的道具）

func _ranged_blocked_at(c: Vector2i, by_thrower: bool) -> bool:
	if by_thrower:
		return false
	for p in placeables:
		if p.is_alive() and p.block_ranged and p.covers(c):
			return true
	return false


## 找某格上的道具

func _placeable_at(c: Vector2i) -> Placeable:
	for p in placeables:
		if p.is_alive() and p.covers(c):
			return p
	return null


# ══════════════════════════════════════════════════════════════════════════════
# 技能：轨道空爆打击（Gerald）
#
# 流程：
#   ① 选「技能」 -> 套用投掷手的瞄准（拖拽力度 -> 3~20 格），下方属性栏显示技能名/描述/数值
#   ② 松手：飞出一枚小球（比头大、比炮弹小），抛物线；落地后小球消失，
#      落点竖起一根紫色光柱（沿地面法线向上，缩到最小也冲出屏幕），随后自动结束回合
#   ③ 给 Gerald 打 tag
#   ④ 下次轮到 Gerald：先执行轨道炮击（5 发，1 秒/发，间隔 0.5 秒），再正常开始他的回合
# ══════════════════════════════════════════════════════════════════════════════

func _menu_skill() -> void:
	if active == null:
		return
	var ids := Skills.skills_for(active)
	if ids.is_empty():
		pass
		return
	if ids.size() == 1:
		_choose_skill(ids[0])
		return
	# 多技能：先把「行动」菜单收起来，再弹技能列表（否则两层菜单会叠在一起）
	_hide_action_menu()
	ui_open_skill_menu(ids)


## 一个单位有多个技能时，先弹一个小列表让玩家选

## 真正进入某个技能的瞄准

func _choose_skill(id: String) -> void:
	if active == null:
		return
	var d := Skills.get_def(id)
	if d.is_empty():
		return
	if active.energy_points() < int(d["cost"]):
		return
	_action_menu.visible = false
	if _skill_menu != null:
		_skill_menu.visible = false
	# 不需要瞄准的技能（哨兵）：直接施放
	if String(d.get("kind", "")) == "sentry":
		_aim_skill_id = ""
		_skill_info_text = ""
		_cast_sentry(active)
		return
	_aim_skill_id = id
	_begin_aim("skill")
	# 用户要求：瞄准时下方属性栏写技能名、描述与数值
	_skill_info_text = Skills.detail_text(id)
	_refresh_detail()


## 施放【哨兵】：不瞄准，进入警戒状态，登记在 GameMaster 上（跨回合存活）

func _cast_sentry(caster: Unit) -> void:
	var d := Skills.get_def("sentry")
	if caster == null or not caster.is_alive():
		return
	if caster.energy_points() < int(d["cost"]):
		_show_action_menu()
		if _ai_turn:
			_finish_turn()                   # AI 没有菜单可点，必须自己收尾
		return
	caster.spend_energy(int(d["cost"]))
	caster.has_acted = true
	caster.has_moved = true
	_push_unit_stats(caster)
	var s := gm.add_sentry(caster, int(d["range_min"]), int(d["range_max"]))
	_log("%s 进入【哨兵】状态：射界 %d~%d 格，精力 -%d（剩余 %d），持续到自己的下一个回合" % [
		caster.name, s.rng_min, s.rng_max, int(d["cost"]), caster.energy_points()])
	_log("  🎯 GM 已登记警戒：%s" % gm.sentry_desc())
	_finish_turn()


## 结束技能瞄准（放置标记）

func _fire_skill(cell: Vector2i) -> void:
	var d := Skills.get_def(_aim_skill_id)
	if d.is_empty():
		return
	var caster := active
	# 扣精力 + 结束回合（用户要求：落地后自动结束回合）
	caster.spend_energy(int(d["cost"]))
	caster.has_acted = true
	caster.has_moved = true
	_push_unit_stats(caster)          # 花了精力 -> 立刻同步精力条与属性栏
	# 关键：延时效果登记在 GameMaster 上，而不是施法者身上 ——
	# 这样即使 Gerald 这回合就死了，三回合后的轨道炮击照样落下。
	var fpos := _aim_float_pos
	gm.schedule("orbital_strike", caster, cell, fpos, int(d["delay_turns"]))
	_orbital_marks.append(fpos)
	_raise_pylon_at(fpos)
	_log("%s 使用【%s】：标记落点 (%d, %d)，精力 -%d，剩余 %d" %
		[caster.name, d["name"], cell.x, cell.y, d["cost"], caster.energy_points()])
	_log("  ⏳ 轨道火力已锁定：%d 个回合后落下 %d 发（GameMaster 计时：%s）" % [
		int(d["delay_turns"]), d["shells"], gm.pending_desc()])
	_skill_info_text = ""
	_aim_skill_id = ""
	_finish_turn()


## 在落点竖起紫色光柱：沿地面法线（+Y）向上，长度足够冲出屏幕

func _raise_pylon_at(pos: Vector2) -> Node3D:
	var root := Node3D.new()
	root.position = Vector3(pos.x, 0.0, pos.y)
	add_child(root)

	# 柱体：很高（80 单位）。缩到最小（zoom 30）时视口高度也就 30 出头，
	# 所以 80 一定能冲出屏幕顶部。
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.20
	cyl.bottom_radius = 0.32
	cyl.height = 80.0
	mi.mesh = cyl
	mi.position = Vector3(0, 40.0, 0)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.72, 0.28, 1.0, 0.55)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	root.add_child(mi)

	# 底部光环，强调落点
	var ring := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 1.0
	disc.bottom_radius = 1.0
	disc.height = 0.05
	ring.mesh = disc
	ring.position = Vector3(0, 0.04, 0)
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rm.albedo_color = Color(0.80, 0.40, 1.0, 0.45)
	ring.material_override = rm
	root.add_child(ring)

	# 轻微脉动，让光柱看起来是"活的"
	var tw := create_tween()
	tw.tween_property(m, "albedo_color:a", 0.85, 0.7)
	tw.tween_property(m, "albedo_color:a", 0.40, 0.7)
	tw.tween_callback(func() -> void:
		if is_instance_valid(m):
			var t2 := create_tween()
			t2.tween_property(m, "albedo_color:a", 0.85, 0.7)
			t2.tween_property(m, "albedo_color:a", 0.40, 0.7))

	_orbital_pylons.append(root)
	return root

func _clear_pylons() -> void:
	for p in _orbital_pylons:
		if is_instance_valid(p):
			p.queue_free()
	_orbital_pylons.clear()


## 轨道炮击：以标记点为中心、半径 3 格内的【不重复】随机落点，随机顺序，
## 每发从"斜右上方"用 1 秒落到中心，两发之间停 0.5 秒。
## 落点是浮点坐标（不做格子吸附），打到哪里算哪里。

func _run_orbital_barrage(p: GameMaster.Pending) -> void:
	var d := Skills.get_def(p.skill_id)
	_orbital_busy = true
	var centers := _pick_shell_centers(p.float_pos, float(d["marker_radius"]), int(d["shells"]))
	for i in range(centers.size() - 1, 0, -1):
		var j := rng.next_int(i + 1)
		var tmp: Vector2 = centers[i]
		centers[i] = centers[j]
		centers[j] = tmp
	var names: Array[String] = []
	for c in centers:
		names.append("(%.1f,%.1f)" % [c.x, c.y])
	_log("  落点顺序：" + " → ".join(names))
	for c in centers:
		_orbital_shell_incoming(c)
		await get_tree().create_timer(float(d["shell_fall_sec"])).timeout
		_resolve_shell_impact(p, c, d)
		await get_tree().create_timer(float(d["shell_gap_sec"])).timeout
	_orbital_marks.clear()
	# 只拆掉"这一发"的光柱（其他在途打击的光柱继续留着）
	if p.pylon != null and is_instance_valid(p.pylon):
		p.pylon.queue_free()
		_orbital_pylons.erase(p.pylon)
	p.pylon = null
	_orbital_busy = false
	_log("—— 轨道火力结束 ——")


## 圆内随机落点，【保证互不重复】。浮点坐标，不做格子吸附。

func _pick_shell_centers(center: Vector2, r: float, n: int) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var tries := 0
	while out.size() < n and tries < n * 300:
		tries += 1
		var ang := rng.next_int(100000) / 100000.0 * TAU
		var rad := sqrt(rng.next_int(100000) / 100000.0) * r
		var q := center + Vector2(cos(ang), sin(ang)) * rad
		q.x = clampf(q.x, 0.05, float(GW) - 0.05)
		q.y = clampf(q.y, 0.05, float(GH) - 0.05)
		var dup := false
		for e in out:
			if q.distance_to(e) < 0.9:
				dup = true
				break
		if not dup:
			out.append(q)
	return out


## 一发炮弹从天而降的动画：从"斜右上方"的视野外落到中心，耗时 1 秒

func _orbital_shell_incoming(pos: Vector2) -> void:
	var target := Vector3(pos.x, 0.0, pos.y)
	# 起点：目标右上方很高处（相机在 -Z 方向俯视，抬高就是出画面）
	var start := target + Vector3(7.0, 26.0, 7.0)

	# 特效与投掷手炮击同款（用户要求）：亮稻草黄 + 光晕 + 尾迹
	var node: Node3D = ProjectileField.make_shell_node(self)
	if node == null or not is_instance_valid(node):
		return
	node.visible = true
	node.position = start

	# 落点红圈：半径按 impact_radius（1 格）
	var ring := _make_impact_ring(pos, float(Skills.get_def("orbital_strike")["impact_radius"]))

	var tw := create_tween()
	tw.tween_method(func(t: float) -> void:
		if not is_instance_valid(node):
			return
		node.position = start.lerp(target, t)
		ProjectileField.orient(node, start.lerp(target, t), start.lerp(target, maxf(0.0, t - 0.02)), 52.0)
		, 0.0, 1.0, float(Skills.get_def("orbital_strike")["shell_fall_sec"]))
	tw.tween_callback(func() -> void:
		if is_instance_valid(node):
			node.queue_free()
		_flash_impact(ring)
		)

func _make_impact_ring(pos: Vector2, radius: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = radius
	disc.bottom_radius = radius
	disc.height = 0.04
	mi.mesh = disc
	mi.position = Vector3(pos.x, 0.05, pos.y)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(1.0, 0.20, 0.18, 0.5)
	mi.material_override = m
	add_child(mi)
	return mi

func _flash_impact(ring: MeshInstance3D) -> void:
	if not is_instance_valid(ring):
		return
	var m := ring.material_override as StandardMaterial3D
	var tw := create_tween()
	tw.tween_property(m, "albedo_color:a", 0.0, 1.1)
	tw.tween_callback(func() -> void:
		if is_instance_valid(ring):
			ring.queue_free())


## 场上现有的"落点红圈"数量（自检/试玩用）。
## 只数炮弹落地时新建的红圈，不含普攻共用的那一个 _impact_ring。

func count_impact_rings() -> int:
	var n := 0
	for c in get_children():
		if c == _impact_ring or not (c is MeshInstance3D):
			continue
		var mi := c as MeshInstance3D
		if not mi.visible or not (mi.material_override is StandardMaterial3D):
			continue
		var col := (mi.material_override as StandardMaterial3D).albedo_color
		if col.r > 0.8 and col.g < 0.4 and col.b < 0.4 and col.a > 0.01:
			n += 1
	return n


## 一发炮弹的结算：12 破甲 + 12 力量（无视 50% 物抗），范围内所有单位（含友军）都吃

func _resolve_shell_impact(p: GameMaster.Pending, pos: Vector2, d: Dictionary) -> void:
	# 轨道炮与普攻炮击走同一套范围规则（红圈沾到格子就算命中），
	# 差别只有：轨道炮不分敌我（skip = null）、参数来自技能表。
	var hits: Array = Damage.blast(null, pos, float(d["impact_radius"]), Combat.opts_orbital(d, rng),
		units, placeables, null, p.caster_side, true)
	if hits.is_empty():
		_log("  爆炸范围内无人")
		return
	for h in hits:
		_log(h.text)
		if h.unit != null:
			_after_damage_to_unit(h.unit)
		else:
			_after_damage_to_placeable(h.placeable)

func _spawn_units() -> void:
	# 用户口径：**场景解耦** —— 花名册（UnitData.UNITS/ENEMIES）只存"定义"，
	# 由【当前关卡的 roster】决定本场景有哪些角色、各站哪一格。
	var defs: Dictionary = {}
	for d in UnitData.UNITS:
		defs[String(d["name"])] = d
	for d in UnitData.ENEMIES:
		defs[String(d["name"])] = d
	var roster: Array = Level.roster()
	for entry in roster:
		var nm := String(entry[0])
		if not defs.has(nm):
			_log("[关卡] 名单里的 %s 不在花名册里，跳过" % nm)
			continue
		var u := Unit.from_data(defs[nm])
		var bname := Unit.base_name(u.name)
		if bname == "老国王":
			u.is_king = true
			u.no_turn = true                     # 老国王不进队列，由 GM 每 5 回合开一炮
		elif Passives.has(u, "always_sentry"):
			u.no_turn = true                     # 公主：没有自己的回合
		u.cell = Vector2i(int(entry[2]), int(entry[3]))
		u.home_cell = u.cell
		if bname.begins_with(HELI_PREFIX):
			u.hover = float(Level.heli().get("hover_h", 2.0))
		units.append(u)
	for u in units:
		var v := UnitVisual.new()
		add_child(v)
		v.setup(u)          # 待机浮动的 Tween 由 UnitVisual 自己管理（走路时自动让位）
	# 常备哨兵（公主）：没有自己的回合，一直处于哨兵状态
	for u in units:
		if Passives.has(u, "always_sentry"):
			var s := gm.add_sentry(u, maxi(1, u.rng_min), maxi(1, u.rng_max))
			_log("[常备哨兵] %s 一直处于警戒：射界 %d~%d" % [u.name, s.rng_min, s.rng_max])


# ══════════════════════════════════════════════════════════════════════════════
# 回合队列
# ══════════════════════════════════════════════════════════════════════════════

func _start_round() -> void:
	round_no += 1
	queue = TurnQueue.new(rng)
	var n := queue.rebuild(units)
	_log("—— 第 %d 轮开始，队列 %d 人：%s ——" % [round_no, n, queue.dump()])
	round_started.emit(round_no)
	_next_turn()

func _next_turn() -> void:
	_clear_hints()
	phase = Phase.IDLE
	selected = null
	_aim_active = false
	_arrow_root.visible = false
	for u in units:
		if u.visual != null:
			u.visual.set_active(false)
			u.visual.set_selected(false)

	var u := queue.current()
	if u == null:
		# 本轮走完：存活单位重置行动标记，开新一轮
		for x in units:
			if x.is_alive():
				x.begin_turn()
		_check_over()
		_start_round()
		return

	# 英雄可以无限重生：死人还在队列里的话直接跳过（否则回合会卡在尸体上）
	var guard := 0
	while u != null and not u.is_alive() and guard < units.size() + 2:
		guard += 1
		queue.advance()
		u = queue.current()
	if u == null:
		_start_round()
		return

	# 最后一人机制（用户新规则）：某一方只剩 1 人时，立刻刷新队列，
	# 把当前回合交给这个孤军，然后对面每人一回合，再轮回孤军。
	if _check_last_stand():
		u = queue.current()
		if u == null:
			_start_round()
			return

	# 不变式（用户报过 bug）：常规模式下绝不允许同一方连续两回合。
	# 队列理论上不会这样，一旦出现（例如某条路径多推进了一次）就地纠正：这回合让给对面。
	if not queue.last_stand and _last_turn_side != -1 and u.side == _last_turn_side:
		_log("  ⚠ 检测到同一方连续行动，已纠正：%s 让位" % u.name)
		queue.advance()
		var other := queue.current()
		if other != null and other.side != _last_turn_side:
			u = other
		_log("     改为 %s（%s）行动" % [u.name, "我方" if u.side == UnitData.Side.PLAYER else "敌方"])
	_last_turn_side = u.side
	if _dive_begin(u):
		active = u
		u.begin_turn()
		return
	_holy_sani_check(u)
	active = u
	u.begin_turn()
	_turn_just_finished = null            # 新回合开始，解除幂等保护
	gm.on_turn_begin(u)                   # 被动机会：只有他自己的回合开始才重置（杰拉尔德弹反）
	# 哨兵状态持续到"自己的下一个回合"——所以自己的回合一开始就撤掉警戒
	if gm.has_sentry(u):
		gm.clear_sentry_for(u)
		_log("  %s 的【哨兵】警戒结束" % u.name)
	if u.visual != null:
		u.visual.set_active(true)
	turn_started.emit(u)

	_log("轮到 %s（%s）行动%s" % [u.name, Unit.role_name(u.role),
		"（敌方阵营 · 玩家操控）" if u.is_manual() and u.side == UnitData.Side.ENEMY else ""])

	# 加农炮 AI（老国王）：不管哪一方，轮到他就朝最近的敌对单位打一发
	if Passives.has(u, "cannon_ai"):
		await get_tree().create_timer(UnitData.DUMMY_SKIP_DELAY * 0.6).timeout
		_fire_cannon_ai(u)
		return

	# 通用 AI（用户口径：敌方整队由 AI 接管；我方只在"自动演算"模式下交给 AI）
	if _is_ai_unit(u):
		_ai_take_turn(u)
		return

	# 没有 AI 的假人：轮到它时停顿一下自动跳过，否则测试/试玩会卡住。
	# 注意：阵营是敌方但标记了 controllable 的角色由玩家操作，**不自动跳过**。
	if not u.is_manual():
		await get_tree().create_timer(UnitData.DUMMY_SKIP_DELAY).timeout
		_finish_turn()
		return

	_show_action_menu()


## ── 通用 AI（用户口径：给每个 AI 索敌优先级与规则，全图视野）────────────────
## 决策在 core/ai.gd（纯函数），这里只负责组装世界快照 + 执行计划。

func _is_ai_unit(u: Unit) -> bool:
	if u == null or not u.has_turn():
		return false
	if u.side == UnitData.Side.ENEMY:
		return gm.ai_enabled or not u.controllable
	return gm.ai_autoplay_player


func _ai_ctx(u: Unit) -> Ai.Ctx:
	var c := Ai.Ctx.new()
	c.me = u
	c.rng = rng
	for o in units:
		if not o.is_alive():
			continue
		if o.side != u.side:
			c.foes.append(o)
			if o.is_king:
				c.foe_king = o
	c.reachable = _compute_reachable(u)
	c.placeables = placeables
	c.me_has_sentry = gm.has_sentry(u)
	# 敌方哨兵覆盖的格子（全图视野，投掷手要靠它避开技能落点）
	for s in gm.sentries:
		if s.side == u.side or s.owner == null or not s.owner.is_alive():
			continue
		var ctr := gm.sentry_center(s)
		var r := float(s.rng_max)
		var x0: int = maxi(0, int(ctr.x - r) - 1)
		var x1: int = mini(GW - 1, int(ctr.x + r) + 1)
		var y0: int = maxi(0, int(ctr.y - r) - 1)
		var y1: int = mini(GH - 1, int(ctr.y + r) + 1)
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				if s.in_range(ctr, Vector2(float(x) + 0.5, float(y) + 0.5)):
					c.sentry_cells[Vector2i(x, y)] = true
	return c


func _ai_take_turn(u: Unit) -> void:
	_ai_turn = true
	await get_tree().create_timer(UnitData.DUMMY_SKIP_DELAY * 0.5).timeout
	if not u.is_alive():
		_ai_turn = false
		_finish_turn()
		return
	var plan := Ai.plan(_ai_ctx(u))
	_log("  🤖 %s：%s" % [u.name, plan.get("note", "-")])
	var mv = plan.get("move_to", null)
	if mv != null:
		await _ai_move(u, mv)
		if not u.is_alive():
			_ai_turn = false
			_finish_turn()
			return
		plan = Ai.plan(_ai_ctx(u))          # 位置变了，重新决策
		_log("  🤖 %s：%s" % [u.name, plan.get("note", "-")])
	match String(plan.get("action", "end")):
		"attack":
			_ai_attack(u, plan)
		"skill":
			_ai_skill(u, plan)
		"rest":
			_menu_rest()
		"move":
			var mv2 = plan.get("move_to", null)
			if mv2 != null:
				await _ai_move(u, mv2)
			_ai_turn = false
			_finish_turn()
			return
		_:
			_finish_turn()
	# 兜底：AI 回合如果既没结束也没在等弹道物，就强制收尾，绝不允许卡住
	if _ai_turn and active == u and not u.has_acted and _pending_turn_end == false \
			and field.items.is_empty():
		_log("  ⚠ AI 回合没有产生任何动作，强制结束")
		_finish_turn()
	_ai_turn = false


func _ai_move(u: Unit, cell: Vector2i) -> void:
	if u == null or cell == u.cell:
		return
	_do_move(u, cell)
	var guard := 0.0
	while u.visual != null and u.visual.is_walking() and guard < 4.0:
		guard += 0.05
		await get_tree().create_timer(0.05).timeout


func _ai_attack(u: Unit, plan: Dictionary) -> void:
	var aim: Vector2 = plan.get("aim", Vector2(float(u.cell.x) + 0.5, float(u.cell.y) + 0.5))
	# 沙盒元素
	if plan.has("placeable") and plan["placeable"] != null:
		var pl: Placeable = plan["placeable"]
		u.has_acted = true
		u.has_moved = true
		_push_unit_stats(u)
		if u.role == UnitData.Role.RANGED:
			var pf := Vector3(float(u.cell.x) + 0.5, 0.75, float(u.cell.y) + 0.5)
			var ap := _spawn_arrow(u, pf, Vector3(aim.x, 0.55, aim.y), null, false, true)
			if ap != null and ap.shot != null:
				ap.shot.target_placeable = pl
		else:
			_damage_placeable(u, pl, false)
		return
	var t: Unit = plan.get("target", null)
	if t == null or not t.is_alive():
		_finish_turn()
		return
	var ba: bool = bool(plan.get("break_armor", false))
	if u.role == UnitData.Role.MELEE:
		_apply_attack(u, t, ba, false)
		return
	u.has_acted = true
	u.has_moved = true
	_push_unit_stats(u)
	if u.role == UnitData.Role.RANGED:
		var f2 := Vector3(float(u.cell.x) + 0.5, 0.75, float(u.cell.y) + 0.5)
		_spawn_arrow(u, f2, Vector3(aim.x, 0.55, aim.y), t, ba, true)
	else:
		_spawn_shell(u, aim, true)


func _ai_skill(u: Unit, plan: Dictionary) -> void:
	var sid := String(plan.get("skill", ""))
	var aim: Vector2 = plan.get("aim", Vector2(float(u.cell.x) + 0.5, float(u.cell.y) + 0.5))
	var d := Skills.get_def(sid)
	if d.is_empty() or u.energy_points() < int(d["cost"]):
		_finish_turn()
		return
	if sid == "sentry":
		_cast_sentry(u)                     # 自己会扣精力 + 结束回合
		return
	if sid == "dive_bomb":
		var dcell: Vector2i = plan.get("cell", Vector2i(-1, -1))
		if dcell == Vector2i(-1, -1):
			_finish_turn()
			return
		_cast_dive(u, dcell)                # 进入准备状态，下一次轮到它时俯冲
		_finish_turn()
		return
	u.spend_energy(int(d["cost"]))
	u.has_acted = true
	u.has_moved = true
	_push_unit_stats(u)
	if sid == "carpet_bomb":
		_start_carpet_bomb(u, aim)
	elif sid == "grenade_launcher":
		# 枪榴弹：与玩家同一条生产线（会惊动哨兵、可被击落、落地后 GM 计时爆炸）
		var gp := Ordnance.make_grenade(u, aim, true)
		gp.shot.group = "grenade_ai"
		field.register(gp)
		_log("%s 投出【枪榴弹】：瞄准 (%.1f, %.1f)，4 个回合后爆炸" % [u.name, aim.x, aim.y])
	elif sid == "orbital_strike":
		_spawn_marker(u, aim)
	else:
		_finish_turn()


## ── 老国王的加农炮 AI ────────────────────────────────────────────────────────
## 用户口径：朝【距离最近的敌对单位】发射一发加农炮弹；
## 不管对方是否在射程内、路径上有没有障碍物或友军；并列最近时随机选一个。

func _fire_cannon_ai(u: Unit, ends_turn: bool = true) -> void:
	var foes: Array[Unit] = []
	for o in units:
		if o.is_alive() and o.side != u.side:
			foes.append(o)
	if foes.is_empty():
		if ends_turn:
			_finish_turn()
		return
	var from := Vector2(float(u.cell.x) + 0.5, float(u.cell.y) + 0.5)
	var best := 1e9
	for o in foes:
		best = minf(best, from.distance_to(Vector2(o.cell)))
	var picks: Array[Unit] = []
	for o in foes:
		if absf(from.distance_to(Vector2(o.cell)) - best) < 0.001:
			picks.append(o)
	var t: Unit = picks[rng.next_int(picks.size())]      # 并列最近 -> 随机
	var to := Vector2(float(t.cell.x) + 0.5, float(t.cell.y) + 0.5)
	var dir := to - from
	dir = dir.normalized() if dir.length() > 0.001 else Vector2.RIGHT
	# 射程 15：超出就只飞 15 格（打不到人，但照打 —— 用户口径"无论是否在射程内"）
	var reach: float = minf(from.distance_to(to), Ordnance.CANNON_RANGE)
	var land := from + dir * reach
	if u.visual != null:
		u.visual.rotation.y = atan2(dir.x, dir.y)        # 炮口转向目标（炮在身前 +Z）
	var muzzle := from + dir * 0.55
	_spawn_cannon(u, Vector3(muzzle.x, 0.80, muzzle.y), Vector3(land.x, 0.55, land.y), ends_turn)
	_log("  💣 %s 的加农炮瞄准最近的 %s（%.1f 格，射程 %.0f）：出膛" %
		[u.name, t.name, from.distance_to(to), reach])


## 这位老国王是不是已经有一发炮弹在飞（GM 定时空袭时避免叠炮）
func _king_ball_in_flight(u: Unit) -> bool:
	for it in field.items:
		var p: Projectile = it["p"]
		if p.kind == Projectile.KIND_CANNON and p.alive and p.owner_unit == u:
			return true
	return false


func _spawn_cannon(caster: Unit, from: Vector3, to: Vector3, ends_turn: bool) -> Projectile:
	var p := Ordnance.make_cannon(caster, from, to, ends_turn)
	field.register(p)
	return p

func _finish_turn() -> void:
	# QTE（箭矢弹反）期间全局暂停：回合也不许推进，等判定出结果再补上
	if _qte_active:
		_pending_turn_end = true
		return
	# 幂等保护：同一回合可能被两条路径同时结束（例如箭矢 Tween 回调 + 结算函数），
	# 若不做保护就会连续 advance 两次，表现为"某一方连续行动两回合"。
	if active == null or active == _turn_just_finished:
		return
	# 投掷手被动「装填」：本回合没有移动 -> 回合结束补 2 点精力（和休息叠加，休息共 4 点）
	var bonus_e: int = Passives.end_turn_energy(active)
	if bonus_e > 0:
		var before_e := active.energy
		active.energy = mini(active.energy_max, active.energy + Rules.points_to_milli(bonus_e))
		if active.energy != before_e:
			_push_unit_stats(active)
			_log("  🧨 %s 本回合没有移动：【装填】精力 +%d（%d→%d）" % [
				active.name, bonus_e, before_e / 1000, active.energy / 1000])
	_turn_just_finished = active
	if active.visual != null:
		active.visual.set_active(false)
	active = null
	selected = null
	queue.advance()
	_hide_action_menu()
	_clear_pending()
	_clear_hints()
	_refresh_all()
	_check_over()
	# GameMaster 的【回合边界】：调度型效果（轨道空爆）在这里暂停回合并执行，
	# 演完再继续进入下一个角色的回合。环境型效果（哨兵）不走这里，随时响应。
	await _gm_step()
	_next_turn()


## 把一个单位的三池变化立刻推到表现层与详情栏（休息、加点、Debug 改值都走这里）

func _push_unit_stats(u: Unit) -> void:
	if u != null and u.visual != null:
		u.visual.update_orb()
	_refresh_detail()


## 点沙盒道具：把它的描述与数据写进下方属性栏（用户要求）

func _show_placeable_info(p: Placeable) -> void:
	_placeable_info_text = _placeable_info(p)
	_refresh_detail()


## 道具信息文字（UI 直接显示）
func _placeable_info(p: Placeable) -> String:
	var txt := "[b][color=#9fe8ff]%s[/color][/b]（沙盒道具 · %dx%d）\n" % [p.name, p.w, p.h]
	txt += "位置 (%d, %d)\n" % [p.cell.x, p.cell.y]
	txt += "[b]力量[/b] %s / %s　　[b]护甲[/b] %s / %s\n" % [
		_fmt(p.power_cur), _fmt(p.power_max), _fmt(p.armor_cur), _fmt(p.armor_max)]
	txt += "物抗 %s　魔抗 %s\n" % [Unit.tier_name(p.pr), Unit.tier_name(p.mr)]
	txt += "阻挡移动：%s　　阻挡远程：%s\n" % [
		"是" if p.block_move else "否", "是" if p.block_ranged else "否"]
	txt += "[color=#ffd866]说明：[/color]"
	if p.name == "木刺":
		txt += "尖桩拒马，挡住地面单位；但箭矢可以从上方越过，不阻挡远程。"
	else:
		txt += "土堆够高，能挡住箭矢；但投掷手的抛物线攻击不受影响。"
	return txt


func _gm_step() -> void:
	var due := gm.dispatch_turn_boundary()
	if not gm.pending.is_empty():
		_log("  [GM] 第 %d 次回合边界：%s" % [gm.turn_count, gm.pending_desc()])
	# 英雄重生：到点的满血放回"两公主之间"的固定格（用户口径：等 10 个回合）
	for u in gm.due_revives():
		_revive_hero(u)
	# 老国王不进队列：由 GM 每 5 个回合边界替他打一炮（用户口径）
	if gm.turn_count > 0 and gm.turn_count % KING_FIRE_TURNS == 0:
		for u in units:
			if u.is_king and u.is_alive() and not _king_ball_in_flight(u):
				_log("  [GM] 第 %d 次回合边界：老国王的加农炮到点" % gm.turn_count)
				_fire_cannon_ai(u, false)
	for p in due:
		if p.skill_id == "grenade":
			_explode_grenade(p)
		if p.skill_id == "orbital_strike":
			_log("  [GM] ☄ %s 的轨道火力到点，暂停回合开始覆盖" % p.caster_name)
			_set_gm_busy(true)
			await _run_orbital_barrage(p)
			_set_gm_busy(false)


## GameMaster 演出开关：锁住所有角色操作与 >> 按钮

func _set_gm_busy(on: bool) -> void:
	_gm_busy = on
	if _btn_next != null:
		_btn_next.disabled = on
	if on:
		_hide_action_menu()
		_clear_pending()
		_clear_hints()
	else:
		pass


## 最后一人检测。
##
## 用户规则：
##   · 一方只剩 1 人、另一方 ≥2 人 -> 进入连击（孤军→对面每人→孤军→…）
##   · 连击一旦进入就保持：对面即使靠复活变回多人，也仍然是连击
##   · 双方都只剩 1 人 -> 退出连击，回到严格交替
##   · 任何时候都不允许同一方连续两回合（除非连击模式下对面全员依次行动）
##
## 返回 true 表示重排过（调用方需要重新取 current）。

func _check_last_stand() -> bool:
	# 决策在 TurnFlow（纯函数，可无头测试）；这里只负责"真的重排队列"
	var lone_alive: bool = queue.lone != null and queue.lone.is_alive()
	var plan := TurnFlow.last_stand_plan(units, queue.last_stand, lone_alive)
	if not bool(plan["changed"]):
		return false
	if bool(plan["want"]):
		var lone_unit: Unit = plan["lone"]
		var opps: Array[Unit] = plan["opponents"]
		queue.enter_last_stand(lone_unit, opps)
		_log("—— 进入最后一人连击：%s 独存 vs %d 人（%s）——" % [
			lone_unit.name, opps.size(), queue.dump()])
	else:
		queue.exit_last_stand(units)
		_log("—— 退出最后一人连击，回到常规循环 ——")
	return true


## 自检：队列里不允许出现"同一方连续两回合"。
## 唯一例外是连击模式（孤军与对面交替，孤军仍不会连出两次）。

func _queue_alternation_ok() -> bool:
	var prev := -1
	for u in queue.order:
		if not u.is_alive():
			continue
		if u.side == prev:
			return false
		prev = u.side
	return true

func _check_over() -> bool:
	# 胜负判定在 TurnFlow（只统计英雄，假人不算战力）
	var w := TurnFlow.winner(units)
	if w == TurnFlow.NONE:
		return false
	_show_result(w == TurnFlow.PLAYER)
	return true


## 胜者界面：中央一个面板 + 「继续」按钮，点了重开（回到初始状态）

func _show_result(win: bool) -> void:
	game_over = true
	_last_win = win
	if ui != null:
		ui.show_result(win)


func _on_result_continue() -> void:
	get_tree().reload_current_scene()

func _show_action_menu() -> void:
	if _ai_turn:
		return                              # AI 回合不弹菜单
	phase = Phase.MENU
	reachable = _compute_reachable(active)
	attackable = {}
	_draw_hints()
	_action_menu.visible = true
	_place_menu_near(active)
	# 刚移动过就不允许休息（用户规则）；且已行动过就不能再动
	if _btn_rest_menu != null:
		var can_rest: bool = active != null and not active.has_moved and not active.has_acted
		_btn_rest_menu.disabled = not can_rest
		_btn_rest_menu.tooltip_text = "" if can_rest else "本回合已经移动过，不能再休息"
	# 技能按钮：有技能的才亮，且精力不够时置灰并写明原因
	if _btn_skill != null:
		if active == null:
			_btn_skill.disabled = true
		else:
			var ids := Skills.skills_for(active)
			if ids.is_empty():
				_btn_skill.disabled = true
				_btn_skill.text = "技能（无）"
				_btn_skill.tooltip_text = ""
			else:
				var d := Skills.get_def(ids[0])
				_btn_skill.disabled = active.energy_points() < int(d["cost"])
				_btn_skill.text = "%s（%d 精力）" % [d["name"], d["cost"]]
				_btn_skill.tooltip_text = "%s\n%s" % [d["name"], d["desc"]]
	_refresh_all()

func _hide_action_menu() -> void:
	if ui != null:
		ui.hide_menus()


func _menu_move() -> void:
	if active == null:
		return
	_action_menu.visible = false
	_attack_menu.visible = false
	phase = Phase.MENU
	selected = active          # 必须有选中者，_draw_hints 才会画可移动格
	reachable = _compute_reachable(active)
	attackable = {}
	_clear_pending()
	_draw_hints()
	_refresh_all()

func _menu_attack() -> void:
	if active == null:
		return
	# 选了普攻/技能后**二级菜单立即消失**（用户强调）
	_action_menu.visible = false
	_clear_pending()          # 上一轮留下的黄勾不许残留
	# 关键：必须显式重置瞄准种类。技能用过之后 _aim_kind 会残留 "skill"，
	# 导致投掷手的普攻走技能分支 -> 不置 has_acted -> 一回合能打两次。
	_aim_skill_id = ""
	_skill_info_text = ""
	if active.role == UnitData.Role.THROWER:
		_begin_aim("throw")
	else:
		phase = Phase.CHOOSE_TARGET
		reachable = {}
		# 只显示"当前位置能打到的格子"（紫色高亮）
		attackable = Targeting.attack_range_cells(active, GW, GH)
		_draw_hints()
		_refresh_all()

func _menu_rest() -> void:
	if active == null or active.has_moved:
		if _ai_turn:
			_finish_turn()                   # AI 没有菜单可点，必须自己收尾，否则回合卡死
		return
	var before_p := active.power_cur
	var before_a := active.armor_cur
	var before_e := active.energy
	active.rest()
	# 关键：立刻把三池的变化推到表现层与详情栏，不要等下一回合
	_push_unit_stats(active)
	_log("%s 休息：力量 %s→%s  护甲 %s→%s  精力 %s→%s（回合结束）" % [
		active.name, _fmt(before_p), _fmt(active.power_cur),
		_fmt(before_a), _fmt(active.armor_cur),
		_fmt(before_e), _fmt(active.energy)])
	_finish_turn()


## 二级菜单的深色底：否则会和右侧详情面板叠在一起看不清

# ══════════════════════════════════════════════════════════════════════════════
# 攻击二级菜单：点敌人后弹出「打力量 / 破甲」，两个按钮上直接写清楚伤害
# ══════════════════════════════════════════════════════════════════════════════

func _show_attack_menu(t: Unit) -> void:
	_attack_target = t
	_action_menu.visible = false
	_attack_menu.visible = true

	# 力量线（用户口径：没有"用精力加伤害"了，预览就是纯力量对护甲）
	var pw: int = active.power_cur
	var p: Rules.Preview = Rules.preview(pw, t.armor_cur, t.pr)
	var power_txt := ""
	match p.branch:
		Rules.Branch.NO_DAMAGE:
			power_txt = "打力量\n0（打不动）"
		Rules.Branch.ROLL:
			power_txt = "打力量\n1（%d%%概率）" % p.hit_percent
		Rules.Branch.AUTO:
			power_txt = "打力量\n%d" % p.damage

	# 破甲线：固定伤害 = 攻方破甲值，无视物抗，打护甲池
	var bd: int = active.armor_break
	var break_txt := "破甲\n%s" % _fmt(bd)
	if t.armor_cur <= 0:
		break_txt = "破甲\n（护甲已空）"

	_btn_power.text = power_txt
	_btn_break.text = break_txt
	# 用户要求：即使"打不动"也**保留选择打力量的权力**（以后可能有上 buff 之类的设计），
	# 所以力量按钮永不置灰，只在文案上标出"打不动"。
	_btn_power.disabled = false
	_btn_break.disabled = (t.armor_cur <= 0)      # 对面没护甲时禁止破甲 —— 这条保留

	# 菜单贴着被点的敌人显示
	var sp := _camera.unproject_position(t.visual.global_position + Vector3(0, 0.5, 0))
	var vp := get_viewport().get_visible_rect().size
	_attack_menu.position = Vector2(
		clampf(sp.x + 30.0, 8.0, vp.x - 350.0),
		clampf(sp.y - 50.0, 60.0, vp.y - 220.0))
	_refresh_all()

func _confirm_attack(break_armor: bool) -> void:
	var t := _attack_target
	_attack_menu.visible = false
	_attack_target = null
	if t != null and t.is_alive():
		_attack_target_unit(t, break_armor)

func _begin_aim(kind: String = "throw") -> void:
	_aim_kind = kind
	_action_menu.visible = false
	phase = Phase.AIMING
	_aim_active = true
	_aim_valid = false
	_planned_cell = Vector2i(-1, -1)     # 必须重置！否则残留上一发的落点/默认 (0,0) 会被当成有效目标
	_aim_origin = get_viewport().get_mouse_position()
	_aim_now = _aim_origin
	_arrow_root.visible = true
	reachable = {}
	attackable = {}
	_clear_hints()
	if kind == "skill":
		pass                              # 技能瞄准与投掷共用同一套拖拽
	_refresh_all()


## 拖拽像素 -> 力度 t（0..1）

func _charge_from_drag(px: float) -> float:
	return clampf((px - UnitData.THROW_DRAG_MIN) / (UnitData.THROW_DRAG_MAX - UnitData.THROW_DRAG_MIN), 0.0, 1.0)


## 力度 -> 射程（格）。非线性：平方曲线，轻拉细腻、重拉才到远距离。

func _aim_range(t: float) -> float:
	return UnitData.THROW_RANGE_MIN + (UnitData.THROW_RANGE_MAX - UnitData.THROW_RANGE_MIN) * t * t


## 力度 t -> 箭头长度（世界单位）。约束：恒定落在 身高的 1~3 倍（用户要求）。
## 用同一条平方曲线，只是把 0~1 的力度映射到 1~3 倍身高：
##   len(t) = ARROW_LEN_MIN + (ARROW_LEN_MAX - ARROW_LEN_MIN) * t²   （单位 = 身高）
## 这样箭头长度与真实射程严格同步（同一 t），且永远看得见（最短也有 1 倍身高）。

func _arrow_len_for_t(t: float) -> float:
	var mult := UnitData.ARROW_LEN_MIN + (UnitData.ARROW_LEN_MAX - UnitData.ARROW_LEN_MIN) * t * t
	return mult * UnitData.UNIT_HEIGHT

func _update_aim(mouse: Vector2) -> void:
	_aim_now = mouse
	var origin3 := Vector3(float(active.cell.x) + 0.5, 0.0, float(active.cell.y) + 0.5)
	var from := _camera.project_ray_origin(mouse)
	var dir := _camera.project_ray_normal(mouse)
	if absf(dir.y) < 0.0001:
		return
	var t := -from.y / dir.y
	if t < 0.0:
		return
	var target := from + dir * t
	var flat := Vector2(target.x - origin3.x, target.z - origin3.z)
	if flat.length() < 0.15:
		_arrow_root.visible = false
		_aim_valid = false
		return
	var dir2 := flat.normalized()
	var drag_px := _aim_origin.distance_to(mouse)
	var charge := _charge_from_drag(drag_px)
	var dist := _aim_range(charge)
	_planned_cell = Vector2i(int(floor(origin3.x + dir2.x * dist)), int(floor(origin3.z + dir2.y * dist)))
	_aim_valid = true
	_aim_float_pos = Vector2(origin3.x + dir2.x * dist, origin3.z + dir2.y * dist)

	_arrow_root.visible = true
	# 箭头从【投掷手身前】沿方向贴地伸出，长度 = 射程（3~20 格 → 1~3 倍身高）
	var start := Vector3(origin3.x, 0.32, origin3.z) + Vector3(dir2.x, 0, dir2.y) * 0.34
	var d := Vector3(dir2.x, 0.0, dir2.y).normalized()
	var bx := d.cross(Vector3.UP).normalized()
	var bz := bx.cross(d).normalized()
	_arrow_root.position = start
	_arrow_root.basis = Basis(bx, d, bz)      # b.y = d（杆的轴向）
	var total_len := _arrow_len_for_t(charge)
	var head_len := clampf(total_len * 0.34, 0.42, 0.85)   # 箭头三角锥长度
	var shaft_len := maxf(0.12, total_len - head_len)
	_shaft.scale = Vector3(1.0, shaft_len, 1.0)
	_shaft.position = Vector3(0, shaft_len * 0.5, 0)
	_head.scale = Vector3(1.0, head_len, 1.0)
	_head.position = Vector3(0, shaft_len + head_len * 0.5, 0)
	_status.text = "力度 %d%%  射程 %.1f 格（箭头 %.1f 倍身高）  %s" % [
		int(round(charge * 100.0)), dist, total_len / UnitData.UNIT_HEIGHT,
		_aim_preview_text(_planned_cell)]


## 瞄准时把落点范围内的单位与该次的命中/伤害预览显示出来（含概率）

func _aim_preview_text(center: Vector2i) -> String:
	if center.x < 0 or active == null:
		return ""
	var parts: Array[String] = []
	for o in units:
		if not o.is_alive() or o == active:
			continue
		if not Targeting.blast_covers(Vector2(float(center.x) + 0.5, float(center.y) + 0.5), o.cell, BLAST_RADIUS):
			continue
		var eff_res: int = o.pr / 2                      # 炮击无视 50% 物抗
		var p: Rules.Preview = Rules.preview(active.power_cur, o.armor_cur, eff_res)
		var seg := "%s:破甲%s" % [o.name, _fmt(active.armor_break)]
		if p.branch == Rules.Branch.NO_DAMAGE:
			seg += "+力量打不动"
		elif p.branch == Rules.Branch.ROLL:
			seg += "+力量1(%d%%)" % p.hit_percent
		else:
			seg += "+力量%d" % p.damage
		if o.side == active.side:
			seg = "[友军]" + seg
		parts.append(seg)
	if parts.is_empty():
		return "落点无单位"
	return "影响→ " + " ｜ ".join(parts)


## 松开左键。
##   投掷手普攻：球沿抛物线飞出 -> 落地 -> 红圈 -> 结算（含友伤）
##   技能瞄准  ：飞出一枚【小球】（比头大、比炮弹小）-> 落地消失 -> 竖起紫色光柱 -> 结束回合

func _fire() -> void:
	if not _aim_active or active == null:
		return
	# 还没算出有效落点（例如按下就松开、鼠标没动过）：不消耗回合，继续瞄准
	if not _aim_valid:
		return
	var thrower := active
	var charge := _charge_from_drag(_aim_origin.distance_to(_aim_now))
	var dist := _aim_range(charge)
	var landing := _planned_cell
	var fpos := _aim_float_pos
	var skill_id := _aim_skill_id
	_arrow_root.visible = false
	_aim_active = false
	_aim_valid = false
	_planned_cell = Vector2i(-1, -1)

	# ── 技能①：地毯式轰炸（7 发依次落下）──
	if skill_id == "carpet_bomb":
		_aim_skill_id = ""
		_skill_info_text = ""
		_start_carpet_bomb(thrower, fpos)
		return

	# ── 技能②：枪榴弹（萨尼铁塔）：手感与投掷手一致，出界/被击落则作废 ──
	if skill_id != "" and bool(Skills.get_def(skill_id).get("grenade", false)):
		var dg := Skills.get_def(skill_id)
		if thrower.energy_points() < int(dg["cost"]):
			return
		thrower.spend_energy(int(dg["cost"]))
		thrower.has_acted = true
		thrower.has_moved = true
		_push_unit_stats(thrower)
		var gid := "grenade_%d" % Time.get_ticks_msec()
		var gp := Ordnance.make_grenade(thrower, fpos, true)
		gp.shot.group = gid
		field.register(gp)
		_log("%s 投出【%s】：落点 (%d, %d)，%d 个回合后爆炸" % [
			thrower.name, dg["name"], landing.x, landing.y, int(dg["delay_turns"])])
		return

	# ── 技能③：投出轨道标记召唤球（手感与普攻完全一致，出界/被击落则作废）──
	if skill_id != "":
		var ds := Skills.get_def(skill_id)
		if thrower.energy_points() < int(ds["cost"]):
			_show_action_menu()
			return
		thrower.spend_energy(int(ds["cost"]))
		thrower.has_acted = true
		thrower.has_moved = true
		_push_unit_stats(thrower)
		var mdist: float = Vector2(float(thrower.cell.x) + 0.5, float(thrower.cell.y) + 0.5).distance_to(fpos)
		_log("%s 投出【%s】召唤球，落点 (%d, %d)，距离 %.1f 格，飞行 %.2f 秒" %
			[thrower.name, ds["name"], landing.x, landing.y, dist, mdist / Ordnance.SHELL_TILES_PER_SEC])
		_spawn_marker(thrower, fpos)
		return

	thrower.has_acted = true
	thrower.has_moved = true
	_push_unit_stats(thrower)

	# 用户口径：投掷手是"玩家操作决定上下限"的角色，**一定要允许失误**。
	# 所以这里不再做任何射程/边界检查 —— 打偏、打出界都照打，
	# 炮弹飞出边界就在边界处消失（保留飞到边界的动画）。
	# 俯冲轰炸直升机：普攻是【吊射 37mm 火箭】——耗 4 精力、瞄准结果翻倍、8 发分 4 次齐射
	if Unit.base_name(thrower.name).begins_with(HELI_PREFIX):
		_rocket_salvo(thrower, fpos)
		return
	var sdist: float = Vector2(float(thrower.cell.x) + 0.5, float(thrower.cell.y) + 0.5).distance_to(fpos)
	_log("%s 投掷，落点 (%d, %d)，射程 %.1f 格，飞行 %.2f 秒" %
		[thrower.name, landing.x, landing.y, dist, sdist / Ordnance.SHELL_TILES_PER_SEC])
	_spawn_shell(thrower, fpos, true)


## ── 炮弹（普攻 / 地毯式轰炸共用）────────────────────────────────────────────
## 弹道物的【物理】交给 Projectile；【伤害/落点】放在发射单里（用户口径）。
## 速度恒定 Ordnance.SHELL_TILES_PER_SEC 格/秒（用户要求降到 2 格/秒）。

func _spawn_shell(caster: Unit, to: Vector2, ends_turn: bool,
		pre: float = 0.0, group: String = "", blast_r: float = Ordnance.DEFAULT_BLAST_R) -> Projectile:
	var p := Ordnance.make_shell(caster, to, ends_turn, rng, pre, group, blast_r)
	field.register(p)
	return p

func _spawn_marker(caster: Unit, to: Vector2) -> Projectile:
	var p := Ordnance.make_marker(caster, to)
	field.register(p)
	return p

func _fire_skill_at(sh: Ordnance.Shot, fpos: Vector2) -> void:
	var caster: Unit = sh.caster if sh != null else null
	if caster == null:
		return
	var d := Skills.get_def("orbital_strike")
	var cell := Vector2i(int(floor(fpos.x)), int(floor(fpos.y)))
	gm.schedule("orbital_strike", caster, cell, fpos, int(d["delay_turns"]))
	_orbital_marks.append(fpos)
	# 光柱挂在这一发身上：允许多个在途打击同时存在（用户要求）
	var pend: GameMaster.Pending = gm.pending[gm.pending.size() - 1]
	pend.pylon = _raise_pylon_at(fpos)
	_log("%s 使用【%s】：标记落点 (%d, %d)，剩余 %d" %
		[caster.name, d["name"], cell.x, cell.y, caster.energy_points()])
	_log("  ⏳ 轨道火力已锁定：%d 个回合后落下 %d 发（GameMaster 计时：%s）" % [
		int(d["delay_turns"]), d["shells"], gm.pending_desc()])


## 箭矢在这一段路径里撞到了什么。返回 {unit: Unit} / {placeable: Placeable} / {}

func _arrow_hit_check(p: Projectile, prev: Vector3, cur: Vector3) -> Dictionary:
	# 跳过谁：默认是自己的箭不打自己；弹反箭跳过的是"出手位置的那个人"（杰拉尔德）
	var skip: Unit = null if p.hit_self else (p.ignore_unit if p.ignore_unit != null else p.owner_unit)
	# ① 角色（细圆柱判定；沿线采样，保证不漏）。判定半径用这一发自己的身体半径
	#    （箭矢 0.075 / 加农炮弹 0.25）
	var u := Targeting.arrow_body_hit_seg(prev, cur, skip, units, UNIT_BODY_R, p.hit_r)
	if u != null:
		if p.shot != null:
			p.shot.last_hit_dist = p.from.distance_to(p.pos())   # 破片伤害要用"飞了多远"
		return {"unit": u}
	# ② 沙盒道具：拦不拦由 Ballistics 一处说了算
	#    （木刺永不拦箭；土堆只要箭从它上空飞过就拦；投掷物土堆挡不住）
	#    注意这里看的是【伤害归属】（owner_unit），不是上面那个"跳过谁"
	var locked: Placeable = p.shot.target_placeable if p.shot != null else null
	if locked != null and locked.is_alive():
		var lc := _placeable_near(cur)
		if lc == locked or Vector2(cur.x, cur.z).distance_to(
				Vector2(float(locked.cell.x) + 0.5, float(locked.cell.y) + 0.5)) <= 0.6:
			return {"placeable": locked}          # 玩家/AI 明确锁定的道具：一定打得中
	if p.owner_unit != null and p.owner_unit.role == UnitData.Role.THROWER:
		return {}
	var pl := _placeable_near(cur)
	if pl != null and Ballistics.placeable_blocks(pl, p.kind):
		return {"placeable": pl}
	return {}


## ── 弹道物的后果处理：弹道物理只上报，具体做什么全在这里（用户口径）──

func _on_projectile_event(event: String, p: Projectile, extra = null) -> void:
	var sh: Ordnance.Shot = p.shot
	match event:
		ProjectileField.EV_OUT:
			_log("  ✈ %s 的%s飞到边界 (%.1f, %.1f)，直接移除（无爆炸）" %
				[p.owner_name, ProjectileField.kind_cn(p.kind), p.removed_at.x, p.removed_at.y])
		ProjectileField.EV_HIT_PROJ:
			var victim: Projectile = extra
			_log("  💥 %s的%s 被%s击落" % [p.owner_name, ProjectileField.kind_cn(p.kind),
				ProjectileField.kind_cn(victim.kind)])
			# 用户口径：炮弹在半空被打掉 -> 就地空爆，而且**要真的有伤害**。
			# 召唤球不走这条路（被击落只是整发作废，不炸）。
			for pr in [p, victim]:
				if pr != null and pr.kind == Projectile.KIND_SHELL and not pr.alive:
					_air_burst(pr)
			# 弓箭手被动「蓄势」：哨兵箭每摧毁一枚投掷物 +1 层
			for pr2 in [p, victim]:
				if pr2 != null and pr2.kind == Projectile.KIND_ARROW \
						and pr2.shot != null and pr2.shot.tint_sentry:
					Passives.add_focus(pr2.shot.caster)
					if Passives.focus_stacks(pr2.shot.caster) > 0:
						_log("  🏹 %s【蓄势】+1（下一发普攻 +%d 力量，当前 %d 层）" % [
							pr2.shot.caster.name,
							int(Passives.def("arrow_focus")["power_bonus"]),
							Passives.focus_stacks(pr2.shot.caster)])
		ProjectileField.EV_HIT_TARGET:
			_resolve_arrow_hit(sh, extra)
		ProjectileField.EV_LANDED:
			_on_proj_landed(p)
		ProjectileField.EV_REMOVED:
			_after_projectile_gone(sh)


## 一发弹道物彻底消失之后的收尾：编组计数，或者按发射单结束回合

func _after_projectile_gone(sh: Ordnance.Shot) -> void:
	var gid: String = sh.group if sh != null else ""
	if gid != "" and _proj_groups.has(gid):
		_proj_groups[gid] = int(_proj_groups[gid]) - 1
		if int(_proj_groups[gid]) <= 0:
			_proj_groups.erase(gid)
			_finish_turn()
		return
	if sh != null and sh.ends_turn:
		_finish_turn()


## 半空被打爆的炮弹：落点就是它当时的位置。
## 用户口径：三维判定 + 爆炸范围恒定为一格球（半径 0.5）——在头顶上炸但飞得高就没伤害。
func _air_burst(p: Projectile) -> void:
	var sh: Ordnance.Shot = p.shot
	var ctr: Vector3 = p.pos3()
	_log("  💥 炮弹在半空被打爆：(%.2f, %.2f) 高度 %.2f 空爆（一格球，三维判定）" %
		[ctr.x, ctr.z, ctr.y])
	_show_impact(Vector2(ctr.x, ctr.z), ctr.y)
	var ring := _make_impact_ring(Vector2(ctr.x, ctr.z),
		sh.blast_r if sh != null else BLAST_RADIUS)
	ring.position.y = maxf(0.05, ctr.y)
	_flash_impact(ring)
	var attacker: Unit = sh.caster if sh != null else null
	var hits: Array = Damage.air_burst(attacker, ctr,
		sh.opts if sh != null else {}, units, attacker, Damage.AIR_BURST_R)
	if hits.is_empty():
		_log("  （一格球内没有角色）")
		return
	for h in hits:
		_log(h.text)
		if h.unit != null:
			_after_damage_to_unit(h.unit)


## 落地结算（由事件处理调用）

func _on_proj_landed(p: Projectile) -> void:
	var at := p.pos()
	var sh: Ordnance.Shot = p.shot
	# 用户口径：炮弹 / 召唤球落进河里直接消失（河里不拦弹道，只是落进去就没了）
	if Level.is_river(Vector2i(int(floor(at.x)), int(floor(at.y)))):
		_log("  🌊 %s的%s落进河里，直接消失（无爆炸）" % [
			p.owner_name, ProjectileField.kind_cn(p.kind)])
		return
	match p.kind:
		Projectile.KIND_SHELL:
			_show_impact(at)
			var ring := _make_impact_ring(at, sh.blast_r if sh != null else BLAST_RADIUS)
			_flash_impact(ring)
			_resolve_blast(sh.caster if sh != null else null, at,
				sh.opts if sh != null else {}, sh.blast_r if sh != null else BLAST_RADIUS)
		Projectile.KIND_MARKER:
			_fire_skill_at(sh, at)
		Projectile.KIND_ARROW:
			pass
		Projectile.KIND_CANNON:
			pass                              # 加农炮弹打空就是打空，没有爆炸
		Projectile.KIND_ROCKET:
			_show_impact(at)                                  # 落点提示（不含红圈也行，这里只是标记）
			_resolve_blast(sh.caster if sh != null else null, at,
				sh.opts if sh != null else {}, Ordnance.ROCKET_BLAST_R)
			_rocket_fragments(sh.caster if sh != null else null, at)
		Projectile.KIND_GRENADE:
			_spawn_grenade_model(Vector2i(int(floor(at.x)), int(floor(at.y))), p)
		Projectile.KIND_FRAGMENT:
			pass                              # 破片打空就是打空
		Projectile.KIND_BULLET:
			pass                              # 子弹打空就是打空


# ── 给自检/试玩用的薄封装（真实实现都在 field 里）──

func clear_projectiles() -> void:
	if field != null:
		field.clear()

func live_projectiles() -> int:
	return 0 if field == null else field.live_count()

func _proj_collision(p: Projectile) -> Projectile:
	return null if field == null else field.collision(p)

## 火箭落地：从落点随机两个方向生成 2 枚破片（破片口径与手榴弹一致：不分敌我）
func _rocket_fragments(caster: Unit, at: Vector2) -> void:
	var from := Vector3(at.x, Ordnance.FRAGMENT_HEIGHT, at.y)
	for i in Ordnance.ROCKET_FRAGMENTS:
		var ang := rng.next_float() * TAU
		var fp := Ordnance.make_fragment(caster, from, Vector2(cos(ang), sin(ang)), false)
		fp.hit_self = true
		fp.shot.group = "rocket_frag"
		field.register(fp)
	_log("  🚀 火箭落地 (%.1f, %.1f)：直径 2 格爆炸 + %d 枚破片" % [
		at.x, at.y, Ordnance.ROCKET_FRAGMENTS])


## ── 直升机的吊射 37mm 火箭：8 发、4 次齐射（左右各一发）、间隔 250ms ──────────
## 用户口径：普攻需 4 精力；瞄准同投掷手但"结果翻倍"（先前飞 x 格现在飞 2x 格）；
## 落点 = 以瞄准落点为圆心、半径 4 格圆内随机 8 个点；每发直击范围 = 半径 1 格圆。
func _rocket_salvo(u: Unit, fpos: Vector2) -> void:
	var cfg := Level.heli()
	var cost: int = int(cfg["basic_cost"])
	if u.energy_points() < cost:
		return
	u.spend_energy(cost)
	_push_unit_stats(u)
	# 瞄准翻倍：以自身为原点，把拖拽得到的位移 ×2
	var base := Vector2(float(u.cell.x) + 0.5, float(u.cell.y) + 0.5)
	var dir := fpos - base
	var doubled := base + dir * float(cfg["aim_mult"])
	var max_d := float(u.rng_max)
	if doubled.distance_to(base) > max_d:
		doubled = base + dir.normalized() * max_d          # 不超过射程 40
	var scatter := float(cfg["scatter_r"])
	var rockets := int(cfg["rockets"])
	var pairs := int(cfg["salvo_pairs"])
	var gap := float(cfg["salvo_gap"])
	var per := maxi(1, rockets / maxi(1, pairs))
	_log("  🚁 %s 吊射火箭：瞄准 (%.1f, %.1f)（原始 (%.1f, %.1f) ×%.0f），%d 发 / %d 次齐射" % [
		u.name, doubled.x, doubled.y, fpos.x, fpos.y, float(cfg["aim_mult"]), rockets, pairs])
	for k in pairs:
		for i in per:
			var ang := rng.next_float() * TAU
			var rr := scatter * sqrt(rng.next_float())     # 圆内均匀
			var aim := doubled + Vector2(cos(ang) * rr, sin(ang) * rr)
			var last := k == pairs - 1 and i == per - 1
			var from := Vector3(float(u.cell.x) + 0.5, u.hover + 0.25, float(u.cell.y) + 0.5)
			var p := Ordnance.make_rocket(u, from, aim, last)
			p.shot.target = null
			field.register(p)
		if k < pairs - 1:
			await get_tree().create_timer(gap).timeout


## ── 枪榴弹：地上的模型 + 4 回合后爆炸出 8 枚破片 ─────────────────────────
var _grenade_models: Dictionary = {}      # 格 -> Node3D（模型，不可交互）


## 落地后立一个手榴弹模型（椭球 + 顶部削平长方体 + 经纬线凹槽），并让 GM 开始计时
func _spawn_grenade_model(cell: Vector2i, p: Projectile) -> void:
	var sh: Ordnance.Shot = p.shot
	var d: Dictionary = Skills.get_def("grenade_launcher")
	var delay: int = int(d.get("delay_turns", 4))
	var caster_name := p.owner_name
	var caster_side: int = p.side
	if _grenade_models.has(cell) and is_instance_valid(_grenade_models[cell]):
		(_grenade_models[cell] as Node3D).queue_free()
	var root := Node3D.new()
	root.position = Vector3(float(cell.x) + 0.5, 0.0, float(cell.y) + 0.5)
	add_child(root)
	# 椭球主体
	var body := MeshInstance3D.new()
	var sp := SphereMesh.new()
	sp.radius = 0.20
	sp.height = 0.40
	body.mesh = sp
	body.scale = Vector3(1.0, 0.85, 1.0)
	body.position = Vector3(0, 0.17, 0)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.30, 0.34, 0.24)
	m.roughness = 0.6
	body.material_override = m
	root.add_child(body)
	# 顶部削平 -> 长方体
	var cap := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.13, 0.09, 0.13)
	cap.mesh = bm
	cap.position = Vector3(0, 0.35, 0)
	var cm := StandardMaterial3D.new()
	cm.albedo_color = Color(0.22, 0.25, 0.18)
	cap.material_override = cm
	root.add_child(cap)
	# 经纬线凹槽：3 圈纬线 + 4 条经线（细圆环近似）
	var gm2 := StandardMaterial3D.new()
	gm2.albedo_color = Color(0.12, 0.14, 0.10)
	for i in 3:
		var ring := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = 0.185
		tm.outer_radius = 0.205
		ring.mesh = tm
		ring.position = Vector3(0, 0.06 + float(i) * 0.11, 0)
		ring.material_override = gm2
		root.add_child(ring)
	for j in 4:
		var mer := MeshInstance3D.new()
		var tm2 := TorusMesh.new()
		tm2.inner_radius = 0.185
		tm2.outer_radius = 0.205
		mer.mesh = tm2
		mer.rotation_degrees = Vector3(90, 0, float(j) * 45.0)
		mer.position = Vector3(0, 0.17, 0)
		mer.material_override = gm2
		root.add_child(mer)
	_grenade_models[cell] = root
	_log("  💣 手榴弹落地 (%d, %d)：%d 个回合后爆炸（%s 投出）" % [
		cell.x, cell.y, delay, caster_name])
	gm.schedule_grenade(cell, caster_name, caster_side, delay)


## 球状闪光（用户口径：只要球状闪光，不要红圈）
## 一次性的发光球体：迅速膨胀 + 淡出，播完自己销毁。
var _last_flash: Node3D = null


func _flash_sphere(center: Vector3, radius: float = 1.5, life: float = 0.38) -> void:
	var mi := MeshInstance3D.new()
	var sp := SphereMesh.new()
	sp.radius = 1.0
	sp.height = 2.0
	sp.radial_segments = 20
	sp.rings = 12
	mi.mesh = sp
	mi.position = center
	mi.scale = Vector3.ONE * (radius * 0.28)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD          # 叠加发光，不是红圈那种贴地圆盘
	m.albedo_color = Color(1.0, 0.86, 0.45, 0.85)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.80, 0.35)
	m.emission_energy_multiplier = 3.0
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	add_child(mi)
	_last_flash = mi
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(mi, "scale", Vector3.ONE * radius, life * 0.45)
	tw.tween_property(m, "albedo_color", Color(1.0, 0.9, 0.6, 0.0), life)
	tw.tween_property(m, "emission_energy_multiplier", 0.0, life)
	tw.set_parallel(false)
	tw.tween_callback(func() -> void:
		if is_instance_valid(mi):
			mi.queue_free())


## 爆炸：向 8 个方向各射出一枚破片（不分敌我，会伤到自己人）
func _explode_grenade(p: GameMaster.Pending) -> void:
	var cell: Vector2i = p.center
	if _grenade_models.has(cell) and is_instance_valid(_grenade_models[cell]):
		(_grenade_models[cell] as Node3D).queue_free()
	_grenade_models.erase(cell)
	var caster: Unit = null
	for u in units:
		if u.name == p.caster_name:
			caster = u
	var d: Dictionary = Skills.get_def("grenade_launcher")
	var n: int = int(d.get("fragments", 8))
	var from := Vector3(float(cell.x) + 0.5, Ordnance.FRAGMENT_HEIGHT, float(cell.y) + 0.5)
	var base := rng.next_float() * TAU
	_flash_sphere(Vector3(from.x, 0.55, from.z), 1.5, 0.38)      # 球状闪光（不要红圈）
	_log("  💥 手榴弹爆炸 (%d, %d)：向 %d 个方向撒出破片" % [cell.x, cell.y, n])
	for i in n:
		var ang := base + float(i) * TAU / float(n)
		var dir := Vector2(cos(ang), sin(ang))
		var fp := Ordnance.make_fragment(caster, from, dir, false)
		fp.hit_self = true               # 用户口径：破片有友伤与自伤
		fp.shot.group = "grenade_frag"
		field.register(fp)


## ── 圣萨尼：她的回合开始时，复活"她回合前最后一个阵亡的可操作队友"，每条命一次 ──
func _holy_sani_check(u: Unit) -> void:
	if u == null or not Passives.has(u, "holy_sani"):
		return
	if u.tags.has("holy_sani_used"):
		return
	var mate := gm.last_dead_teammate(u.side, units)
	if mate == null:
		return
	u.tags["holy_sani_used"] = true
	_log("  ✨ %s 触发【圣萨尼】：立即复活队友 %s" % [u.name, mate.name])
	_revive_hero(mate)


## 破片：箭矢类平飞弹（无重力、离地 0.5），伤害随飞行距离衰减
func _spawn_fragment(caster: Unit, from: Vector3, dir: Vector2) -> Projectile:
	var p := Ordnance.make_fragment(caster, from, dir)
	field.register(p)
	return p


func _resolve_arrow_hit(sh: Ordnance.Shot, what: Dictionary) -> void:
	var attacker: Unit = sh.caster
	var silent: bool = not sh.ends_turn
	# 弓箭手被动「蓄势」：只吃"选普攻选目标"的那一发（哨兵箭 tint_sentry、技能都不算）
	var is_basic: bool = sh.target != null and not sh.tint_sentry
	var bonus: int = Passives.focus_bonus_milli(attacker) if is_basic else 0
	var mult: float = sh.power_mult
	if what.has("unit"):
		var victim: Unit = what["unit"]
		# 被动：箭矢弹反。先扣下伤害，暂停全局打 QTE，结果出来再结算（用户口径）。
		if gm.claim_arrow_deflect(victim):
			if is_basic:
				Passives.clear_focus(attacker)      # 这一发算命中了：蓄势清零
			_start_arrow_qte(victim, sh, bonus)
			return
		# 子弹：阶梯衰减（0-12 格 100% / 12-16 格 60% / 16-24 格 20% / >24 格 0）
		if sh.kind == Projectile.KIND_BULLET:
			var bd: float = sh.last_hit_dist
			var bmult: float = Damage.bullet_mult(bd)
			var bpw: int = int(floor(float(attacker.power_cur) * bmult))
			var bbr: int = int(floor(float(attacker.armor_break) * bmult))
			_apply_attack(attacker, victim, true, silent, 0, 1.0, bpw, bbr)
			_log("  ✦ 子弹命中 %s：飞行 %.1f 格 ×%.0f%% → 力 %d / 甲 %d" % [
				victim.name, bd, bmult * 100.0, bpw / 1000, bbr / 1000])
			return
		# 破片：伤害按"离生成点走了多远"衰减（0 格 25/25 ｜ 3 格 12/12 ｜ 16 格 0）
		if sh.kind == Projectile.KIND_FRAGMENT:
			var fd: float = sh.last_hit_dist
			_apply_attack(attacker, victim, true, silent, 0, 1.0,
				Damage.fragment_power_milli(fd), Damage.fragment_break_milli(fd))
			_log("  ✦ 破片命中 %s：飞行 %.1f 格 → 力 %d / 甲 %d" % [
				victim.name, fd,
				Damage.fragment_power_milli(fd) / 1000, Damage.fragment_break_milli(fd) / 1000])
			return
		# 反弹回来的箭：命中一定要有明确日志（用户报过"命中却没伤害、也没日志"）
		if sh.reflected:
			_log("  ↩ 反弹箭命中 %s" % victim.name)
		_apply_attack(attacker, victim, sh.break_armor, silent, bonus, mult)
	elif what.has("placeable"):
		_damage_placeable(attacker, what["placeable"], silent)
	if is_basic:
		# 用户口径：命中之后清零（打空不算）
		if bonus > 0:
			_log("  🏹 %s 的【蓄势】打出 +%d 力量后清零" % [attacker.name, bonus / 1000])
		Passives.clear_focus(attacker)


## ── 箭矢弹反（杰拉尔德）：暂停时间 -> 3 次按键 -> 反弹 or 结算伤害 ──────────
## 伤害不在这里结算：GM 已经"受理"了这次弹反，判定失败时再补伤害。

func _start_arrow_qte(victim: Unit, sh: Ordnance.Shot, bonus_milli: int = 0) -> void:
	# AI 接管的一方不弹 QTE：直接按概率判定。
	# （否则自动演算/AI 对射会永远停在 get_tree().paused = true 上没人按键）
	if _is_ai_unit(victim) or gm.ai_autoplay_player:
		var ok := rng.next_float() < AI_QTE_CHANCE
		_log("  🛡 %s 触发【箭矢弹反】：AI 自动判定 %s" % [victim.name, "成功" if ok else "失败"])
		_on_arrow_qte_done(ok, victim, sh, bonus_milli)
		return
	_qte_active = true
	get_tree().paused = true              # 动画 / 弹道 / 输入全部停住（用户口径：暂停时间）
	_log("  🛡 %s 触发【箭矢弹反】" % victim.name)
	var layer := CanvasLayer.new()
	layer.layer = 10                      # 盖在所有 HUD 之上
	add_child(layer)
	var q := ArrowQTE.new()
	layer.add_child(q)
	arrow_qte = q
	q.start(victim, Passives.def("arrow_deflect"), rng, _camera)
	q.finished.connect(func(ok: bool) -> void:
		_on_arrow_qte_done(ok, victim, sh, bonus_milli)
		if is_instance_valid(layer):
			remove_child(layer)
			layer.queue_free())


func _find_arrow_qte() -> ArrowQTE:
	return arrow_qte if is_instance_valid(arrow_qte) else null


func _on_arrow_qte_done(ok: bool, victim: Unit, sh: Ordnance.Shot, bonus_milli: int = 0) -> void:
	get_tree().paused = false
	_qte_active = false
	arrow_qte = null
	var shooter: Unit = sh.caster
	if ok and shooter != null:
		# 反弹：从受害者身上射回射手，**发射者仍然是当初射箭的那个人**（用户口径）
		var vpos := Vector2(float(victim.cell.x) + 0.5, float(victim.cell.y) + 0.5)
		var spos := Vector2(float(shooter.cell.x) + 0.5, float(shooter.cell.y) + 0.5)
		var dir := spos - vpos
		dir = dir.normalized() if dir.length() > 0.001 else Vector2.RIGHT
		var start := vpos + dir * 0.6      # 从杰拉尔德身前出手：否则箭一生成就撞到自己
		var landing := gm.reflect_landing(victim, shooter, rng)
		var refl := _spawn_arrow(shooter,
			Vector3(start.x, 0.75, start.y),
			Vector3(landing.x, 0.55, landing.y), null, sh.break_armor, false, false)
		refl.ignore_unit = victim        # 物理上从杰拉尔德身上出手：判定跳过他自己
		refl.shot.reflected = true       # 标记：命中时要写"反弹箭命中"日志
		_log("  ↩ 弹反成功：%s 的箭被弹回，落点 (%.2f, %.2f)，距离 %.1f 格，散步半径 %.2f 格" % [
			shooter.name, landing.x, landing.y, vpos.distance_to(spos),
			Spread.reflect_radius(vpos.distance_to(spos))])
	else:
		_log("  ✗ 弹反失败，照常结算伤害")
		_apply_attack(shooter, victim, sh.break_armor, not sh.ends_turn, bonus_milli, sh.power_mult)
	if _pending_turn_end:
		_pending_turn_end = false
		_finish_turn()


## ── 哨兵：GM 的 FIFO 队列每 150ms 放出一支箭（不再有 200ms 延迟）────────────
##
## 一次一支、轮流瞄准：队头是谁就打谁此刻的位置，打完轮到队尾；
## 队头已经消失或飞出射界就剔除，接着看下一个。规则全在 GameMaster.sentry_tick 里。

func _tick_sentry_queue(delta: float) -> void:
	for sh in gm.sentry_tick(delta):
		_sentry_fire(sh)


## 放出一支哨兵箭（GM 的队列决定什么时候、打哪里）
func _sentry_fire(sh: GameMaster.Shot) -> void:
	var a: Unit = sh.sentry.owner
	if a == null or not a.is_alive():
		return
	# 用户口径：不再瞄准对象当前位置，而是【以它当前位置为球心、半径 1 格的球内随机一点】
	# 用户口径：拦弹道物也吃同一套散布 —— 炮弹有速度，随机性正好允许"提前量"出现，多抽几次总有一次是对的
	var j := Spread.ball_offset(SENTRY_AIM_BALL_R, rng)
	var aim := Vector3(sh.at.x + j.x, 0.55 + j.y * 0.5, sh.at.y + j.z)
	_log("  🎯 哨兵射击（%s）：%s 实际位置 (%.2f, %.2f) → 瞄准 (%.2f, %.2f)｜队列剩余 %d" %
		[sh.reason, sh.target_name, sh.at.x, sh.at.y, aim.x, aim.z, gm.sentry_queue_size()])
	_spawn_arrow(a, Vector3(float(a.cell.x) + 0.5, 0.75, float(a.cell.y) + 0.5),
		aim, null, false, false, true)


## ── 箭矢（远程普攻 / 哨兵共用）──────────────────────────────────────────────
## 弓箭是**纯物理**的：恒定速度、真实抛物线、机头永远朝着速度方向（平抛出去）。
## 伤害与落点都由发射者给（放在发射单里），弹道物本身不知道伤害。

func _spawn_arrow(attacker: Unit, from: Vector3, to: Vector3, target: Unit,
		break_armor: bool, ends_turn: bool, tint_sentry: bool = false) -> Projectile:
	var p := Ordnance.make_arrow(attacker, from, to, target, break_armor, ends_turn, tint_sentry)
	field.register(p)
	return p

func _resolve_mortar_impact(attacker: Unit, center: Vector2i) -> void:
	_resolve_blast(attacker, Vector2(float(center.x) + 0.5, float(center.y) + 0.5))


## 一次炮击的结算（浮点圆心）。普攻炮击与地毯式轰炸共用这一份逻辑：
##   · 同时造成【破甲伤害】（= 攻方破甲值）与【力量伤害】
##   · 力量伤害无视 50% 物理抗性
##   · 圆沾到格子就算命中（所以圆心到格中心距离 <= BLAST_RADIUS + 0.5）

func _resolve_blast(attacker: Unit, ctr: Vector2,
		pre_opts: Dictionary = {}, radius: float = BLAST_RADIUS) -> void:
	var o: Dictionary = pre_opts
	if o.is_empty():
		o = Damage.blast_opts(attacker, rng)
	var hits: Array = Damage.blast(attacker, ctr, radius, o, units, placeables, attacker, attacker.side, true)
	if hits.is_empty():
		_log("  落点范围内没有目标（空爆）")
		return
	for h in hits:
		_log(h.text)
		if h.unit != null:
			_after_damage_to_unit(h.unit)
		else:
			_after_damage_to_placeable(h.placeable)


# ══════════════════════════════════════════════════════════════════════════════
# 技能：地毯式轰炸（投掷手 / 空爆迫击炮）
#   · 瞄准方式与普攻完全一样（拖拽 -> 松手）
#   · 轰炸区：以落点（爆心）为中心、沿"投掷手 -> 落点"这条中轴线铺开的
#     长 7 格 x 宽 5 格长方形（**不显示**）
#   · 区内取 7 个落点：切成 7 个"宽5 x 长1"长条，每条至少一个点；
#     任意两点间距 >= 0.2 格
#   · 7 发炮弹间隔 0.2 秒从投掷手飞出，由近及远逐个落到落点上
#   · 每发威力 = 普攻（破甲 + 力量，无视 50% 物抗，不分敌我）
#   · 每个落点画红圈
# ══════════════════════════════════════════════════════════════════════════════

func _start_carpet_bomb(caster: Unit, center: Vector2) -> void:
	var d := Skills.get_def("carpet_bomb")
	if caster == null or not caster.is_alive():
		pass
		return
	if caster.energy_points() < int(d["cost"]):
		_aim_kind = "throw"
		_show_action_menu()
		return
	caster.spend_energy(int(d["cost"]))
	caster.has_acted = true
	caster.has_moved = true
	_push_unit_stats(caster)
	_aim_skill_id = ""
	_skill_info_text = ""
	_aim_kind = "throw"

	var origin := Vector2(float(caster.cell.x) + 0.5, float(caster.cell.y) + 0.5)
	var pts := Skills.carpet_points(d, center, center - origin, rng)
	var names: Array[String] = []
	for p in pts:
		names.append("(%.1f,%.1f)" % [p.x, p.y])
	_log("%s 呼叫【%s】：%d 个落点 %s" % [caster.name, d["name"], pts.size(), " → ".join(names)])
	# 7 发炮弹：间隔 gap_sec 逐一起飞（用 Projectile.pre 做延迟），
	# 于是它们全是"物理弹道物"——可以被箭击落、可以被哨兵盯上、出界就地消失。
	# 速度恒定 Ordnance.SHELL_TILES_PER_SEC，由近及远距离递增 -> 自然就是"由近及远逐个落地"。
	var gap := float(d["gap_sec"])
	# 全部打进同一个编组：7 发全落地/全消失之后才结束回合
	var gid := "carpet_%d" % gm.turn_count + str(Time.get_ticks_msec())
	_proj_groups[gid] = pts.size()
	for i in pts.size():
		# 地毯式轰炸的爆炸范围用【轨道炮击同款】（比普攻小的那个版本）
		_spawn_shell(caster, pts[i], false, float(i) * gap, gid, CARPET_BLAST_R)


## 角色挨打后的统一收尾：闪白、刷新指示器、判定阵亡

## 用户口径：直升机力量低于阈值 -> 坠机（加速下坠 -> 2.5 格炮击 -> 死亡）
func _check_heli_crash(u: Unit) -> bool:
	if u == null or not u.is_alive():
		return false
	if not Unit.base_name(u.name).begins_with(HELI_PREFIX):
		return false
	if u.tags.has("crashing"):
		return false
	var cfg := Level.heli()
	if u.power_cur >= int(cfg["crash_threshold"]) * 1000:
		return false
	_start_crash(u)
	return true


func _start_crash(u: Unit) -> void:
	var cfg := Level.heli()
	u.tags["crashing"] = true
	u.tags.erase("diving")
	u.tags.erase("dive_ready")
	_dive_clear(u)
	_log("  💥 %s 力量低于 %d —— 坠机！" % [u.name, int(cfg["crash_threshold"])])
	var from_h: float = u.visual.position.y if u.visual != null else u.hover
	var tw := create_tween()
	tw.tween_property(u.visual, "position:y", 0.0, 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(func() -> void: _crash_impact(u))


func _crash_impact(u: Unit) -> void:
	var cfg := Level.heli()
	var center := Vector2(float(u.cell.x) + 0.5, float(u.cell.y) + 0.5)
	_flash_sphere(Vector3(center.x, 0.6, center.y), 2.0, 0.45)
	var opts := Combat.opts({
		"power": int(cfg["crash_power"]) * 1000,
		"armor_break": int(cfg["crash_break"]) * 1000,
		"ignore_res": float(cfg["crash_res"]),
		"rng": rng,
	})
	_log("  💥 %s 坠机落地 (%.1f, %.1f)：半径 %.1f 格内所有角色吃 %d 力 + %d 破甲（无视 50%% 物抗）" % [
		u.name, center.x, center.y, float(cfg["crash_r"]),
		int(cfg["crash_power"]), int(cfg["crash_break"])])
	var hits: Array = Damage.blast(u, center, float(cfg["crash_r"]), opts, units, placeables,
		null, u.side, true)
	for h in hits:
		if h.unit != null:
			_log(h.text)
			_after_damage_to_unit(h.unit)
	u.power_cur = 0
	if u.visual != null:
		u.visual.position.y = 0.0
	_on_unit_died(u)


## ── 俯冲轰炸（主动技能）：准备 -> 俯冲 -> 停 0.5 秒投弹 -> 原路返回 ──────────
var _dive_markers: Dictionary = {}        # 单位名 -> 目标格地面标识（Node3D）
var _dive: Dictionary = {}                # 正在俯冲的状态机


func _dive_marker(cell: Vector2i, on: bool) -> void:
	var key := "shared"
	if on:
		if _dive_markers.has(key) and is_instance_valid(_dive_markers[key]):
			(_dive_markers[key] as Node3D).queue_free()
		var root := Node3D.new()
		root.position = Vector3(float(cell.x) + 0.5, 0.0, float(cell.y) + 0.5)
		var disc := MeshInstance3D.new()
		var cy := CylinderMesh.new()
		cy.top_radius = 0.42
		cy.bottom_radius = 0.42
		cy.height = 0.04
		disc.mesh = cy
		disc.position = Vector3(0, 0.05, 0)
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(1.0, 0.62, 0.15, 0.55)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.emission_enabled = true
		m.emission = Color(1.0, 0.55, 0.1)
		m.emission_energy_multiplier = 1.4
		disc.material_override = m
		root.add_child(disc)
		add_child(root)
		_dive_markers[key] = root
		_log("  🎯 已标记俯冲目标 (%d, %d)（橙色圆盘）—— 下一次轮到它会俯冲过去" % [cell.x, cell.y])
	elif _dive_markers.has(key):
		if is_instance_valid(_dive_markers[key]):
			(_dive_markers[key] as Node3D).queue_free()
		_dive_markers.erase(key)


func _dive_clear(u: Unit) -> void:
	if u.tags.has("dive_ready"):
		u.tags.erase("dive_ready")
	_dive_marker(Vector2i.ZERO, false)


## 玩家/AI 选定目标格 -> 进入准备状态
func _cast_dive(u: Unit, cell: Vector2i) -> void:
	var d := Skills.get_def("dive_bomb")
	if u.energy_points() < int(d["cost"]):
		_log("%s 精力不足，无法使用【%s】" % [u.name, d["name"]])
		return
	u.spend_energy(int(d["cost"]))
	u.tags["dive_ready"] = cell
	_push_unit_stats(u)
	_dive_marker(cell, true)
	_log("  🚁 %s 进入【俯冲准备】：目标 (%d, %d)，距离 %d 格" % [
		u.name, cell.x, cell.y, Ai.manhattan(u.cell, cell)])


## 轮到它的回合：开始俯冲（返回 true 表示本回合由俯冲接管）
func _dive_begin(u: Unit) -> bool:
	if not u.tags.has("dive_ready"):
		return false
	var cfg := Level.heli()
	var target: Vector2i = u.tags["dive_ready"]
	_dive_clear(u)
	u.tags["diving"] = true
	_dive = {
		"u": u, "phase": "out",
		"from": Vector2(float(u.cell.x) + 0.5, float(u.cell.y) + 0.5),
		"to": Vector2(float(target.x) + 0.5, float(target.y) + 0.5),
		"t": 0.0, "speed": float(cfg["dive_speed"]), "hold": 0.0,
	}
	if u.visual != null:
		u.visual.position.y = u.hover
	_log("  🚁 %s 开始俯冲 -> (%d, %d)" % [u.name, target.x, target.y])
	return true


func _dive_tick(delta: float) -> void:
	if _dive.is_empty():
		return
	var u: Unit = _dive["u"]
	if u == null or not u.is_alive() or not u.tags.has("diving"):
		_dive = {}
		return
	var cfg := Level.heli()
	var phase := String(_dive["phase"])
	var from: Vector2 = _dive["from"]
	var to: Vector2 = _dive["to"]
	var speed: float = float(_dive["speed"])
	var total := maxf(0.5, from.distance_to(to))
	if phase == "out":
		_dive["t"] = minf(1.0, float(_dive["t"]) + speed * delta / total)
		var k: float = float(_dive["t"])
		var pos := from.lerp(to, k)
		_place_diving(u, pos, lerpf(u.hover, float(cfg["dive_h"]), k))
		if k >= 1.0:
			_dive["phase"] = "hold"
			_dive["hold"] = float(cfg["drop_hold"])
			_log("  🚁 %s 抵达目标上方，停 %.2f 秒投弹" % [u.name, float(cfg["drop_hold"])])
	elif phase == "hold":
		_dive["hold"] = float(_dive["hold"]) - delta
		if float(_dive["hold"]) <= 0.0:
			_dive["phase"] = "back"
			_dive["t"] = 1.0
			_drop_bomb(u, to)
	elif phase == "back":
		_dive["t"] = maxf(0.0, float(_dive["t"]) - speed * delta / total)
		var k2: float = float(_dive["t"])
		var pos2 := from.lerp(to, k2)
		_place_diving(u, pos2, lerpf(u.hover, float(cfg["dive_h"]), k2))
		if k2 <= 0.0:
			u.tags.erase("diving")
			_dive = {}
			if u.visual != null:
				u.visual.position.y = u.hover
			_log("  🚁 %s 返航完成" % u.name)
			_finish_turn()


## 俯冲中的位置同步（格坐标 + 高度）
func _place_diving(u: Unit, pos: Vector2, h: float) -> void:
	u.cell = Vector2i(int(floor(pos.x)), int(floor(pos.y)))
	if u.visual != null:
		u.visual.position = Vector3(pos.x, h, pos.y)
	_check_heli_crash(u)          # 用户口径：俯冲期间会受伤、也会触发被动


## 投弹：投掷手普攻模型直径翻倍、半径 3 格、40 破甲 + 20 力量、不触发哨兵、下落速度同轨道空爆
func _drop_bomb(u: Unit, at: Vector2) -> void:
	var cfg := Level.heli()
	_flash_sphere(Vector3(at.x, 0.8, at.y), 1.2, 0.3)
	var opts := Combat.opts({
		"power": int(cfg["drop_power"]) * 1000,
		"armor_break": int(cfg["drop_break"]) * 1000,
		"ignore_res": 0.0,
		"rng": rng,
	})
	_log("  💣 %s 投弹 (%.1f, %.1f)：半径 %.1f 格，%d 破甲 + %d 力量（不触发哨兵）" % [
		u.name, at.x, at.y, float(cfg["drop_blast_r"]), int(cfg["drop_break"]), int(cfg["drop_power"])])
	var hits: Array = Damage.blast(u, at, float(cfg["drop_blast_r"]), opts, units, placeables,
		null, u.side, true)
	_show_impact(at)
	for h in hits:
		if h.unit != null:
			_log(h.text)
			_after_damage_to_unit(h.unit)


func _after_damage_to_unit(u: Unit) -> void:
	_flash(u)
	if u.visual != null:
		u.visual.update_orb()
	if not u.is_alive():
		_on_unit_died(u)


## 道具挨打后的统一收尾

func _after_damage_to_placeable(pl: Placeable) -> void:
	if pl.visual != null:
		(pl.visual as PlaceableView).update_orb()
	if not pl.is_alive():
		_log("  🧱 %s 被摧毁" % pl.name)
		if pl.visual != null:
			(pl.visual as PlaceableView).play_destroy()


## 落点 BLAST_RADIUS 内是否有沙盒道具（决定要不要走"空爆"提前返回）

func _any_placeable_in_blast(center: Vector2i) -> bool:
	var ctr := Vector2(float(center.x) + 0.5, float(center.y) + 0.5)
	for pl in placeables:
		if not pl.is_alive():
			continue
		if ctr.distance_to(Vector2(float(pl.cell.x) + 0.5, float(pl.cell.y) + 0.5)) <= BLAST_RADIUS:
			return true
	return false


## 单位阵亡统一入口：假人会自动满血复活（用户要求，方便长期测试）
## 关键：**同一单位的复活计时器只能有一个**。以前每挨一发就新建一个计时器，
## 它们各自在不同时刻把 visible 改来改去，多死几次后就会卡在"看不见"。

func _on_unit_died(u: Unit) -> void:
	if u.visual == null:
		return
	var dummy := u.name.begins_with("Dummy")
	# 同一个单位重复播报没有意义（地毯式轰炸会一次性打死好几次）
	if dummy and uid_dead.has(u):
		return
	if dummy:
		uid_dead[u] = true
		_log("  ☠ %s 阵亡" % u.name)
		_log("    假人不死：%s 秒后满血复活" % UnitData.DUMMY_REVIVE_SEC)
		u.visual.visible = false
		if _revive_timers.has(u) and _revive_timers[u] != null:
			var old: SceneTreeTimer = _revive_timers[u]
			if old.timeout.is_connected(_on_revive_timeout.bind(u)):
				old.timeout.disconnect(_on_revive_timeout.bind(u))
		var tm := get_tree().create_timer(UnitData.DUMMY_REVIVE_SEC)
		_revive_timers[u] = tm
		tm.timeout.connect(_on_revive_timeout.bind(u))
	else:
		_log("  ☠ %s 阵亡" % u.name)
		u.visual.visible = false
		# 用户口径：**阵亡清除一切 buff 与状态**（哨兵警戒不保留、蓄势清零、挂起的技能作废）
		gm.note_death(u)          # 阵亡顺序（圣萨尼要用）
		_clear_unit_states(u)
		# 英雄（三家将）：用户口径 —— 无限满血满护甲重生，每次等 10 个回合
		if not u.is_king and not Passives.has(u, "always_sentry"):
			var rt: int = Level.respawn_turns(u.name)
			gm.schedule_hero_revive(u, rt)
			_log("    %s 将在 %d 个回合后满血复活（位置 %s）" % [u.name, rt, u.home_cell])


## 阵亡：清空这个角色的一切状态与 buff（用户口径）
##   · 哨兵警戒（含 GM 队列里属于他的条目）
##   · 蓄势层数、被动机会记录
##   · 挂起未结算的技能（轨道空爆标记）
func _clear_unit_states(u: Unit) -> void:
	if u == null:
		return
	var had_sentry := gm.has_sentry(u)
	gm.clear_sentry_for(u)
	gm.forget_passives(u)
	gm.cancel_pending_for(u.name)
	Passives.clear_focus(u)
	u.tags.clear()
	_log("    %s 阵亡：所有状态已清除（哨兵=%s）" % [u.name, "有" if had_sentry else "无"])


## 英雄重生：满血满护甲 + 回到关卡给的固定格（两个公主之间那三格）
func _revive_hero(u: Unit) -> void:
	if u == null:
		return
	if u.visual != null:
		u.visual.visible = true
	uid_dead.erase(u)
	u.power_cur = u.power_max
	u.armor_cur = u.armor_max
	u.energy = u.energy_max
	u.has_moved = false
	u.has_acted = false
	# 回家：优先回【关卡的英雄重生点】（河旁边居中那三格），被占了再顺着往后找
	var hs: Array = Level.respawn_cells(u.side)
	if hs.is_empty():
		hs = Level.hero_cells(u.side)
	var target: Vector2i = u.home_cell
	var free_found := true
	for c in [target] + hs:
		var cc: Vector2i = c
		var taken := false
		for o in units:
			if o != u and o.is_alive() and o.cell == cc:
				taken = true
		if not taken:
			target = cc
			free_found = true
			break
		free_found = false
	if not free_found:
		target = u.home_cell
	u.cell = target
	if u.visual != null:
		u.visual.position = Vector3(float(target.x) + 0.5, u.hover, float(target.y) + 0.5)
		u.visual.update_orb()
	_log("    %s 复活：状态已清空（阵亡时清掉的哨兵警戒等不会带回来）" % u.name)
	_log("  ♻ %s 复活（力%s 甲%s 精力%s）→ 回到 %s" % [
		u.name, _fmt(u.power_cur), _fmt(u.armor_cur), u.energy_points(), target])

func _on_revive_timeout(u: Unit) -> void:
	if u == null or u.visual == null:
		return
	_revive_timers.erase(u)
	uid_dead.erase(u)
	u.power_cur = u.power_max
	u.armor_cur = u.armor_max
	u.energy = u.energy_max
	u.visual.visible = true
	u.visual.update_orb()
	_log("  ♻ %s 已满血复活（力%s 甲%s）" % [
		u.name, _fmt(u.power_cur), _fmt(u.armor_cur)])


## 兜底不变式：**活着就必须看得见**。
## 复活/连死/被击落等各种路径都可能把 visible 弄错，这里每帧纠一次，成本极低。
## 当前行动者如果在自己的回合里被打死（例如被哨兵箭射死），必须立刻结束它的回合，
## 否则回合会卡在一个死人身上，永远轮不到下一位。

func _check_active_alive() -> void:
	if active == null or active.is_alive():
		return
	_log("  %s 在自己的回合中阵亡 —— 立刻结束该回合" % active.name)
	_finish_turn()

func _sync_unit_visibility() -> void:
	for u in units:
		if u.visual == null:
			continue
		if u.is_alive() and not u.visual.visible:
			u.visual.visible = true


## 落地后的 red circle：标出 impact 范围（浮点落点，用户口径）

func _show_impact(center: Vector2, y: float = 0.05) -> void:
	_impact_ring.position = Vector3(center.x, y, center.y)
	_impact_ring.visible = true
	var im := _impact_ring.material_override as StandardMaterial3D
	im.albedo_color = Color(1.0, 0.22, 0.20, 0.45)
	# 关键：先把上一次没跑完的淡出动画杀掉，否则它会在这一帧把红圈又藏起来
	if _impact_tw != null and _impact_tw.is_valid():
		_impact_tw.kill()
	var t := create_tween()
	_impact_tw = t
	t.tween_property(im, "albedo_color:a", 0.0, 1.2)
	t.tween_callback(func() -> void: _impact_ring.visible = false)


# ══════════════════════════════════════════════════════════════════════════════
# 目标选择（近战 / 远程）
# ══════════════════════════════════════════════════════════════════════════════
## 萨尼铁塔：三连发。间隔 100ms 依次出膛，**每发各自判定命中**，
## 落点吃"玩家侧线性散布"（r = 距离/12，12 格 ≈ 1 格）——所以选中目标也不一定打中。
func _volley_bullets(u: Unit, t: Unit, break_armor: bool) -> void:
	u.has_acted = true
	u.has_moved = true
	_push_unit_stats(u)
	var from := Vector3(float(u.cell.x) + 0.5, 0.75, float(u.cell.y) + 0.5)
	var dist := Vector2(float(u.cell.x) + 0.5, float(u.cell.y) + 0.5).distance_to(
		Vector2(float(t.cell.x) + 0.5, float(t.cell.y) + 0.5))
	for i in VOLLEY_COUNT:
		var aim := Spread.linear_scatter(
			Vector2(float(t.cell.x) + 0.5, float(t.cell.y) + 0.5), dist, rng)
		var last := i == VOLLEY_COUNT - 1
		var p := Ordnance.make_bullet(u, from, aim, last)
		p.shot.target = t
		p.shot.break_armor = break_armor
		field.register(p)
		_log("  • %s 第 %d/%d 发子弹：目标 %s（%.1f 格，散布半径 %.2f）→ 瞄准 (%.2f, %.2f）" % [
			u.name, i + 1, VOLLEY_COUNT, t.name, dist, Spread.linear_radius(dist), aim.x, aim.y])
		if not last:
			await get_tree().create_timer(VOLLEY_GAP).timeout


## 结算一次普通攻击。近战立即生效；远程先飞一支箭，命中后才结算。
## 硬性守卫：本回合已经出手过就不再响应（防止 UI 或外部脚本重复调用导致"一回合打两次"）。

func _attack_target_unit(t: Unit, break_armor: bool) -> void:
	if active == null or t == null or not t.is_alive():
		return
	if active.has_acted:
		return
	active.has_acted = true
	active.has_moved = true
	_push_unit_stats(active)          # 同步精力条与属性栏

	if Unit.base_name(active.name) == SANI_NAME:
		_volley_bullets(active, t, break_armor)          # 三连发（各自散布、各自判定）
		return
	if active.role == UnitData.Role.RANGED:
		var from := Vector3(float(active.cell.x) + 0.5, 0.75, float(active.cell.y) + 0.5)
		var to := Vector3(float(t.cell.x) + 0.5, 0.55, float(t.cell.y) + 0.5)
		_spawn_arrow(active, from, to, t, break_armor, true)
	else:
		_apply_attack(active, t, break_armor, false)


## 锁定沙盒元素（用户口径：双方近战/远程英雄都能打木刺/土堆）
func _attack_target_placeable(pl: Placeable) -> void:
	if active == null or pl == null or not pl.is_alive():
		return
	if active.has_acted:
		return
	active.has_acted = true
	active.has_moved = true
	_push_unit_stats(active)
	_log("%s 锁定沙盒：%s" % [active.name, pl.name])
	if active.role == UnitData.Role.RANGED:
		var from := Vector3(float(active.cell.x) + 0.5, 0.75, float(active.cell.y) + 0.5)
		var to := Vector3(float(pl.cell.x) + 0.5, 0.55, float(pl.cell.y) + 0.5)
		var p := _spawn_arrow(active, from, to, null, false, true)
		if p != null and p.shot != null:
			p.shot.target_placeable = pl            # 明确锁定：箭一定打得中它
	else:
		_damage_placeable(active, pl, false)

func _apply_attack(attacker: Unit, t: Unit, break_armor: bool,
		silent: bool = false, bonus_milli: int = 0, power_mult: float = 1.0,
		power_override: int = -1, break_override: int = -1) -> void:
	var h: Damage.Hit = Damage.strike(attacker, t, break_armor, rng, bonus_milli, power_mult,
		power_override, break_override)
	if h == null:
		return
	_log(h.text)
	_after_damage_to_unit(t)
	if not silent:
		_finish_turn()


## 箭矢"身体"判定半径等常量见 Targeting / Ordnance

func _placeable_near(pos: Vector3) -> Placeable:
	var c := Vector2i(int(floor(pos.x)), int(floor(pos.z)))
	for p in placeables:
		if p.is_alive() and p.covers(c):
			return p
	return null


## 对沙盒道具结算一次普通伤害（力量线），实际计算在 Damage 里

func _damage_placeable(attacker: Unit, p: Placeable, silent: bool = false) -> void:
	var h: Damage.Hit = Damage.prop_strike(attacker, p, rng)
	if h == null:
		return
	_log(h.text)
	if h.died:
		_log("  🧱 %s 被摧毁" % p.name)
	_after_damage_to_placeable(p)
	if not silent:
		_finish_turn()          # 撞到道具也算用掉了这次行动（哨兵箭 silent）


# ══════════════════════════════════════════════════════════════════════════════
# 输入
# ══════════════════════════════════════════════════════════════════════════════

func _process(delta: float) -> void:
	_dive_tick(delta)
	_tick_heli_fx(delta)


## 直升机的每帧表现（悬浮高度 / 旋翼自转 / 俯冲姿态）—— 队友交付的 HeliFx
## 只对直升机调用，其它单位零开销（HeliFx.tick 内部第一行就返回）
func _tick_heli_fx(delta: float) -> void:
	for u in units:
		if u == null or u.visual == null:
			continue
		if Unit.base_name(u.name).begins_with(HELI_PREFIX):
			HeliFx.tick(u.visual, u, delta)
	_tick_color_cycle(delta)
	_tick_pending_pulse(delta)
	_sync_menu_position()          # 菜单跟着角色走
	_tick_queue_anim(delta)
	field.step(delta)              # 弹道物理：推进 / 碰撞 / 上报结果（顺带把进入射界的送进哨兵队列）
	if _qte_active:
		return                     # 弹反 QTE 进行中：这一帧剩下的都别做（时间已暂停）
	_tick_sentry_queue(delta)      # 哨兵：每 150ms 放一支箭打队头
	_tick_unit_walk(delta)         # 走路中的哨兵检测
	sentry_range.sync(gm.sentries) # 射界高亮跟着哨兵状态走
	_sync_unit_visibility()        # 兜底：活着就必须看得见
	_check_active_alive()         # 当前行动者在自己回合里被打死 -> 立刻结束其回合
	_camera_process(delta)


## 队列条动画计时：到点就收尾；期间攒下的刷新请求在这里补做（最小间隔 0.5 秒）

func _unhandled_input(event: InputEvent) -> void:
	# GameMaster 演出期间（例如轨道炮击）：只允许相机操作，角色一律不可操作
	if _gm_busy:
		var cam_only := false
		if event is InputEventMouseButton and event.pressed \
				and (event.button_index == MOUSE_BUTTON_WHEEL_UP
					or event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			cam_only = true
		elif event is InputEventKey and event.pressed and not event.echo \
				and event.keycode == KEY_R:
			cam_only = true
		if not cam_only:
			return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_R: get_tree().reload_current_scene(); return
			KEY_ESCAPE:
				if _aim_active:
					_aim_active = false
					_arrow_root.visible = false
					phase = Phase.MENU
					_show_action_menu()
				elif phase == Phase.CHOOSE_TARGET:
					if _attack_menu.visible:
						_attack_menu.visible = false
					_clear_pending()
					_show_action_menu()
				return
			KEY_Q:
				if phase == Phase.MENU: _menu_attack()
				return
			KEY_E:
				if phase == Phase.MENU: _menu_rest()
				return
		return

	# ── 鼠标滚轮缩放 ──
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom = clampf(_zoom - 1.5, 6.0, 30.0)
			if _zoom_slider != null:
				_zoom_slider.set_value_no_signal(_zoom)
			_update_camera()
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom = clampf(_zoom + 1.5, 6.0, 30.0)
			if _zoom_slider != null:
				_zoom_slider.set_value_no_signal(_zoom)
			_update_camera()
			return
		# ── 右键：退出当前选项，回到二级菜单 ──
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_cancel_to_menu()
			return

	# ── 瞄准中的鼠标 ──
	if _aim_active:
		if event is InputEventMouseMotion:
			_update_aim(event.position)
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			_fire()
		return

	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var cell = _pick_cell(event.position)
		if cell == null:
			# 点到棋盘外也算"点空白"：收起所有菜单与选中（放置阶段除外）
			if phase != Phase.PLACE:
				_on_blank_click()
			return
		var t := _unit_at(cell)

		# ── 放置阶段：点地面放下选中的道具 ──
		if phase == Phase.PLACE:
			if _place_kind == "":
				pass
				return
			if _same_pending("place", cell):
				_place_at(cell)
				_clear_pending()
			else:
				_set_pending("place", cell)
			_refresh_all()
			return

		if phase == Phase.CHOOSE_TARGET:
			# 用户口径：远程和近战【选单位都要确认】—— 第一次点只出黄勾，第二次才弹攻击菜单
			# 沙盒元素（木刺/土堆）也可以被锁定，流程一样：第一次出勾，第二次打
			var pl_t: Placeable = _placeable_at(cell) if t == null else null
			if pl_t != null and attackable.has(cell):
				if _same_pending("place", cell):
					_clear_pending()
					_attack_target_placeable(pl_t)
				else:
					_set_pending("place", cell, null)
					_refresh_all()
				return
			if t != null and t.side != active.side and attackable.has(cell):
				if _same_pending("attack", cell):
					_clear_pending()
					_show_attack_menu(t)
				else:
					_set_pending("attack", cell, t)
					_refresh_all()
			else:
				# 点到空白 / 自己人 / 打不到的格子：收起攻击菜单与紫色范围，回到未选择
				_on_blank_click()
			return

		# ── 移动待确认：同一格再点一次才真的走 ──
		if phase == Phase.MOVE_CONFIRM:
			if _same_pending("move", cell) and reachable.has(cell):
				_clear_pending()
				_do_move(active, cell)
			elif reachable.has(cell):
				_set_pending("move", cell, active)
			else:
				_clear_pending()
				_cancel_to_menu()
			_refresh_all()
			return

		# IDLE：点自己人（若轮到它）弹出菜单
		if t != null and t.is_manual():
			if t == active and t.is_alive():
				_select_for_detail(t)
				_show_action_menu()
			else:
				_select_for_detail(t)
			return
		# 点空格：MENU 阶段（还没三选一）且已选"移动" -> 进入移动确认
		if active != null and active.is_manual() and phase == Phase.MENU \
				and not active.has_acted and reachable.has(cell):
			_set_pending("move", cell, active)
			phase = Phase.MOVE_CONFIRM
			_refresh_all()
			return
		var pl := _placeable_at(cell)
		if pl != null:
			# 点沙盒道具 -> 显示它的描述与数据
			_clear_selection()
			_show_placeable_info(pl)
			return
		if t == null:
			# 点空白 -> 不选任何人：收起详情栏与二级菜单，只留队列
			_clear_selection()
			return
		if t != null:
			_select_for_detail(t)


## 右键：退出当前选项（选目标 / 瞄准 / 攻击菜单），把二级菜单重新显示出来

func _cancel_to_menu() -> void:
	if _aim_active:
		_aim_active = false
		_arrow_root.visible = false
		_aim_skill_id = ""
		_skill_info_text = ""
		_aim_kind = "throw"
		_show_action_menu()
		return
	if _skill_menu != null and _skill_menu.visible:
		_skill_menu.visible = false
		_show_action_menu()
		return
	if _attack_menu.visible:
		_attack_menu.visible = false
		_show_action_menu()
		return
	if phase == Phase.CHOOSE_TARGET:
		_clear_pending()
		_show_action_menu()
		return
	if phase == Phase.MENU and _action_menu.visible:
		# 已经在菜单里：右键只关菜单，人物仍保持选中（想取消选择就点空白处）
		_action_menu.visible = false
		return


## 点空白处（含棋盘外）：收起一切二级菜单、待确认标记与选中状态。
## 用户反馈"点空白处无法正确隐藏二级菜单"——所以所有空白分支都收敛到这一个入口。

func _on_blank_click() -> void:
	_placeable_info_text = ""
	_clear_pending()
	_clear_selection()


## 取消选择：不显示详情栏、不显示任何二级菜单，只保留底部队列

func _clear_selection() -> void:
	selected = null
	_action_menu.visible = false
	if _skill_menu != null:
		_skill_menu.visible = false
	_attack_menu.visible = false
	_attack_target = null
	if phase == Phase.CHOOSE_TARGET:
		phase = Phase.IDLE
	for u in units:
		if u.visual != null:
			u.visual.set_selected(false)
	if active != null and active.visual != null:
		active.visual.set_active(true)
	_refresh_all()

func _do_move(u: Unit, cell: Vector2i) -> void:
	# 走路动画：沿路径逐格"抬腿 + 小跳"，同时朝向转到行进方向（不是瞬移）
	var path: Array[Vector2i] = _path_to(u, cell)
	gm.on_move_begin(u)                     # 哨兵：这次移动的"已触发"闩清零
	if u.visual != null and path.size() > 1:
		u.visual.walk_path(path)
	u.cell = cell
	u.has_moved = true
	if u.visual == null or path.size() <= 1:
		# 没有走路动画（无头测试 / 原地）：直接按终点判定哨兵
		_sentry_lock(u, Vector2(float(cell.x) + 0.5, float(cell.y) + 0.5))
	reachable = _compute_reachable(u)      # 已移动 -> 空集合，不能再动
	# 移动后重开菜单：此时"休息"会被禁用（移动过不能休息）
	_show_action_menu()
	_place_menu_near(u)
	_draw_hints()
	_refresh_all()


## 走路中的哨兵检测：角色的逻辑格子是瞬移的，所以用视觉位置当作真实浮点位置。
## 用户口径："从射界外进入射界内，或者已经在射界内然后移动"都要触发。

func _tick_unit_walk(_delta: float) -> void:
	if gm.sentries.is_empty():
		return
	for u in units:
		if not u.is_alive() or u.visual == null:
			continue
		var vis := u.visual as UnitVisual
		if vis == null or not vis.is_walking():
			continue
		_sentry_lock(u, Vector2(vis.position.x, vis.position.z))


## 角色进入射界 -> 入队尾（真的射箭由 150ms 节奏的队列决定，不再"立刻一发"）
func _sentry_lock(u: Unit, pos: Vector2) -> void:
	if gm.check_unit(u, pos):
		_log("  🎯 哨兵锁定：%s 进入射界（队列 %d）" % [u.name, gm.sentry_queue_size()])


## BFS 求一条从当前格到目标格的路径（4 邻格，避开其他单位与阻挡移动的道具）

func _path_to(u: Unit, goal: Vector2i) -> Array[Vector2i]:
	var occupied := _blocked_cells()          # 沙盒道具：阻挡移动的占格
	for o in units:
		if o.is_alive() and o != u:
			occupied[o.cell] = true
	var start: Vector2i = u.cell
	if start == goal:
		return [start]
	var prev := {start: start}
	var frontier: Array[Vector2i] = [start]
	var found := false
	while not frontier.is_empty() and not found:
		var nxt: Array[Vector2i] = []
		for c in frontier:
			for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = c + off
				if n.x < 0 or n.y < 0 or n.x >= GW or n.y >= GH:
					continue
				if prev.has(n) or occupied.has(n):
					continue
				prev[n] = c
				if n == goal:
					found = true
					break
				nxt.append(n)
			if found:
				break
		frontier = nxt
	if not found:
		return [start, goal]          # 兜底：直接走直线
	var out: Array[Vector2i] = []
	var cur: Vector2i = goal
	while cur != start:
		out.push_front(cur)
		cur = prev[cur]
	out.push_front(start)
	return out

func _select_for_detail(u: Unit) -> void:
	_placeable_info_text = ""
	selected = u
	for x in units:
		if x.visual != null:
			x.visual.set_selected(x == u and x == active)
	if _panel != null:
		_panel.visible = (u != null)
	_refresh_all()

func _pick_cell(mouse: Vector2) -> Variant:
	var from := _camera.project_ray_origin(mouse)
	var dir := _camera.project_ray_normal(mouse)
	if absf(dir.y) < 0.0001:
		return null
	var t := -from.y / dir.y
	if t < 0.0:
		return null
	var p := from + dir * t
	var cell := Vector2i(int(floor(p.x)), int(floor(p.z)))
	if cell.x < 0 or cell.y < 0 or cell.x >= GW or cell.y >= GH:
		return null
	return cell

func _unit_at(cell: Vector2i) -> Unit:
	for u in units:
		if u.is_alive() and u.cell == cell:
			return u
	return null

func _compute_reachable(u: Unit) -> Dictionary:
	var res := {}
	if u.has_moved or not u.is_alive():
		return res
	var occupied := _blocked_cells()          # 沙盒道具：阻挡移动的占格
	for o in units:
		if o.is_alive():
			occupied[o.cell] = true
	var frontier: Array[Vector2i] = [u.cell]
	var dist := {u.cell: 0}
	while not frontier.is_empty():
		var nxt: Array[Vector2i] = []
		for c in frontier:
			var d: int = dist[c]
			if d >= u.move:
				continue
			for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = c + off
				if n.x < 0 or n.y < 0 or n.x >= GW or n.y >= GH:
					continue
				if occupied.has(n) or dist.has(n):
					continue
				dist[n] = d + 1
				res[n] = true
				nxt.append(n)
		frontier = nxt
	return res


# ══════════════════════════════════════════════════════════════════════════════
# 高亮
# ══════════════════════════════════════════════════════════════════════════════

func _clear_hints() -> void:
	if _hint_layer == null:
		return
	for c in _hint_layer.get_children():
		c.queue_free()
	# 高亮重建后，旧的 PendingMark 引用就失效了，必须一起清掉
	# （否则下一帧 _tick_color_cycle 会去改已释放节点的材质）
	_pending_marks.clear()


## 待确认高亮的一个格子：填充 + 更显眼的描边（都用流动彩色）

func _pending_cell_mark(cell: Vector2i, phase: float) -> void:
	var mk := PendingMark.new()
	mk.phase = phase
	var cx := float(cell.x) + 0.5
	var cz := float(cell.y) + 0.5

	# ① 填充（半透明，别挡住底下的东西）
	var fm := MeshInstance3D.new()
	var fq := BoxMesh.new()
	fq.size = Vector3(0.84, 0.02, 0.84)
	fm.mesh = fq
	fm.position = Vector3(cx, 0.03, cz)
	fm.material_override = _cycle_mat()
	_hint_layer.add_child(fm)
	mk.fill = fm

	# ② 边缘：四条亮线（用 ImmediateMesh 画线框，比一块板子更像"描边"）
	var em := MeshInstance3D.new()
	var emesh := ImmediateMesh.new()
	emesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var y := 0.07
	var h := 0.45
	var pts := [
		Vector3(cx - h, y, cz - h), Vector3(cx + h, y, cz - h),
		Vector3(cx + h, y, cz - h), Vector3(cx + h, y, cz + h),
		Vector3(cx + h, y, cz + h), Vector3(cx - h, y, cz + h),
		Vector3(cx - h, y, cz + h), Vector3(cx - h, y, cz - h),
	]
	for i in range(0, pts.size(), 2):
		emesh.surface_add_vertex(pts[i])
		emesh.surface_add_vertex(pts[i + 1])
	emesh.surface_end()
	em.mesh = emesh
	em.material_override = _cycle_mat()
	_hint_layer.add_child(em)
	mk.edge = em
	_pending_marks.append(mk)

func _cycle_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(1, 1, 1, 0.5)
	return m


## 每帧推进所有"待确认"高亮的颜色：hue 随时间匀速增长 -> 连续渐变

func _tick_color_cycle(delta: float) -> void:
	_cycle_time += delta
	for mk in _pending_marks:
		(mk.fill.material_override as StandardMaterial3D).albedo_color = \
			ColorCycle.fill_at(_cycle_time, mk.phase, 0.40)
		(mk.edge.material_override as StandardMaterial3D).albedo_color = \
			ColorCycle.edge_at(_cycle_time, mk.phase, 1.0)
	# 被操作的角色（正在移动的人 / 待确认攻击的目标）：脚下环同步变色
	if _pending_actor_on and _pending_actor != null and _pending_actor.visual != null:
		var v := _pending_actor.visual as UnitVisual
		v.set_cycle_ring(ColorCycle.edge_at(_cycle_time, 0.0, 0.95))


## 设定"待确认"时要染色的角色（可为 null 取消）

func _set_pending_actor(u: Unit) -> void:
	if _pending_actor != null and _pending_actor.visual != null \
			and _pending_actor != u:
		(_pending_actor.visual as UnitVisual).set_cycle_ring(null)
	_pending_actor = u
	_pending_actor_on = u != null
	if u != null and u.visual != null:
		(u.visual as UnitVisual).set_cycle_ring(ColorCycle.edge_at(_cycle_time, 0.0, 0.95))

func _draw_hints() -> void:
	_clear_hints()
	# 放置阶段：鼠标悬停格显示绿色/红色占位框
	if phase == Phase.PLACE and _place_kind != "":
		var hc: Variant = _hover_cell()
		if hc != null:
			var hcv: Vector2i = hc
			_hint_cell(hcv, Color(0.30, 1.00, 0.45, 0.42) if _can_place_at(hcv)
				else Color(1.00, 0.25, 0.25, 0.42))
	# 可移动格：只有在"有单位被选定"且处于菜单阶段才显示（蜘蛛绿）
	if (phase == Phase.MENU or phase == Phase.MOVE_CONFIRM) \
			and selected != null and selected == active:
		for cell in reachable.keys():
			_hint_cell(cell, Color(0.22, 0.62, 0.20, 0.34))
	# 可攻击范围（紫色）
	for cell in attackable.keys():
		_hint_cell(cell, Color(0.62, 0.28, 0.92, 0.38))
	# ── 待确认：用"常驻的一根脉冲灯柱 + 橙色描边格"表示 ──
	# 之前的彩色流动方案依赖每帧重建 mesh，实测看不见；改成常驻节点 + 直接改材质色。
	_update_pending_visual()


## 待确认可视化：一个常驻的橙色方框 + 一根上下脉动的光柱。
## 只创建一次，之后每帧只改颜色/缩放，避免"重建导致看不见"。

func _update_pending_visual() -> void:
	var on: bool = _pending_kind != "" and _pending_cell.x >= 0
	if _pending_root == null:
		_pending_root = Node3D.new()
		_pending_root.name = "PendingMark"
		add_child(_pending_root)
		# 方框：四根细柱围成一圈
		_pending_mats.clear()
		for seg in [
			[Vector3(-0.45, 0, -0.45), Vector3(0.45, 0, -0.45)],
			[Vector3(0.45, 0, -0.45), Vector3(0.45, 0, 0.45)],
			[Vector3(0.45, 0, 0.45), Vector3(-0.45, 0, 0.45)],
			[Vector3(-0.45, 0, 0.45), Vector3(-0.45, 0, -0.45)],
		]:
			var mi := MeshInstance3D.new()
			var bm := BoxMesh.new()
			var a: Vector3 = seg[0]
			var b: Vector3 = seg[1]
			bm.size = Vector3(0.10, 0.10, a.distance_to(b) + 0.10)
			mi.mesh = bm
			mi.position = (a + b) * 0.5 + Vector3(0, 0.07, 0)
			mi.rotation.y = atan2(b.x - a.x, b.z - a.z)
			var m := StandardMaterial3D.new()
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mi.material_override = m
			_pending_root.add_child(mi)
			_pending_mats.append(m)
		# 黄勾取代了旧的光柱：两根竖线叠在一起会看成"叉"，用户要的就是一个勾
		_build_check_mark()
	if not on or _pending_cell.x < 0:
		_pending_root.visible = false
		return
	_pending_root.visible = true
	_pending_root.position = Vector3(float(_pending_cell.x) + 0.5, 0.0, float(_pending_cell.y) + 0.5)


## 待确认的【黄勾】：两段笔画（短 + 长）组成的 ✓，外加一圈加法混合的柔光。
## 用户口径：发亮的黄勾、必须正对摄像机（不能斜）—— 每帧抄摄像机的 basis。
## 只画勾，不填充格子；格子本身的橙框仍然由 _pending_mats 负责。

func _build_check_mark() -> void:
	_check_root = Node3D.new()
	_check_root.name = "CheckMark"
	_pending_root.add_child(_check_root)
	_check_mats.clear()
	var strokes := [
		[Vector2(-0.22, 0.05), Vector2(-0.06, -0.13)],     # 短笔画
		[Vector2(-0.06, -0.13), Vector2(0.27, 0.25)],      # 长笔画
	]
	# wide = 柔光层（加法混合、更粗更淡）；否则是亮芯
	for wide in [true, false]:
		for st in strokes:
			var a: Vector2 = st[0]
			var b: Vector2 = st[1]
			var th: float = 0.17 if wide else 0.075
			var mi := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(a.distance_to(b) + th * 0.8, th, 0.05)
			mi.mesh = bm
			mi.position = Vector3((a.x + b.x) * 0.5, (a.y + b.y) * 0.5, 0.0)
			mi.rotation.z = atan2(b.y - a.y, b.x - a.x)
			var m := StandardMaterial3D.new()
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
			m.no_depth_test = true                    # 别被格子/单位挡掉
			if wide:
				m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
				m.albedo_color = Color(1.0, 0.82, 0.18, 0.28)
			else:
				m.albedo_color = Color(1.0, 0.92, 0.30, 1.0)
			mi.material_override = m
			_check_root.add_child(mi)
			_check_mats.append(m)


## 黄勾朝向：永远和屏幕平行（正对摄像机），并且轻轻呼吸
func _face_check_mark() -> void:
	if _check_root == null or _camera == null or _pending_root == null:
		return
	var k: float = 0.5 + 0.5 * sin(_pulse_t * 6.0)
	var t := _check_root.global_transform
	t.basis = _camera.global_transform.basis.scaled(Vector3.ONE * (1.35 + 0.14 * k))
	t.origin = _pending_root.global_position + Vector3(0.0, 1.05 + 0.07 * k, 0.0)
	_check_root.global_transform = t


## 每帧让待确认标记呼吸：格子橙框在橙<->黄之间脉动，黄勾同步呼吸并保持正对摄像机

func _tick_pending_pulse(delta: float) -> void:
	if _pending_root == null or not _pending_root.visible:
		return
	_pulse_t += delta
	var k: float = 0.5 + 0.5 * sin(_pulse_t * 6.0)
	var col := Color(1.0, 0.45 + 0.45 * k, 0.10, 0.85 + 0.15 * k)
	for m in _pending_mats:
		m.albedo_color = col
	for m in _check_mats:
		var mc: StandardMaterial3D = m
		if mc.blend_mode == BaseMaterial3D.BLEND_MODE_ADD:
			mc.albedo_color = Color(1.0, 0.82, 0.18, 0.20 + 0.18 * k)
		else:
			mc.albedo_color = Color(1.0, 0.88 + 0.10 * k, 0.24 + 0.18 * k, 1.0)
	_face_check_mark()


## 鼠标当前指向的格子（无有效指向返回 null）

func _hover_cell() -> Variant:
	var mp := get_viewport().get_mouse_position()
	var from := _camera.project_ray_origin(mp)
	var dir := _camera.project_ray_normal(mp)
	if absf(dir.y) < 0.0001:
		return null
	var t := -from.y / dir.y
	if t < 0.0:
		return null
	var p := from + dir * t
	var c := Vector2i(int(floor(p.x)), int(floor(p.z)))
	if c.x < 0 or c.y < 0 or c.x >= GW or c.y >= GH:
		return null
	return c

func _hint_cell(cell: Vector2i, col: Color) -> void:
	var mi := MeshInstance3D.new()
	var q := BoxMesh.new()
	q.size = Vector3(0.86, 0.02, 0.86)
	mi.mesh = q
	mi.position = Vector3(float(cell.x) + 0.5, 0.02, float(cell.y) + 0.5)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = col
	mi.material_override = m
	_hint_layer.add_child(mi)

func _flash(u: Unit) -> void:
	if u.visual == null:
		return
	# 白闪逻辑搬到 UnitVisual：基准色只记一次，否则连吃几发就永久变白
	(u.visual as UnitVisual).flash_hit()

static func _fmt(milli: int) -> String:
	if milli % 1000 == 0:
		return str(milli / 1000)
	return "%.1f" % (milli / 1000.0)


## 阵营显示名：敌方阵营里"玩家可控"的角色要标出来，否则玩家分不清谁能操作

func _log(line: String) -> void:
	if _status != null:
		_status.text = line
	# 同时记进 Debug 日志（环形缓冲，最多 DEBUG_LOG_MAX 条）
	var plain := _strip_bb(line)
	_debug_log.append(plain)
	if _debug_log.size() > DEBUG_LOG_MAX:
		_debug_log = _debug_log.slice(_debug_log.size() - DEBUG_LOG_MAX)


## 去掉 BBCode 标签，日志区显示纯文本

static func _strip_bb(s: String) -> String:
	var re := RegEx.new()
	re.compile("\\[/?[^\\]]+\\]")
	return re.sub(s, "", true)


# ══════════════════════════════════════════════════════════════════════════════
# UI
# ══════════════════════════════════════════════════════════════════════════════
## 右下角 >> 按钮：放置阶段结束放置；战斗中结束回合

func _on_next_pressed() -> void:
	if _gm_busy:
		return
	if phase == Phase.PLACE:
		_finish_placement()
	else:
		_finish_turn()

## 力量被改成 >0 的死者：复活并重新显示模型

func _revive_unit(u: Unit) -> void:
	if u.visual != null:
		u.visual.visible = true
		u.visual.update_orb()
	_log("[调试] %s 力量 >0，已复活（力%s 甲%s）" % [u.name, _fmt(u.power_cur), _fmt(u.armor_cur)])


# ══════════════════════════════════════════════════════════════════════════════
# UI 接口层
#
# BattleUI 只通过这里读状态、发意图。把这些薄方法集中在一处，
# 好处是"UI 需要什么"一目了然，换 UI 实现时只动这一层。
# ══════════════════════════════════════════════════════════════════════════════
# ── 只读：状态 ──
func ui_round_text() -> String:
	var side := "玩家" if (active != null and active.is_manual()) else "敌方"
	return "第 %d 轮 ｜ 当前：%s（%s）" % [round_no, active.name if active else "-", side]


func ui_upcoming(n: int) -> Array[Unit]:
	var out: Array[Unit] = []
	if queue == null:
		return out
	for u in queue.preview(n):
		if out.size() >= n:
			break
		if u.is_alive():
			out.append(u)
	return out


func ui_skill_info() -> String:
	return _skill_info_text


func ui_placeable_info() -> String:
	return _placeable_info_text


func ui_place_left() -> Dictionary:
	return place_left


func ui_place_kind() -> String:
	return _place_kind


func ui_is_placing() -> bool:
	return phase == Phase.PLACE


func ui_busy() -> bool:
	return _gm_busy


func ui_restart() -> void:
	get_tree().reload_current_scene()


func ui_camera() -> Camera3D:
	return _camera


func ui_faction_cn(u: Unit) -> String:
	return _faction_cn(u)


func ui_fmt(milli: int) -> String:
	return _fmt(milli)


func ui_collect_log() -> PackedStringArray:
	return PackedStringArray(_debug_log)


func ui_dbg_fields() -> Array:
	return DBG_FIELDS


func ui_dbg_get(u: Unit, key: String) -> int:
	if u == null:
		return 0
	match key:
		"power_max": return int(round(u.power_max / 1000.0))
		"power_cur": return int(round(u.power_cur / 1000.0))
		"armor_max": return int(round(u.armor_max / 1000.0))
		"armor_cur": return int(round(u.armor_cur / 1000.0))
		"armor_break": return int(round(u.armor_break / 1000.0))
		"energy_max": return int(round(u.energy_max / 1000.0))
		"move": return u.move
		"rng_max": return u.rng_max
		"rest_power": return int(round(u.rest_power / 1000.0))
		"rest_armor": return int(round(u.rest_armor / 1000.0))
		"rest_energy": return int(round(u.rest_energy / 1000.0))
		"pr": return int(round(u.pr / 10.0))
		"mr": return int(round(u.mr / 10.0))
	return 0


## 写回：非整数直接拒绝，越界夹取。返回 false = 没按原样写进去（UI 会重建输入框显示真实值）
func _dbg_write(u: Unit, f: Array, raw: String) -> bool:
	var lo: int = f[2]
	var hi: int = f[3]
	var txt := raw.strip_edges()
	if not txt.is_valid_int():
		_log("[调试] %s 的「%s」不是整数，已还原" % [u.name, f[1]])
		return false
	var v := txt.to_int()
	var ok := true
	if v < lo or v > hi:
		var clamped: int = clampi(v, lo, hi)
		_log("[调试] %s 的「%s」%d 超出 %d~%d，已改为 %d" % [u.name, f[1], v, lo, hi, clamped])
		v = clamped
		ok = false
	var key: String = f[0]
	match key:
		"power_max":
			u.power_max = Rules.points_to_milli(v)
			if u.power_cur > u.power_max: u.power_cur = u.power_max
			if u.power_cur <= 0 and v > 0: u.power_cur = u.power_max     # 顺手复活
		"power_cur":
			var was_dead := not u.is_alive()
			u.power_cur = Rules.points_to_milli(v)
			if was_dead and v > 0:
				_revive_unit(u)
			elif not was_dead and v <= 0:
				# 被改成 0 -> 立即阵亡，模型收起（与战斗中的死亡表现一致）
				_log("[调试] %s 力量被改为 0，判定阵亡" % u.name)
				_on_unit_died(u)
		"armor_max":
			u.armor_max = Rules.points_to_milli(v)
			if u.armor_cur > u.armor_max: u.armor_cur = u.armor_max
		"armor_cur": u.armor_cur = Rules.points_to_milli(v)
		"armor_break": u.armor_break = Rules.points_to_milli(v)
		"energy_max":
			u.energy_max = Rules.points_to_milli(v)
			if u.energy > u.energy_max: u.energy = u.energy_max
		"move": u.move = v
		"rng_max":
			u.rng_max = v
			if u.rng_min > u.rng_max: u.rng_min = u.rng_max
		"rest_power": u.rest_power = Rules.points_to_milli(v)
		"rest_armor": u.rest_armor = Rules.points_to_milli(v)
		"rest_energy": u.rest_energy = Rules.points_to_milli(v)
		"pr": u.pr = v * 10
		"mr": u.mr = v * 10
	# 数值改完立刻反映到画面（血量条 / 详情栏 / 可移动格）
	if u.visual != null:
		u.visual.update_orb()
	_refresh_all()
	return ok


func ui_dbg_set(u: Unit, key: String, raw: String) -> bool:
	if u == null:
		return false
	for f in DBG_FIELDS:
		if f[0] == key:
			var ok: bool = _dbg_write(u, f, raw)
			_push_unit_stats(u)
			return ok
	return false


func ui_dbg_reset(u: Unit) -> void:
	if u == null:
		return
	_log("[调试] %s 的字段已还原为当前真实数值" % u.name)
	_push_unit_stats(u)

## 详情面板的文字（UI 只负责显示）
func ui_detail_text(u: Unit) -> String:
	var t := "[b][color=#ffd866]%s[/color][/b] %s·%s" % [
		u.name, Unit.role_name(u.role) if not u.name.begins_with("Dummy") else "假人",
		_faction_cn(u)]
	if u == active:
		t += "  [color=#8f8]←正在行动[/color]"
	t += "   位置(%d,%d) 存活%s\n" % [u.cell.x, u.cell.y, "是" if u.is_alive() else "否"]
	t += "[b]力[/b] %s/%s  [b]甲[/b] %s/%s  物抗%s 魔抗%s 破甲%s 精力%d/%d\n" % [
		_fmt(u.power_cur), _fmt(u.power_max), _fmt(u.armor_cur), _fmt(u.armor_max),
		Unit.tier_name(u.pr), Unit.tier_name(u.mr), _fmt(u.armor_break),
		u.energy_points(), u.energy_max_points()]
	t += "移动%d 射程%s 休息恢复 力%s/甲%s" % [u.move,
		"近战" if u.role == UnitData.Role.MELEE else "%d-%d" % [u.rng_min, u.rng_max],
		_fmt(u.rest_power), _fmt(u.rest_armor)]
	if Passives.focus_stacks(u) > 0:
		t += "  [color=#ff9]【蓄势】%d 层（下一发普攻 +%d 力量）[/color]" % [
			Passives.focus_stacks(u), Passives.focus_bonus_milli(u) / 1000]
	# 被动（目前只有杰拉尔德有）
	for pname in Passives.names_for_unit(u):
		t += "\n[b][color=#ffd866]被动[/color][/b] %s" % pname
	if not u.allocated.is_empty():
		var parts: Array[String] = []
		for k in u.allocated:
			parts.append("%s+%d" % [Rules.option_label(k), u.allocated[k]])
		t += "  [color=#8fd]已加:%s[/color]" % ",".join(parts)
	return t


# ── 意图：玩家操作 ──
func ui_click_unit(u: Unit, from_queue: bool = false) -> void:
	if u == null or not u.is_alive():
		return
	if u == active and u.is_manual():
		_select_for_detail(u)
		_show_action_menu()
		return
	_select_for_detail(u)
	if from_queue:
		pass                              # 从队列表点进来只做选中，不再往日志里写提示
	elif u.is_manual() and u == active:
		_show_action_menu()


func ui_click_blank() -> void:
	_on_blank_click()


func ui_move() -> void:
	_menu_move()


func ui_attack() -> void:
	_menu_attack()


func ui_skill() -> void:
	_menu_skill()


func ui_rest() -> void:
	_menu_rest()


func ui_end_turn() -> void:
	_on_next_pressed()


func ui_pick_place(nm: String) -> void:
	_pick_place_kind(nm)


## 自动演算用：这一局谁赢了
func ui_result_win() -> bool:
	return _last_win


## 关卡列表（调试页用）
func ui_levels() -> Array:
	var out: Array = []
	for id in Level.ids():
		out.append({"id": id, "name": Level.name_of(id), "current": id == Level.current})
	return out


## 切换关卡：记住 id 然后重载场景（Level.current 是静态的，重载后还记得）
func ui_set_level(id: String) -> void:
	Level.current = id
	_log("[关卡] 切换到 %s，重载场景" % Level.name_of(id))
	get_tree().reload_current_scene()


func ui_set_zoom(v: float) -> void:
	_zoom = v
	_update_camera()


func ui_pick_skill(id: String) -> void:
	_choose_skill(id)


func ui_confirm_attack(break_armor: bool) -> void:
	_confirm_attack(break_armor)


func ui_cancel() -> void:
	_cancel_to_menu()


func ui_upgrade(u: Unit, key: String) -> void:
	if Rules.apply_point(u, key):
		_push_unit_stats(u)


func ui_reset_upgrades(u: Unit) -> void:
	Rules.reset_points(u)
	_push_unit_stats(u)


## 打开攻击菜单（用户口径：不再有"投入精力加伤害"，预览就是纯力量对护甲）
func ui_open_attack_menu(t: Unit) -> void:
	if ui != null:
		ui.show_attack_menu(t)


func ui_open_skill_menu(ids: Array[String]) -> void:
	if ui != null:
		ui.show_skill_menu(ids, active)
