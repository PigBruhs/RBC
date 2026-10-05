# ══════════════════════════════════════════════════════════════════════════════
# 回合机 + 行棋寻路 + 单位生命周期（从 battle_scene.gd 拆出，P2b）
#
# 形态与其他模块一致：RefCounted 子对象 + 构造注入宿主，模块内用 _st.xxx 显式访问共享状态。
# 行为零变化：函数体逐字搬运，只做两类改写 ——
#   宿主成员（var/func/const/signal/枚举 Phase） -> _st.<名字>
#   被搬走的函数互相调用                        -> 直接调模块方法（去掉前导下划线）
# 宿主保留同名薄包装，所以 _process / _ready / 回调 Callable / 别人的模块调用点全部照旧。
#
# ⚠️ 四条血泪口径（搬过来时逐字保留，别重构）：
#   1. 队头模型：回合结束 queue.advance(active) 必须显式传人；阵亡当场 remove；复活 push_front
#   2. 空队列不许无限递归：_begin_next_round 推进 GM 边界等人复活，连续 200 个兜底结束
#   3. _check_over 读 Level.victory()（第 97 轮），保持 TurnFlow.check 调用形态
#   4. _finish_turn 留在宿主（共享函数），本模块只负责它调用的 _check_over / _next_turn
# ══════════════════════════════════════════════════════════════════════════════
class_name TurnRunner
extends RefCounted

## 宿主 BattleScene。**故意不加静态类型**（宿主没有 class_name，静态写 Node3D 会编译报错）。
var _st = null


func _init(host: Node3D) -> void:
	_st = host


func next_turn() -> void:
	_st.fx.clear_hints()
	_st.phase = _st.Phase.IDLE
	_st.selected = null
	_st._aim_active = false
	_st._arrow_root.visible = false
	for u in _st.units:
		if u.visual != null:
			u.visual.set_active(false)
			u.visual.set_selected(false)

	var u: Unit = _st.queue.current()
	if u == null:
		# 本轮走完：存活单位重置行动标记，开新一轮
		for x in _st.units:
			if x.is_alive():
				x.begin_turn()
		if check_over():
			return
		await begin_next_round()
		return

	# 用户口径第 87 轮：死人【当场移出队列】，所以队列里不会有尸体 ——
	# current() 只会返回活人（它自己也会顺手清一遍，兜底）。

	# 最后一人机制（用户新规则）：某一方只剩 1 人时，立刻刷新队列，
	# 把当前回合交给这个孤军，然后对面每人一回合，再轮回孤军。
	if check_last_stand():
		u = _st.queue.current()
		if u == null:
			await begin_next_round()
			return

	# 不变式（用户报过 bug）：**严格交替模式下**绝不允许同一方连续两回合。
	# 队列理论上不会这样，一旦出现（例如某条路径多推进了一次）就地纠正：这回合让给对面。
	# 例外：对面队列是空的（全在等复活）—— 那时本来就该他连着动，不算违规。
	#
	# ⚠ 第 99 轮：`MODE_BY_SIDE`（Reaper 战）**故意**让同一方连续行动 ——
	#   所以这条纠正必须跳过，否则它会把 by_side 的"一边全部行动完"硬拉回交替，
	#   表现为"同一方每个人都能反复动、另一边永远轮不到"（实测就是这个症状）。
	var other_side := 1 - u.side
	if _st.queue.mode != TurnQueue.MODE_BY_SIDE \
			and not _st.queue.last_stand and _st._last_turn_side != -1 \
			and u.side == _st._last_turn_side and _st.queue.has_side(other_side):
		_st._log("  ⚠ 检测到同一方连续行动，已纠正：%s 让位" % u.name)
		_st.queue.advance(u)
		var other: Unit = _st.queue.current()
		if other != null and other.side != _st._last_turn_side:
			u = other
		_st._log("     改为 %s（%s）行动" % [u.name, "我方" if u.side == UnitData.Side.PLAYER else "敌方"])
	_st._last_turn_side = u.side
	_st._turn_watch_t = 0.0
	if _st._dive_begin(u):
		_st.active = u
		u.begin_turn()
		return
	_st._holy_sani_check(u)
	_st.active = u
	u.begin_turn()
	_st._turn_just_finished = null            # 新回合开始，解除幂等保护
	_st.gm.on_turn_begin(u)                   # 被动机会：只有他自己的回合开始才重置（杰拉尔德弹反）
	# 哨兵状态持续到"自己的下一个回合"——所以自己的回合一开始就撤掉警戒
	if _st.gm.has_sentry(u):
		_st.gm.clear_sentry_for(u)
		_st._log("  %s 的【哨兵】警戒结束" % u.name)
	if u.visual != null:
		u.visual.set_active(true)
	_st.turn_started.emit(u)

	_st._log("轮到 %s（%s）行动%s" % [u.name, Unit.role_name(u.role),
		"（敌方阵营 · 玩家操控）" if u.is_manual() and u.side == UnitData.Side.ENEMY else ""])

	# 加农炮 AI（老国王）：不管哪一方，轮到他就朝最近的敌对单位打一发
	if Passives.has(u, "cannon_ai"):
		await _st.get_tree().create_timer(UnitData.DUMMY_SKIP_DELAY * 0.6).timeout
		_st._fire_cannon_ai(u)
		return

	# 通用 AI（用户口径：敌方整队由 AI 接管；我方只在"自动演算"模式下交给 AI）
	if _st._is_ai_unit(u):
		_st._ai_take_turn(u)
		return

	# 没有 AI 的假人：轮到它时停顿一下自动跳过，否则测试/试玩会卡住。
	# 注意：阵营是敌方但标记了 controllable 的角色由玩家操作，**不自动跳过**。
	if not u.is_manual():
		await _st.get_tree().create_timer(UnitData.DUMMY_SKIP_DELAY).timeout
		_st._finish_turn()
		return

	_st.action_menu.show_action_menu()


