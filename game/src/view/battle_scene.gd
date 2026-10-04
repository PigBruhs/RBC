# ══════════════════════════════════════════════════════════════════════════════
# 战场场景：状态 + 场景搭建 + UI + 输入 + 回合机 + 伤害/技能收尾
#
# 【两条唯一入口】（第 82 轮重构）：不管从哪条路出手，最终都只走这两个函数 ——
#   _perform_basic()  普攻：拖拽 / 点目标 / AI 三条入口都调它（模板见 core/attack_profile.gd）
#   _perform_skill()  技能：玩家（拖拽/点格子/点一下）与 AI 都调它（cast/aim 见 core/skills.gd）
# 受伤触发的被动走 _after_damage_to_unit() 里的钩子表（Passives.DEFS 的 on_damaged）。
# 加角色 / 加技能 = 表里加一行，不再需要在多条入口里各插一个 if。
#
# 说明：这个文件仍然偏大（约 4000 行）。拆分方案（继承链：状态/场景/UI 归父类）
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
## GW/GH = 物理边界（炮弹能飞到哪）；PX/PY/PW/PH = 可行动区域（有格子的地方）。
## 用户口径（第 83 轮）：竞技场的物理边界扩到 100×100，但真正有格子的还是那块 21×41 ——
## 外面是"空场"：不能走、不能放、不画地形，但炮弹照飞、照常触发碰撞。
var GW := 48

var GH := 48

var PX := 0                  # 可行动区域左上角 x
var PY := 0                  # 可行动区域左上角 y
var PW := 48                 # 可行动区域宽
var PH := 48                 # 可行动区域高

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

## 表现层模块（格子高亮 / 待确认标记 / 落点红圈 / 闪光，见 view/view_fx.gd）。
## 节点由它创建、宿主只持有引用；下面这些 _xxx 在 playtest / probe 里被直接读，名字不能改。
var fx: ViewFx = null

## 弹道物与爆炸结算模块（弹道事件 / 唯一落地入口 / 空爆 / 破片 / 齐射 / 枪榴弹，
## 见 view/projectile_sink.gd）。_salvo_u / _salvo_dbg / _grenade_models / _proj_groups
## 这些被测试直读的字段**仍然声明在本类**，模块通过 _st._xxx 读写。
var sink: ProjectileSink = null

## 普攻唯一入口模块（三条入口分派 / 目标闸门 / 打角色与打沙盒的结算，
## 见 view/basic_attack.gd）。attackable 等被测试直读的字段仍声明在本类。
var attack: BasicAttack = null

## 技能编排模块（唯一入口 perform_skill / 光柱 / 地毯轰炸 / 俯冲 / 待确认格子，
## 见 view/skill_runner.gd）。字段名不叫 skills —— 那是 core 的类名。
var skills_mod: SkillRunner = null

## 回合机 + 行棋寻路 + 单位生命周期模块（P2b 拆出，见 view/turn_runner.gd）。
## 下面的同名薄包装转发到它；_process / _ready / 回调 Callable / 别人的调用点都照旧。
var turn: TurnRunner = null

## AI 开关（P4 从 GameMaster 迁出：GM 是 core 的场上状态裁判，不该知道 AI）。
## 驱动层（本场景）才是它的家；测试走 t_ai_enabled() / t_set_ai_enabled() 门面读写。
var ai_enabled := true                       # 敌方整队交给 AI
var ai_autoplay_player := false              # 自动演算：我方也交给 AI（跑测试用）

## AI 驱动 + GM 演出推进模块（P2e 拆出，见 view/ai_runner.gd）。
## 它负责 _ai_ctx / _ai_take_turn / _ai_move / _ai_attack / _ai_skill / _is_ai_unit
## 与老国王加农炮（_fire_cannon_ai）以及 GM 回合边界演出（_gm_step）。
## 上面的 ai_enabled / ai_autoplay_player 是**驱动层状态**，模块经 _st. 读。
var ai: AiRunner = null

## 放置/沙盒/待确认状态机模块（P2c 拆出，见 view/sandbox_runner.gd）。
## place_left / _place_kind / placeables / _pending_kind / _pending_cell 的**声明留在本类**
## （ViewFx 的黄勾可视化要读 _st._pending_cell），模块经 _st. 读写。
var sandbox: SandboxRunner = null

## 行动菜单状态机（二级行动菜单 / 普攻菜单 / 技能入口 / 沙盒道具详情，
## 见 view/action_menu.gd）。菜单节点本身仍是 _action_menu / _attack_menu 等字段，声明留在本类。
var action_menu: ActionMenu = null

## 瞄准 / 拖拽输入 / 相机 / 鼠标拾取（见 view/aim_controller.gd）。
## _arrow_root / _cam_focus / _zoom 等被测试直读的字段声明仍留在本类。
var aim: AimController = null

## 空中单位：巡飞弹（发射器 + Q/E 制导）+ 直升机全流程（见 view/air_runner.gd）。
## _dive / _dive_markers / _loiter_control / _heli_shadows / _salvo_u 等字段声明仍留在本类。
var air: AirRunner = null

## 激光类（光束）模块：Reaper 的横扫 / 竖切（见 view/laser_beam.gd）。
## 光束**不是飞行物**（不进 ProjectileField）：每个物理帧对覆盖到的角色累加帧伤，
## 光束结束时统一结算一次。`_process` 里每帧 `laser_mod.tick(delta)`，测试走 t_laser_* 门面。
var laser_mod: LaserBeam.Runner = null

var _zoom: float = 15.0

var _cam_focus: Vector3 = Vector3.ZERO      # 相机注视的地面点（WASD 平移）

var _cam_height: float = 0.0               # 相机抬高（QE）

# 瞄准

var _aim_active := false

var _aim_valid := false              # 是否已经算出一个有效落点（防止在 (0,0) 误开火）

var _aim_float_pos: Vector2 = Vector2.ZERO  # 浮点落点（不做格子吸附）

var _aim_origin := Vector2.ZERO      # 屏幕坐标

var _aim_now := Vector2.ZERO

var _arrow_root: Node3D

var _shaft: MeshInstance3D

var _head: MeshInstance3D

var _projectile: MeshInstance3D

var _impact_ring: MeshInstance3D

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

# 待确认状态机（可视化在 ViewFx：_pending_root / _pending_mats / 黄勾）

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

## 哨兵编排模块（组合而非继承）：队列 tick / 放箭 / 进界锁定都转发给它
var sentry: SentryRunner = null

var _revive_timers: Dictionary = {}           # Unit -> SceneTreeTimer（同一单位只保留一个）

var uid_dead: Dictionary = {}                 # Unit -> true（已经播报过阵亡，防止重复）

var _aim_skill_id: String = ""                # 正在瞄准的技能 id（空 = 投掷手普攻）

var _skill_info_text: String = ""
var _placeable_info_text: String = ""             # 瞄准时显示在属性栏的技能说明

var _btn_skill: Button                        # 二级菜单里的「技能」按钮
var _btn_attack: Button                       # 二级菜单里的「普攻」按钮（第 89 轮：精力不够置灰）

var _skill_menu: PanelContainer               # 多技能时的选择列表

var _menu_anchor: Unit = null                 # 二级菜单跟随的角色
# 待确认标记（常驻节点，避免每帧重建导致"看不见"）

var _pending_root: Node3D = null

var _pending_mats: Array = []

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
const SENTRY_AIM_BALL_R := SentryRunner.AIM_BALL_R   # 真值在 SentryRunner（避免两份半径）
const HELI_PREFIX := AttackProfile.HELI_PREFIX   # 悬浮 + 火箭齐射 + 坠机/俯冲都按这个名字前缀识别
# 三连发的发数与间隔、谁用近战/弓箭/投掷，全部来自 AttackProfile（见 core/attack_profile.gd）
var game_over := false                    # 分出胜负了（自动演算用）
var _last_win := false
var _last_turn_side := -1                 # 上一个结束的回合属于哪一方（防"同方连走两回合")

const AI_QTE_CHANCE := 0.6            # AI 阵营的弹反成功率（不弹 2D 面板）

## 进入技能瞄准（目前套用投掷手那一整套瞄准）

const UNIT_BODY_R := 0.30            # 角色脚下的判定半径

const CARPET_BLAST_R := 1.0          # 地毯式轰炸的爆炸半径 = 轨道炮击同款（比普攻 1.5 小）

## 相机相关：WASD 平移 / 滚轮缩放 / QE 高度
## 处理相机输入，同时把日志刷进 Debug 面板（每帧最多刷一次）

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
	# 只铺【可行动区域】的地板：空场没有格子划分（用户口径第 83 轮）
	for y in range(PY, PY + PH):
		for x in range(PX, PX + PW):
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

	# 落点范围圈（落地后才出现，表示 impact 范围）：节点由表现层 ViewFx 造，宿主挂上并持有引用
	# 半径与命中判定完全一致（BLAST_RADIUS），所以"红圈沾到格子 = 命中"是真的
	_impact_ring = fx.make_impact_ring_node(BLAST_RADIUS)
	add_child(_impact_ring)

	_hint_layer = fx.make_hint_layer_node()
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


# ══════════════════════════════════════════════════════════════════════════════
# 巡飞弹 + 沙盒发射器（用户口径第 90 轮）
#
#   · 发射器：射程 12 格，**只打"进入范围的正在移动的角色"**（站着的不打），
#     每 5 个 GM 回合边界只能发射一枚；方向 = 目标方向 ±45° 内随机。
#   · 巡飞弹：定高 1.5、恒速 3 格/秒、直径一格的球；玩家用 Q/E 制导；
#     造伤范围直径两格的球（40 破甲 + 40 力量）；近炸引信 / 飞满 32 格自动引爆。
# ══════════════════════════════════════════════════════════════════════════════
var _loiter_control: Projectile = null     # 玩家正在制导的那一发（见 _loiter_pick_control）
var _loiter_sample: float = 0.0            # 发射器采样计时
var _unit_seen: Dictionary = {}            # Unit -> 上次采样到的浮点位置（判"在动"）


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
	_btn_attack = ui.btn_attack
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




# ── ⚠️ 跨模块事实接口（别删）：别的模块正在通过 _st._xxx 调这两个 ──
#   projectile_sink.gd -> _st._loiter_burst(p, ...)  （被击落 / 落地都按就地引爆）
#   turn_runner.gd     -> _st._dive_begin(u)         （AI/回合机发起俯冲）
# 实现在 view/air_runner.gd。删了会在运行时炸，编译期查不出来。
func _loiter_burst(p: Projectile, ctr: Vector3) -> void:
	air.loiter_burst(p, ctr)


func _dive_begin(u: Unit) -> bool:
	return air.dive_begin(u)


