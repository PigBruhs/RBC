# ══════════════════════════════════════════════════════════════════════════════
# 技能编排：唯一入口 perform_skill + 各技能的实现与演出
#
# 职责边界：
#   · 技能表与数值来自 core/skills.gd；伤害结算走 core 的 Damage/Combat
#   · 这里只做"技能这一块的编排与演出"：菜单、选目标、扣精力、光柱、地毯轰炸、俯冲、待确认格子
#   · 宿主状态一律走 _st.xxx（显式路径），与 sentry_runner / projectile_sink / view_fx 同一形态
#
# **唯一出口**（规格 §14.3）：perform_skill 是玩家与 AI 共用的唯一入口；
# 扣精力只发生一次 —— carpet 由 start_carpet_bomb 自己扣，入口不再重复扣。
#
# 宿主是 battle_scene（Node3D）。_st 故意用**动态类型**：写 `: Node3D` 会编译不过
# （宿主成员不在 Node3D 上），见 sentry_runner.gd 的同样注释。
# ══════════════════════════════════════════════════════════════════════════════
class_name SkillRunner
extends RefCounted

var _st = null                 # 宿主（battle_scene）；动态类型见文件头


func _init(host: Node3D) -> void:
	_st = host

func menu_skill() -> void:
	if _st.active == null:
		return
	var ids := Skills.skills_for(_st.active)
	if ids.is_empty():
		pass
		return
	if ids.size() == 1:
		choose_skill(ids[0])
		return
	# 多技能：先把「行动」菜单收起来，再弹技能列表（否则两层菜单会叠在一起）
	_st._hide_action_menu()
	# ui_open_skill_menu 随 ActionMenu 一起搬走了 —— 跨模块调用要指向新家
	_st.action_menu.ui_open_skill_menu(ids)




## 真正进入某个技能的瞄准。走哪条流程由 Skills.aim_of(id) 决定（数据驱动）：
##   self  -> 点一下就用（哨兵） ｜ cell -> 直接点一格（俯冲轰炸） ｜ drag -> 拖拽瞄准
func choose_skill(id: String) -> void:
	if _st.active == null:
		return
	var d := Skills.get_def(id)
	if d.is_empty():
		return
	if _st.active.energy_points() < int(d["cost"]):
		return
	_st._action_menu.visible = false
	if _st._skill_menu != null:
		_st._skill_menu.visible = false
	match Skills.aim_of(id):
		Skills.AIM_SELF:
			_st._aim_skill_id = ""
			_st._skill_info_text = ""
			perform_skill(_st.active, id, _st._cc(_st.active.cell), _st.active.cell)
		Skills.AIM_CELL:
			# 用户口径：俯冲轰炸是【直接点 0~20 格内的一个格子】，不是拖拽瞄准，也不用标记球；
			# 第 84 轮：可选格用【粉色高亮】画出来，而且要两次点击确认（第一次出黄勾）
			_st._aim_skill_id = id
			_st._cell_targeting = true
			_st.phase = _st.Phase.CHOOSE_TARGET
			_st._skill_info_text = Skills.detail_text(id)
			_st.cell_targets = Targeting.disc_cells(_st._cc(_st.active.cell),
				float(d.get("range_max", 20.0)), _st.PW, _st.PH, _st.PX, _st.PY)
			_st.fx.clear_hints()
			_st.fx.draw_hints()
			_st._refresh_all()
			_st._log("  🎯 选择【%s】目标：%d 格内共 %d 个可选格（粉色高亮）" % [
				d["name"], int(d.get("range_max", 20.0)), _st.cell_targets.size()])
		_:
			_st._aim_skill_id = id
			_st._begin_aim()
			# 用户要求：瞄准时下方属性栏写技能名、描述与数值
			_st._skill_info_text = Skills.detail_text(id)
			_st._refresh_detail()




