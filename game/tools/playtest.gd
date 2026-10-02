# 无头试玩：脚本驱动真实场景，验证回合队列、二级菜单、投掷瞄准、友伤、取消选择、队列条。
# 运行: godot --headless --path <项目> --script res://tools/playtest.gd
# 设计：所有检查走 _chk()，末尾统一打印并 quit()，**不会因断言失败而挂住**。
extends SceneTree

var _s: Node
var _fails: Array[String] = []
var _checks := 0

## 统计高亮格数量（排除常驻的待确认 √ sprite）
func _count_hint_boxes() -> int:
	var n := 0
	for c in _s._hint_layer.get_children():
		if c is MeshInstance3D:
			n += 1
	return n


func _chk(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_fails.append(label)


## 当前是否有一个活着的弹反 QTE 节点
func _find_qte() -> ArrowQTE:
	return _s._find_arrow_qte()


## 把老国王 / 公主挪到地图角落，免得它们的 AI 与常备哨兵干扰确定性检查
func _clear_ai_corner() -> void:
	for u in _s.units:
		if Unit.base_name(u.name) == "老国王" or Unit.base_name(u.name) == "公主":
			var far := Vector2i(2, 44) if u.side == UnitData.Side.PLAYER else Vector2i(45, 44)
			u.cell = far
			if u.visual != null:
				u.visual.position = Vector3(float(far.x) + 0.5, 0.0, float(far.y) + 0.5)


func _initialize() -> void:
	_s = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(_s)
	for i in 5:
		await process_frame
	# 新角色（老国王 / 公主）会自己开炮、开哨兵，会打扰后面的确定性检查。
	# 全部先挪到地图角落（各自阵营的那一侧），要测它们时再单独摆位。
	# 通用 AI 也先关掉（试玩要复现"敌方站着不动"的老行为），第 30 节单独测 AI。
	_s.gm.ai_enabled = false
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
		_s._pick_place_kind("木刺")
		_chk(_s._place_kind == "木刺", "应选中木刺")
		var pc := Vector2i(6, 12)
		_chk(_s._can_place_at(pc), "空地上可以放置")
		_s._place_at(pc)
		print("    放置木刺后：道具数 = %d，剩余 = %d" % [
			_s.placeables.size(), _s.place_left.get("木刺", 0)])
		_chk(_s.placeables.size() == 1, "应放下 1 个道具")
		_chk(int(_s.place_left.get("木刺")) == spike_n - 1, "剩余数量应减 1")
		_chk(not _s._can_place_at(pc), "同一格不能再放")
		_chk(not _s._can_place_at(_s.units[0].cell), "有单位的格子不能放")
	if mound_n > 0:
		_s._pick_place_kind("土堆")
		_s._place_at(Vector2i(7, 12))
		_chk(_s.placeables.size() == 2, "再放一个土堆")
	_s._finish_placement()
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
			_s._finish_turn()          # 我方 + 敌方阵营里的可控角色都由玩家结束回合
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
	_s._select_for_detail(gerald)
	_s._show_action_menu()
	print("\n[3] 菜单可见 =", _s._action_menu.visible, " 阶段 =", _s.phase, " 可达格 =", _s.reachable.size())
	_chk(_s._action_menu.visible, "点自己人应弹出菜单")
	_chk(_s.reachable.size() > 0, "菜单打开时应有移动范围")

	# ── 4. 攻击二级菜单 ──
	gerald.cell = dummy.cell + Vector2i(-1, 0)
	_s._menu_attack()
	_chk(_s.phase == _s.Phase.CHOOSE_TARGET, "普攻应进入选目标阶段")
	_chk(_s.attackable.has(dummy.cell), "相邻敌人应可攻击")
	_s._show_attack_menu(dummy)
	print("\n[4] 攻击菜单可见 =", _s._attack_menu.visible)
	print("    蓝(破甲) = %s   红(力量) = %s" % [
		_s._btn_break.text.replace("\n", "/"), _s._btn_power.text.replace("\n", "/")])
	_chk(_s._attack_menu.visible, "点敌人应弹出攻击方式菜单")
	_chk(_s._btn_break.text.contains("破甲"), "左按钮是破甲")
	_chk(_s._btn_power.text.contains("打力量"), "右按钮是打力量")
	_chk(_s._btn_break.text.contains("16"), "破甲按钮应显示 16")
	# 假人现在是 100 甲，Gerald 41 力打不动 -> 按钮应显示"打不动"且置灰
	print("    假人现在 100 甲，Gerald 41 力：力量按钮 =", _s._btn_power.text.replace("\n", "/"),
		" disabled=", _s._btn_power.disabled)
	_chk(_s._btn_power.text.contains("打不动"), "力量打不动时应显示「打不动」")
	var arm_before: int = dummy.armor_cur
	_s._confirm_attack(true)          # 用破甲，必然能削它护甲
	await process_frame
	print("    确认破甲后：%s 护甲 %s -> %s" % [dummy.name, arm_before / 1000.0, dummy.armor_cur / 1000.0])
	_chk(dummy.armor_cur < arm_before, "破甲应削减护甲池")

	# 概率命中的文案：dummy 物抗为 0，所以临时给它一个高档位来构造 0<D<1
	var tough = e_list[1]
	tough.pr = 800
	_s.active = gerald
	gerald.power_cur = tough.armor_cur + Rules.points_to_milli(1)
	_s._show_attack_menu(tough)
	print("    概率区间的红按钮 =", _s._btn_power.text.replace("\n", "/"))
	_chk(_s._btn_power.text.contains("概率"), "概率区间应写「1（xx%概率）」")
	tough.pr = 0

	# ── 5. 投掷瞄准数学 ──
	_s.active = mortar
	_s._begin_aim()
	print("\n[5] 射程 %s~%s 格；箭头 %s~%s 倍身高" % [
		UnitData.THROW_RANGE_MIN, UnitData.THROW_RANGE_MAX,
		UnitData.ARROW_LEN_MIN, UnitData.ARROW_LEN_MAX])
	var prev_r := -1.0
	var prev_l := -1.0
	for px in [0, 30, 100, 200, 300, 400, 700]:
		var t1: float = _s._charge_from_drag(float(px))
		var r1: float = _s._aim_range(t1)
		var al1: float = _s._arrow_len_for_t(t1) / UnitData.UNIT_HEIGHT
		print("      拖 %4d px -> 力度 %3d%% -> 射程 %5.2f 格 -> 箭头 %.2f 倍身高" % [
			px, int(t1 * 100), r1, al1])
		_chk(r1 >= UnitData.THROW_RANGE_MIN - 0.001, "射程 >= 最短")
		_chk(r1 <= UnitData.THROW_RANGE_MAX + 0.001, "射程 <= 最长")
		_chk(al1 >= UnitData.ARROW_LEN_MIN - 0.001, "箭头 >= 1 倍身高")
		_chk(al1 <= UnitData.ARROW_LEN_MAX + 0.001, "箭头 <= 3 倍身高")
	for px in range(0, 500, 10):
		var t2: float = _s._charge_from_drag(float(px))
		var r2: float = _s._aim_range(t2)
		var al2: float = _s._arrow_len_for_t(t2)
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
	_s._resolve_mortar_impact(mortar, Vector2i(9, 6))
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
	_s._on_unit_died(d2)
	await create_timer(UnitData.DUMMY_REVIVE_SEC + 0.3).timeout
	print("      复活后 力=%s 甲=%s alive=%s" % [
		d2.power_cur / 1000.0, d2.armor_cur / 1000.0, d2.is_alive()])
	_chk(d2.is_alive(), "假人应已复活")
	_chk(d2.power_cur == d2.power_max, "复活后力量满")
	_chk(d2.armor_cur == d2.armor_max, "复活后护甲满")

	# ── 7. 取消选择 ──
	_s.selected = gerald
	_s._clear_selection()
	print("\n[7] 取消选择：selected=%s 详情=%s 行动菜单=%s 攻击菜单=%s" % [
		_s.selected, _s._panel.visible, _s._action_menu.visible, _s._attack_menu.visible])
	_chk(_s.selected == null, "点空白应取消选择")
	_chk(not _s._panel.visible, "未选人时详情栏隐藏")
	_chk(not _s._action_menu.visible and not _s._attack_menu.visible, "未选人时二级菜单隐藏")

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
	_s._next_turn()
	await create_timer(UnitData.DUMMY_SKIP_DELAY + 0.2).timeout
	var head: Unit = _s.active
	_s._finish_turn()
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
	_s._show_action_menu()
	print("    未移动时：休息按钮 disabled =", _s._btn_rest_menu.disabled)
	_chk(not _s._btn_rest_menu.disabled, "未移动时可以休息")
	_chk(_s.reachable.size() > 0, "未移动时可以移动")

	# 移动一格
	var dest: Vector2i = _s.reachable.keys()[0]
	_s._do_move(gerald, dest)
	print("    移动后：has_moved =", gerald.has_moved,
		" 休息按钮 disabled =", _s._btn_rest_menu.disabled,
		" 可达格 =", _s.reachable.size())
	_chk(gerald.has_moved, "移动标记置位")
	_chk(_s._btn_rest_menu.disabled, "移动后不能休息")
	_chk(_s.reachable.size() == 0, "移动后不能再移动")

	# 移动后点休息 -> 应被拒绝
	gerald.power_cur = Rules.points_to_milli(10)
	var before_rest: int = gerald.power_cur
	_s._menu_rest()
	print("    移动后强行点休息：力量 %s -> %s（应不变）" % [before_rest / 1000.0, gerald.power_cur / 1000.0])
	_chk(gerald.power_cur == before_rest, "移动后休息应被拒绝")

	# 三选一（普攻）后回合立即结束：active 应换人
	var who_before: Unit = gerald
	_s._show_action_menu()
	_s.active = gerald
	_s.phase = _s.Phase.CHOOSE_TARGET
	var victim = e_list[0]
	victim.cell = gerald.cell + Vector2i(1, 0)
	victim.power_cur = victim.power_max
	victim.armor_cur = Rules.points_to_milli(10)     # 压低护甲让 Gerald 打得动
	_s._attack_target_unit(victim, false)
	await create_timer(0.35).timeout
	print("    普攻后：active %s -> %s（回合应自动结束）" % [
		who_before.name, _s.active.name if _s.active else "-"])
	_chk(_s.active != who_before, "三选一后回合应自动结束、轮到下一个人")

	# 「结束回合」已从二级菜单挪到右下角的 >> 按钮（用户要求）
	print("    二级菜单：休息=%s ｜ 右下角按钮=%s" % [_s._btn_rest_menu.text, _s._btn_next.text])
	_chk(_s._btn_next.text == ">>", "右下角按钮应是 >>")
	_chk(_s._btn_end_turn == null, "二级菜单里的「结束回合」按钮应已移除")

	# ── 11. 高亮与菜单显隐（用户第三轮要求）──
	print("\n[11] 高亮与菜单显隐")
	# ① 没选任何人 -> 不应有可移动格
	_s._clear_selection()
	_s._draw_hints()
	var hint_count_empty: int = _count_hint_boxes()
	print("    未选人时高亮格数 =", hint_count_empty)
	_chk(hint_count_empty == 0, "未选人时不应高亮任何格子")

	# ② 选定当前单位 -> 出现可移动格（蜘蛛绿）
	_s.active = gerald
	gerald.begin_turn()
	gerald.cell = Vector2i(5, 5)
	_s.selected = gerald
	_s._show_action_menu()
	var hint_move: int = _count_hint_boxes()
	print("    选中且未移动时高亮格数 =", hint_move, "（可达格 %d）" % _s.reachable.size())
	_chk(hint_move > 0, "选中后应高亮可移动格")

	# ③ 点普攻 -> 二级菜单必须消失，且高亮变成"可攻击范围"
	_s._menu_attack()
	print("    点普攻后：二级菜单可见 =", _s._action_menu.visible,
		" 阶段 =", _s.phase, " 可攻击格数 =", _s.attackable.size())
	_chk(not _s._action_menu.visible, "点普攻后二级菜单必须消失")
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
	_s._show_action_menu()
	_s._menu_attack()
	print("    点普攻（投掷手）后：菜单可见 =", _s._action_menu.visible, " 瞄准中 =", _s._aim_active)
	_chk(not _s._action_menu.visible, "投掷手点普攻后菜单也应消失")
	_chk(_s._aim_active, "投掷手点普攻应进入瞄准")
	_s._aim_active = false
	_s._arrow_root.visible = false

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
	_s._turn_just_finished = null                     # 模拟"一个全新的回合"，避免幂等保护挡掉推进
	var tc0: int = _s.gm.turn_count
	_s._attack_target_unit(victim2, true)             # 破甲
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
	_s._attack_target_unit(victim2, true)
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
	var entered: bool = _s._check_last_stand()
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
	var triggered2: bool = _s._check_last_stand()
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
	_s.reachable = _s._compute_reachable(gerald)
	var goal := Vector2i(-1, -1)
	for c in _s.reachable.keys():
		if absi(c.x - gerald.cell.x) + absi(c.y - gerald.cell.y) == 4:
			goal = c
			break
	_chk(goal.x >= 0, "应能找到距离 4 的可达目标格")
	var path: Array = _s._path_to(gerald, goal)
	print("    路径格子数 =", path.size(), "（起点 + 4 步 = 5）")
	print("    路径 =", path)
	_chk(path.size() == 5, "路径应是 5 个格子")
	if path.size() >= 5:
		_chk(path[0] == gerald.cell and path[4] == goal, "路径首尾应正确")
	var samples: Array[Vector2] = []
	var heights: Array[float] = []
	var stamps: Array[float] = []
	_s._do_move(gerald, goal)
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
	_s._resolve_mortar_impact(mortar, center)
	print("    斜邻格里的 %s（甲5、无抗）：力 %s->%s 甲 %s->%s" % [e_list[0].name,
		p0 / 1000.0, e_list[0].power_cur / 1000.0, a0 / 1000.0, e_list[0].armor_cur / 1000.0])
	_chk(e_list[0].armor_cur < a0, "斜邻格单位应被破甲")
	_chk(e_list[0].power_cur < p0, "斜邻格单位应吃力量伤害（甲5 时炮手 36 力打得动）")
	# 反面：高护甲时力量线打不动是正确行为（用户要求保留"打不动也能选力量"的权利）
	e_list[0].armor_cur = Rules.points_to_milli(100)
	e_list[0].power_cur = e_list[0].power_max
	var p1: int = e_list[0].power_cur
	_s._resolve_mortar_impact(mortar, center)
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
	_s._select_for_detail(e_list[0])
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
	_s._sync_unit_visibility()
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
		var blocked: Dictionary = _s._blocked_cells()
		print("    木刺@%s 土堆@%s 阻挡移动格数 = %d" % [spike.cell, mound.cell, blocked.size()])
		_chk(blocked.has(spike.cell) and blocked.has(mound.cell), "两种道具都应阻挡移动")
		_chk(not _s._ranged_blocked_at(spike.cell, false), "木刺不阻挡远程")
		_chk(_s._ranged_blocked_at(mound.cell, false), "土堆阻挡远程")
		_chk(not _s._ranged_blocked_at(mound.cell, true), "投掷手不受土堆阻挡")

		# 目标在道具【后面】：路径必须绕开道具，不能穿过它所在格
		var block_path: Array = _s._path_to(alette, spike.cell + Vector2i(0, 2))
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
		_s._attack_target_unit(victim3, false)
		await create_timer(4.5).timeout
		# 注意：假人会定时满血复活，直接比血量会被"复活"冲掉。
		# 所以这里以【游戏日志】为准：只要出现"Alette 攻击 → 目标"就说明箭穿过了木刺。
		var pierced := false
		for lg in _s._debug_log:
			if String(lg).contains("Alette 攻击 → %s" % victim3.name):
				pierced = true
		print("    箭矢飞向 (4,8)，木刺在 (4,6)：木刺 %s -> %s，日志命中=%s" % [
			spike_before / 1000.0, spike.power_cur / 1000.0, pierced])
		_chk(pierced, "木刺不挡箭：箭应穿过木刺命中后面的目标")
		_chk(spike.power_cur == spike_before, "木刺不挡箭：木刺本身不应被箭击中")

		# 友伤：友军站在弹道上
		alette.begin_turn()
		_s.active = alette
		spike.power_cur = spike.power_max
		spike.cell = Vector2i(30, 30)            # 挪走木刺
		gerald.cell = Vector2i(4, 6)             # 友军挡中间
		gerald.power_cur = gerald.power_max
		gerald.armor_cur = Rules.points_to_milli(5)   # 压低护甲，否则 26力 vs 26甲 = 打不动
		victim3.cell = Vector2i(4, 8)
		victim3.power_cur = victim3.power_max
		var gerald_before: int = gerald.power_cur
		_s._attack_target_unit(victim3, false)
		await create_timer(4.5).timeout
		print("    弹道上放友军 Gerald：力量 %s -> %s" % [
			gerald_before / 1000.0, gerald.power_cur / 1000.0])
		_chk(gerald.power_cur < gerald_before, "箭矢应打中友军（友伤）")
		gerald.armor_cur = gerald.armor_max
		_chk(victim3.power_cur == victim3.power_max, "友军挡下后目标不受伤害")

	# ── 18. 移动选项 + 二次确认 ──
	print("\n[18] 移动选项与二次确认")
	_s.active = gerald
	gerald.begin_turn()
	gerald.cell = Vector2i(5, 5)
	gerald.visual.position = Vector3(5.5, 0.0, 5.5)
	_s.selected = gerald
	_s._show_action_menu()
	_s._menu_move()
	print("    点「移动」后：二级菜单可见=%s，可移动格=%d" % [
		_s._action_menu.visible, _s.reachable.size()])
	_chk(not _s._action_menu.visible, "点移动后二级菜单应消失")
	_chk(_s.reachable.size() > 0, "点移动后应高亮可移动格")
	var goal2 := Vector2i(5, 7)
	_chk(_s.reachable.has(goal2), "目标格应可达")
	_s._set_pending("move", goal2)
	_s.phase = _s.Phase.MOVE_CONFIRM
	_s._draw_hints()
	print("    第一次点 (%d,%d)：待确认=%s，格子仍是 %s" % [
		goal2.x, goal2.y, _s._pending_kind, gerald.cell])
	_chk(gerald.cell == Vector2i(5, 5), "第一次点不应真的移动")
	_chk(_s._same_pending("move", goal2), "待确认目标应是该格")
	_s._do_move(gerald, goal2)
	await create_timer(0.6).timeout
	print("    确认后：已移动到 %s" % gerald.cell)
	_chk(gerald.cell == goal2, "确认后才真的移动")

	# ── 19. 队列绝不连续同阵营（用户重点）──
	print("\n[19] 队列交替自检")
	_chk(_s._queue_alternation_ok(), "当前队列不应出现连续同阵营")
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
	_chk(_s._queue_alternation_ok(), "人数不等时也必须严格交替")
	var sides2: Array[int] = []
	for u in _s.queue.order:
		if u.is_alive():
			sides2.append(u.side)
	print("    阵营序列 =", sides2)
	_chk(_s._queue_alternation_ok(), "阵营序列不能有相邻相同")

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
	_chk(_s._queue_alternation_ok(), "1 vs 1 也应隔一回合换边")

	# 敌方复活一个 -> 变成 1 vs 2 -> 应进入连击
	eh20[1].power_cur = eh20[1].power_max
	var switched: bool = _s._check_last_stand()
	_s.queue.rebuild(_s.units)
	print("    敌方复活 1 人后：检测到切换=%s 连击=%s" % [switched, _s.queue.last_stand])
	print("      队列 = %s" % _s.queue.dump())
	_chk(_s.queue.last_stand, "1 vs 2 应进入连击")
	_chk(_s._queue_alternation_ok(), "连击模式下也不能连续同阵营")

	# 关键：再复活一个敌方 -> 连击必须保持
	eh20[2].power_cur = eh20[2].power_max
	print("    敌方再复活 1 人（变成 1 vs 3）：")
	_s.queue.rebuild(_s.units)
	print("      连击保持 = %s" % _s.queue.last_stand)
	print("      队列 = %s" % _s.queue.dump())
	_chk(_s.queue.last_stand, "对面复活后连击状态必须保持")
	_chk(_s._queue_alternation_ok(), "连击保持时仍不能连续同阵营")
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
	_s._show_action_menu()
	_s._menu_move()
	var goal3 := Vector2i(5, 7)
	print("    点「移动」后：可移动格 = %d（应 > 0，说明高亮存在）" % _s.reachable.size())
	_chk(_s.reachable.size() > 0, "点移动后应有可移动格")
	_s._set_pending("move", goal3, gerald)
	_s.phase = _s.Phase.MOVE_CONFIRM
	_s._draw_hints()
	_chk(_s._pending_root != null, "应创建常驻的待确认标记节点")
	print("    待确认标记可见 = %s 位置 = %s" % [
		_s._pending_root.visible, _s._pending_root.position])
	_chk(_s._pending_root.visible, "待确认标记应可见")
	_chk(_s._pending_root.position.x > 5.0 and _s._pending_root.position.x < 6.0,
		"标记应落在待确认格 (5,7) 上")
	# 脉冲：颜色随时间变化
	var cols: Array[Color] = []
	for i in 6:
		_s._tick_pending_pulse(0.08)
		cols.append((_s._pending_mats[0] as StandardMaterial3D).albedo_color)
	var all_diff := true
	for i in range(1, cols.size()):
		if cols[i].is_equal_approx(cols[i - 1]):
			all_diff = false
	print("    标记颜色脉动：", cols[0], "->", cols[5])
	_chk(all_diff, "标记颜色应随时间脉动")
	# 取消后应隐藏
	_s._clear_pending()
	_s._draw_hints()
	_chk(not _s._pending_root.visible, "取消待确认后标记应隐藏")

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
	_s._start_carpet_bomb(mortar22, ctr22)
	# 物理弹道：7 发间隔 0.2 秒起飞，每发飞 1 秒 -> 最后一发在 2.2 秒后落地
	await create_timer(6.0).timeout
	var hurt := 0
	for i in mini(3, e_list.size()):
		if e_list[i].power_cur < e_list[i].power_max:
			hurt += 1
	for lg in _s._debug_log:
		if String(lg).contains("呼叫【地毯式轰炸】"):
			print("    [实际落点] %s" % lg)
	print("    放完：精力 %d -> %d（应 -%d）｜ 区内 %d/3 个目标挨打 ｜ 红圈节点 %d 个 ｜ gm_busy=%s" % [
		e_before, mortar22.energy, int(d22["cost"]), hurt, _s.count_impact_rings(), _s._gm_busy])
	_chk(mortar22.energy == e_before - int(d22["cost"]) * 1000, "地毯式轰炸应扣 3 点精力")
	_chk(hurt > 0, "轰炸区内的目标应吃到炮弹")
	_chk(_s.count_impact_rings() > 0, "炮弹落点必须有红圈")
	_chk(not _s._gm_busy, "演出结束后必须解锁操作")
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
	_s._action_menu.visible = true
	_s._attack_menu.visible = true
	if _s._skill_menu != null: _s._skill_menu.visible = true
	_s._set_pending("move", Vector2i(6, 6), g24)
	_s._on_blank_click()
	_chk(not _s._action_menu.visible, "点空白后行动菜单必须收起")
	_chk(not _s._attack_menu.visible, "点空白后攻击菜单必须收起")
	_chk(not _s._skill_menu.visible, "点空白后技能菜单必须收起")
	_chk(_s.selected == null, "点空白后不应保持选中")
	_chk(_s._pending_kind == "", "点空白后待确认标记必须清掉")

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
	_s._cast_sentry(al25)
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
	# 用户口径①：进入射界后先等 500ms 才射第一支
	_chk(_s.gm.sentry_tick(0.2).is_empty(), "进入射界 200ms 内还不该开火（要等 500ms）")
	_chk(_s.gm.sentry_tick(0.2).is_empty(), "400ms 仍不该开火")
	foe25.visual.position = Vector3(5.5, 0.0, 11.0)   # 目标在动（否则按"静止不追击"剔除）
	var f1: Array = _s.gm.sentry_tick(0.2)
	var f1_at := "(%.2f, %.2f)" % [f1[0].at.x, f1[0].at.y] if f1.size() > 0 else "-"
	print("    延迟 500ms 之后：射出 %d 支，队列 %d ｜ 瞄准 %s" % [
		f1.size(), _s.gm.sentry_queue_size(), f1_at])
	_chk(f1.size() == 1, "等满 500ms 应射出一支")
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
	_s.gm.sentry_tick(0.6)
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
	var g1: Array = _s.gm.sentry_tick(0.6)          # 先等满 500ms 触发延迟
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
	var mk: Projectile = _s._spawn_marker(mkthrow, Vector2(5.5, 9.5))
	print("    召唤球：sentry_trigger=%s hit_tags=%s 半径=%.2f" % [
		mk.sentry_trigger, mk.hit_tags, mk.hit_r])
	_chk(mk.sentry_trigger, "轨道召唤球必须能惊动哨兵")
	_chk(mk.hit_tags.has("arrow"), "轨道召唤球必须能被箭打掉")
	s25.queue.clear()
	s25.cooldown = 0.0
	_chk(_s.gm.check_projectile(mk), "召唤球进入射界应入队")
	s25.cooldown = 0.0
	_chk(_s.gm.sentry_tick(0.6).size() == 1, "召唤球应被哨兵瞄准射出一支箭（弹道物不受'静止'限制）")
	s25.queue.clear()
	_s.clear_projectiles()

	# 炮弹被箭击落：炮弹有碰撞体积
	# 走工厂生成：保证"测试造的炮弹"和游戏里的炮弹字段完全一致
	_s.clear_projectiles()
	var shooter2 = null
	for u in _s.units:
		if u.name == "Airburst mortar": shooter2 = u
	shooter2.cell = Vector2i(5, 5)
	var sh2: Projectile = _s._spawn_shell(shooter2, Vector2(9.0, 9.0), false)
	var ar2: Projectile = _s._spawn_arrow(shooter2, Vector3(5.5, 0.75, 5.5),
		Vector3(9.5, 0.55, 9.5), null, false, false)
	_chk(_s._proj_collision(sh2) == ar2, "箭矢应能击落炮弹（炮弹必须有碰撞体积）")
	_s.clear_projectiles()
	_chk(_s.live_projectiles() == 0, "清场后不应残留弹道物")

	# 飞出边界的炮弹：直接移除，不爆炸、不留红圈
	_s.clear_projectiles()
	var rings_before: int = _s.count_impact_rings()
	_s.active = null
	var p_out: Projectile = _s._spawn_shell(g25, Vector2(float(_s.GW) + 12.0, 5.0), true, 1.0)
	for i in 3000:
		_s.field.step(1.0 / 30.0)
		if not p_out.alive:
			break
	print("    打向界外 (40,5)：存活=%s 移除原因=%s 红圈 %d -> %d" % [
		p_out.alive, p_out.removed_reason, rings_before, _s.count_impact_rings()])
	_chk(not p_out.alive, "飞出边界的炮弹应被移除")
	_chk(p_out.removed_reason == "out_of_bounds", "移除原因应是出界")
	_chk(_s.count_impact_rings() == rings_before, "出界的炮弹不应产生爆炸红圈")
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
	var shell_b: Projectile = _s._spawn_shell(shooter_b, Vector2(12.0, 5.5), false)
	var arrow_b: Projectile = _s._spawn_arrow(shooter_b, Vector3(4.5, 0.75, 5.5),
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
	for lg in _s._debug_log:
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
	var low_shell: Projectile = _s._spawn_shell(shooter_b, Vector2(6.5, 6.5), false)
	low_shell.from = Vector2(6.5, 6.5)
	low_shell.to = Vector2(6.5, 6.5)
	_s._air_burst(low_shell)                       # 起飞高度 0.85 -> 贴脸炸
	print("    贴地空爆（高 %.2f）：杰拉尔德力量 %d -> %d" % [
		low_shell.pos3().y, hp_low, gerald.power_cur])
	_chk(gerald.power_cur < hp_low, "贴地空爆必须有伤害")
	var hp_high: int = gerald.power_cur
	var high_shell: Projectile = _s._spawn_shell(shooter_b, Vector2(6.5, 6.5), false)
	high_shell.from = Vector2(6.5, 6.5)
	high_shell.to = Vector2(6.5, 6.5)
	high_shell.apex = 3.0
	high_shell.t = 0.5                              # 抬到拱顶
	_s._air_burst(high_shell)
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
	var land_arrow: Projectile = _s._spawn_arrow(archer, Vector3(4.5, 0.75, 4.5),
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
	_s._menu_attack()
	_chk(_s.phase == _s.Phase.CHOOSE_TARGET, "近战点普攻后应进入选目标（要确认）")
	foe27.cell = Vector2i(6, 5)
	foe27.power_cur = foe27.power_max
	foe27.visual.position = Vector3(6.5, 0.0, 5.5)
	_s.attackable = Targeting.attack_range_cells(gerald, _s.GW, _s.GH)
	_chk(_s.attackable.has(foe27.cell), "相邻敌格应在可攻击范围里")
	_s._set_pending("attack", foe27.cell, foe27)      # 第一次点
	_chk(_s._pending_root.visible, "待确认黄勾必须立刻出现（不能依赖调用方补 _draw_hints）")
	_s._draw_hints()
	print("    第一次点 %s：待确认=%s 黄勾可见=%s 笔画=%d" % [
		foe27.name, _s._pending_kind, _s._pending_root.visible, _s._check_mats.size()])
	_chk(_s._pending_kind == "attack" and _s._same_pending("attack", foe27.cell),
		"第一次点目标只是待确认，不弹菜单")
	_chk(_s._pending_root.visible, "待确认黄勾应出现")
	_chk(_s._check_mats.size() == 4, "黄勾 = 2 段笔画 × (亮芯 + 柔光)")
	# 朝向：必须正对摄像机（不能斜）
	_s._face_check_mark()
	var cb: Basis = _s._check_root.global_transform.basis
	var camz: Vector3 = _s._camera.global_transform.basis.z
	print("    黄勾朝向与摄像机 z 轴点积 = %.4f（1 = 完全正对）" % cb.z.normalized().dot(camz))
	_chk(absf(cb.z.normalized().dot(camz) - 1.0) < 0.001, "黄勾必须正对摄像机，不能斜")
	# 第二次点同一格 -> 确认，弹攻击菜单
	if _s._same_pending("attack", foe27.cell):
		_s._clear_pending()
		_s._show_attack_menu(foe27)
	_s._draw_hints()
	_chk(_s._attack_menu.visible, "第二次点同一目标才弹攻击菜单")
	_chk(not _s._pending_root.visible, "确认后黄勾必须消失")
	_s._attack_menu.visible = false
	# 远程：同样要确认
	alette.cell = Vector2i(9, 5)
	alette.visual.position = Vector3(9.5, 0.0, 5.5)
	alette.begin_turn()
	_s.active = alette
	_s._menu_attack()
	_chk(_s.phase == _s.Phase.CHOOSE_TARGET, "远程点普攻后也应进入选目标（要确认）")
	# 投掷手：直接进入瞄准，不需要确认
	var mortar27 = null
	for u in _s.units:
		if u.name == "Airburst mortar": mortar27 = u
	mortar27.begin_turn()
	_s.active = mortar27
	_s._menu_attack()
	_chk(_s.phase == _s.Phase.AIMING and _s._aim_active, "投掷手瞄准不需要确认（直接进入拖动瞄准）")
	_s._aim_active = false
	_s._arrow_root.visible = false

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
	var arrow1: Projectile = _s._spawn_arrow(alette, Vector3(5.5, 0.75, 12.5),
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
	var arrow1b: Projectile = _s._spawn_arrow(alette, Vector3(5.5, 0.75, 12.5),
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
	var arrow2: Projectile = _s._spawn_arrow(alette, Vector3(5.5, 0.75, 12.5),
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
		_chk(d_refl <= 8.0, "7 格距离的散步很小，落点应贴在射手附近")
	# 让反弹箭飞完：应该打回射手身上
	for i in 900:
		_s.field.step(1.0 / 60.0)
		if refl != null and not refl.alive:
			break
	print("    反弹箭落地后：射手力量 %d -> %d" % [al_hp, alette.power_cur])
	_chk(alette.power_cur < al_hp, "反弹的箭应该打回射手身上")

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
	_s._on_unit_died(gerald)
	print("    阵亡后：哨兵=%s ｜ 蓄势层数=%d" % [_s.gm.has_sentry(gerald), Passives.focus_stacks(gerald)])
	_chk(not _s.gm.has_sentry(gerald), "阵亡应清除哨兵警戒")
	_chk(Passives.focus_stacks(gerald) == 0, "阵亡应清空蓄势层数")
	print("    杰拉尔德阵亡：还要等 %d 个回合 ｜ 归位格 %s ｜ 可见=%s" % [
		_s.gm.revive_countdown(gerald), gerald.home_cell, gerald.visual.visible])
	_chk(_s.gm.revive_countdown(gerald) == GameMaster.HERO_REVIVE_TURNS,
		"英雄阵亡后要等 %d 个回合" % GameMaster.HERO_REVIVE_TURNS)
	_chk(not gerald.visual.visible, "阵亡期间模型收起")
	_chk(Level.hero_cells(gerald.side).has(gerald.home_cell),
		"归位格必须是关卡给的英雄格（两公主之间）")
	for i in GameMaster.HERO_REVIVE_TURNS - 1:
		_s.gm.dispatch_turn_boundary()
		for u in _s.gm.due_revives():
			_s._revive_hero(u)
	_chk(not gerald.is_alive(), "没到 10 个回合还不能复活")
	_s.gm.dispatch_turn_boundary()
	for u in _s.gm.due_revives():
		_s._revive_hero(u)
	print("    10 个回合后：力量 %s/%s 护甲 %s/%s 位置 %s 可见=%s" % [
		gerald.power_cur / 1000.0, gerald.power_max / 1000.0,
		gerald.armor_cur / 1000.0, gerald.armor_max / 1000.0, gerald.cell, gerald.visual.visible])
	_chk(gerald.is_alive(), "10 个回合后应满血复活")
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
	_s._place_kind = "木刺"
	_s.place_left["木刺"] = 1
	_s._place_at(Vector2i(8, 8))
	_chk(_s.placeables.size() >= 1, "应能放下一个木刺")
	var spike2: Placeable = _s.placeables[_s.placeables.size() - 1]
	print("    木刺在 %s ｜ 力量 %d ｜ 阻挡远程=%s" % [spike2.cell, spike2.power_cur / 1000, spike2.block_ranged])
	# 近战：杰拉尔德贴着打
	gerald.cell = Vector2i(8, 9)
	gerald.has_acted = false
	gerald.has_moved = false
	_s.active = gerald
	var hp_spike: int = spike2.power_cur
	_s._attack_target_placeable(spike2)
	print("    杰拉尔德近战：木刺力量 %d -> %d" % [hp_spike / 1000, spike2.power_cur / 1000])
	_chk(spike2.power_cur < hp_spike or not spike2.is_alive(), "近战英雄应能锁定并打伤沙盒道具")
	# 远程：阿莱特射它（木刺不挡远程，但【明确锁定】必须打得中）
	spike2.power_cur = spike2.power_max
	alette.cell = Vector2i(8, 4)
	alette.has_acted = false
	alette.has_moved = false
	_s.active = alette
	_s.clear_projectiles()
	_s._attack_target_placeable(spike2)
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
	_s._place_kind = ""

	# ── 30. AI 决策（索敌打分 / 技能规避 / 休息与靠拢）──
	print("\n[30] AI 决策")
	_s.gm.ai_enabled = true
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
	ctx.reachable = _s._compute_reachable(ai_me)
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
	# ③ 投掷手不该把地毯丢进敌方哨兵射界
	var mortar_ai: Unit = null
	for u in _s.units:
		if u.name == "Airburst mortar": mortar_ai = u
	var mctx := Ai.Ctx.new()
	mctx.rng = RngService.new(3)
	mctx.me = mortar_ai
	mctx.foes = ctx.foes
	mctx.foe_king = foe_king
	mctx.reachable = {}
	mctx.placeables = []
	var blocked := {}
	for o in ctx.foes:
		blocked[o.cell] = true
		blocked[Vector2i(o.cell.x + 1, o.cell.y)] = true
	mctx.sentry_cells = blocked
	var mpl := Ai.plan(mctx)
	print("    投掷手（落点全在哨兵射界里）：%s" % mpl.get("note", "-"))
	_chk(String(mpl.get("action", "")) != "skill" or String(mpl.get("skill", "")) != "carpet_bomb",
		"投掷手不应把地毯式轰炸丢进敌方哨兵射界")
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
	_s.gm.ai_enabled = false

	# ── 32. 日志只允许"既定事实"（谁打谁 / 伤害 / 谁触发了什么）──
	print("\n[32] 日志体检")
	var banned := ["点高亮格", "未选择角色", "再点一次", "还没轮到", "精力不足", "本回合已经行动过了",
		"无法使用", "不能休息", "先从道具箱", "选择攻击方式", "假人无 AI", "操作已锁定",
		"放不下", "没有可用技能", "用完了", "请点", "右键返回"]
	var bad: Array[String] = []
	for lg in _s._debug_log:
		var s := String(lg)
		for b in banned:
			if s.contains(b):
				bad.append(s)
	print("    日志共 %d 行，命中提示类文案 %d 行" % [_s._debug_log.size(), bad.size()])
	var tail: Array = _s._debug_log.slice(maxi(0, _s._debug_log.size() - 10))
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
	_s._spawn_grenade_model(Vector2i(6, 6), grn)
	print("    落地模型 %d 个 ｜ GM 在途 %d" % [_s._grenade_models.size(), _s.gm.pending.size()])
	_chk(_s._grenade_models.has(Vector2i(6, 6)), "手榴弹落地应留下模型（不可交互）")
	_chk(_s.gm.pending.size() == 1 and String(_s.gm.pending[0].skill_id) == "grenade",
		"GM 应开始 4 回合倒计时")
	# ② 4 个回合边界后爆炸 -> 8 枚破片
	var gcell := Vector2i(6, 6)
	for i in 4:
		for p in _s.gm.dispatch_turn_boundary():
			if String(p.skill_id) == "grenade":
				_s._explode_grenade(p)
	var frags := 0
	for it in _s.field.items:
		var pp: Projectile = it["p"]
		if pp.kind == Projectile.KIND_FRAGMENT and pp.alive:
			frags += 1
			_chk(pp.hit_self, "手榴弹破片必须能打自己人（hit_self）") if frags == 1 else null
	print("    爆炸后场上破片 %d 枚 ｜ 模型残留 %d" % [frags, _s._grenade_models.size()])
	_chk(frags == 8, "爆炸应撒出 8 枚破片")
	_chk(_s._grenade_models.is_empty(), "爆炸后模型应被清掉")
	_s.clear_projectiles()
	# ③ 圣萨尼：复活最后一个阵亡的队友，每条命一次
	var mate: Unit = null
	for u in _s.units:
		if u.name == "Gerald": mate = u
	mate.power_cur = 0
	_s._on_unit_died(mate)
	print("    队友阵亡：%s ｜ 她的标记=%s" % [mate.name, sani.tags.has("holy_sani_used")])
	_s._holy_sani_check(sani)
	print("    圣萨尼之后：队友 alive=%s 位置 %s ｜ 已用标记=%s" % [
		mate.is_alive(), mate.cell, sani.tags.has("holy_sani_used")])
	_chk(mate.is_alive() and mate.power_cur == mate.power_max, "圣萨尼应立即复活最后一个阵亡的队友")
	_chk(sani.tags.has("holy_sani_used"), "每条命只能触发一次")
	# 第二条命：阵亡清状态 -> 标记被清掉，可以再用
	sani.tags.clear()
	_chk(not sani.tags.has("holy_sani_used"), "阵亡清状态后她又能用一次（每条命一次）")

	print("\n── 共 %d 项检查，失败 %d 项 ──" % [_checks, _fails.size()])
	if _fails.is_empty():
		print("✅ v3 试玩链路全部通过")
		quit(0)
	else:
		for f in _fails:
			print("   ❌ ", f)
		quit(1)