# ── 跨模块事实接口：这三个别的模块会用 `_st.` 调，宿主必须留公开入口 ──
#   action_menu.gd / skill_runner.gd -> _st._begin_aim()
#   view_fx.gd                       -> _st._hover_cell()
#   sandbox（放置/沙盒）             -> _st._pick_cell(...)  ← 预防性：拾格是放置的依赖
# 实现在 view/aim_controller.gd。**别删**（删了调用方会在运行时炸，编译期查不出来）。
func _begin_aim() -> void:
	aim.begin_aim()


func _hover_cell() -> Variant:
	return aim.hover_cell()


func _pick_cell(mouse: Vector2) -> Variant:
	return aim.pick_cell(mouse)


# ── 跨模块事实接口：这三个动作**别的模块也会调**，所以宿主必须留一个公开入口 ──
#   basic_attack.gd   -> _st._show_action_menu() / _st._push_unit_stats(...)
#   skill_runner.gd   -> _st._show_action_menu() / _st._hide_action_menu() / _st._push_unit_stats(...)
# 实现在 view/action_menu.gd，这里只是"跨模块那一步"的转发 —— 别删（删了那两个模块会炸）。
# 这也是 task-7 得到的判据：**包装能不能删，取决于有没有别的模块通过 `_st.` 调它。**
func _show_action_menu() -> void:
	action_menu.show_action_menu()


func _hide_action_menu() -> void:
	action_menu.hide_action_menu()


func _push_unit_stats(u: Unit) -> void:
	action_menu.push_unit_stats(u)


## 注：上面的 `_refresh_upgrades()` 全仓零引用 —— 保留是因为 `check_wrappers` 把它
## 登记成了 `battle_ui.gd` 的包装（覆盖顺带纳入的）。加点 UI 已按用户要求整体移除
## （规格 §九：左下角只保留队列可视化），所以它永远不会有调用方；
## 删它需要同步改 `check_wrappers.gd` 的 MODULES。留在 P0 清账期的后续步骤里一起处理。

func _ready() -> void:
	# 先按当前关卡定尺寸与相机角度，再建一切
	GW = Level.gw()
	GH = Level.gh()
	PX = Level.play_x0()
	PY = Level.play_y0()
	PW = Level.play_w()
	PH = Level.play_h()
	_cam_yaw = Level.cam_yaw()
	_log("[关卡] %s（物理 %d×%d，可行动 %d×%d @ %d,%d）" % [Level.name_of(), GW, GH, PW, PH, PX, PY])
	# 协作模块（组合，非继承）：构造函数只注入宿主引用、没有副作用，
	# 所以先建它们 —— 下面的 field.setup / gm.on_projectile_event 要把**模块方法**当 Callable 传进去。
	sentry = SentryRunner.new(self)      # 哨兵编排模块（宿主 = 本场景）
	fx = ViewFx.new(self)                # 表现层模块（高亮/待确认标记/落点环/闪光）
	sink = ProjectileSink.new(self)      # 弹道物与爆炸结算模块
	attack = BasicAttack.new(self)       # 普攻唯一入口模块
	skills_mod = SkillRunner.new(self)   # 技能编排模块（唯一入口 perform_skill）
	turn = TurnRunner.new(self)         # 回合机 / 寻路 / 单位生命周期模块
	ai = AiRunner.new(self)             # AI 驱动 + GM 演出推进模块
	sandbox = SandboxRunner.new(self)   # 放置 / 沙盒 / 待确认状态机模块
	action_menu = ActionMenu.new(self)   # 行动菜单状态机
	aim = AimController.new(self)        # 瞄准/拖拽 + 相机 + 鼠标拾取
	air = AirRunner.new(self)            # 巡飞弹（含发射器）+ 直升机全流程
	laser_mod = LaserBeam.Runner.new(self)  # 激光类光束：帧伤累计 + 统一结算 + 表现
	# 弹道物场：只做物理与上报，后果由 ProjectileSink 处理
	# ⚠️ 这里传的是**模块方法**（Callable 事实接口）：改名即断，两处都在本函数里
	field = ProjectileField.new()
	field.setup(self, gm, sink.arrow_hit_check)
	field.log_fn = _log
	field.grid_w = GW
	field.grid_h = GH
	gm.on_projectile_event = sink.on_projectile_event
	# 哨兵射界高亮：只画描边，判定仍然走 Sentry.in_range
	sentry_range = SentryRange.new()
	sentry_range.setup(self)
	sentry_range.grid_w = PW
	sentry_range.grid_h = PH
	sentry_range.grid_x0 = PX
	sentry_range.grid_y0 = PY
	_build_env()
	_build_terrain()
	aim.build_camera()
	_build_aim_helpers()
	_init_passive_hooks()          # 受伤触发的被动钩子表（坠机…）
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
	sandbox.build_sandbox()


func _enter_placement() -> void:
	sandbox.enter_placement()

func _pick_place_kind(nm: String) -> void:
	sandbox.pick_place_kind(nm)

## 该格能不能放：在界内、不在河里、不压单位、不压已有道具

## ⚠️ 跨模块事实接口（**别删**）：view_fx.gd（放置高亮配色） 正在通过 `_st._can_place_at` 调它。
## 删掉这个同名包装 = 对方在运行时报 Nonexistent function（编译期查不出来）。
func _can_place_at(c: Vector2i) -> bool:
	return sandbox.can_place_at(c)


## 放一个道具

func _place_at(c: Vector2i) -> void:
	sandbox.place_at(c)

func _placeable_data(nm: String) -> Dictionary:
	return sandbox.placeable_data(nm)


## 结束放置 -> 正式开始第 1 回合

func _finish_placement() -> void:
	sandbox.finish_placement()


# ══════════════════════════════════════════════════════════════════════════════
# 二次确认（两段式操作）
#   用户要求：所有操作第一次点 = 进入"待确认"（目标格显示黄色 √），
#             再点同一处 = 真正执行。点别处 = 取消待确认。
# ══════════════════════════════════════════════════════════════════════════════
## 设置待确认操作。kind: "move" / "attack" / "place" / "aim"
## actor：这次操作要一起染色的角色（移动 = 自己；攻击 = 目标；放置 = 无）

## ⚠️ 跨模块事实接口（**别删**）：skill_runner.gd 正在通过 `_st._set_pending` 调它。
## 删掉这个同名包装 = 对方在运行时报 Nonexistent function（编译期查不出来）。
func _set_pending(kind: String, cell: Vector2i, actor: Unit = null) -> void:
	sandbox.set_pending(kind, cell, actor)

## ⚠️ 跨模块事实接口（**别删**）：skill_runner.gd / action_menu.gd 正在通过 `_st._clear_pending` 调它。
## 删掉这个同名包装 = 对方在运行时报 Nonexistent function（编译期查不出来）。
func _clear_pending() -> void:
	sandbox.clear_pending()

## ⚠️ 跨模块事实接口（**别删**）：skill_runner.gd 正在通过 `_st._same_pending` 调它。
## 删掉这个同名包装 = 对方在运行时报 Nonexistent function（编译期查不出来）。
func _same_pending(kind: String, cell: Vector2i) -> bool:
	return sandbox.same_pending(kind, cell)


# ══════════════════════════════════════════════════════════════════════════════
# 移动 / 阻挡查询
# ══════════════════════════════════════════════════════════════════════════════
## 走不进去的格子：阻挡移动的道具 + 河面（不含桥）
## ⚠️ 跨模块事实接口（**别删**）：turn_runner.gd（寻路占格） 正在通过 `_st._blocked_cells` 调它。
## 删掉这个同名包装 = 对方在运行时报 Nonexistent function（编译期查不出来）。
func _blocked_cells() -> Dictionary:
	return sandbox.blocked_cells()


## 远程弹道是否被该格的道具挡住（投掷手无视阻挡远程的道具）

func _ranged_blocked_at(c: Vector2i, by_thrower: bool) -> bool:
	return sandbox.ranged_blocked_at(c, by_thrower)


## 找某格上的道具

## ⚠️ 跨模块事实接口（**别删**）：basic_attack.gd（近战打道具） 正在通过 `_st._placeable_at` 调它。
## 删掉这个同名包装 = 对方在运行时报 Nonexistent function（编译期查不出来）。
func _placeable_at(c: Vector2i) -> Placeable:
	return sandbox.placeable_at(c)


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

## 一个单位有多个技能时，先弹一个小列表让玩家选

## 施放【哨兵】：不瞄准，进入警戒状态，登记在 GameMaster 上（跨回合存活）

# ══════════════════════════════════════════════════════════════════════════════
# 技能统一入口（用户要求：玩家路径与 AI 路径必须是同一条生产线）
#
#   玩家：拖拽松手（_fire 的技能分支）/ 点格子（俯冲）/ 点一下（哨兵）
#   AI  ：_ai_skill()
# 都只负责"算出瞄哪里"，然后调 _perform_skill()；施放方式来自 Skills.cast_of(id)。
# 以前这两条路各写一套 if，结果是"某个技能只给玩家接了、AI 没接"（枪榴弹、
# 俯冲轰炸都真实发生过）。现在加技能 = Skills.DEFS 加一行 + 一个 cast 实现。
# ══════════════════════════════════════════════════════════════════════════════

## 在落点竖起紫色光柱：沿地面法线（+Y）向上，长度足够冲出屏幕

## 轨道炮击：以标记点为中心、半径 3 格内的【不重复】随机落点，随机顺序，
## 每发从"斜右上方"用 1 秒落到中心，两发之间停 0.5 秒。
## 落点是浮点坐标（不做格子吸附），打到哪里算哪里。

## 圆内随机落点，【保证互不重复】。浮点坐标，不做格子吸附。

## 一发炮弹从天而降的动画：从"斜右上方"的视野外落到中心，耗时 1 秒

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

func _spawn_units() -> void:
	turn.spawn_units()


# ══════════════════════════════════════════════════════════════════════════════
# 回合队列
# ══════════════════════════════════════════════════════════════════════════════

func _start_round() -> void:
	turn.start_round()


## 场上有没有"能进队列的"单位（英雄；国王与公主是 no_turn，不算）
func _has_actor() -> bool:
	var c := TurnFlow.hero_counts(units)
	return c[0] > 0 or c[1] > 0


## 开新一轮，但先处理一种极端情况：**场上一个"能进队列的"单位都没有**
## （双方英雄全在等复活；国王与公主是 no_turn，不进队列）。
## 这时如果直接 _start_round() -> _next_turn() -> 又是空队列 -> 再 _start_round()…
## 会无限递归直到栈溢出（AI 自动演算里真实发生过，轮次直接冲到 1023）。
## 正确做法：推进 GM 回合边界（复活计时就走在这里），等人回来再开新一轮。
func _begin_next_round() -> void:
	await turn.begin_next_round()

func _next_turn() -> void:
	await turn.next_turn()


## ── 通用 AI（用户口径：给每个 AI 索敌优先级与规则，全图视野）────────────────
## 决策在 core/ai.gd（纯函数），这里只负责组装世界快照 + 执行计划。