func cast_sentry(caster: Unit) -> void:
	var d := Skills.get_def("sentry")
	if caster == null or not caster.is_alive():
		return
	if caster.energy_points() < int(d["cost"]):
		_st._show_action_menu()
		if _st._ai_turn:
			_st._finish_turn()                   # AI 没有菜单可点，必须自己收尾
		return
	caster.spend_energy(int(d["cost"]))
	caster.has_acted = true
	caster.has_moved = true
	_st._push_unit_stats(caster)
	var s: GameMaster.Sentry = _st.gm.add_sentry(caster, int(d["range_min"]), int(d["range_max"]))
	_st._log("%s 进入【哨兵】状态：射界 %d~%d 格，精力 -%d（剩余 %d），持续到自己的下一个回合" % [
		caster.name, s.rng_min, s.rng_max, int(d["cost"]), caster.energy_points()])
	_st._log("  🎯 GM 已登记警戒：%s" % _st.gm.sentry_desc())
	_st._finish_turn()




## 【唯一】技能施放入口。返回 false = 没施放（精力不够 / 目标非法）。
func perform_skill(u: Unit, sid: String, aim: Vector2, cell: Vector2i) -> bool:
	var d := Skills.get_def(sid)
	if d.is_empty() or u == null or not u.is_alive():
		return false
	if u.energy_points() < int(d["cost"]):
		return false                             # 拒绝类文案不写日志（用户口径：只留在状态栏/菜单）
	match Skills.cast_of(sid):
		Skills.CAST_SENTRY:
			cast_sentry(u)                      # 自己扣精力 + 结束回合
			return true
		Skills.CAST_DIVE:
			if not _st._in_bounds(cell):
				return false
			cast_dive(u, cell)                  # 自己扣精力；下次轮到自己才俯冲
			_st._finish_turn()
			return true
		Skills.CAST_CARPET:
			# 注意：_start_carpet_bomb 自己扣精力 + 标记已行动（它也会被单独调用），
			# 这里**不能再 _commit_skill**，否则一次技能扣两份精力。
			start_carpet_bomb(u, aim)
			return true
		Skills.CAST_GRENADE:
			commit_skill(u, sid)
			spawn_grenade_shot(u, aim, sid)
			return true
		Skills.CAST_MARKER:
			commit_skill(u, sid)
			var md: float = _st._cc(u.cell).distance_to(aim)
			_st._log("%s 投出【%s】召唤球，落点 (%d, %d)，距离 %.1f 格，飞行 %.2f 秒" % [
				u.name, d["name"], cell.x, cell.y, md, md / Ordnance.SHELL_TILES_PER_SEC])
			_st.sink.spawn_marker(u, aim)                # 落地后由 _fire_skill_at 登记 GM 计时
			return true
		Skills.CAST_LOITER:
			# 第 104 轮：轮式齐射午餐盒的巡飞弹（耗 12 精力）。
			# 放出去了才扣精力 + 结束回合；没放出（无目标/超距）就当没施放。
			if not _st.air.launch_loiter_skill(u, aim):
				return false
			commit_skill(u, sid)
			_st._finish_turn()
			return true
	push_error("未知技能施放方式：%s（%s）" % [Skills.cast_of(sid), sid])
	return false




## 拖拽/投掷类技能共用的"扣精力 + 标记已行动"
## （回合结束交给弹道物：落地/消失时才 _finish_turn，所以飞行途中还能被击落）
func commit_skill(u: Unit, sid: String) -> void:
	var d := Skills.get_def(sid)
	u.spend_energy(int(d["cost"]))
	u.has_acted = true
	u.has_moved = true
	_st._push_unit_stats(u)




## 枪榴弹：与投掷手普攻同款抛物线；落地后只是模型，GM 计时 4 个回合后爆炸
func spawn_grenade_shot(u: Unit, aim: Vector2, sid: String) -> Projectile:
	var d := Skills.get_def(sid)
	var gp := Ordnance.make_grenade(u, aim, true)
	gp.shot.group = "grenade_%d" % Time.get_ticks_msec()
	_st.field.register(gp)
	var cell := Vector2i(int(floor(aim.x)), int(floor(aim.y)))
	_st._log("%s 投出【%s】：落点 (%d, %d)，%d 个回合后爆炸" % [
		u.name, d["name"], cell.x, cell.y, int(d.get("delay_turns", 4))])
	return gp




