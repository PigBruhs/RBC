# 独立复核：子弹地板碰撞的 75/25 概率（第 108 轮 task-35）
#
# ⚠ 为什么要复核：docs-keeper 的 1000 发样本给出 27.1% : 72.9%（期望 25 : 75）。
#   1000 发样本的 2σ 约 ±2.7%，27.1% 落在边缘；而且他脚本里还有一处除错 1000 倍的笔误，
#   所以我要**自己用大样本 + 直接读 RngService**再测一遍。
extends SceneTree

var _s: Node
var _fails := 0
var _checks := 0


func _ok(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("  PASS  ", label)
	else:
		_fails += 1
		print("  FAIL  ", label)


func _initialize() -> void:
	Level.current = "field"
	_s = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(_s)
	for i in 8:
		await process_frame
	_run()
	quit(1 if _fails > 0 else 0)


func _run() -> void:
	print("[1] 概率：**直接读注入的随机流**，与场里的判定阈值同源")
	# 场里用的是注入进来的 rng；这里拿同一个对象来复现它的判定
	var rng: RngService = _s.field.floor_rng
	if rng == null:
		_ok(false, "field.floor_rng 已注入（battle_scene 传了第 4 参）")
		return
	_ok(true, "field.floor_rng 已注入")
	_ok(is_same(rng, _s.rng), "注入的就是场景的 rng（同种子可复现）")

	# 阈值：反弹 = next_float() < (1 - VANISH)。统计 next_float 的超阈比例即可判定阈值是否 0.25。
	const N := 200000
	var bounce := 0
	for i in N:
		if rng.next_float() < (1.0 - Projectile.FLOOR_VANISH_CHANCE):
			bounce += 1
	var rate := float(bounce) / float(N)
	# 用另一个独立随机流复核"阈值本身"是不是 0.25（避免被同一个流的自相关骗到）
	var rng2 := RngService.new(987654321)
	var bounce2 := 0
	for i in N:
		if rng2.next_float() < (1.0 - Projectile.FLOOR_VANISH_CHANCE):
			bounce2 += 1
	var rate2 := float(bounce2) / float(N)
	print("      VANISH = %.4f（期望 0.75）｜ 反弹阈值 = %.4f（期望 0.25）" % [
		Projectile.FLOOR_VANISH_CHANCE, 1.0 - Projectile.FLOOR_VANISH_CHANCE])
	print("      独立流 A（场景 rng，%d 次）：反弹 %d = **%.3f%%**" % [N, bounce, rate * 100.0])
	print("      独立流 B（另一个种子）：反弹 %d = **%.3f%%**" % [bounce2, rate2 * 100.0])
	# 200000 次样本的 2σ ≈ 0.19%，所以 24.8~25.2 才算真的命中
	_ok(absf(rate - 0.25) < 0.003, "流 A 反弹比例 ≈ 25%%（实测 %.3f%%）" % (rate * 100.0))
	_ok(absf(rate2 - 0.25) < 0.003, "流 B 反弹比例 ≈ 25%%（实测 %.3f%%）" % (rate2 * 100.0))
	_ok(absf(Projectile.FLOOR_VANISH_CHANCE - 0.75) < 1e-9, "消失概率常量 = 0.75")

	print("\n[2] 端到端：真的打一发向下俯冲的子弹穿过地板，统计它 vanish 还是 bounce")
	var b := 0
	var v := 0
	const M := 4000
	for i in M:
		var p := _make_diving_bullet()
		if p == null:
			_ok(false, "造的出俯冲子弹")
			return
		# 推进到穿地
		var guard := 0
		while p.alive and guard < 600:
			_s.field.step(1.0 / 60.0)
			guard += 1
		if p.bounces > 0:
			b += 1
		else:
			v += 1
		# 清场，避免累积
		_s.clear_projectiles()
	var rate3 := float(b) / float(M)
	print("      %d 发里：反弹 %d ｜ 消失 %d -> **%.2f%% : %.2f%%**" % [
		M, b, v, rate3 * 100.0, (1.0 - rate3) * 100.0])
	_ok(absf(rate3 - 0.25) < 0.02, "端到端反弹比例 ≈ 25%%（实测 %.2f%%）" % (rate3 * 100.0))

	print("\n[3] 反弹上限 = 1（再撞地必消失）")
	_ok(Projectile.FLOOR_MAX_BOUNCES == 1, "FLOOR_MAX_BOUNCES = 1（实际 %d）" % Projectile.FLOOR_MAX_BOUNCES)


## 造一发"高打低、会穿地"的子弹：从高处斜向下，保证 y 会穿过 0
func _make_diving_bullet() -> Projectile:
	var u: Unit = null
	for x in _s.units:
		if x != null and x.is_alive():
			u = x
			break
	if u == null:
		return null
	# 起点 (5,8)，瞄准点在地板以下远处 -> 弹道向下穿过 y=0
	var p := Ordnance.make_bullet_at(u, Vector3(5.0, 6.0, 5.0), Vector3(20.0, -12.0, 5.0), false)
	_s.field.register(p)
	return p
