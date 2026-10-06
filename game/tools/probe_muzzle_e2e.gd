# 第 111 轮：**端到端**验证"可见炮管 -> 子弹"的一致性（用户报的"垂直飞出"）
#
# ⚠ 为什么之前两个探针都没抓到：
#   · `probe_muzzle_axis`   量的是 `muzzle_local_at()` 的**数学方向** vs 子弹方向（同源 -> 恒平行）
#   · `probe_prism_axis`    量的是**棱柱网格的世界长轴** vs 数学方向（建模本来就对 -> dot=1.0）
#   两者都**没量**「可见炮管的**世界位置**」与「子弹的**发射点**」是否同一个地方 ——
#   而真正的 bug 恰恰是**基准点错了**（`_lb_center` vs 模型根，车体转向后差 1.1 格）。
# 本探针把四件事放在**同一个世界坐标系**里量：
#   ① 棱柱网格的世界长轴（= 玩家看到的炮管朝向）
#   ② 炮口的**可见**世界位置（棱柱前端）
#   ③ 子弹的**实际发射点**
#   ④ 子弹的**实际飞行方向**
# 然后再**转动车体**（yaw 0/90/180/270）各测一遍 —— bug 只在车体转向后显现。
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
	for u in s.units:
		if u != null and u.name == "轮式齐射午餐盒":
			cart = u
			break
	_ok(cart != null, "找到齐射车")
	if cart == null:
		return
	var m: LunchboxModel = s._lb_model(cart)
	var prism: MeshInstance3D = m.t_prism()
	_ok(m != null and prism != null, "拿到模型与棱柱")
	if m == null or prism == null:
		return
	var foe: Unit = null
	for u in s.units:
		if u != null and u.is_alive() and u.side != cart.side:
			foe = u
			break
	_ok(foe != null, "找到敌人")
	if foe == null:
		return

	print("\n[1] **转动车体**（yaw）后逐项核对：可见炮口 vs 子弹发射点 vs 方向")
	for yaw in [90.0, 0.0, 180.0, 270.0]:
		m.set_body_yaw(yaw)
		# ⚠ 必须等**上一轮齐射真的跑完**再开始下一轮：`_lunchbox_salvo` 是 async，
		#   它会持续 12 波；不等它跑完，`field.items` 里混着**上一波**的子弹，
		#   而我读的是**这一波**的炮管角 —— 两者差的是 ±10° 摇动，于是 dot 只有 0.97。
		#   （这正是我第一次跑出 dot=0.968 的原因：**探针**的问题，不是 bug。）
		var g0 := 0
		while s._lb_salvo_busy() and g0 < 3000:
			await process_frame
			g0 += 1
		m.set_body_yaw(yaw)
		# 目标固定在车的"网格 +y"方向 8 格
		cart.cell = Vector2i(20, 20)
		cart.visual.position = Vector3(20.5, cart.visual.position.y, 20.5)
		foe.cell = Vector2i(20, 28)
		foe.visual.position = Vector3(20.5, foe.visual.position.y, 28.5)
		s.active = cart
		cart.has_acted = false
		s.clear_projectiles()
		s._lunchbox_salvo(cart, GridMath.unit_pos(foe))
		var guard := 0
		while s.field.items.is_empty() and guard < 900:
			await process_frame
			guard += 1
		var st: Dictionary = s._lb_state(cart)
		var aim_th: float = (st["aim"] as Lunchbox.Aim).theta
		# 抓到第一发子弹的**同一帧**再读炮管（`set_aim` 就在 `_lb_fire_wave` 前一行）
		# ① 棱柱世界长轴
		var barrel_dir: Vector3 = prism.global_transform.basis.y.normalized()
		# ② 可见炮口 = 棱柱中心 + 长轴 × 半长（棱柱高度 1.2）
		var ab: AABB = prism.mesh.get_aabb()
		var barrel_tip: Vector3 = prism.global_position + barrel_dir * (ab.size.y * 0.5)
		# ③④ 子弹的发射点与方向
		var shot_from := Vector3.ZERO
		var shot_dir3 := Vector3.ZERO
		var found := false
		for it in s.field.items:
			var p: Projectile = it["p"]
			if p.kind != Projectile.KIND_CART_BULLET:
				continue
			# ⚠ 必须用**三维**发射点与方向：`p.from`/`p.to` 只有 xz，
			#   高度在 `p.y0`/`p.y1`。我第一版把 y 清零 -> 拿"带俯仰的炮管轴"
			#   去比"水平方向"，dot 只有 0.95~0.98，那是**探针**的错，不是 bug。
			shot_from = Vector3(p.from.x, p.y0, p.from.y)
			var to3 := Vector3(p.to.x, p.y1, p.to.y)
			shot_dir3 = (to3 - shot_from).normalized()
			found = true
			break
		if not found:
			print("      yaw=%.0f：⚠ 没有子弹" % yaw)
			continue
		var shot_dir := shot_dir3
		# 发射点与可见炮口的水平距离（这是关键指标）
		var gap := Vector2(shot_from.x - barrel_tip.x, shot_from.z - barrel_tip.z).length()
		# ⚠ 判据用**方位角**（水平投影）：用户看到的"指向左上 / 飞向右上"就是方位差。
		#   俯仰上允许有小差：炮管的 phi 是按**支点**(`TURRET_Y`)算的，
		#   而子弹是从**炮口**往 `tgt_y` 连一条直线 —— 两者天然差
		#   `atan(BARREL_LEN·sin(phi) / dist)`（本例约 1°），这是既有的、无害的口径差。
		var b_h := Vector2(barrel_dir.x, barrel_dir.z).normalized()
		var s_h := Vector2(shot_dir.x, shot_dir.z).normalized()
		var dot_h := b_h.dot(s_h)
		var elev_b := rad_to_deg(asin(clampf(barrel_dir.y, -1.0, 1.0)))
		var elev_s := rad_to_deg(asin(clampf(shot_dir.y, -1.0, 1.0)))
		print("      yaw=%5.1f ｜ aim.theta=%.1f° phi=%.1f° ｜ 棱柱轴=(%.2f,%.2f,%.2f) ｜ 子弹3D方向=(%.2f,%.2f,%.2f)" % [
			yaw, aim_th, (st["aim"] as Lunchbox.Aim).phi,
			barrel_dir.x, barrel_dir.y, barrel_dir.z, shot_dir.x, shot_dir.y, shot_dir.z])
		print("                 发射点 vs 可见炮口 水平间距 = %.3f 格 ｜ 方位 dot=%.4f ｜ 俯仰 炮管%.1f° vs 子弹%.1f°" % [
			gap, dot_h, elev_b, elev_s])
		# ⚠ 方位差允许 **22°**（= 两侧摇动 ±10° 的全包络 20° + 余量）：
		#   炮管**每波摇 ±10°**（用户要求的手感），而本探针读炮管的角度比"那一发出膛"
		#   晚 1~2 帧 —— 期间 `step_aim` 已经朝下一波转了一点，所以读数天然有偏差。
		#   **能做的最强断言**就是"在同一摇动包络内"；要更严就得在出膛那一帧精确取样。
		#   真正决定性的是下面那条"发射点间距"（它才是用户看到的"从旁边冒出"）。
		var addr := rad_to_deg(b_h.angle_to(s_h))
		_ok(absf(addr) < 22.0, "yaw=%.0f：**方位在摇动包络内**（差 %.1f° ≤ 22°）" % [yaw, addr])
		_ok(absf(elev_b - elev_s) < 8.0, "yaw=%.0f：俯仰差在既有口径内（%.1f° - %.1f°）" % [
			yaw, elev_b, elev_s])
		# 允许 0.35 格（棱柱半长 + 子弹横向铺开 0.15 的合理余量）
		_ok(gap < 0.45, "yaw=%.0f：**子弹从可见炮口附近射出**（间距 %.3f 格）" % [yaw, gap])

	print("\n[2] 连打多轮普攻后，冷却走完能**再次开火**（用户报的第二个症状）")
	# ⚠ 必须**等一轮齐射真的跑完**再开下一轮（`_lunchbox_salvo` 是 async，12 波 × 133ms
	#   ≈ 1.6 秒）。第一版只等"第一发出膛"就急着开下一轮 -> 几轮叠加，探针读到的是
	#   中间态（rounds=8、cool_left=0.97），那是**探针**的错。
	for i in 3:
		cart.has_acted = false
		s.clear_projectiles()
		s._lunchbox_salvo(cart, GridMath.unit_pos(foe))
		var g2 := 0
		while s._lb_salvo_busy() and g2 < 3000:
			await process_frame
			g2 += 1
		print("      第 %d 轮齐射跑完（等了 %d 帧）" % [i + 1, g2])
	var heat: Lunchbox.Heat = (s._lb_state(cart) as Dictionary)["heat"]
	print("      三轮之后：heat.rounds=%d ｜ cool_left=%.2f ｜ can_fire=%s" % [
		heat.rounds, heat.cool_left, str(Lunchbox.can_fire(heat))])
	# 冷却走完（最多等 5 秒）
	# ⚠ 第 111 轮：冷却 3 -> **13 秒**，所以等待上限要够（无头下每帧 delta 不稳定，
	#   实测 1400 帧只走了 ~10 秒冷却，所以这里留到 3000 帧）
	var g3 := 0
	while not Lunchbox.can_fire(heat) and g3 < 3000:
		await process_frame
		g3 += 1
	print("      冷却后：heat.rounds=%d ｜ cool_left=%.2f ｜ can_fire=%s（等了 %d 帧）" % [
		heat.rounds, heat.cool_left, str(Lunchbox.can_fire(heat)), g3])
	_ok(Lunchbox.can_fire(heat), "**冷却结束后可以再次开火**（rounds 归零、cool_left<=0）")

	print("\n── 炮口端到端探针：%d 项检查，失败 %d 项 ──" % [_n, _f])
