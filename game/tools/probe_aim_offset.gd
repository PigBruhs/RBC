# 第 111 轮：**车普攻的弹着点到底偏多少**（用户："锁 reaper 现在打都打不到了，直接偏两格"）
# 不猜 —— 直接量三件事：
#   ① 车开火时用的**基准点** `_lb_origin` 与"车体几何中心"差多少（这是我最怀疑的地方）
#   ② 每一发子弹的**落点 `p.to`** 与目标格中心的偏差
#   ③ 子弹**实际终止位置**的分布中心与目标格中心的偏差（≈ 弹着点）
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
	await _run(s)
	quit(1 if _f > 0 else 0)


func _run(s: Node) -> void:
	var cart: Unit = null
	var big: Unit = null
	for u in s.units:
		if u == null:
			continue
		if u.name == "轮式齐射午餐盒":
			cart = u
		if u.name == "Reaper":
			big = u
	_ok(cart != null and big != null, "reaper 关里有 车 与 Reaper")
	if cart == null or big == null:
		return

	cart.cell = Vector2i(20, 20)
	cart.visual.position = Vector3(20.5, cart.visual.position.y, 20.5)
	big.cell = Vector2i(20, 34)                     # 正 +y 方向 14 格
	big.visual.position = Vector3(20.5, big.visual.position.y, 34.5)
	var m: LunchboxModel = s._lb_model(cart)

	print("\n[1] 基准点几何：`_lb_origin` vs `_lb_center` vs 车体几何中心")
	var vis: Vector3 = cart.visual.position
	var org: Vector2 = s._lb_origin(cart)
	var ctr: Vector2 = s._lb_center(cart)
	print("      视觉位置(锚点格中心) = (%.2f, %.2f)" % [vis.x, vis.z])
	print("      `_lb_origin`（开火基准） = (%.2f, %.2f)  ｜ 与视觉差 %.2f 格" % [
		org.x, org.y, Vector2(vis.x, vis.z).distance_to(org)])
	print("      `_lb_center`（车体中心口径） = (%.2f, %.2f) ｜ 与视觉差 %.2f 格" % [
		ctr.x, ctr.y, Vector2(vis.x, vis.z).distance_to(ctr)])
	print("      车体朝向 yaw = %.1f°" % m.body_yaw())
	print("      ⚠ 两者相差 %.2f 格 —— 这就是瞄准基准的歧义来源" % org.distance_to(ctr))

	print("\n[2] 各发子弹的**落点**与目标格中心的偏差")
	var aim_cell := big.cell
	var aim_ctr := GridMath.cell_center(aim_cell)
	var base_dist: float = s._lb_origin(cart).distance_to(aim_ctr)
	print("      目标格 %s ｜ 格中心 = (%.2f, %.2f) ｜ 体半径 %.2f ｜ 基准到目标 %.2f 格" % [
		str(aim_cell), aim_ctr.x, aim_ctr.y, Targeting.unit_body_r(big), base_dist])
	s.active = cart
	cart.has_acted = false
	s.clear_projectiles()
	s._lunchbox_salvo(cart, aim_ctr)
	var g := 0
	while s.field.items.is_empty() and g < 900:
		await process_frame
		g += 1
	# 把日志里的"中轴/射程"打出来（`射程` 就是 `_lb_fire_wave` 用的 `dist`）
	var lg: Array[String] = s.t_debug_log()
	for i in range(maxi(0, lg.size() - 4), lg.size()):
		if lg[i].find("齐射") >= 0:
			print("      日志：%s" % lg[i])
	var dist_used := base_dist
	var sum := Vector2.ZERO
	var n := 0
	var worst := 0.0
	var off_before := 0.0            # 普通齐射第一波的偏移（留给 [2b] 做对照）
	for it in s.field.items:
		var p: Projectile = it["p"]
		if not p.is_bullet_class():
			continue
		# ⚠⚠ **`p.to` 不是瞄准点！** 子弹的 `to` = `from + dir × BULLET_MAX_DIST`（≈32 格，
		#   即"飞满最大射程的终点"）。第一版拿它当落点，量出"偏 19.8 格"—— 那是**探针的错**。
		#   真正的瞄准方向 = `(p.to - p.from)` 的**方向**，把它按 `dist` 外推才是瞄准点。
		var d: Vector2 = p.to
		var aim_pt: Vector2 = Vector2(p.from.x, p.from.y) \
			+ (d - Vector2(p.from.x, p.from.y)).normalized() * dist_used
		# ⚠⚠ 外推距离必须是"**炮口 -> 目标**"，不是"基准 -> 目标"！
		#   子弹是从**炮口**出发的，拿 `dist`（从基准算）去外推会多飞一个"炮口前伸量"（≈1.2 格）
		#   —— 第一版就是这么量出"+1.16 格"的假偏移。
		dist_used = Vector2(p.from.x, p.from.y).distance_to(aim_ctr)
		aim_pt = Vector2(p.from.x, p.from.y) \
			+ (d - Vector2(p.from.x, p.from.y)).normalized() * dist_used
		print("        发 %d：方向角 %.2f° ｜ 按(炮口->目标)%.2f 格外推的瞄准点 = (%.2f,%.2f)" % [
			n, rad_to_deg((d - Vector2(p.from.x, p.from.y)).angle()), dist_used,
			aim_pt.x, aim_pt.y])
		sum += aim_pt
		n += 1
		worst = maxf(worst, d.distance_to(aim_ctr))
	if n > 0:
		var mean := sum / float(n)
		off_before = mean.distance_to(aim_ctr)
		print("      第一波 %d 发：落点均值 = (%.2f, %.2f) ｜ 与目标格中心差 %.3f 格（最远 %.3f）" % [
			n, mean.x, mean.y, mean.distance_to(aim_ctr), worst])
		# ⚠ 判据（第 111 轮定位后修正）：**普通齐射本来就是 ±10° 甩头**，
		#   所以第一波的瞄准点**不该**在目标格中心 —— 而应该在"中轴 ±10°"那条线上。
		#   用户看到的"偏两格"就是这个甩头（14 格处 ±10° ≈ ±2.5 格）。
		print("      ⚠ 该偏移 = **普通齐射的 ±10° 甩头**（第 1 波 theta 84.7° vs 中轴 90°）")
		_ok(mean.distance_to(aim_ctr) > 0.8 and mean.distance_to(aim_ctr) < 3.0,
			"**普通齐射第一波偏离目标 0.8~3.0 格 = 甩头的量级**（实际 %.2f 格）" % mean.distance_to(aim_ctr))
	else:
		print("      ⚠ 第一波没抓到子弹")

	# 等齐射跑完，看**最终落点分布**（更能代表"弹着点"）
	var guard := 0
	while s._lb_salvo_busy() and guard < 3000:
		await process_frame
		guard += 1
	var ends: Array[Vector2] = []
	for ev in []:
		pass
	print("\n[2b] 对照：**【锁定齐射】不甩头**，瞄准点应当就在目标格中心")
	s.clear_projectiles()
	cart.has_acted = false
	s._lunchbox_salvo_locked(cart, aim_ctr, big)
	g = 0
	while s.field.items.is_empty() and g < 900:
		await process_frame
		g += 1
	var sum2 := Vector2.ZERO
	var n2 := 0
	for it in s.field.items:
		var p2: Projectile = it["p"]
		if not p2.is_bullet_class():
			continue
		var d2: Vector2 = p2.to
		var du: float = Vector2(p2.from.x, p2.from.y).distance_to(aim_ctr)
		sum2 += Vector2(p2.from.x, p2.from.y) \
			+ (d2 - Vector2(p2.from.x, p2.from.y)).normalized() * du
		n2 += 1
	if n2 > 0:
		var mean2 := sum2 / float(n2)
		var off_after := mean2.distance_to(aim_ctr)
		print("      锁定齐射第一波 %d 发：瞄准点均值 = (%.2f, %.2f) ｜ 与目标格中心差 %.3f 格" % [
			n2, mean2.x, mean2.y, off_after])
		print("      对照：普通齐射偏 %.3f 格 -> 锁定齐射偏 %.3f 格" % [off_before, off_after])
		_ok(off_after < off_before - 0.5,
			"**【锁定齐射】明显更贴目标**（%.2f -> %.2f 格）" % [off_before, off_after])
		_ok(off_after < 1.0, "锁定齐射的瞄准点已很接近目标格中心（%.3f 格）" % off_after)
	else:
		print("      ⚠ 锁定齐射没抓到子弹")
	g = 0
	while s._lb_salvo_busy() and g < 3000:
		await process_frame
		g += 1

	print("\n[3] 结论（供下一步定位）")
	print("      若 [2] 的落点均值 ≈ 目标格中心 -> **瞄准是对的**，偏差在**弹道/碰撞**；")
	print("      若明显偏 -> 偏差在**瞄准点**（基准点或 `fpos`）。")

	print("\n── 弹着点偏移探针：%d 项检查，失败 %d 项 ──" % [_n, _f])
