# 无头试玩：脚本驱动真实场景，验证回合队列、二级菜单、投掷瞄准、友伤、取消选择、队列条。
# 运行: godot --headless --path <项目> --script res://tools/playtest.gd
# 设计：所有检查走 _chk()，末尾统一打印并 quit()，**不会因断言失败而挂住**。
extends SceneTree

var _s: Node
var _fails: Array[String] = []
var _checks := 0
var _do_move_probe_start: int = 0        # 走位耗时探针（第 40 节）

## 统计高亮格数量（排除常驻的待确认 √ sprite）
func _count_hint_boxes() -> int:
	var n := 0
	for c in _s.t_hint_layer().get_children():
		if c is MeshInstance3D:
			n += 1
	return n


func _chk(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails.append(label)


## 当前是否有一个活着的弹反 QTE 节点
func _find_qte() -> ArrowQTE:
	return _s.t_find_arrow_qte()


## 等直升机的火箭齐射全部出膛（第 93 轮：8 波 / 间隔 1 秒 = 7 秒多）
func _wait_salvo() -> void:
	var guard := 0.0
	while _s.t_salvo_u() != null and guard < 12.0:
		guard += 0.1
		await create_timer(0.1).timeout


## 把老国王 / 公主挪到地图角落，免得它们的 AI 与常备哨兵干扰确定性检查
func _clear_ai_corner() -> void:
	for u in _s.units:
		if Unit.base_name(u.name) == "老国王" or Unit.base_name(u.name) == "公主":
			var far := Vector2i(2, 44) if u.side == UnitData.Side.PLAYER else Vector2i(45, 44)
			u.cell = far
			if u.visual != null:
				u.visual.position = Vector3(float(far.x) + 0.5, 0.0, float(far.y) + 0.5)


## 按基础名找一个活着的单位（都死了就把第一个满血复活，方便反复测试）
func _unit_by(bname: String, side: int = -1) -> Unit:
	var fallback: Unit = null
	for u in _s.units:
		if Unit.base_name(u.name) != bname:
			continue
		if side >= 0 and u.side != side:
			continue
		if u.is_alive():
			return u
		if fallback == null:
			fallback = u
	if fallback != null:
		fallback.power_cur = fallback.power_max
		fallback.armor_cur = fallback.armor_max
		fallback.tags.erase("crashing")
		if fallback.visual != null:
			fallback.visual.visible = true
	return fallback


## 数场上某种弹道物有几发（kind 是字符串，见 Projectile.KIND_*）
func _count_kind(kind: String) -> int:
	var n := 0
	for it in _s.field.items:
		if (it["p"] as Projectile).kind == kind:
			n += 1
	return n


## 用【某一条入口】打一次普攻，返回这一击的指纹。
## 三条入口（拖拽 / 点目标 / AI）产出的指纹必须一模一样 —— 这是本轮重构的防回归核心。
## 探测前把参战双方拉回满血：前面的小节可能已经把人打死了（这不影响入口一致性）。
func _basic_sig(u: Unit, victim: Unit, entry: String) -> String:
	_s.clear_projectiles()
	_s.gm.pending.clear()
	_s.gm.clear_all_sentries()
	for o in [u, victim]:
		o.power_cur = o.power_max
		o.armor_cur = o.armor_max
		o.tags.erase("crashing")
		o.tags.erase("diving")
		o.tags.erase("dive_ready")
		o.has_acted = false
		o.has_moved = false
		if o.visual != null:
			o.visual.visible = true
	u.energy = u.energy_max
	u.cell = Vector2i(10, 10)
	if u.visual != null:
		u.visual.position = Vector3(10.5, u.hover, 10.5)
	var melee: bool = AttackProfile.basic_of(u) == AttackProfile.BASIC_MELEE
	victim.cell = Vector2i(11, 10) if melee else Vector2i(14, 10)
	if victim.visual != null:
		victim.visual.position = Vector3(float(victim.cell.x) + 0.5, victim.hover,
			float(victim.cell.y) + 0.5)
	var hp0: int = victim.power_cur
	var aim := Vector2(float(victim.cell.x) + 0.5, float(victim.cell.y) + 0.5)
	_s.active = u
	_s.t_set_turn_just_finished(null)
	_s.phase = _s.Phase.IDLE
	match entry:
		"drag":
			_s.phase = _s.Phase.AIMING
			_s.t_set_aim_active(true)
			_s.t_set_aim_valid(true)
			_s.t_set_aim_origin(Vector2.ZERO)
			_s.t_set_aim_now(Vector2(220, 0))
			_s.t_set_aim_float_pos(aim)
			_s.t_set_planned_cell(victim.cell)
			_s.t_set_aim_skill_id("")
			_s.t_fire()
		"click":
			_s.t_attack_target_unit(victim, false)
		_:
			_s.t_ai_attack(u, {"target": victim, "aim": aim})
	var kinds: Array = []
	for it in _s.field.items:
		var kn := ProjectileField.kind_cn((it["p"] as Projectile).kind)
		if not kinds.has(kn):
			kinds.append(kn)
	kinds.sort()
	var hit_ok := int(victim.power_cur < hp0)
	var sig := "有效 %d｜%s｜发弹 %d｜精力 %d｜已出手 %d｜掉血 %d" % [
		int(_s.field.items.size() > 0 or hit_ok > 0), ",".join(PackedStringArray(kinds)),
		_s.field.items.size(), u.energy_points(), int(u.has_acted), hit_ok]
	# 齐射/连发是异步的：等它把剩下的打完再交给下一次探测（免得污染下一条入口的计数）
	# 第 93 轮：直升机变成 8 波 / 间隔 1 秒 -> 要等 7 秒多，所以直接等 _salvo_u 清空
	await _wait_salvo()
	_s.clear_projectiles()
	return sig


## 某个技能"真的产生了效果"的计数（两条入口必须一致）
func _skill_effect(sid: String, caster: Unit) -> int:
	match sid:
		"sentry":
			return _s.gm.sentries.size()
		"dive_bomb":
			return 1 if caster.tags.has("dive_ready") else 0
		"carpet_bomb":
			return _count_kind(Projectile.KIND_SHELL)
		"grenade_launcher":
			return _count_kind(Projectile.KIND_GRENADE)
		"orbital_strike":
			return _count_kind(Projectile.KIND_MARKER)
		"loiter_launch":
			# 第 104 轮新技能（轮式齐射午餐盒）：朝"落点附近 32 格内最近的敌人"放一枚巡飞弹。
			# 效果 = 在飞的巡飞弹数量（放不出来就是 0，断言会红）。
			return _count_kind(Projectile.KIND_LOITER)
		"radar_link":
			# 第 111 轮新技能（雷达午餐盒）：连接一名友军。
			# 效果 = 这台雷达车当前的**连接数**（放不出来就是 0，断言会红）。
			var rst: Radar.State = _s.t_radar_state(caster.name)
			return 0 if rst == null else rst.links.size()
	return -1


## 把一次技能测试的现场清干净（弹道物 / GM 在途 / 哨兵 / 俯冲准备）
func _reset_skill_scene(caster: Unit) -> void:
	_s.clear_projectiles()
	_s.gm.pending.clear()
	_s.gm.clear_all_sentries()
	_s.t_clear_pylons()
	caster.tags.erase("dive_ready")
	caster.tags.erase("diving")
	_s.t_dive_clear(caster)
	caster.energy = caster.energy_max
	caster.has_acted = false
	caster.has_moved = false


func _initialize() -> void:
	_s = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(_s)
	for i in 5:
		await process_frame
	# 新角色（老国王 / 公主）会自己开炮、开哨兵，会打扰后面的确定性检查。
	# 全部先挪到地图角落（各自阵营的那一侧），要测它们时再单独摆位。
	# 通用 AI 也先关掉（试玩要复现"敌方站着不动"的老行为），第 30 节单独测 AI。
	_s.t_set_ai_enabled(false)
	_clear_ai_corner()

	# ── 0. 放置阶段（战斗开始前）──
	print("\n[0] 放置阶段")
	print("    初始阶段 = %d（PLACE=%d）  可放置物种类 = %d" % [
		_s.phase, _s.Phase.PLACE, _s.place_left.size()])
	_chk(_s.phase == _s.Phase.PLACE, "开局应处于放置阶段")
	_chk(_s.active == null, "放置阶段不应有当前行动者")
	_chk(_s.queue == null, "放置阶段还没有回合队列")
	var spike_n: int = _s.place_left.get("木刺", 0)
	var mound_n: int = _s.place_left.get("土堆", 0)
	print("    木刺 ×%d   土堆 ×%d（来自 bc_stat.md）" % [spike_n, mound_n])
	_chk(_s.place_left.has("木刺") and _s.place_left.has("土堆"), "两种道具都应被解析出来")
	if spike_n > 0:
		_s.t_pick_place_kind("木刺")
		_chk(_s.t_place_kind() == "木刺", "应选中木刺")
		var pc := Vector2i(6, 12)
		_chk(_s.t_can_place_at(pc), "空地上可以放置")
		_s.t_place_at(pc)
		print("    放置木刺后：道具数 = %d，剩余 = %d" % [
			_s.placeables.size(), _s.place_left.get("木刺", 0)])
		_chk(_s.placeables.size() == 1, "应放下 1 个道具")
		_chk(int(_s.place_left.get("木刺")) == spike_n - 1, "剩余数量应减 1")
		_chk(not _s.t_can_place_at(pc), "同一格不能再放")
		_chk(not _s.t_can_place_at(_s.units[0].cell), "有单位的格子不能放")
	if mound_n > 0:
		_s.t_pick_place_kind("土堆")
		_s.t_place_at(Vector2i(7, 12))
		_chk(_s.placeables.size() == 2, "再放一个土堆")
	_s.t_finish_placement()
	print("    结束放置后：阶段 = %d，队列 = %s" % [_s.phase, _s.queue.dump() if _s.queue else "-"])
	_chk(_s.phase != _s.Phase.PLACE, "点 >> 后应离开放置阶段")
	_chk(_s.queue != null, "结束后应建立回合队列")
	_chk(_s.active != null, "结束后应有第一个行动者")

	print("\n单位数：", _s.units.size())
	for u in _s.units:
		print("  %-16s %-4s %-5s 位置%s 力%s 甲%s 射程%d-%d" % [
			u.name, Unit.role_name(u.role),
			"我方" if u.side == UnitData.Side.PLAYER else "敌方",
			u.cell, u.power_points(), u.armor_points(), u.rng_min, u.rng_max])

	# ── 1. 队列交错 ──
	var q: TurnQueue = _s.queue
	print("\n[1] 队列：", q.dump())
	var actors := 0
	for u in _s.units:
		if u.has_turn(): actors += 1
	_chk(q.p_queue.size() + q.e_queue.size() == actors, "%d 个会行动的单位应全部进入两条循环队列（假人不进）" % actors)
	_chk(q.alternation_ok(), "两条队列交替执行，绝不能出现同阵营连续两次")
	# 循环队列：人少的一方会先绕回来（重复出现是正常的）
	var pv: Array = q.preview(12)
	var sides: Array[int] = []
	for u in pv:
		sides.append(u.side)
	print("    预测序列（阵营）=", sides)
	_chk(sides.size() >= 6, "应能预测至少 6 步")

	# ── 2. 假人自动跳过（信号观测）──
	# 敌方回合是"延迟 0.5s 自动跳过"，所以每一步多等一点；
	# 用自适应轮询避免时序太紧导致漏观测。
	var seen: Array[String] = []
	_s.turn_started.connect(func(u: Unit) -> void:
		seen.append("%s(%s)" % [u.name, "P" if u.side == 0 else "E"]))
	for i in 16:
		var waited := 0.0
		while _s.active == null and waited < 1.0:
			await create_timer(0.05).timeout
			waited += 0.05
		if _s.active == null:
			continue
		if _s.active.is_manual():
			_s.t_finish_turn()          # 我方 + 敌方阵营里的可控角色都由玩家结束回合
		await create_timer(UnitData.DUMMY_SKIP_DELAY + 0.35).timeout
	var enemy_seen := 0
	var player_seen := 0
	for s2 in seen:
		if s2.ends_with("(E)"): enemy_seen += 1
		else: player_seen += 1
	print("\n[2] 行动序列：", seen)
	_chk(enemy_seen > 0, "假人应被轮到并自动跳过")
	_chk(player_seen > 0, "玩家应有回合")
	_chk(seen.size() >= 6, "至少观察到一轮全员（6 个会行动的单位）")
	print("    玩家 %d 次 / 敌方 %d 次" % [player_seen, enemy_seen])

	# ── 3. 二级菜单 ──
	var gerald = null
	var mortar = null
	var alette = null
	var dummy = null
	var e_list: Array = []
	for u in _s.units:
		if u.name == "Gerald": gerald = u
		if u.name == "Airburst mortar": mortar = u
		if u.name == "Alette": alette = u
		if u.side == UnitData.Side.ENEMY:
			e_list.append(u)
			if dummy == null: dummy = u
	_s.active = gerald
	_s.phase = _s.Phase.IDLE
	_s.t_select_for_detail(gerald)
	_s.t_show_action_menu()
	print("\n[3] 菜单可见 =", _s.t_action_menu().visible, " 阶段 =", _s.phase, " 可达格 =", _s.reachable.size())
	_chk(_s.t_action_menu().visible, "点自己人应弹出菜单")
	_chk(_s.reachable.size() > 0, "菜单打开时应有移动范围")

	# ── 4. 攻击二级菜单 ──
	gerald.cell = dummy.cell + Vector2i(-1, 0)
	_s.t_menu_attack()
	_chk(_s.phase == _s.Phase.CHOOSE_TARGET, "普攻应进入选目标阶段")
	_chk(_s.attackable.has(dummy.cell), "相邻敌人应可攻击")
	_s.t_show_attack_menu(dummy)
	print("\n[4] 攻击菜单可见 =", _s.t_attack_menu().visible)
	print("    蓝(破甲) = %s   红(力量) = %s" % [
		_s.t_btn_break().text.replace("\n", "/"), _s.t_btn_power().text.replace("\n", "/")])
	_chk(_s.t_attack_menu().visible, "点敌人应弹出攻击方式菜单")
	_chk(_s.t_btn_break().text.contains("破甲"), "左按钮是破甲")
	_chk(_s.t_btn_power().text.contains("打力量"), "右按钮是打力量")
	_chk(_s.t_btn_break().text.contains("16"), "破甲按钮应显示 16")
	# 假人现在是 100 甲，Gerald 41 力打不动 -> 按钮应显示"打不动"且置灰
	print("    假人现在 100 甲，Gerald 41 力：力量按钮 =", _s.t_btn_power().text.replace("\n", "/"),
		" disabled=", _s.t_btn_power().disabled)
	_chk(_s.t_btn_power().text.contains("打不动"), "力量打不动时应显示「打不动」")
	var arm_before: int = dummy.armor_cur
	_s.t_confirm_attack(true)          # 用破甲，必然能削它护甲
	await process_frame
	print("    确认破甲后：%s 护甲 %s -> %s" % [dummy.name, arm_before / 1000.0, dummy.armor_cur / 1000.0])
	_chk(dummy.armor_cur < arm_before, "破甲应削减护甲池")

	# 概率命中的文案：dummy 物抗为 0，所以临时给它一个高档位来构造 0<D<1
	var tough = e_list[1]
	tough.pr = 800
	_s.active = gerald
	gerald.power_cur = tough.armor_cur + Rules.points_to_milli(1)
	_s.t_show_attack_menu(tough)
	print("    概率区间的红按钮 =", _s.t_btn_power().text.replace("\n", "/"))
	_chk(_s.t_btn_power().text.contains("概率"), "概率区间应写「1（xx%概率）」")
	tough.pr = 0

	# ── 5. 投掷瞄准数学 ──
	_s.active = mortar
	_s.t_begin_aim()
	print("\n[5] 射程 %s~%s 格；箭头 %s~%s 倍身高" % [
		UnitData.THROW_RANGE_MIN, UnitData.THROW_RANGE_MAX,
		UnitData.ARROW_LEN_MIN, UnitData.ARROW_LEN_MAX])
	var prev_r := -1.0
	var prev_l := -1.0
	for px in [0, 30, 100, 200, 300, 400, 700]:
		var t1: float = _s.t_charge_from_drag(float(px))
		var r1: float = _s.t_aim_range(t1)
		var al1: float = _s.t_arrow_len_for_t(t1) / UnitData.UNIT_HEIGHT
		print("      拖 %4d px -> 力度 %3d%% -> 射程 %5.2f 格 -> 箭头 %.2f 倍身高" % [
			px, int(t1 * 100), r1, al1])
		_chk(r1 >= UnitData.THROW_RANGE_MIN - 0.001, "射程 >= 最短")
		_chk(r1 <= UnitData.THROW_RANGE_MAX + 0.001, "射程 <= 最长")
		_chk(al1 >= UnitData.ARROW_LEN_MIN - 0.001, "箭头 >= 1 倍身高")
		_chk(al1 <= UnitData.ARROW_LEN_MAX + 0.001, "箭头 <= 3 倍身高")
	for px in range(0, 500, 10):
		var t2: float = _s.t_charge_from_drag(float(px))
		var r2: float = _s.t_aim_range(t2)
		var al2: float = _s.t_arrow_len_for_t(t2)
		_chk(r2 >= prev_r - 0.0001, "射程单调不减")
		_chk(al2 >= prev_l - 0.0001, "箭头单调不减")
		prev_r = r2
		prev_l = al2

	# ── 6. 炮击：破甲 + 力量（物抗减半）+ 友伤 ──
	e_list[0].cell = Vector2i(8, 6)
	e_list[1].cell = Vector2i(9, 6)
	e_list[2].cell = Vector2i(12, 10)
	gerald.cell = Vector2i(9, 7)
	e_list[1].pr = 800                               # 落点上的假人给 high 物抗，验证"减半"
	e_list[1].armor_cur = e_list[1].armor_max
	# 炮手 36 力打不动 100 甲，所以先把落点上那个假人的护甲压低，才能观察到力量伤害
	e_list[1].armor_cur = Rules.points_to_milli(20)
	gerald.armor_cur = Rules.points_to_milli(20)     # 友军也压低，否则翻倍后的 52 甲直接免伤
	var tgt: Array = [e_list[0], e_list[1], e_list[2], gerald]
	var pb: Array[int] = []
	var ab: Array[int] = []
	for u in tgt:
		pb.append(u.power_cur)
		ab.append(u.armor_cur)
	print("\n[6] 炮击（落点 9,6；落点上的假人物抗 high=80% → 按 40% 计）")
	var expect_bd: int = mortar.armor_break
	_s.t_resolve_mortar_impact(mortar, Vector2i(9, 6))
	for i in tgt.size():
		print("      %-16s 力 %s->%s  甲 %s->%s" % [tgt[i].name,
			pb[i] / 1000.0, tgt[i].power_cur / 1000.0,
			ab[i] / 1000.0, tgt[i].armor_cur / 1000.0])
	_chk(e_list[1].armor_cur == maxi(0, ab[1] - expect_bd),
		"落点上的假人护甲应正好减少破甲值 %d" % (expect_bd / 1000))
	# 力量伤害：炮手 36 力 vs 护甲 20、物抗 0.8→按 0.4 计 → 差值 16 × 0.6 = 9.6 → 9 点
	var expect_power := int((36.0 - 20.0) * (1.0 - 0.4))
	print("      期望力量伤害 ≈ %d 点（36力-20甲 再按物抗减半的 40%% 计）" % expect_power)
	_chk(e_list[1].power_cur < pb[1], "落点上的假人力量应下降")
	_chk(gerald.power_cur < pb[3], "友军也应受伤")
	_chk(gerald.armor_cur < ab[3], "友军护甲也应被破甲")
	_chk(e_list[2].power_cur == pb[2] and e_list[2].armor_cur == ab[2], ">1 格的单位不受影响")

	# ── 6b. 假人死亡后自动满血复活 ──
	print("\n[6b] 假人死亡后自动满血复活（等 %.1f 秒）" % UnitData.DUMMY_REVIVE_SEC)
	var d2 = e_list[0]
	d2.take_power_damage(999999)          # 打到力量池归零 = 阵亡（alive 是派生属性，不能直接赋值）
	_chk(not d2.is_alive(), "力量归零后 is_alive() 为 false")
	_s.t_on_unit_died(d2)
	await create_timer(UnitData.DUMMY_REVIVE_SEC + 0.3).timeout
	print("      复活后 力=%s 甲=%s alive=%s" % [
		d2.power_cur / 1000.0, d2.armor_cur / 1000.0, d2.is_alive()])
	_chk(d2.is_alive(), "假人应已复活")
	_chk(d2.power_cur == d2.power_max, "复活后力量满")
	_chk(d2.armor_cur == d2.armor_max, "复活后护甲满")

	# ── 7. 取消选择 ──
	_s.selected = gerald
	_s.t_clear_selection()
	print("\n[7] 取消选择：selected=%s 详情=%s 行动菜单=%s 攻击菜单=%s" % [
		_s.selected, _s.t_panel().visible, _s.t_action_menu().visible, _s.t_attack_menu().visible])
	_chk(_s.selected == null, "点空白应取消选择")
	_chk(not _s.t_panel().visible, "未选人时详情栏隐藏")
	_chk(not _s.t_action_menu().visible and not _s.t_attack_menu().visible, "未选人时二级菜单隐藏")

	# ── 8. 队列条 ──
	_s.ui.queue_anim_lock = 0.0
	_s.ui._clear_slots()
	_s.ui.refresh_queue()
	var alive := 0
	for u in _s.units:
		if u.is_alive(): alive += 1
	var icons := 0
	var lines := 0
	for c in _s.ui.queue_strip.get_children():
		if c is TextureButton: icons += 1
		elif c is ColorRect: lines += 1
	var seq: Array = _s.ui_upcoming(10)
	print("\n[8] 队列条：存活 %d -> 图案 %d，连线 %d" % [alive, icons, lines])
	print("    顺序：", seq.map(func(u: Unit) -> String: return u.name))
	_chk(icons > 0, "队列条应有图案")
	_chk(lines == icons - 1, "连线数 = 图案数 - 1")
	# 循环队列里同一个单位重复出现是【正确】的（人少的一方先绕回来）
	print("    窗口内允许重复（循环队列）：", seq.map(func(u: Unit) -> String: return u.name))
	_chk(seq.size() > 0, "队列条应有可预测的行动者")

	# ── 9. 回合推进后队头左移 ──
	# 先确保"当前回合是活的"（否则 _finish_turn 会走幂等保护、队列不动，
	# 这条断言就会因为测试自身的状态而假失败）
	_s.t_next_turn()
	await create_timer(UnitData.DUMMY_SKIP_DELAY + 0.2).timeout
	var head: Unit = _s.active
	_s.t_finish_turn()
	await create_timer(UnitData.DUMMY_SKIP_DELAY + 0.3).timeout
	var seq2: Array = _s.ui_upcoming(10)
	var new_head: Unit = seq2[0] if seq2.size() > 0 else null
	print("\n[9] 队头 %s -> %s" % [head.name if head else "-", new_head.name if new_head else "-"])
	_chk(new_head != head, "回合结束后队头应换人（队列左移）")

	# ── 10. 回合规则（用户新规）：移动 -> 三选一 -> 自动结束；移动后不能休息 ──
	print("\n[10] 回合规则")
	# 把 Gerald 放回场上并交给他一个干净的回合
	_s.active = gerald
	gerald.begin_turn()
	gerald.cell = Vector2i(4, 4)
	gerald.power_cur = gerald.power_max
	gerald.armor_cur = gerald.armor_max
	_s.t_show_action_menu()
	print("    未移动时：休息按钮 disabled =", _s.t_btn_rest_menu().disabled)
	_chk(not _s.t_btn_rest_menu().disabled, "未移动时可以休息")
	_chk(_s.reachable.size() > 0, "未移动时可以移动")

	# 移动一格
	var dest: Vector2i = _s.reachable.keys()[0]
	_s.t_do_move(gerald, dest)
	print("    移动后：has_moved =", gerald.has_moved,
		" 休息按钮 disabled =", _s.t_btn_rest_menu().disabled,
		" 可达格 =", _s.reachable.size())
	_chk(gerald.has_moved, "移动标记置位")
	_chk(_s.t_btn_rest_menu().disabled, "移动后不能休息")
	_chk(_s.reachable.size() == 0, "移动后不能再移动")

	# 移动后点休息 -> 应被拒绝
	gerald.power_cur = Rules.points_to_milli(10)
	var before_rest: int = gerald.power_cur
	_s.t_menu_rest()
	print("    移动后强行点休息：力量 %s -> %s（应不变）" % [before_rest / 1000.0, gerald.power_cur / 1000.0])
	_chk(gerald.power_cur == before_rest, "移动后休息应被拒绝")

	# 三选一（普攻）后回合立即结束：active 应换人
	var who_before: Unit = gerald
	_s.t_show_action_menu()
	_s.active = gerald
	_s.phase = _s.Phase.CHOOSE_TARGET
	var victim = e_list[0]
	victim.cell = gerald.cell + Vector2i(1, 0)
	victim.power_cur = victim.power_max
	victim.armor_cur = Rules.points_to_milli(10)     # 压低护甲让 Gerald 打得动
	_s.t_attack_target_unit(victim, false)
	await create_timer(0.35).timeout
	print("    普攻后：active %s -> %s（回合应自动结束）" % [
		who_before.name, _s.active.name if _s.active else "-"])
	_chk(_s.active != who_before, "三选一后回合应自动结束、轮到下一个人")

	# 「结束回合」已从二级菜单挪到右下角的 >> 按钮（用户要求）
	print("    二级菜单：休息=%s ｜ 右下角按钮=%s" % [_s.t_btn_rest_menu().text, _s.t_btn_next().text])
	_chk(_s.t_btn_next().text == ">>", "右下角按钮应是 >>")
	_chk(_s.t_btn_end_turn() == null, "二级菜单里的「结束回合」按钮应已移除")

	# ── 11. 高亮与菜单显隐（用户第三轮要求）──
	print("\n[11] 高亮与菜单显隐")
	# ① 没选任何人 -> 不应有可移动格
	_s.t_clear_selection()
	_s.t_draw_hints()
	var hint_count_empty: int = _count_hint_boxes()
	print("    未选人时高亮格数 =", hint_count_empty)
	_chk(hint_count_empty == 0, "未选人时不应高亮任何格子")

	# ② 选定当前单位 -> 出现可移动格（蜘蛛绿）
	_s.active = gerald
	gerald.begin_turn()
	gerald.cell = Vector2i(5, 5)
	_s.selected = gerald
	_s.t_show_action_menu()
	var hint_move: int = _count_hint_boxes()
	print("    选中且未移动时高亮格数 =", hint_move, "（可达格 %d）" % _s.reachable.size())
	_chk(hint_move > 0, "选中后应高亮可移动格")

	# ③ 点普攻 -> 二级菜单必须消失，且高亮变成"可攻击范围"
	_s.t_menu_attack()
	print("    点普攻后：二级菜单可见 =", _s.t_action_menu().visible,
		" 阶段 =", _s.phase, " 可攻击格数 =", _s.attackable.size())
	_chk(not _s.t_action_menu().visible, "点普攻后二级菜单必须消失")
	_chk(_s.phase == _s.Phase.CHOOSE_TARGET, "点普攻应进入目标选择阶段")

	# ④ 近战：可攻击范围应为 4 邻格（含越界剔除）
	var melee_cells: Dictionary = Targeting.attack_range_cells(gerald, _s.GW, _s.GH)
	var expect := 0
	for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var c: Vector2i = gerald.cell + off
		if c.x >= 0 and c.y >= 0 and c.x < 13 and c.y < 13: expect += 1
	print("    近战可攻击格数 =", melee_cells.size(), "（期望 %d）" % expect)
	_chk(melee_cells.size() == expect, "近战可攻击范围 = 4 邻格")

	# ⑤ 远程：可攻击范围为正比于射程的环带
	var ranged_cells: Dictionary = Targeting.attack_range_cells(mortar, _s.GW, _s.GH)
	var expect_ranged := 0
	for y in _s.GH:
		for x in _s.GW:
			var d: int = absi(x - mortar.cell.x) + absi(y - mortar.cell.y)
			if d >= mortar.rng_min and d <= mortar.rng_max: expect_ranged += 1
	print("    投掷可攻击格数 =", ranged_cells.size(), "（期望 %d，射程 %d-%d）" % [
		expect_ranged, mortar.rng_min, mortar.rng_max])
	_chk(ranged_cells.size() == expect_ranged, "投掷可攻击范围 = 射程环带内全部格子")

	# ⑥ 投掷瞄准时菜单也要消失
	_s.active = mortar
	_s.selected = mortar
	_s.t_show_action_menu()
	_s.t_menu_attack()
	print("    点普攻（投掷手）后：菜单可见 =", _s.t_action_menu().visible, " 瞄准中 =", _s.t_aim_active())
	_chk(not _s.t_action_menu().visible, "投掷手点普攻后菜单也应消失")
	_chk(_s.t_aim_active(), "投掷手点普攻应进入瞄准")
	_s.t_set_aim_active(false)
	_s.t_arrow_root().visible = false

	# ── 12. 远程一回合只能打一次（用户报告"弓箭手破甲能打两次"）──
	print("\n[12] 远程一回合只打一次")
	_s.active = alette
	alette.begin_turn()
	alette.cell = Vector2i(4, 4)
	var victim2 = e_list[1]
	victim2.cell = Vector2i(4, 8)                     # 落在射程 1-8 内
	victim2.armor_cur = victim2.armor_max
	var arm0: int = victim2.armor_cur
	_s.phase = _s.Phase.CHOOSE_TARGET
	_s.t_set_turn_just_finished(null) # 模拟"一个全新的回合"，避免幂等保护挡掉推进
	var tc0: int = _s.gm.turn_count
	_s.t_attack_target_unit(victim2, true)             # 破甲
	# 出手瞬间就应被标记"已行动"（必须在这时检查：等回合结束后 active 已换人）
	var acted_now: bool = alette.has_acted
	await create_timer(4.5).timeout                   # 等箭矢飞完+结算（箭速降到 2 格/秒）
	print("    Alette 破甲一次后：目标护甲 %s -> %s；出手瞬间 has_acted=%s" % [
		arm0 / 1000.0, victim2.armor_cur / 1000.0, acted_now])
	_chk(victim2.armor_cur < arm0, "破甲应生效一次")
	_chk(acted_now, "出手瞬间应标记已行动")
	# 判据：出手必须让"回合机"往前走（换人或至少跨过一次回合边界）
	_chk(_s.gm.turn_count > tc0 or _s.active != alette, "出手后回合应结束、换人")
	_s.active = alette                                # 把回合还给她，模拟"同一回合内再点一次"
	# 再调一次：应被 has_acted 挡住，不能再打
	var arm_after: int = victim2.armor_cur
	_s.t_attack_target_unit(victim2, true)
	await create_timer(0.3).timeout
	print("    再打一次：护甲 %s -> %s（应不变）" % [arm_after / 1000.0, victim2.armor_cur / 1000.0])
	_chk(victim2.armor_cur == arm_after, "同一回合不能二次攻击")

	# ── 13. 最后一人机制 ──
	print("\n[13] 最后一人机制")
	# 假人不进队列也不算战力，所以最后一人只算【英雄】
	var eh13: Array = []
	for u in e_list:
		if u.has_turn(): eh13.append(u)
	for i in range(1, eh13.size()):
		eh13[i].take_power_damage(999999)
	_s.queue.last_stand = false
	_s.queue.lone = null
	_s.queue.rebuild(_s.units)
	var entered: bool = _s.t_check_last_stand()
	print("    只剩 1 敌 vs 3 玩家 -> 进入连击=%s 队列 %s" % [entered, _s.queue.dump()])
	_chk(_s.queue.is_last_stand(), "应进入最后一人模式")
	var pv2: Array = _s.queue.preview(6)
	var pattern_ok := true
	for i in pv2.size():
		var is_lone: bool = pv2[i] == _s.queue.lone
		if is_lone != (i % 2 == 0): pattern_ok = false
	print("    预测序列：", pv2.map(func(u: Unit) -> String: return u.name))
	_chk(pattern_ok, "孤军应出现在偶数位（孤军→对面1→孤军→对面2…）")
	_chk(pv2.size() == 6, "应能预测 6 步")
	var triggered2: bool = _s.t_check_last_stand()
	_chk(not triggered2, "已处于最后一人模式时不应反复重排")
	# 真正走一遍回合推进（不是只看 preview）：必须是 孤军→对面1→孤军→对面2→…
	var run: Array = []
	for i in 8:
		var uu: Unit = _s.queue.current()
		run.append(uu.name if uu != null else "-")
		_s.queue.advance()
	var lone_ok := true
	for i in run.size():
		var is_lone: bool = run[i] == _s.queue.lone.name
		if is_lone != (i % 2 == 0):
			lone_ok = false
	print("    实际推进序列：", run)
	_chk(lone_ok, "连击模式下实际回合同样是 孤军→对面1→孤军→对面2…")
	# 哨兵/连击都不能让同一方连出两次
	var same_twice := false
	for i in range(1, run.size()):
		if run[i] == run[i - 1]:
			same_twice = true
	_chk(not same_twice, "连击模式下不会连续两次都是同一个人")

	# ── 14. 走路动画（用户要求：不能瞬移、有东西在动）──
	print("\n[14] 走路动画")
	_s.active = gerald
	gerald.begin_turn()
	gerald.cell = Vector2i(4, 4)
	gerald.visual.position = Vector3(4.5, 0.0, 4.5)
	_s.selected = gerald
	_s.phase = _s.Phase.MENU
	_s.reachable = _s.t_compute_reachable(gerald)
	var goal := Vector2i(-1, -1)
	for c in _s.reachable.keys():
		if absi(c.x - gerald.cell.x) + absi(c.y - gerald.cell.y) == 4:
			goal = c
			break
	_chk(goal.x >= 0, "应能找到距离 4 的可达目标格")
	var path: Array = _s.t_path_to(gerald, goal)
	print("    路径格子数 =", path.size(), "（起点 + 4 步 = 5）")
	print("    路径 =", path)
	_chk(path.size() == 5, "路径应是 5 个格子")
	if path.size() >= 5:
		_chk(path[0] == gerald.cell and path[4] == goal, "路径首尾应正确")
	var samples: Array[Vector2] = []
	var heights: Array[float] = []
	var stamps: Array[float] = []
	_s.t_do_move(gerald, goal)
	_chk(gerald.visual.is_walking(), "移动后应处于走路状态")
	var t := 0.0
	while t < 2.6 and gerald.visual.is_walking():
		await create_timer(0.03).timeout
		t += 0.03
		samples.append(Vector2(gerald.visual.position.x, gerald.visual.position.z))
		heights.append(gerald.visual.position.y)
		stamps.append(t)
	var distinct := {}
	var max_jump := 0.0
	# 注意：_do_move 会立刻把逻辑格子改到终点，所以起点要单独存
	var prev := Vector2(gerald.visual.position.x, gerald.visual.position.z)
	# 末尾几次采样会落在"走路刚结束、循环还没退出"的边界上，排除掉
	for i in maxi(0, samples.size() - 3):
		var s: Vector2 = samples[i]
		distinct["%.2f_%.2f" % [s.x, s.y]] = true
		max_jump = maxf(max_jump, (s - prev).length())
		prev = s
	var max_h := 0.0
	var min_h := 999.0
	for h in heights:
		max_h = maxf(max_h, h)
		min_h = minf(min_h, h)
	print("    采样 %d 次，不同中间位置 %d 个，单次最大位移 %.3f 格，高度 %.3f~%.3f" % [
		samples.size(), distinct.size(), max_jump, min_h, max_h])
	_chk(samples.size() >= 5, "应能采到多个中间位置")
	_chk(distinct.size() >= 4, "位置应有多个不同中间值（不是瞬移）")
	# 用户口径：匀速滑动 —— 不要一顿一顿、不要抬腿
	var speeds: Array[float] = []
	# 只统计"中途"的采样：首尾几次会落在起步前/停下后，位移 0 会污染统计
	for i in range(2, maxi(3, samples.size() - 2)):
		var dt: float = stamps[i] - stamps[i - 1]
		if dt <= 0.0001:
			continue
		speeds.append((samples[i] - samples[i - 1]).length() / dt)
	var avg := 0.0
	for s in speeds:
		avg += s
	if speeds.size() > 0:
		avg /= float(speeds.size())
	var dev := 0.0
	for s in speeds:
		dev = maxf(dev, absf(s - avg))
	print("    速度：平均 %.2f 格/秒，中途最大偏离 %.2f（要求 %.1f 格/秒且匀速）" % [
		avg, dev, UnitVisual.WALK_TILES_PER_SEC])
	_chk(absf(avg - UnitVisual.WALK_TILES_PER_SEC) < 0.6, "移动速度应约为每秒 2 格")
	_chk(dev < 1.2, "速度必须基本恒定（不能一顿一顿）")
	_chk(max_h - min_h < 0.05, "不应有抬腿/跳动（高度全程不变）")
	await create_timer(0.8).timeout
	print("    走完停在 (%.2f, %.2f)，期望 (%.1f, %.1f)" % [
		gerald.visual.position.x, gerald.visual.position.z,
		float(goal.x) + 0.5, float(goal.y) + 0.5])
	_chk(absf(gerald.visual.position.x - (float(goal.x) + 0.5)) < 0.01, "X 应停在目标格")
	_chk(absf(gerald.visual.position.z - (float(goal.y) + 0.5)) < 0.01, "Z 应停在目标格")
	_chk(gerald.cell == goal, "逻辑坐标也应更新到目标格")

	# ── 15. 炮击落点判定：红圈沾到格子即命中（用户口径）──
	print("\n[15] 炮击落点判定（半径 %.1f 格）" % _s.BLAST_RADIUS)
	var center := Vector2i(10, 10)
	# 正邻格（距离 1）必定命中
	_chk(Targeting.circle_touches_cell(Vector2(float(center.x) + 0.5, float(center.y) + 0.5), Vector2i(11, 10), _s.BLAST_RADIUS), "正邻格应命中")
	# 斜邻格：中心距离 = √2 ≈ 1.414 < 1.5，但格子角落在 0.707 处 -> 必须命中
	_chk(Targeting.circle_touches_cell(Vector2(float(center.x) + 0.5, float(center.y) + 0.5), Vector2i(11, 11), _s.BLAST_RADIUS), "斜邻格应命中（圈沾到了格子）")
	# 2 格外的直线距离 = 2 > 1.5，格子最近点 = 1.0 < 1.5 -> 也应命中（圈边压到格子边）
	_chk(Targeting.circle_touches_cell(Vector2(float(center.x) + 0.5, float(center.y) + 0.5), Vector2i(12, 10), _s.BLAST_RADIUS), "距离 2 格但圈边压到格子 -> 应命中")
	# 3 格外：最近点 2.0 > 1.5 -> 不命中
	_chk(not Targeting.circle_touches_cell(Vector2(float(center.x) + 0.5, float(center.y) + 0.5), Vector2i(13, 10), _s.BLAST_RADIUS), "3 格外不应命中")
	# 对角远处：(13,13) 最近点距离 √(2.5²+2.5²)≈3.54 -> 不命中
	_chk(not Targeting.circle_touches_cell(Vector2(float(center.x) + 0.5, float(center.y) + 0.5), Vector2i(13, 13), _s.BLAST_RADIUS), "对角远处不应命中")
	# 旧口径（比"爆心到格中心"）会漏判斜邻格：(11,11) 中心距离 1.414 < 1.5 其实也过，
	# 但 (12,10) 中心距离 2.0 > 1.5 会被旧口径漏掉 —— 这正是用户说的"显示比实际大"
	print("    正邻/斜邻/2格外 命中，3格外与对角远处 不命中")

	# 实际结算也应命中斜邻格里的单位
	e_list[0].cell = Vector2i(11, 11)
	e_list[0].pr = 0                                  # 无抗性，纯看护甲
	e_list[0].power_cur = e_list[0].power_max
	e_list[0].armor_cur = Rules.points_to_milli(5)    # 低护甲，好观察力量伤害
	var p0: int = e_list[0].power_cur
	var a0: int = e_list[0].armor_cur
	_s.t_resolve_mortar_impact(mortar, center)
	print("    斜邻格里的 %s（甲5、无抗）：力 %s->%s 甲 %s->%s" % [e_list[0].name,
		p0 / 1000.0, e_list[0].power_cur / 1000.0, a0 / 1000.0, e_list[0].armor_cur / 1000.0])
	_chk(e_list[0].armor_cur < a0, "斜邻格单位应被破甲")
	_chk(e_list[0].power_cur < p0, "斜邻格单位应吃力量伤害（甲5 时炮手 36 力打得动）")
	# 反面：高护甲时力量线打不动是正确行为（用户要求保留"打不动也能选力量"的权利）
	e_list[0].armor_cur = Rules.points_to_milli(100)
	e_list[0].power_cur = e_list[0].power_max
	var p1: int = e_list[0].power_cur
	_s.t_resolve_mortar_impact(mortar, center)
	print("    甲 100 时：力 %s->%s（应不变，因为打不动）" % [p1 / 1000.0, e_list[0].power_cur / 1000.0])
	_chk(e_list[0].power_cur == p1, "护甲 100 时炮手力量线打不动，力应不变")

	# ── 16. 调试面板（重写版：选中即编辑）──
	print("\n[16] 调试面板")
	_chk(not _s.ui.is_debug_open(), "默认应隐藏")
	_s.ui.toggle_debug()
	_chk(_s.ui.is_debug_open(), "点按钮应显示")
	_s.ui.toggle_debug()
	_chk(not _s.ui.is_debug_open(), "再点应关闭")
	_s.ui.toggle_debug()

	var n_fields: int = _s.DBG_FIELDS.size()
	_s.t_select_for_detail(e_list[0])
	_s.ui.dbg_seen_unit = null
	_s.ui.refresh_debug()
	print("    选中 %s 后编辑框 = %d 个（字段 %d 个）" % [
		e_list[0].name, _s.ui.dbg_edits.size(), n_fields])
	_chk(_s.ui.dbg_edits.size() == n_fields, "只给【当前选中的单位】建输入框（不再 6×13）")

	var d1 = e_list[0]
	# 力量：正常输入 / 非数字 / 越界 / 负数（都应夹取并写下）
	_s.ui_dbg_set(d1, "power_cur", "37")
	_chk(d1.power_cur == Rules.points_to_milli(37), "输入 37 -> 力量 37")
	_s.ui_dbg_set(d1, "power_cur", "abc")
	_chk(d1.power_cur == Rules.points_to_milli(37), "非数字应被拒绝，值不变")
	_s.ui_dbg_set(d1, "power_cur", "999999999")
	_chk(d1.power_cur == Rules.points_to_milli(99999), "越界应夹到上限")
	_s.ui_dbg_set(d1, "power_cur", "-5")
	_chk(d1.power_cur == 0, "负数应夹到 0")
	print("    力量归零：alive=%s 模型可见=%s" % [d1.is_alive(), d1.visual.visible])
	_chk(not d1.is_alive(), "力量 0 应判定阵亡")
	_s.ui_dbg_set(d1, "power_cur", "50")
	_chk(d1.is_alive(), "改回 50 应复活")
	_s.t_sync_unit_visibility()
	_chk(d1.visual.visible, "复活后模型必须可见")
	_s.ui.dbg_seen_unit = null
	_s.ui.refresh_debug()
	_s.ui.toggle_debug()

	# ── 17. 沙盒道具的阻挡与箭矢碰撞 ──
	print("\n[17] 沙盒道具")
	var spike = null
	var mound = null
	for p in _s.placeables:
		if p.name == "木刺": spike = p
		if p.name == "土堆": mound = p
	if spike != null and mound != null:
		var blocked: Dictionary = _s.t_blocked_cells()
		print("    木刺@%s 土堆@%s 阻挡移动格数 = %d" % [spike.cell, mound.cell, blocked.size()])
		_chk(blocked.has(spike.cell) and blocked.has(mound.cell), "两种道具都应阻挡移动")
		_chk(not _s.t_ranged_blocked_at(spike.cell, false), "木刺不阻挡远程")
		_chk(_s.t_ranged_blocked_at(mound.cell, false), "土堆阻挡远程")
		_chk(not _s.t_ranged_blocked_at(mound.cell, true), "投掷手不受土堆阻挡")

		# 目标在道具【后面】：路径必须绕开道具，不能穿过它所在格
		var block_path: Array = _s.t_path_to(alette, spike.cell + Vector2i(0, 2))
		var passes := false
		for c in block_path:
			if c == spike.cell: passes = true
		print("    目标在木刺后面时 路径=%s" % [block_path])
		print("    寻路穿过木刺所在格 = %s（应为 false）" % passes)
		_chk(not passes, "寻路不能穿过阻挡移动的道具")

		# 箭矢飞行碰撞：木刺挡在 Alette 与目标之间
		alette.cell = Vector2i(4, 4)
		alette.begin_turn()
		spike.cell = Vector2i(4, 6)
		spike.power_cur = spike.power_max
		var victim3 = e_list[0]
		victim3.cell = Vector2i(4, 8)
		victim3.power_cur = victim3.power_max
		victim3.armor_cur = Rules.points_to_milli(5)   # 压低护甲，否则 26力打 100甲 = 打不动
		victim3.power_cur = victim3.power_max
		gerald.cell = Vector2i(20, 20)           # 先把友军挪开
		for u in _s.units:
			if u != alette and u != victim3 and u != gerald and u.cell == Vector2i(4, 6):
				u.cell = Vector2i(25, 25)        # 清空弹道
		var spike_before: int = spike.power_cur
		_s.active = alette
		alette.begin_turn()                      # 清掉 has_acted，否则守卫会拦下这次攻击
		_s.t_attack_target_unit(victim3, false)
		await create_timer(4.5).timeout
		# 注意：假人会定时满血复活，直接比血量会被"复活"冲掉。
		# 所以这里以【游戏日志】为准：只要出现"Alette 攻击 → 目标"就说明箭穿过了木刺。
		var pierced := false
		for lg in _s.t_debug_log():
			if String(lg).contains("Alette 攻击 → %s" % victim3.name):
				pierced = true
		print("    箭矢飞向 (4,8)，木刺在 (4,6)：木刺 %s -> %s，日志命中=%s" % [
			spike_before / 1000.0, spike.power_cur / 1000.0, pierced])
		_chk(pierced, "木刺不挡箭：箭应穿过木刺命中后面的目标")
		_chk(spike.power_cur == spike_before, "木刺不挡箭：木刺本身不应被箭击中")

		# 友伤（第 84 轮口径：一切按物理碰撞判定）
		#   ① 挡在弹道上的友军：箭从他头顶飞过 -> 不算命中（不再"隔空误伤"）
		#   ② 直接朝友军射：箭真的碰到他 -> 照常造伤
		# 先把别人挪到角落：箭现在是物理判定，弹道上站着谁就会打到谁
		for u2 in _s.units:
			if u2 != alette and u2 != gerald and u2 != victim3:
				u2.cell = Vector2i(45, 45)
				if u2.visual != null:
					u2.visual.position = Vector3(45.5, u2.hover, 45.5)
		alette.begin_turn()
		_s.active = alette
		spike.power_cur = spike.power_max
		spike.cell = Vector2i(30, 30)            # 挪走木刺
		gerald.cell = Vector2i(4, 6)             # 友军站在弹道中间
		gerald.power_cur = gerald.power_max
		gerald.armor_cur = Rules.points_to_milli(5)   # 压低护甲，否则 26力 vs 26甲 = 打不动
		victim3.cell = Vector2i(4, 8)
		victim3.power_cur = victim3.power_max
		var gerald_before: int = gerald.power_cur
		var log_from: int = _s.t_debug_log().size()
		_s.t_attack_target_unit(victim3, false)
		await create_timer(4.5).timeout
		print("    弹道上放友军 Gerald：力量 %s -> %s ｜ 目标 %s -> %s" % [
			gerald_before / 1000.0, gerald.power_cur / 1000.0,
			victim3.power_max / 1000.0, victim3.power_cur / 1000.0])
		# 假人会定时满血复活，所以以【本次新增的日志】为准（和上面木刺那条同一个套路）
		var new_lines: Array = _s.t_debug_log().slice(log_from)
		var hit_friend := false
		var hit_target := false
		for lg2 in new_lines:
			if String(lg2).contains("攻击 → %s" % gerald.name):
				hit_friend = true
			if String(lg2).contains("攻击 → %s" % victim3.name):
				hit_target = true
		_chk(not hit_friend, "箭从友军头顶飞过不算命中（按物理碰撞判定）")
		_chk(gerald.power_cur == gerald_before, "被飞过的友军不掉血")
		_chk(hit_target, "箭从友军头顶飞过后仍然打到被瞄准的目标")
		# ② 直接瞄准友军射一箭：碰到了就必须正常造伤
		alette.begin_turn()
		_s.active = alette
		gerald.armor_cur = Rules.points_to_milli(5)
		gerald.power_cur = gerald.power_max
		victim3.cell = Vector2i(40, 40)
		var gerald_before2: int = gerald.power_cur
		_s.t_attack_target_unit(gerald, false)
		await create_timer(4.5).timeout
		print("    直接朝友军 Gerald 射：力量 %s -> %s" % [
			gerald_before2 / 1000.0, gerald.power_cur / 1000.0])
		_chk(gerald.power_cur < gerald_before2, "箭矢碰到任何角色都要正常造伤（友军也一样）")
		gerald.armor_cur = gerald.armor_max

	# ── 18. 移动选项 + 二次确认 ──
	print("\n[18] 移动选项与二次确认")
	_s.active = gerald
	gerald.begin_turn()
	gerald.cell = Vector2i(5, 5)
	gerald.visual.position = Vector3(5.5, 0.0, 5.5)
	_s.selected = gerald
	_s.t_show_action_menu()
	_s.t_menu_move()
	print("    点「移动」后：二级菜单可见=%s，可移动格=%d" % [
		_s.t_action_menu().visible, _s.reachable.size()])
	_chk(not _s.t_action_menu().visible, "点移动后二级菜单应消失")
	_chk(_s.reachable.size() > 0, "点移动后应高亮可移动格")
	var goal2 := Vector2i(5, 7)
	_chk(_s.reachable.has(goal2), "目标格应可达")
	_s.t_set_pending("move", goal2)
	_s.phase = _s.Phase.MOVE_CONFIRM
	_s.t_draw_hints()
	print("    第一次点 (%d,%d)：待确认=%s，格子仍是 %s" % [
		goal2.x, goal2.y, _s.t_pending_kind(), gerald.cell])
	_chk(gerald.cell == Vector2i(5, 5), "第一次点不应真的移动")
	_chk(_s.t_same_pending("move", goal2), "待确认目标应是该格")
	_s.t_do_move(gerald, goal2)
	await create_timer(0.6).timeout
	print("    确认后：已移动到 %s" % gerald.cell)
	_chk(gerald.cell == goal2, "确认后才真的移动")

	# ── 19. 队列绝不连续同阵营（用户重点）──
	print("\n[19] 队列交替自检")
	_chk(_s.t_queue_alternation_ok(), "当前队列不应出现连续同阵营")
	gerald.power_cur = gerald.power_max
	alette.power_cur = alette.power_max
	var alive_p := 0
	var alive_e := 0
	for u in _s.units:
		if u.is_alive():
			if u.side == UnitData.Side.PLAYER: alive_p += 1
			else: alive_e += 1
	_s.queue.rebuild(_s.units)
	print("    %d 人 vs %d 人 -> %s" % [alive_p, alive_e, _s.queue.dump()])
	_chk(_s.t_queue_alternation_ok(), "人数不等时也必须严格交替")
	var sides2: Array[int] = []
	for u in _s.queue.order:
		if u.is_alive():
			sides2.append(u.side)
	print("    阵营序列 =", sides2)
	_chk(_s.t_queue_alternation_ok(), "阵营序列不能有相邻相同")

	# ── 20. 连击状态在"对面复活"后必须保持 ──
	print("\n[20] 连击状态的保持")
	# 造：我方只剩 Gerald，敌方只剩 1 个英雄（假人不是英雄，不进队列）
	var eh20: Array = []
	for u in e_list:
		if u.has_turn(): eh20.append(u)
	for u in _s.units:
		if u.side == UnitData.Side.PLAYER and u != gerald:
			u.power_cur = 0
		if u.side == UnitData.Side.ENEMY and u.has_turn() and u != eh20[0]:
			u.power_cur = 0
	gerald.power_cur = gerald.power_max
	eh20[0].power_cur = eh20[0].power_max
	_s.queue.last_stand = false
	_s.queue.lone = null
	_s.queue.rebuild(_s.units)
	print("    1 vs 1 时：连击=%s 队列=%s" % [_s.queue.last_stand, _s.queue.dump()])
	_chk(not _s.queue.last_stand, "1 vs 1 不该进入连击（应严格交替）")
	_chk(_s.t_queue_alternation_ok(), "1 vs 1 也应隔一回合换边")

	# 敌方复活一个 -> 变成 1 vs 2 -> 应进入连击
	eh20[1].power_cur = eh20[1].power_max
	var switched: bool = _s.t_check_last_stand()
	_s.queue.rebuild(_s.units)
	print("    敌方复活 1 人后：检测到切换=%s 连击=%s" % [switched, _s.queue.last_stand])
	print("      队列 = %s" % _s.queue.dump())
	_chk(_s.queue.last_stand, "1 vs 2 应进入连击")
	_chk(_s.t_queue_alternation_ok(), "连击模式下也不能连续同阵营")

	# 关键：再复活一个敌方 -> 连击必须保持
	eh20[2].power_cur = eh20[2].power_max
	print("    敌方再复活 1 人（变成 1 vs 3）：")
	_s.queue.rebuild(_s.units)
	print("      连击保持 = %s" % _s.queue.last_stand)
	print("      队列 = %s" % _s.queue.dump())
	_chk(_s.queue.last_stand, "对面复活后连击状态必须保持")
	_chk(_s.t_queue_alternation_ok(), "连击保持时仍不能连续同阵营")
	# 一个完整循环 = 孤军 + 对面每人各一次
	var opp_n: int = _s.queue.e_queue.size() if _s.queue.lone.side == UnitData.Side.PLAYER \
		else _s.queue.p_queue.size()
	var cycle: int = opp_n * 2
	var lone_count := 0
	for i in mini(cycle, _s.queue.order.size()):
		if _s.queue.order[i] == gerald: lone_count += 1
	print("      一个循环（%d 步）里孤军 Gerald 出现 %d 次（对面 %d 人 -> 应为 %d）" % [
		cycle, lone_count, opp_n, opp_n])
	_chk(lone_count == opp_n, "孤军次数应等于对面人数")

	# ── 21. 待确认指示（常驻脉冲标记）──
	print("\n[21] 待确认指示")
	_s.active = gerald
	gerald.begin_turn()
	gerald.cell = Vector2i(5, 5)
	_s.selected = gerald
	_s.t_show_action_menu()
	_s.t_menu_move()
	var goal3 := Vector2i(5, 7)
	print("    点「移动」后：可移动格 = %d（应 > 0，说明高亮存在）" % _s.reachable.size())
	_chk(_s.reachable.size() > 0, "点移动后应有可移动格")
	_s.t_set_pending("move", goal3, gerald)
	_s.phase = _s.Phase.MOVE_CONFIRM
	_s.t_draw_hints()
	_chk(_s.t_pending_root() != null, "应创建常驻的待确认标记节点")
	print("    待确认标记可见 = %s 位置 = %s" % [
		_s.t_pending_root().visible, _s.t_pending_root().position])
	_chk(_s.t_pending_root().visible, "待确认标记应可见")
	_chk(_s.t_pending_root().position.x > 5.0 and _s.t_pending_root().position.x < 6.0,
		"标记应落在待确认格 (5,7) 上")
	# 脉冲：颜色随时间变化
	var cols: Array[Color] = []
	for i in 6:
		_s.t_tick_pending_pulse(0.08)
		cols.append((_s.t_pending_mats()[0] as StandardMaterial3D).albedo_color)
	var all_diff := true
	for i in range(1, cols.size()):
		if cols[i].is_equal_approx(cols[i - 1]):
			all_diff = false
	print("    标记颜色脉动：", cols[0], "->", cols[5])
	_chk(all_diff, "标记颜色应随时间脉动")
	# 取消后应隐藏
	_s.t_clear_pending()
	_s.t_draw_hints()
	_chk(not _s.t_pending_root().visible, "取消待确认后标记应隐藏")

	# ── 22. 地毯式轰炸（新技能）──
	print("\n[22] 地毯式轰炸")
	var d22 := Skills.get_def("carpet_bomb")
	print("    技能定义：名称=%s 消耗=%d 轰炸区=%dx%d 炮弹=%d 发 间隔=%.1fs" % [
		d22["name"], int(d22["cost"]), int(d22["rect_width"]), int(d22["rect_len"]),
		int(d22["shells"]), float(d22["gap_sec"])])
	_chk(d22.get("owner", "") == "Airburst mortar", "地毯式轰炸是投掷手的技能")
	var mortar22 = null
	for u in _s.units:
		if u.name == "Airburst mortar": mortar22 = u
	_chk(mortar22 != null, "应能找到投掷手")
	_chk(Skills.skills_for(mortar22).has("carpet_bomb"), "投掷手应会地毯式轰炸")

	# 落点几何：中轴线 = 投掷手 -> 爆心；长 7 宽 5；7 个点；每个 5x1 长条至少一个；间距 >= 0.2
	var ctr22 := Vector2(14.0, 14.0)
	var org22 := Vector2(4.0, 14.0)
	var axis22 := (ctr22 - org22).normalized()          # = (1, 0)
	var perp22 := Vector2(-axis22.y, axis22.x)
	var pts22: Array = Skills.carpet_points(d22, ctr22, ctr22 - org22, _s.rng)
	print("    落点 %d 个：%s" % [pts22.size(), pts22.map(
		func(p: Vector2) -> String: return "(%.2f,%.2f)" % [p.x, p.y])])
	_chk(pts22.size() == 7, "应取 7 个落点")
	var in_rect := true
	var bands_hit := {}
	var min_pair := 999.0
	for p in pts22:
		var rel: Vector2 = p - ctr22
		var along: float = rel.dot(axis22)
		var across: float = rel.dot(perp22)
		if absf(along) > 3.5 + 0.001 or absf(across) > 2.5 + 0.001:
			in_rect = false
		bands_hit[int(floor(along + 3.5))] = true      # 0..6 号长条
	for i in pts22.size():
		for j in range(i + 1, pts22.size()):
			min_pair = minf(min_pair, (pts22[i] as Vector2).distance_to(pts22[j]))
	print("    全部在 5x7 矩形内 = %s ｜ 命中的长条 = %s ｜ 最近两点间距 = %.3f" % [
		in_rect, bands_hit.keys(), min_pair])
	_chk(in_rect, "7 个落点必须都在 5x7 轰炸区内")
	_chk(bands_hit.size() == 7, "7 个 5x1 长条每个都要有落点")
	_chk(min_pair >= 0.2 - 0.0001, "任意两点间距必须 >= 0.2 格")
	# 由近及远
	var near_first := true
	for i in range(1, pts22.size()):
		if (pts22[i] as Vector2).dot(axis22) < (pts22[i - 1] as Vector2).dot(axis22) - 0.0001:
			near_first = false
	print("    由近及远排序 = %s（第一个 %.2f，最后一个 %.2f）" % [
		near_first, (pts22[0] as Vector2).dot(axis22), (pts22[6] as Vector2).dot(axis22)])
	_chk(near_first, "炮弹应由近及远依次落下")

	# 实战：让投掷手真的放一次（7 发 * 0.2s 间隔 + 1s 飞行 ≈ 2.2s）
	mortar22.cell = Vector2i(4, 14)
	mortar22.power_cur = mortar22.power_max      # 前面的测试可能把它打死了
	mortar22.energy = mortar22.energy_max
	mortar22.begin_turn()
	# 不占用 active：让 _finish_turn() 直接返回，免得回合机器在测试期间继续自转
	_s.active = null
	_s.phase = _s.Phase.MENU
	var e_before: int = mortar22.energy
	# 三个假人分别放在轰炸区里的不同位置，保证至少有一个吃到炮弹
	var cells22 := [Vector2i(12, 13), Vector2i(14, 14), Vector2i(16, 15)]
	for i in mini(3, e_list.size()):
		e_list[i].cell = cells22[i]
		e_list[i].power_cur = e_list[i].power_max
		e_list[i].armor_cur = Rules.points_to_milli(5)
	_s.t_start_carpet_bomb(mortar22, ctr22)
	# 物理弹道：7 发间隔 0.2 秒起飞，每发飞 1 秒 -> 最后一发在 2.2 秒后落地
	await create_timer(6.0).timeout
	var hurt := 0
	for i in mini(3, e_list.size()):
		if e_list[i].power_cur < e_list[i].power_max:
			hurt += 1
	for lg in _s.t_debug_log():
		if String(lg).contains("呼叫【地毯式轰炸】"):
			print("    [实际落点] %s" % lg)
	print("    放完：精力 %d -> %d（应 -%d）｜ 区内 %d/3 个目标挨打 ｜ 红圈节点 %d 个 ｜ gm_busy=%s" % [
		e_before, mortar22.energy, int(d22["cost"]), hurt, _s.count_impact_rings(), _s.t_gm_busy()])
	_chk(mortar22.energy == e_before - int(d22["cost"]) * 1000, "地毯式轰炸应扣 3 点精力")
	_chk(hurt > 0, "轰炸区内的目标应吃到炮弹")
	_chk(_s.count_impact_rings() > 0, "炮弹落点必须有红圈")
	_chk(not _s.t_gm_busy(), "演出结束后必须解锁操作")
	_chk(mortar22.has_acted, "放完技能应标记已行动（不能一回合打两次）")

	# ── 23. 空爆延迟 = 5 回合 ──
	print("\n[23] 空爆延迟")
	_chk(int(Skills.get_def("orbital_strike")["delay_turns"]) == 5, "轨道空爆延迟应为 5 回合")

	# ── 24. 点空白处收起二级菜单 ──
	print("\n[24] 点空白收起二级菜单")
	var g24: Unit = null
	for u in _s.units:
		if u.name == "Gerald": g24 = u
	_s.active = g24
	_s.selected = g24
	g24.begin_turn()
	_s.phase = _s.Phase.CHOOSE_TARGET
	_s.t_action_menu().visible = true
	_s.t_attack_menu().visible = true
	if _s.t_skill_menu() != null: _s.t_skill_menu().visible = true
	_s.t_set_pending("move", Vector2i(6, 6), g24)
	_s.t_on_blank_click()
	_chk(not _s.t_action_menu().visible, "点空白后行动菜单必须收起")
	_chk(not _s.t_attack_menu().visible, "点空白后攻击菜单必须收起")
	_chk(not _s.t_skill_menu().visible, "点空白后技能菜单必须收起")
	_chk(_s.selected == null, "点空白后不应保持选中")
	_chk(_s.t_pending_kind() == "", "点空白后待确认标记必须清掉")

	# ── 25. 哨兵 / 弹道物物理 / 受击白闪 ──
	print("\n[25] 哨兵与弹道物物理")
	for u in _s.units:
		u.power_cur = u.power_max
		u.armor_cur = u.armor_max
	_s.clear_projectiles()
	_s.gm.clear_all_sentries()
	_s.gm.pending.clear()
	var al25 = null
	var foe25 = null
	var g25 = null
	for u in _s.units:
		if u.name == "Alette": al25 = u
		if u.name == "Gerald": g25 = u
		if u.side == UnitData.Side.ENEMY and not u.controllable: foe25 = u
	al25.cell = Vector2i(5, 5)
	al25.energy = al25.energy_max
	al25.begin_turn()
	_s.active = null          # 让 _cast_sentry 内部的 _finish_turn() 直接返回，别把哨兵刷掉
	_s.t_cast_sentry(al25)
	print("    施放哨兵：登记=%s 精力 %d/%d ｜ %s" % [
		_s.gm.has_sentry(al25), al25.energy_points(), al25.energy_max_points(), _s.gm.sentry_desc()])
	_chk(_s.gm.has_sentry(al25), "施放后 GM 必须登记哨兵状态")
	_chk(al25.energy == al25.energy_max - 2000, "哨兵应扣 2 点精力")

	# 射界外：不入队
	foe25.cell = Vector2i(25, 25)
	_s.gm.on_move_begin(foe25)
	_chk(not _s.gm.check_unit(foe25, Vector2(25.5, 25.5)), "射界外的敌人不应惊动哨兵")
	# 进入射界（距离 6，在 1~8 内）：入队一次，且同一次移动只入队一次
	_chk(_s.gm.check_unit(foe25, Vector2(5.5, 11.5)), "敌人进入射界应入队")
	print("    敌人进入射界：队列 %d" % _s.gm.sentry_queue_size())
	_chk(_s.gm.sentry_queue_size() == 1, "队列里应有 1 个目标")
	_chk(not _s.gm.check_unit(foe25, Vector2(5.5, 12.0)), "同一次移动只入队一次")
	# 下一次移动（界内移动）还能再入队
	_s.gm.on_move_begin(foe25)
	_chk(_s.gm.check_unit(foe25, Vector2(5.5, 8.5)), "已在界内再移动应再次入队")

	# ── 队列节奏：一次一支、150ms 一发、打完轮转队尾、出界剔除 ──
	var s25: GameMaster.Sentry = _s.gm.sentries[0]
	s25.queue.clear()
	s25.cooldown = 0.0
	foe25.cell = Vector2i(5, 11)
	foe25.visual.position = Vector3(5.5, 0.0, 11.5)   # 队列按视觉位置判定，这里让它站定
	_s.gm.on_move_begin(foe25)                        # 新的一次移动：闩清零
	_chk(_s.gm.check_unit(foe25, Vector2(5.5, 11.5)), "新的一次移动应能再次入队")
	# 用户口径①：进入射界后先等 SENTRY_TRIGGER_DELAY（第 93 轮：1 秒）才射第一支
	_chk(_s.gm.sentry_tick(0.2).is_empty(), "进入射界 200ms 内还不该开火")
	_chk(_s.gm.sentry_tick(0.2).is_empty(), "400ms 仍不该开火")
	_chk(_s.gm.sentry_tick(0.2).is_empty(), "600ms 仍不该开火（第 93 轮把反应时间改成 1 秒）")
	_chk(_s.gm.sentry_tick(0.2).is_empty(), "800ms 仍不该开火")
	foe25.visual.position = Vector3(5.5, 0.0, 11.0)   # 目标在动（否则按"静止不追击"剔除）
	var f1: Array = _s.gm.sentry_tick(0.3)            # 累计 1.1 秒 > 1 秒
	var f1_at := "(%.2f, %.2f)" % [f1[0].at.x, f1[0].at.y] if f1.size() > 0 else "-"
	print("    延迟 %.0fms 之后：射出 %d 支，队列 %d ｜ 瞄准 %s" % [
		GameMaster.SENTRY_TRIGGER_DELAY * 1000.0, f1.size(), _s.gm.sentry_queue_size(), f1_at])
	_chk(f1.size() == 1, "等满 %.0fms 应射出一支" % (GameMaster.SENTRY_TRIGGER_DELAY * 1000.0))
	_chk(f1.size() == 1 and absf(f1[0].at.x - 5.5) < 0.001 and absf(f1[0].at.y - 11.0) < 0.001,
		"瞄准的是它此时的位置")
	_chk(_s.gm.sentry_queue_size() == 1, "打完的队头应轮转到队尾（不饿死、不消失）")
	_chk(_s.gm.sentry_tick(0.04).is_empty(), "100ms 冷却之内不能再射第二支")
	foe25.visual.position = Vector3(5.5, 0.0, 10.0)   # 继续移动
	_chk(_s.gm.sentry_tick(0.11).size() == 1, "冷却走完（且目标仍在动）应再射一支")
	# 静止目标：不再被追击（用户口径②）
	foe25.visual.position = Vector3(5.5, 0.0, 10.0)
	_s.gm.sentry_tick(0.2)
	_chk(_s.gm.sentry_queue_size() == 0, "目标停下来之后应从队列里剔除（不再对静止目标触发）")
	# 队头出界 -> 踢出队列（保持队列合法）
	_s.gm.on_move_begin(foe25)
	_s.gm.check_unit(foe25, Vector2(5.5, 11.5))
	foe25.visual.position = Vector3(25.5, 0.0, 25.5)
	_s.gm.sentry_tick(GameMaster.SENTRY_TRIGGER_DELAY + 0.1)   # 触发延迟走完才轮到"出界剔除"
	_chk(_s.gm.sentry_queue_size() == 0, "队头出界应被踢出队列")

	# 多个目标：一帧只射一支，按 FIFO 轮流
	var sh_p: Projectile = Projectile.make(Projectile.KIND_SHELL, Vector2(5.5, 9.5), Vector2(5.5, 9.5), 1.0)
	sh_p.sentry_trigger = true
	sh_p.hit_tags = ["arrow"]
	sh_p.side = UnitData.Side.PLAYER                 # 友军炮弹
	var sh_e: Projectile = Projectile.make(Projectile.KIND_SHELL, Vector2(5.5, 8.0), Vector2(5.5, 8.0), 1.0)
	sh_e.sentry_trigger = true
	sh_e.hit_tags = ["arrow"]
	sh_e.side = UnitData.Side.ENEMY                  # 敌军炮弹
	var ar_x: Projectile = Projectile.make(Projectile.KIND_ARROW, Vector2(5.5, 9.5), Vector2(5.5, 9.5), 1.0)
	_chk(_s.gm.check_projectile(sh_p), "友军炮弹进入射界也应入队（不分敌我）")
	_chk(not _s.gm.check_projectile(sh_p), "同一发炮弹不会重复入队")
	_chk(_s.gm.check_projectile(sh_e), "敌军炮弹进入射界应入队")
	_chk(not _s.gm.check_projectile(ar_x), "箭矢不应惊动哨兵（用户明确）")
	s25.cooldown = 0.0
	var g1: Array = _s.gm.sentry_tick(GameMaster.SENTRY_TRIGGER_DELAY + 0.02)   # 先等满触发延迟
	var g2: Array = _s.gm.sentry_tick(0.11)         # 再等满 100ms 射击间隔
	var g1_at := "(%.1f, %.1f)" % [g1[0].at.x, g1[0].at.y] if g1.size() > 0 else "-"
	var g2_at := "(%.1f, %.1f)" % [g2[0].at.x, g2[0].at.y] if g2.size() > 0 else "-"
	print("    两个目标轮流：第 1 支瞄准 %s，第 2 支瞄准 %s" % [g1_at, g2_at])
	_chk(g1.size() == 1 and g2.size() == 1, "两个目标排队时一次也只射一支")
	_chk(g1.size() == 1 and g2.size() == 1
			and absf(g1[0].at.y - 9.5) < 0.001 and absf(g2[0].at.y - 8.0) < 0.001,
		"严格 FIFO：先入队的先打，打完轮转队尾")
	# 轨道召唤球：也必须惊动哨兵 + 能被箭打掉（用户报的 bug：这两行属性曾被改丢）
	var mkthrow = null
	for u in _s.units:
		if u.name == "Airburst mortar": mkthrow = u
	mkthrow.cell = Vector2i(5, 9)      # 离阿莱特 4 格，正好在射界 1~8 内
	var mk: Projectile = _s.t_spawn_marker(mkthrow, Vector2(5.5, 9.5))
	print("    召唤球：sentry_trigger=%s hit_tags=%s 半径=%.2f" % [
		mk.sentry_trigger, mk.hit_tags, mk.hit_r])
	_chk(mk.sentry_trigger, "轨道召唤球必须能惊动哨兵")
	_chk(mk.hit_tags.has("arrow"), "轨道召唤球必须能被箭打掉")
	s25.queue.clear()
	s25.cooldown = 0.0
	_chk(_s.gm.check_projectile(mk), "召唤球进入射界应入队")
	s25.cooldown = 0.0
	_chk(_s.gm.sentry_tick(GameMaster.SENTRY_TRIGGER_DELAY + 0.02).size() == 1,
		"召唤球应被哨兵瞄准射出一支箭（弹道物不受'静止'限制）")
	s25.queue.clear()
	_s.clear_projectiles()

	# 炮弹被箭击落：炮弹有碰撞体积
	# 走工厂生成：保证"测试造的炮弹"和游戏里的炮弹字段完全一致
	_s.clear_projectiles()
	var shooter2 = null
	for u in _s.units:
		if u.name == "Airburst mortar": shooter2 = u
	shooter2.cell = Vector2i(5, 5)
	var sh2: Projectile = _s.t_spawn_shell(shooter2, Vector2(9.0, 9.0), false)
	var ar2: Projectile = _s.t_spawn_arrow(shooter2, Vector3(5.5, 0.75, 5.5),
		Vector3(9.5, 0.55, 9.5), null, false, false)
	_chk(_s.t_proj_collision(sh2) == ar2, "箭矢应能击落炮弹（炮弹必须有碰撞体积）")
	_s.clear_projectiles()
	_chk(_s.live_projectiles() == 0, "清场后不应残留弹道物")

	# 飞出边界的炮弹：直接移除，不爆炸、不留红圈
	_s.clear_projectiles()
	var rings_before: int = _s.count_impact_rings()
	_s.active = null
	# 第 87 轮起：炮弹飞行途中撞到角色会当成"在命中处落地" —— 所以先清空弹道（所有人挪到角落）
	for u in _s.units:
		u.cell = Vector2i(1, 40)
		if u.visual != null:
			u.visual.position = Vector3(1.5, u.hover, 40.5)
	g25.cell = Vector2i(2, 45)
	if g25.visual != null:
		g25.visual.position = Vector3(2.5, 0.0, 45.5)
	var p_out: Projectile = _s.t_spawn_shell(g25, Vector2(float(_s.GW) + 12.0, 45.0), true, 1.0)
	for i in 3000:
		_s.field.step(1.0 / 30.0)
		if not p_out.alive:
			break
	print("    打向界外 (60,45)：存活=%s 移除原因=%s 红圈 %d -> %d" % [
		p_out.alive, p_out.removed_reason, rings_before, _s.count_impact_rings()])
	_chk(not p_out.alive, "飞出边界的炮弹应被移除")
	_chk(p_out.removed_reason == "out_of_bounds", "移除原因应是出界")
	# 第 93 轮：炮弹类飞出物理边界改成"就地引爆"（敌方火箭凭空消失就是这么来的）
	_chk(_s.count_impact_rings() == rings_before + 1, "飞出边界的炮弹就地爆炸（留下一圈红圈）")
	_chk(p_out.removed_at.x >= -0.01 and p_out.removed_at.x <= float(_s.GW) + 0.01, "移除时应停在边界处（保留飞行动画）")

	# 哨兵在自己的下一个回合开始时结束
	al25.begin_turn()
	_s.gm.clear_sentry_for(al25)
	_chk(not _s.gm.has_sentry(al25), "自己的回合开始后哨兵必须结束")

	# 受击白闪：连续挨打后必须回到基准色
	var vis25 = g25.visual
	var mat25: StandardMaterial3D = null
	for c in vis25.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).material_override is StandardMaterial3D:
			mat25 = (c as MeshInstance3D).material_override
			break
	await create_timer(1.2).timeout       # 先等残留弹道/白闪全部跑完，再取真正的基准色
	var base25 := mat25.albedo_color
	vis25.flash_hit()
	await create_timer(0.1).timeout
	vis25.flash_hit()
	await create_timer(0.1).timeout
	vis25.flash_hit()
	await create_timer(0.6).timeout
	print("    连续受击 3 次后颜色 %s（基准 %s）" % [mat25.albedo_color, base25])
	_chk(mat25.albedo_color.is_equal_approx(base25), "连续受击后必须回到基准色（不会永久变白）")
	_chk(not base25.is_equal_approx(Color(1, 1, 1)), "基准色不应该是白色（否则说明基准色记错了）")

	# 敌方阵营里的可控角色：必须被当成"玩家操作"
	var ctrl25 = null
	for u in _s.units:
		if u.controllable: ctrl25 = u
	_chk(ctrl25 != null, "应有敌方阵营的可控角色")
	print("    可控敌方：%s 阵营=%d 手动=%s 技能=%s" % [
		ctrl25.name, ctrl25.side, ctrl25.is_manual(), Skills.skills_for(ctrl25)])
	_chk(ctrl25.is_manual(), "标记可控的敌方角色应被当作可操作单位")
	_chk(Skills.skills_for(ctrl25) == Skills.skills_for(g25) if ctrl25.name.begins_with("Gerald") else true,
		"镜像角色应继承对应角色的技能")

	# ── 25b. 炮弹在半空被打爆：就地空爆而且**有伤害**（用户口径）──
	print("\n[25b] 半空打爆炮弹")
	_s.clear_projectiles()
	_s.gm.clear_sentry_for(al25)             # 别让哨兵插一脚
	# 清空弹道：只留投掷手、杰拉尔德（箭要沿着 y=5.5 一路飞过去，别人别站道上）
	for u in _s.units:
		u.cell = Vector2i(1, 40)
		if u.visual != null:
			u.visual.position = Vector3(1.5, 0.0, 40.5)
	var shooter_b = null
	for u in _s.units:
		if u.name == "Airburst mortar": shooter_b = u
	shooter_b.cell = Vector2i(5, 5)
	gerald.cell = Vector2i(6, 6)             # 站在弹道旁边（不在道上，免得箭先打到他）
	gerald.visual.position = Vector3(6.5, 0.0, 6.5)
	gerald.power_cur = gerald.power_max
	var hp_bt: int = gerald.power_cur
	# 炮弹往远处飞（落点够远 -> 落地爆炸打不到杰拉尔德），只有"半空打爆"才会伤到他
	var shell_b: Projectile = _s.t_spawn_shell(shooter_b, Vector2(12.0, 5.5), false)
	var arrow_b: Projectile = _s.t_spawn_arrow(shooter_b, Vector3(4.5, 0.75, 5.5),
		Vector3(14.0, 0.55, 5.5), null, false, false)
	for i in 400:
		_s.field.step(1.0 / 60.0)
		if not shell_b.alive:
			break
	print("    炮弹 alive=%s 原因='%s' 位置=(%.2f, %.2f) ｜ 杰拉尔德力量 %d -> %d" % [
		shell_b.alive, shell_b.removed_reason, shell_b.removed_at.x, shell_b.removed_at.y,
		hp_bt, gerald.power_cur])
	_chk(not shell_b.alive and shell_b.removed_reason == "shot_down", "炮弹应被箭在半空击落")
	var burst_logged := false
	for lg in _s.t_debug_log():
		if String(lg).contains("空爆"):
			burst_logged = true
	_chk(burst_logged, "半空被打爆必须走空爆结算（日志里应有空爆字样）")
	# 空爆的三维判定：贴地炸有伤害，飞得高就炸不到（用户口径：一格球 + 三维判定）
	_s.clear_projectiles()
	gerald.cell = Vector2i(6, 6)
	gerald.visual.position = Vector3(6.5, 0.0, 6.5)
	gerald.power_cur = gerald.power_max
	gerald.armor_cur = Rules.points_to_milli(10)
	var hp_low: int = gerald.power_cur
	shooter_b.power_cur = shooter_b.power_max      # 保证"发射者活着"：发射单里的力量是开火那一刻的快照
	var low_shell: Projectile = _s.t_spawn_shell(shooter_b, Vector2(6.5, 6.5), false)
	low_shell.from = Vector2(6.5, 6.5)
	low_shell.to = Vector2(6.5, 6.5)
	_s.t_air_burst(low_shell)                       # 起飞高度 0.85 -> 贴脸炸
	print("    贴地空爆（高 %.2f）：杰拉尔德力量 %d -> %d" % [
		low_shell.pos3().y, hp_low, gerald.power_cur])
	_chk(gerald.power_cur < hp_low, "贴地空爆必须有伤害")
	var hp_high: int = gerald.power_cur
	var high_shell: Projectile = _s.t_spawn_shell(shooter_b, Vector2(6.5, 6.5), false)
	high_shell.from = Vector2(6.5, 6.5)
	high_shell.to = Vector2(6.5, 6.5)
	high_shell.apex = 3.0
	high_shell.t = 0.5                              # 抬到拱顶
	_s.t_air_burst(high_shell)
	print("    高空空爆（高 %.2f）：杰拉尔德力量 %d -> %d" % [
		high_shell.pos3().y, hp_high, gerald.power_cur])
	_chk(gerald.power_cur == hp_high, "飞得高的空爆打不到人（三维判定 + 一格球）")
	_s.clear_projectiles()

	# ── 26. 箭矢落在地上：留模型 2 秒，期间零判定 ──
	print("\n[26] 箭矢落地留存")
	_s.clear_projectiles()
	var archer = null
	for u in _s.units:
		if u.name == "Alette": archer = u
	archer.cell = Vector2i(4, 4)
	var land_arrow: Projectile = _s.t_spawn_arrow(archer, Vector3(4.5, 0.75, 4.5),
		Vector3(4.5, 0.55, 7.5), null, false, false)
	# 推到落地
	for i in 600:
		_s.field.step(1.0 / 60.0)
		if not land_arrow.alive:
			break
	print("    落地后：alive=%s 原因=%s 场上条目=%d" % [
		land_arrow.alive, land_arrow.removed_reason, _s.field.items.size()])
	_chk(land_arrow.removed_reason == "landed_on_ground", "箭矢触地应标记为落地")
	_chk(_s.field.items.size() == 1, "落地后模型应继续留在场上")
	var node0: Node3D = _s.field.items[0]["node"]
	_chk(is_instance_valid(node0), "留存期间模型节点必须有效")
	# 再推 1.5 秒：还没到 2 秒，应该还在
	for i in 90:
		_s.field.step(1.0 / 60.0)
	_chk(_s.field.items.size() == 1, "留存不足 2 秒时不应消失")
	# 再推 1 秒：超过 2 秒，应该消失
	for i in 60:
		_s.field.step(1.0 / 60.0)
	print("    总计约 2.5 秒后：场上条目=%d" % _s.field.items.size())
	_chk(_s.field.items.is_empty(), "留存满 2 秒后箭矢应消失")

	# ── 27. 待确认黄勾 + 远程/近战选目标二次确认 ──
	print("\n[27] 待确认黄勾")
	_s.clear_projectiles()
	var foe27 = null
	for u in _s.units:
		if u.side == UnitData.Side.ENEMY and not u.name.begins_with("Dummy"):
			foe27 = u
	# 近战：相邻敌格 -> 第一次点只出黄勾，第二次才弹攻击菜单
	gerald.cell = Vector2i(5, 5)
	gerald.visual.position = Vector3(5.5, 0.0, 5.5)
	gerald.begin_turn()
	_s.active = gerald
	_s.t_menu_attack()
	_chk(_s.phase == _s.Phase.CHOOSE_TARGET, "近战点普攻后应进入选目标（要确认）")
	foe27.cell = Vector2i(6, 5)
	foe27.power_cur = foe27.power_max
	foe27.visual.position = Vector3(6.5, 0.0, 5.5)
	_s.attackable = Targeting.attack_range_cells(gerald, _s.GW, _s.GH)
	_chk(_s.attackable.has(foe27.cell), "相邻敌格应在可攻击范围里")
	_s.t_set_pending("attack", foe27.cell, foe27)      # 第一次点
	_chk(_s.t_pending_root().visible, "待确认黄勾必须立刻出现（不能依赖调用方补 _draw_hints）")
	_s.t_draw_hints()
	print("    第一次点 %s：待确认=%s 黄勾可见=%s 笔画=%d" % [
		foe27.name, _s.t_pending_kind(), _s.t_pending_root().visible, _s.t_check_mats().size()])
	_chk(_s.t_pending_kind() == "attack" and _s.t_same_pending("attack", foe27.cell),
		"第一次点目标只是待确认，不弹菜单")
	_chk(_s.t_pending_root().visible, "待确认黄勾应出现")
	_chk(_s.t_check_mats().size() == 4, "黄勾 = 2 段笔画 × (亮芯 + 柔光)")
	# 朝向：必须正对摄像机（不能斜）
	_s.t_face_check_mark()
	var cb: Basis = _s.t_check_root().global_transform.basis
	var camz: Vector3 = _s.t_camera().global_transform.basis.z
	print("    黄勾朝向与摄像机 z 轴点积 = %.4f（1 = 完全正对）" % cb.z.normalized().dot(camz))
	_chk(absf(cb.z.normalized().dot(camz) - 1.0) < 0.001, "黄勾必须正对摄像机，不能斜")
	# 第二次点同一格 -> 确认，弹攻击菜单
	if _s.t_same_pending("attack", foe27.cell):
		_s.t_clear_pending()
		_s.t_show_attack_menu(foe27)
	_s.t_draw_hints()
	_chk(_s.t_attack_menu().visible, "第二次点同一目标才弹攻击菜单")
	_chk(not _s.t_pending_root().visible, "确认后黄勾必须消失")
	_s.t_attack_menu().visible = false
	# 远程：同样要确认
	alette.cell = Vector2i(9, 5)
	alette.visual.position = Vector3(9.5, 0.0, 5.5)
	alette.begin_turn()
	_s.active = alette
	_s.t_menu_attack()
	_chk(_s.phase == _s.Phase.CHOOSE_TARGET, "远程点普攻后也应进入选目标（要确认）")
	# 投掷手：直接进入瞄准，不需要确认
	var mortar27 = null
	for u in _s.units:
		if u.name == "Airburst mortar": mortar27 = u
	mortar27.begin_turn()
	_s.active = mortar27
	_s.t_menu_attack()
	_chk(_s.phase == _s.Phase.AIMING and _s.t_aim_active(), "投掷手瞄准不需要确认（直接进入拖动瞄准）")
	_s.t_set_aim_active(false)
	_s.t_arrow_root().visible = false

	# ── 28. 杰拉尔德被动：箭矢弹反 QTE ──
	print("\n[28] 箭矢弹反 QTE")
	# 清场：只留杰拉尔德和爱莱特站在弹道上，别的单位挪开（否则箭先打到别人）
	for u in _s.units:
		if u != gerald and u != alette:
			u.cell = Vector2i(1, 40)
			if u.visual != null:
				u.visual.position = Vector3(1.5, 0.0, 40.5)
	_s.clear_projectiles()
	gerald.cell = Vector2i(5, 5)
	gerald.visual.position = Vector3(5.5, 0.0, 5.5)
	gerald.power_cur = gerald.power_max
	alette.cell = Vector2i(5, 12)
	alette.visual.position = Vector3(5.5, 0.0, 12.5)
	alette.power_cur = Rules.points_to_milli(100)      # 保证打杰拉尔德真的掉血（否则 26 打 26 甲 = 0）
	_s.active = null

	# ① 按错一次 -> 立刻结算伤害；同一角色回合里的后续箭矢不再给机会
	_s.gm.on_turn_begin()
	var hp0: int = gerald.power_cur
	var arrow1: Projectile = _s.t_spawn_arrow(alette, Vector3(5.5, 0.75, 12.5),
		Vector3(5.5, 0.55, 5.5), gerald, false, true)
	var q1: ArrowQTE = null
	for i in 900:
		_s.field.step(1.0 / 60.0)
		q1 = _find_qte()
		if q1 != null or not arrow1.alive:
			break
	print("    箭：alive=%s 原因='%s' ｜ QTE=%s 全局暂停=%s ｜ 杰拉尔德力量 %d" % [
		arrow1.alive, arrow1.removed_reason, q1 != null, _s.get_tree().paused, gerald.power_cur])
	_chk(q1 != null, "箭矢命中杰拉尔德应立刻进入 QTE")
	_chk(_s.get_tree().paused, "QTE 期间必须暂停时间")
	_chk(gerald.power_cur == hp0, "QTE 期间先不结算伤害")
	if q1 != null:
		_chk(q1.keys.size() == 3, "应该有 3 次按键提示")
		print("    提示按键 = %s ｜ 窗口 = %s" % [q1.keys, q1.windows])
		_chk(q1.windows == [2.0, 1.0, 1.0], "窗口第一个 2 秒、后两个各 1 秒")
		var wrong := "z" if q1.keys[0] != "z" else "x"
		q1.press(wrong)
		await create_timer(0.6).timeout
		print("    按错后：暂停=%s 杰拉尔德力量 %d -> %d" % [
			_s.get_tree().paused, hp0, gerald.power_cur])
		_chk(not _s.get_tree().paused, "QTE 结束后必须解除暂停")
		_chk(gerald.power_cur < hp0, "按错一次立刻结算伤害")

	# ①b 同一个角色回合里的第二支箭：直接结算，不再弹 QTE（用户口径）
	_s.clear_projectiles()
	var hp_mid: int = gerald.power_cur
	var arrow1b: Projectile = _s.t_spawn_arrow(alette, Vector3(5.5, 0.75, 12.5),
		Vector3(5.5, 0.55, 5.5), gerald, false, true)
	var q1b: ArrowQTE = null
	for i in 900:
		_s.field.step(1.0 / 60.0)
		q1b = _find_qte()
		if q1b != null or not arrow1b.alive:
			break
	print("    同一回合第二支箭：QTE=%s 力量 %d -> %d" % [
		q1b != null, hp_mid, gerald.power_cur])
	_chk(q1b == null, "同一角色回合里只有第一支箭给 QTE 机会")
	_chk(gerald.power_cur < hp_mid, "第二支箭直接结算伤害")

	# ② 下一个角色回合：三次全对 -> 反弹回射手（落点由散步决定，发射者仍是原射手）
	await create_timer(0.4).timeout
	_chk(_find_qte() == null, "上一轮的 QTE 节点应该已经收掉")
	_s.gm.on_turn_begin()
	_s.clear_projectiles()
	var hp1: int = gerald.power_cur
	var al_hp: int = alette.power_cur
	# 第 93 轮：反弹箭力量系数回到 75%（52 × 75% = 39），护甲照样压低到 8 方便看伤害
	var al_armor0: int = alette.armor_cur
	alette.armor_cur = Rules.points_to_milli(8)
	var arrow2: Projectile = _s.t_spawn_arrow(alette, Vector3(5.5, 0.75, 12.5),
		Vector3(5.5, 0.55, 5.5), gerald, false, true)
	var q2: ArrowQTE = null
	for i in 900:
		_s.field.step(1.0 / 60.0)
		q2 = _find_qte()
		if q2 != null or not arrow2.alive:
			break
	_chk(q2 != null, "第二次命中应再次进入 QTE（新一轮机会）")
	if q2 != null:
		for i in 3:
			q2.press(q2.keys[i])
	await create_timer(0.6).timeout
	print("    三次全对：杰拉尔德力量 %d（应不变）｜场上弹道物 %d" % [
		gerald.power_cur, _s.live_projectiles()])
	_chk(gerald.power_cur == hp1, "三次全对不应受到伤害")
	var refl: Projectile = null
	for it in _s.field.items:
		var pp: Projectile = it["p"]
		if pp.kind == Projectile.KIND_ARROW and pp.alive and pp.shot != null \
				and pp.shot.caster == alette:
			refl = pp
	_chk(refl != null, "反弹后应有一支箭在飞")
	if refl != null:
		var d_refl: float = refl.from.distance_to(refl.to)
		print("    反弹箭：发射者=%s 起点=%s 落点=%s 距离=%.1f 格" % [
			refl.shot.caster.name, refl.from, refl.to, d_refl])
		_chk(refl.shot.caster == alette, "反弹箭绑定的发射者必须是【原射手】，不是杰拉尔德")
		_chk(refl.shot.caster != gerald, "反弹箭不能记在杰拉尔德头上")
		_chk(absf(refl.shot.power_mult - 0.75) < 0.0001,
			"反弹箭力量系数 = 75%%（第 93 轮，实际 %.2f）" % refl.shot.power_mult)
		_chk(d_refl <= 8.0, "7 格距离的散步很小，落点应贴在射手附近")
	# 让反弹箭飞完：应该打回射手身上
	for i in 900:
		_s.field.step(1.0 / 60.0)
		if refl != null and not refl.alive:
			break
	print("    反弹箭落地后：射手力量 %d -> %d（护甲 %d，75%% 力量系数）" % [
		al_hp, alette.power_cur, alette.armor_cur / 1000])
	_chk(alette.power_cur < al_hp, "反弹的箭应该打回射手身上")
	alette.armor_cur = al_armor0                # 还原，别影响后面的检查

	# ── 汇总 ──
	# ── 29. 英雄无限重生（GM 记 10 个回合，回到两公主之间的固定格）──
	print("\n[29] 英雄重生")
	_s.clear_projectiles()
	gerald.cell = Vector2i(5, 5)
	gerald.visual.position = Vector3(5.5, 0.0, 5.5)
	gerald.power_cur = 0
	# 用户口径：阵亡要清除一切状态（哨兵警戒 / 蓄势层数）
	_s.gm.add_sentry(gerald, 1, 8)
	Passives.add_focus(gerald)
	_s.t_on_unit_died(gerald)
	print("    阵亡后：哨兵=%s ｜ 蓄势层数=%d" % [_s.gm.has_sentry(gerald), Passives.focus_stacks(gerald)])
	_chk(not _s.gm.has_sentry(gerald), "阵亡应清除哨兵警戒")
	_chk(Passives.focus_stacks(gerald) == 0, "阵亡应清空蓄势层数")
	print("    杰拉尔德阵亡：还要等 %d 个回合 ｜ 归位格 %s ｜ 可见=%s" % [
		_s.gm.revive_countdown(gerald), gerald.home_cell, gerald.visual.visible])
	_chk(_s.gm.revive_countdown(gerald) == Level.respawn_turns("Gerald"),
		"英雄阵亡后要等 %d 个回合（场景元数据，第 100 轮）" % Level.respawn_turns("Gerald"))
	_chk(not gerald.visual.visible, "阵亡期间模型收起")
	_chk(Level.hero_cells(gerald.side).has(gerald.home_cell),
		"归位格必须是关卡给的英雄格（两公主之间）")
	# ⚠ 重生等待回合走**场景元数据**（第 100 轮：直升机 20、其余角色 15），
	#   不要再写死 `GameMaster.HERO_REVIVE_TURNS`（那是全局缺省 10）——
	#   写死的话"等到第 10 个回合"这句就永远等不到人，后面 5 条断言会连锁变红。
	var wait_turns: int = Level.respawn_turns("Gerald")
	for i in wait_turns - 1:
		_s.gm.dispatch_turn_boundary()
		for u in _s.gm.due_revives():
			_s.t_revive_hero(u)
	_chk(not gerald.is_alive(), "没到 %d 个回合还不能复活" % wait_turns)
	_s.gm.dispatch_turn_boundary()
	for u in _s.gm.due_revives():
		_s.t_revive_hero(u)
	print("    %d 个回合后：力量 %s/%s 护甲 %s/%s 位置 %s 可见=%s" % [
		wait_turns,
		gerald.power_cur / 1000.0, gerald.power_max / 1000.0,
		gerald.armor_cur / 1000.0, gerald.armor_max / 1000.0, gerald.cell, gerald.visual.visible])
	_chk(gerald.is_alive(), "%d 个回合后应满血复活" % wait_turns)
	_chk(gerald.power_cur == gerald.power_max and gerald.armor_cur == gerald.armor_max,
		"复活是满血满护甲")
	_chk(Level.hero_cells(gerald.side).has(gerald.cell), "复活位置在两公主之间的英雄格")
	_chk(gerald.visual.visible, "复活后模型可见")
	# 胜负只看国王
	var king = null
	for u in _s.units:
		if u.is_king and u.side == UnitData.Side.ENEMY:
			king = u
	_chk(king != null and TurnFlow.winner(_s.units) == TurnFlow.NONE, "双方国王都活着 -> 不算分胜负")
	if king != null:
		king.power_cur = 0
		_chk(TurnFlow.winner(_s.units) == TurnFlow.PLAYER, "敌方国王一死 -> 立刻判玩家胜")

	# ── 31. 锁定沙盒元素（近战 + 远程都能打木刺/土堆）──
	print("\n[31] 锁定沙盒元素")
	_s.clear_projectiles()
	_s.phase = _s.Phase.PLACE
	_s.t_set_place_kind("木刺")
	_s.place_left["木刺"] = 1
	_s.t_place_at(Vector2i(8, 8))
	_chk(_s.placeables.size() >= 1, "应能放下一个木刺")
	var spike2: Placeable = _s.placeables[_s.placeables.size() - 1]
	print("    木刺在 %s ｜ 力量 %d ｜ 阻挡远程=%s" % [spike2.cell, spike2.power_cur / 1000, spike2.block_ranged])
	# 近战：杰拉尔德贴着打
	gerald.cell = Vector2i(8, 9)
	gerald.has_acted = false
	gerald.has_moved = false
	_s.active = gerald
	var hp_spike: int = spike2.power_cur
	_s.t_attack_target_placeable(spike2)
	print("    杰拉尔德近战：木刺力量 %d -> %d" % [hp_spike / 1000, spike2.power_cur / 1000])
	_chk(spike2.power_cur < hp_spike or not spike2.is_alive(), "近战英雄应能锁定并打伤沙盒道具")
	# 远程：阿莱特射它（木刺不挡远程，但【明确锁定】必须打得中）
	spike2.power_cur = spike2.power_max
	alette.cell = Vector2i(8, 4)
	alette.has_acted = false
	alette.has_moved = false
	_s.active = alette
	_s.clear_projectiles()
	_s.t_attack_target_placeable(spike2)
	var arrow_ok: bool = _s.live_projectiles() >= 1
	for i in 300:
		if _s.field.items.is_empty():
			break
		_s.field.step(1.0 / 30.0)
	print("    阿莱特远程：出箭=%s ｜ 木刺力量 %d/%d" % [
		arrow_ok, spike2.power_cur / 1000, spike2.power_max / 1000])
	_chk(arrow_ok, "远程英雄应能对沙盒道具出箭")
	_chk(spike2.power_cur < spike2.power_max, "锁定的箭必须打中木刺（哪怕木刺不挡远程）")
	_s.phase = _s.Phase.IDLE
	_s.t_set_place_kind("")

	# ── 30. AI 决策（索敌打分 / 技能规避 / 休息与靠拢）──
	print("\n[30] AI 决策")
	_s.t_set_ai_enabled(true)
	var ctx := Ai.Ctx.new()
	ctx.rng = RngService.new(9)
	var ai_me: Unit = null
	for u in _s.units:
		if u.name == "Gerald": ai_me = u
	var foe_king: Unit = null
	for u in _s.units:
		if u.is_king and u.side != ai_me.side: foe_king = u
	ctx.me = ai_me
	ctx.foes = []
	for u in _s.units:
		if u.side != ai_me.side and u.is_alive(): ctx.foes.append(u)
	ctx.foe_king = foe_king
	ctx.reachable = _s.t_compute_reachable(ai_me)
	ctx.placeables = _s.placeables
	# ① 国王的分数必须高于远处的小兵
	var sc_king := Ai.score(ai_me, foe_king, Vector2i(9, 36), ctx)
	var sc_far := 0.0
	for u in ctx.foes:
		if not u.is_king:
			sc_far = Ai.score(ai_me, u, Vector2i(9, 36), ctx)
			break
	print("    打分：国王 %.1f ｜ 一个非国王目标 %.1f" % [sc_king, sc_far])
	_chk(sc_king > sc_far, "打国王的分数应高于打普通角色（胜利条件优先）")
	# ② 贴脸时应该直接打，不用走（构造：只有一个贴脸的敌人 + 不能走）
	var near: Unit = null
	for u in ctx.foes:
		if u.name == "Gerald (E)": near = u
	near.cell = Vector2i(10, 35)
	ai_me.cell = Vector2i(9, 35)
	var one_ctx := Ai.Ctx.new()
	one_ctx.rng = RngService.new(2)
	one_ctx.me = ai_me
	one_ctx.foes = [near]
	one_ctx.foe_king = near
	one_ctx.reachable = {}
	var pl := Ai.plan(one_ctx)
	print("    贴脸计划：%s（走位 %s）" % [pl.get("note", "-"), pl.get("move_to", null)])
	_chk(String(pl.get("action", "")) == "attack" and pl.get("move_to", null) == null,
		"能直接打到就该原地打，不要白走一步")
	# ③ 投掷手：有目标就优先技能；**只有"自己在敌方哨兵射界里"才不用**
	# ⚠ 第 110 轮：投掷手可能在到达这里之前就阵亡（回合推进改成"施放即结束"后战斗更快，
	#   实测它已不在场）-> 这里**先复活**，否则整段断言拿 null 去比，报的是"不在场"而非真实结论。
	var mortar_ai: Unit = null
	for u in _s.units:
		if u.name == "Airburst mortar": mortar_ai = u
	# ⚠ 第 110 轮：这两条断言要求投掷手**有足够精力**放地毯式轰炸（cost=6）。
	#   前面的战斗会把它精力花掉 -> 必须**无条件回满**（不是只在阵亡时复活）。
	if mortar_ai != null:
		mortar_ai.power_cur = mortar_ai.power_max
		mortar_ai.armor_cur = mortar_ai.armor_max
		mortar_ai.energy = mortar_ai.energy_max
	# ⚠ 第 110 轮：投掷手在战斗中会**漂到紧贴敌人的格子**（实测漂到 (1,40)、敌人 (0,40)），
	#   于是两条测试前提同时被破坏：① 它落进下面构造的 `sentry_cells` ->
	#   "自己不在敌方哨兵射界里"这条闸拦住；② 距离 1 格 < 地毯 `range_min` -> 够不着。
	#   所以这里**显式把它摆到敌人数格外**，让断言测的是"AI 决策"而不是"漂到哪了"。
	if mortar_ai != null and not ctx.foes.is_empty():
		var anchor: Vector2i = ctx.foes[0].cell
		mortar_ai.cell = Vector2i(clampi(anchor.x, 2, _s.PW - 3), clampi(anchor.y + 8, 2, _s.PH - 3))
	_chk(mortar_ai != null and mortar_ai.is_alive() and mortar_ai.energy_points() >= 6,
		"投掷手在场、活着且精力够放技能（下面三条断言的前提）")
	var mctx := Ai.Ctx.new()
	mctx.rng = RngService.new(3)
	mctx.me = mortar_ai
	mctx.foes = ctx.foes
	mctx.foe_king = foe_king
	mctx.reachable = {}
	mctx.placeables = []
	# 落点在哨兵射界里、但自己不在 -> 照丢（第 86 轮口径：不再检查落点）
	var blocked := {}
	for o in ctx.foes:
		blocked[o.cell] = true
		blocked[Vector2i(o.cell.x + 1, o.cell.y)] = true
	mctx.sentry_cells = blocked
	var mpl := Ai.plan(mctx)
	print("    投掷手（落点在哨兵射界里、自己不在）：%s" % mpl.get("note", "-"))
	_chk(String(mpl.get("action", "")) == "skill" and String(mpl.get("skill", "")) == "carpet_bomb",
		"投掷手面对目标永远优先用技能（落点是否在射界里不管）")
	# 自己踩在敌方哨兵射界里 -> 不用技能
	var walked_into := blocked.duplicate()
	walked_into[mortar_ai.cell] = true
	mctx.sentry_cells = walked_into
	var mpl2 := Ai.plan(mctx)
	print("    投掷手（自己在哨兵射界里）：%s" % mpl2.get("note", "-"))
	_chk(String(mpl2.get("action", "")) != "skill" or String(mpl2.get("skill", "")) != "carpet_bomb",
		"自己在敌方哨兵射界里时不用地毯式轰炸（用户口径第 86 轮）")
	mctx.sentry_cells = blocked
	# 同一个目标只出现一次：也应该丢技能（不再要求 ≥2 人挤在一起）
	var solo_ctx := Ai.Ctx.new()
	solo_ctx.rng = RngService.new(4)
	solo_ctx.me = mortar_ai
	solo_ctx.foes = [ctx.foes[0]]
	solo_ctx.foe_king = ctx.foes[0]
	solo_ctx.reachable = {}
	solo_ctx.sentry_cells = {}
	var mpl3 := Ai.plan(solo_ctx)
	print("    投掷手（只有 1 个目标）：%s" % mpl3.get("note", "-"))
	_chk(String(mpl3.get("action", "")) == "skill" and String(mpl3.get("skill", "")) == "carpet_bomb",
		"只有一个目标也优先用技能（第 86 轮：不再要求 ≥2 人集聚）")
	# ④ 打不到人 + 血不满 -> 休息；打不到人 + 血满 -> 靠拢
	#    用近战（没有技能分支干扰），敌人在很远处、且不是国王
	var foe_far: Unit = null
	for u in _s.units:
		if u.side != ai_me.side and not u.is_king and u.is_alive():
			foe_far = u
	foe_far.cell = Vector2i(40, 40)
	ai_me.cell = Vector2i(11, 3)
	ai_me.power_cur = ai_me.power_max
	ai_me.has_moved = false                      # 规划"靠拢/休息"要看这个 flag
	ai_me.has_acted = false
	var far_ctx := Ai.Ctx.new()
	far_ctx.rng = RngService.new(4)
	far_ctx.me = ai_me
	far_ctx.foes = [foe_far]
	far_ctx.foe_king = null
	far_ctx.reachable = {Vector2i(11, 4): true, Vector2i(11, 5): true}
	var p2 := Ai.plan(far_ctx)
	print("    满血够不着（距离 %d）：%s" % [Ai.manhattan(ai_me.cell, foe_far.cell), p2.get("note", "-")])
	_chk(String(p2.get("action", "")) == "move", "够不着又满血 -> 朝敌人靠拢")
	ai_me.power_cur = ai_me.power_max / 3
	print("    残血够不着：%s" % Ai.plan(far_ctx).get("note", "-"))
	_chk(String(Ai.plan(far_ctx).get("action", "")) == "rest", "够不着又残血 -> 休息")
	ai_me.power_cur = ai_me.power_max
	_s.t_set_ai_enabled(false)

	# ── 32. 日志只允许"既定事实"（谁打谁 / 伤害 / 谁触发了什么）──
	print("\n[32] 日志体检")
	var banned := ["点高亮格", "未选择角色", "再点一次", "还没轮到", "精力不足", "本回合已经行动过了",
		"无法使用", "不能休息", "先从道具箱", "选择攻击方式", "假人无 AI", "操作已锁定",
		"放不下", "没有可用技能", "用完了", "请点", "右键返回"]
	var bad: Array[String] = []
	for lg in _s.t_debug_log():
		var s := String(lg)
		for b in banned:
			if s.contains(b):
				bad.append(s)
	print("    日志共 %d 行，命中提示类文案 %d 行" % [_s.t_debug_log().size(), bad.size()])
	var tail: Array = _s.t_debug_log().slice(maxi(0, _s.t_debug_log().size() - 10))
	for lg in tail:
		print("    ｜%s" % String(lg))
	_chk(bad.is_empty(), "日志里不应出现提示/拒绝类文案（只有既定事实）")
	if not bad.is_empty():
		for b2 in bad.slice(0, 5):
			print("    ❌ 提示类日志：%s" % b2)

	# ── 33. 枪榴弹（落地成模型 + GM 计时 + 8 枚破片）与圣萨尼 ──
	print("\n[33] 枪榴弹与圣萨尼")
	_s.clear_projectiles()
	var sani: Unit = null
	for u in _s.units:
		if u.name == "萨尼铁塔": sani = u
	_chk(sani != null, "场上应有萨尼铁塔")
	# ① 落地：地上出现模型 + GM 开始计时
	var grn := Ordnance.make_grenade(sani, Vector2(6.5, 6.5), true)
	_s.t_spawn_grenade_model(Vector2i(6, 6), grn)
	print("    落地模型 %d 个 ｜ GM 在途 %d" % [_s.t_grenade_models().size(), _s.gm.pending.size()])
	_chk(_s.t_grenade_models().has(Vector2i(6, 6)), "手榴弹落地应留下模型（不可交互）")
	_chk(_s.gm.pending.size() == 1 and String(_s.gm.pending[0].skill_id) == "grenade",
		"GM 应开始 4 回合倒计时")
	# ② 4 个回合边界后爆炸 -> 破片数见 Skills 表（第 98 轮 = 12）
	var gcell := Vector2i(6, 6)
	for i in 4:
		for p in _s.gm.dispatch_turn_boundary():
			if String(p.skill_id) == "grenade":
				_s.t_explode_grenade(p)
	var frags := 0
	for it in _s.field.items:
		var pp: Projectile = it["p"]
		if pp.kind == Projectile.KIND_FRAGMENT and pp.alive:
			frags += 1
			_chk(pp.hit_self, "手榴弹破片必须能打自己人（hit_self）") if frags == 1 else null
	print("    爆炸后场上破片 %d 枚 ｜ 模型残留 %d" % [frags, _s.t_grenade_models().size()])
	_chk(frags == int(Skills.get_def("grenade_launcher")["fragments"]), "爆炸应撒出 %d 枚破片（第 98 轮：8 -> 12）" % int(Skills.get_def("grenade_launcher")["fragments"]))
	_chk(_s.t_grenade_models().is_empty(), "爆炸后模型应被清掉")
	print("    爆炸闪光节点 = %s" % ("有" if _s.t_last_flash() != null and is_instance_valid(_s.t_last_flash()) else "无"))
	_chk(_s.t_last_flash() != null and is_instance_valid(_s.t_last_flash()), "爆炸应有球状闪光（不是红圈）")
	_s.clear_projectiles()
	# ③ 圣萨尼：复活最后一个阵亡的队友，每条命一次
	var mate: Unit = null
	for u in _s.units:
		if u.name == "Gerald": mate = u
	mate.power_cur = 0
	_s.t_on_unit_died(mate)
	print("    队友阵亡：%s ｜ 她的标记=%s" % [mate.name, sani.tags.has("holy_sani_used")])
	# 第 99 轮（用户口径）：圣萨尼**不再复活队友**，改成"每个回合随机向受伤队友投医疗包"。
	# 所以这里改成验"不复活 + 旧标记不存在 + 受伤队友在场时会投出医疗包"。
	var kit0: int = _s.t_sani_medkit_count()
	_s.t_holy_sani_check(sani)
	print("    圣萨尼之后：队友 alive=%s 位置 %s ｜ 医疗包 %d -> %d" % [
		mate.is_alive(), mate.cell, kit0, _s.t_sani_medkit_count()])
	_chk(not mate.is_alive(), "圣萨尼不再复活队友（第 99 轮：旧口径已删除）")
	_chk(not sani.tags.has("holy_sani_used"), "不再有【每条命一次】的复活标记")
	# 把队友救回来并打伤，再投一次 -> 应该有医疗包
	mate.power_cur = mate.power_max
	mate.take_power_damage(Rules.points_to_milli(30))
	var kit1: int = _s.t_sani_medkit_count()
	_s.t_sani_throw_medkit()
	print("    手动投一次：医疗包 %d -> %d（选中目标 = %s）" % [
		kit1, _s.t_sani_medkit_count(), _s.t_sani_heal_roll()])
	_chk(_s.t_sani_medkit_count() > kit1, "受伤队友在场时萨尼会投出医疗包")
	_chk(mate.power_cur > 0, "队友仍然活着（没有被治疗逻辑弄死）")

	# ── 34. 直升机：坠机被动 + 俯冲轰炸 ──
	print("\n[34] 直升机")
	var heli: Unit = null
	for u in _s.units:
		if Unit.base_name(u.name).begins_with("俯冲轰炸直升机"): heli = u
	_chk(heli != null, "场上应有俯冲轰炸直升机")
	print("    悬浮高度 = %.1f ｜ 力 %d ｜ 甲 %d ｜ 移动 %d ｜ 射程 %d-%d" % [
		heli.hover, heli.power_cur / 1000, heli.armor_cur / 1000, heli.move, heli.rng_min, heli.rng_max])
	_chk(absf(heli.hover - 2.0) < 0.001, "悬浮离地 2 格")
	# 用户报过：直升机会不断往下掉（待机浮动 Tween 每帧把 y 拉回 0）——这里跑一段时间看它稳不稳
	var y0: float = heli.visual.position.y
	await create_timer(1.4).timeout
	var y1: float = heli.visual.position.y
	print("    悬浮高度：起始 %.3f -> 1.4 秒后 %.3f" % [y0, y1])
	_chk(absf(y0 - 2.0) < 0.01 and absf(y1 - 2.0) < 0.01, "悬浮高度必须稳定在 2 格（不受重力影响）")
	# 坠机：把力量打空（第 97 轮：只有力量归零才坠机，不再有"半血自毁"）
	_s.clear_projectiles()
	var victim_near: Unit = null
	for u in _s.units:
		if u.name == "Gerald": victim_near = u
	victim_near.cell = Vector2i(heli.cell.x + 1, heli.cell.y)
	victim_near.power_cur = victim_near.power_max
	victim_near.armor_cur = victim_near.armor_max
	heli.power_cur = 15 * 1000
	# 先确认"还剩 15 点力量"不坠机（第 97 轮删掉的那条半血自毁规则）
	_s.t_check_heli_crash(heli)
	_chk(not heli.tags.has("crashing"), "力量还剩 15 点【不】坠机（第 97 轮：删掉半血自毁）")
	heli.power_cur = 0
	var hp_crash: int = victim_near.power_cur
	_s.t_check_heli_crash(heli)
	print("    坠机触发：crashing=%s" % heli.tags.has("crashing"))
	_chk(heli.tags.has("crashing"), "力量归零应进入坠机")
	await create_timer(0.7).timeout
	print("    坠机后：直升机 alive=%s ｜ 邻居力量 %d -> %d" % [
		heli.is_alive(), hp_crash / 1000, victim_near.power_cur / 1000])
	_chk(not heli.is_alive(), "坠机后直升机死亡")
	_chk(victim_near.power_cur < hp_crash, "坠机炮击应打到 2.5 格内的角色")
	_chk(_s.gm.revive_countdown(heli) > 0, "坠机后应进入重生倒计时")
	# 俯冲轰炸：准备状态 -> AI 可读 -> 俯冲 -> 投弹 -> 返航
	heli.power_cur = heli.power_max
	_s.t_revive_hero(heli)
	heli.energy = heli.energy_max
	var dtgt := Vector2i(heli.cell.x + 4, heli.cell.y)
	_s.t_cast_dive(heli, dtgt)
	print("    准备状态：ready=%s 目标=%s ｜ 标识节点=%d" % [
		Ai.heli_is_ready(heli), Ai.heli_ready_target(heli), _s.t_dive_markers().size()])
	_chk(Ai.heli_is_ready(heli) and Ai.heli_ready_target(heli) == dtgt, "应进入准备状态并记住目标格")
	_chk(_s.t_dive_markers().size() == 1, "目标格应有地面标识（橙色圆盘）")
	_chk(Ai.heli_threatens_cell(heli, dtgt + Vector2i(1, 1)), "AI 能算出它威胁到的格子")
	_chk(Ai.ready_helis([heli]).size() == 1, "AI 能列出正在准备的敌方直升机")
	_chk(_s.t_dive_begin(heli), "轮到它的回合应开始爬升轰炸")
	_chk(heli.tags.has("diving"), "爬升轰炸中要打上 diving 标记")
	var dummy_v: Unit = victim_near
	dummy_v.cell = dtgt
	dummy_v.power_cur = dummy_v.power_max
	var hp_bomb: int = dummy_v.power_cur
	var top_h := 0.0
	# ⚠ 第 103 轮（投弹半径 3 → 6 之后才暴露的测试写法问题）：
	#   炸弹的下落 `Tween` 走**真实时间**，而以前这里用**紧循环**手工推 `t_dive_tick(1/60)`
	#   （400 次几毫秒就跑完，真实时间几乎没走）→ 循环结束时炸弹**还没落地**，
	#   于是"投弹不能炸到自己"这条断言在**投弹后**立刻检查，而那时直升机还在返航途中。
	#   半径 3 时它够不着自己（所以以前一直是绿的），半径 6 之后就打到了 → 假红。
	#   正确做法：**让场景自己按真实 delta 推进**，并按真实时间等炸弹落地。
	for i in 600:
		await create_timer(1.0 / 60.0).timeout
		top_h = maxf(top_h, heli.visual.position.y)
		if not heli.tags.has("diving"):
			break
	print("    爬升轰炸结束：diving=%s ｜ 最高爬到 %.2f 格 ｜ 目标格角色力量 %d -> %d" % [
		heli.tags.has("diving"), top_h, hp_bomb / 1000, dummy_v.power_cur / 1000])
	print("    爬升高度（第 86 轮口径）：%.2f 格（要求 >= %.1f，才不会炸到自己）" % [
		top_h, float(Level.heli()["climb_h"])])
	_chk(not heli.tags.has("diving"), "爬升轰炸应完整走完（投弹后返航）")
	_chk(top_h >= float(Level.heli()["climb_h"]) - 0.01, "要爬到设定高度再投弹")
	await create_timer(1.4).timeout          # 炸弹下落 1 秒后才触地结算
	print("    投弹后：目标格角色力量 %d -> %d" % [hp_bomb / 1000, dummy_v.power_cur / 1000])
	_chk(dummy_v.power_cur < hp_bomb, "投弹应打到目标格半径 3 格内的角色")
	_chk(heli.power_cur == heli.power_max, "投弹不能炸到自己（爬到安全高度了）")

	# ── 35. 选技能链路（枪榴弹）：说明文案 + 刷新界面不许崩（用户报过崩溃）──
	print("\n[35] 枪榴弹选技能链路")
	_s.active = sani
	_s.t_set_aim_skill_id("grenade_launcher")
	_s.t_set_skill_info_text(Skills.detail_text("grenade_launcher"))
	_s.t_refresh_all()
	var info: String = _s.ui_skill_info()
	print("    说明文案长度 = %d ｜ 前 40 字：%s" % [info.length(), info.substr(0, mini(40, info.length()))])
	_chk(info.length() > 0, "选中枪榴弹后应能生成技能说明（不崩）")
	_chk(int(Skills.get_def("grenade_launcher")["cost"]) == 2, "枪榴弹仍是 2 精力")
	_s.t_set_aim_skill_id("")
	_s.t_set_skill_info_text("")

	# ── 36. 直升机普攻（真实 _fire 路径）+ 坠机（真实受伤路径）──
	print("\n[36] 直升机普攻与坠机（真实路径）")
	_s.clear_projectiles()
	var he2: Unit = null
	for u in _s.units:
		if Unit.base_name(u.name).begins_with("俯冲轰炸直升机"): he2 = u
	he2.cell = Vector2i(6, 6)
	he2.visual.position = Vector3(6.5, he2.hover, 6.5)
	he2.energy = he2.energy_max
	he2.has_acted = false
	he2.has_moved = false
	_s.active = he2
	_s.phase = _s.Phase.AIMING
	_s.t_set_aim_active(true)
	_s.t_set_aim_valid(true)
	_s.t_set_aim_origin(Vector2.ZERO)
	_s.t_set_aim_now(Vector2(200, 0))
	_s.t_set_aim_float_pos(Vector2(20.5, 6.5))
	_s.t_set_planned_cell(Vector2i(20, 6))
	_s.t_set_aim_skill_id("")
	var e0: int = he2.energy_points()
	_s.t_fire()
	var rockets := 0
	for it in _s.field.items:
		var pp: Projectile = it["p"]
		if pp.kind == Projectile.KIND_ROCKET: rockets += 1
	print("    一次普攻：场上火箭 %d 发 ｜ 精力 %d -> %d ｜ 回合已结束=%s" % [
		rockets, e0, he2.energy_points(), _s.active != he2])
	_chk(rockets == 2, "第一次齐射应左右各一发（第 93 轮：共 8 次、16 发，每两波间隔 1 秒）")
	_chk(he2.energy_points() == e0 - 4, "普攻必须消耗 4 点精力")
	_chk(int(Level.heli()["salvo_gap"] * 1000.0) == 500, "第 95 轮：每两波火箭弹间隔 0.5 秒")
	# 齐射是异步的：等它把 8 次打完（间隔 0.5 秒 -> 至少 3.5 秒）
	await _wait_salvo()
	var rockets2 := 0
	for it2 in _s.field.items:
		var pp2: Projectile = it2["p"]
		if pp2.kind == Projectile.KIND_ROCKET: rockets2 += 1
	print("    齐射完成：场上火箭（含在飞）%d 发 ｜ 已出膛波次 %d" % [
		rockets2, (_s.t_salvo_dbg().get("spawns", []) as Array).size()])
	_chk(rockets2 >= 6, "齐射应陆续出膛（不等落地，3.5 秒内 16 发基本都在飞）")
	_chk((_s.t_salvo_dbg().get("spawns", []) as Array).size() == int(Level.heli()["salvo_pairs"]),
		"8 次齐射全部出膛（第 93 轮：4 -> 8）")
	_chk(_s.active != he2, "发射完即进入下一回合（无需等待落地）")
	# 坠机：走"受伤"这条真实路径（第 97 轮：力量归零才坠机）
	_s.clear_projectiles()
	he2.power_cur = 15 * 1000
	he2.tags.erase("crashing")
	var nb: Unit = null
	for u in _s.units:
		if u.name == "Gerald": nb = u
	nb.cell = Vector2i(he2.cell.x + 1, he2.cell.y)
	nb.power_cur = nb.power_max
	var nb0: int = nb.power_cur
	_s.t_after_damage_to_unit(he2)
	_chk(not he2.tags.has("crashing"), "还剩 15 点力量：受伤路径也【不】坠机（第 97 轮）")
	he2.power_cur = 0
	_s.t_after_damage_to_unit(he2)
	print("    受伤路径：crashing=%s" % he2.tags.has("crashing"))
	_chk(he2.tags.has("crashing"), "力量归零后【受伤】必须触发坠机（真实路径）")
	await create_timer(0.7).timeout
	print("    坠机结果：alive=%s ｜ 邻居力量 %d -> %d ｜ 重生倒计时 %d" % [
		he2.is_alive(), nb0 / 1000, nb.power_cur / 1000, _s.gm.revive_countdown(he2)])
	_chk(not he2.is_alive(), "坠机后应死亡")
	_chk(nb.power_cur < nb0, "坠机炮击应打到 2.5 格内的角色")
	_chk(_s.gm.revive_countdown(he2) > 0, "坠机死亡后应有重生倒计时")

	# ── 37. 手榴弹走真实 GM 路径爆炸 + 出界防护 ──
	print("\n[37] 手榴弹 GM 路径与出界防护")
	_s.clear_projectiles()
	for k in _s.t_grenade_models().keys():
		pass
	var sani3: Unit = null
	for u in _s.units:
		if u.name == "萨尼铁塔": sani3 = u
	var g3 := Ordnance.make_grenade(sani3, Vector2(7.5, 7.5), true)
	_s.t_spawn_grenade_model(Vector2i(7, 7), g3)
	print("    落地后 GM 在途 = %d（skill=%s delay=%d）" % [
		_s.gm.pending.size(),
		String(_s.gm.pending[0].skill_id) if _s.gm.pending.size() > 0 else "-",
		int(_s.gm.pending[0].delay) if _s.gm.pending.size() > 0 else -1])
	_chk(_s.gm.pending.size() == 1, "手榴弹落地必须由 GM 登记")
	for i in 4:
		await _s.t_gm_step()                       # 真实路径：回合边界 -> GM 到期 -> 爆炸
	var frag := 0
	for it in _s.field.items:
		var pp3: Projectile = it["p"]
		if pp3.kind == Projectile.KIND_FRAGMENT and pp3.alive: frag += 1
	print("    4 个回合边界后：破片 %d 枚 ｜ 残留模型 %d ｜ GM 在途 %d" % [
		frag, _s.t_grenade_models().size(), _s.gm.pending.size()])
	_chk(frag == int(Skills.get_def("grenade_launcher")["fragments"]), "手榴弹 4 回合后应爆炸并撒出 %d 枚破片（真实 GM 路径）" % int(Skills.get_def("grenade_launcher")["fragments"]))
	_chk(_s.t_grenade_models().is_empty(), "爆炸后地上模型应清掉")
	# 出界防护：钳制 + 移动不会跑出地图
	var he3: Unit = null
	for u in _s.units:
		if Unit.base_name(u.name).begins_with("俯冲轰炸直升机"): he3 = u
	print("    钳制：(-5, 999) -> %s ｜ (9999, -3) -> %s" % [
		_s.t_clamp_cell(Vector2i(-5, 999)), _s.t_clamp_cell(Vector2i(9999, -3))])
	var c1: Vector2i = _s.t_clamp_cell(Vector2i(-5, 999))
	_chk(_s.t_in_bounds(c1) and _s.t_in_bounds(_s.t_clamp_cell(Vector2i(9999, -3))),
		"任何格子都会被钳进地图内（永不出界）")
	_s.t_do_move(he3, Vector2i(-8, -8))
	await create_timer(0.4).timeout
	print("    强制向场外移动后：位置 %s ｜ 在界内=%s" % [he3.cell, _s.t_in_bounds(he3.cell)])
	_chk(_s.t_in_bounds(he3.cell), "单位不可能被移动到地图外")

	# ── 38. 普攻/技能统一入口（本轮重构的防回归核心）──
	# 病根：一次普攻有四条并行入口，每加一个角色要改四处；漏一处就出 bug
	#       （直升机火箭只接了拖拽、坠机只挂了俯冲、枪榴弹 AI 分支被冲掉）。
	# 现在：入口只算"打哪里"，全部调 _perform_basic / _perform_skill。
	print("\n[38] 统一入口：三条普攻入口必须产出同一击")
	_s.t_set_ai_enabled(false)
	_clear_ai_corner()          # 国王/公主挪到角落：免得他们的加农炮在探测期间打死参战者
	_s.clear_projectiles()
	_s.gm.pending.clear()
	_s.gm.clear_all_sentries()
	# 代表角色：近战 / 弓箭 / 连发 / 投掷 / 火箭齐射
	var reps := [
		_unit_by("Gerald", 0),
		_unit_by("Alette", 0),
		_unit_by("萨尼铁塔", 0),
		_unit_by("Airburst mortar", 0),
		_unit_by(AttackProfile.HELI_PREFIX + "（不要问那么多）", 0),
	]
	var fp_ok := 0
	for u in reps:
		if u == null:
			continue
		var rep_victim := _unit_by("Alette", 1 - u.side)
		if rep_victim == null or rep_victim == u:
			rep_victim = _unit_by("Gerald", 1 - u.side)
		if rep_victim == null:
			continue
		# 只有该模板允许的入口才参与比对：近战是"点目标"，没有拖拽普攻
		var entries: Array = ["click", "ai"]
		if AttackProfile.basic_of(u) != AttackProfile.BASIC_MELEE:
			entries.push_front("drag")
		var sigs: Array = []
		for e in entries:
			sigs.append(await _basic_sig(u, rep_victim, String(e)))
		var same := true
		for i in range(1, sigs.size()):
			if sigs[i] != sigs[0]:
				same = false
		print("    %s（%s）× %s：%s" % [u.name, AttackProfile.basic_of(u), str(entries), sigs[0]])
		if not same:
			print("       ❌ 不一致：%s" % [sigs])
		else:
			fp_ok += 1
		_chk(same, "%s：%s 三条入口产出完全一致" % [u.name, str(entries)])
		_chk(String(sigs[0]).begins_with("有效 1") and String(sigs[0]).contains("已出手 1"),
			"%s：普攻一定要真的出手（不是空挥）" % u.name)
	print("    指纹一致的角色 = %d / %d" % [fp_ok, reps.size()])
	# 直升机必须消耗精力（曾被漏掉：只走拖拽那条时点目标/AI 不耗精力）
	var heli_p: Unit = _unit_by(AttackProfile.HELI_PREFIX + "（不要问那么多）", 0)
	_chk(heli_p != null and AttackProfile.cost_of(heli_p) == 4, "直升机普攻 = 4 精力（模板给出的）")

	# ── 38b. 精力不足：不许"先占回合再打不出来"（真实软锁过）──
	print("\n[38b] 精力不足不许软锁")
	var heli_b: Unit = _unit_by(AttackProfile.HELI_PREFIX + "（不要问那么多）", 0)
	var foe_b := _unit_by("Gerald", 1 - heli_b.side)
	heli_b.cell = Vector2i(10, 10)
	foe_b.cell = Vector2i(14, 10)
	heli_b.energy = 0
	heli_b.has_acted = false
	heli_b.has_moved = false
	_s.clear_projectiles()
	_s.active = heli_b
	_s.phase = _s.Phase.IDLE
	_s.t_attack_target_unit(foe_b, false)
	print("    点目标入口：火箭 %d 发 ｜ 已出手=%s ｜ 精力 %d" % [
		_count_kind(Projectile.KIND_ROCKET), heli_b.has_acted, heli_b.energy_points()])
	_chk(_count_kind(Projectile.KIND_ROCKET) == 0, "精力不足时不许出弹")
	_chk(not heli_b.has_acted, "精力不足时不许占掉这一次行动（否则玩家白亏一回合）")
	# AI 出手：打不出也必须自己收尾（不然 AI 回合卡死，以前靠 9 秒看门狗兜）
	_s.t_set_turn_just_finished(null)
	_s.active = heli_b
	var tc_b0: int = _s.gm.turn_count
	_s.t_ai_attack(heli_b, {"target": foe_b, "aim": Vector2(14.5, 10.5)})
	await create_timer(0.4).timeout          # 回合收尾是异步的（_finish_turn -> _gm_step -> _next_turn）
	print("    AI 入口：火箭 %d 发 ｜ 推进了回合边界=%s" % [
		_count_kind(Projectile.KIND_ROCKET), _s.gm.turn_count > tc_b0])
	_chk(_count_kind(Projectile.KIND_ROCKET) == 0, "AI 精力不足时也不许出弹")
	_chk(_s.gm.turn_count > tc_b0, "AI 打不出来时必须自己结束回合（绝不允许软锁）")
	# AI 决策层：付不起的普攻根本不该被选中
	heli_b.energy = 0
	heli_b.has_acted = false
	heli_b.has_moved = false
	heli_b.cell = Vector2i(10, 10)
	foe_b.cell = Vector2i(12, 10)
	foe_b.power_cur = foe_b.power_max
	var broke_plan := Ai.plan(_s.t_ai_ctx(heli_b))
	print("    精力 0 的直升机 AI 选择：%s（%s）" % [
		broke_plan.get("action", "-"), broke_plan.get("note", "-")])
	_chk(String(broke_plan.get("action", "")) != "attack",
		"AI 不会选一个自己付不起的普攻（否则出手即空转）")
	_chk(String(broke_plan.get("action", "")) == "rest",
		"付不起普攻时所有 AI 都必须选【休息】（用户口径第 86 轮）")
	# 对照：同一个人，精力够就该打（说明上面选休息不是别的原因）
	heli_b.energy = heli_b.energy_max
	var paid_plan := Ai.plan(_s.t_ai_ctx(heli_b))
	print("    精力满的同一个直升机：%s" % paid_plan.get("action", "-"))
	_chk(String(paid_plan.get("action", "")) == "attack", "精力够就该打（对照）")
	heli_b.energy = 0
	heli_b.energy = heli_b.energy_max

	# ── 38c. 技能：玩家入口与 AI 入口同一条生产线 ──
	print("\n[38c] 技能双路径（玩家 / AI）")
	# ⚠ 第 104 轮：新角色「轮式齐射午餐盒」按用户口径**只出场在竞技场 / Reaper 战**，
	#   测试场（本试玩跑的关卡）刻意没有它。但它带一个技能 `loiter_launch`，
	#   而下面这组是"**每个技能都必须有测试施法者**"的通用契约 —— 为了不让它漏测，
	#   这里**在试玩场景里就地造一辆**（就地造比中途 reload 关卡安全得多：
	#   reload 会把前面几十节的场景状态全冲掉，而且是无头下最容易挂住的写法）。
	var lb: Unit = _unit_by("轮式齐射午餐盒", 0)
	if lb == null:
		var lb_def := {}
		for d in UnitData.UNITS:
			if String(d["name"]) == "轮式齐射午餐盒":
				lb_def = d
		if not lb_def.is_empty():
			lb = Unit.from_data(lb_def)
			lb.cell = Vector2i(8, 8)
			lb.home_cell = lb.cell
			_s.units.append(lb)
			# 挂 visual：照 `_reaper_do_summon` 的成例（宿主没有公开的 attach 门面，
			# 而 `UnitVisual.setup` 是既有的公开入口）
			var lv := UnitVisual.new()
			_s.add_child(lv)
			lv.setup(lb)
			print("    就地造了一辆轮式齐射午餐盒 @ %s（它不在测试场名单里）" % str(lb.cell))
	# 第 111 轮：雷达午餐盒也**不在测试场名单里**（用户口径：它不能影响巡飞弹的选目标，
	#   而 playtest 会把 field 的单位堆在一起 -> 叠格会让 `_unit_at` 返回友方）。
	#   同样"就地造一台"，让它带的新技能 `radar_link` 也有施法者可测。
	var rb: Unit = _unit_by(Radar.NAME, 0)
	if rb == null:
		var rb_def := {}
		for d in UnitData.UNITS:
			if String(d["name"]) == Radar.NAME:
				rb_def = d
		if not rb_def.is_empty():
			rb = Unit.from_data(rb_def)
			rb.cell = Vector2i(6, 6)
			rb.home_cell = rb.cell
			_s.units.append(rb)
			var rv := UnitVisual.new()
			_s.add_child(rv)
			rv.setup(rb)
			print("    就地造了一台雷达午餐盒 @ %s（它不在测试场名单里）" % str(rb.cell))
	var casters := {
		"sentry": _unit_by("Alette", 0),
		"dive_bomb": _unit_by(AttackProfile.HELI_PREFIX + "（不要问那么多）", 0),
		"grenade_launcher": _unit_by("萨尼铁塔", 0),
		"carpet_bomb": _unit_by("Airburst mortar", 0),
		"orbital_strike": _unit_by("Gerald", 0),
		"loiter_launch": lb,
		"radar_link": rb,
	}
	for sid in Skills.DEFS:
		var sid_s := String(sid)
		var caster: Unit = casters.get(sid_s, null)
		if caster == null:
			_chk(false, "技能 %s 找不到测试用施法者" % sid_s)
			continue
		caster.cell = Vector2i(10, 10)
		if caster.visual != null:
			caster.visual.position = Vector3(10.5, caster.hover, 10.5)
		var aim := Vector2(14.5, 10.5)
		var tcell := Vector2i(14, 10)
		# 第 111 轮：`aim=ally`（雷达连接）的目标必须是**真实友军**，写死的 (14,10) 那格没人
		# -> 共享/AI 两个入口都会返回 false。这里按 aim 类型挑一个真实目标格。
		if Skills.aim_of(sid_s) == Skills.AIM_ALLY:
			var friend_pick: Unit = null
			for cand in _s.units:
				if cand == null or not cand.is_alive() or cand == caster:
					continue
				if cand.side != caster.side:
					continue
				if GridMath.unit_pos(caster).distance_to(GridMath.unit_pos(cand)) <= 16.0:
					friend_pick = cand
					break
			if friend_pick != null:
				aim = GridMath.unit_pos(friend_pick)
				tcell = friend_pick.cell
		var cast_kind := Skills.cast_of(sid_s)
		var aim_kind := Skills.aim_of(sid_s)
		# ① 共享入口（玩家所有入口最终都调它）
		# 注：把 _turn_just_finished 指成施法者自己，_finish_turn() 的幂等保护就会直接返回，
		#     免得回合推进把刚放下的状态（俯冲准备 / 哨兵）当场消费掉，干扰效果计数。
		_reset_skill_scene(caster)
		_s.active = caster
		_s.t_set_turn_just_finished(caster)
		var ok_shared: bool = _s.t_perform_skill(caster, sid_s, aim, tcell)
		var eff_shared := _skill_effect(sid_s, caster)
		# ② AI 入口
		_reset_skill_scene(caster)
		_s.active = caster
		_s.t_set_turn_just_finished(caster)
		_s.t_ai_skill(caster, {"skill": sid_s, "aim": aim, "cell": tcell})
		var eff_ai := _skill_effect(sid_s, caster)
		# ③ 玩家真实入口：拖拽类走 _fire，点格子类走 _choose_skill + _confirm_cell_target，
		#    点一下类（哨兵）走 _choose_skill
		_reset_skill_scene(caster)
		_s.active = caster
		_s.t_set_turn_just_finished(caster)
		var eff_ui := -1
		if aim_kind == Skills.AIM_DRAG:
			_s.phase = _s.Phase.AIMING
			_s.t_set_aim_active(true)
			_s.t_set_aim_valid(true)
			_s.t_set_aim_origin(Vector2.ZERO)
			_s.t_set_aim_now(Vector2(220, 0))
			_s.t_set_aim_float_pos(aim)
			_s.t_set_planned_cell(tcell)
			_s.t_set_aim_skill_id(sid_s)
			_s.t_fire()
			eff_ui = _skill_effect(sid_s, caster)
		elif aim_kind == Skills.AIM_CELL:
			_s.t_choose_skill(sid_s)
			var targeting: bool = _s.t_cell_targeting()
			_s.t_confirm_cell_target(tcell)
			eff_ui = _skill_effect(sid_s, caster)
			_chk(targeting, "%s：点格子类技能会进入选格阶段（不拖拽、不投标记球）" % sid_s)
		elif aim_kind == Skills.AIM_UNIT:
			# ⚠ 第 105 轮：`AIM_UNIT` = **点选一个敌方角色**（用户口径："一定要做选择目标而不是瞄准！"）。
			#   这条就是**用户真正会走的那条路**：选技能 -> 高亮敌人 -> 点敌人（两次确认）-> 施放。
			#   （上一轮这里还是拖拽写法，所以巡飞弹在真机上"点了没反应"—— 底层函数是好的，是 UI 路径对不上。）
			#   ⚠ 必须用 `t_click_cell`（= 鼠标点击那条真实代码），**不能**用 `ui_click_unit`
			#   （那是"选中看属性"的入口，不走选目标/施放的分派）。
			_s.t_choose_skill(sid_s)
			var unit_targeting: bool = _s.phase == _s.Phase.CHOOSE_TARGET
			# 挑一个在射程内的目标：`aim=ally`（雷达连接）要**友军**，其余要**敌人**。
			var want_ally: bool = Skills.aim_of(sid_s) == Skills.AIM_ALLY
			var picked: Unit = null
			var reach := float(Skills.get_def(sid_s).get("range_max", 32.0))
			for cand in _s.units:
				if cand == null or not cand.is_alive() or cand == caster:
					continue
				if want_ally != (cand.side == caster.side):
					continue
				if GridMath.unit_pos(caster).distance_to(GridMath.unit_pos(cand)) <= reach:
					picked = cand
					break
			if picked == null:
				_chk(false, "%s：射程内找不到可点选的%s目标" % [sid_s, "友军" if want_ally else "敌方"])
			else:
				# 第一次点 = 黄勾确认，第二次点 = 真的施放（与弓箭手同一套两次确认）
				_s.t_click_cell(picked.cell)
				_s.t_click_cell(picked.cell)
				eff_ui = _skill_effect(sid_s, caster)
			_chk(unit_targeting, "%s：点选目标类技能会进入选目标阶段（不拖拽）" % sid_s)
		else:
			_s.t_choose_skill(sid_s)
			eff_ui = _skill_effect(sid_s, caster)
		print("    %s（cast=%s aim=%s）：共享=%d ｜ AI=%d ｜ 玩家入口=%d" % [
			sid_s, cast_kind, aim_kind, eff_shared, eff_ai, eff_ui])
		_chk(ok_shared and eff_shared >= 1, "%s：统一入口真的产生了效果" % sid_s)
		_chk(eff_ai == eff_shared, "%s：AI 入口与统一入口效果一致" % sid_s)
		_chk(eff_ui == eff_shared, "%s：玩家入口与统一入口效果一致" % sid_s)
		_reset_skill_scene(caster)
	_s.t_set_turn_just_finished(null)
	# 精力不足用不出技能：不扣精力、不进状态
	var sani_z: Unit = _unit_by("萨尼铁塔", 0)
	sani_z.energy = 0
	_s.active = sani_z
	var ok_poor: bool = _s.t_perform_skill(sani_z, "grenade_launcher", Vector2(14.5, 10.5), Vector2i(14, 10))
	print("    精力 0 用枪榴弹：成功=%s ｜ 精力 %d ｜ 弹道物 %d" % [
		ok_poor, sani_z.energy_points(), _count_kind(Projectile.KIND_GRENADE)])
	_chk(not ok_poor and sani_z.energy_points() == 0, "精力不足时技能不许施放、也不许扣成负数")
	_chk(_count_kind(Projectile.KIND_GRENADE) == 0, "精力不足时不许真的扔出枪榴弹")
	sani_z.energy = sani_z.energy_max

	# ── 38d. 被动钩子表：被动表里声明的受伤被动都必须有实现 ──
	print("\n[38d] 受伤被动钩子表")
	var missing_hooks: Array = []
	for u in _s.units:
		for id in Passives.damaged_hooks(u):
			if not _s.t_passive_hooks().has(String(id)):
				missing_hooks.append(String(id))
	print("    钩子表 = %s ｜ 直升机受伤被动 = %s" % [
		_s.t_passive_hooks().keys(), Passives.damaged_hooks(heli_p)])
	_chk(missing_hooks.is_empty(), "battle_scene 的钩子表覆盖所有 on_damaged 被动（漏了 %s）" % [missing_hooks])
	_chk(not _s.t_passive_hooks().is_empty(), "钩子表不是空的（否则坠机这类被动会静默失效）")

	# ── 39. 极端情况：双方英雄同时全灭（不进队列的国王/公主还活着）──
	# 以前这里会 _next_turn -> _start_round -> _next_turn 无限递归，栈溢出（AI 演算里真实发生）
	print("\n[39] 英雄全灭：不许无限递归（栈溢出）")
	# 前面的小节可能已经分出过胜负 / 打死过国王：先把国王恢复、把胜负标记清掉，
	# 否则 _begin_next_round 会因为"已经结束"直接返回，测不到要测的那条路径。
	for u in _s.units:
		if u.is_king:
			u.power_cur = u.power_max
			u.armor_cur = u.armor_max
			if u.visual != null:
				u.visual.visible = true
	_s.game_over = false
	var killed := 0
	for u in _s.units:
		if u.has_turn() and u.is_king == false and u.is_alive():
			u.power_cur = 0
			_s.t_on_unit_died(u)
			killed += 1
	_s.queue = TurnQueue.new(_s.rng)
	_s.queue.rebuild(_s.units)
	var round0: int = _s.round_no
	var left_actors := TurnFlow.hero_counts(_s.units)
	print("    打死 %d 人 ｜ 能进队列的还剩 %s ｜ 第 %d 轮" % [killed, left_actors, round0])
	_chk(left_actors[0] == 0 and left_actors[1] == 0, "测试前提：场上已没有能进队列的单位")
	_s.t_set_ai_enabled(false)
	_s.t_set_turn_just_finished(null)
	_s.active = null
	var tcb: int = _s.gm.turn_count
	_s.t_next_turn()                       # 关键：这里以前会递归到栈溢出
	await create_timer(1.2).timeout
	var left2 := TurnFlow.hero_counts(_s.units)
	print("    1.2 秒后：轮次 %d（+%d）｜ 能行动的 %s ｜ 推进边界 %d ｜ 胜负已分=%s" % [
		_s.round_no, _s.round_no - round0, left2, _s.gm.turn_count - tcb, _s.game_over])
	_chk(_s.round_no - round0 <= 3,
		"没有可行动单位时不许无限递归重开（轮次暴涨 = 栈溢出）")
	_chk(_s.gm.turn_count - tcb > 0, "等复活期间会推进回合边界（复活计时照常走）")
	_chk(left2[0] > 0 or left2[1] > 0 or _s.game_over,
		"推进回合边界后英雄会复活（或直接判结束），战斗不会卡死")

	# ── 40. 移动结束后才能开火（第 86 轮口径）──
	print("\n[40] 移动结束后才能释放技能/普攻")
	var he_e: Unit = _unit_by(AttackProfile.HELI_PREFIX + "（不要问那么多）", 1)
	var mate_e: Unit = _unit_by("Gerald", 1)
	var foe_p: Unit = _unit_by("Alette", 0)
	he_e.power_cur = he_e.power_max
	he_e.energy = he_e.energy_max
	he_e.controllable = false              # 这一节要测"AI 操作的直升机"，所以先摘掉可控标记
	he_e.cell = Vector2i(10, 10)
	he_e.visual.position = Vector3(10.5, he_e.hover, 10.5)
	_s.t_set_ai_enabled(false)
	_s.t_set_turn_just_finished(null)
	_s.active = he_e
	# 发起一次移动：AI 走位函数必须等它走完才返回（摇杆期间不许开火）
	_do_move_probe_start = Time.get_ticks_msec()
	await _s.t_ai_move(he_e, Vector2i(10, 20))
	print("    走位结束：逻辑格 %s ｜ 视觉位置 (%.2f, %.2f) ｜ 还在走=%s ｜ 用时 %.1f 秒（2.5 格/秒）" % [
		he_e.cell, _s.t_unit_pos(he_e).x, _s.t_unit_pos(he_e).y, he_e.visual.is_walking(),
		(Time.get_ticks_msec() - _do_move_probe_start) / 1000.0])
	_chk(not he_e.visual.is_walking(), "AI 走位函数会等走完（移动中不释放技能/普攻）")
	_chk(_s.t_unit_pos(he_e).distance_to(Vector2(10.5, 20.5)) < 0.05,
		"走完后视觉位置 = 脚下格中心（不会停在半路）")
	_chk(he_e.visual.walk_speed > 2.4 and he_e.visual.walk_speed < 2.6,
		"直升机移动速度 = 2.5 格/秒（第 86 轮）")
	# 站定后开火：所有齐射都从脚下这个位置出膛
	_s.clear_projectiles()
	_s.t_ai_attack(he_e, {"target": mate_e, "aim": Vector2(10.5, 30.5)})
	var wave1: Array[Vector2] = []
	var ids1: Array = []
	for it in _s.field.items:
		var pp: Projectile = it["p"]
		if pp.kind == Projectile.KIND_ROCKET:
			wave1.append(pp.from)
			ids1.append(pp.id)
	var here: Vector2 = _s.t_unit_pos(he_e)
	var near_fire := 0
	for f in wave1:
		if f.distance_to(here) < 0.6:
			near_fire += 1
	var salvo0: Dictionary = _s.t_salvo_dbg()
	print("    第一波 %d 发：出膛 %s ｜ 当前位置 (%.2f, %.2f) ｜ 基准 %s" % [
		wave1.size(), wave1, here.x, here.y, salvo0.get("base", "-")])
	_chk(wave1.size() == 2, "第一波应有左右各一发")
	_chk(near_fire == wave1.size(), "齐射必须从脚下（当前位置）出膛")
	_chk((salvo0.get("base", Vector2.ZERO) as Vector2).distance_to(here) < 0.001,
		"齐射基准 = 开火那一刻的当前位置")
	await create_timer(float(Level.heli()["salvo_gap"]) + 0.15).timeout
	var wave2: Array[Vector2] = []
	for it2 in _s.field.items:
		var pp2: Projectile = it2["p"]
		if pp2.kind == Projectile.KIND_ROCKET and not ids1.has(pp2.id):
			wave2.append(pp2.from)
	var same_spot := true
	for f2 in wave2:
		if f2.distance_to(here) > 0.6:
			same_spot = false
	print("    第二波 %d 发：出膛 %s（应与第一波同一处）" % [wave2.size(), wave2])
	_chk(wave2.size() >= 2, "第二波也应出膛（间隔 %.1f 秒）" % float(Level.heli()["salvo_gap"]))
	_chk(same_spot and (he_e.visual.is_walking() == false), "站定开火：两波都从同一处出膛")
	await _wait_salvo()                      # 等 8 波打完，别污染后面
	_s.clear_projectiles()

	# ── 41. 敌方直升机坠毁：死亡附加伤害必须打到所有人（不分敌我）──
	print("\n[41] 敌方直升机坠毁的附加伤害")
	var he_c: Unit = _unit_by(AttackProfile.HELI_PREFIX + "（不要问那么多）", 1)
	var bud_p: Unit = _unit_by("Gerald", 0)
	var bud_e: Unit = _unit_by("Alette", 1)
	for w in [he_c, bud_p, bud_e]:
		w.power_cur = w.power_max
		w.armor_cur = w.armor_max
		w.tags.erase("crashing")
		if w.visual != null:
			w.visual.visible = true
	he_c.cell = Vector2i(12, 10)
	he_c.visual.position = Vector3(12.5, he_c.hover, 12.5)
	bud_p.cell = Vector2i(13, 10)          # 我方：紧贴坠机点
	bud_p.visual.position = Vector3(13.5, 0.0, 13.5)
	bud_e.cell = Vector2i(11, 10)          # 敌方友军：也要吃（不分敌我）
	bud_e.visual.position = Vector3(11.5, 0.0, 11.5)
	he_c.power_cur = 0                     # 力量归零（第 97 轮：只有归零才坠机）
	var hp_p0: int = bud_p.power_cur
	var hp_e0: int = bud_e.power_cur
	_s.t_after_damage_to_unit(he_c)          # 真实受伤路径 -> 坠机
	print("    触发坠机：crashing=%s" % he_c.tags.has("crashing"))
	_chk(he_c.tags.has("crashing"), "敌方直升机力量归零 -> 坠机（走受伤主路径）")
	await create_timer(0.8).timeout
	print("    落地后：直升机 alive=%s ｜ 我方 %d -> %d ｜ 敌方 %d -> %d" % [
		he_c.is_alive(), hp_p0 / 1000, bud_p.power_cur / 1000, hp_e0 / 1000, bud_e.power_cur / 1000])
	_chk(not he_c.is_alive(), "坠机后敌方直升机死亡")
	_chk(bud_p.power_cur < hp_p0, "坠机的死亡附加伤害必须打到我方单位")
	_chk(bud_e.power_cur < hp_e0, "坠机的死亡附加伤害不分敌我（敌方友军也吃）")

	# ── 42. 远程瞄准悬停的直升机（高度轴，第 83 轮）──
	print("\n[42] 远程瞄准悬停的直升机")
	var he_t: Unit = _unit_by(AttackProfile.HELI_PREFIX + "（不要问那么多）", 1)
	var arch_t: Unit = _unit_by("Alette", 0)
	for w2 in [he_t, arch_t]:
		w2.power_cur = w2.power_max
		w2.armor_cur = w2.armor_max
		w2.tags.erase("crashing")
		w2.tags.erase("diving")
		if w2.visual != null:
			w2.visual.visible = true
	he_t.power_cur = Rules.points_to_milli(100)      # 抬高上限：只要看到掉血，不触发坠机
	he_t.cell = Vector2i(10, 10)
	he_t.visual.position = Vector3(10.5, he_t.hover, 10.5)
	arch_t.cell = Vector2i(10, 16)
	arch_t.visual.position = Vector3(10.5, 0.0, 16.5)
	arch_t.has_acted = false
	arch_t.has_moved = false
	arch_t.energy = arch_t.energy_max
	_s.clear_projectiles()
	_s.gm.clear_all_sentries()
	_s.t_set_turn_just_finished(null)
	_s.active = arch_t
	var hp_t0: int = he_t.power_cur
	_s.t_attack_target_unit(he_t, false)
	var arrow_y := -1.0
	var arrow_to := Vector2.ZERO
	for it3 in _s.field.items:
		var pa: Projectile = it3["p"]
		if pa.kind == Projectile.KIND_ARROW:
			arrow_y = pa.y1
			arrow_to = pa.to
	print("    箭的出膛瞄准点 (%.1f, %.1f) 高度 %.2f ｜ 直升机悬停 %.1f" % [
		arrow_to.x, arrow_to.y, arrow_y, he_t.hover])
	_chk(absf(arrow_y - Targeting.aim_height(he_t)) < 0.01,
		"瞄悬停的直升机要抬到它的身体中心（%.1f）" % Targeting.aim_height(he_t))
	await create_timer(2.0).timeout
	print("    箭飞完：直升机力量 %d -> %d" % [hp_t0 / 1000, he_t.power_cur / 1000])
	_chk(he_t.power_cur < hp_t0, "远程普攻必须能真的打到悬停的直升机（高度轴正确）")
	_s.clear_projectiles()

	# ── 43. 俯冲轰炸：粉色可选格 + 两次点击确认（第 84 轮）──
	print("\n[43] 俯冲轰炸选格：粉色高亮 + 两次确认")
	var he_p: Unit = _unit_by(AttackProfile.HELI_PREFIX + "（不要问那么多）", 0)
	he_p.power_cur = he_p.power_max
	he_p.energy = he_p.energy_max
	he_p.has_acted = false
	he_p.has_moved = false
	he_p.cell = Vector2i(10, 10)
	he_p.visual.position = Vector3(10.5, he_p.hover, 10.5)
	he_p.tags.erase("dive_ready")
	_s.t_dive_clear(he_p)
	_s.t_set_ai_enabled(false)
	_s.t_set_turn_just_finished(he_p) # 让 _finish_turn() 的幂等保护生效：别让回合机马上把准备状态消费掉
	_s.t_clear_pending()
	_s.active = he_p
	_s.t_choose_skill("dive_bomb")
	# 第 109 轮：技能射程 20 -> 64（真值源 `Skills.get_def("dive_bomb")["range_max"]`）。
	# ⚠ 断言不再硬编码 20，而是**读真值源**，这样以后再调射程这条会自动跟上。
	var dive_range := float(Skills.get_def("dive_bomb")["range_max"])
	var want_cells: Dictionary = Targeting.disc_cells(Vector2(10.5, 10.5), dive_range,
		_s.PW, _s.PH, _s.PX, _s.PY)
	print("    进入选格：粉色格 %d（期望 %d，射程 %.0f）｜ 目标格在集合里=%s ｜ 已选格=%s" % [
		_s.cell_targets.size(), want_cells.size(), dive_range,
		_s.cell_targets.has(Vector2i(14, 10)), _s.t_pending_kind()])
	_chk(_s.t_cell_targeting(), "俯冲轰炸进入【点格子】阶段（不拖拽）")
	_chk(_s.cell_targets.size() == want_cells.size() and _s.cell_targets.size() > 100,
		"可选格 = %.0f 格圆盘内的所有格子（粉色高亮）" % dive_range)
	# 射程内取一个近格、射程外取一个**必然超程**的远格 —— 都按真值源算，别再写死坐标
	# （写死会随射程改动假红：原来写的 (10,40) 距圆心 29.5 格，射程 64 时**已经够得着**）
	var out_probe := Vector2i(10, 10 + int(dive_range) + 5)
	_chk(_s.cell_targets.has(Vector2i(14, 10)) and not _s.cell_targets.has(out_probe),
		"射程内是可选格、射程外不是（近格在内、%s 在外）" % str(out_probe))
	# 第一次点：只出黄勾，不放技能
	var cast1: bool = _s.t_click_cell_target(Vector2i(14, 10))
	print("    第一次点 (14,10)：施放=%s ｜ 待确认=%s ｜ 目标格=%s" % [
		cast1, _s.t_pending_kind(), _s.t_pending_cell()])
	_chk(not cast1 and _s.t_pending_kind() == "cell" and _s.t_pending_cell() == Vector2i(14, 10),
		"第一次点只出黄勾（两次点击确认）")
	_chk(not he_p.tags.has("dive_ready"), "第一次点不许真的放技能")
	# 点另一格：黄勾跟着移动（仍然不放）
	_s.t_click_cell_target(Vector2i(15, 10))
	_chk(_s.t_pending_cell() == Vector2i(15, 10) and not he_p.tags.has("dive_ready"),
		"改点别的格子只是移动黄勾")
	# 第二次点同一格：确认施放
	var cast2: bool = _s.t_click_cell_target(Vector2i(15, 10))
	print("    第二次点 (15,10)：施放=%s ｜ 目标=%s ｜ 粉色格残留=%d" % [
		cast2, he_p.tags.get("dive_ready", "-"), _s.cell_targets.size()])
	_chk(cast2 and he_p.tags.has("dive_ready") and he_p.tags["dive_ready"] == Vector2i(15, 10),
		"第二次点同一格才真的进入俯冲准备")
	_chk(_s.cell_targets.is_empty() and not _s.t_cell_targeting(), "放完技能后粉色高亮要收干净")
	# 超程的格子：不画勾、不施放
	_s.t_dive_clear(he_p)
	he_p.tags.erase("dive_ready")
	he_p.energy = he_p.energy_max
	he_p.has_acted = false
	_s.active = he_p
	_s.t_choose_skill("dive_bomb")
	# 第 109 轮：射程 20 -> 64，所以"超程格"要真的超过程序算出来的射程
	# （原来写死的 (10,40) 距圆心 29.5 格，在 64 射程下**已经够得着**了 → 会假红）。
	# 这里按真值源反推一个**必然超程**的格子：沿 +y 推 `射程 + 5` 格。
	var over := int(dive_range) + 5
	var far_cell := Vector2i(10, 10 + over)
	var cast3: bool = _s.t_click_cell_target(far_cell)
	print("    点超程格 %s（距圆心约 %d 格 > 射程 %.0f）：施放=%s ｜ 待确认=%s" % [
		far_cell, over, dive_range, cast3, _s.t_pending_kind()])
	_chk(not cast3 and _s.t_pending_kind() == "" and not he_p.tags.has("dive_ready"),
		"超出 %.0f 格的格子点了不作数（提示重新点）" % dive_range)
	_s.t_clear_pending()
	_s.cell_targets = {}
	_s.t_set_cell_targeting(false)
	_s.t_show_action_menu()

	# ── 44. 火箭也能被箭击落（炮弹类统一模板，第 84 轮）──
	print("\n[44] 火箭被箭击落")
	_s.clear_projectiles()
	var he_s: Unit = _unit_by(AttackProfile.HELI_PREFIX + "（不要问那么多）", 1)
	var bud_s: Unit = _unit_by("Gerald", 0)
	for w3 in [he_s, bud_s]:
		w3.power_cur = w3.power_max
		w3.armor_cur = w3.armor_max
		w3.tags.erase("crashing")
		if w3.visual != null:
			w3.visual.visible = true
	he_s.cell = Vector2i(4, 5)
	he_s.visual.position = Vector3(4.5, he_s.hover, 5.5)
	# 弹道物互相判定是"水平面重叠"：两条弹道必须在同一行，否则永远不会撞上
	var rk_s := Ordnance.make_rocket(he_s, Vector3(4.5, 2.0, 5.5), Vector2(16.0, 5.5), false)
	_s.field.register(rk_s)
	var ar_s: Projectile = _s.t_spawn_arrow(bud_s, Vector3(16.0, 0.75, 5.5), Vector3(4.0, 0.55, 5.5),
		null, false, false)
	_chk(rk_s.hit_tags.has(Projectile.KIND_ARROW) and Ballistics.can_shoot_down(Projectile.KIND_ARROW, rk_s),
		"火箭声明自己怕箭（炮弹类统一模板）")
	_s.t_debug_log().clear()                    # 日志是环形缓冲：先清空，再看这一段里有没有"空爆"
	for i4 in 400:
		_s.field.step(1.0 / 60.0)
		if not rk_s.alive:
			break
	var burst := false
	for lg4 in _s.t_debug_log():
		if String(lg4).contains("空爆"):
			burst = true
	print("    火箭 alive=%s 原因='%s' 位置 %s ｜ 箭 alive=%s ｜ 空爆日志=%s" % [
		rk_s.alive, rk_s.removed_reason, rk_s.removed_at, ar_s.alive, burst])
	_chk(not rk_s.alive and rk_s.removed_reason == "shot_down", "火箭会被箭击落")
	_chk(burst, "火箭被击落后走统一的空爆结算（有日志）")
	_s.clear_projectiles()

	# ── 45. 火箭还没落地就撞到角色 = 当成在命中处落地（第 87 轮）──
	print("\n[45] 火箭撞到角色 -> 在命中处落地")
	_s.clear_projectiles()
	_s.gm.clear_all_sentries()               # 公主会射箭拦火箭，先请她们下班
	var he_v: Unit = _unit_by(AttackProfile.HELI_PREFIX + "（不要问那么多）", 1)
	var tgt_v: Unit = _unit_by("Gerald", 0)
	for u5 in _s.units:
		u5.cell = Vector2i(1, 40)
		if u5.visual != null:
			u5.visual.position = Vector3(1.5, u5.hover, 40.5)
	he_v.cell = Vector2i(4, 5)
	he_v.visual.position = Vector3(4.5, he_v.hover, 5.5)
	he_v.power_cur = he_v.power_max
	# 靶子站在弹道末端：那里火箭已经降到 1 格以下（撞得到人）
	tgt_v.cell = Vector2i(15, 5)
	tgt_v.visual.position = Vector3(15.5, 0.0, 5.5)
	tgt_v.power_cur = tgt_v.power_max
	tgt_v.armor_cur = 0
	tgt_v.pr = 0
	var hp_v: int = tgt_v.power_cur
	var frags0: int = _count_kind(Projectile.KIND_FRAGMENT)
	_s.t_debug_log().clear()
	var rk_v := Ordnance.make_rocket(he_v, Vector3(4.5, he_v.hover + 0.25, 5.5),
		Vector2(16.0, 5.5), false)
	_s.field.register(rk_v)
	for i5 in 900:
		_s.field.step(1.0 / 60.0)
		if not rk_v.alive:
			break
	var landed_log := false
	var burst_log := false
	for lg5 in _s.t_debug_log():
		if String(lg5).contains("当成在"):
			landed_log = true
		if String(lg5).contains("空爆"):
			burst_log = true
	print("    火箭 alive=%s 原因='%s' 位置 (%.1f, %.1f) ｜ 杰拉尔德 %d -> %d ｜ 破片 %d -> %d" % [
		rk_v.alive, rk_v.removed_reason, rk_v.pos().x, rk_v.pos().y,
		hp_v, tgt_v.power_cur, frags0, _count_kind(Projectile.KIND_FRAGMENT)])
	print("    日志：落地=%s 空爆=%s" % [landed_log, burst_log])
	_chk(not rk_v.alive and rk_v.removed_reason == "body_impact",
		"火箭撞到角色的消亡原因 = 命中处落地（不是 shot_down）")
	_chk(landed_log, "日志写明「当成在命中处落地结算」")
	_chk(not burst_log, "撞到人不再走空爆（空爆只留给被箭击落的）")
	_chk(tgt_v.power_cur < hp_v, "命中处落地必须真的造伤（以前这里常常整发作废）")
	_chk(_count_kind(Projectile.KIND_FRAGMENT) >= frags0 + Ordnance.ROCKET_FRAGMENTS,
		"火箭在命中处落地照常撒出 %d 枚破片" % Ordnance.ROCKET_FRAGMENTS)
	_s.clear_projectiles()

	# ── 46. 枪榴弹：落地后与投出者解耦，投出者阵亡也照常爆炸（第 87 轮）──
	print("\n[46] 枪榴弹与投出者解耦")
	_s.clear_projectiles()
	var sani_g: Unit = _unit_by("萨尼铁塔", 0)
	sani_g.cell = Vector2i(12, 20)
	sani_g.visual.position = Vector3(12.5, 0.0, 20.5)
	sani_g.power_cur = sani_g.power_max
	sani_g.armor_cur = sani_g.armor_max
	sani_g.energy = sani_g.energy_max
	sani_g.has_acted = false
	sani_g.has_moved = false
	_s.active = sani_g
	var gp_cell := Vector2i(20, 20)
	var gp: Projectile = _s.t_spawn_grenade_shot(sani_g, Vector2(20.5, 20.5), "grenade_launcher")
	for i6 in 900:
		_s.field.step(1.0 / 60.0)
		if not gp.alive:
			break
	print("    落地：alive=%s 模型=%s ｜ GM：%s" % [
		gp.alive, _s.t_grenade_models().has(gp_cell), _s.gm.pending_desc()])
	_chk(not gp.alive and _s.t_grenade_models().has(gp_cell), "枪榴弹落地：地上立起弹体模型")
	_chk(_s.gm.decoupled_count() == 1, "落地后 GM 里这一条已和投出者解耦")
	# 投出者阵亡（用户报的 bug：萨尼扔完就死 -> 手榴弹不炸了）
	var pend0: int = _s.gm.pending.size()
	sani_g.power_cur = 0
	_s.t_on_unit_died(sani_g)
	print("    萨尼阵亡：GM 待引爆 %d -> %d ｜ 解耦条数 %d" % [
		pend0, _s.gm.pending.size(), _s.gm.decoupled_count()])
	_chk(_s.gm.pending.size() == pend0 and _s.gm.decoupled_count() == 1,
		"投出者阵亡不会取消已落地的手榴弹")
	_s.t_debug_log().clear()
	for i7 in int(Skills.get_def("grenade_launcher")["delay_turns"]):
		_s.t_gm_step()                        # 真实路径：GM 回合边界 -> 到点引爆
	var boom := false
	for lg6 in _s.t_debug_log():
		if String(lg6).contains("手榴弹爆炸"):
			boom = true
	print("    %d 个回合边界后：爆炸日志=%s ｜ 模型还在=%s" % [
		int(Skills.get_def("grenade_launcher")["delay_turns"]), boom, _s.t_grenade_models().has(gp_cell)])
	_chk(boom, "投出者已阵亡，手榴弹照样到点爆炸")
	_chk(not _s.t_grenade_models().has(gp_cell), "爆炸后弹体模型必须回收（不能留在地上）")
	_s.clear_projectiles()

	# ── 47. 队列：阵亡当场移出 / 复活压回队头（第 87 轮：修"复活饥饿"）──
	print("\n[47] 队列：阵亡移出 / 复活压队头")
	var qv: Unit = _unit_by("Alette", 1)
	# ⚠ 第 103 轮：投弹从"半径 3 / 20 力量"变成"**半径 6 / 120 力量**"之后它变得真能打死人，
	#   所以跑到这里时这位敌人**很可能已经在前面的小节里阵亡过**了。
	#   而 `on_unit_died` 是**幂等**的（`uid_dead` 里有他 + 他已经不是 alive → 直接 return），
	#   于是"再杀一次"不会走移除队列那一步 → 这条断言假红。
	#   这里先把他**救活并把阵亡记账清掉**，让这一节从头复现"首次阵亡"。
	qv.power_cur = qv.power_max
	qv.armor_cur = qv.armor_max
	_s.uid_dead.erase(qv)
	_s.queue.rebuild(_s.units)
	var in_q0: bool = _s.queue.p_queue.has(qv) or _s.queue.e_queue.has(qv)
	qv.power_cur = 0
	_s.t_on_unit_died(qv)
	var in_q1: bool = _s.queue.p_queue.has(qv) or _s.queue.e_queue.has(qv)
	print("    阵亡前在队列=%s ｜ 阵亡后在队列=%s ｜ %s" % [in_q0, in_q1, _s.queue.dump()])
	_chk(in_q0 and not in_q1, "阵亡的人当场移出队列（不是跳到队尾）")
	# 模拟"他不在队列里"的处境（旧实现里全灭重排就会把他甩掉，活过来也没回合）
	_s.queue.rebuild(_s.units)
	var in_q2: bool = _s.queue.p_queue.has(qv) or _s.queue.e_queue.has(qv)
	_s.t_revive_hero(qv)
	var eqv: Array[Unit] = _s.queue.p_queue if qv.side == UnitData.Side.PLAYER else _s.queue.e_queue
	print("    重排时在队列=%s ｜ 复活后队头=%s（本方 %d 人）" % [
		in_q2, eqv[0].name if eqv.size() > 0 else "-", eqv.size()])
	_chk(not in_q2, "重排时他不在队列里（旧实现就是这样把活过来的人饿死的）")
	_chk(eqv.size() > 0 and eqv[0] == qv, "复活：压回自己这条队列的队头")
	var seen_q: Array[String] = []
	for i8 in 4:
		var cu2: Unit = _s.queue.current()
		seen_q.append(cu2.name if cu2 != null else "-")
		_s.queue.advance(cu2)
	print("    复活后接下来 4 个行动者：%s" % [seen_q])
	_chk(seen_q.has(qv.name), "复活的人立刻出现在行动序列里（不会再饿死）")
	# 用户报的场景（复活饥饿）：一方全灭 -> 对面一直动 -> 活过来的人必须立刻接上回合
	var px_n := 0
	var first_rev: Unit = null
	for u9 in _s.units:
		if u9.side == UnitData.Side.PLAYER and u9.has_turn():
			if first_rev == null:
				first_rev = u9
			u9.power_cur = 0
			_s.t_on_unit_died(u9)
			px_n += 1
	var e_only: bool = not _s.queue.has_side(UnitData.Side.PLAYER) \
		and _s.queue.has_side(UnitData.Side.ENEMY)
	var after_q: Array[String] = []
	for i9 in 3:
		var cu3: Unit = _s.queue.current()
		after_q.append(cu3.name if cu3 != null else "-")
		_s.queue.advance(cu3)
	print("    我方 %d 个英雄全灭：我方队列空=%s ｜ 对面接下来：%s" % [
		px_n, not _s.queue.has_side(UnitData.Side.PLAYER), after_q])
	_chk(e_only, "一方全灭 -> 那条队列清空，对面连续行动（不会卡住）")
	_chk(not after_q.has("-"), "全灭期间对面照常一个一个动")
	_s.t_revive_hero(first_rev)
	var got_turn := false
	for i10 in 3:
		if _s.queue.current() == first_rev:
			got_turn = true
			break
		_s.queue.advance(_s.queue.current())
	print("    复活 %s -> 最多等对面 1 个回合就轮到（结果=%s）" % [first_rev.name, got_turn])
	_chk(got_turn, "复活的人立刻接上回合（旧实现里他排在队尾，永远轮不到）")

	# ── 48. 火箭：发射者阵亡之后落地照样造伤（第 89 轮）──
	print("\n[48] 火箭落地伤害快照（发射者阵亡也照打）")
	_s.clear_projectiles()
	_s.gm.clear_all_sentries()
	var p89_he: Unit = _unit_by(AttackProfile.HELI_PREFIX + "（不要问那么多）", 0)
	var p89_vic: Unit = _unit_by("Gerald", 1)
	for p89_u in _s.units:
		p89_u.cell = Vector2i(2, 44)
		if p89_u.visual != null:
			p89_u.visual.position = Vector3(2.5, p89_u.hover, 44.5)
	p89_he.cell = Vector2i(10, 5)
	p89_he.visual.position = Vector3(10.5, p89_he.hover, 5.5)
	p89_he.power_cur = p89_he.power_max
	p89_he.armor_cur = p89_he.armor_max
	p89_he.tags.erase("crashing")
	p89_he.visual.visible = true
	p89_he.body_y = -1.0
	p89_vic.cell = Vector2i(10, 12)
	p89_vic.visual.position = Vector3(10.5, 0.0, 12.5)
	p89_vic.power_cur = p89_vic.power_max
	p89_vic.armor_cur = 0
	p89_vic.pr = 0
	var p89_hp: int = p89_vic.power_cur
	var p89_rk := Ordnance.make_rocket(p89_he, Vector3(10.5, p89_he.hover + 0.25, 5.5),
		Vector2(10.5, 12.5), false, _s.rng)
	_s.field.register(p89_rk)
	# 出膛之后立刻让发射者阵亡（用户报的"火箭落地不造伤"就是这个）
	p89_he.power_cur = 0
	_s.t_on_unit_died(p89_he)
	for p89_i in 900:
		_s.field.step(1.0 / 60.0)
		if not p89_rk.alive:
			break
	print("    火箭 alive=%s 原因='%s' ｜ 目标力量 %d -> %d（发射者已阵亡）" % [
		p89_rk.alive, p89_rk.removed_reason, p89_hp, p89_vic.power_cur])
	_chk(not p89_rk.alive and p89_vic.power_cur < p89_hp,
		"发射者阵亡后火箭落地照样造伤（发射单里是开火那一刻的快照）")
	_s.clear_projectiles()
	p89_he.power_cur = p89_he.power_max
	_s.t_revive_hero(p89_he)

	# ── 49. 技能移动也要触发哨兵（第 89 轮）──
	print("\n[49] 技能移动触发哨兵")
	_s.clear_projectiles()
	_s.gm.clear_all_sentries()
	var p89_dive: Unit = _unit_by(AttackProfile.HELI_PREFIX + "（不要问那么多）", 1)
	var p89_watch: Unit = _unit_by("公主", 0)     # 「公主·左/·右」的基础名就是「公主」
	for p89_u2 in _s.units:
		p89_u2.cell = Vector2i(2, 44)
		if p89_u2.visual != null:
			p89_u2.visual.position = Vector3(2.5, p89_u2.hover, 44.5)
	p89_watch.cell = Vector2i(10, 20)
	p89_watch.visual.position = Vector3(10.5, 0.0, 20.5)
	p89_watch.power_cur = p89_watch.power_max
	p89_watch.visual.visible = true
	_s.gm.add_sentry(p89_watch, p89_watch.rng_min, p89_watch.rng_max)   # 射界 1~12
	p89_dive.cell = Vector2i(10, 34)          # 起点在射界外（14 格）
	p89_dive.visual.position = Vector3(10.5, p89_dive.hover, 34.5)
	p89_dive.power_cur = p89_dive.power_max
	p89_dive.armor_cur = p89_dive.armor_max
	p89_dive.tags.erase("crashing")
	p89_dive.visual.visible = true
	p89_dive.energy = p89_dive.energy_max
	p89_dive.tags["dive_ready"] = Vector2i(10, 26)   # 目标在射界内（6 格）
	_s.t_debug_log().clear()
	_s.active = null
	_s.t_set_turn_just_finished(p89_dive) # 收尾的 _finish_turn 变空操作（别把 AI 回合带起来）
	var p89_began: bool = _s.t_dive_begin(p89_dive)
	for p89_i2 in 1200:
		_s.t_dive_tick(1.0 / 60.0)
		if not p89_dive.tags.has("diving"):
			break
	var p89_locked := false
	for p89_lg in _s.t_debug_log():
		if String(p89_lg).contains("哨兵锁定"):
			p89_locked = true
	print("    开始=%s ｜ 哨兵队列=%d ｜ 日志有哨兵锁定=%s" % [
		p89_began, _s.gm.sentry_queue_size(), p89_locked])
	_chk(p89_began and p89_locked,
		"技能飞行从射界外飞进射界 -> 触发哨兵（以前只有走路会触发）")
	_chk(_s.gm.sentry_queue_size() >= 1, "直升机被排进哨兵队列")
	_s.gm.clear_all_sentries()
	_s.clear_projectiles()

	# ── 50. 普攻按钮的精力检测（第 89 轮）──
	print("\n[50] 普攻按钮精力检测")
	var p89_btn: Unit = _unit_by(AttackProfile.HELI_PREFIX + "（不要问那么多）", 0)
	p89_btn.power_cur = p89_btn.power_max
	p89_btn.energy = p89_btn.energy_max
	p89_btn.has_acted = false
	p89_btn.has_moved = false
	p89_btn.tags.erase("diving")
	p89_btn.body_y = -1.0
	_s.active = p89_btn
	var p89_ai0: bool = _s.t_ai_turn()
	_s.t_set_ai_turn(false)
	_s.t_show_action_menu()
	var p89_cost: int = AttackProfile.cost_of(p89_btn)
	var p89_ok_txt: String = _s.t_btn_attack().text
	_chk(p89_cost > 0 and not _s.t_btn_attack().disabled, "精力够（%d 点）：普攻按钮可点" % p89_cost)
	p89_btn.energy = 0
	_s.t_show_action_menu()
	print("    精力满：文本='%s' ｜ 精力 0：disabled=%s 提示='%s'" % [
		p89_ok_txt, _s.t_btn_attack().disabled, _s.t_btn_attack().tooltip_text])
	_chk(_s.t_btn_attack().disabled, "精力不足：普攻按钮置灰")
	# 灰了之后硬调也不许进瞄准流程
	_s.t_menu_attack()
	_chk(_s.phase == _s.Phase.MENU, "精力不足时 _menu_attack 直接返回（不进入瞄准）")
	p89_btn.energy = p89_btn.energy_max
	_s.t_show_action_menu()
	_chk(not _s.t_btn_attack().disabled, "精力恢复后按钮重新可点")
	_s.t_set_ai_turn(p89_ai0) # 还原：别把还在跑的 AI 回合保护关掉

	# ── 51. 枪榴弹破片方向随机（第 89 轮）──
	print("\n[51] 枪榴弹破片方向随机")
	_s.clear_projectiles()
	for p89_u3 in _s.units:
		p89_u3.cell = Vector2i(2, 44)
		if p89_u3.visual != null:
			p89_u3.visual.position = Vector3(2.5, p89_u3.hover, 44.5)
	var p89_x: GameMaster.Pending = _s.gm.schedule_grenade(Vector2i(20, 30), "萨尼铁塔", 0, 4)
	_s.t_debug_log().clear()
	_s.t_explode_grenade(p89_x)
	var p89_dirs: Array[float] = []
	for p89_it in _s.field.items:
		var p89_pp: Projectile = p89_it["p"]
		if p89_pp.kind == Projectile.KIND_FRAGMENT and p89_pp.alive:
			p89_dirs.append(atan2(p89_pp.to.y - p89_pp.from.y, p89_pp.to.x - p89_pp.from.x))
	p89_dirs.sort()
	var p89_gaps: Array[float] = []
	for p89_i3 in p89_dirs.size():
		var p89_nxt: float = p89_dirs[(p89_i3 + 1) % p89_dirs.size()]
		var p89_g: float = p89_nxt - p89_dirs[p89_i3]
		if p89_i3 == p89_dirs.size() - 1:
			p89_g = (p89_dirs[0] + TAU) - p89_dirs[p89_i3]
		p89_gaps.append(p89_g)
	var p89_uniform := true
	var p89_want: float = TAU / float(maxi(1, p89_dirs.size()))
	for p89_g2 in p89_gaps:
		if absf(p89_g2 - p89_want) > 0.02:
			p89_uniform = false
	var p89_gap_txt: Array[String] = []
	for p89_g3 in p89_gaps:
		p89_gap_txt.append("%.0f°" % rad_to_deg(p89_g3))
	print("    破片 %d 枚 ｜ 相邻夹角 %s ｜ 均匀=%s" % [p89_dirs.size(), p89_gap_txt, p89_uniform])
	_chk(p89_dirs.size() == int(Skills.get_def("grenade_launcher")["fragments"]) and not p89_uniform,
		"8 枚破片方向随机（不再是每 45° 一发）")
	_s.clear_projectiles()

	# ── 52. 爬升轰炸不自伤（真实时间，第 89 轮）──
	print("\n[52] 爬升轰炸不自伤（真实时间跑完整套）")
	_s.clear_projectiles()
	_s.gm.clear_all_sentries()
	var p89_dv: Unit = _unit_by(AttackProfile.HELI_PREFIX + "（不要问那么多）", 0)
	var p89_tgt: Unit = _unit_by("Gerald", 1)
	for p89_u4 in _s.units:
		p89_u4.cell = Vector2i(2, 44)
		if p89_u4.visual != null:
			p89_u4.visual.position = Vector3(2.5, p89_u4.hover, 44.5)
	p89_dv.cell = Vector2i(10, 6)
	p89_dv.visual.position = Vector3(10.5, p89_dv.hover, 6.5)
	p89_dv.power_cur = p89_dv.power_max
	p89_dv.armor_cur = p89_dv.armor_max
	p89_dv.tags.erase("crashing")
	p89_dv.tags.erase("diving")
	p89_dv.body_y = -1.0
	p89_dv.visual.visible = true
	p89_dv.energy = p89_dv.energy_max
	p89_tgt.cell = Vector2i(10, 10)           # 4 格外的目标格（旧实现里这一发一定会自伤）
	p89_tgt.visual.position = Vector3(10.5, 0.0, 10.5)
	p89_tgt.power_cur = p89_tgt.power_max
	p89_tgt.armor_cur = 0
	p89_tgt.pr = 0
	var p89_dv_hp: int = p89_dv.power_cur
	var p89_tgt_hp: int = p89_tgt.power_cur
	_s.active = p89_dv                      # 别设 null：可能还有 AI 协程在跑，它要用 active
	_s.t_set_turn_just_finished(p89_dv) # 让收尾的 _finish_turn 变成空操作（别把 AI 回合带起来）
	_s.t_cast_dive(p89_dv, Vector2i(10, 10))
	_s.t_dive_begin(p89_dv)
	await create_timer(7.0).timeout          # 爬升 1.6s + 停 0.5s + 弹落 1s + 返航 1.6s
	print("    技能结束：diving=%s ｜ 直升机 %d -> %d ｜ 目标格 %d -> %d" % [
		p89_dv.tags.has("diving"), p89_dv_hp / 1000, p89_dv.power_cur / 1000,
		p89_tgt_hp / 1000, p89_tgt.power_cur / 1000])
	_chk(not p89_dv.tags.has("diving"), "爬升轰炸走完（投弹 -> 在 4 格上等弹落地 -> 返航）")
	_chk(p89_dv.power_cur == p89_dv_hp,
		"投弹阶段不再自伤（身体高度按真实高度算，且等弹落地才返航）")
	_chk(p89_tgt.power_cur < p89_tgt_hp, "目标格照常吃炸弹")
	_chk(absf(p89_dv.body_y + 1.0) < 0.001, "返航结束后临时高度清掉（回到悬停）")

	# ── 53. 被一发打空的直升机照样坠机（死亡附加伤害，第 89 轮）──
	print("\n[53] 被一发打空的直升机照样坠机")
	_s.clear_projectiles()
	var p89_kill: Unit = _unit_by("Airburst mortar", 0)
	var p89_cr: Unit = _unit_by(AttackProfile.HELI_PREFIX + "（不要问那么多）", 1)
	var p89_nb: Unit = _unit_by("Gerald", 0)
	for p89_u5 in _s.units:
		p89_u5.cell = Vector2i(2, 44)
		if p89_u5.visual != null:
			p89_u5.visual.position = Vector3(2.5, p89_u5.hover, 44.5)
	p89_kill.cell = Vector2i(15, 20)
	p89_kill.visual.position = Vector3(15.5, 0.0, 20.5)
	p89_kill.power_cur = Rules.points_to_milli(60)      # 一发就能打空直升机（邻居还剩 20 血左右）
	p89_cr.cell = Vector2i(20, 20)
	p89_cr.visual.position = Vector3(20.5, p89_cr.hover, 20.5)
	p89_cr.power_cur = p89_cr.power_max
	p89_cr.armor_cur = 0
	p89_cr.pr = 0
	p89_cr.tags.erase("crashing")
	p89_cr.body_y = -1.0
	p89_cr.visual.visible = true
	p89_nb.cell = Vector2i(21, 20)                      # 站在它旁边 1 格吃坠机炮击
	p89_nb.visual.position = Vector3(21.5, 0.0, 20.5)
	p89_nb.power_cur = p89_nb.power_max
	p89_nb.armor_cur = 0
	p89_nb.pr = 0
	var p89_nb_hp: int = p89_nb.power_cur
	_s.t_debug_log().clear()
	var p89_shell: Projectile = _s.t_spawn_shell(p89_kill, Vector2(20.5, 20.5), false)
	for p89_i4 in 900:
		_s.field.step(1.0 / 60.0)
		if not p89_shell.alive:
			break
	var p89_crashed := false
	for p89_lg2 in _s.t_debug_log():
		if String(p89_lg2).contains("坠机"):
			p89_crashed = true
	await create_timer(1.0).timeout                     # 等坠机动画（0.45 秒）与结算
	print("    直升机 alive=%s ｜ 坠机日志=%s ｜ 邻居力量 %d -> %d" % [
		p89_cr.is_alive(), p89_crashed, p89_nb_hp, p89_nb.power_cur])
	_chk(not p89_cr.is_alive(), "一发打空 -> 直接阵亡")
	_chk(p89_crashed, "被一发打空也要走坠机（死亡附加伤害不再偶尔丢失）")
	_chk(p89_nb.power_cur < p89_nb_hp, "坠机炮击照常结算到旁边的角色身上")
	_s.clear_projectiles()

	# ── 54. 巡飞弹发射器 + 巡飞弹（第 90 轮）──
	print("\n[54] 巡飞弹发射器与巡飞弹")
	_s.clear_projectiles()
	_s.gm.clear_all_sentries()
	_s.phase = _s.Phase.IDLE
	_s.active = null
	_s.t_set_place_kind("巡飞弹发射器")
	_chk(int(_s.place_left.get("巡飞弹发射器", 0)) == 1,
		"沙盒里有巡飞弹发射器，且每个场景上限 1 台（数量来自表格）")
	_s.place_left["巡飞弹发射器"] = 1
	_s.t_place_at(Vector2i(10, 10))
	var p90_lp: Placeable = null
	for p90_pl in _s.placeables:
		if Loiter.is_launcher(p90_pl):
			p90_lp = p90_pl
	print("    发射器：%s 于 %s ｜ 力量 %d ｜ 射程 %.0f ｜ 冷却 %d 回合" % [
		p90_lp.name if p90_lp != null else "-", p90_lp.cell if p90_lp != null else "-",
		p90_lp.power_cur / 1000 if p90_lp != null else 0,
		Loiter.LAUNCH_RANGE, Loiter.LAUNCH_COOLDOWN_TURNS])
	_chk(p90_lp != null and p90_lp.power_cur == Rules.points_to_milli(20), "发射器血量 20")
	# 场上只留一个"会动的"目标：先全体挪到角落，再让它挪一下位置
	var p90_tgt: Unit = _unit_by("Gerald", 1)
	for p90_u in _s.units:
		p90_u.cell = Vector2i(2, 44)
		if p90_u.visual != null:
			p90_u.visual.position = Vector3(2.5, p90_u.hover, 44.5)
	p90_tgt.power_cur = p90_tgt.power_max
	p90_tgt.armor_cur = p90_tgt.power_max
	p90_tgt.cell = Vector2i(10, 16)                 # 距发射器 6 格（射程内）
	p90_tgt.visual.position = Vector3(10.5, 0.0, 16.5)
	_s.t_tick_loiter_launchers(0.2)                  # 第一次采样：只是记下位置
	var p90_n0: int = _count_kind(Projectile.KIND_LOITER)
	_s.t_tick_loiter_launchers(0.2)                  # 位置没变 -> 不算"在动"
	_chk(_count_kind(Projectile.KIND_LOITER) == p90_n0,
		"站着不动的角色不会触发发射器（只打运动中的）")
	# 区分敌我（第 91 轮）：友军从旁边走过也不打
	var p91_friend: Unit = _unit_by("Gerald", 0)
	p91_friend.cell = Vector2i(10, 16)
	p91_friend.visual.position = Vector3(10.5, 0.0, 16.5)
	_s.t_tick_loiter_launchers(0.2)
	p91_friend.cell = Vector2i(10, 15)
	p91_friend.visual.position = Vector3(10.5, 0.0, 15.5)
	_s.t_tick_loiter_launchers(0.2)
	print("    友军（我方 Gerald）在射程内走动：巡飞弹 %d 发" % p90_n0)
	_chk(_count_kind(Projectile.KIND_LOITER) == p90_n0, "友军在射程内移动不会触发发射器（区分敌我）")
	# 动一下（浮点位置变了）-> 下一帧采样就该发射
	p90_tgt.cell = Vector2i(10, 15)
	p90_tgt.visual.position = Vector3(10.5, 0.0, 15.5)
	_s.t_debug_log().clear()
	_s.t_tick_loiter_launchers(0.2)
	var p90_mun: Projectile = null
	for p90_it in _s.field.items:
		var p90_pp: Projectile = p90_it["p"]
		if p90_pp.kind == Projectile.KIND_LOITER:
			p90_mun = p90_pp
	print("    移动后：巡飞弹 %s ｜ GM 回合 %d ｜ 冷却到 %s" % [
		"有" if p90_mun != null else "无", _s.gm.turn_count, p90_lp.tags.get("loiter_next", "-")])
	_chk(p90_mun != null, "角色在射程内移动 -> 发射器发射巡飞弹")
	if p90_mun != null:
		var p90_want: float = Vector2(p90_tgt.visual.position.x - p90_lp.visual.position.x,
			p90_tgt.visual.position.z - p90_lp.visual.position.z).angle()
		var p90_off: float = absf(rad_to_deg(wrapf(p90_mun.heading - p90_want, -PI, PI)))
		print("    初始方向偏中心线 %.1f°（上限 %.0f°）｜ 高度 %.2f ｜ 碰撞半径 %.2f" % [
			p90_off, Loiter.CONE_DEG, p90_mun.height(), p90_mun.hit_r])
		_chk(p90_off <= Loiter.CONE_DEG + 0.01, "初始方向在目标方向 ±45° 内")
		_chk(absf(p90_mun.height() - Loiter.HEIGHT) < 0.001 and absf(p90_mun.hit_r - 0.5) < 0.001,
			"巡飞弹定高 1.5 格、碰撞半径 0.5（直径一格）")
		_chk(int(p90_lp.tags.get("loiter_next", -1)) == _s.gm.turn_count + Loiter.LAUNCH_COOLDOWN_TURNS,
			"发射后登记冷却：%d 个回合边界" % Loiter.LAUNCH_COOLDOWN_TURNS)
	# 冷却期间再动也不给第二发
	p90_tgt.cell = Vector2i(10, 14)
	p90_tgt.visual.position = Vector3(10.5, 0.0, 14.5)
	_s.t_tick_loiter_launchers(0.2)
	_chk(_count_kind(Projectile.KIND_LOITER) == 1, "冷却没到 -> 不许再发射（每 5 个回合一枚）")
	# ── Q/E 制导：越按越快 + 有上下限 + 松手带惯性 ──
	if p90_mun != null:
		var p90_h0: float = p90_mun.heading
		_s.t_loiter_steer_apply(p90_mun, 1.0, 1.0 / 60.0)          # 刚按下
		var p90_d1: float = absf(wrapf(p90_mun.heading - p90_h0, -PI, PI))
		for p90_i in 30:
			_s.t_loiter_steer_apply(p90_mun, 1.0, 1.0 / 60.0)      # 按住半秒
		var p90_h1: float = p90_mun.heading
		_s.t_loiter_steer_apply(p90_mun, 1.0, 1.0 / 60.0)
		var p90_d2: float = absf(wrapf(p90_mun.heading - p90_h1, -PI, PI))
		var p90_w: float = p90_mun.turn_w
		var p90_h2: float = p90_mun.heading
		_s.t_loiter_steer_apply(p90_mun, 0.0, 1.0 / 60.0)          # 松手
		var p90_w_off: float = p90_mun.turn_w
		var p90_d_off: float = absf(wrapf(p90_mun.heading - p90_h2, -PI, PI))
		print("    Q/E 制导：第一帧转 %.3f° ｜ 按住半秒后每帧 %.3f° ｜ 角速度 %.1f°/秒 ｜ 松手后 %.1f°/秒（还在转 %.3f°）" % [
			rad_to_deg(p90_d1), rad_to_deg(p90_d2), p90_w, p90_w_off, rad_to_deg(p90_d_off)])
		_chk(p90_d2 > p90_d1 * 1.5, "按得越久转得越快（第一帧 %.3f° -> 半秒后 %.3f°）" % [
			rad_to_deg(p90_d1), rad_to_deg(p90_d2)])
		_chk(p90_w <= Loiter.TURN_MAX + 0.001, "角速度有上限（%.1f <= %.0f）" % [p90_w, Loiter.TURN_MAX])
		_chk(p90_w_off > 0.0 and p90_d_off > 0.0, "松手带惯性：角速度还在，继续转一点再停")
		_chk(absf(p90_w_off) < absf(p90_w), "松手后角速度在衰减（%.1f -> %.1f）" % [p90_w, p90_w_off])
		# ── 第 91/92 轮：场上有多发时只有"最先那发"受控，多余的永远不受控 ──
		_s.t_fire_loiter(p90_lp, Vector2(10.5, 10.5), p90_tgt)     # 真实发射路径 -> 被标记为多余
		var p91_b: Projectile = null
		for p91_it in _s.field.items:
			var p91_pp: Projectile = p91_it["p"]
			if p91_pp.kind == Projectile.KIND_LOITER and p91_pp.alive and p91_pp != p90_mun:
				p91_b = p91_pp
		print("    场上两发：受控的是%s ｜ 第二发 no_control=%s" % [
			"最先那发" if _s.t_loiter_pick_control() == p90_mun else "？",
			p91_b.no_control if p91_b != null else "-"])
		_chk(p91_b != null and p91_b.no_control, "后来发射的那一发被标记成多余（不受控）")
		_chk(_s.t_loiter_pick_control() == p90_mun, "只有最先发射的那一发受 Q/E 控制")
		p90_mun.kill("test_kill")               # 第一发爆炸
		_chk(_s.t_loiter_pick_control() == null and p91_b.alive,
			"第一发爆炸后不再接管：多余的那发还在飞，但永远不受控")
		# ── 近炸引信：把敌方角色挪到感应范围里（第 92 轮：只认敌方、直径 1.5 格）──
		var p90_vic: Unit = _unit_by("Alette", 1)
		p90_vic.power_cur = p90_vic.power_max
		p90_vic.armor_cur = 0
		p90_vic.cell = Vector2i(2, 44)                         # 敌方先待在场外
		p90_vic.visual.position = Vector3(2.5, 0.0, 44.5)
		# 先塞一个"友军"进感应范围：不许炸
		var p92_friend: Unit = _unit_by("Gerald", 0)
		p92_friend.power_cur = p92_friend.power_max
		p92_friend.cell = Vector2i(int(floor(p91_b.pos().x)), int(floor(p91_b.pos().y)))
		p92_friend.visual.position = Vector3(p91_b.pos().x, 0.0, p91_b.pos().y)
		_s.t_tick_loiter_fuse()
		_chk(p91_b.alive, "感应范围里只有友军 -> 不引爆（第 92 轮：只认敌方）")
		p92_friend.cell = Vector2i(2, 44)                      # 友军走开
		p92_friend.visual.position = Vector3(2.5, 0.0, 44.5)
		p90_vic.cell = Vector2i(int(floor(p91_b.pos().x)), int(floor(p91_b.pos().y)))
		p90_vic.visual.position = Vector3(p91_b.pos().x, 0.0, p91_b.pos().y)
		var p90_vhp: int = p90_vic.power_cur
		_s.t_debug_log().clear()
		_s.t_tick_loiter_fuse()
		var p90_fuse := false
		for p90_lg in _s.t_debug_log():
			if String(p90_lg).contains("近炸引信"):
				p90_fuse = true
		print("    近炸引信：触发=%s ｜ 目标力量 %d -> %d ｜ 巡飞弹还在=%s" % [
			p90_fuse, p90_vhp / 1000, p90_vic.power_cur / 1000, p91_b.alive])
		_chk(p90_fuse and not p91_b.alive, "敌方角色在感应范围内 -> 近炸引信引爆")
		_chk(p90_vic.power_cur < p90_vhp, "巡飞弹造伤落到范围里的角色身上（40 破甲 + 40 力量）")
	# ── 飞满 32 格自动引爆 ──
	_s.clear_projectiles()
	var p90_far := Ordnance.make_loiter(-1, "巡飞弹发射器", Vector2(2.5, 40.5), 0.0, _s.rng)
	p90_far.flown = Loiter.MAX_DIST - 0.01
	_s.field.register(p90_far)
	_s.t_debug_log().clear()
	for p90_i2 in 5:
		_s.field.step(1.0 / 60.0)
	var p90_boom := false
	for p90_lg2 in _s.t_debug_log():
		if String(p90_lg2).contains("巡飞弹引爆"):
			p90_boom = true
	print("    飞满 %d 格：引爆=%s ｜ 还在场上=%s" % [
		int(Loiter.MAX_DIST), p90_boom, p90_far.alive])
	_chk(p90_boom and not p90_far.alive, "飞满 32 格自动引爆（不会一直飞）")
	_s.clear_projectiles()

	# ── 55. 火箭飞出物理边界必须就地引爆（第 93 轮：敌方火箭凭空消失的根因）──
	print("\n[55] 火箭飞出边界 = 就地引爆")
	_s.clear_projectiles()
	_s.gm.clear_all_sentries()
	var p93_he: Unit = _unit_by(AttackProfile.HELI_PREFIX + "（不要问那么多）", 1)
	for p93_u in _s.units:
		p93_u.cell = Vector2i(2, 44)
		if p93_u.visual != null:
			p93_u.visual.position = Vector3(2.5, p93_u.hover, 44.5)
	p93_he.cell = Vector2i(12, 40)                 # 敌方直升机在"上边"
	p93_he.visual.position = Vector3(12.5, p93_he.hover, 40.5)
	p93_he.power_cur = p93_he.power_max
	p93_he.tags.erase("crashing")
	p93_he.visual.visible = true
	_s.t_debug_log().clear()
	# 真实战里就是"瞄准×2 + 散布"把落点算到了 y<0（只有从上往下打的敌方会遇到）
	var p93_rk := Ordnance.make_rocket(p93_he, Vector3(12.5, p93_he.hover + 0.25, 40.5),
		Vector2(10.5, -6.0), false, _s.rng)
	_s.field.register(p93_rk)
	for p93_i in 900:
		_s.field.step(1.0 / 60.0)
		if not p93_rk.alive:
			break
	var p93_boom := false
	var p93_out := false
	for p93_lg in _s.t_debug_log():
		if String(p93_lg).contains("火箭落地"):
			p93_boom = true
		if String(p93_lg).contains("飞到边界"):
			p93_out = true
	print("    火箭 alive=%s 原因='%s' ｜ 落地引爆=%s ｜ 出界移除=%s" % [
		p93_rk.alive, p93_rk.removed_reason, p93_boom, p93_out])
	_chk(p93_boom and not p93_out,
		"炮弹类飞出物理边界要就地引爆（第 93 轮：以前唯一的收尾是「直接移除、无爆炸」）")
	# 齐射落点必须钳在可行动区域内 —— 这样根本不会飞到界外
	_s.clear_projectiles()
	_s.active = p93_he
	_s.t_set_turn_just_finished(p93_he)
	_s.t_rocket_salvo(p93_he, Vector2(10.5, 2.5))
	var p93_pts: Array = _s.t_salvo_dbg().get("rolled", [])
	var p93_outside := 0
	for p93_pt in p93_pts:
		var p93_v: Vector2 = p93_pt
		if p93_v.x < float(_s.PX) + 0.5 - 0.001 or p93_v.x > float(_s.PX + _s.PW) - 0.5 + 0.001 \
				or p93_v.y < float(_s.PY) + 0.5 - 0.001 or p93_v.y > float(_s.PY + _s.PH) - 0.5 + 0.001:
			p93_outside += 1
	print("    齐射落点 %d 个（第 93 轮：8 波 × 左右各一发），钳进区域外 %d 个" % [
		p93_pts.size(), p93_outside])
	_chk(p93_pts.size() == int(Level.heli()["rockets"]) and p93_outside == 0,
		"直升机齐射落点全部钳在可行动区域内（%d 发）" % int(Level.heli()["rockets"]))
	_s.clear_projectiles()

	# ── 56. 枪榴弹在空中被箭击落：整发直接消失（第 96 轮；以前会就地落地 + 照炸）──
	print("\n[56] 枪榴弹飞行中被击落")
	_s.clear_projectiles()
	_s.gm.clear_all_sentries()
	var p94_sani: Unit = _unit_by("萨尼铁塔", 0)
	var p94_archer: Unit = _unit_by("Alette", 0)
	for p94_u in _s.units:
		p94_u.cell = Vector2i(2, 44)
		if p94_u.visual != null:
			p94_u.visual.position = Vector3(2.5, p94_u.hover, 44.5)
	p94_sani.cell = Vector2i(10, 20)
	p94_sani.visual.position = Vector3(10.5, 0.0, 20.5)
	p94_archer.cell = Vector2i(10, 26)          # 站在弹道正上方：箭沿 y 往下飞
	p94_archer.visual.position = Vector3(10.5, 0.0, 26.5)
	var p94_gp: Projectile = _s.t_spawn_grenade_shot(p94_sani, Vector2(10.5, 40.5), "grenade_launcher")
	# 先飞一会儿，让手榴弹离开萨尼铁塔身前（不然箭一生成就撞上别人）
	for p94_i in 30:
		_s.field.step(1.0 / 60.0)
	var p94_alive0: bool = p94_gp.alive
	var p94_can: bool = p94_alive0 and Ballistics.can_shoot_down(Projectile.KIND_ARROW, p94_gp)
	var p94_models0: int = _s.t_grenade_models().size()
	var p94_pend0: int = _s.gm.pending.size()
	_s.t_debug_log().clear()
	var p94_ar: Projectile = _s.t_spawn_arrow(p94_archer, Vector3(10.5, 0.75, 26.5),
		Vector3(10.5, 0.4, 20.0), null, false, false)
	for p94_i2 in 400:
		_s.field.step(1.0 / 60.0)
		if not p94_gp.alive:
			break
	var p94_shot := false
	var p94_gone := false
	for p94_lg in _s.t_debug_log():
		if String(p94_lg).contains("击落"):
			p94_shot = true
		if String(p94_lg).contains("直接消失"):
			p94_gone = true
	# 再多跑 6 秒：确认它不会"过一会儿又在地上炸一下"（GM 里不许有这一发）
	for p94_i3 in 360:
		_s.field.step(1.0 / 60.0)
	print("    枪榴弹：飞行中 alive=%s ｜ 被击落=%s ｜ 消亡原因='%s' ｜ 模型 %d -> %d ｜ GM %d -> %d ｜ 直接消失=%s" % [
		p94_alive0, p94_shot, p94_gp.removed_reason, p94_models0, _s.t_grenade_models().size(),
		p94_pend0, _s.gm.pending.size(), p94_gone])
	_chk(p94_can, "枪榴弹声明自己怕箭（炮弹类统一模板，飞行中可以被击落）")
	_chk(not p94_gp.alive and p94_gp.removed_reason == "shot_down",
		"飞行中的枪榴弹真的被箭打掉了（飞行模型消失）")
	_chk(p94_shot, "日志里写明「被箭矢击落」")
	_chk(p94_gone, "日志写明整发直接消失（不落地、不爆炸）")
	_chk(_s.t_grenade_models().size() == p94_models0 and _s.gm.pending.size() == p94_pend0,
		"被击落的枪榴弹不落地：不立弹体模型、不登记 GM 计时（第 96 轮：不会过一会儿又炸）")
	_s.clear_projectiles()

	# ── 57. 近战不能瞄准直升机（第 96 轮）──
	print("\n[57] 近战 vs 悬停的直升机")
	_s.clear_projectiles()
	var p96_heli: Unit = null
	for p96_u in _s.units:
		# 注意：花名册里双方各有一架直升机，这里要的是**敌方那架**（近战的敌人）
		if AttackProfile.is_heli(p96_u) and p96_u.side == UnitData.Side.ENEMY:
			p96_heli = p96_u
			break
	p96_heli.power_cur = p96_heli.power_max
	p96_heli.cell = Vector2i(11, 30)
	p96_heli.visual.position = Vector3(11.5, p96_heli.hover, 30.5)
	gerald.cell = Vector2i(10, 30)                   # 近战贴到它旁边那一格
	gerald.visual.position = Vector3(10.5, 0.0, 30.5)
	gerald.begin_turn()
	gerald.energy = gerald.energy_max
	_s.active = gerald
	_s.t_menu_attack()
	var p96_hl: bool = _s.attackable.has(p96_heli.cell)
	var p96_aim: bool = _s.t_can_aim_unit(p96_heli)
	var p96_pw0: int = p96_heli.power_cur
	var p96_ok: bool = _s.t_perform_basic(gerald, _s.t_cc(p96_heli.cell), p96_heli)
	print("    相邻：直升机高 %0.1f 格 ｜ 紫格高亮=%s ｜ 可瞄准=%s ｜ 出手=%s ｜ 直升机力量 %d -> %d ｜ 已行动=%s" % [
		p96_heli.body_h(), p96_hl, p96_aim, p96_ok, p96_pw0 / 1000, p96_heli.power_cur / 1000,
		gerald.has_acted])
	_chk(not p96_hl, "近战点普攻后：悬停的直升机那一格不亮（够不着）")
	_chk(not p96_aim, "近战不能瞄准直升机（_can_aim_unit 直接拒绝）")
	_chk(not p96_ok and p96_heli.power_cur == p96_pw0 and not gerald.has_acted,
		"就算硬调 _perform_basic 也打不出去：不掉血、不置已行动")
	# 远程不受这条限制：照样能瞄（它本来就按高度轴抬枪口）
	alette.cell = Vector2i(7, 30)
	alette.visual.position = Vector3(7.5, 0.0, 30.5)
	alette.begin_turn()
	alette.energy = alette.energy_max
	_s.active = alette
	_s.t_menu_attack()
	print("    弓箭手（4 格外）：紫格高亮=%s ｜ 可瞄准=%s" % [
		_s.attackable.has(p96_heli.cell), _s.t_can_aim_unit(p96_heli)])
	_chk(_s.attackable.has(p96_heli.cell) and _s.t_can_aim_unit(p96_heli),
		"远程不受这条限制：照样能瞄准直升机")
	_s.t_cancel_to_menu()

	print("\n── 共 %d 项检查，失败 %d 项 ──" % [_checks, _fails.size()])
	if _fails.is_empty():
		print("✅ v3 试玩链路全部通过")
		quit(0)
	else:
		for f in _fails:
			print("   ❌ ", f)
		quit(1)