func raise_pylon_at(pos: Vector2) -> Node3D:
	var root := Node3D.new()
	root.position = Vector3(pos.x, 0.0, pos.y)
	_st.add_child(root)

	# 柱体：很高（80 单位）。缩到最小（zoom 30）时视口高度也就 30 出头，
	# 所以 80 一定能冲出屏幕顶部。
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.20
	cyl.bottom_radius = 0.32
	cyl.height = 80.0
	mi.mesh = cyl
	mi.position = Vector3(0, 40.0, 0)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.72, 0.28, 1.0, 0.55)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	root.add_child(mi)

	# 底部光环，强调落点
	var ring := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 1.0
	disc.bottom_radius = 1.0
	disc.height = 0.05
	ring.mesh = disc
	ring.position = Vector3(0, 0.04, 0)
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rm.albedo_color = Color(0.80, 0.40, 1.0, 0.45)
	ring.material_override = rm
	root.add_child(ring)

	# 轻微脉动，让光柱看起来是"活的"
	var tw: Tween = _st.create_tween()
	tw.tween_property(m, "albedo_color:a", 0.85, 0.7)
	tw.tween_property(m, "albedo_color:a", 0.40, 0.7)
	tw.tween_callback(func() -> void:
		if is_instance_valid(m):
			var t2: Tween = _st.create_tween()
			t2.tween_property(m, "albedo_color:a", 0.85, 0.7)
			t2.tween_property(m, "albedo_color:a", 0.40, 0.7))

	_st._orbital_pylons.append(root)
	return root



func clear_pylons() -> void:
	for p in _st._orbital_pylons:
		if is_instance_valid(p):
			p.queue_free()
	_st._orbital_pylons.clear()




func run_orbital_barrage(p: GameMaster.Pending) -> void:
	var d := Skills.get_def(p.skill_id)
	_st._orbital_busy = true
	var centers := pick_shell_centers(p.float_pos, float(d["marker_radius"]), int(d["shells"]))
	for i in range(centers.size() - 1, 0, -1):
		var j: int = _st.rng.next_int(i + 1)
		var tmp: Vector2 = centers[i]
		centers[i] = centers[j]
		centers[j] = tmp
	var names: Array[String] = []
	for c in centers:
		names.append("(%.1f,%.1f)" % [c.x, c.y])
	_st._log("  落点顺序：" + " → ".join(names))
	for c in centers:
		orbital_shell_incoming(c)
		await _st.get_tree().create_timer(float(d["shell_fall_sec"])).timeout
		resolve_shell_impact(p, c, d)
		await _st.get_tree().create_timer(float(d["shell_gap_sec"])).timeout
	_st._orbital_marks.clear()
	# 只拆掉"这一发"的光柱（其他在途打击的光柱继续留着）
	if p.pylon != null and is_instance_valid(p.pylon):
		p.pylon.queue_free()
		_st._orbital_pylons.erase(p.pylon)
	p.pylon = null
	_st._orbital_busy = false
	_st._log("—— 轨道火力结束 ——")




func pick_shell_centers(center: Vector2, r: float, n: int) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var tries := 0
	while out.size() < n and tries < n * 300:
		tries += 1
		var ang: float = _st.rng.next_int(100000) / 100000.0 * TAU
		var rad := sqrt(_st.rng.next_int(100000) / 100000.0) * r
		var q := center + Vector2(cos(ang), sin(ang)) * rad
		q.x = clampf(q.x, float(_st.PX) + 0.05, float(_st.PX + _st.PW) - 0.05)
		q.y = clampf(q.y, float(_st.PY) + 0.05, float(_st.PY + _st.PH) - 0.05)
		var dup := false
		for e in out:
			if q.distance_to(e) < 0.9:
				dup = true
				break
		if not dup:
			out.append(q)
	return out




