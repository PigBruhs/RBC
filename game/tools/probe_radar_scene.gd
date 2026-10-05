# 雷达午餐盒**接进场景后**的探针（第 111 轮）：证明状态机真的挂在正确的生命周期上
extends SceneTree

const RADAR := "雷达午餐盒"
## ⚠ 第 111 轮：雷达**不在测试场 field 名单里**（用户口径：巡飞弹不受雷达影响，
##   而 playtest 的 [38c] 段会把 field 的单位挪成一堆 -> 雷达与靶子叠格会让巡飞弹假红）。
##   所以本探针改用 **arena（沙盒）**，那里有雷达。
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
		if u != null and u.name == RADAR:
			radar = u
	_ok(radar != null, "场上找到 %s（关卡 roster 生效）" % RADAR)
	if radar == null:
		return
	print("      属性：力量 %d 护甲 %d 移动 %d 精力 %d" % [
		radar.power_cur / 1000, radar.armor_cur / 1000, radar.move, radar.energy_points()])
	_ok(radar.power_max / 1000 == 40 and radar.armor_max / 1000 == 40 and radar.move == 6
		and radar.energy_max == 0, "40 力 / 40 甲 / 移动 6 / 精力 0（数据表口径）")

	print("\n[1] 选定锁定 -> 同回合立刻 -1（81 格应落在 5 回合）")
	# 找一个离雷达 81 格左右的敌人；找不到就用实际距离校对
	# ⚠ 必须挑一个**远处**的敌人：15 格内的目标 ceil(15/20)=1 -> 选定即锁定，
	#   那样测不到"每回合 -1"。用敌方老国王（离雷达 ~29 格 -> 2 回合）。
	var foe: Unit = null
	for u in s.units:
		if u != null and u.is_alive() and u.name == "老国王 (E)":
			foe = u
	if foe == null:
		for u in s.units:
			if u != null and u.is_alive() and u.side != radar.side:
				if GridMath.unit_pos(radar).distance_to(GridMath.unit_pos(u)) > 25.0:
					foe = u
					break
	_ok(foe != null, "场上有敌方单位可锁")
	if foe == null:
		return
	var dist := GridMath.unit_pos(radar).distance_to(GridMath.unit_pos(foe))
	var want := Radar.turns_for(dist)
	s.t_radar_begin_lock(RADAR, foe.name)
	var st: Radar.State = s.t_radar_state(RADAR)
	print("      距离 %.1f 格 -> 需 %d 回合；选定后 lock_left = %d" % [dist, want, st.lock_left])
	_ok(st.lock_name == foe.name, "锁定目标已登记（%s）" % st.lock_name)
	_ok(st.lock_total == want, "回合总数 = ceil(距离/20)（%d）" % st.lock_total)
	_ok(st.lock_left == want - 1, "**选定当回合立刻 -1**（%d -> %d）" % [want, st.lock_left])

	print("\n[2] 每轮到自己再 -1，到 0 已锁定")
	var left_before := st.lock_left
	s._radar_on_turn_begin(radar)
	print("      再一次自己的回合：%d -> %d" % [left_before, st.lock_left])
	_ok(st.lock_left == left_before - 1, "自己的回合 -1")
	for i in 60:
		if st.locked():
			break
		s._radar_on_turn_begin(radar)
	_ok(st.locked(), "**最终判定为已锁定**（desc=%s）" % st.desc())

	print("\n[3] 换目标 -> 重置并按新距离重算")
	var foe2: Unit = null
	for u in s.units:
		if u != null and u.is_alive() and u.side != radar.side and u.name != foe.name:
			foe2 = u
			break
	if foe2 != null:
		s.t_radar_begin_lock(RADAR, foe2.name)
		# 换目标 = **先重置再按新距离重算**；新目标若在 20 格内则当回合即锁定（正确行为）
		_ok(st.lock_name == foe2.name and st.lock_total == Radar.turns_for(
			GridMath.unit_pos(radar).distance_to(GridMath.unit_pos(foe2))),
			"换目标后按**新距离**重算（%s：需 %d 回合，lock_left=%d）" % [
				st.lock_name, st.lock_total, st.lock_left])

	print("\n[4] 目标死亡 / 休息 / 被摧毁 -> 重置（但连接保留）")
	Radar.add_link(st, "Gerald")
	s.t_radar_begin_lock(RADAR, foe.name)
	s._radar_clear_lock(radar, "休息")
	_ok(st.lock_name == "" and st.lock_left == 0, "**休息重置锁定**")
	_ok(st.links.has("Gerald"), "**休息不影响连接**（连接与锁定解耦）")
	s.t_radar_begin_lock(RADAR, foe.name)
	s._clear_unit_states(foe)                     # 模拟锁定目标阵亡
	_ok(st.lock_name == "", "**锁定目标灭亡 -> 重置**")
	Radar.add_link(st, "Gerald")
	s._clear_unit_states(radar)                   # 雷达车自己被摧毁
	_ok(not s._radar_states.has(RADAR), "**被摧毁 -> 状态清空**（锁定与连接都没了）")

	print("\n[5] 连接距离持续检查")
	var st2: Radar.State = s.t_radar_state(RADAR)
	Radar.add_link(st2, "Gerald")
	var g: Unit = null
	for u in s.units:
		if u != null and u.name == "Gerald":
			g = u
	_ok(g != null, "找到 Gerald")
	if g != null:
		# 先放到雷达旁边 -> 应保留
		g.cell = radar.cell
		g.visual.position = Vector3(float(g.cell.x) + 0.5, g.visual.position.y, float(g.cell.y) + 0.5)
		s._radar_tick_links()
		_ok(st2.links.has("Gerald"), "紧邻时连接保留")
		# 挪到 40 格外 -> 应断开
		g.cell = radar.cell + Vector2i(40, 0)
		g.visual.position = Vector3(float(g.cell.x) + 0.5, g.visual.position.y, float(g.cell.y) + 0.5)
		s._radar_tick_links()
		_ok(not st2.links.has("Gerald"), "**走远到 40 格 -> 连接断开**")

	print("\n── 雷达场景接线探针：%d 项检查，失败 %d 项 ──" % [_n, _f])
