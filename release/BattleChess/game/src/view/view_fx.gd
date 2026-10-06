# ══════════════════════════════════════════════════════════════════════════════
# 表现层模块：格子高亮 / 待确认标记（橙框 + 黄勾）/ 落点红圈 / 球状闪光 / 角色闪白。
#
# 形态：RefCounted + 构造注入宿主（battle_scene），模块内一律用 _st.xxx 显式访问宿主状态。
#
# 状态归属（刻意的划分）：
#   · 宿主仍持有 _hint_layer / _impact_ring / _pending_root / _pending_mats /
#     _check_root / _check_mats / _last_flash 这几个引用 —— playtest / probe 直接读它们
#     （例：playtest 数 _hint_layer.get_children()、读 _s._last_flash）。
#     节点由本模块创建，宿主只是"指向同一个对象"。
#   · 本模块自己持有 _cycle_time / _pending_marks / _pending_actor(_on) / _pulse_t /
#     _impact_tw —— 这几个在宿主之外没有任何读取方。
#
# 行为零变化：函数体都是从 battle_scene.gd 原样搬过来的，只做两种改写：
#   _xxx        -> _st._xxx      （宿主成员）
#   _xxx        -> _xxx          （本模块成员）
# add_child / create_tween / _hover_cell / _can_place_at / Phase 枚举 一律通过 _st 走。
# 宿主保留同名薄包装（_draw_hints() -> fx.draw_hints()），所以 playtest 的上千处
# _s.xxx 私有访问与反射调用全部照旧。
# ══════════════════════════════════════════════════════════════════════════════
class_name ViewFx
extends RefCounted

## 宿主 BattleScene。**故意不加静态类型**：宿主没有 class_name，若静态写成 Node3D，
## _st.phase / _st.reachable / _st.Phase.PLACE 全部会在分析期报错
## （同 BattleUI.host 的处理，见 battle_ui.gd:27）。
var _st = null

# ── 只属于表现层、宿主/测试都不直接读的状态 ──
var _cycle_time: float = 0.0           # 彩色流动（待确认可视化）计时
var _pending_marks: Array = []         # [PendingMark]
var _pending_actor: Unit = null        # 待确认时被染色的角色
var _pending_actor_on: bool = false
var _pulse_t: float = 0.0              # 待确认标记的呼吸相位
var _impact_tw: Tween = null           # 红圈淡出动画（重开时必须 kill 掉旧的）


## 待确认高亮的一个格子（填充 + 描边，都用流动彩色）
class PendingMark extends RefCounted:
	var fill: MeshInstance3D
	var edge: MeshInstance3D
	var phase: float = 0.0


## 接口契约仍是 Node3D（和 SentryRunner 一致）；只有 _st 这个**成员**变量必须是动态类型，
## 否则 _st.phase / _st.reachable / _st.Phase.PLACE 会在分析期报 Cannot find member。
func _init(host: Node3D) -> void:
	_st = host


# ══════════════════════════════════════════════════════════════════════════════
# 节点工厂：节点由本模块造，但引用的所有权留在宿主（测试直接读宿主字段）
#
# 宿主挂载方式（见 battle_scene._build_aim_helpers）：
#   _impact_ring = fx.make_impact_ring_node(BLAST_RADIUS); add_child(_impact_ring)
#   _hint_layer  = fx.make_hint_layer_node();              add_child(_hint_layer)
# ══════════════════════════════════════════════════════════════════════════════

