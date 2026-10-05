# 萨尼铁塔连发的散布形状探针（第 106 轮用户口径：「我需要立体球状散布」）
#
# 背景：用户要求子弹散布是**立体球**。午餐盒齐射已改（`make_cart_bullet_at`），
# 但萨尼铁塔的连发原先走 `Spread.linear_scatter`（**水平圆盘**）+ `make_bullet`（高度固定）
# → 垂直散布恒为 0。本探针验证改完之后她也是立体球。
#
# 运行： exe --headless --path game --script res://tools/probe_burst_spread.gd --quit-after 60000
extends SceneTree

var _s: Node
var _fails: Array[String] = []
var _checks := 0


func _chk(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("  PASS  ", label)
	else:
		print("  FAIL  ", label)
		_fails.append(label)


func _initialize() -> void:
	Level.current = "field"
	_s = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(_s)
	for i in 10:
		await process_frame

	# 找萨尼铁塔（她带连发普攻）
	var sani: Unit = null
	for u in _s.units:
		if Unit.base_name(u.name) == "萨尼铁塔" and u.side == UnitData.Side.PLAYER:
			sani = u
			break
	_chk(sani != null, "场上找得到萨尼铁塔")
	if sani == null:
		_finish()
		return

	print("\n[1] 连发真的在打（走真实入口）")
	var foe: Unit = null
	for u in _s.units:
		if u != null and u.is_alive() and u.side != sani.side:
			foe = u
			break
	_chk(foe != null, "找得到敌方目标")
	if foe == null:
		_finish()
		return
	# 目标放到 12 格外（散布半径 = 12/12 = 1 格）
	foe.cell = sani.cell + Vector2i(0, 12)
	if foe.visual != null:
		foe.visual.position = Vector3(float(foe.cell.x) + 0.5, foe.visual.position.y,
			float(foe.cell.y) + 0.5)
	await process_frame
	var d := GridMath.cell_center(sani.cell).distance_to(GridMath.cell_center(foe.cell))
	print("      目标 %s 距萨尼 %.1f 格（线性散布半径 = %.3f 格）" % [foe.name, d, Spread.linear_radius(d)])

	# 直接调连发实现，收集生成的子弹
	_s.clear_projectiles()
	sani.has_acted = false
	_s.active = sani
	var prof := AttackProfile.for_unit(sani)
	print("      普攻模板 = %s（shots=%s gap=%s）" % [
		AttackProfile.basic_of(sani), str(prof.get("shots")), str(prof.get("gap"))])
	_s.attack.volley_bullets(sani, GridMath.cell_center(foe.cell), foe, null, false, prof)
	# 立刻收集（间隔 0.1 秒，先收第一发；再等一会儿收齐）
	var ys: Array[float] = []
	var y1s: Array[float] = []
	for it in _s.field.items:
		var p: Projectile = it["p"]
		if p.kind == Projectile.KIND_BULLET:
			ys.append(p.y0)
			y1s.append(p.y1)
	print("      第一批发出的子弹：%d 发 ｜ y0 = %s" % [ys.size(), str(ys)])
	_chk(ys.size() >= 1, "连发真的出膛了")

	print("\n[2] 弹道**带俯仰**（y0 ≠ y1 至少有一发）—— 这是立体散布的直接证据")
	await _s.get_tree().create_timer(0.35).timeout
	ys.clear()
	y1s.clear()
	for it in _s.field.items:
		var p: Projectile = it["p"]
		if p.kind == Projectile.KIND_BULLET:
			ys.append(p.y0)
			y1s.append(p.y1)
	print("      共 %d 发 ｜ y0 = %s ｜ y1 = %s" % [ys.size(), str(ys), str(y1s)])
	var tilted := 0
	for i in ys.size():
		if absf(y1s[i] - ys[i]) > 0.001:
			tilted += 1
	# ⚠ 第 107 轮用户口径**反转**了第 106 轮：
	#   「萨尼的子弹会穿越地图下方……请你**解耦两种子弹的散布，即萨尼的子弹按圆盘车按球**」
	#   → 萨尼（连发）**必须没有俯仰**（y1 == y0），否则她会把子弹打到地图下面去。
	_chk(tilted == 0, "萨尼的连发**没有俯仰**（%d/%d 发 y1 ≠ y0，要求 0 = 圆盘散布）" % [tilted, ys.size()])
	var y1_var := _variance(y1s)
	print("      y1 的方差 = %.4f（萨尼是圆盘 → 应为 0）" % y1_var)
	_chk(y1_var <= 0.001, "萨尼 y1 **无方差**（圆盘散布：垂直方向不散）")
	# 反向保险：用户报的 bug 就是"穿越地图下方"，所以高度必须全部 ≥ 0
	var below := 0
	for v in ys:
		if v < 0.0:
			below += 1
	_chk(below == 0, "萨尼的子弹**没有一发**高度 < 0（不再穿越地图下方，实际 %d 发）" % below)

	print("\n[3] 散布形状是**球**不是圆盘/球壳（量 `Spread.ball_offset` 的 r² 分布）")
	var rng := RngService.new(12345)
	var R := 1.0
	var sum_r2 := 0.0
	var n := 10000
	var maxr := 0.0
	for i in n:
		var v := Spread.ball_offset(R, rng)
		var rr := v.length()
		sum_r2 += rr * rr
		maxr = maxf(maxr, rr)
	var ratio := sum_r2 / float(n) / (R * R)
	print("      E[r²]/R² = %.4f（球内均匀理论 0.600 ｜ 圆盘 0.500 ｜ 球壳 1.000）" % ratio)
	print("      最大半径 = %.4f（应 ≤ R = %.1f）" % [maxr, R])
	_chk(absf(ratio - 0.6) < 0.03, "落点分布 = **球内均匀**（E[r²]/R² = %.4f ≈ 0.6）" % ratio)
	_chk(maxr <= R + 0.0001, "所有落点都在球内（最大 %.4f ≤ %.1f）" % [maxr, R])

	print("\n[4] 不受重力（弹道仍是直线）")
	var arc_ok := true
	for it in _s.field.items:
		var p: Projectile = it["p"]
		if p.kind == Projectile.KIND_BULLET and absf(p.arc_scale) > 0.0001:
			arc_ok = false
	_chk(arc_ok, "所有在飞子弹 arc_scale = 0（**没有引入重力**）")

	_finish()


func _variance(a: Array[float]) -> float:
	if a.size() < 2:
		return 0.0
	var m := 0.0
	for v in a:
		m += v
	m /= float(a.size())
	var s := 0.0
	for v in a:
		s += (v - m) * (v - m)
	return s / float(a.size())


func _finish() -> void:
	print("\n── 连发立体散布探针：%d 项检查，失败 %d 项 ──" % [_checks, _fails.size()])
	for f in _fails:
		print("   - ", f)
	quit(1 if _fails.size() > 0 else 0)