## ⚠️ 跨模块事实接口（**别删**）：turn_runner.gd 正在通过 `_st._is_ai_unit` 调它。
## 删掉这个同名包装 = 对方在运行时报 Nonexistent function（编译期查不出来）。
func _is_ai_unit(u: Unit) -> bool:
	return ai.is_ai_unit(u)


func _ai_ctx(u: Unit) -> Ai.Ctx:
	return ai.ai_ctx(u)


## ⚠️ 跨模块事实接口（**别删**）：turn_runner.gd 正在通过 `_st._ai_take_turn` 调它。
## 删掉这个同名包装 = 对方在运行时报 Nonexistent function（编译期查不出来）。
func _ai_take_turn(u: Unit) -> void:
	if gm.is_reaper(u):
		await reaper_take_turn(u)        # Boss-3：三循环（召唤/横扫/竖切），不走通用 AI
		return
	await ai.ai_take_turn(u)


## AI 走位。wait = false 时只发起移动、不等走完（保留参数：现在所有 AI 都等走完）
func _ai_move(u: Unit, cell: Vector2i, wait: bool = true) -> void:
	await ai.ai_move(u, cell, wait)


## AI 出手：和玩家点目标走的是同一条生产线（_perform_basic）。
## 差别只有两点：不弹菜单、打不出也必须自己收尾（绝不允许 AI 回合卡住）。
func _ai_attack(u: Unit, plan: Dictionary) -> void:
	ai.ai_attack(u, plan)


## AI 用技能：和玩家走同一条生产线（_perform_skill）。
## 差别只有两点：不弹菜单、用不出也必须自己收尾（绝不允许 AI 回合卡住）。
func _ai_skill(u: Unit, plan: Dictionary) -> void:
	ai.ai_skill(u, plan)


## ── 老国王的加农炮 AI ────────────────────────────────────────────────────────
## 用户口径：朝【距离最近的敌对单位】发射一发加农炮弹；
## 不管对方是否在射程内、路径上有没有障碍物或友军；并列最近时随机选一个。

## ⚠️ 跨模块事实接口（**别删**）：turn_runner.gd 正在通过 `_st._fire_cannon_ai` 调它。
## 删掉这个同名包装 = 对方在运行时报 Nonexistent function（编译期查不出来）。
func _fire_cannon_ai(u: Unit, ends_turn: bool = true) -> void:
	ai.fire_cannon_ai(u, ends_turn)


## 这位老国王是不是已经有一发炮弹在飞（GM 定时空袭时避免叠炮）
func _king_ball_in_flight(u: Unit) -> bool:
	return ai.king_ball_in_flight(u)


func _spawn_cannon(caster: Unit, from: Vector3, to: Vector3, ends_turn: bool) -> Projectile:
	return ai.spawn_cannon(caster, from, to, ends_turn)

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
			action_menu.push_unit_stats(active)
			_log("  🧨 %s 本回合没有移动：【装填】精力 +%d（%d→%d）" % [
				active.name, bonus_e, before_e / 1000, active.energy / 1000])
	_turn_just_finished = active
	if active.visual != null:
		active.visual.set_active(false)
	# 用户口径第 87 轮：谁行动完就【出队再入队尾】—— 必须把 active 显式传进去：
	# 复活会把别人压到队头，那时"队头"已经不是他了。
	var who := active
	active = null
	selected = null
	# 防御（第 99 轮）：`queue` 在【放置阶段结束】之前是 null —— 场景 `_ready` 之后
	# 先进放置阶段，玩家点 >> 才 `start_round()` 造队列。这期间若有人（探针/异常输入）
	# 调到这个函数，以前会报 `Nonexistent function 'advance' in base 'Nil'`。
	# 现在：没有队列就当"还没开打"，只做收尾不做队列推进。
	if queue == null:
		action_menu.hide_action_menu()
		_clear_pending()
		fx.clear_hints()
		return
	queue.advance(who)
	action_menu.hide_action_menu()
	_clear_pending()
	fx.clear_hints()
	_refresh_all()
	_check_over()
	# GameMaster 的【回合边界】：调度型效果（轨道空爆）在这里暂停回合并执行，
	# 演完再继续进入下一个角色的回合。环境型效果（哨兵）不走这里，随时响应。
	await _gm_step()
	_next_turn()


## 把一个单位的三池变化立刻推到表现层与详情栏（休息、加点、Debug 改值都走这里）

## 点沙盒道具：把它的描述与数据写进下方属性栏（用户要求）

## ⚠️ 跨模块事实接口（**别删**）：turn_runner.gd 正在通过 `_st._gm_step` 调它。
## 删掉这个同名包装 = 对方在运行时报 Nonexistent function（编译期查不出来）。
func _gm_step() -> void:
	await ai.gm_step()
	gm.reaper_passive_tick(units, rng)        # Reaper 6 格被动：每游戏回合（回合边界）造伤一次        # Reaper 6 格范围被动（GM 负责，每个回合边界一次）


## GameMaster 演出开关：锁住所有角色操作与 >> 按钮

func _set_gm_busy(on: bool) -> void:
	_gm_busy = on
	if _btn_next != null:
		_btn_next.disabled = on
	if on:
		action_menu.hide_action_menu()
		_clear_pending()
		fx.clear_hints()
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
	return turn.check_last_stand()


## 自检：队列里不允许出现"同一方连续两回合"。
## 唯一例外是连击模式（孤军与对面交替，孤军仍不会连出两次）。

func _queue_alternation_ok() -> bool:
	return turn.queue_alternation_ok()

func _check_over() -> bool:
	return turn.check_over()


## 胜者界面：中央一个面板 + 「继续」按钮，点了重开（回到初始状态）

func _show_result(win: bool) -> void:
	game_over = true
	_last_win = win
	if ui != null:
		ui.show_result(win)


## 注：原 `_on_result_continue()`（`get_tree().reload_current_scene()`）于第 97 轮 P0
## 清账期删除 —— 全仓零引用（死代码）。胜者界面的「继续」按钮走的是 `ui_restart()` /
## `BattleUI` 自己的回调，不需要这个中转。

## 二级菜单的深色底：否则会和右侧详情面板叠在一起看不清

# ══════════════════════════════════════════════════════════════════════════════
# 攻击二级菜单：点敌人后弹出「打力量 / 破甲」，两个按钮上直接写清楚伤害
# ══════════════════════════════════════════════════════════════════════════════

## 拖拽像素 -> 力度 t（0..1）

## 力度 -> 射程（格）。非线性：平方曲线，轻拉细腻、重拉才到远距离。

## 力度 t -> 箭头长度（世界单位）。约束：恒定落在 身高的 1~3 倍（用户要求）。
## 用同一条平方曲线，只是把 0~1 的力度映射到 1~3 倍身高：
##   len(t) = ARROW_LEN_MIN + (ARROW_LEN_MAX - ARROW_LEN_MIN) * t²   （单位 = 身高）
## 这样箭头长度与真实射程严格同步（同一 t），且永远看得见（最短也有 1 倍身高）。

## 瞄准时把落点范围内的单位与该次的命中/伤害预览显示出来（含概率）

## 松开左键。
##   投掷手普攻：球沿抛物线飞出 -> 落地 -> 红圈 -> 结算（含友伤）
##   技能瞄准  ：飞出一枚【小球】（比头大、比炮弹小）-> 落地消失 -> 竖起紫色光柱 -> 结束回合

## ── 炮弹（普攻 / 地毯式轰炸共用）────────────────────────────────────────────
## 弹道物的【物理】交给 Projectile；【伤害/落点】放在发射单里（用户口径）。
## 速度恒定 Ordnance.SHELL_TILES_PER_SEC 格/秒（用户要求降到 2 格/秒）。
## ↓ 实现已搬到 view/projectile_sink.gd（保留同名薄包装：playtest / probe 仍从本类调）

func _spawn_shell(caster: Unit, to: Vector2, ends_turn: bool,
		pre: float = 0.0, group: String = "", blast_r: float = Ordnance.DEFAULT_BLAST_R) -> Projectile:
	return sink.spawn_shell(caster, to, ends_turn, pre, group, blast_r)

## 箭矢在这一段路径里撞到了什么。返回 {unit: Unit} / {placeable: Placeable} / {}

## 落地事件（弹道物理上报）
# ── 给自检/试玩用的薄封装（真实实现都在 field 里）──

func clear_projectiles() -> void:
	if field != null:
		field.clear()

func live_projectiles() -> int:
	return 0 if field == null else field.live_count()

## 移动中开火：自检用（试玩第 40 节读它来验证"从当前位置出膛 + 落点按位移平移"）
var _salvo_dbg: Dictionary = {}


## ── 直升机的吊射 37mm 火箭：8 发、4 次齐射（左右各一发）、每次间隔 1 秒 ────────
## 用户口径第 93 轮：**波次 4 -> 8**（每波仍然左右各一发 -> 一共 16 发）。
## 注意：8 波要 7 秒才打完，所以它有了自己的"回合占用"标记 _salvo_u ——
##   · AI 回合看门狗在齐射期间不计时（否则 7 秒的齐射会被 9 秒看门狗砍断）
##   · 齐射收尾时只有"这一发还是当前回合的主人"才结束回合（否则会去结束下一个人的回合）
var _salvo_u: Unit = null


## ↓ 实现已搬到 view/projectile_sink.gd（保留同名薄包装）。
##   **包装必须 await**：sink.rocket_salvo 是协程（内含 create_timer 的 await），
##   不 await 的话包装自己不是协程、返回值会从"函数状态"变成 null，
##   将来谁写 `await _s._rocket_salvo(...)` 就会静默不等待。
##   当前全部调用方（basic_attack._basic_salvo / probe_r89 / playtest §93）都不 await，
##   所以这一条不改变任何现有行为，只是把原来的协程语义原样保住。
func _rocket_salvo(u: Unit, fpos: Vector2) -> void:
	await sink.rocket_salvo(u, fpos)


## ── 枪榴弹：地上的模型 + 4 回合后爆炸出 8 枚破片 ─────────────────────────
var _grenade_models: Dictionary = {}      # 格 -> Node3D（模型，不可交互）


## 球状闪光（用户口径：只要球状闪光，不要红圈）
## ★ 实现在 view/view_fx.gd；_last_flash 留在本类（playtest 直接读它，见 playtest.gd:1816）
var _last_flash: Node3D = null


# ══════════════════════════════════════════════════════════════════════════════
# 圣萨尼（第 98 轮新口径）：每个轮到萨尼铁塔的回合，朝一名受伤的队友投一枚**绿色箭头医疗包**
#
# 用户口径：
#   · **不再复活队友**（旧的"复活最后一个阵亡队友 / 每条命一次"整条已删除）
#   · 随机向一名"受了伤的队友"投掷，命中恢复 20 点力量（不超上限）
#   · 散布**复用杰拉德弹反那条曲线**（`Spread.reflect_scatter`）
#   · 飞行中碰到**任何人或沙盒元素**都给对方回血（含敌人 —— 刻意的搞笑口径，不要"修正"）
#
# 医疗包**不进 ProjectileField**：它不造伤、不能被击落、不惊动哨兵、也没有落地爆炸，
# 所以在这里自己推进（复用 `Projectile` 的抛物线数学 + `Ordnance.make_arrow` 的弹道参数）。
# `_holy_sani_check` 这个名字保持不变：`view/turn_runner.gd` 的回合开始路径按它调用。
# ══════════════════════════════════════════════════════════════════════════════

