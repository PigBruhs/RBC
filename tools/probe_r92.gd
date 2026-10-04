# 第 92 轮排查探针：Q/E 制导在【真实输入路径】上到底有没有生效。
#   Godot_v4.7.2-stable_win64.exe --headless --path game --script res://tools/probe_r92.gd --quit-after 60000
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
var _h_after_q := 0.0


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
			_s._place_kind = "巡飞弹发射器"
			_s.place_left["巡飞弹发射器"] = 1
			_s._place_at(Vector2i(10, 10))
			for p in _s.placeables:
				if Loiter.is_launcher(p):
					_lp = p
			_chk(_lp != null, "发射器放好了")
			for u in _s.units:
				_move(u, Vector2i(2, 44))
			var foe := _unit("Gerald (E)")
			foe.power_cur = foe.power_max
			_move(foe, Vector2i(10, 16))
			_t0 = _t
			_stage = 1
		1:
			if _t - _t0 > 0.3:
				_move(_unit("Gerald (E)"), Vector2i(10, 15))     # 敌人动一下 -> 发射
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
				_chk(_s._loiter_pick_control() == _mun and not _mun.no_control,
					"场上只有这一发 -> 它就是受控的那一发")
				_key(KEY_Q, true)                                # 真的按下 Q
				_t0 = _t
				_stage = 3
		3:
			if _t - _t0 > 1.0:
				_h_after_q = rad_to_deg(_mun.heading)
				_key(KEY_Q, false)
				_key(KEY_E, true)
				print("    按住 Q 一秒：朝向 %.1f° ｜ 角速度 %.1f°/秒 ｜ hold_l=%.2f ｜ 路程 %.2f 格" % [
					_h_after_q, _mun.turn_w, _mun.hold_l, _mun.flown])
				_chk(absf(_mun.turn_w) > 5.0, "按住 Q -> 角速度非零（输入真的接通了）")
				_chk(absf(_mun.hold_l - 1.0) < 0.2, "按住时长被累计（惯性曲线靠它算）")
				_t0 = _t
				_stage = 4
		4:
			if _t - _t0 > 1.0:
				_key(KEY_E, false)
				print("    改按 E 一秒：朝向 %.1f° ｜ 角速度 %.1f°/秒" % [
					rad_to_deg(_mun.heading), _mun.turn_w])
				# 到场一发"多余的"：它必须永远不受控
				var extra := Ordnance.make_loiter(-1, "巡飞弹发射器", Vector2(3.5, 40.5), 0.0, _s.rng)
				_s.field.register(extra)
				_chk(_s._loiter_pick_control() == _mun, "两发在场时仍然控制原来那发")
				_chk(not _s._loiter_pick_control().no_control, "受控那发没有被标记成多余")
				# 原受控那发爆炸 -> 多余的仍然不受控
				_mun.kill("probe_kill")
				_chk(_s._loiter_pick_control() == null,
					"受控那发爆炸后：多余的仍然不受控（不会接管）")
				_chk(extra.alive, "多余的那发还在飞（只是没人能控它）")
				# 而之后新发射的一发（场上只剩那发"多余的"）……
				extra.kill("probe_kill2")                        # 先清场，模拟"场上没有别的巡飞弹"
				_s.clear_projectiles()
				var fresh := Ordnance.make_loiter(-1, "巡飞弹发射器", Vector2(3.5, 40.5), 0.0, _s.rng)
				_s.field.register(fresh)
				_chk(_s._loiter_pick_control() == fresh,
					"场上清空后新发射的一发重新受控（玩家按 Q/E 一定有反应）")
				print("\n── r92 探针：%d 项检查，失败 %d 项 ──" % [_checks, _fail])
				Level.current = "field"
				return true
	return false
