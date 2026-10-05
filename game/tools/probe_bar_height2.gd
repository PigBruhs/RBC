# 第 109 轮：验证 `max_height()` **真的**把"炮管扫掠顶"计进去了（修正版）
#
# ⚠ 上一版探针测错了对象：`_measure_top()` 量的是**全模型**顶，而现在**发射器(3.49)与立柱(3.10)**
#   都远高于炮管，把炮管的变化完全淹没了 —— 所以"仰起 60° 更高"这个变化根本看不见。
#   正确做法：**单独量炮塔子树**，并且在验证钩子时把发射器**和立柱一起**移开。
extends SceneTree

var _fails := 0
var _checks := 0


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  PASS  ", what)
	else:
		_fails += 1
		print("  FAIL  ", what)


## 只量**炮塔子树**（`_turret` 及其后代）的最高点 —— 排除车体/轮子/发射器/立柱
func _turret_top(m: LunchboxModel) -> float:
	var top := 0.0
	for mi in m._meshes(m.t_traverse()):
		var t := Transform3D.IDENTITY
		var n: Node = mi
		while n != null and n != m:
			t = (n as Node3D).transform * t
			n = n.get_parent()
		var aabb: AABB = (mi as MeshInstance3D).get_aabb()
		for k in 8:
			var y: float = (t * aabb.get_endpoint(k)).y
			if y > top:
				top = y
	return top


func _initialize() -> void:
	_run()
	quit(1 if _fails > 0 else 0)


func _run() -> void:
	var m := LunchboxModel.new()
	root.add_child(m)
	m.build()          # build() 是同步的（Node3D 进树后 transform 立即可用）

	print("[1] 炮塔子树：0° vs 60° 的**真实**最高点（排除发射器/立柱）")
	var t0 := _turret_top(m)
	m.set_aim(90.0, 60.0)
	var t60 := _turret_top(m)
	m.set_aim(90.0, 0.0)
	print("      phi=0°  炮塔子树顶 = %.3f" % t0)
	print("      phi=60° 炮塔子树顶 = %.3f" % t60)
	_ok(t60 > t0 + 0.3, "炮管仰起确实更高（60° 比 0° 高 %.3f）" % (t60 - t0))
	_ok(absf(t0 - 2.34) < 0.06, "0° 时 ≈ 2.34（TURRET_Y 2.0 + PRISM_R 0.34，实际 %.3f）" % t0)
	_ok(absf(t60 - 2.956) < 0.10, "60° 时 ≈ 2.956（实际 %.3f）" % t60)

	print("\n[2] ★ 把发射器**与立柱/支臂**都移开（只剩车体+炮塔），验证钩子真的算炮管扫掠顶")
	# 立柱是 3.10 -> 不移开的话它又会淹没炮管
	var root_pos: Vector3 = m.t_loiter_root().position
	m.t_loiter_root().position = Vector3(0.0, -50.0, 0.0)
	var post := m.get_node_or_null("BodyRoot/LoiterPost") as Node3D
	var arm := m.get_node_or_null("BodyRoot/LoiterArm") as Node3D
	var post_saved := Vector3.ZERO
	var arm_saved := Vector3.ZERO
	if post != null:
		post_saved = post.position
		post.position = Vector3(0.0, -50.0, 0.0)
	if arm != null:
		arm_saved = arm.position
		arm.position = Vector3(0.0, -50.0, 0.0)
	print("      找到 LoiterPost=%s ｜ LoiterArm=%s" % [str(post != null), str(arm != null)])

	m.set_aim(90.0, 0.0)                       # 炮管回水平（最不利姿态）
	var cur_level: float = m._measure_top()
	var swept: float = m.max_height()
	print("      当前姿态顶 = %.3f ｜ max_height() = %.3f" % [cur_level, swept])
	_ok(cur_level < 2.5, "当前姿态顶掉到炮管高度（%.3f）" % cur_level)
	_ok(swept >= 2.95,
		"★ **max_height() 仍报 >= 2.95**（实际 %.3f）—— 炮管扫掠顶真被算进去了" % swept)
	_ok(swept > cur_level + 0.3,
		"★ 且**明显高于当前姿态**（%.3f > %.3f）—— 不是靠当前位置蒙对的" % [swept, cur_level])

	print("\n[3] 反面：旧算法（只量一次）会漏掉仰起的炮管")
	_ok(cur_level < 2.95,
		"旧算法在发射器低于炮管时会报 %.3f < 2.956 -> 会被仰起的炮管顶到" % cur_level)

	print("\n[4] 还原 + 量姿态不变")
	m.t_loiter_root().position = root_pos
	if post != null:
		post.position = post_saved
	if arm != null:
		arm.position = arm_saved
	m.set_aim(37.0, 25.0)
	var b: Vector3 = m.t_elevation().rotation_degrees
	var t: Vector3 = m.t_traverse().rotation_degrees
	m.max_height()
	_ok(b.is_equal_approx(m.t_elevation().rotation_degrees)
		and t.is_equal_approx(m.t_traverse().rotation_degrees),
		"量完姿态不变（traverse=%s elevation=%s）" % [
			str(m.t_traverse().rotation_degrees), str(m.t_elevation().rotation_degrees)])

	print("\n── max_height 有效性探针：%d 项检查，失败 %d 项 ──" % [_checks, _fails])
