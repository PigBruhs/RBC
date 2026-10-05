# 第 111 轮：**雷达车普攻能选到任意距离的敌人**（用户报的恶性 bug 的回归钉子）
#
# 用户口径：「**只有连接有距离限制，目标选择没有**」
# 实测 bug：雷达的数据行射程是 `0-0`（它没有武器），而普攻选目标走的是
#   `Targeting.attack_range_cells_rect`（按射程算）-> 可选集合**空** -> 一个目标都点不了。
# 本探针把"全场敌人可选 + 远到 90 格也能选 + 点了真的开始锁定"钉死。
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
	_run(s)
	quit(1 if _f > 0 else 0)


func _run(s: Node) -> void:
	var radar: Unit = null
	for u in s.units:
		if u != null and u.name == "雷达午餐盒":
			radar = u
			break
	_ok(radar != null, "找到雷达午餐盒")
	if radar == null:
		return
	_ok(AttackProfile.basic_of(radar) == AttackProfile.BASIC_LOCK,
		"雷达的普攻模板 = BASIC_LOCK（实际 %s）" % AttackProfile.basic_of(radar))
	_ok(radar.rng_max == 0, "雷达数据行射程确实是 0-0（这正是原来可选集合为空的原因）")

	# 把雷达与一个敌人放到**很远**（90 格），并确保我方其它单位都不在附近干扰
	var foe: Unit = null
	for u in s.units:
		if u != null and u.is_alive() and u.side != radar.side:
			foe = u
			break
	_ok(foe != null, "场上找到敌人")
	if foe == null:
		return
	s.active = radar
	radar.cell = Vector2i(2, 2)
	radar.visual.position = Vector3(2.5, radar.visual.position.y, 2.5)
	foe.cell = Vector2i(2, 2) + Vector2i(0, 90)     # 90 格外
	foe.visual.position = Vector3(float(foe.cell.x) + 0.5, foe.visual.position.y,
		float(foe.cell.y) + 0.5)
	var dist := GridMath.unit_pos(radar).distance_to(GridMath.unit_pos(foe))
	print("      雷达 @%s ｜ 敌人 @%s ｜ 距离 %.1f 格" % [str(radar.cell), str(foe.cell), dist])

	print("\n[1] 进入选目标阶段后，**全场敌人**都在可选集合里")
	s._aim_skill_id = ""
	s.action_menu.menu_attack()
	_ok(s.phase == s.Phase.CHOOSE_TARGET, "进入选目标阶段")
	var cells: Dictionary = s.t_attackable_cells()
	var enemies := 0
	for u in s.units:
		if u != null and u.is_alive() and u.side != radar.side:
			enemies += 1
	print("      可选格 %d ｜ 场上敌人 %d ｜ 含那个 90 格外的敌人 = %s" % [
		cells.size(), enemies, str(cells.has(foe.cell))])
	_ok(cells.size() > 0, "**可选集合非空**（原来这里是 0 -> 一个目标都点不了）")
	_ok(cells.has(foe.cell), "**90 格外的敌人也可选**（目标选择无距离限制）")

	print("\n[2] 真的点两下 -> 开始锁定（且按开始时的距离算回合数）")
	s.t_click_cell(foe.cell)
	s.t_click_cell(foe.cell)
	var st: Radar.State = s.t_radar_state("雷达午餐盒")
	_ok(st != null and st.lock_name == foe.name,
		"**两次点击后开始锁定 %s**（实际 %s）" % [foe.name, "-" if st == null else st.lock_name])
	if st != null and st.lock_name == foe.name:
		print("      需 %d 回合 ｜ lock_left = %d" % [st.lock_total, st.lock_left])
		_ok(st.lock_total == Radar.turns_for(dist),
			"回合数 = ceil(距离/20)（距离 %.1f -> %d）" % [dist, st.lock_total])

	print("\n[3] 对照组：**连接仍然有** 16 格距离限制（别把这条一起放开）")
	_ok(absf(float(Skills.get_def("radar_link")["range_max"]) - 16.0) < 0.001,
		"连接的距离上限仍是 16 格")

	print("\n── 雷达普攻选目标探针：%d 项检查，失败 %d 项 ──" % [_n, _f])