## 在途医疗包：[{"p": Projectile, "node": Node3D, "prev": Vector3}]
var _medkits: Array = []
## 最近一次选中的目标名（探针断言"随机但确定"用）
var _sani_heal_roll: String = ""


func _holy_sani_check(u: Unit) -> void:
	if u == null or not Passives.has(u, "holy_sani") or not u.is_alive():
		return
	var mate := Medkit.pick_target(u, units, rng)
	_sani_heal_roll = mate.name if mate != null else ""
	if mate == null:
		_log("  💚 %s 的【圣萨尼】：场上没有受伤的队友，这一回合不投" % u.name)
		return
	_throw_medkit(u, mate)


## 真实投掷路径（探针 `t_sani_throw_medkit` 也走这里）
func _throw_medkit(sani: Unit, target: Unit) -> void:
	var from := Vector3(float(sani.cell.x) + 0.5, 0.75, float(sani.cell.y) + 0.5)
	var dist := Vector2(from.x, from.z).distance_to(
		Vector2(float(target.cell.x) + 0.5, float(target.cell.y) + 0.5))
	var land := Medkit.scatter_landing(target, dist, rng)
	var to := Vector3(land.x, Targeting.aim_height(target), land.y)
	var p := Ordnance.make_arrow(sani, from, to, target, false, false)
	# ⚠ 医疗包飞得**平**（几乎不抛）：用户口径要求"飞行中碰到谁就给谁回血"。
	# 箭矢那种大拱高（arc_scale 0.34 / 最高 4.2 格）会从所有地面角色**头顶飞过**
	# （高度轴是物理判定），那条口径就永远不触发。压到 0.10~0.15 格：
	# 全程高度 ≈ 0.5~0.78 格，正好在"身高 1 格"的身体区间里 —— 谁在线上谁被治。
	p.arc_scale = 0.05
	p.arc_min = 0.10
	p.arc_max = 0.15
	p.recalc_apex()
	var node := _make_medkit_arrow(p.from.distance_to(p.to))
	node.position = from
	_medkits.append({"p": p, "node": node, "prev": from})
	_log("  💚 %s 的【圣萨尼】：向 %s 投出医疗包（%.1f 格，散布 %.2f 格）" % [
		sani.name, target.name, dist, Medkit.scatter_radius(dist)])


## 每帧推进在途医疗包：飞行 -> 碰到什么就治什么 -> 飞完还没碰到就飘走
func _tick_medkits(delta: float) -> void:
	if _medkits.is_empty():
		return
	var keep: Array = []
	for it in _medkits:
		var p: Projectile = it["p"]
		var prev: Vector3 = it["prev"]
		p.step(delta)
		var cur: Vector3 = p.pos3()
		it["prev"] = cur
		var node: Node3D = it["node"]
		if node != null and is_instance_valid(node):
			ProjectileField.orient(node, cur, prev, Ordnance.ARROW_TILES_PER_SEC)
			node.position = cur
		if _medkit_apply_hit(p, prev, cur):
			_medkit_fx_free(node)
			continue
		if p.finished():
			_log("  💚 医疗包没碰到任何人，飘走了")
			_medkit_fx_free(node)
			continue
		keep.append(it)
	_medkits = keep


## 这一小段路径碰到了谁：① 角色（**不分敌我**，碰到谁给谁回血）② 沙盒元素（也回血）
## 跳过投掷者自己（`p.owner_unit`）—— 否则一出膛就先给萨尼回一次血。
func _medkit_apply_hit(p: Projectile, prev: Vector3, cur: Vector3) -> bool:
	var u := Targeting.arrow_body_hit_seg(prev, cur, p.owner_unit, units, UNIT_BODY_R, p.hit_r)
	if u != null:
		_heal_unit(u)
		return true
	var pl := _placeable_near(cur)
	if pl != null:
		_heal_placeable(pl)
		return true
	return false


## 回血：力量池 +20，不超过上限。**这不是伤害**，所以不走 `_after_damage_to_unit`。
func _heal_unit(u: Unit) -> int:
	var before: int = u.power_cur
	u.power_cur = mini(u.power_max, u.power_cur + Medkit.heal_milli())
	var healed: int = u.power_cur - before
	_log("  💚 医疗包命中 %s：+%d 力量（%d → %d）" % [
		u.name, healed / 1000, before / 1000, u.power_cur / 1000])
	if u.visual != null:
		u.visual.update_orb()
	return healed


## 沙盒元素也能被"回血"（用户口径：会给飞行中碰到的沙盒元素回血）。
## `Placeable` 只有 `take_power_damage`（没有 heal API），所以直接按同一个池子补，照样钳上限。
func _heal_placeable(pl: Placeable) -> int:
	var before: int = pl.power_cur
	pl.power_cur = mini(pl.power_max, pl.power_cur + Medkit.heal_milli())
	var healed: int = pl.power_cur - before
	_log("  💚 医疗包命中沙盒元素 %s：+%d 力量（%d → %d）" % [
		pl.name, healed / 1000, before / 1000, pl.power_cur / 1000])
	if pl.visual != null:
		(pl.visual as PlaceableView).update_orb()
	return healed


## 医疗包外观：**绿色箭头**（用户口径）。几何照 `ProjectileField.make_arrow_node`
## （细杆 + 锥形箭头，沿局部 -Z 建，配合 `ProjectileField.orient` 的朝向约定），
## 颜色改成绿色 + 自发光，一眼看出是"回血"而不是"伤害"。
func _make_medkit_arrow(dist_tiles: float) -> Node3D:
	var arrow := Node3D.new()
	arrow.name = "MedkitArrow"
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.35, 1.0, 0.45)
	mat.emission_enabled = true
	mat.emission = Color(0.25, 1.0, 0.40)
	mat.emission_energy_multiplier = 1.6
	var shaft := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.035
	cyl.bottom_radius = 0.035
	cyl.height = 1.0
	shaft.mesh = cyl
	shaft.rotation.x = PI * 0.5
	shaft.position = Vector3(0, 0, -0.5)
	shaft.material_override = mat
	var head := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.09
	cone.height = 0.24
	head.mesh = cone
	head.rotation.x = -PI * 0.5
	head.position = Vector3(0, 0, -1.12)
	head.material_override = mat
	arrow.add_child(shaft)
	arrow.add_child(head)
	arrow.scale = Vector3.ONE * clampf(dist_tiles * 0.22, 0.6, 1.4)
	add_child(arrow)
	return arrow


func _medkit_fx_free(node: Node3D) -> void:
	if node != null and is_instance_valid(node):
		node.queue_free()


## 注：原 `_spawn_fragment()` 薄包装于第 97 轮 P0 清账期删除 —— 全仓零引用。
## 破片是 `ProjectileSink.rocket_fragments()` / `explode_grenade()` 里**直接**
## `Ordnance.make_fragment(...)` 造的，从来没走过这个中转。（实现仍在
## `view/projectile_sink.gd` 里，只是它自己也没被调用 —— 见那里的注释。）


## ── 箭矢弹反（杰拉尔德）：暂停时间 -> 3 次按键 -> 反弹 or 结算伤害 ──────────
## 伤害不在这里结算：GM 已经"受理"了这次弹反，判定失败时再补伤害。