func start_round() -> void:
	_st.round_no += 1
	_st.queue = TurnQueue.new(_st.rng)
	# 回合顺序模式来自【场景元数据】（第 99 轮）：没声明 = 严格交替（既有行为）。
	# Reaper 战声明 `turn_mode = "by_side"` -> 一边全部行动完才轮到另一边。
	_st.queue.mode = Level.turn_mode()
	var n: int = _st.queue.rebuild(_st.units)
	_st._log("—— 第 %d 轮开始，队列 %d 人：%s ——" % [_st.round_no, n, _st.queue.dump()])
	if _st.queue.mode == TurnQueue.MODE_BY_SIDE:
		_st._log("  回合顺序：一边全部行动完才轮到另一边（本场景专属）")
	_st.round_started.emit(_st.round_no)
	next_turn()


func begin_next_round() -> void:
	if not _st._has_actor():
		_st._log("  ⏳ 场上没有可行动单位（英雄都在等复活）：推进回合边界")
		var steps := 0
		while not _st._has_actor() and steps < 200 and not _st.game_over:
			steps += 1
			await _st._gm_step()
		if not _st._has_actor():
			# 极端兜底：推了这么多边界还是没人能行动 -> 结束战斗，绝不允许卡死
			_st._log("  ⚠ 连续 %d 个回合边界都没有可行动单位，判定战斗结束" % steps)
			if not _st.game_over:
				_st._show_result(false)
			return
	if _st.game_over:
		return
	start_round()


func check_over() -> bool:
	# 胜负判定是纯函数，规则**来自本场景的元数据** `Level.victory()`（用户口径第 97 轮：
	# 不同场景的胜负条件相互独立）。缺省 = 一方老国王阵亡。
	# 判定细节见 `core/turn_flow.gd` 顶部与 `docs/level_campaign.md`；加场景/加玩法都不用改这里。
	var cfg := Level.victory()
	var w := TurnFlow.check(_st.units, cfg, _st.gm.turn_count)
	if w == TurnFlow.NONE:
		return false
	_st._log("  ⚑ 战斗结束：%s（%s）" % [
		"我方胜" if w == TurnFlow.PLAYER else "敌方胜", TurnFlow.reason_text(cfg, w)])
	_st._show_result(w == TurnFlow.PLAYER)
	return true


