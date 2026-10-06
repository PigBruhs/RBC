# 第 111 轮：**子弹是否沿炮管轴线飞出**（用户报"又坏了"）
# 在**真实场景**里量：炮管的世界轴线 vs 子弹的世界速度方向。分别在
#   ① 车体朝向 = 默认（yaw 90）② 车体朝另一方向（yaw 0，走动后）两种情况下测。
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
		if u != null and u.name == "轮式齐射午餐车" or (u != null and u.name == "轮式齐射午餐盒"):
			cart = u
			break
	_ok(cart != null, "找到轮式齐射午餐盒")
	if cart == null:
		return
	var m: LunchboxModel = s._lb_model(cart)
	_ok(m != null, "拿到模型")

	for yaw in [90.0, 0.0, 180.0, 270.0]:
		m.set_body_yaw(yaw)
		for th in [0.0, 45.0, 90.0, 180.0, 270.0]:
			# ⚠ 必须同时设**场景的 aim 状态**（`_lb_muzzle` 读的是它，不是模型的）
			var st: Dictionary = s._lb_state(cart)
			(st["aim"] as Lunchbox.Aim).theta = th
			(st["aim"] as Lunchbox.Aim).phi = 0.0
			m.set_aim(th, 0.0)
			# 炮管中轴线（世界）：`muzzle_local_at` 的公式就是"世界对齐"的模型本地方向
			var ml: Vector3 = m.muzzle_local_at(th, 0.0)
			var pivot := Vector3(LunchboxModel.TURRET_X, LunchboxModel.TURRET_Y, 0.0)
			var barrel_axis: Vector3 = (ml - pivot).normalized()
			# 子弹方向：`_lb_fire_wave` 用的那一套
			# ⚠ 瞄准点高度与炮管**同高**（TURRET_Y），否则 phi=0 的炮管 vs 向下瞄的弹道
			#   天然有个小夹角（第一次跑探针时 dot=0.987 就是这么来的，不是 bug）
			# ⚠ 第 111 轮：生产代码的基准已统一到 `_lb_origin`（模型根），探针必须跟着改，
			#   否则量的是"旧口径 vs 新口径"，必然不平行。
			var base: Vector2 = s._lb_origin(cart)
			var dir := Vector2(cos(deg_to_rad(th)), sin(deg_to_rad(th)))
			var aim3 := Vector3(base.x + dir.x * 12.0, LunchboxModel.TURRET_Y,
				base.y + dir.y * 12.0)
			var from: Vector3 = s._lb_muzzle(cart, st)
			var shot_dir: Vector3 = (aim3 - from).normalized()
			var dot: float = barrel_axis.dot(shot_dir)
			print("      yaw=%5.1f theta=%5.1f ｜ dot=%+.4f ｜ from=(%.2f,%.1f,%.2f) ｜ 与base水平差=%.2f 格" % [
				yaw, th, dot, from.x, from.y, from.z,
				Vector2(base.x, base.y).distance_to(Vector2(from.x, from.z))])
			_ok(dot > 0.999, "**yaw=%.0f° theta=%.0f°：子弹沿炮管轴线**（dot=%.4f）" % [yaw, th, dot])

	print("\n── 子弹沿炮管轴线探针：%d 项检查，失败 %d 项 ──" % [_n, _f])
