# 第 111 轮：**火箭的加速度制导**（用户口径，第二版）
#   「不是直接平移而是**改变速度方向**，比如我向左打就画一个圆弧转向右，
#     **头部始终指向速度方向**（**高度也要引导**）；
#     每隔 **100ms** 做一次引导判定：当前位置与目标落点差多少、什么方向；
#     然后把这个间隔内的**加速度方向**变成从现在的位置指向目标落点
#     （初始加速度有限，转弯半径设得稍微大一点；**加速度逐渐增大**，
#      不然会出现一直转圈的情况）」
#   参考轨迹：「初始速度向左 -> 直线 -》向右大圆弧 -》圈变小 -》命中；
#              没那么左：直线 -》向右修正 -》命中」
#
# ⚠ 同时保留旧闸门：**只有到达最大速度（飞满 ROCKET_RAMP_DIST）才开始引导**。
extends SceneTree

const LEVEL := "arena"
const HELI := "俯冲轰炸直升机（不要问那么多）"

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
	var heli: Unit = null
	var foe: Unit = null
	for u in s.units:
		if u == null:
			continue
		if u.name == "雷达午餐盒":
			radar = u
		if u.name == HELI:
			heli = u
		if foe == null and u.is_alive() and u.side != 0 and u.name != "雷达午餐盒":
			foe = u
	_ok(radar != null and heli != null and foe != null, "找到 雷达 / 直升机 / 敌人")
	if radar == null or heli == null or foe == null:
		return

	print("\n[1] 散布：连接后减半（旧口径，保留）")
	var base_r: float = float(Level.heli("arena")["scatter_r"])
	_ok(absf(s._radar_spread(base_r, heli) - base_r) < 1e-6, "没连接时散布不动（%.1f）" % base_r)
	s.t_radar_add_link("雷达午餐盒", HELI)
	_ok(absf(s._radar_spread(base_r, heli) - base_r * 0.5) < 1e-6, "连接后 ×0.5")

	s.t_radar_begin_lock("雷达午餐盒", foe.name)
	var rst: Radar.State = s.t_radar_state("雷达午餐盒")
	while not rst.locked():
		s._radar_on_turn_begin(radar)
	_ok(rst.locked(), "雷达已锁定 %s" % foe.name)

	heli.cell = Vector2i(10, 10)
	heli.visual.position = Vector3(10.5, heli.hover, 10.5)
	foe.cell = Vector2i(10, 50)
	foe.visual.position = Vector3(10.5, foe.visual.position.y, 50.5)

	print("\n[2] **没到最大速度就不引导**")
	# 故意朝**左**打（目标在 +y，等于"向左 90°"）—— 正是用户给的第一种参考情形
	var from := Vector3(10.5, heli.hover + 0.5, 10.5)
	var left_to := Vector2(10.5, 10.5) + Vector2(-1.0, 0.0) * 20.0
	var p := Ordnance.make_rocket(heli, from, left_to, false, s.rng)
	s.field.register(p)
	s._radar_guide_rockets(1.0 / 60.0)
	print("      flown=%.2f ｜ steering=%s ｜ guide_accel=%.1f" % [
		p.flown_dist(), str(p.steering), p.guide_accel])
	_ok(p.flown_dist() < Ordnance.ROCKET_RAMP_DIST, "此刻还没飞满 %.0f 格" % Ordnance.ROCKET_RAMP_DIST)
	_ok(not p.steering and p.guide_accel <= 0.0, "**未到最大速度 -> 完全没有引导**")

	print("\n[3] 飞满最大速度后：**加速度制导**接管")
	var n := 0
	while p.flown_dist() < Ordnance.ROCKET_RAMP_DIST and n < 4000:
		p.t = minf(1.0, p.t + 0.005)
		n += 1
	s._radar_guide_rockets(1.0 / 60.0)
	print("      flown=%.1f ｜ steering=%s ｜ guide_accel=%.1f ｜ 初速=(%.1f, %.1f)" % [
		p.flown_dist(), str(p.steering), p.guide_accel, p.steer_vel.x, p.steer_vel.y])
	_ok(p.steering, "**制导已接管**（steering = true）")
	_ok(p.guide_accel > 0.0, "加速度 > 0（开始掰速度方向）")
	_ok(p.steer_vel.x < -1.0, "初速方向仍是**向左**（%.1f）—— 保住直线段" % p.steer_vel.x)

	print("\n[4] 每 100ms 一次判定 + **加速度逐渐增大**（圈越来越小）")
	var accs: Array[float] = [p.guide_accel]
	for i in 5:
		for j in 6:
			p.step(1.0 / 60.0)
			s._radar_guide_rockets(1.0 / 60.0)
		accs.append(p.guide_accel)
	print("      5 段（每段 100ms）的加速度 = %s" % str(accs))
	var growing := true
	for i in range(1, accs.size()):
		if accs[i] < accs[i - 1] - 1e-6:
			growing = false
	_ok(growing, "**加速度单调增大**（%.1f -> %.1f）" % [accs[0], accs[accs.size() - 1]])

	print("\n[5] 速度方向被掰向目标 + 头朝向 = 速度方向 + 高度也引导")
	# ⚠ 判据用**到目标的距离**，不用"速度方向 vs 目标方向"的夹角 ——
	#   后者在火箭逼近目标时**本身不适定**（离得越近，指向目标的方位摆动越剧烈，
	#   实测会在最后 0.5 秒从 20° 甩到 45°，那不是发散、是几何）。距离单调缩短才是"能命中"。
	var dists: Array[float] = []
	for i in 120:
		p.step(1.0 / 60.0)
		s._radar_guide_rockets(1.0 / 60.0)
		if i % 30 == 29:
			dists.append(p.pos().distance_to(GridMath.unit_pos(foe)))
	var vel := p.steer_vel
	print("      每 0.5 秒到目标的距离 = %s" % str(dists))
	_ok(dists.size() >= 3 and dists[dists.size() - 1] < dists[0] - 1.0,
		"**持续接近目标**（%.1f -> %.1f 格）" % [dists[0], dists[dists.size() - 1]])
	var head_dir := Vector2(cos(p.heading), sin(p.heading))
	_ok(head_dir.dot(vel.normalized()) > 0.999,
		"**头部始终指向速度方向**（dot=%.4f）" % head_dir.dot(vel.normalized()))
	print("      垂直速度 = %+.2f ｜ 当前高 %.2f ｜ 目标高 %.2f" % [
		p.steer_vy, p.steer_h, Targeting.aim_height(foe)])
	_ok(absf(p.steer_vy) > 0.01 or absf(p.steer_h - Targeting.aim_height(foe)) < 0.5,
		"**高度方向也在被引导**（vy=%+.2f）" % p.steer_vy)

	print("\n[6] 雷达没锁定时：**不接管**")
	s.clear_projectiles()
	var q := Ordnance.make_rocket(heli, from, left_to, false, s.rng)
	s.field.register(q)
	var m := 0
	while q.flown_dist() < Ordnance.ROCKET_RAMP_DIST and m < 4000:
		q.t = minf(1.0, q.t + 0.005)
		m += 1
	Radar.clear_lock(rst)
	s._radar_guide_rockets(1.0 / 60.0)
	_ok(not q.steering and q.guide_accel <= 0.0,
		"**雷达没锁定时不接管**（steering=%s）" % str(q.steering))

	print("\n[7] **接管不跳变**（用户报的虫洞：一帧跨出去一大截）")
	# ⚠ [6] 把锁定清了 -> 这里必须**重新锁定**，否则接管根本不会发生（第一版就踩了这个坑）
	s.t_radar_begin_lock("雷达午餐盒", foe.name)
	s._radar_on_turn_begin(radar)
	while not rst.locked():
		s._radar_on_turn_begin(radar)
	s.clear_projectiles()
	var w := Ordnance.make_rocket(heli, from, left_to, false, s.rng)
	s.field.register(w)
	var k := 0
	while w.flown_dist() < Ordnance.ROCKET_RAMP_DIST and k < 4000:
		w.t = minf(1.0, w.t + 0.005)
		k += 1
	var before_pos: Vector2 = w.pos()
	s._radar_guide_rockets(1.0 / 60.0)
	var after_pos: Vector2 = w.pos()
	var jump: float = before_pos.distance_to(after_pos)
	print("      接管那一帧：位置 %s -> %s ｜ 位移 %.4f 格" % [
		str(before_pos.snapped(Vector2(0.01, 0.01))),
		str(after_pos.snapped(Vector2(0.01, 0.01))), jump])
	_ok(jump < 0.5, "**接管瞬间位置连续**（位移 %.4f 格，不得跳变）" % jump)
	# 接管速度必须 ≈ 火箭自己的当前极速（不是全程平均速度）
	print("      接管速度 = %.2f 格/秒（火箭极速 %.1f）" % [w.steer_vel.length(), Ordnance.ROCKET_VMAX])
	_ok(w.steer_vel.length() <= Ordnance.ROCKET_VMAX * 1.6,
		"**接管速度不超过极速的量级**（%.2f <= %.1f）" % [
			w.steer_vel.length(), Ordnance.ROCKET_VMAX * 1.6])
	# 连续推进 2 秒，逐帧确认**任何一帧的位移都不异常**
	var worst := 0.0
	var prev: Vector2 = w.pos()
	for i in 120:
		w.step(1.0 / 60.0)
		s._radar_guide_rockets(1.0 / 60.0)
		var cur2: Vector2 = w.pos()
		worst = maxf(worst, prev.distance_to(cur2))
		prev = cur2
	print("      2 秒内单帧最大位移 = %.4f 格（速度上限 %.1f → 单帧上限 %.4f）" % [
		worst, w.guide_cap, w.guide_cap / 60.0])
	_ok(worst <= w.guide_cap / 60.0 + 0.01,
		"**制导期间没有一帧超速**（最大 %.4f ≤ %.4f）" % [worst, w.guide_cap / 60.0])

	print("\n── 火箭加速度制导探针：%d 项检查，失败 %d 项 ──" % [_n, _f])