func check_last_stand() -> bool:
	# 决策在 TurnFlow（纯函数，可无头测试）；这里只负责"真的重排队列"
	var lone_alive: bool = _st.queue.lone != null and _st.queue.lone.is_alive()
	var plan := TurnFlow.last_stand_plan(_st.units, _st.queue.last_stand, lone_alive)
	if not bool(plan["changed"]):
		return false
	if bool(plan["want"]):
		var lone_unit: Unit = plan["lone"]
		var opps: Array[Unit] = plan["opponents"]
		_st.queue.enter_last_stand(lone_unit, opps)
		_st._log("—— 进入最后一人连击：%s 独存 vs %d 人（%s）——" % [
			lone_unit.name, opps.size(), _st.queue.dump()])
	else:
		_st.queue.exit_last_stand(_st.units)
		_st._log("—— 退出最后一人连击，回到常规循环 ——")
	return true


func queue_alternation_ok() -> bool:
	var prev := -1
	for u in _st.queue.order:
		if not u.is_alive():
			continue
		if u.side == prev:
			return false
		prev = u.side
	return true


func on_revive_timeout(u: Unit) -> void:
	if u == null or u.visual == null:
		return
	_st._revive_timers.erase(u)
	_st.uid_dead.erase(u)
	u.power_cur = u.power_max
	u.armor_cur = u.armor_max
	u.energy = u.energy_max
	# 第 109 轮：午餐盒复活时把它的**双机/热量状态清掉** —— 用户口径
	# 「炮管初始状态为指向车头（**只是复活时的状态**，后续改变后不会自动恢复）」。
	# 清掉之后下一次 `_lb_state(u)` 会重建，`theta` 回到 90°（= 车头）。
	_st._lb_forget_state(u)
	u.visual.visible = true
	u.visual.update_orb()
	_st._log("  ♻ %s 已满血复活（力%s 甲%s）" % [
		u.name, _st._fmt(u.power_cur), _st._fmt(u.armor_cur)])


func revive_hero(u: Unit) -> void:
	if u == null:
		return
	if u.visual != null:
		u.visual.visible = true
	_st.uid_dead.erase(u)
	u.power_cur = u.power_max
	u.armor_cur = u.armor_max
	u.energy = u.energy_max
	u.has_moved = false
	u.has_acted = false
	# 第 109 轮：午餐盒复活 -> 双机/热量状态清掉（炮管回到指向车头，见 `on_revive_timeout`）
	_st._lb_forget_state(u)
	u.cell = revive_cell(u)
	if u.visual != null:
		u.visual.position = Vector3(float(u.cell.x) + 0.5, u.hover, float(u.cell.y) + 0.5)
		u.visual.update_orb()
	queue_revive(u)
	_st._log("    %s 复活：状态已清空（阵亡时清掉的哨兵警戒等不会带回来）" % u.name)
	_st._log("  ♻ %s 复活（力%s 甲%s 精力%s）→ 回到 %s" % [
		u.name, _st._fmt(u.power_cur), _st._fmt(u.armor_cur), u.energy_points(), u.cell])


func revive_unit(u: Unit) -> void:
	if u.visual != null:
		u.visual.visible = true
		u.visual.update_orb()
	_st.uid_dead.erase(u)                # 调试复活：把阵亡账目清掉
	queue_revive(u)                 # 调试复活也走同一条路：压回队列队头
	_st._log("[调试] %s 力量 >0，已复活（力%s 甲%s）" % [u.name, _st._fmt(u.power_cur), _st._fmt(u.armor_cur)])


func revive_cell(u: Unit) -> Vector2i:
	var hs: Array = Level.respawn_cells(u.side)
	if hs.is_empty():
		hs = Level.hero_cells(u.side)
	if hs.is_empty():
		return u.home_cell
	var idx := 0
	for x in _st.units:
		if x == u:
			break
		if x.side == u.side and x.has_turn():
			idx += 1
	var pref: Vector2i = hs[idx % hs.size()]
	var cands: Array[Vector2i] = [pref]
	for c in hs:
		var cc: Vector2i = c
		if cc != pref:
			cands.append(cc)
	if not cands.has(u.home_cell):
		cands.append(u.home_cell)
	for c in cands:
		if not cell_occupied(c, u):
			return c
	return u.home_cell


func queue_revive(u: Unit) -> void:
	if _st.queue != null and u != null and u.has_turn():
		_st.queue.push_front(u)


