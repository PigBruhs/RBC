# 第 111 轮：**白色烟雾拖尾**（用户口径：「火箭经过的轨迹上要出现白色烟雾，
# 逐渐变淡**两秒**散去」）
extends SceneTree

const LEVEL := "arena"
const HELI := "俯冲轰炸直升机（不要问那么多）"

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
	var heli: Unit = null
	for u in s.units:
		if u != null and u.name == HELI:
			heli = u
			break
	_ok(heli != null, "找到直升机（发火箭的）")
	if heli == null:
		return

	print("\n[1] 模块独立行为：冒烟 / 变淡 / 两秒散去")
	var tr := SmokeTrail.make(s)
	_ok(tr.t_pool() > 0, "对象池已建（%d 个）" % tr.t_pool())
	_ok(absf(tr.t_life_const() - 2.0) < 1e-6, "**寿命 = 2.0 秒（用户口径）**")
	# 1 秒里按 60fps 喂一个固定发射点 -> 应当冒出一批
	var p0 := Vector3(10.0, 2.0, 10.0)
	for i in 60:
		tr.step(1.0 / 60.0, [p0])
	var live1 := tr.t_live_count()
	print("      1 秒后：活着的烟雾 = %d ｜ 最浓 alpha = %.3f ｜ 最淡 alpha = %.3f" % [
		live1, tr.t_max_alpha(), tr.t_min_alpha_live()])
	_ok(live1 > 5, "**沿轨迹持续冒烟**（1 秒冒出 %d 颗）" % live1)
	_ok(tr.t_max_alpha() > 0.4, "新冒的烟是**白色且较浓**（alpha %.3f）" % tr.t_max_alpha())
	_ok(tr.t_min_alpha_live() < tr.t_max_alpha() - 0.1,
		"**同一条轨迹上浓度不同 = 在逐渐变淡**（%.3f < %.3f）" % [
			tr.t_min_alpha_live(), tr.t_max_alpha()])
	# 停止发射，等 2.1 秒 -> 应当全部散尽
	for i in 126:
		tr.step(1.0 / 60.0, [])
	print("      停止发射并等 2.1 秒：活着的烟雾 = %d" % tr.t_live_count())
	_ok(tr.t_live_count() == 0, "**两秒后全部散去**（剩 %d 颗）" % tr.t_live_count())
	tr.queue_free()

	print("\n[2] 场景接线：**火箭飞过就冒烟**")
	# 造一发火箭，让它真的被 `field.step` 推进，看烟雾是否跟着出现
	heli.cell = Vector2i(12, 12)
	heli.visual.position = Vector3(12.5, heli.hover, 12.5)
	s.clear_projectiles()
	var from := Vector3(12.5, heli.hover + 0.5, 12.5)
	var rp := Ordnance.make_rocket(heli, from, Vector2(12.5, 30.5), false, s.rng)
	s.field.register(rp)
	# ⚠ **不要 await 真实帧**：arena 里打下去会判胜负 -> 游戏自己 `quit()`，
	#   把探针在半路掐断（这个坑在 `probe_ai_menu` 也踩过）。改成**手动驱动**两步：
	#   `field.step` 推进弹道 + `_tick_smoke` 推进烟雾。
	for i in 90:
		s.field.step(1.0 / 60.0)
		s._tick_smoke(1.0 / 60.0)
	_ok(s._smoke != null and is_instance_valid(s._smoke), "场景里已建出 `SmokeTrail`")
	var live2: int = s._smoke.t_live_count() if s._smoke != null else -1
	print("      火箭飞了 1.5 秒 ｜ 场上烟雾 = %d ｜ 火箭还在飞 = %s" % [
		live2, str(rp.alive)])
	_ok(live2 > 3, "**火箭经过的轨迹上出现了烟雾**（%d 颗）" % live2)

	print("\n[3] 没有火箭时不冒烟（池不空转）")
	s.clear_projectiles()
	for i in 200:
		s._tick_smoke(1.0 / 60.0)
	print("      清空火箭并等 3.3 秒：场上烟雾 = %d" % s._smoke.t_live_count())
	_ok(s._smoke.t_live_count() == 0, "**没有火箭时烟雾会全部散尽**（剩 %d）" % s._smoke.t_live_count())

	print("\n── 烟雾拖尾探针：%d 项检查，失败 %d 项 ──" % [_n, _f])
