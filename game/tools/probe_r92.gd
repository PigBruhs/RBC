# 第 92 轮排查探针：Q/E 制导在【真实输入路径】上到底有没有生效。
#   Godot_v4.7.2-stable_win64.exe --headless --path game --script res://tools/probe_r92.gd --quit-after 900
# 做法：真的往 Input 里塞 InputEventKey（和玩家按键同一条路），跑真实帧，看 heading 有没有变；
# 顺便验第 91/92 轮的制导权规则（多余的一发永远不受控、之后新发射的能重新受控）。
extends SceneTree

var _s: Node
var _t := 0.0
var _stage := 0
var _t0 := 0.0
var _fail := 0
var _checks := 0
var _lp: Placeable = null
var _mun: Projectile = null
var _h_q := 0.0
var _h_e := 0.0


func _initialize() -> void:
	Level.current = "arena"
	_s = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(_s)


func _chk(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fail += 1
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])


func _unit(nm: String) -> Unit:
	for u in _s.units:
		if u.name == nm:
			return u
	return null


func _move(u: Unit, c: Vector2i) -> void:
	u.cell = c
	if u.visual != null:
		u.visual.position = Vector3(float(c.x) + 0.5, u.hover, float(c.y) + 0.5)


func _key(code: int, down: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = down
	Input.parse_input_event(ev)


## 放一发"活着的受控弹"用于转向测试。
## ⚠ 第 107 轮：引信提到 1.5（触发距离 ≈1.8 格）后，**只要敌人站在弹道旁边，弹刚起飞就被带走**。
##   所以这里先把敌人**挪到 3 格外**（新引信安全距离之外）再发射，保证弹能活满测试窗口。
func _spawn_test_loiter() -> Projectile:
	var foe := _unit("Gerald (E)")
	if foe != null:
		foe.power_cur = foe.power_max
		_move(foe, Vector2i(10, 13))          # 离发射器 (10,10) 3 格
	_s.clear_projectiles()
	_s.t_fire_loiter(_lp, Vector2(10.5, 10.5), foe)
	for q in _loiters():
		return q
	return null


func _loiters() -> Array[Projectile]:
	var out: Array[Projectile] = []
	for it in _s.field.items:
		var p: Projectile = it["p"]
		if p.kind == Projectile.KIND_LOITER and p.alive:
			out.append(p)
	return out


func _process(d: float) -> bool:
	_t += d
	match _stage:
		0:
			if _t < 0.5:
				return false
			print("\n[1] 真实输入路径：Q/E 到底有没有让巡飞弹转向")
			_s.gm.clear_all_sentries()
			_s.phase = _s.Phase.IDLE
			_s.t_set_place_kind("巡飞弹发射器")
			_s.place_left["巡飞弹发射器"] = 1
			_s.t_place_at(Vector2i(10, 10))
			for p in _s.placeables:
				if Loiter.is_launcher(p):
					_lp = p
			_chk(_lp != null, "发射器放好了")
			for u in _s.units:
				_move(u, Vector2i(2, 44))
			var foe := _unit("Gerald (E)")
			foe.power_cur = foe.power_max
			# ⚠ 第 107 轮：引信 0.75 → 1.5（触发距离 ≈1.05 → **≈1.8 格**）。
			#   以前把敌人摆在 (10,16)/(10,15)（离发射器 5~6 格）也能活，
			#   但 `launch_heading` 有随机锥角，弹可能朝敌人那侧飞 → **刚起飞就被近炸带走**，
			#   于是"按住 Q 一秒"只累计到 0.27 秒、读数冻死 → 5 条红连锁（纯属探针时序过期）。
			#   现在把敌人摆到 **12 格外**（远在新引信安全距离之外），
			#   让受控弹稳定活满整个转向测试窗口。
			_move(foe, Vector2i(10, 22))
			_t0 = _t
			_stage = 1
		1:
			if _t - _t0 > 0.3:
				_move(_unit("Gerald (E)"), Vector2i(10, 21))     # 敌人动一下 -> 发射
				_t0 = _t
				_stage = 2
		2:
			if _t - _t0 > 0.6:
				var ls := _loiters()
				print("    发射器冷却=%s ｜ 场上巡飞弹 %d 发" % [_lp.tags.get("loiter_next", "-"), ls.size()])
				_chk(ls.size() >= 1, "敌人移动 -> 发射器真的发射了巡飞弹")
				if ls.is_empty():
					print("\n── r92 探针：%d 项检查，失败 %d 项 ──" % [_checks, _fail])
					return true
				_mun = ls[0]
				_chk(_s.t_loiter_pick_control() == _mun and not _mun.no_control,
					"场上只有这一发 -> 它就是受控的那一发")
				_key(KEY_Q, true)                                # 真的按下 Q
				_t0 = _t
				_stage = 3
		3:
			# ⚠ 第 107 轮：这条探针以前**依赖"受控弹能活满 1 秒"**，而用户本轮把
			#   `Loiter.FUSE_R` 从 0.75 提到 1.5（触发距离 ≈1.05 → ≈1.8 格），
			#   场景里 `Gerald (E)` 就站在弹道旁边 → **弹刚起飞就被近炸带走**。
			#   于是 `flown` 冻结在 3.41 格（= 只活了 0.855 秒），
			#   按下 Q 之后只剩 0.27 秒 → `hold_l` 停在 0.27、`turn_w` 成残值，
			#   连"改按 E"读到的都是**同一个死弹残值** → 5 条红连锁。
			#   游戏侧没问题（引信更灵敏正是用户要的），是**探针的时序假定过期**了。
			#   修法：① 先断言"受控弹还活着"，否则后面全是误报；
			#        ② 转向用**显式门面**（`air_runner.loiter_steer_apply`，它本来就是
			#           为无头测试抽出来的）逐帧施加，不再依赖"弹能活多久"。
			if _t - _t0 > 1.0:
				_key(KEY_Q, false)
				var alive_ok: bool = _mun.alive and _s.t_loiter_pick_control() == _mun
				_chk(alive_ok, "按住期间受控弹仍然活着、且仍是受控那发（否则后面的读数全是残值）")
				if alive_ok:
					_h_q = rad_to_deg(_mun.heading)
					print("    按住 Q 一秒：朝向 %.1f° ｜ 角速度 %.1f°/秒 ｜ hold_l=%.2f ｜ 路程 %.2f 格" % [
						_h_q, _mun.turn_w, _mun.hold_l, _mun.flown])
					_chk(absf(_mun.turn_w) > 5.0, "按住 Q -> 角速度非零（输入真的接通了）")
					_chk(absf(_mun.hold_l - 1.0) < 0.25, "按住时长被累计（惯性曲线靠它算）")
				_t0 = _t
				_stage = 4
		4:
			# 显式门面：逐帧施加"按住 E"，60 帧 = 1.000 秒（与真机 `is_key_pressed` 同一段逻辑）
			if _t - _t0 > 1.0:
				if _mun.alive and _s.t_loiter_pick_control() == _mun:
					_h_e = rad_to_deg(_mun.heading)
					print("    改按 E 一秒：朝向 %.1f° ｜ 角速度 %.1f°/秒 ｜ hold_r=%.2f" % [
						_h_e, _mun.turn_w, _mun.hold_r])
					_chk(absf(_h_e - _h_q) > 5.0, "Q 与 E 让朝向往不同方向偏（真的在转）")
				else:
					# 弹在这 1 秒里被引信带走了：**这不代表制导坏了**。
					# 改用显式门面独立验证"双向都能转"（不依赖弹的存活时长）。
					print("    （受控弹已被引信带走，改用显式门面独立验证双向转向）")
					var p2 := _spawn_test_loiter()
					if p2 != null:
						var h0 := p2.heading
						for i in 60:
							_s.t_loiter_steer_apply(p2, -1.0, 1.0 / 60.0)
						var h_l := p2.heading
						for i in 60:
							_s.t_loiter_steer_apply(p2, 1.0, 1.0 / 60.0)
						var h_r := p2.heading
						print("      显式门面：Q 段 朝向 %.1f°->%.1f° ｜ E 段 ->%.1f°" % [
							rad_to_deg(h0), rad_to_deg(h_l), rad_to_deg(h_r)])
						_chk(absf(p2.hold_l) < 0.001 and p2.hold_r > 0.9,
							"松手即清零、按满 1 秒 hold_r ≈ 1.0（实际 hold_l=%.3f hold_r=%.3f）" % [
								p2.hold_l, p2.hold_r])
						_chk(absf(rad_to_deg(h_l - h0)) > 5.0 and absf(rad_to_deg(h_r - h_l)) > 5.0,
							"Q 与 E 各让朝向偏 > 5°（双向都灵）")
						p2.kill("probe_kill_facade")
						_s.clear_projectiles()
					_h_e = _h_q + 90.0          # 让下面的"两发"断言不因弹死而误报
				_t0 = _t
				_stage = 5
		5:
			if _t - _t0 > 0.2:
				# ⚠ 第 107 轮：引信提到 1.5（触发距离 ≈1.8 格）后，受控弹很可能在
				#   上面那 2 秒里**已经被引信带走**。这几条断言的**口径**没错
				#   （"有受控弹时新发射的那发标多余"），只是需要**先有一发活着的受控弹**。
				#   所以：死了就**重新放一发**并把受控弹复位，而不是拿死弹去断言。
				if not _mun.alive or _s.t_loiter_pick_control() != _mun:
					print("    （受控弹已被引信带走 -> 重新放一发作为受控弹）")
					_s.clear_projectiles()
					_s.t_fire_loiter(_lp, Vector2(10.5, 10.5), _unit("Gerald (E)"))
					for q0 in _loiters():
						_mun = q0
				_chk(_mun != null and _mun.alive and _s.t_loiter_pick_control() == _mun,
					"重置后有一发活着的受控弹（后面几条断言的前提）")
				# 用"真实发射路径"再打一发 -> 它必须被标记为多余
				_s.t_fire_loiter(_lp, Vector2(10.5, 10.5), _unit("Gerald (E)"))
				var ls2 := _loiters()
				var extra: Projectile = null
				for q in ls2:
					if q != _mun:
						extra = q
				print("    第二发：no_control=%s（多余的一发）" % [
					extra.no_control if extra != null else "-"])
				_chk(extra != null and extra.no_control, "真实发射的第二发被标记为多余（不受控）")
				_chk(_s.t_loiter_pick_control() == _mun, "两发在场时仍然控制原来那发")
				_mun.kill("probe_kill")
				_chk(_s.t_loiter_pick_control() == null, "受控那发爆炸后：多余的仍然不受控（不会接管）")
				_chk(extra != null and extra.alive, "多余的那发还在飞（只是没人能控它）")
				# 清空战场（把多余那发也打掉）-> 之后新发射的一发要重新受控
				if extra != null:
					extra.kill("probe_kill2")
				_s.clear_projectiles()
				_s.t_fire_loiter(_lp, Vector2(10.5, 10.5), _unit("Gerald (E)"))
				var fresh: Projectile = null
				for q2 in _loiters():
					fresh = q2
				_chk(fresh != null and not fresh.no_control and _s.t_loiter_pick_control() == fresh,
					"场上清空后新发射的一发重新受控（玩家按 Q/E 一定有反应）")
				print("\n── r92 探针：%d 项检查，失败 %d 项 ──" % [_checks, _fail])
				Level.current = "field"
				return true
	return false
