# 午餐盒「点选目标」探针（第 105 轮用户口径）
#
# 用户原话：
#   「**一定要做选择目标而不是瞄准！我不明白难点在哪，你之前弓箭手不都是点选敌人瞄准的吗？**
#     **车普攻和巡飞弹都要点选目标瞄准！**」
#
# ⚠ 这个探针**必须走真实点击路径**（`t_click_cell` = 鼠标左键点击那一段代码），
#   不能直接调底层 `perform_skill` —— 上一轮的教训就是"只测底层函数、没测 UI 输入路径"，
#   结果用户一点就发现巡飞弹放不出来。
#
# 运行： exe --headless --path game --script res://tools/probe_unit_target.gd --quit-after 90000
extends SceneTree

var _s: Node
var _fails: Array[String] = []
var _checks := 0


func _chk(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("  PASS  ", label)
	else:
		print("  FAIL  ", label)
		_fails.append(label)


func _cart() -> Unit:
	for u in _s.units:
		if Unit.base_name(u.name) == "轮式齐射午餐盒" and u.side == UnitData.Side.PLAYER:
			return u
	return null


func _foe() -> Unit:
	var c := _cart()
	if c == null:
		return null
	for u in _s.units:
		if u != null and u.is_alive() and u.side != c.side:
			return u
	return null


func _initialize() -> void:
	Level.current = "arena"
	_s = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(_s)
	for i in 12:
		await process_frame

	var cart := _cart()
	_chk(cart != null, "竞技场里找得到轮式齐射午餐盒（玩家侧）")
	if cart == null:
		_finish()
		return

	print("\n[1] 车的**普攻**是点选目标（不是拖拽）")
	var aim_kind := AttackProfile.aim_of(cart)
	print("      车的普攻 aim = %s（AIM_TARGET = %s）" % [aim_kind, AttackProfile.AIM_TARGET])
	_chk(aim_kind == AttackProfile.AIM_TARGET, "车的普攻 aim = target（点选敌人）")
	# 直升机必须**仍然是拖拽**（车与它共用 BASIC_SALVO 模板，别改坏了）
	var heli: Unit = null
	for u in _s.units:
		if u.name.begins_with(AttackProfile.HELI_PREFIX) and u.side == UnitData.Side.PLAYER:
			heli = u
			break
	if heli != null:
		var h_aim := AttackProfile.aim_of(heli)
		print("      直升机普攻 aim = %s" % h_aim)
		_chk(h_aim == AttackProfile.AIM_DRAG, "直升机**仍然是拖拽**（共用模板但交互没被带坏）")

	print("\n[2] 巡飞弹技能 = 点选目标（AIM_UNIT）")
	_chk(Skills.aim_of("loiter_launch") == Skills.AIM_UNIT,
		"loiter_launch 的 aim = unit（点选敌方角色）")
	_chk(Skills.skills_for(cart).has("loiter_launch"), "车身上挂着巡飞弹技能")

	print("\n[3] ★ 真实点击路径：选技能 -> 点敌人 -> 巡飞弹真的放出去 + 扣 12 精力 + 结束回合")
	cart.energy = cart.energy_max
	cart.has_acted = false
	cart.has_moved = false
	_s.active = cart
	_s.phase = _s.Phase.MENU
	var foe := _foe()
	_chk(foe != null, "场上找得到敌方目标")
	if foe != null:
		# 让目标在 64 格内（技能射程，第 111 轮由 32 提到 64），并且**落在可到达区内**
		var cand := cart.cell + Vector2i(0, 6)
		if not Level.in_play(cand, "arena"):
			cand = cart.cell + Vector2i(0, -6)
		foe.cell = cand
		foe.home_cell = foe.cell
		if foe.visual != null:
			foe.visual.position = Vector3(float(foe.cell.x) + 0.5, foe.visual.position.y, float(foe.cell.y) + 0.5)
		await process_frame
		var d := GridMath.unit_pos(cart).distance_to(GridMath.unit_pos(foe))
		print("      目标 %s @ %s 距车 %.1f 格（技能射程 64）" % [foe.name, str(foe.cell), d])
		var e0 := cart.energy_points()
		var n0 := _count_loiter()
		# ① 选技能（走真实入口）
		_s.t_choose_skill("loiter_launch")
		await process_frame
		print("      选技能后 phase = %s ｜ 可选目标格数 = %d" % [
			_s.phase, _s.t_attackable_cells().size()])
		_chk(_s.phase == _s.Phase.CHOOSE_TARGET, "进入『选目标』阶段（不是拖拽的 AIMING）")
		_chk(_s.t_attackable_cells().has(foe.cell), "目标所在格被高亮为可选")
		# ② 点敌人两次（第一次黄勾确认，第二次施放）—— 走**鼠标点击**那段代码
		_s.t_click_cell(foe.cell)
		await process_frame
		print("      第一次点：在飞巡飞弹 = %d（应仍为 %d，只是确认）" % [_count_loiter(), n0])
		_chk(_count_loiter() == n0, "第一次点只做确认，**还没**放出去")
		_s.t_click_cell(foe.cell)
		# ⚠ 第二次点之后**立刻**读一次（不 await）：如果"当帧有、下一帧没了"，
		#   说明子弹被生成后马上被回收（引信/落地/收尾），而不是"没生成"。
		var n_immediate := _count_loiter()
		var items_immediate: int = _s.field.items.size()
		print("      第二次点（当帧）：在飞巡飞弹 = %d ｜ field.items = %d" % [n_immediate, items_immediate])
		# 记住它，下一帧看它是**被什么原因回收**的（kill 会记 removed_reason）
		var spawned: Projectile = null
		for it in _s.field.items:
			var pp: Projectile = it["p"]
			if pp.kind == Projectile.KIND_LOITER:
				spawned = pp
		if spawned != null:
			print("      生成的巡飞弹：from=%s to=%s 存活=%s" % [
				str(spawned.from), str(spawned.to), spawned.alive])
		await process_frame
		if spawned != null:
			print("      下一帧：存活=%s ｜ removed_reason='%s' ｜ removed_at=%s ｜ pos=%s" % [
				spawned.alive, spawned.removed_reason, str(spawned.removed_at), str(spawned.pos())])
		var n1 := _count_loiter()
		var e1 := cart.energy_points()
		print("      第二次点：在飞巡飞弹 %d -> %d ｜ field.items 总数 %d ｜ 精力 %d -> %d ｜ has_acted = %s" % [
			n0, n1, _s.field.items.size(), e0, e1, cart.has_acted])
		# 把 field 里所有弹道物的 kind 打出来（定位"到底放出去没有"）
		var kinds: Array = []
		for it in _s.field.items:
			kinds.append((it["p"] as Projectile).kind)
		print("      field 里的弹种 = %s" % str(kinds))
		_chk(n1 > n0, "★ 巡飞弹**真的放出去了**（这就是用户报的『无法召唤巡飞弹』）")
		_chk(e1 == e0 - 12, "★ 精力**真的扣了 12**（%d -> %d）" % [e0, e1])
		_chk(cart.has_acted, "★ 施放后**真的结束回合**（has_acted = true）")

	print("\n[4] 反向对照：目标超出 64 格 -> 不给选、也不许悄悄扣精力")
	_s.clear_projectiles()
	cart.energy = cart.energy_max
	cart.has_acted = false
	_s.phase = _s.Phase.MENU
	_s.active = cart
	var far := _foe()
	if far != null:
		# ⚠ 第 111 轮：巡飞弹射程 32 -> **64**，所以"超程"要放到 64 之外
		far.cell = cart.cell + Vector2i(0, 70)          # 70 格 > 64
		far.home_cell = far.cell
		if far.visual != null:
			far.visual.position = Vector3(float(far.cell.x) + 0.5, far.visual.position.y, float(far.cell.y) + 0.5)
		await process_frame
		var dfar := GridMath.unit_pos(cart).distance_to(GridMath.unit_pos(far))
		print("      目标 @ %s 距车 %.1f 格（要求 > 64）" % [str(far.cell), dfar])
		_chk(dfar > 64.0, "构造出来的目标确实超出 64 格（%.1f）" % dfar)
		var e0b := cart.energy_points()
		var n0b := _count_loiter()
		_s.t_choose_skill("loiter_launch")
		await process_frame
		var highlighted: bool = _s.t_attackable_cells().has(far.cell)
		print("      远超目标是否被高亮 = %s" % highlighted)
		_chk(not highlighted, "超出 64 格的目标**不被高亮**（选不了）")
		_s.t_click_cell(far.cell)
		_s.t_click_cell(far.cell)
		await process_frame
		_chk(_count_loiter() == n0b, "点超程目标**不会**放出巡飞弹")
		_chk(cart.energy_points() == e0b, "点超程目标**不会**扣精力（不能悄悄扣）")

	print("\n[5] 车的普攻：走真实点击路径点敌人 = 开打")
	cart.energy = cart.energy_max
	cart.has_acted = false
	cart.has_moved = false
	cart.tags.erase("diving")
	_s.phase = _s.Phase.MENU
	_s.active = cart
	var tgt := _foe()
	if tgt != null:
		tgt.cell = cart.cell + Vector2i(0, 5)
		if tgt.visual != null:
			tgt.visual.position = Vector3(float(tgt.cell.x) + 0.5, tgt.visual.position.y, float(tgt.cell.y) + 0.5)
		await process_frame
		# ⚠ 第 107 轮用户口径：车的普攻**不再弹"打力量 / 破甲"三级菜单** ——
		#   它的普攻是**齐射**，`armor_break = 0` 使菜单里"破甲"那条对它是死的
		#   （实测点了毫无反应），所以第二次点敌人**直接开打**。
		#   这条断言因此从"必须弹菜单"改成"**必须不弹菜单、且真的开打**"。
		_s.t_menu_attack()
		await process_frame
		print("      普攻选目标阶段 phase = %s ｜ 可选格数 = %d" % [
			_s.phase, _s.t_attackable_cells().size()])
		_chk(_s.t_attackable_cells().has(tgt.cell), "普攻阶段目标格被高亮")
		_s.t_click_cell(tgt.cell)
		await process_frame
		_chk(_s.t_pending_kind() == "attack", "第一次点敌人 -> 出黄勾待确认（pending = attack）")
		_chk(not _s.t_attack_menu().visible, "第一次点**还没**弹攻击菜单（两次确认没被绕过）")
		_s.t_click_cell(tgt.cell)
		await process_frame
		var am: PanelContainer = _s.t_attack_menu()
		print("      点两下后：攻击菜单可见 = %s ｜ has_acted = %s" % [
			am != null and am.visible, cart.has_acted])
		_chk(am == null or not am.visible,
			"★ 车普攻**不弹**力量/破甲三级菜单（用户第 107 轮：那个菜单对车是死的）")
		_chk(cart.has_acted, "★ 点两下敌人后**真的开始普攻**（has_acted = true）")

	print("\n[3b] 隔离：直接调底层 launch_loiter_skill，看断点在底层还是 UI 层")
	cart.energy = cart.energy_max
	cart.has_acted = false
	_s.phase = _s.Phase.MENU
	_s.active = cart
	var foe2 := _foe()
	if foe2 != null:
		var fpos := GridMath.unit_pos(foe2)
		var ok2: bool = _s.air.launch_loiter_skill(cart, fpos)
		print("      launch_loiter_skill 返回 = %s ｜ field.items = %d ｜ 在飞巡飞弹 = %d" % [
			ok2, _s.field.items.size(), _count_loiter()])
		_chk(ok2, "底层 launch_loiter_skill 返回 true")
		_chk(_count_loiter() >= 1, "底层调用后场上**至少有一枚**在飞巡飞弹")

	_finish()


func _count_loiter() -> int:
	var n := 0
	# ⚠ `field.items` 里装的是 `{"p": Projectile, "node": ..., "prev": ...}` 字典，不是 Projectile 本身
	for it in _s.field.items:
		var p: Projectile = it["p"]
		if p.alive and p.kind == Projectile.KIND_LOITER:
			n += 1
	return n


func _count_bullets() -> int:
	var n := 0
	for it in _s.field.items:
		var p: Projectile = it["p"]
		if p.alive and (p.kind == Projectile.KIND_CART_BULLET or p.kind == Projectile.KIND_BULLET):
			n += 1
	return n


func _finish() -> void:
	print("\n── 午餐盒点选目标探针：%d 项检查，失败 %d 项 ──" % [_checks, _fails.size()])
	for f in _fails:
		print("   - ", f)
	quit(1 if _fails.size() > 0 else 0)