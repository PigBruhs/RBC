# 第 111 轮：瞄准点是**点的那一格**，不是大单位的**锚点格**
# 用户口径：「为什么雷达锁定 Reaper 后齐射车瞄准的总是 Reaper 标定的格子
#   （瞄准时紫色的那个）**左斜边一格**？……你看能不能改到**选目标时瞄准的那一格**上」
# 根因：`attack_target_unit` 原来一律用 `t.cell`（单位自己的锚点格）。
#   Reaper 是多格大单位，锚点格 ≠ 玩家点的那一格 -> 瞄准点整体偏一格。
# 本探针在 **reaper 关**里量：点的格与锚点格**角度不同**时，实际对准的是哪一个。
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
	print("      Reaper 体半径 = %.2f（普通角色 0.3）" % Targeting.unit_body_r(big))

	# 把车放在 Reaper 的**斜下方**，这样"锚点格"与"邻格"的角度差最明显
	cart.cell = Vector2i(20, 20)
	cart.visual.position = Vector3(20.5, cart.visual.position.y, 20.5)
	big.cell = Vector2i(30, 30)
	big.visual.position = Vector3(30.5, big.visual.position.y, 30.5)
	var anchor := GridMath.cell_center(big.cell)
	var click_cell := Vector2i(30, 31)                 # 锚点的**邻格**
	var clicked := GridMath.cell_center(click_cell)
	var base: Vector2 = s._lb_origin(cart)
	var ang_anchor := rad_to_deg((anchor - base).angle())
	var ang_clicked := rad_to_deg((clicked - base).angle())
	print("      锚点格中心 %s（%.2f°）｜ 点的格中心 %s（%.2f°）｜ 差 %.2f°" % [
		str(anchor), ang_anchor, str(clicked), ang_clicked, absf(ang_clicked - ang_anchor)])
	_ok(absf(ang_clicked - ang_anchor) > 0.5,
		"**两格角度确实不同**（差 %.2f° > 0.5°）—— 这条断言才有意义" % absf(ang_clicked - ang_anchor))

	s.active = cart
	cart.has_acted = false
	s.clear_projectiles()
	var logs0: int = s.t_debug_log().size()
	s.attack.attack_target_unit(big, false, click_cell)
	await process_frame
	var lg: Array[String] = s.t_debug_log()
	var line := ""
	for i in range(logs0, lg.size()):
		# 普通齐射写「中轴 X°」，锁定齐射写「对准 X°」—— 两种都认
		if lg[i].find("中轴 ") >= 0 or lg[i].find("对准 ") >= 0:
			line = lg[i]
			break
	print("      日志：%s" % line)
	var k := line.find("对准 ")
	if k < 0:
		k = line.find("中轴 ")
	_ok(k >= 0, "日志里有角度读数")
	if k >= 0:
		# ⚠ 抠角度不能靠**固定偏移**（"中轴" 与 "对准" 长度不同 —— 第一版就是这里错了，
		#   把 46.4° 读成了 10.00°）。改成：从标记往后取**第一段连续数字**。
		var tail := line.substr(k)
		var num := ""
		for ch in tail:
			if ch == "-" or ch == "." or (ch >= "0" and ch <= "9"):
				num += ch
			elif num != "":
				break
		var got := float(num)
		print("      实际对准 = %.2f°" % got)
		_ok(absf(got - ang_clicked) < 0.6,
			"**对准的是点的那一格**（%.2f° ≈ %.2f°）" % [got, ang_clicked])
		_ok(absf(got - ang_anchor) > 0.4,
			"**不是单位的锚点格**（锚点格是 %.2f°，差 %.2f°）" % [
				ang_anchor, absf(got - ang_anchor)])

	print("\n── 瞄准点=点击格 探针：%d 项检查，失败 %d 项 ──" % [_n, _f])
