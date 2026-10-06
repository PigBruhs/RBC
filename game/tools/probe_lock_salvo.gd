# 第 111 轮：**【锁定齐射】新模板**（用户口径）
#   「当检测到选择目标**被雷达锁定且自己连接到雷达**时，**无视射程限制**
#     （子弹飞不到无所谓，但一定要打出去）并用**新普攻模板**覆盖原本的甩头模板；
#     新普攻模板 20 格处散布 0.5 格，**不甩头**但是**只连发 3 波**」
#   用户报的两个症状：
#     · 仍然无法攻击**被雷达锁定的射程外**的目标
#     · 攻击**射程内**被雷达锁定的目标时走的仍然是**一般普攻**（甩头 12 波）
extends SceneTree

const LEVEL := "arena"

var _f := 0
var _n := 0


func _ok(c: bool, w: String) -> void:
	_n += 1
	if c:
		print("  PASS  ", w)
	else:
		_f += 1
		print("  FAIL  ", w)


func _initialize() -> void:
	Level.current = LEVEL
	var s: Node = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(s)
	for i in 8:
		await process_frame
	await _run(s)
	quit(1 if _f > 0 else 0)


func _run(s: Node) -> void:
	var cart: Unit = null
	var radar: Unit = null
	var foe: Unit = null
	for u in s.units:
		if u == null:
			continue
		if u.name == "轮式齐射午餐盒":
			cart = u
		if u.name == "雷达午餐盒":
			radar = u
		if foe == null and u.is_alive() and u.side != 0 and u.name != "雷达午餐盒":
			foe = u
	_ok(cart != null and radar != null and foe != null, "找到 车 / 雷达 / 敌人")
	if cart == null or radar == null or foe == null:
		return
	s.t_radar_add_link("雷达午餐盒", "轮式齐射午餐盒")
	s.t_radar_begin_lock("雷达午餐盒", foe.name)
	var rst: Radar.State = s.t_radar_state("雷达午餐盒")
	while not rst.locked():
		s._radar_on_turn_begin(radar)
	_ok(rst.locked(), "雷达已锁定 %s" % foe.name)

	# 把敌人放到 **56 格**（远超车的曼哈顿射程 24）
	cart.cell = Vector2i(10, 10)
	cart.visual.position = Vector3(10.5, cart.visual.position.y, 10.5)
	foe.cell = Vector2i(10, 66)
	foe.visual.position = Vector3(10.5, foe.visual.position.y, 66.5)
	var md: int = absi(cart.cell.x - foe.cell.x) + absi(cart.cell.y - foe.cell.y)
	print("      车 @%s ｜ 敌人 @%s ｜ 曼哈顿距离 %d（车射程 1-%d）" % [
		str(cart.cell), str(foe.cell), md, cart.rng_max])
	_ok(md > cart.rng_max, "**目标确实在射程外**（%d > %d）" % [md, cart.rng_max])

	print("\n[1] 射程外 + 被锁定 -> **第一次点击就有确认**（用户报点第一下没反应）")
	s.active = cart
	cart.has_acted = false
	s._aim_skill_id = ""
	s.action_menu.menu_attack()
	_ok(s.phase == s.Phase.CHOOSE_TARGET, "进入选目标阶段")
	_ok(s.t_attackable_cells().has(foe.cell), "**射程外的锁定目标在可选集合里**")
	_ok(s.can_aim_now(foe), "**`can_aim_unit` 放行**（原来被 `in_range_of` 拦掉）")
	s.t_click_cell(foe.cell)
	_ok(s.t_pending_kind() != "", "**点第一下出现待确认**（pending=%s）" % s.t_pending_kind())

	print("\n[2] 点第二下 -> 走的是【锁定齐射】：无视射程 / 3 波 / 不甩头")
	s.clear_projectiles()
	var logs_before: int = s.t_debug_log().size()
	s.t_click_cell(foe.cell)
	var g := 0
	while s._lb_salvo_busy() and g < 3000:
		await process_frame
		g += 1
	# 看日志：应当出现"锁定齐射"字样，且波数 = 3
	var logs: Array[String] = s.t_debug_log()
	var lock_line := ""
	for i in range(logs_before, logs.size()):
		if logs[i].find("锁定齐射") >= 0:
			lock_line = logs[i]
			break
	print("      日志：%s" % lock_line)
	_ok(lock_line != "", "**走的是【锁定齐射】模板**（不是一般普攻）")
	_ok(lock_line.find("无视射程") >= 0, "日志里明确标注**无视射程**")
	# 数波数
	var waves := 0
	for i in range(logs_before, logs.size()):
		if logs[i].find("齐射第") >= 0:
			waves += 1
	# ⚠ 口径已变更（用户原话）：「从 3 波调到 **12 波**」
	print("      出膛波数 = %d（新模板现应为 %d）" % [waves, 12])
	_ok(waves == 12, "**连发 12 波**（实际 %d）" % waves)

	print("\n[3] **不甩头**：3 波的 theta 必须完全相同")
	var thetas: Array[float] = []
	for i in range(logs_before, logs.size()):
		var ln: String = logs[i]
		if ln.find("齐射第") < 0:
			continue
		var k := ln.find("theta ")
		if k < 0:
			continue
		var seg := ln.substr(k + 6)
		var e := seg.find("°")
		if e > 0:
			thetas.append(float(seg.substr(0, e)))
	print("      3 波的 theta = %s" % str(thetas))
	if thetas.size() >= 2:
		var d := absf(thetas[0] - thetas[thetas.size() - 1])
		_ok(d < 0.01, "**不甩头：3 波中轴完全相同**（首尾差 %.3f°）" % d)

	print("\n[4] 没被锁定 / 没连接时：**仍然走一般普攻**（12 波，且射程外选不中）")
	Radar.clear_lock(rst)
	if rst.links.has("轮式齐射午餐盒"):
		rst.links.erase("轮式齐射午餐盒")
	cart.has_acted = false
	s.active = cart
	s._aim_skill_id = ""
	s.action_menu.menu_attack()
	_ok(not s.t_attackable_cells().has(foe.cell),
		"**没锁定 -> 射程外的目标不在可选集合里**（恢复原状）")

	print("\n── 锁定齐射模板探针：%d 项检查，失败 %d 项 ──" % [_n, _f])