## 落点范围圈（落地后才出现，表示 impact 范围）。
## 半径由宿主传入 BLAST_RADIUS —— 与命中判定完全一致，所以"红圈沾到格子 = 命中"是真的。
func make_impact_ring_node(radius: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = radius
	disc.bottom_radius = radius
	disc.height = 0.04
	mi.mesh = disc
	var im := StandardMaterial3D.new()
	im.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	im.albedo_color = Color(1.0, 0.22, 0.20, 0.45)
	im.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = im
	mi.visible = false
	return mi


## 高亮层：所有格子高亮都挂在它底下（playtest 靠数它的子节点来数高亮格）
func make_hint_layer_node() -> Node3D:
	var n := Node3D.new()
	n.name = "Hints"
	return n


# ══════════════════════════════════════════════════════════════════════════════
# 高亮
# ══════════════════════════════════════════════════════════════════════════════

func clear_hints() -> void:
	if _st._hint_layer == null:
		return
	for c in _st._hint_layer.get_children():
		c.queue_free()
	# 高亮重建后，旧的 PendingMark 引用就失效了，必须一起清掉
	# （否则下一帧 tick_color_cycle 会去改已释放节点的材质）
	_pending_marks.clear()


## 造一个"彩色流动"的格子高亮材质：半透明底色，颜色每帧由 tick_color_cycle 填。
func cycle_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(1, 1, 1, 0.5)
	return m


## 每帧推进所有"待确认"高亮的颜色：hue 随时间匀速增长 -> 连续渐变
func tick_color_cycle(delta: float) -> void:
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
func set_pending_actor(u: Unit) -> void:
	if _pending_actor != null and _pending_actor.visual != null \
			and _pending_actor != u:
		(_pending_actor.visual as UnitVisual).set_cycle_ring(null)
	_pending_actor = u
	_pending_actor_on = u != null
	if u != null and u.visual != null:
		(u.visual as UnitVisual).set_cycle_ring(ColorCycle.edge_at(_cycle_time, 0.0, 0.95))


func draw_hints() -> void:
	clear_hints()
	# 放置阶段：鼠标悬停格显示绿色/红色占位框
	if _st.phase == _st.Phase.PLACE and _st._place_kind != "":
		var hc: Variant = _st._hover_cell()
		if hc != null:
			var hcv: Vector2i = hc
			hint_cell(hcv, Color(0.30, 1.00, 0.45, 0.42) if _st._can_place_at(hcv)
				else Color(1.00, 0.25, 0.25, 0.42))
	# 可移动格：只有在"有单位被选定"且处于菜单阶段才显示（蜘蛛绿）
	if (_st.phase == _st.Phase.MENU or _st.phase == _st.Phase.MOVE_CONFIRM) \
			and _st.selected != null and _st.selected == _st.active:
		for cell in _st.reachable.keys():
			hint_cell(cell, Color(0.22, 0.62, 0.20, 0.34))
	# 可攻击范围（紫色）
	for cell in _st.attackable.keys():
		hint_cell(cell, Color(0.62, 0.28, 0.92, 0.38))
	# 点格子类技能的可选格（粉色，用户口径第 84 轮）
	for cell in _st.cell_targets.keys():
		hint_cell(cell, Color(1.00, 0.36, 0.82, 0.40))
	# ── 待确认：用"常驻的一根脉冲灯柱 + 橙色描边格"表示 ──
	# 之前的彩色流动方案依赖每帧重建 mesh，实测看不见；改成常驻节点 + 直接改材质色。
	update_pending_visual()


## 待确认可视化：一个常驻的橙色方框 + 一根上下脉动的光柱。
## 只创建一次，之后每帧只改颜色/缩放，避免"重建导致看不见"。
func update_pending_visual() -> void:
	var on: bool = _st._pending_kind != "" and _st._pending_cell.x >= 0
	if _st._pending_root == null:
		_st._pending_root = Node3D.new()
		_st._pending_root.name = "PendingMark"
		_st.add_child(_st._pending_root)
		# 方框：四根细柱围成一圈
		_st._pending_mats.clear()
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
			_st._pending_root.add_child(mi)
			_st._pending_mats.append(m)
		# 黄勾取代了旧的光柱：两根竖线叠在一起会看成"叉"，用户要的就是一个勾
		build_check_mark()
	if not on or _st._pending_cell.x < 0:
		_st._pending_root.visible = false
		return
	_st._pending_root.visible = true
	_st._pending_root.position = Vector3(float(_st._pending_cell.x) + 0.5, 0.0, float(_st._pending_cell.y) + 0.5)


## 待确认的【黄勾】：两段笔画（短 + 长）组成的 ✓，外加一圈加法混合的柔光。
## 用户口径：发亮的黄勾、必须正对摄像机（不能斜）—— 每帧抄摄像机的 basis。
## 只画勾，不填充格子；格子本身的橙框仍然由 _pending_mats 负责。
func build_check_mark() -> void:
	_st._check_root = Node3D.new()
	_st._check_root.name = "CheckMark"
	_st._pending_root.add_child(_st._check_root)
	_st._check_mats.clear()
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
			_st._check_root.add_child(mi)
			_st._check_mats.append(m)


## 黄勾朝向：永远和屏幕平行（正对摄像机），并且轻轻呼吸
func face_check_mark() -> void:
	if _st._check_root == null or _st._camera == null or _st._pending_root == null:
		return
	var k: float = 0.5 + 0.5 * sin(_pulse_t * 6.0)
	var t: Transform3D = _st._check_root.global_transform
	t.basis = _st._camera.global_transform.basis.scaled(Vector3.ONE * (1.35 + 0.14 * k))
	t.origin = _st._pending_root.global_position + Vector3(0.0, 1.05 + 0.07 * k, 0.0)
	_st._check_root.global_transform = t


## 每帧让待确认标记呼吸：格子橙框在橙<->黄之间脉动，黄勾同步呼吸并保持正对摄像机
func tick_pending_pulse(delta: float) -> void:
	if _st._pending_root == null or not _st._pending_root.visible:
		return
	_pulse_t += delta
	var k: float = 0.5 + 0.5 * sin(_pulse_t * 6.0)
	var col := Color(1.0, 0.45 + 0.45 * k, 0.10, 0.85 + 0.15 * k)
	for m in _st._pending_mats:
		m.albedo_color = col
	for m in _st._check_mats:
		var mc: StandardMaterial3D = m
		if mc.blend_mode == BaseMaterial3D.BLEND_MODE_ADD:
			mc.albedo_color = Color(1.0, 0.82, 0.18, 0.20 + 0.18 * k)
		else:
			mc.albedo_color = Color(1.0, 0.88 + 0.10 * k, 0.24 + 0.18 * k, 1.0)
	face_check_mark()


func hint_cell(cell: Vector2i, col: Color) -> void:
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
	_st._hint_layer.add_child(mi)


# ══════════════════════════════════════════════════════════════════════════════
# 落点环 + 闪光
# ══════════════════════════════════════════════════════════════════════════════

func make_impact_ring(pos: Vector2, radius: float) -> MeshInstance3D:
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
	_st.add_child(mi)
	return mi


func flash_impact(ring: MeshInstance3D) -> void:
	if not is_instance_valid(ring):
		return
	var m := ring.material_override as StandardMaterial3D
	var tw: Tween = _st.create_tween()
	tw.tween_property(m, "albedo_color:a", 0.0, 1.1)
	tw.tween_callback(func() -> void:
		if is_instance_valid(ring):
			ring.queue_free())


## 落地后的 red circle：标出 impact 范围（浮点落点，用户口径）
func show_impact(center: Vector2, y: float = 0.05) -> void:
	_st._impact_ring.position = Vector3(center.x, y, center.y)
	_st._impact_ring.visible = true
	var im := _st._impact_ring.material_override as StandardMaterial3D
	im.albedo_color = Color(1.0, 0.22, 0.20, 0.45)
	# 关键：先把上一次没跑完的淡出动画杀掉，否则它会在这一帧把红圈又藏起来
	if _impact_tw != null and _impact_tw.is_valid():
		_impact_tw.kill()
	var t: Tween = _st.create_tween()
	_impact_tw = t
	t.tween_property(im, "albedo_color:a", 0.0, 1.2)
	t.tween_callback(func() -> void: _st._impact_ring.visible = false)


## 球状闪光（用户口径：只要球状闪光，不要红圈）
## 一次性的发光球体：迅速膨胀 + 淡出，播完自己销毁。
func flash_sphere(center: Vector3, radius: float = 1.5, life: float = 0.38) -> void:
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
	_st.add_child(mi)
	_st._last_flash = mi
	var tw: Tween = _st.create_tween()
	tw.set_parallel(true)
	tw.tween_property(mi, "scale", Vector3.ONE * radius, life * 0.45)
	tw.tween_property(m, "albedo_color", Color(1.0, 0.9, 0.6, 0.0), life)
	tw.tween_property(m, "emission_energy_multiplier", 0.0, life)
	tw.set_parallel(false)
	tw.tween_callback(func() -> void:
		if is_instance_valid(mi):
			mi.queue_free())


## 角色被击中时的白闪
func flash(u: Unit) -> void:
	if u.visual == null:
		return
	# 白闪逻辑搬到 UnitVisual：基准色只记一次，否则连吃几发就永久变白
	(u.visual as UnitVisual).flash_hit()
