# 第 111 轮：车普攻的两条用户报障
#   ① **连接后普攻选不到任何目标**（射程内与锁定都不行）
#   ② **方向机瞄准好前就开火** -> 子弹方向完全是错的
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
		if foe == null and u.is_alive() and u.side != 0:
			foe = u
	_ok(cart != null and radar != null and foe != null, "找到 车 / 雷达 / 敌人")
	if cart == null or radar == null or foe == null:
		return
	# 把敌人放到车的射程内（曼哈顿 5 格）
	cart.cell = Vector2i(10, 10)
	cart.visual.position = Vector3(10.5, cart.visual.position.y, 10.5)
	foe.cell = Vector2i(10, 15)
	foe.visual.position = Vector3(10.5, foe.visual.position.y, 15.5)

	print("\n[1] **未连接**时：车普攻能选到目标")
	s.active = cart
	s._aim_skill_id = ""
	s.action_menu.menu_attack()
	_ok(s.phase == s.Phase.CHOOSE_TARGET, "进入选目标阶段")
	var n0: int = s.t_attackable_cells().size()
	print("      可选格 = %d ｜ 敌人格 %s 在内 = %s" % [
		n0, str(foe.cell), str(s.t_attackable_cells().has(foe.cell))])
	_ok(n0 > 0 and s.t_attackable_cells().has(foe.cell), "未连接时**能选到射程内的敌人**")

	print("\n[2] **连接后**：车普攻仍要能选到目标（用户报的 bug）")
	_ok(s.t_radar_add_link("雷达午餐盒", "轮式齐射午餐盒"), "把车连到雷达上")
	# 让雷达**已锁定**该敌人（这样难点2 那条"无视距离"也会参与进来）
	s.t_radar_begin_lock("雷达午餐盒", foe.name)
	var rst: Radar.State = s.t_radar_state("雷达午餐盒")
	while not rst.locked():
		s._radar_on_turn_begin(radar)
	_ok(rst.locked(), "雷达已锁定该敌人")
	s.active = cart
	s._aim_skill_id = ""
	s.action_menu.menu_attack()
	var cells: Dictionary = s.t_attackable_cells()
	print("      可选格 = %d ｜ 敌人格在内 = %s ｜ phase=%s" % [
		cells.size(), str(cells.has(foe.cell)), str(s.phase)])
	_ok(cells.size() > 0, "**连接后可选集合非空**（用户报选不到任何目标）")
	_ok(cells.has(foe.cell), "**连接后射程内的敌人仍可选**")
	# 点两下真的开打
	s.t_click_cell(foe.cell)
	s.t_click_cell(foe.cell)
	print("      点两下后 has_acted=%s ｜ 在飞弹道物=%d" % [str(cart.has_acted), s.field.items.size()])
	_ok(cart.has_acted, "**连接后点两下能真的开始普攻**")

	print("\n[3] 方向机：齐射期间**炮管必须已经对准开火方向**")
	# 先把炮塔拧到一个明显不对的朝向，再叫一次齐射，看它会不会没转到位就开火
	cart.has_acted = false
	var st2: Dictionary = s._lb_state(cart)
	(st2["aim"] as Lunchbox.Aim).theta = 270.0        # 故意朝反方向
	(st2["aim"] as Lunchbox.Aim).phi = 0.0
	var m: LunchboxModel = s._lb_model(cart)
	if m != null:
		m.set_aim(270.0, 0.0)
	cart.cell = Vector2i(10, 10)
	cart.visual.position = Vector3(10.5, cart.visual.position.y, 10.5)
	foe.cell = Vector2i(10, 16)                        # 目标在 +y -> 期望 theta ≈ 90
	foe.visual.position = Vector3(10.5, foe.visual.position.y, 16.5)
	s.clear_projectiles()
	_lb_salvo_probe(s, cart)
	# 等齐射第一波出膛
	var guard := 0
	while s.field.items.is_empty() and guard < 900:
		await process_frame
		guard += 1
	# 第一发出膛那一刻，炮管朝向与**子弹方向**的夹角
	var worst := 1.0
	var shots := 0
	for it in s.field.items:
		var p: Projectile = it["p"]
		if p.kind != Projectile.KIND_CART_BULLET:
			continue
		shots += 1
		var v: Vector2 = (p.pos() - Vector2(it.get("prev", p.pos())))
		if v.length() < 0.0001:
			continue
		var aim_th := (st2["aim"] as Lunchbox.Aim).theta
		var barrel := Vector2(cos(deg_to_rad(aim_th)), sin(deg_to_rad(aim_th)))
		worst = minf(worst, barrel.normalized().dot(v.normalized()))
	print("      第一波出膛 %d 发 ｜ 炮管朝向 %.1f° ｜ 炮管与子弹方向最小 dot = %.4f" % [
		shots, (st2["aim"] as Lunchbox.Aim).theta, worst])
	_ok(shots > 0, "齐射真的开火了")
	_ok(worst > 0.99, "**开火时炮管已对准发射方向**（dot=%.4f）" % worst)

	print("\n── 车普攻选目标 + 方向机探针：%d 项检查，失败 %d 项 ──" % [_n, _f])


## 直接调 `_lunchbox_salvo`（它是 async，所以这里"点火即走"）
func _lb_salvo_probe(s: Node, cart: Unit) -> void:
	s._lunchbox_salvo(cart, GridMath.unit_pos(cart) + Vector2(0, 6))
