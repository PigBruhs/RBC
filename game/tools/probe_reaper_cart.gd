# 第 111 轮：**Reaper 关里齐射车普攻点不动**（用户报：点第一下都没反应，连确认都没有）
#   用户口径：脚底下有紫框，射程内和被雷达锁定的射程外的都不能选。
# 本探针在 **reaper** 关复现：进普攻选目标阶段 -> 找一个射程内敌人 -> 点它，看有没有黄勾。
extends SceneTree

const LEVEL := "reaper"

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
	var cart: Unit = null
	for u in s.units:
		if u != null and u.name == "轮式齐射午餐盒":
			cart = u
			break
	_ok(cart != null, "**reaper 关里有齐射车**")
	if cart == null:
		return
	print("      车 @%s ｜ rng %d-%d ｜ 场上单位 %d" % [
		str(cart.cell), cart.rng_min, cart.rng_max, s.units.size()])
	# 逐个列出敌方单位及距离，看看有没有射程内的
	var foes: Array[Unit] = []
	for u in s.units:
		if u != null and u.is_alive() and u.side != cart.side:
			foes.append(u)
	print("      敌方单位 %d 个：" % foes.size())
	for e in foes:
		print("        %s @%s 距离 %.1f" % [e.name, str(e.cell),
			GridMath.unit_pos(cart).distance_to(GridMath.unit_pos(e))])
	_ok(not foes.is_empty(), "场上有敌人")

	s.active = cart
	cart.has_acted = false
	cart.has_moved = false
	s._aim_skill_id = ""
	print("\n[1] 进普攻选目标阶段")
	s.action_menu.menu_attack()
	_ok(s.phase == s.Phase.CHOOSE_TARGET, "进入选目标阶段（phase=%s）" % str(s.phase))
	var cells: Dictionary = s.t_attackable_cells()
	print("      可选格 = %d" % cells.size())
	_ok(cells.size() > 0, "**可选集合非空**")

	# 找一个"射程内的敌人"（曼哈顿 1..24）
	var near: Unit = null
	for e in foes:
		var d: int = absi(cart.cell.x - e.cell.x) + absi(cart.cell.y - e.cell.y)
		if d >= 1 and d <= cart.rng_max:
			near = e
			break
	if near != null:
		print("\n[2] 点一个**射程内**的敌人 %s @%s" % [near.name, str(near.cell)])
		var occ: Unit = s.t_unit_at(near.cell)
		print("      `_unit_at(那一格)` 返回：%s（side=%d）" % [
			"—" if occ == null else occ.name, -1 if occ == null else occ.side])
		_ok(occ == near, "**那一格上取到的就是它**（不是被别的单位占了）")
		_ok(cells.has(near.cell), "它的格子在可选集合里")
		s.t_click_cell(near.cell)
		var pend: bool = s.t_pending_kind() != ""
		print("      点第一下后：pending = %s" % str(pend))
		_ok(pend, "**点第一下有反应（出现确认）**")
		s.t_click_cell(near.cell)
		print("      点第二下后：has_acted = %s" % str(cart.has_acted))
		_ok(cart.has_acted, "**点两下真的开打**")
	else:
		print("\n[2] 射程内没有敌人（那用户说'射程内的也不能选'就无从复现）")

	print("\n[3] 被锁定但超射程的目标也要能选")
	var radar: Unit = null
	for u in s.units:
		if u != null and u.name == "雷达午餐盒":
			radar = u
	_ok(radar != null, "**reaper 关里有雷达车**")
	if radar != null and not foes.is_empty():
		s.t_radar_add_link("雷达午餐盒", "轮式齐射午餐盒")
		s.t_radar_begin_lock("雷达午餐盒", foes[0].name)
		var rst: Radar.State = s.t_radar_state("雷达午餐盒")
		while not rst.locked():
			s._radar_on_turn_begin(radar)
		cart.has_acted = false
		s.active = cart
		s._aim_skill_id = ""
		s.action_menu.menu_attack()
		var c2: Dictionary = s.t_attackable_cells()
		print("      锁定 %s ｜ 可选格 = %d ｜ 含锁定目标 = %s" % [
			foes[0].name, c2.size(), str(c2.has(foes[0].cell))])
		_ok(c2.has(foes[0].cell), "**被雷达锁定的目标在可选集合里**")

	print("\n── Reaper 关车普攻探针：%d 项检查，失败 %d 项 ──" % [_n, _f])
