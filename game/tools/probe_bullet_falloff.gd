# 第 111 轮用户口径：**子弹伤害衰减改到 24 格外保留 20%、64 格模型消失（伤害 0）**
#   「子弹伤害衰减修改至 24 格外保留 20% 伤害，64 格模型消失（64 格伤害为 0）」
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
	print("\n[1] 伤害衰减阶梯")
	var pts := [0.0, 12.0, 16.0, 24.0, 32.0, 44.0, 56.0, 63.9, 64.0, 80.0]
	for d in pts:
		print("      %5.1f 格 -> %.4f" % [d, Damage.bullet_mult(d)])
	# ⚠ 第 111 轮**简化**：24 格内 100%、25~63 = 50%、64 起 = 0
	_ok(absf(Damage.bullet_mult(12.0) - 1.0) < 1e-6, "12 格 = 100%")
	_ok(absf(Damage.bullet_mult(24.0) - 1.0) < 1e-6, "**24 格 = 100%（新口径：24 格内满伤）**")
	_ok(absf(Damage.bullet_mult(25.0) - 0.5) < 1e-6, "**25 格 = 50%（新口径）**")
	# 24 -> 64 线性
	_ok(absf(Damage.bullet_mult(44.0) - 0.5) < 1e-6, "44 格 = 50%（25~64 一档）")
	_ok(absf(Damage.bullet_mult(30.0) - 0.5) < 1e-6,
		"**24 格外 = 50%**（30 格 = %.3f）" % Damage.bullet_mult(30.0))
	_ok(absf(Damage.bullet_mult(64.0)) < 1e-6, "**64 格伤害 = 0（用户口径）**")
	_ok(absf(Damage.bullet_mult(80.0)) < 1e-6, "80 格仍为 0")
	_ok(absf(Damage.bullet_mult(63.0) - 0.5) < 1e-6,
		"63 格仍 = 50%%（%.4f）；64 格才归零" % Damage.bullet_mult(63.0))

	print("\n[2] **64 格模型消失**：子弹飞满 64 格被移除")
	var cart: Unit = null
	var foe: Unit = null
	for u in s.units:
		if u == null:
			continue
		if u.name == "轮式齐射午餐盒":
			cart = u
		if foe == null and u.is_alive() and u.side != 0 and u.name != "雷达午餐盒":
			foe = u
	_ok(cart != null and foe != null, "找到车与敌人")
	if cart == null or foe == null:
		return
	cart.cell = Vector2i(10, 10)
	cart.visual.position = Vector3(10.5, cart.visual.position.y, 10.5)
	foe.cell = Vector2i(10, 90)                     # 80 格外的目标（**远超 64 格上限**）
	print("      目标在 %d 格外（曼哈顿）" % (absi(cart.cell.x - foe.cell.x) + absi(cart.cell.y - foe.cell.y)))
	foe.visual.position = Vector3(10.5, foe.visual.position.y, 90.5)
	s.active = cart
	s.clear_projectiles()
	# ⚠ 必须用**【锁定齐射】**（`_lunchbox_salvo_locked`，**不夹射程**）才验得到 64 格消失；
	#   普通齐射把 `dist` 夹在 `SALVO_RANGE`(24) 内，子弹根本飞不到 64。
	s._lunchbox_salvo_locked(cart, GridMath.unit_pos(foe), foe)
	var g := 0
	while s.field.items.is_empty() and g < 600:
		await process_frame
		g += 1
	_ok(not s.field.items.is_empty(), "子弹已出膛")
	# 数一数：先记录出膛总数，再让它们飞到底
	var max_flown := 0.0
	var alive_after := -1
	var guard := 0
	while guard < 4000:
		await process_frame
		guard += 1
		var any := false
		for it in s.field.items:
			var p: Projectile = it["p"]
			if not p.is_bullet_class():
				continue
			any = true
			max_flown = maxf(max_flown, p.flown_dist())
			# 任何一发都不该飞过 64 格
			if p.flown_dist() > Damage.BULLET_MAX_DIST + 1.0:
				_ok(false, "有子弹飞过了 64 格（%.1f）" % p.flown_dist())
				return
		if not any:
			alive_after = 0
			break
	print("      跟踪中：最远已飞 %.1f 格（上限 %.1f）｜ 场上剩余子弹 %d" % [
		max_flown, Damage.BULLET_MAX_DIST, alive_after])
	_ok(max_flown <= Damage.BULLET_MAX_DIST + 1.0,
		"**没有子弹飞过 64 格**（最远 %.1f）" % max_flown)
	_ok(max_flown > 30.0, "子弹确实飞了很远（%.1f 格）—— 说明射程外真的打出去了" % max_flown)

	print("\n── 子弹衰减/消失探针：%d 项检查，失败 %d 项 ──" % [_n, _f])
