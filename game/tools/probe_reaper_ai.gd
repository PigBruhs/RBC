# ══════════════════════════════════════════════════════════════════════════════
# Reaper AI 探针（Boss-3）：三循环 / 前移一格 / 召唤 / 6 格被动 / 红环预警
# 运行: godot --headless --path game --script res://tools/probe_reaper_ai.gd --quit-after 60000
# ══════════════════════════════════════════════════════════════════════════════
extends SceneTree

var _s: Node
var _checks := 0
var _fails: Array[String] = []


func _chk(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("  PASS  %s" % label)
	else:
		print("  FAIL  %s" % label)
		_fails.append(label)


## 出回合前把宿主状态摆正（探针是"带外"驱动回合，必须自己复位 active / 幂等标记）
func _prep(rp: Unit) -> void:
	_s.active = rp
	_s._turn_just_finished = null
	rp.has_acted = false
	rp.has_moved = false


## 把单位拉回满血（探针要它活着当靶子）
func _revive(u: Unit) -> void:
	u.power_cur = u.power_max
	u.armor_cur = u.armor_max
	if u.visual != null:
		u.visual.visible = true


func _initialize() -> void:
	await process_frame
	_s = load("res://src/view/battle_scene.tscn").instantiate()
	root.add_child(_s)
	await process_frame
	await process_frame
	print("\n── Reaper AI 探针 ──")

	var units: Array = _s.units
	var rp: Unit = null
	for u in units:
		if _s.gm.is_reaper(u) and u.is_alive():
			rp = u
			break
	# 关卡 roster 里还没有 Reaper（level.gd 不在本任务写区）-> 探针自己按花名册造一个
	if rp == null:
		var def := {}
		for arr in [UnitData.UNITS, UnitData.ENEMIES]:
			for d in arr:
				if String(d["name"]) == "Reaper":
					def = d
		if def.is_empty():
			_chk(false, "UnitData 里应有 Reaper 数据行")
			_finish()
			return
		rp = Unit.from_data(def)
		rp.side = UnitData.Side.ENEMY
		rp.cell = Vector2i(10, 20)
		rp.home_cell = rp.cell
		units.append(rp)
		var vis := UnitVisual.new()
		_s.add_child(vis)
		vis.setup(rp)
		print("      （探针自建 Reaper：关卡 roster 尚未收录它）")
	_chk(rp != null, "场上应有一个 Reaper")
	if rp == null:
		_finish()
		return

	# 清场：只留 Reaper + 一个敌方靶子（保证确定性）
	var foe: Unit = null
	for u in units:
		if u == rp:
			continue
		if u.side != rp.side and foe == null:
			foe = u
		else:
			u.power_cur = 0
	rp.power_cur = rp.power_max
	rp.armor_cur = rp.armor_max
	_s.gm.clear_all_sentries()
	_s.ai_enabled = false
	rp.cell = Vector2i(10, 20)
	if rp.visual != null:
		rp.visual.position = Vector3(10.5, rp.visual.position.y, 20.5)
	foe.cell = Vector2i(10, 26)               # 正下方 6 格
	foe.power_cur = foe.power_max
	foe.armor_cur = foe.armor_max
	if foe.visual != null:
		foe.visual.position = Vector3(10.5, foe.visual.position.y, 26.5)

	# ── ① 三循环顺序 ──
	print("\n[1] 三循环顺序")
	var seq: Array = []
	for i in 4:
		var before: int = _s.t_reaper_step(rp)
		seq.append(before)
		await _s.t_reaper_take_turn(rp)
		# 每回合结束会把 active 让出去，这里手动复位以便连跑
		_prep(rp)
	print("      循环步序列 = %s（0=召唤 1=横扫 2=竖切）" % str(seq))
	_chk(seq == [0, 1, 2, 0], "连续四回合的循环步应为 召唤→横扫→竖切→召唤")

	# ── ② 每回合前移一格 ──
	print("\n[2] 每回合向前移动一格")
	var c0: Vector2i = rp.cell
	rp.cell = Vector2i(10, 20)
	foe.cell = Vector2i(10, 26)
	var mv: Dictionary = Reaper.plan_forward(rp, units)
	print("      从 (10,20) 朝敌人 (10,26) 计划落点 = %s（moved=%s）" % [str(mv["cell"]), mv["moved"]])
	_chk(bool(mv["moved"]) and Vector2i(mv["cell"]) == Vector2i(10, 21),
		"朝最近敌人方向应前进 1 格（10,20)->(10,21）")
	# 被占：把敌人堵到正前方
	var blocker: Unit = foe
	blocker.cell = Vector2i(10, 21)
	var mv2: Dictionary = Reaper.plan_forward(rp, units)
	_chk(not bool(mv2["moved"]) and Vector2i(mv2["cell"]) == Vector2i(10, 20),
		"前方格被占时停在原地（body_r=3 不硬挤）")
	print("      被占原因 = %s" % String(mv2["blocked"]))
	blocker.cell = Vector2i(10, 26)

	# ── ③ 召唤回合：3 个单位、敌方阵营、靠 Reaper 近 ──
	print("\n[3] 召唤回合")
	var n0: int = units.size()
	# 强制下一步是召唤
	_s.gm.reaper_cycle[rp.name] = Reaper.Step.SUMMON
	_prep(rp)
	await _s.t_reaper_take_turn(rp)
	_prep(rp)
	var born: Array = []
	for u in units:
		if u != rp and u.side == rp.side and u.has_turn():
			born.append(u)
	print("      召唤后同阵营可行动单位 = %d 个" % born.size())
	_chk(units.size() == n0 + 3, "召唤回合应新增 3 个单位（%d -> %d）" % [n0, units.size()])
	var near_ok := true
	var side_ok := true
	for i in range(n0, units.size()):
		var s: Unit = units[i]
		if s.side != rp.side:
			side_ok = false
		if GridMath.unit_pos(s).distance_to(GridMath.unit_pos(rp)) > 12.0:
			near_ok = false
	_chk(side_ok, "召唤物都是敌方阵营")
	_chk(near_ok, "召唤物都落在 Reaper 附近（≤12 格）")

	# ── ④ 6 格范围被动 ──
	print("\n[4] 6 格范围被动（每个回合边界一次）")
	var near5: Unit = null
	var far7: Unit = null
	for u in units:
		if u.side != rp.side and u != rp:
			_revive(u)                      # 先保证它是活的（前面的激光可能把它打死了）
			if near5 == null:
				near5 = u
			elif far7 == null:
				far7 = u
	if near5 == null or far7 == null:
		_chk(false, "需要两个敌方单位来测 6 格被动")
	else:
		rp.cell = Vector2i(10, 20)
		if rp.visual != null:
			rp.visual.position = Vector3(10.5, rp.visual.position.y, 20.5)
		near5.cell = Vector2i(10, 25)          # 中心距离 5
		if near5.visual != null:
			near5.visual.position = Vector3(10.5, near5.visual.position.y, 25.5)
		far7.cell = Vector2i(10, 27)           # 中心距离 7
		if far7.visual != null:
			far7.visual.position = Vector3(10.5, far7.visual.position.y, 27.5)
		near5.armor_cur = near5.armor_max
		near5.power_cur = near5.power_max
		far7.armor_cur = far7.armor_max
		far7.power_cur = far7.power_max
		var a0: int = near5.armor_cur
		var p0: int = near5.power_cur
		var a1: int = far7.armor_cur
		var p1: int = far7.power_cur
		_s.t_reaper_passive_tick()
		print("      5 格处：护甲 %d->%d，力量 %d->%d" % [a0 / 1000, near5.armor_cur / 1000,
			p0 / 1000, near5.power_cur / 1000])
		print("      7 格处：护甲 %d->%d，力量 %d->%d" % [a1 / 1000, far7.armor_cur / 1000,
			p1 / 1000, far7.power_cur / 1000])
		# 护甲段是**确定值**（直接打护甲池）：20 点
		_chk(a0 - near5.armor_cur == Reaper.PASSIVE_ARMOR_MILLI, "5 格内应掉 20 点护甲")
		# ⚠ 力量段是**物理力量线**（第 100 轮用户口径「6格被动是物理伤害」）：
		#   先减护甲、再过物抗、**有命中判定** —— 所以它合法地可能是 0（ROLL 未命中）。
		#   断言"必扣 10"是错的（那是旧的魔法伤害口径）。
		#   这里断言：掉血量 ∈ {0, 命中后的期望值}，且**绝不超过**名义值 10 点。
		var pw_drop: int = p0 - near5.power_cur
		var expect_hit: int = Rules.points_to_milli(int(floor(10.0 * (1000 - near5.pr) / 1000.0)))
		_chk(pw_drop == 0 or pw_drop == expect_hit,
			"5 格内力量掉 0（未命中）或 %d（命中后过物抗 %d‰），实际 %d" % [
				expect_hit / 1000, near5.pr, pw_drop / 1000])
		_chk(pw_drop <= Reaper.PASSIVE_POWER_POINTS * 1000,
			"力量掉血不超过名义值 10 点（实际 %d）" % (pw_drop / 1000))
		_chk(far7.armor_cur == a1, "7 格外不该掉护甲")
		_chk(far7.power_cur == p1, "7 格外不该掉力量")

	# ── ⑤ 红环预警 + 真的"发"了光束（打桩期看日志）──
	print("\n[5] 激光预警（红环 2 秒 -> 发激光 -> 回蓝）")
	for u in units:
		if u.side != rp.side and u != rp:
			_revive(u)
			break
	_s.t_reaper_clear_laser_log()
	_s.t_reaper_reset_saw_red()
	_s.gm.reaper_cycle[rp.name] = Reaper.Step.SWEEP
	_prep(rp)
	await _s.t_reaper_take_turn(rp)
	var log_: Array = _s.t_reaper_laser_log()
	print("      光束条数 = %d ｜ 环色 = %s ｜ 进过红环 = %s" % [
		log_.size(), str(_s.t_reaper_ring_color_of(rp)), str(_s.t_reaper_saw_red())])
	_chk(_s.t_reaper_saw_red(), "发激光前必须先红环预警")
	_chk(not log_.is_empty(), "横扫回合应产出光束（打桩期记在 _reaper_laser_log）")
	_chk(_s.t_reaper_ring_color_of(rp) == _s.REAPER_RING_IDLE, "结束后环应变回蓝色")
	if not log_.is_empty():
		var sp: Dictionary = log_[0]
		print("      首条光束：from=%s to=%s 距离=%.1f 帧=%d 伤害=%d‰" % [
			str(sp["from"]), str(sp["to"]), sp["dist"], sp["frames"], sp["dmg_milli"]])
		# 口径（用户原话 + Lead 确认）：**起点离地 6 格、末端落到目标身上** = 斜光束
		_chk(absf(float(sp["from"].y) - Reaper.BASE_HEIGHT) < 0.01,
			"起点在 Reaper 蓝环（离地 6 格）")
		_chk(absf(float(sp["to"].y) - Targeting.aim_height(Reaper.nearest_enemy(rp, units))) < 0.01,
			"末端落在目标身体高度（斜射，不是水平线）")
		# "越远格数越多、每格伤害越低"：同一角度下比较 6 格与 12 格
		var d6 := Reaper.cell_damage_milli(6.0, 120.0, 120.0)
		var d12 := Reaper.cell_damage_milli(12.0, 120.0, 120.0)
		print("      每格伤害：6 格处 %d‰ ｜ 12 格处 %d‰" % [d6, d12])
		_chk(d6 > d12, "距离越远每格被覆盖的帧数越少 -> 每格伤害越低")

	_finish()


func _finish() -> void:
	print("\n── Reaper AI 探针：%d 项检查，失败 %d 项 ──" % [_checks, _fails.size()])
	if _fails.is_empty():
		print("✅ Reaper 三循环 + 6 格被动链路通过")
	quit(1 if _fails.size() > 0 else 0)
