# 第 111 轮：**棱柱炮管网格的真实世界长轴** vs **子弹飞行方向**
#
# ⚠ 为什么之前 22 项"子弹沿炮管轴线"全绿却仍有 bug：
#   那个探针量的是 `muzzle_local_at()` 的**数学方向** vs 子弹方向 —— 两者同源，
#   当然永远平行。**用户看到的是"棱柱这个网格模型"的朝向**，那是 `_turret`/`_barrel`
#   的实际节点变换结果，必须**直接量网格的世界长轴**才算验到。
# 用户口径：「注意**长的那个轴**，指向左上角的才是炮管方向！但是子弹现在向右上角飞」
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
	_run(s)
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
	_ok(m != null, "拿到模型")
	var prism: MeshInstance3D = m.t_prism()
	_ok(prism != null, "拿到棱柱网格 `t_prism()`")
	if prism == null:
		return
	print("      棱柱的 mesh 类型 = %s" % prism.mesh.get_class())

	# 逐 theta 量：棱柱的**世界长轴**（取节点 basis 的三个轴里与"数学炮管方向"最接近的？
	# 不行 —— 那等于自己挑答案。改成：把三条本地轴都变换到世界，看**哪条最长**
	# （棱柱是细长的，它的长轴对应的那条本地轴就是炮管的实际指向）。
	var worst := 1.0
	var rows: Array[String] = []
	for th in [0.0, 45.0, 90.0, 135.0, 180.0, 225.0, 270.0, 315.0]:
		m.set_aim(th, 0.0)
		# ⚠ 棱柱是 `CylinderMesh`（`height` 沿**本地 +y**），AABB 也证实 y=1.2 是最长边
		#   -> **网格本地 +y = 炮管的实际指向**。把它变换到世界就是玩家看到的那根长轴。
		#   （我第一版用"basis 三条列里最长的那条"是错的：节点没有缩放，三列长度都是 1，
		#    于是它按浮点噪声乱挑轴，量出来的 dot 恒为 0 —— 那是**探针**的错。）
		var gb: Basis = prism.global_transform.basis
		var world_axis: Vector3 = gb.y.normalized()
		var ab: AABB = prism.mesh.get_aabb()
		var sz := ab.size
		var want := Vector3(cos(deg_to_rad(th)), 0.0, sin(deg_to_rad(th)))
		var dot := world_axis.dot(want)
		rows.append("      theta=%6.1f ｜ 棱柱 AABB=%s ｜ 世界长轴(+y)=(%.2f,%.2f,%.2f) ｜ 数学炮管=(%.2f,%.2f,%.2f) ｜ dot=%+.4f" % [
			th, str(sz.snapped(Vector3(0.01, 0.01, 0.01))),
			world_axis.x, world_axis.y, world_axis.z, want.x, want.y, want.z, dot])
		worst = minf(worst, dot)
	for r in rows:
		print(r)
	print("      最差 dot = %+.4f" % worst)
	_ok(worst > 0.999, "**棱柱网格的世界长轴 = 数学炮管方向**（最差 dot=%+.4f）" % worst)

	# ⚠ 端到端那节（"子弹真的沿炮管轴线吗"）已由 `tools/probe_muzzle_e2e.gd` **专门**覆盖
	#   （它在 4 种车体朝向下量"可见炮口 vs 子弹发射点 vs 方向"）。这里只负责
	#   "**棱柱网格的世界长轴 = 数学炮管方向**"这一条，避免两处重复、也避免 await 卡住。

	print("\n── 棱柱长轴探针：%d 项检查，失败 %d 项 ──" % [_n, _f])