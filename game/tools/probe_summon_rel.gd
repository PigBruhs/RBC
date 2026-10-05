# 第 109 轮：Reaper **移动后**召唤点是否仍然跟着它走（用户口径）
#   「别忘了 Reaper **会移动**，所以召唤点也应该是**相对于 Reaper 所在格**的，
#     否则仍然会出现召唤在 Reaper 内部的情况」
#
# ⚠ 这条是**回归钉子**：实现看起来已经是相对的（`reaper.cell + Vector2i(dx, dy)`），
#   但"看起来对"不等于"移动后也对" —— 所以真把 Reaper 挪几个位置再量。
extends SceneTree

var _s: Node
var _fails := 0
var _checks := 0


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  PASS  ", what)
	else:
		_fails += 1
		print("  FAIL  ", what)


func _initialize() -> void:
	Level.current = "reaper"
	_s = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(_s)
	for i in 8:
		await process_frame
	_run()
	quit(1 if _fails > 0 else 0)


func _run() -> void:
	var rp: Unit = null
	for u in _s.units:
		if u != null and u.name == "Reaper":
			rp = u
			break
	_ok(rp != null, "场上找到 Reaper")
	if rp == null:
		return
	var br: float = Targeting.unit_body_r(rp)
	print("      Reaper 初始格 %s ｜ body_r = %.1f" % [str(rp.cell), br])

	# 把它挪到几个不同位置（含贴边、含换象限），每次核对落点仍在体外
	var spots: Array[Vector2i] = [
		Vector2i(36, 60), Vector2i(20, 30), Vector2i(10, 10),
		Vector2i(5, 55), Vector2i(35, 5), Vector2i(20, 60),
	]
	var worst := 999.0
	var worst_at := ""
	var inside := 0
	var total := 0
	for c in spots:
		rp.cell = c
		rp.visual.position = Vector3(float(c.x) + 0.5, rp.visual.position.y, float(c.y) + 0.5)
		var cells: Array[Vector2i] = Reaper.summon_cells(rp, _s.units, 3)
		var ds: Array = []
		for sc in cells:
			total += 1
			# 落点到 **Reaper 当前格中心** 的欧氏距离（最保守的"在不在体内"判据）
			var d := Vector2(float(sc.x - c.x), float(sc.y - c.y)).length()
			ds.append("%s=%.2f" % [str(sc), d])
			if d <= br:
				inside += 1
			if d < worst:
				worst = d
				worst_at = str(c)
		print("      Reaper @ %-9s -> 落点 %s ｜ 中心距 %s" % [
			str(c), str(cells), ", ".join(ds)])
	_ok(inside == 0, "**全部 %d 个落点都在体外**（落在半径 %.1f 内的有 %d 个）" % [total, br, inside])
	_ok(worst > br, "最小中心距 %.2f > body_r %.1f（出现在 Reaper @ %s）" % [worst, br, worst_at])

	# 关键回归：**落点是相对当前格的** —— 同一个 Reaper 在两个不同格，
	# 算出来的落点必须跟着平移，而不是固定在某个绝对格
	rp.cell = Vector2i(20, 30)
	var a: Array[Vector2i] = Reaper.summon_cells(rp, _s.units, 3)
	rp.cell = Vector2i(20, 40)          # 只沿 y 挪 10 格
	var b: Array[Vector2i] = Reaper.summon_cells(rp, _s.units, 3)
	var shifted := true
	if a.size() == b.size() and a.size() > 0:
		var d0 := b[0] - a[0]
		for i in a.size():
			if (b[i] - a[i]) != d0:
				shifted = false
		print("      相对性验证：@(20,30) -> %s ｜ @(20,40) -> %s ｜ 平移量 = %s" % [
			str(a), str(b), str(d0)])
		_ok(shifted and d0 == Vector2i(0, 10),
			"**落点严格跟随 Reaper 平移**（整体平移 %s，不是固定在绝对格）" % str(d0))
	else:
		_ok(false, "两次召唤都返回了落点（a=%d b=%d）" % [a.size(), b.size()])

	print("\n── Reaper 召唤点相对性探针：%d 项检查，失败 %d 项 ──" % [_checks, _fails])
