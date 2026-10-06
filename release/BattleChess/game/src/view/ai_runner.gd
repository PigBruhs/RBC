# ══════════════════════════════════════════════════════════════════════════════
# AI 驱动 + GM 演出推进（从 battle_scene.gd 拆出，P2c）
#
# 模块形态与其他一致：RefCounted 子对象 + 构造注入宿主，模块内用 _st.xxx 显式访问共享状态。
# 行为零变化：函数体逐字搬运，只做两类改写 ——
#   宿主成员（var/func/const/signal/枚举 Phase/继承自 Node 的方法） -> _st.<名字>
#   被搬走的函数互相调用 -> 直接调模块方法（去掉前导下划线）
#
# ⚠️ 跨模块事实接口（**宿主同名包装不许删**）：turn_runner.gd 正在通过 _st. 调
#   _fire_cannon_ai / _is_ai_unit / _ai_take_turn / _gm_step（回合机推进要用）。
#
# ⚠️ AI 口径（别重构）：付不起的普攻不许选、执行端打不出必须自己结束回合（第 82/86 轮，防软锁）；
#   AI 回合看门狗在直升机齐射期间让位（_st._salvo_u，第 93 轮），否则齐射会被砍断；
#   "移动中开火"已取消（第 86 轮）—— 一律等走完再决策。
# ⚠️ AI 开关（ai_enabled / ai_autoplay_player）已按 P4 从 GameMaster 迁到宿主（驱动层），
#   本模块经 _st.ai_enabled / _st.ai_autoplay_player 读；测试走宿主 t_* 门面写。
# ══════════════════════════════════════════════════════════════════════════════
class_name AiRunner
extends RefCounted

## 宿主 BattleScene。**故意不加静态类型**（宿主没有 class_name）。
var _st = null


func _init(host: Node3D) -> void:
	_st = host


func ai_ctx(u: Unit) -> Ai.Ctx:
	var c := Ai.Ctx.new()
	c.me = u
	c.rng = _st.rng
	for o in _st.units:
		if not o.is_alive():
			continue
		if o.side != u.side:
			c.foes.append(o)
			if o.is_king:
				c.foe_king = o
	c.reachable = _st._compute_reachable(u)
	c.placeables = _st.placeables
	c.me_has_sentry = _st.gm.has_sentry(u)
	# 敌方哨兵覆盖的格子（全图视野，投掷手要靠它避开技能落点）
	for s in _st.gm.sentries:
		if s.side == u.side or s.owner == null or not s.owner.is_alive():
			continue
		var ctr: Vector2 = _st.gm.sentry_center(s)
		var r := float(s.rng_max)
		var x0: int = maxi(_st.PX, int(ctr.x - r) - 1)
		var x1: int = mini(_st.PX + _st.PW - 1, int(ctr.x + r) + 1)
		var y0: int = maxi(_st.PY, int(ctr.y - r) - 1)
		var y1: int = mini(_st.PY + _st.PH - 1, int(ctr.y + r) + 1)
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				if s.in_range(ctr, Vector2(float(x) + 0.5, float(y) + 0.5)):
					c.sentry_cells[Vector2i(x, y)] = true
	return c


func ai_take_turn(u: Unit) -> void:
	_st._ai_turn = true
	await _st.get_tree().create_timer(UnitData.DUMMY_SKIP_DELAY * 0.5).timeout
	if not u.is_alive():
		_st._ai_turn = false
		_st._finish_turn()
		return
	var plan := Ai.plan(ai_ctx(u))
	_st._log("  🤖 %s：%s" % [u.name, plan.get("note", "-")])
	var mv = plan.get("move_to", null)
	if mv != null:
		# 用户口径（第 86 轮）：**移动结束后才能释放技能或普攻** ——
		# 所以这里一律等它走完（直升机也一样：看上去"边走边打"做不到，就不做）。
		await ai_move(u, mv)
		if not u.is_alive():
			_st._ai_turn = false
			_st._finish_turn()
			return
		plan = Ai.plan(ai_ctx(u))          # 位置变了，重新决策
		_st._log("  🤖 %s：%s" % [u.name, plan.get("note", "-")])
	match String(plan.get("action", "end")):
		"attack":
			ai_attack(u, plan)
		"skill":
			ai_skill(u, plan)
		"rest":
			_st.action_menu.menu_rest()
		"move":
			var mv2 = plan.get("move_to", null)
			if mv2 != null:
				await ai_move(u, mv2)
			_st._ai_turn = false
			_st._finish_turn()
			return
		_:
			_st._finish_turn()
	# 兜底：AI 回合如果既没结束也没在等弹道物，就强制收尾，绝不允许卡住
	if _st._ai_turn and _st.active == u and not u.has_acted and _st._pending_turn_end == false \
			and _st.field.items.is_empty():
		_st._log("  ⚠ AI 回合没有产生任何动作，强制结束")
		_st._finish_turn()
	_st._ai_turn = false