func check_active_alive() -> void:
	if _st.active == null or _st.active.is_alive():
		return
	_st._log("  %s 在自己的回合中阵亡 —— 立刻结束该回合" % _st.active.name)
	_st._finish_turn()


func sync_unit_visibility() -> void:
	for u in _st.units:
		if u.visual == null:
			continue
		if u.is_alive() and not u.visual.visible:
			u.visual.visible = true


func on_unit_died(u: Unit) -> void:
	if u.visual == null:
		return
	# 幂等（第 89 轮）：一次阵亡只处理一次。
	# 以前只有假人查 uid_dead，于是"坠机动画期间又挨了一发"会连报两次阵亡、
	# 还会把复活计时重排一遍。复活时会 erase（_revive_hero / _on_revive_timeout）。
	if _st.uid_dead.has(u):
		if not u.is_alive():
			return
		_st.uid_dead.erase(u)          # 有人把他救回来了（调试/测试直接改力量也算）：重新记账
	var dummy := u.name.begins_with("Dummy")
	if dummy:
		_st.uid_dead[u] = true
		_st._log("  ☠ %s 阵亡" % u.name)
		_st._log("    假人不死：%s 秒后满血复活" % UnitData.DUMMY_REVIVE_SEC)
		u.visual.visible = false
		if _st._revive_timers.has(u) and _st._revive_timers[u] != null:
			var old: SceneTreeTimer = _st._revive_timers[u]
			if old.timeout.is_connected(on_revive_timeout.bind(u)):
				old.timeout.disconnect(on_revive_timeout.bind(u))
		var tm: SceneTreeTimer = _st.get_tree().create_timer(UnitData.DUMMY_REVIVE_SEC)
		_st._revive_timers[u] = tm
		tm.timeout.connect(on_revive_timeout.bind(u))
	else:
		_st.uid_dead[u] = true
		_st._log("  ☠ %s 阵亡" % u.name)
		u.visual.visible = false
		# 用户口径第 87 轮：**阵亡 = 当场移出回合队列**（不是跳到队尾）。
		# 死人不再占位置，队列整圈也不再因为他变长；复活时再压回队头。
		if _st.queue != null:
			_st.queue.remove(u)
		# 用户口径：**阵亡清除一切 buff 与状态**（哨兵警戒不保留、蓄势清零、挂起的技能作废）
		_st.gm.note_death(u)          # 阵亡顺序（圣萨尼要用）
		clear_unit_states(u)
		# 英雄（三家将）：用户口径 —— 无限满血满护甲重生，每次等 10 个回合
		if not u.is_king and not Passives.has(u, "always_sentry"):
			var rt: int = Level.respawn_turns(u.name)
			_st.gm.schedule_hero_revive(u, rt)
			_st._log("    %s 将在 %d 个回合后满血复活（位置 %s）" % [u.name, rt, revive_cell(u)])


func clear_unit_states(u: Unit) -> void:
	if u == null:
		return
	var had_sentry: bool = _st.gm.has_sentry(u)
	_st.gm.clear_sentry_for(u)
	_st.gm.forget_passives(u)
	_st.gm.cancel_pending_for(u.name)
	Passives.clear_focus(u)
	u.tags.clear()
	_st._log("    %s 阵亡：所有状态已清除（哨兵=%s）" % [u.name, "有" if had_sentry else "无"])


func do_move(u: Unit, cell: Vector2i) -> void:
	cell = clamp_cell(cell)          # 任何移动都不许出界
	# 走路动画：沿路径逐格"抬腿 + 小跳"，同时朝向转到行进方向（不是瞬移）
	var path: Array[Vector2i] = path_to(u, cell)
	_st.gm.on_move_begin(u)                     # 哨兵：这次移动的"已触发"闩清零
	# ── 用户口径（第 107 轮）：**车体朝向与炮管朝向解耦** ──
	#   「车体转向又没有延迟而且**只在移动时需要转向**；炮管随时都有可能转向……
	#     载具的精髓就是移动与瞄准方向不一致（战列舰：车体向前、炮管垂直车体向左）」
	#   所以：**移动开始那一刻转一次底盘**（无插值、停下不回正），
	#   **炮管的 theta/phi 一行不碰**（`_lb_tick` 那条链照旧）。
	_st._lb_turn_body(u, Vector2(float(u.cell.x) + 0.5, float(u.cell.y) + 0.5),
		Vector2(float(cell.x) + 0.5, float(cell.y) + 0.5))
	if u.visual != null and path.size() > 1:
		u.visual.walk_path(path)
	u.cell = cell
	u.has_moved = true
	if u.visual == null or path.size() <= 1:
		# 没有走路动画（无头测试 / 原地）：直接按终点判定哨兵
		_st.sentry.lock(u, Vector2(float(cell.x) + 0.5, float(cell.y) + 0.5))
	_st.reachable = compute_reachable(u)      # 已移动 -> 空集合，不能再动
	# 移动后重开菜单：此时"休息"会被禁用（移动过不能休息）
	_st.action_menu.show_action_menu()
	_st._place_menu_near(u)
	_st.fx.draw_hints()
	_st._refresh_all()


