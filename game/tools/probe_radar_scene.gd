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

	print("\n[6] 难点 1：锁定 HUD（荧光绿矩形 + 左上剩余回合 / 右上状态）")
	var foe3: Unit = null
	for u in s.units:
		if u != null and u.is_alive() and u.side != radar.side:
			foe3 = u
			break
	if foe3 != null:
		s.t_radar_begin_lock(RADAR, foe3.name)
		s._radar_tick_huds()
		var hud = s._radar_huds.get(foe3.name, null)
		_ok(hud != null, "**被锁定目标身上出现了 HUD**（%s）" % foe3.name)
		if hud != null:
			var sz: Vector2 = hud.t_size()
			print("      HUD 尺寸 = %.2f x %.2f ｜ 左上 = '%s' ｜ 右上 = '%s'" % [
				sz.x, sz.y, hud.t_left_text(), hud.t_right_text()])
			var r: float = Targeting.unit_body_r(foe3)
			_ok(absf(sz.x - maxf(1.0, r * 2.0)) < 0.001,
				"尺寸 = **按碰撞体积的直径**（体半径 %.2f -> 宽 %.2f）" % [r, sz.x])
			_ok(hud.t_left_text() != "" and hud.t_right_text() in ["锁定中", "已锁定"],
				"**左上 = 数字、右上 = 锁定中/已锁定**（'%s' / '%s'）" % [
					hud.t_left_text(), hud.t_right_text()])
			_ok(hud.t_right_text() == "锁定中" or hud.t_left_text() == "0",
				"未锁定完成时右上显示'锁定中'")
			# HUD 会**面向相机**（法线与相机同向）
			hud.face_camera(s._camera)
			var cam_b: Basis = s._camera.global_transform.basis
			var hud_b: Basis = hud.global_transform.basis
			_ok(hud_b.z.dot(cam_b.z) > 0.999,
				"**HUD 面向相机**（法线与相机同向 dot=%.4f）" % hud_b.z.dot(cam_b.z))
		# 清掉锁定 -> HUD 移除
		s._radar_clear_lock(radar, "探针")
		s._radar_tick_huds()
		_ok(s._radar_huds.get(foe3.name, null) == null, "**锁定清掉后 HUD 被移除**")

	print("\n[7] 连接技能（cast=link）+ 闪动蓝色光柱")
	# 技能定义
	var d := Skills.get_def("radar_link")
	_ok(not d.is_empty() and String(d.get("cast", "")) == Skills.CAST_LINK,
		"技能 radar_link 存在且 cast=link")
	_ok(String(d.get("aim", "")) == Skills.AIM_ALLY and absf(float(d.get("range_max", 0)) - 16.0) < 0.001,
		"瞄准方式 = 点友军（AIM_ALLY）、距离上限 16 格")
	_ok(String(d.get("owner", "")) == RADAR, "owner = %s" % RADAR)
	# 走**玩家真实入口**：选技能 -> 进选友军阶段 -> 点友军两次
	var st3: Radar.State = s.t_radar_state(RADAR)
	var g2: Unit = null
	for u in s.units:
		if u != null and u.name == "Gerald":
			g2 = u
	_ok(g2 != null, "找到友军 Gerald")
	if g2 != null:
		# 摆到 10 格内（16 格限制内）
		g2.cell = radar.cell + Vector2i(10, 0)
		g2.visual.position = Vector3(float(g2.cell.x) + 0.5, g2.visual.position.y,
			float(g2.cell.y) + 0.5)
		radar.energy = radar.energy_max          # 雷达精力 0，技能免费，但先确保不卡在"没行动"
		radar.has_acted = false
		s.active = radar
		s.t_choose_skill("radar_link")
		_ok(s.phase == s.Phase.CHOOSE_TARGET, "进入【选友军】阶段")
		_ok(s.t_attackable_cells().has(g2.cell), "**友军所在格被高亮**（可选）")
		s.t_click_cell(g2.cell)
		s.t_click_cell(g2.cell)
		_ok(st3.links.has("Gerald"), "**两次点击后连接建立**（links=%s）" % str(st3.links))
		# 光柱
		s._radar_tick_beams(0.016)
		_ok(s._radar_beams.size() == st3.links.size(),
			"**连接光柱数量 = 连接数**（%d）" % s._radar_beams.size())
		if s._radar_beams.size() > 0:
			var beam: RadarBeam = s._radar_beams[0]
			var a1: float = beam.t_alpha()
			var h1: float = beam.t_height()
			# 闪动：推进半个周期后透明度应不同
			var half := 1.0 / (2.0 * RadarBeam.PULSE_HZ)
			s._radar_tick_beams(half)
			var a2: float = beam.t_alpha()
			print("      光柱高度 %.2f 格（应 ≈ 雷达→友军 距离）｜ 透明度 %.3f -> %.3f" % [h1, a1, a2])
			_ok(h1 > 5.0, "光柱长度跟着两点距离（%.2f 格）" % h1)
			_ok(absf(a1 - a2) > 0.15, "**光柱在闪动**（透明度 %.3f -> %.3f）" % [a1, a2])
		# FIFO：再连两个 -> 最早那个被挤出（Gerald 应被挤掉）
		var others: Array[Unit] = []
		for u in s.units:
			if u != null and u.is_alive() and u.side == radar.side and u != radar:
				others.append(u)
		if others.size() >= 2:
			var st4: Radar.State = s.t_radar_state(RADAR)
			Radar.add_link(st4, others[0].name)
			Radar.add_link(st4, others[1].name)
			_ok(st4.links.size() == Radar.MAX_LINKS,
				"**最多两名**（实际 %d）" % st4.links.size())

	print("\n[8] 难点 2 接入：散布修正 + 无视距离选被锁定目标")
	var cart: Unit = null
	for u in s.units:
		if u != null and u.name == "轮式齐射午餐盒":
			cart = u
			break
	_ok(cart != null, "场上找到轮式齐射午餐盒（有散布的角色）")
	if cart != null:
		var st5: Radar.State = s.t_radar_state(RADAR)
		st5.links.clear()
		Radar.clear_lock(st5)
		Radar.add_link(st5, cart.name)
		# 未锁定 -> 基准半径 ×0.5
		_ok(absf(s.radar_spread_mult(cart, 20.0) - 0.5) < 1e-6,
			"**锁定完成前：散布倍率 = 0.5**（实际 %.3f）" % s.radar_spread_mult(cart, 20.0))
		_ok(absf(s._radar_spread(1.5, cart) - 0.75) < 1e-6, "绝对半径 1.5 -> 0.75（×0.5）")
		# 锁定完成 -> "直径 0.1 格的球"（半径 0.05）
		var foe4: Unit = null
		for u in s.units:
			if u != null and u.is_alive() and u.side != radar.side:
				foe4 = u
				break
		if foe4 != null:
			s.t_radar_begin_lock(RADAR, foe4.name)
			while not st5.locked():
				s._radar_on_turn_begin(radar)
			_ok(absf(s._radar_spread(1.5, cart) - 0.05) < 1e-6,
				"**锁定完成后：绝对半径 = 0.05（= 直径 0.1 格的球）**（实际 %.3f）" % s._radar_spread(1.5, cart))
			# 没被连接的角色不受影响
			var other: Unit = null
			for u in s.units:
				if u != null and u.is_alive() and u.side == radar.side and u.name != RADAR \
						and not st5.links.has(u.name):
					other = u
					break
			if other != null:
				_ok(absf(s._radar_spread(1.5, other) - 1.5) < 1e-6,
					"**未被连接的友军散布不变**（%s）" % other.name)
			# 无视距离选被锁定目标（走**普攻**那条选目标路：空 sid）
			s.active = cart
			s._aim_skill_id = ""
			cart.cell = radar.cell
			cart.visual.position = Vector3(float(cart.cell.x) + 0.5, cart.visual.position.y,
				float(cart.cell.y) + 0.5)
			foe4.cell = radar.cell + Vector2i(60, 0)
			foe4.visual.position = Vector3(float(foe4.cell.x) + 0.5, foe4.visual.position.y,
				float(foe4.cell.y) + 0.5)
			s._begin_unit_targeting("")
			var got: bool = s.t_attackable_cells().has(foe4.cell)
			print("      被锁定目标挪到 60 格外 ｜ 进可选集合 = %s" % str(got))
			_ok(got, "**被连接的友军可无视距离选被锁定目标**（60 格外也在可选集合里）")

	print("\n── 雷达场景接线探针：%d 项检查，失败 %d 项 ──" % [_n, _f])