func ai_move(u: Unit, cell: Vector2i, wait: bool = true) -> void:
	if u == null or cell == u.cell:
		return
	_st._do_move(u, cell)
	if not wait:
		return
	var guard := 0.0
	while u.visual != null and u.visual.is_walking() and guard < 4.0:
		guard += 0.05
		await _st.get_tree().create_timer(0.05).timeout


func ai_attack(u: Unit, plan: Dictionary) -> void:
	var aim: Vector2 = plan.get("aim", _st._cc(u.cell))
	var t: Unit = plan.get("target", null)
	var pl: Placeable = plan.get("placeable", null)
	if t != null and not t.is_alive():
		t = null
	if pl != null and not pl.is_alive():
		pl = null
	if t == null and pl == null:
		_st._finish_turn()
		return
	if not _st.attack.perform_basic(u, aim, t, pl, bool(plan.get("break_armor", false))):
		_st._finish_turn()          # 精力不足/目标非法：也必须结束回合，否则软锁


func ai_skill(u: Unit, plan: Dictionary) -> void:
	var sid := String(plan.get("skill", ""))
	var aim: Vector2 = plan.get("aim", _st._cc(u.cell))
	var cell: Vector2i = plan.get("cell", Vector2i(int(floor(aim.x)), int(floor(aim.y))))
	if not _st.skills_mod.perform_skill(u, sid, aim, cell):
		_st._finish_turn()


func is_ai_unit(u: Unit) -> bool:
	if u == null or not u.has_turn():
		return false
	if u.side == UnitData.Side.ENEMY:
		return _st.ai_enabled or not u.controllable
	return _st.ai_autoplay_player


func fire_cannon_ai(u: Unit, ends_turn: bool = true) -> void:
	var foes: Array[Unit] = []
	for o in _st.units:
		if o.is_alive() and o.side != u.side:
			foes.append(o)
	if foes.is_empty():
		if ends_turn:
			_st._finish_turn()
		return
	var from := Vector2(float(u.cell.x) + 0.5, float(u.cell.y) + 0.5)
	var best := 1e9
	for o in foes:
		best = minf(best, from.distance_to(Vector2(o.cell)))
	var picks: Array[Unit] = []
	for o in foes:
		if absf(from.distance_to(Vector2(o.cell)) - best) < 0.001:
			picks.append(o)
	var t: Unit = picks[_st.rng.next_int(picks.size())]      # 并列最近 -> 随机
	var to := Vector2(float(t.cell.x) + 0.5, float(t.cell.y) + 0.5)
	var dir := to - from
	dir = dir.normalized() if dir.length() > 0.001 else Vector2.RIGHT
	# 射程 15：超出就只飞 15 格（打不到人，但照打 —— 用户口径"无论是否在射程内"）
	var reach: float = minf(from.distance_to(to), Ordnance.CANNON_RANGE)
	var land := from + dir * reach
	if u.visual != null:
		u.visual.rotation.y = atan2(dir.x, dir.y)        # 炮口转向目标（炮在身前 +Z）
	var muzzle := from + dir * 0.55
	spawn_cannon(u, Vector3(muzzle.x, 0.80, muzzle.y),
		Vector3(land.x, Targeting.aim_height(t), land.y), ends_turn)
	_st._log("  💣 %s 的加农炮瞄准最近的 %s（%.1f 格，射程 %.0f）：出膛" %
		[u.name, t.name, from.distance_to(to), reach])


func king_ball_in_flight(u: Unit) -> bool:
	for it in _st.field.items:
		var p: Projectile = it["p"]
		if p.kind == Projectile.KIND_CANNON and p.alive and p.owner_unit == u:
			return true
	return false


func spawn_cannon(caster: Unit, from: Vector3, to: Vector3, ends_turn: bool) -> Projectile:
	var p := Ordnance.make_cannon(caster, from, to, ends_turn)
	_st.field.register(p)
	return p


func gm_step() -> void:
	var due: Array[GameMaster.Pending] = _st.gm.dispatch_turn_boundary()
	if not _st.gm.pending.is_empty():
		_st._log("  [GM] 第 %d 次回合边界：%s" % [_st.gm.turn_count, _st.gm.pending_desc()])
	# 英雄重生：到点的满血放回"两公主之间"的固定格（用户口径：等 10 个回合）
	for u in _st.gm.due_revives():
		_st._revive_hero(u)
	# 老国王不进队列：由 GM 每 5 个回合边界替他打一炮（用户口径）
	if _st.gm.turn_count > 0 and _st.gm.turn_count % _st.KING_FIRE_TURNS == 0:
		for u in _st.units:
			if u.is_king and u.is_alive() and not king_ball_in_flight(u):
				_st._log("  [GM] 第 %d 次回合边界：老国王的加农炮到点" % _st.gm.turn_count)
				fire_cannon_ai(u, false)
	for p in due:
		if p.skill_id == "grenade":
			_st.sink.explode_grenade(p)
		if p.skill_id == "orbital_strike":
			_st._log("  [GM] ☄ %s 的轨道火力到点，暂停回合开始覆盖" % p.caster_name)
			_st._set_gm_busy(true)
			await _st.skills_mod.run_orbital_barrage(p)
			_st._set_gm_busy(false)