func path_to(u: Unit, goal: Vector2i) -> Array[Vector2i]:
	var occupied: Dictionary = _st._blocked_cells()          # 沙盒道具：阻挡移动的占格
	for o in _st.units:
		if o.is_alive() and o != u:
			# 第 104 轮：占多格的角色（车 1×2）**每一格都挡人**
			for c in Targeting.unit_cells(o):
				occupied[c] = true
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
				if not Level.in_play(n):
					continue
				# 第 104 轮：落点要能让**整个**占地放得下（车 1×2 的第二格也不能压人）
				if not Targeting.unit_fits_at(u, n, occupied):
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


func compute_reachable(u: Unit) -> Dictionary:
	var res := {}
	if u.has_moved or not u.is_alive():
		return res
	var occupied: Dictionary = _st._blocked_cells()          # 沙盒道具：阻挡移动的占格
	for o in _st.units:
		if o.is_alive():
			# 第 104 轮：占多格的角色**每一格都挡人**（含它自己：锚点格本来就该被 dist 排除）
			for c in Targeting.unit_cells(o):
				occupied[c] = true
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
				if not Level.in_play(n):
					continue
				# 第 104 轮：落点要能让**整个**占地放得下（车 1×2 的第二格也不能压人）
				if not Targeting.unit_fits_at(u, n, occupied):
					continue
				if occupied.has(n) or dist.has(n):
					continue
				dist[n] = d + 1
				res[n] = true
				nxt.append(n)
		frontier = nxt
	return res


func tick_unit_walk(_delta: float) -> void:
	if _st.gm.sentries.is_empty():
		return
	for u in _st.units:
		if not u.is_alive() or u.visual == null:
			continue
		var vis := u.visual as UnitVisual
		if vis == null or not vis.is_walking():
			continue
		_st.sentry.lock(u, Vector2(vis.position.x, vis.position.z))


func in_bounds(c: Vector2i) -> bool:
	return Level.in_play(c)


func clamp_cell(c: Vector2i) -> Vector2i:
	return Vector2i(clampi(c.x, _st.PX, _st.PX + _st.PW - 1), clampi(c.y, _st.PY, _st.PY + _st.PH - 1))


func spawn_units() -> void:
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
			_st._log("[关卡] 名单里的 %s 不在花名册里，跳过" % nm)
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
		if bname.begins_with(_st.HELI_PREFIX):
			u.hover = float(Level.heli().get("hover_h", 2.0))
		_st.units.append(u)
	for u in _st.units:
		var v := UnitVisual.new()
		_st.add_child(v)
		v.setup(u)          # 待机浮动的 Tween 由 UnitVisual 自己管理（走路时自动让位）
	# 常备哨兵（公主）：没有自己的回合，一直处于哨兵状态
	for u in _st.units:
		if Passives.has(u, "always_sentry"):
			var s: GameMaster.Sentry = _st.gm.add_sentry(u, maxi(1, u.rng_min), maxi(1, u.rng_max))
			_st._log("[常备哨兵] %s 一直处于警戒：射界 %d~%d" % [u.name, s.rng_min, s.rng_max])


func unit_at(cell: Vector2i) -> Unit:
	for u in _st.units:
		if u.is_alive() and u.cell == cell:
			return u
	return null


func cell_occupied(c: Vector2i, except: Unit) -> bool:
	for o in _st.units:
		if o != except and o.is_alive() and c in Targeting.unit_cells(o):
			return true
	return false