func orbital_shell_incoming(pos: Vector2) -> void:
	var target := Vector3(pos.x, 0.0, pos.y)
	# 起点：目标右上方很高处（相机在 -Z 方向俯视，抬高就是出画面）
	var start := target + Vector3(7.0, 26.0, 7.0)

	# 特效与投掷手炮击同款（用户要求）：亮稻草黄 + 光晕 + 尾迹
	var node: Node3D = ProjectileField.make_shell_node(_st)
	if node == null or not is_instance_valid(node):
		return
	node.visible = true
	node.position = start

	# 落点红圈：半径按 impact_radius（1 格）
	var ring: MeshInstance3D = _st.fx.make_impact_ring(pos, float(Skills.get_def("orbital_strike")["impact_radius"]))

	var tw: Tween = _st.create_tween()
	tw.tween_method(func(t: float) -> void:
		if not is_instance_valid(node):
			return
		node.position = start.lerp(target, t)
		ProjectileField.orient(node, start.lerp(target, t), start.lerp(target, maxf(0.0, t - 0.02)), 52.0)
		, 0.0, 1.0, float(Skills.get_def("orbital_strike")["shell_fall_sec"]))
	tw.tween_callback(func() -> void:
		if is_instance_valid(node):
			node.queue_free()
		_st.fx.flash_impact(ring)
		)



func resolve_shell_impact(p: GameMaster.Pending, pos: Vector2, d: Dictionary) -> void:
	# 轨道炮与普攻炮击走同一套范围规则（红圈沾到格子就算命中），
	# 差别只有：轨道炮不分敌我（skip = null）、参数来自技能表。
	var hits: Array = Damage.blast(null, pos, float(d["impact_radius"]), Combat.opts_orbital(d, _st.rng),
		_st.units, _st.placeables, null, p.caster_side, true)
	if hits.is_empty():
		_st._log("  爆炸范围内无人")
		return
	for h in hits:
		_st._log(h.text)
		if h.unit != null:
			_st._after_damage_to_unit(h.unit)
		else:
			_st._after_damage_to_placeable(h.placeable)



func start_carpet_bomb(caster: Unit, center: Vector2) -> void:
	var d := Skills.get_def("carpet_bomb")
	if caster == null or not caster.is_alive():
		pass
		return
	if caster.energy_points() < int(d["cost"]):
		_st._show_action_menu()
		return
	caster.spend_energy(int(d["cost"]))
	caster.has_acted = true
	caster.has_moved = true
	_st._push_unit_stats(caster)
	_st._aim_skill_id = ""
	_st._skill_info_text = ""

	var origin := Vector2(float(caster.cell.x) + 0.5, float(caster.cell.y) + 0.5)
	var pts := Skills.carpet_points(d, center, center - origin, _st.rng)
	var names: Array[String] = []
	for p in pts:
		names.append("(%.1f,%.1f)" % [p.x, p.y])
	_st._log("%s 呼叫【%s】：%d 个落点 %s" % [caster.name, d["name"], pts.size(), " → ".join(names)])
	# 7 发炮弹：间隔 gap_sec 逐一起飞（用 Projectile.pre 做延迟），
	# 于是它们全是"物理弹道物"——可以被箭击落、可以被哨兵盯上、出界就地消失。
	# 速度恒定 Ordnance.SHELL_TILES_PER_SEC，由近及远距离递增 -> 自然就是"由近及远逐个落地"。
	var gap := float(d["gap_sec"])
	# 全部打进同一个编组：7 发全落地/全消失之后才结束回合
	var gid := "carpet_%d" % _st.gm.turn_count + str(Time.get_ticks_msec())
	_st._proj_groups[gid] = pts.size()
	for i in pts.size():
		# 地毯式轰炸的爆炸范围用【轨道炮击同款】（比普攻小的那个版本）
		_st._spawn_shell(caster, pts[i], false, float(i) * gap, gid, _st.CARPET_BLAST_R)




## 玩家/AI 选定目标格 -> 进入准备状态
func cast_dive(u: Unit, cell: Vector2i) -> void:
	var d := Skills.get_def("dive_bomb")
	if u.energy_points() < int(d["cost"]):
		return                                   # 拒绝类文案不进日志（用户口径）
	u.spend_energy(int(d["cost"]))
	u.tags["dive_ready"] = cell
	_st._push_unit_stats(u)
	dive_marker(cell, true)
	_st._log("  🚁 %s 进入【俯冲准备】：目标 (%d, %d)，距离 %d 格" % [
		u.name, cell.x, cell.y, Ai.manhattan(u.cell, cell)])




func dive_clear(u: Unit) -> void:
	if u.tags.has("dive_ready"):
		u.tags.erase("dive_ready")
	dive_marker(Vector2i.ZERO, false)