func _start_arrow_qte(victim: Unit, sh: Ordnance.Shot, bonus_milli: int = 0) -> void:
	# AI 接管的一方不弹 QTE：直接按概率判定。
	# （否则自动演算/AI 对射会永远停在 get_tree().paused = true 上没人按键）
	if _is_ai_unit(victim) or ai_autoplay_player:
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
		# 用户口径第 87 轮：反弹出去的箭只吃 25% 力量（同一个 power_mult 参数，先乘再减护甲）
		var refl_mult: float = float(Passives.def("arrow_deflect").get("power_mult", 1.0))
		refl.shot.power_mult = refl_mult
		_log("  ↩ 弹反成功：%s 的箭被弹回（力量系数 %.0f%%），落点 (%.2f, %.2f)，距离 %.1f 格，散步半径 %.2f 格" % [
			shooter.name, refl_mult * 100.0, landing.x, landing.y, vpos.distance_to(spos),
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
## 实现已搬到 src/view/sentry_runner.gd；下面两个是**同名薄包装**（测试直接调它们）。

## 放出一支哨兵箭（GM 的队列决定什么时候、打哪里）
## ── 箭矢（远程普攻 / 哨兵共用）──────────────────────────────────────────────
## 弓箭是**纯物理**的：恒定速度、真实抛物线、机头永远朝着速度方向（平抛出去）。
## 伤害与落点都由发射者给（放在发射单里），弹道物本身不知道伤害。

func _spawn_arrow(attacker: Unit, from: Vector3, to: Vector3, target: Unit,
		break_armor: bool, ends_turn: bool, tint_sentry: bool = false) -> Projectile:
	var p := Ordnance.make_arrow(attacker, from, to, target, break_armor, ends_turn, tint_sentry)
	field.register(p)
	return p

## 一次炮击的结算（浮点圆心）。普攻炮击与地毯式轰炸共用这一份逻辑：
##   · 同时造成【破甲伤害】（= 攻方破甲值）与【力量伤害】
##   · 力量伤害无视 50% 物理抗性
##   · 圆沾到格子就算命中（所以圆心到格中心距离 <= BLAST_RADIUS + 0.5）
## ↓ 实现已搬到 view/projectile_sink.gd（保留同名薄包装：radius 省略时由本类的
##   BLAST_RADIUS 兜底，签名与默认值逐字未变）

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

## 角色挨打后的统一收尾：闪白、刷新指示器、判定阵亡

## ── 俯冲轰炸（主动技能）：准备 -> 俯冲 -> 停 0.5 秒投弹 -> 原路返回 ──────────
var _dive_markers: Dictionary = {}        # 单位名 -> 目标格地面标识（Node3D）
var _dive: Dictionary = {}                # 正在俯冲的状态机
var _cell_targeting: bool = false         # 正在"点格子"选技能目标（俯冲轰炸这类 aim=cell 的技能）
## 点格子类技能的【可选格】：进入选格阶段时算好，粉色高亮画出来（用户口径第 84 轮）
var cell_targets: Dictionary = {}
var _turn_watch_t: float = 0.0            # AI 回合看门狗


## 把格子钳进【可行动区域】内（用户口径：任何单位都不该跑到空场/场外去）
func _in_bounds(c: Vector2i) -> bool:
	return turn.in_bounds(c)


func _clamp_cell(c: Vector2i) -> Vector2i:
	return turn.clamp_cell(c)


## 受伤后的被动钩子表：被动表里声明 on_damaged = true 的，在这里依次执行。
## 加新被动 = Passives.DEFS 加一行 + 这里加一行，不用再改 _after_damage_to_unit。
var _passive_hooks: Dictionary = {}          # 被动 id -> Callable(u) -> bool（true = 已接管收尾）


func _init_passive_hooks() -> void:
	# ⚠️ Callable 事实接口：改名即断。坠机接管实现在 air_runner.gd（air 在 _ready 里先于本函数创建）
	_passive_hooks = {
		"heli_crash": air.hook_heli_crash,
	}


func _after_damage_to_unit(u: Unit) -> void:
	fx.flash(u)
	# 用户口径：受伤触发的被动（例：直升机力量掉到阈值以下坠机）必须挂在
	# "受伤"这条主路径上才真的会触发 —— 以前只挂在俯冲里，正常挨打永远不触发。
	for id in Passives.damaged_hooks(u):
		if _passive_hooks.has(id) and bool(_passive_hooks[id].call(u)):
			return                            # 钩子接管了后续（坠机：动画 + 死亡）
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


## 注：原 `_any_placeable_in_blast()` 于第 97 轮 P0 清账期删除 —— 全仓零引用（死代码）。
## 空爆的"要不要提前返回"判定现在在 `ProjectileSink.air_burst()` 里自己算，
## 不需要宿主提供这个查询。

## 单位阵亡统一入口：假人会自动满血复活（用户要求，方便长期测试）
## 关键：**同一单位的复活计时器只能有一个**。以前每挨一发就新建一个计时器，
## 它们各自在不同时刻把 visible 改来改去，多死几次后就会卡在"看不见"。

func _on_unit_died(u: Unit) -> void:
	turn.on_unit_died(u)


## 阵亡：清空这个角色的一切状态与 buff（用户口径）
##   · 哨兵警戒（含 GM 队列里属于他的条目）
##   · 蓄势层数、被动机会记录
##   · 挂起未结算的技能（轨道空爆标记）
func _clear_unit_states(u: Unit) -> void:
	turn.clear_unit_states(u)


## 英雄重生：满血满护甲 + 回到关卡给的固定格
##   · 测试场：地图正中、两军之间那三格
##   · 竞技场：**老国王正前方 3 格那一行**（两个公主之间居中）
## 用户口径第 87 轮：复活的人【压回自己这条队列的队头】—— 下一次轮到自己这方立刻能动。
func _revive_hero(u: Unit) -> void:
	turn.revive_hero(u)


## 复活落点 = **关卡给的英雄重生点**（用户口径第 87 轮修正）。
## 以前第一个候选是 home_cell（开局的出场格）——竞技场里那就是河边，
## 所以"重生点改到国王面前"改了关卡数据也没用，人还是回河边。现在：
##   ① 按"本阵营第几个会行动的角色"分配英雄格（三人各占一格，不挤在一起）
##   ② 那一格被占了就顺着英雄格往后找
##   ③ 全被占了才回家（出场格）—— 兜底，正常不会走到
func _revive_cell(u: Unit) -> Vector2i:
	return turn.revive_cell(u)


## 这一格上有没有别的活人（复活占位判定）
func _cell_occupied(c: Vector2i, except: Unit) -> bool:
	return turn.cell_occupied(c, except)


## 复活的人压回自己这条队列的队头（没有回合的人——国王/公主/假人——不进队列）
func _queue_revive(u: Unit) -> void:
	turn.queue_revive(u)

func _on_revive_timeout(u: Unit) -> void:
	turn.on_revive_timeout(u)


## 兜底不变式：**活着就必须看得见**。
## 复活/连死/被击落等各种路径都可能把 visible 弄错，这里每帧纠一次，成本极低。
## 当前行动者如果在自己的回合里被打死（例如被哨兵箭射死），必须立刻结束它的回合，
## 否则回合会卡在一个死人身上，永远轮不到下一位。

func _check_active_alive() -> void:
	turn.check_active_alive()

func _sync_unit_visibility() -> void:
	turn.sync_unit_visibility()


# ══════════════════════════════════════════════════════════════════════════════
# 普攻统一入口（用户要求：三条入口不许各写一套 if）
#
#   拖拽松手 _fire()  ─┐
#   点目标   _attack_target_unit() ─┼─ 都只负责"算出打哪里" -> _perform_basic()
#   AI 出手  _ai_attack()          ─┘
#
# 普攻长什么样来自 AttackProfile（近战 / 弓箭 / 连发 / 投掷 / 火箭齐射），
# 所以"加一个角色"只需要在表里加一行，三条入口自动同步 —— 不再出现
# "拖拽那条接上了、点目标那条还在打普通炮弹"这类事故。
# ══════════════════════════════════════════════════════════════════════════════

## 格子中心（浮点）：落点统一用它，避免各入口各写一份 +0.5
## 实现唯一一份在 core/grid_math.gd（Ordnance._cell_center 也曾是它的复制品）
static func _cc(c: Vector2i) -> Vector2:
	return GridMath.cell_center(c)


## 单位"现在在哪"（浮点格坐标）。**走路中的角色要用视觉位置** ——
## 逻辑格子（u.cell）在移动发起时就瞬移到终点了，视觉位置才是它当下真正所在的地方
## （用户口径第 83 轮：直升机边走边打时，火箭必须从"当前位置"出膛）。
static func _unit_pos(u: Unit) -> Vector2:
	return GridMath.unit_pos(u)


## 近战：贴上去直接结算（打角色走 Damage.strike，打沙盒走道具那条）
## 弓箭：恒定速度抛物线，命中靠碰撞判定（可能打空）。
## 高度轴（第 83 轮）：瞄角色就瞄【身体中心】—— 悬停 2 格的直升机要瞄 2.5 高，
## 否则箭从它下面穿过去（以前判定不看高度，看着就像穿模）。
## 连发（萨尼铁塔）：发数 / 间隔 / 散布全来自模板。
## 注意：连发是协程（要等间隔出膛），这里不能 await 它的返回值，直接放走即可。
## 投掷炮弹：落点吃拖拽结果，**出界也照打**（用户口径：投掷手一定要允许失误）
## 火箭齐射（直升机）：耗精力、左右开弓、发射完即结束回合，全部在 _rocket_salvo 里
## 连发实现。间隔依次出膛，**每发各自判定命中**，
## 落点吃"玩家侧线性散布"（r = 距离/12，12 格 ≈ 1 格）——所以选中目标也不一定打中。
## ↓ 这个函数体内有 await（协程），包装里也必须 await，否则调用方拿不到真正的返回值。
## 点目标前的最后一道闸（口径与 _perform_basic 里的拒绝完全一致）：
## 近战够不着空中的单位 —— 第 96 轮用户口径「近战攻击不应该能瞄准直升机」。
## 近战的高亮格：空中单位（够不着）那一格不点亮。
## 例外：那格上还站着可打的沙盒道具时保留（同一格里道具照样能砍）。
## 点目标路径（玩家）：唯一差别是"已经出手过就不再响应"。
## 打不出（精力不足）时把行动菜单还给他，别把回合卡住。
## 锁定沙盒元素（用户口径：双方英雄都能打木刺/土堆）
func _apply_attack(attacker: Unit, t: Unit, break_armor: bool,
		silent: bool = false, bonus_milli: int = 0, power_mult: float = 1.0,
		power_override: int = -1, break_override: int = -1,
		fixed_power: bool = false) -> void:
	attack.apply_attack(attacker, t, break_armor, silent, bonus_milli, power_mult,
		power_override, break_override, fixed_power)


## 箭矢"身体"判定半径等常量见 Targeting / Ordnance

func _placeable_near(pos: Vector3) -> Placeable:
	return attack.placeable_near(pos)


## 对沙盒道具结算一次普通伤害（力量线），实际计算在 Damage 里

func _damage_placeable(attacker: Unit, p: Placeable, silent: bool = false) -> void:
	attack.damage_placeable(attacker, p, silent)


# ══════════════════════════════════════════════════════════════════════════════
# 输入
# ══════════════════════════════════════════════════════════════════════════════

func _process(delta: float) -> void:
	gm.reaper_range_update(units)        # Reaper 6 格：每帧只更进出集合（不造伤）
	air.dive_tick(delta)
	air.tick_heli_fx(delta)
	air.tick_loiter_steer(delta)      # 巡飞弹：Q/E 制导（改的是这一帧的方向）


## 直升机的每帧表现（悬浮高度 / 旋翼自转 / 俯冲姿态）—— 队友交付的 HeliFx
## 只对直升机调用，其它单位零开销（HeliFx.tick 内部第一行就返回）
	fx.tick_color_cycle(delta)
	fx.tick_pending_pulse(delta)
	_sync_menu_position()          # 菜单跟着角色走
	_tick_queue_anim(delta)
	field.step(delta)              # 弹道物理：推进 / 碰撞 / 上报结果（顺带把进入射界的送进哨兵队列）
	air.tick_loiter_fuse()            # 巡飞弹近炸引信：走完这一帧再看谁进了造伤范围
	if _qte_active:
		return                     # 弹反 QTE 进行中：这一帧剩下的都别做（时间已暂停）
	air.tick_loiter_launchers(delta)  # 巡飞弹发射器：12Hz 采样"正在移动的角色"
	sentry.tick(delta)      # 哨兵：每 150ms 放一支箭打队头
	_tick_unit_walk(delta)         # 走路中的哨兵检测
	sentry_range.sync(gm.sentries) # 射界高亮跟着哨兵状态走
	_sync_unit_visibility()        # 兜底：活着就必须看得见
	_check_active_alive()         # 当前行动者在自己回合里被打死 -> 立刻结束其回合
	aim.camera_process(delta)
	# 激光类（第 98 轮）：**放在所有既有 tick 之后** —— 光速不是飞行物，它只是
	# "这一帧的光束在哪里、盖住了谁"，所以必须在弹道/哨兵/走路都推进完之后再采样，
	# 这样它看到的是本帧最终位置。累计帧伤，寿命到点的光束由模块自己统一结算。
	laser_mod.tick(delta)
	# 医疗包（第 98 轮 · 圣萨尼）：在途的绿色箭头自己慢慢飞（不进 ProjectileField）
	_tick_medkits(delta)


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
					action_menu.show_action_menu()
				elif phase == Phase.CHOOSE_TARGET:
					if _attack_menu.visible:
						_attack_menu.visible = false
					_clear_pending()
					action_menu.show_action_menu()
				return
		return

	# ── 鼠标滚轮缩放 ──
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom = clampf(_zoom - 1.5, 6.0, 30.0)
			if _zoom_slider != null:
				_zoom_slider.set_value_no_signal(_zoom)
			aim.update_camera()
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom = clampf(_zoom + 1.5, 6.0, 30.0)
			if _zoom_slider != null:
				_zoom_slider.set_value_no_signal(_zoom)
			aim.update_camera()
			return
		# ── 右键：退出当前选项，回到二级菜单 ──
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_cancel_to_menu()
			return

	# ── 瞄准中的鼠标 ──
	if _aim_active:
		if event is InputEventMouseMotion:
			aim.update_aim(event.position)
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			aim.fire()
		return

	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var cell = aim.pick_cell(event.position)
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
			# 点格子类目标：技能（俯冲轰炸）或"点格子"类普攻
			# 用户口径（第 84 轮）：粉色可选格 + **两次点击确认**（第一次出黄勾）
			if _cell_targeting:
				skills_mod.click_cell_target(cell)
				return
			# 用户口径：远程和近战【选单位都要确认】—— 第一次点只出黄勾，第二次才弹攻击菜单
			# 沙盒元素（木刺/土堆）也可以被锁定，流程一样：第一次出勾，第二次打
			var pl_t: Placeable = _placeable_at(cell) if t == null else null
			if pl_t != null and attackable.has(cell):
				if _same_pending("place", cell):
					_clear_pending()
					attack.attack_target_placeable(pl_t)
				else:
					_set_pending("place", cell, null)
					_refresh_all()
				return
			if t != null and t.side != active.side and attackable.has(cell) and attack.can_aim_unit(t):
				if _same_pending("attack", cell):
					_clear_pending()
					action_menu.show_attack_menu(t)
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
				action_menu.show_action_menu()
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
			action_menu.show_placeable_info(pl)
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
		action_menu.show_action_menu()
		return
	if _skill_menu != null and _skill_menu.visible:
		_skill_menu.visible = false
		action_menu.show_action_menu()
		return
	if _attack_menu.visible:
		_attack_menu.visible = false
		action_menu.show_action_menu()
		return
	if phase == Phase.CHOOSE_TARGET:
		_cell_targeting = false          # 点格子类目标取消后不许残留，否则下一次点地格会误放技能
		cell_targets = {}
		_aim_skill_id = ""
		_clear_pending()
		action_menu.show_action_menu()
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
	turn.do_move(u, cell)


## 走路中的哨兵检测：角色的逻辑格子是瞬移的，所以用视觉位置当作真实浮点位置。
## 用户口径："从射界外进入射界内，或者已经在射界内然后移动"都要触发。

func _tick_unit_walk(_delta: float) -> void:
	turn.tick_unit_walk(_delta)


## BFS 求一条从当前格到目标格的路径（4 邻格，避开其他单位与阻挡移动的道具）

func _path_to(u: Unit, goal: Vector2i) -> Array[Vector2i]:
	return turn.path_to(u, goal)

func _select_for_detail(u: Unit) -> void:
	_placeable_info_text = ""
	selected = u
	for x in units:
		if x.visual != null:
			x.visual.set_selected(x == u and x == active)
	if _panel != null:
		_panel.visible = (u != null)
	_refresh_all()

func _unit_at(cell: Vector2i) -> Unit:
	return turn.unit_at(cell)

func _compute_reachable(u: Unit) -> Dictionary:
	return turn.compute_reachable(u)


# ══════════════════════════════════════════════════════════════════════════════
# 高亮
# ══════════════════════════════════════════════════════════════════════════════

## 注：原 _pending_cell_mark() 全仓零引用（死代码），随本次搬迁一并删除；
## 它用到的 PendingMark / _cycle_mat 仍留在 ViewFx（彩色流动机制的备用件）。
## 每帧推进所有"待确认"高亮的颜色：hue 随时间匀速增长 -> 连续渐变

## 设定"待确认"时要染色的角色（可为 null 取消）

## 待确认可视化：一个常驻的橙色方框 + 一根上下脉动的光柱。
## 只创建一次，之后每帧只改颜色/缩放，避免"重建导致看不见"。

## 待确认的【黄勾】：两段笔画（短 + 长）组成的 ✓，外加一圈加法混合的柔光。
## 用户口径：发亮的黄勾、必须正对摄像机（不能斜）—— 每帧抄摄像机的 basis。
## 只画勾，不填充格子；格子本身的橙框仍然由 _pending_mats 负责。

## 黄勾朝向：永远和屏幕平行（正对摄像机），并且轻轻呼吸
## 每帧让待确认标记呼吸：格子橙框在橙<->黄之间脉动，黄勾同步呼吸并保持正对摄像机

## 鼠标当前指向的格子（无有效指向返回 null）

## 角色被击中时的白闪（实现在 view/view_fx.gd）
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
	turn.revive_unit(u)


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


## ⚠️ 跨模块事实接口（**别删**）：battle_ui.gd（道具箱按钮） 正在通过 `_st.ui_place_left` 调它。
## 删掉这个同名包装 = 对方在运行时报 Nonexistent function（编译期查不出来）。
func ui_place_left() -> Dictionary:
	return sandbox.ui_place_left()


## ⚠️ 跨模块事实接口（**别删**）：battle_ui.gd 正在通过 `_st.ui_place_kind` 调它。
## 删掉这个同名包装 = 对方在运行时报 Nonexistent function（编译期查不出来）。
func ui_place_kind() -> String:
	return sandbox.ui_place_kind()


## ⚠️ 跨模块事实接口（**别删**）：battle_ui.gd 正在通过 `_st.ui_is_placing` 调它。
## 删掉这个同名包装 = 对方在运行时报 Nonexistent function（编译期查不出来）。
func ui_is_placing() -> bool:
	return sandbox.ui_is_placing()


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
			action_menu.push_unit_stats(u)
			return ok
	return false


func ui_dbg_reset(u: Unit) -> void:
	if u == null:
		return
	_log("[调试] %s 的字段已还原为当前真实数值" % u.name)
	action_menu.push_unit_stats(u)

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
		action_menu.show_action_menu()
		return
	_select_for_detail(u)
	if from_queue:
		pass                              # 从队列表点进来只做选中，不再往日志里写提示
	elif u.is_manual() and u == active:
		action_menu.show_action_menu()


func ui_click_blank() -> void:
	_on_blank_click()


func ui_move() -> void:
	action_menu.menu_move()


func ui_attack() -> void:
	action_menu.menu_attack()


func ui_skill() -> void:
	skills_mod.menu_skill()


func ui_rest() -> void:
	action_menu.menu_rest()


func ui_end_turn() -> void:
	_on_next_pressed()


## ⚠️ 跨模块事实接口（**别删**）：battle_ui.gd 正在通过 `_st.ui_pick_place` 调它。
## 删掉这个同名包装 = 对方在运行时报 Nonexistent function（编译期查不出来）。
func ui_pick_place(nm: String) -> void:
	sandbox.ui_pick_place(nm)


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
	aim.update_camera()


func ui_pick_skill(id: String) -> void:
	skills_mod.choose_skill(id)


func ui_confirm_attack(break_armor: bool) -> void:
	action_menu.confirm_attack(break_armor)


func ui_cancel() -> void:
	_cancel_to_menu()


func ui_upgrade(u: Unit, key: String) -> void:
	if Rules.apply_point(u, key):
		action_menu.push_unit_stats(u)


func ui_reset_upgrades(u: Unit) -> void:
	Rules.reset_points(u)
	action_menu.push_unit_stats(u)


## 打开攻击菜单（用户口径：不再有"投入精力加伤害"，预览就是纯力量对护甲）
func ui_open_attack_menu(t: Unit) -> void:
	if ui != null:
		ui.show_attack_menu(t)


## 直升机脚下的圆形阴影（跟随移动，越高越淡越大）
var _heli_shadows: Dictionary = {}


# ══════════════════════════════════════════════════════════════════════════════
# 测试 / 探针专用接口（t_*）—— **不是游戏逻辑**
#
# 谁用：只有 tools/playtest.gd 与 tools/probe_*.gd。
# 游戏本体（src/ 下的任何代码）不许调用这里的方法 —— 它们是给测试的稳定契约，
# 不参与"重构时怎么改内部结构"的自由度：内部怎么搬，t_* 的名字与语义都不变。
#
# 为什么要有这一层：测试过去直接摸 `_s._私有成员`，导致
#   · 内部一改名/一搬模块，测试就炸；
#   · battle_scene 里为了"测试还能调"被迫留着薄包装，行数永远降不下来。
# 现在测试只认 t_*：读 = t_xxx()，写 = t_set_xxx(v)。
#
# 约束（与 tools 侧一一对应）：
#   · 只暴露"测试真的用到的"成员，不预先扩大；
#   · 不暴露可变字段本身（否则收口没意义）；
#   · 与私有成员同名不同前缀：t_foo() -> _foo；t_set_foo(v) -> _foo = v；
#   · 被 await 的私有协程，t_* 必须同样 await（否则调用方不再等待）。
# ══════════════════════════════════════════════════════════════════════════════

func t_debug_log() -> Array[String]:
	return _debug_log

func t_grenade_models() -> Dictionary:
	return _grenade_models

func t_turn_just_finished() -> Unit:
	return _turn_just_finished

func t_set_turn_just_finished(v: Unit) -> void:
	_turn_just_finished = v

func t_action_menu() -> PanelContainer:
	return _action_menu

func t_set_action_menu(v: PanelContainer) -> void:
	_action_menu = v

func t_pending_root() -> Node3D:
	return _pending_root

func t_on_unit_died(u: Unit) -> void:
	turn.on_unit_died(u)

func t_show_action_menu() -> void:
	action_menu.show_action_menu()

func t_attack_target_unit(t: Unit, break_armor: bool) -> void:
	attack.attack_target_unit(t, break_armor)

func t_menu_attack() -> void:
	action_menu.menu_attack()

func t_pending_kind() -> String:
	return _pending_kind

func t_spawn_arrow(attacker: Unit, from: Vector3, to: Vector3, target: Unit,
		break_armor: bool, ends_turn: bool, tint_sentry: bool = false) -> Projectile:
	return _spawn_arrow(attacker, from, to, target, break_armor, ends_turn, tint_sentry)

func t_aim_active() -> bool:
	return _aim_active

func t_set_aim_active(v: bool) -> void:
	_aim_active = v

func t_attack_menu() -> PanelContainer:
	return _attack_menu

func t_set_attack_menu(v: PanelContainer) -> void:
	_attack_menu = v

func t_draw_hints() -> void:
	fx.draw_hints()

func t_revive_hero(u: Unit) -> void:
	turn.revive_hero(u)

func t_spawn_shell(caster: Unit, to: Vector2, ends_turn: bool,
		pre: float = 0.0, group: String = "", blast_r: float = Ordnance.DEFAULT_BLAST_R) -> Projectile:
	return _spawn_shell(caster, to, ends_turn, pre, group, blast_r)

func t_btn_power() -> Button:
	return _btn_power

func t_loiter_pick_control() -> Projectile:
	return air.loiter_pick_control()

func t_btn_attack() -> Button:
	return _btn_attack

func t_cam_focus() -> Vector3:
	return _cam_focus

func t_set_cam_focus(v: Vector3) -> void:
	_cam_focus = v

func t_queue_alternation_ok() -> bool:
	return turn.queue_alternation_ok()

func t_tick_loiter_launchers(delta: float) -> void:
	air.tick_loiter_launchers(delta)

func t_update_camera() -> void:
	aim.update_camera()

func t_aim_skill_id() -> String:
	return _aim_skill_id

func t_set_aim_skill_id(v: String) -> void:
	_aim_skill_id = v

func t_btn_rest_menu() -> Button:
	return _btn_rest_menu

func t_clear_pending() -> void:
	sandbox.clear_pending()

func t_place_at(c: Vector2i) -> void:
	sandbox.place_at(c)

func t_place_kind() -> String:
	return _place_kind

func t_set_place_kind(v: String) -> void:
	_place_kind = v

func t_set_pending(kind: String, cell: Vector2i, actor: Unit = null) -> void:
	sandbox.set_pending(kind, cell, actor)

func t_zoom() -> float:
	return _zoom

func t_set_zoom(v: float) -> void:
	_zoom = v

func t_ai_turn() -> bool:
	return _ai_turn

func t_set_ai_turn(v: bool) -> void:
	_ai_turn = v

func t_cell_targeting() -> bool:
	return _cell_targeting

func t_set_cell_targeting(v: bool) -> void:
	_cell_targeting = v

func t_choose_skill(id: String) -> void:
	skills_mod.choose_skill(id)

func t_clamp_cell(c: Vector2i) -> Vector2i:
	return turn.clamp_cell(c)

func t_click_cell_target(cell: Vector2i) -> bool:
	return skills_mod.click_cell_target(cell)

func t_do_move(u: Unit, cell: Vector2i) -> void:
	turn.do_move(u, cell)

func t_in_bounds(c: Vector2i) -> bool:
	return turn.in_bounds(c)

func t_last_flash() -> Node3D:
	return _last_flash

func t_loiter_steer_apply(p: Projectile, dir: float, delta: float) -> void:
	air.loiter_steer_apply(p, dir, delta)

func t_salvo_dbg() -> Dictionary:
	return _salvo_dbg

static func t_unit_pos(u: Unit) -> Vector2:
	return _unit_pos(u)

func t_after_damage_to_unit(u: Unit) -> void:
	_after_damage_to_unit(u)

func t_ai_attack(u: Unit, plan: Dictionary) -> void:
	ai.ai_attack(u, plan)

func t_aim_float_pos() -> Vector2:
	return _aim_float_pos

func t_set_aim_float_pos(v: Vector2) -> void:
	_aim_float_pos = v

func t_aim_now() -> Vector2:
	return _aim_now

func t_set_aim_now(v: Vector2) -> void:
	_aim_now = v

func t_aim_origin() -> Vector2:
	return _aim_origin

func t_set_aim_origin(v: Vector2) -> void:
	_aim_origin = v

func t_aim_valid() -> bool:
	return _aim_valid

func t_set_aim_valid(v: bool) -> void:
	_aim_valid = v

func t_btn_break() -> Button:
	return _btn_break

func t_can_aim_unit(t: Unit) -> bool:
	return attack.can_aim_unit(t)

func t_can_place_at(c: Vector2i) -> bool:
	return sandbox.can_place_at(c)

func t_check_last_stand() -> bool:
	return turn.check_last_stand()

func t_check_mats() -> Array:
	return _check_mats

func t_dive_begin(u: Unit) -> bool:
	return air.dive_begin(u)

func t_dive_clear(u: Unit) -> void:
	skills_mod.dive_clear(u)

func t_finish_placement() -> void:
	sandbox.finish_placement()

func t_fire() -> void:
	aim.fire()

func t_fire_loiter(pl: Placeable, ctr: Vector2, tgt: Unit) -> void:
	air.fire_loiter(pl, ctr, tgt)

func t_gm_busy() -> bool:
	return _gm_busy

func t_passive_hooks() -> Dictionary:
	return _passive_hooks

func t_pending_cell() -> Vector2i:
	return _pending_cell

func t_planned_cell() -> Vector2i:
	return _planned_cell

func t_set_planned_cell(v: Vector2i) -> void:
	_planned_cell = v

func t_ranged_blocked_at(c: Vector2i, by_thrower: bool) -> bool:
	return sandbox.ranged_blocked_at(c, by_thrower)

func t_resolve_mortar_impact(attacker: Unit, center: Vector2i) -> void:
	sink.resolve_mortar_impact(attacker, center)

func t_same_pending(kind: String, cell: Vector2i) -> bool:
	return sandbox.same_pending(kind, cell)

func t_select_for_detail(u: Unit) -> void:
	_select_for_detail(u)

func t_show_attack_menu(t: Unit) -> void:
	action_menu.show_attack_menu(t)

func t_skill_menu() -> PanelContainer:
	return _skill_menu

func t_set_skill_menu(v: PanelContainer) -> void:
	_skill_menu = v

func t_ai_ctx(u: Unit) -> Ai.Ctx:
	return ai.ai_ctx(u)

func t_aim_range(t: float) -> float:
	return aim.aim_range(t)

func t_air_burst(p: Projectile, why: String = "被打爆") -> void:
	sink.air_burst(p, why)

func t_arrow_len_for_t(t: float) -> float:
	return aim.arrow_len_for_t(t)

func t_arrow_root() -> Node3D:
	return _arrow_root

func t_set_arrow_root(v: Node3D) -> void:
	_arrow_root = v

func t_attack_target_placeable(pl: Placeable) -> void:
	attack.attack_target_placeable(pl)

func t_blocked_cells() -> Dictionary:
	return sandbox.blocked_cells()

func t_btn_next() -> Button:
	return _btn_next

func t_cast_dive(u: Unit, cell: Vector2i) -> void:
	skills_mod.cast_dive(u, cell)

func t_cast_sentry(caster: Unit) -> void:
	skills_mod.cast_sentry(caster)

func t_charge_from_drag(px: float) -> float:
	return aim.charge_from_drag(px)

func t_check_heli_crash(u: Unit) -> bool:
	return air.check_heli_crash(u)

func t_clear_selection() -> void:
	_clear_selection()

func t_compute_reachable(u: Unit) -> Dictionary:
	return turn.compute_reachable(u)

func t_dive_markers() -> Dictionary:
	return _dive_markers

func t_dive_tick(delta: float) -> void:
	air.dive_tick(delta)

func t_explode_grenade(p: GameMaster.Pending) -> void:
	sink.explode_grenade(p)

func t_find_arrow_qte() -> ArrowQTE:
	return _find_arrow_qte()

func t_finish_turn() -> void:
	await _finish_turn()

func t_gm_step() -> void:
	await ai.gm_step()

func t_menu_move() -> void:
	action_menu.menu_move()

func t_next_turn() -> void:
	await turn.next_turn()

func t_on_proj_landed(p: Projectile) -> void:
	sink.on_proj_landed(p)

func t_panel() -> PanelContainer:
	return _panel

func t_path_to(u: Unit, goal: Vector2i) -> Array[Vector2i]:
	return turn.path_to(u, goal)

func t_perform_skill(u: Unit, sid: String, aim: Vector2, cell: Vector2i) -> bool:
	return skills_mod.perform_skill(u, sid, aim, cell)

func t_pick_place_kind(nm: String) -> void:
	sandbox.pick_place_kind(nm)

func t_rocket_salvo(u: Unit, fpos: Vector2) -> void:
	await _rocket_salvo(u, fpos)

func t_skill_info_text() -> String:
	return _skill_info_text

func t_set_skill_info_text(v: String) -> void:
	_skill_info_text = v

func t_spawn_grenade_model(cell: Vector2i, p: Projectile) -> void:
	sink.spawn_grenade_model(cell, p)

func t_spawn_grenade_shot(u: Unit, aim: Vector2, sid: String) -> Projectile:
	return skills_mod.spawn_grenade_shot(u, aim, sid)

func t_tick_loiter_fuse() -> void:
	air.tick_loiter_fuse()

func t_ai_move(u: Unit, cell: Vector2i, wait: bool = true) -> void:
	await ai.ai_move(u, cell, wait)

func t_ai_skill(u: Unit, plan: Dictionary) -> void:
	ai.ai_skill(u, plan)

func t_begin_aim() -> void:
	aim.begin_aim()

func t_btn_end_turn() -> Button:
	return _btn_end_turn

func t_cam_yaw() -> float:
	return _cam_yaw

func t_camera() -> Camera3D:
	return _camera

func t_cancel_to_menu() -> void:
	_cancel_to_menu()

static func t_cc(c: Vector2i) -> Vector2:
	return _cc(c)

func t_check_root() -> Node3D:
	return _check_root

func t_clear_pylons() -> void:
	skills_mod.clear_pylons()

func t_confirm_attack(break_armor: bool) -> void:
	action_menu.confirm_attack(break_armor)

func t_confirm_cell_target(cell: Vector2i) -> bool:
	return skills_mod.confirm_cell_target(cell)

func t_face_check_mark() -> void:
	fx.face_check_mark()

func t_fire_cannon_ai(u: Unit, ends_turn: bool = true) -> void:
	ai.fire_cannon_ai(u, ends_turn)

func t_hint_layer() -> Node3D:
	return _hint_layer

func t_holy_sani_check(u: Unit) -> void:
	_holy_sani_check(u)

func t_is_ai_unit(u: Unit) -> bool:
	return ai.is_ai_unit(u)


## AI 开关的测试门面（P4：字段已从 GameMaster 迁到本类）
func t_ai_enabled() -> bool:
	return ai_enabled


func t_set_ai_enabled(v: bool) -> void:
	ai_enabled = v


func t_autoplay_player() -> bool:
	return ai_autoplay_player


func t_set_autoplay_player(v: bool) -> void:
	ai_autoplay_player = v

func t_menu_rest() -> void:
	action_menu.menu_rest()

func t_on_blank_click() -> void:
	_on_blank_click()

func t_pending_mats() -> Array:
	return _pending_mats

func t_perform_basic(u: Unit, aim: Vector2, target: Unit = null, placeable: Placeable = null,
		break_armor: bool = false, guard_acted: bool = false) -> bool:
	return attack.perform_basic(u, aim, target, placeable, break_armor, guard_acted)

func t_proj_collision(p: Projectile) -> Projectile:
	return sink.proj_collision(p)

func t_qte_active() -> bool:
	return _qte_active

func t_refresh_all() -> void:
	_refresh_all()

func t_salvo_u() -> Unit:
	return _salvo_u

func t_shell_intercepted(p: Projectile, why: String) -> void:
	sink.shell_intercepted(p, why)

func t_spawn_marker(caster: Unit, to: Vector2) -> Projectile:
	return sink.spawn_marker(caster, to)

func t_start_carpet_bomb(caster: Unit, center: Vector2) -> void:
	skills_mod.start_carpet_bomb(caster, center)

func t_sync_unit_visibility() -> void:
	turn.sync_unit_visibility()

func t_tick_pending_pulse(delta: float) -> void:
	fx.tick_pending_pulse(delta)


# ══════════════════════════════════════════════════════════════════════════════
# Reaper（Boss-3）回合执行入口：召唤 / 横扫 / 竖切 三循环 + 每回合前移一格
#
# 决策与几何全在 core/reaper.gd（纯函数）；这里只负责"演出 + 真的改场上状态"。
# 三循环状态在 GameMaster.reaper_cycle（跨回合调度状态，不埋在 view 里）。
#
# ⚠️ 激光打桩（第 1 版）：mod-sentry-2 的 core/laser.gd + `t_spawn_laser` 尚未交付，
#    所以本版把每条光束的**起终点/角度/覆盖帧数/伤害**算出来记进 `_reaper_laser_log`
#    （探针可读），并按**同一个帧模型**直接结算伤害，不生成光束节点。
#    他交付后 `_spawn_reaper_laser()` / `_reaper_apply_beam()` 两处换成真调用即可。
# ══════════════════════════════════════════════════════════════════════════════
## 打桩期记录的光束规格（探针读它验证"本该发射什么"）
var _reaper_laser_log: Array = []
## 环色（真模型未就绪时由本变量兜底；就绪后同步给 t_set_reaper_ring）
var _reaper_ring_color := Color(0.25, 0.55, 1.0)
const REAPER_RING_IDLE := Color(0.25, 0.55, 1.0)


## Reaper 的一个回合：① 向前一格 ② 按三循环做一件事 ③ 结束回合
func reaper_take_turn(u: Unit) -> void:
	var step := gm.reaper_advance_cycle(u)
	var mv := Reaper.plan_forward(u, units)
	if bool(mv["moved"]):
		var to: Vector2i = mv["cell"]
		u.cell = to
		if u.visual != null:
			u.visual.position = Vector3(float(to.x) + 0.5, u.visual.position.y, float(to.y) + 0.5)
		_log("  👁 Reaper 向前移动一格 → %s" % str(to))
	else:
		_log("  👁 Reaper 停在原地：%s" % String(mv["blocked"]))
	_log("  👁 Reaper 回合【%s】（三循环）" % Reaper.step_name(step))
	match step:
		Reaper.Step.SUMMON:
			await _reaper_do_summon(u)
		Reaper.Step.SWEEP:
			await _reaper_laser_volley(u, false)
		Reaper.Step.SLICE:
			await _reaper_laser_volley(u, true)
	_finish_turn()


## 环色：真模型就绪后自动改走 mod-sentry 的门面（has_method 守卫，两边都不用改）
func _set_reaper_ring(u: Unit, c: Color) -> void:
	_reaper_ring_color = c
	if c == Color.RED:
		_reaper_saw_red = true               # 探针用：确实进过"红环预警"
	if has_method("t_set_reaper_ring"):
		call("t_set_reaper_ring", u, c)


func reaper_ring_color() -> Color:
	return _reaper_ring_color


## 探针用：这一回合是否真的进过"红环预警"（预警是 await 出来的，外面采样不到）
var _reaper_saw_red := false


func t_reaper_saw_red() -> bool:
	return _reaper_saw_red


func t_reaper_reset_saw_red() -> void:
	_reaper_saw_red = false


## 花名册查定义（召唤用；不能新建数据行，所以复用现成单位）
func _roster_def(nm: String) -> Dictionary:
	for arr in [UnitData.UNITS, UnitData.ENEMIES]:
		for d in arr:
			if String(d["name"]) == nm:
				return d
	return {}


## 召唤回合：二选一（确定性随机）→ 在 Reaper 周围一圈找空格 → 造敌方单位
func _reaper_do_summon(u: Unit) -> void:
	var kit: Dictionary = Reaper.SUMMON_KITS[rng.next_int(Reaper.SUMMON_KITS.size())]
	var names: Array = kit["names"]
	var cells := Reaper.summon_cells(u, units, names.size())
	_log("  👁 召唤【%s】：%d 个落点" % [kit["desc"], cells.size()])
	for i in cells.size():
		var nm := String(names[i])
		var d := _roster_def(nm)
		if d.is_empty():
			_log("      ⚠ 花名册里没有 %s，跳过" % nm)
			continue
		var s := Unit.from_data(d)
		s.side = u.side                       # 召唤物一律**敌方阵营**（源数据可能是 PLAYER）
		s.cell = cells[i]
		s.home_cell = cells[i]
		units.append(s)
		var v := UnitVisual.new()
		add_child(v)
		v.setup(s)
		_log("      + %s @ %s（阵营 %d）" % [s.name, str(s.cell), s.side])


## 横扫 / 竖切共用：红环预警 2 秒 → 逐条发（打桩）/ 发真激光 → 蓝环
func _reaper_laser_volley(u: Unit, slice: bool) -> void:
	var tgt := Reaper.nearest_enemy(u, units)
	if tgt == null:
		_log("  ⚠ 场上没有敌人，Reaper 这一击落空")
		return
	var tp := GridMath.unit_pos(tgt)
	_set_reaper_ring(u, Color.RED)
	_log("  👁 环变红，预警 %.1f 秒（目标 %s）" % [Reaper.WARN_SEC, tgt.name])
	await get_tree().create_timer(Reaper.WARN_SEC).timeout
	var steps := 12
	var secs: float = Reaper.SLICE_SEC if slice else Reaper.SWEEP_SEC
	var specs: Array = Reaper.slice_specs(u, tp, steps, tgt) if slice \
			else Reaper.sweep_specs(u, tp, steps, tgt)
	_log("  👁 %s：%d 条光束，总 %.1f 秒" % ["竖切" if slice else "横扫", specs.size(), secs])
	for sp in specs:
		_spawn_reaper_laser(u, sp)
		await get_tree().create_timer(secs / float(steps)).timeout
	_set_reaper_ring(u, REAPER_RING_IDLE)


## 真激光（docs-keeper task-15 已交付）：直接调宿主门面 t_spawn_laser。
## ⚠️ 打桩期的"自制命中判定 + 直接扣血"**已删除** —— 真激光会在 _process 里每帧累计、
##    寿命到/被打断时统一结算；留着会**双倍结算**（docs-keeper 报过）。
##    命中判定在 laser.gd（三维线段 vs 单位竖直圆柱，半径走 Targeting.unit_body_r）。
##    `_reaper_laser_log` 只留给探针观测"本该发射什么"。
func _spawn_reaper_laser(u: Unit, sp: Dictionary) -> void:
	_reaper_laser_log.append(sp)
	t_spawn_laser("reaper_laser", sp["from"], sp["to"])


## 点到线段的距离（判定"这一格有没有被这条光束扫到"）
static func _point_seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 0.0001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


# ── 测试/探针门面（t_*）：Reaper 相关 ──
func t_reaper_take_turn(u: Unit) -> void:
	await reaper_take_turn(u)


func t_reaper_step(u: Unit) -> int:
	return gm.reaper_step_for(u)


func t_reaper_ring_color() -> Color:
	return reaper_ring_color()


func t_reaper_laser_log() -> Array:
	return _reaper_laser_log


func t_reaper_clear_laser_log() -> void:
	_reaper_laser_log.clear()


func t_reaper_passive_tick() -> Array[Unit]:
	return gm.reaper_passive_tick(units, rng)


# ── Reaper 模型（reaper_model.gd）的测试门面 ─────────────────────────────────
# 激光预警的调用链是：_reaper_laser_volley -> _set_reaper_ring(u, RED)
#   -> call("t_set_reaper_ring", u, c)  （mod-fx 留的扩展点，用字符串 call）
# 这里把它接到真模型上：红 2 秒 -> 打完调回蓝。

## 找这个单位身上挂的 ReaperModel（UnitVisual 的子节点）。不是 Reaper / 还没建模就返回 null。
func _reaper_model_of(u: Unit) -> ReaperModel:
	if u == null or u.visual == null:
		return null
	return u.visual.find_child("ReaperModel", true, false) as ReaperModel


## 激光预警：把环染成 c（红）。**名字是 mod-fx 已经 call() 好的，别改名。**
func t_set_reaper_ring(u: Unit, c: Color) -> void:
	var m := _reaper_model_of(u)
	if m != null:
		m.set_ring_color(c)


## 真模型上环的颜色（0 参的 t_reaper_ring_color() 读的是宿主的兜底变量，不是模型）
func t_reaper_ring_color_of(u: Unit) -> Color:
	var m := _reaper_model_of(u)
	return Color.BLACK if m == null else m.ring_color()


# ══════════════════════════════════════════════════════════════════════════════
# 测试 / 探针门面（t_*）：激光类（第 98 轮 · Boss-1）
#
# 契约（名字别改，Reaper AI / 探针都按这个调）：
#   t_spawn_laser(id, a, b) -> LaserBeam     发一条激光（终点先按地形截断）
#   t_laser_count() -> int                   在途激光数
#   t_laser_frames(id_or_beam) -> Dictionary 帧数表（String = 合并同 id；LaserBeam = 自己那条）
#   t_settle_all_lasers() -> Array           把在途激光全部统一结算，返回 Array[Damage.Hit]
#   t_laser_clip(a, b) -> Vector2            地形截断（a/b 是水平坐标 Vector2）
# ══════════════════════════════════════════════════════════════════════════════

func t_spawn_laser(id: String, a: Vector3, b: Vector3) -> LaserBeam:
	return laser_mod.spawn(id, a, b)


func t_laser_count() -> int:
	return laser_mod.count()


func t_laser_frames(id_or_beam) -> Dictionary:
	return laser_mod.frames(id_or_beam)


func t_settle_all_lasers() -> Array:
	return laser_mod.settle_all()


func t_laser_clip(a: Vector2, b: Vector2) -> Vector2:
	return Laser.clip_by_terrain(a, b, placeables, GW, GH)


# ══════════════════════════════════════════════════════════════════════════════
# 测试 / 探针门面（t_*）：医疗包（第 98 轮 · 圣萨尼）
#
#   t_sani_medkit_count() -> int     在途医疗包数
#   t_sani_heal_roll() -> String     最近一次选中的目标名（""= 没投）
#   t_sani_throw_medkit() -> void    立刻走一次真实投掷路径（= 她的回合开始那一下）
#   t_tick_medkits(delta) -> void    手工推进在途医疗包（探针关掉 _process 后自己推）
# ══════════════════════════════════════════════════════════════════════════════

func t_sani_medkit_count() -> int:
	return _medkits.size()


func t_sani_heal_roll() -> String:
	return _sani_heal_roll


func t_sani_throw_medkit() -> void:
	for u in units:
		if u.name == "萨尼铁塔" and u.is_alive():
			_holy_sani_check(u)
			return
	for u in units:                                  # 敌方镜像兜底
		if Unit.base_name(u.name) == "萨尼铁塔" and u.is_alive():
			_holy_sani_check(u)
			return


func t_tick_medkits(delta: float) -> void:
	_tick_medkits(delta)

