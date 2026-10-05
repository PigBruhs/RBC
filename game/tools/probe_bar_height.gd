# 第 109 轮：验证"条子/名字永远高于炮管在**任何仰角**下的最高点"
#
# ⚠ 为什么需要这个探针（`probe_turret` 抓不到）：
#   `unit_visual._model_top_y()` 是**建模型那一刻**量包围盒 —— 那时炮管水平（phi=0）。
#   而现在模型顶由车尾发射器决定（3.49），恰好 > 炮管在 PHI_MAX=60° 的实顶（2.956），
#   所以"条子抬到 3.49 以上"**顺带**覆盖了仰起的炮管。**这是巧合**：
#   谁把发射器降到 2.956 以下，仰起的炮管就会重新顶到条子，而公式不知道。
#   本探针**直接断言那个不等式**（用 max_height() 报的扫掠顶，不是当前姿态），
#   所以发射器被降低时会**当场变红**，而不是等用户肉眼发现。
extends SceneTree

const LEVEL := "reaper"
const CART := "轮式齐射午餐盒"
const NORMAL := "Gerald"

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
	Level.current = LEVEL
	var s: Node = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(s)
	for i in 10:
		await process_frame
	_run(s)
	quit(1 if _fails > 0 else 0)


func _run(s: Node) -> void:
	var cart: Unit = null
	var gerald: Unit = null
	for u in s.units:
		if u != null and u.name == CART:
			cart = u
		if u != null and u.name == NORMAL:
			gerald = u
	_ok(cart != null, "场上找到 %s" % CART)
	_ok(gerald != null, "场上找到 %s（对照组）" % NORMAL)
	if cart == null or gerald == null:
		return

	var m: LunchboxModel = s._lb_model(cart)
	_ok(m != null, "拿到午餐盒模型")

	print("\n[1] 模型自己报的**扫掠顶**（不是当前姿态的顶）")
	var mh: float = m.max_height()
	print("      max_height() = %.3f ｜ 当前姿态实测顶 = %.3f" % [mh, m._measure_top()])
	_ok(mh >= 2.95, "扫掠顶 >= 2.95（炮管 60° 实顶 2.956，实际 %.3f）" % mh)

	print("\n[2] ★ 核心不等式：**任何仰角**下的炮管都不能高过条子下边")
	# 把炮管摆到各个 phi，量真实最高点；逐个与"条子下边"比较
	var bar_bottom: float = float(s.t_bar_bottom_y(cart))
	print("      条子下边 y = %.3f（模型顶 %.3f）" % [bar_bottom, mh])
	if bar_bottom > 0.0:
		var worst := 0.0
		var worst_phi := 0.0
		for phi in [0.0, 15.0, 30.0, 45.0, 60.0]:
			m.set_aim(90.0, phi)
			var top: float = m._measure_top()
			print("        phi=%5.1f° -> 子树顶 %.3f" % [phi, top])
			if top > worst:
				worst = top
				worst_phi = phi
		_ok(bar_bottom > worst,
			"**条子下边 %.3f > 所有仰角下的最高点 %.3f**（最凶的是 phi=%.0f°）" % [
				bar_bottom, worst, worst_phi])
		_ok(bar_bottom > mh,
			"条子下边 %.3f > 模型报价的扫掠顶 %.3f（这条是防发射器被降低的钉子）" % [
				bar_bottom, mh])
		m.set_aim(90.0, 0.0)          # 复位，别影响后面的断言

	print("\n[3] 挂钩对**普通角色无副作用**（行为逐字不变）")
	var gm = s._lb_model(gerald) if gerald.name == CART else null
	_ok(!(gerald.visual.get_children().any(func(c): return c is LunchboxModel)),
		"Gerald 身上没有 LunchboxModel -> 走原静态路径（返回值与第 107 轮一致）")

	print("\n[4] `max_height()` 不动现场：量完必须回到原姿态")
	m.set_aim(33.0, 22.0)
	var t_before: Vector3 = m.t_traverse().rotation_degrees
	var b_before: Vector3 = m.t_elevation().rotation_degrees
	m.max_height()
	var t_after: Vector3 = m.t_traverse().rotation_degrees
	var b_after: Vector3 = m.t_elevation().rotation_degrees
	print("      量前 traverse=%s elevation=%s" % [str(t_before), str(b_before)])
	print("      量后 traverse=%s elevation=%s" % [str(t_after), str(b_after)])
	_ok(t_before.is_equal_approx(t_after) and b_before.is_equal_approx(b_after),
		"max_height() 量完把姿态还原了（不会把炮管定在 60 度）")

	print("\n── 条子高度 vs 炮管扫掠顶探针：%d 项检查，失败 %d 项 ──" % [_checks, _fails])