func dive_marker(cell: Vector2i, on: bool) -> void:
	var key := "shared"
	if on:
		if _st._dive_markers.has(key) and is_instance_valid(_st._dive_markers[key]):
			(_st._dive_markers[key] as Node3D).queue_free()
		var root := Node3D.new()
		root.position = Vector3(float(cell.x) + 0.5, 0.0, float(cell.y) + 0.5)
		var red := StandardMaterial3D.new()
		red.albedo_color = Color(1.0, 0.22, 0.18, 0.62)
		red.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		red.emission_enabled = true
		red.emission = Color(1.0, 0.16, 0.12)
		red.emission_energy_multiplier = 2.0
		var disc := MeshInstance3D.new()
		var cy := CylinderMesh.new()
		cy.top_radius = 0.45
		cy.bottom_radius = 0.45
		cy.height = 0.04
		disc.mesh = cy
		disc.position = Vector3(0, 0.05, 0)
		disc.material_override = red
		root.add_child(disc)
		# 细红光柱（用户口径：投弹指示点用红色，不要紫色激光柱）
		var beam := MeshInstance3D.new()
		var bcy := CylinderMesh.new()
		bcy.top_radius = 0.045
		bcy.bottom_radius = 0.045
		bcy.height = 3.0
		beam.mesh = bcy
		beam.position = Vector3(0, 1.5, 0)
		beam.material_override = red
		root.add_child(beam)
		_st.add_child(root)
		_st._dive_markers[key] = root
		_st._log("  🎯 已标记俯冲目标 (%d, %d)（橙色圆盘）—— 下一次轮到它会俯冲过去" % [cell.x, cell.y])
	elif _st._dive_markers.has(key):
		if is_instance_valid(_st._dive_markers[key]):
			(_st._dive_markers[key] as Node3D).queue_free()
		_st._dive_markers.erase(key)




## 点格子类目标（俯冲轰炸这类 aim=cell 的技能，以及以后"点地格"的普攻）：
## 越界/超程会提示重新点；合法就交给统一入口。单独成函数便于自检直接调用。
func cell_target_ok(cell: Vector2i) -> bool:
	if _st.active == null:
		return false
	var dcell_sk := Skills.get_def(_st._aim_skill_id)
	var base0: Vector2 = _st._cc(_st.active.cell)
	var ctr0: Vector2 = _st._cc(cell)
	var dd_max := float(dcell_sk.get("range_max", 20.0)) \
		if not dcell_sk.is_empty() else float(_st.active.rng_max)
	if not _st._in_bounds(cell):
		_st._log("  ✗ 目标格在地图外，重新点一个")
		return false
	if base0.distance_to(ctr0) > dd_max:
		_st._log("  ✗ 超出射程（%.1f > %.0f 格），重新点一个" % [base0.distance_to(ctr0), dd_max])
		return false
	return true




## 点格子类目标的一次点击（用户口径第 84 轮：粉色可选格 + **两次点击确认**）。
## 返回 true = 这次点击真的把技能放出去了。第一次点只出黄勾，第二次点同一格才确认。
func click_cell_target(cell: Vector2i) -> bool:
	if not _st._cell_targeting:
		return false
	if not _st._same_pending("cell", cell):
		if not cell_target_ok(cell):          # 越界/超程：不画勾，提示重新点
			return false
		_st._set_pending("cell", cell)             # 第一次点：出黄勾，等第二次确认
		_st._refresh_all()
		return false
	_st._clear_pending()
	return confirm_cell_target(cell)




func confirm_cell_target(cell: Vector2i) -> bool:
	if _st.active == null:
		return false
	if not cell_target_ok(cell):
		return false
	_st._cell_targeting = false
	_st.cell_targets = {}
	var sid0: String = _st._aim_skill_id
	_st._aim_skill_id = ""
	# sid 为空 = 点格子类普攻；否则是该技能
	var ok0: bool = perform_skill(_st.active, sid0, _st._cc(cell), cell) if sid0 != "" \
		else _st.attack.perform_basic(_st.active, _st._cc(cell), null, null, false, true)
	if not ok0:
		_st._show_action_menu()
	return ok0
