# ══════════════════════════════════════════════════════════════════════════════
# 空中单位：巡飞弹（含发射器与 Q/E 制导）+ 直升机全流程（俯冲轰炸 / 坠机）
#
# 巡飞弹口径（第 90~92 轮，规格 §二十）：
#   · 恒速 4 格/秒、定高 1.5 格；模型/碰撞 = 直径一格的球，造伤 = 直径两格的球
#   · 40 破甲 + 40 力量、**不分敌我**；飞满 32 格自爆；被击落/撞人/出界都算"就地引爆"
#   · 近炸引信只认**敌方角色**、感应直径 1.5 格（半径 0.75）；发射它的发射器忽略
#   · **制导权（第 92 轮修正）**：场上清空后新发射的那一发重新受控；场上已有别的巡飞弹时
#     新发的标 `no_control` **永远直线飞**；受控那发爆炸后**不接管**任何一发。见 loiter_pick_control()
#   · Q/E 转向在**屏幕平面**做（右转 = 屏幕上顺时针，与相机 yaw 无关），角速度带惯性
#   · 发射器：每场景上限 1 台、判定 24 格、每 5 个 GM 回合边界发一枚，
#     只打"进入范围的**正在移动的敌方**角色"
#
# 直升机口径（第 83~96 轮）：
#   · **坠机唯一触发 = 力量池归零**（第 97 轮删掉了半血自毁）；死亡附加伤害**不分敌我**
#     （半径 2.5 / 20 力 + 40 破甲 / 无视 50% 物抗）
#   · 爬升轰炸：爬到 4 格 → 停 0.5 秒 → 投弹（下落 1 秒）→ **在 4 格等弹落地** → 原路返回
#   · 投弹是半径 3 格的**三维球**（球心离地 0.15），所以爬到 4 格不自伤
#   · 技能移动也要触发哨兵：每帧按**真实浮点位置** sentry.lock（不是格坐标）
#
# 宿主是 battle_scene（Node3D）。_st 动态类型（写 `: Node3D` 编译不过），同其它模块。
# ══════════════════════════════════════════════════════════════════════════════
class_name AirRunner
extends RefCounted

var _st = null                 # 宿主（battle_scene）；动态类型见文件头


func _init(host: Node3D) -> void:
	_st = host

## 发射器（沙盒元素）采样：只挑"正在移动且在 12 格内"的角色，最近优先
func tick_loiter_launchers(delta: float) -> void:
	if _st.phase == _st.Phase.PLACE or _st.game_over:
		return
	_st._loiter_sample += delta
	if _st._loiter_sample < 1.0 / Loiter.SAMPLE_HZ:
		return
	_st._loiter_sample = 0.0
	var moving := moving_units()
	for pl in _st.placeables:
		if not pl.is_alive() or not Loiter.is_launcher(pl):
			continue
		if _st.gm.turn_count < int(pl.tags.get("loiter_next", 0)):
			continue                                     # 5 个回合边界冷却
		var ctr := Vector2(float(pl.cell.x) + 0.5, float(pl.cell.y) + 0.5)
		var best: Unit = null
		var best_d := 1e9
		for u in moving:
			if not Loiter.is_target(u):
				continue                                 # 区分敌我：只打敌方角色（第 91 轮）
			var d: float = ctr.distance_to(_st._unit_pos(u))
			if d > Loiter.LAUNCH_RANGE:
				continue
			if d < best_d:
				best_d = d
				best = u
		if best == null:
			continue
		fire_loiter(pl, ctr, best)




## 这一帧哪些角色"在动"：走路 Tween 在跑，或者浮点位置和上次采样差了 MOVE_EPS
func moving_units() -> Array[Unit]:
	var out: Array[Unit] = []
	for u in _st.units:
		if not u.is_alive():
			continue
		var pos: Vector2 = _st._unit_pos(u)
		var last = _st._unit_seen.get(u, pos)
		_st._unit_seen[u] = pos
		var vis := u.visual as UnitVisual
		var walked := vis != null and vis.is_walking()
		if walked or pos.distance_to(last) > Loiter.MOVE_EPS:
			out.append(u)
	return out




func fire_loiter(pl: Placeable, ctr: Vector2, tgt: Unit) -> void:
	var heading := Loiter.launch_heading(ctr, _st._unit_pos(tgt), _st.rng)
	var p := Ordnance.make_loiter(-1, pl.name, ctr, heading, _st.rng)
	p.ignore_placeable = pl                    # 别一出膛就被自己的发射器触发了引信
	_st.field.register(p)
	pl.tags["loiter_next"] = _st.gm.turn_count + Loiter.LAUNCH_COOLDOWN_TURNS
	# 制导权（第 91/92 轮）：**场上已经有别的巡飞弹 -> 这一发是"多余的一发"，永远不受控**；
	# 场上没有别的 -> 这一发就是玩家能控的那一发（哪怕之前那发已经爆炸，新的一发照样能控）。
	var others := 0
	for it2 in _st.field.items:
		var q2: Projectile = it2["p"]
		if q2 != p and q2.kind == Projectile.KIND_LOITER and q2.alive:
			others += 1
	if others > 0:
		p.no_control = true
	if _st._loiter_control == null or not _st._loiter_control.alive:
		_st._loiter_control = p if not p.no_control else null
	var d: float = ctr.distance_to(_st._unit_pos(tgt))
	_st._log("  🚀 %s 发射【巡飞弹】→ 目标 %s（%.1f 格，初始方向 %.0f°，中心线偏 %+.0f°）%s" % [
		pl.name, tgt.name, d, rad_to_deg(heading),
		rad_to_deg(heading) - rad_to_deg((_st._unit_pos(tgt) - ctr).angle()),
		"｜ Q/E 制导" if not p.no_control else "｜ 场上已有巡飞弹：这一发不受控（沿直线飞）"])




## 近炸引信（每帧）：**只在敌方角色**进入感应范围（直径 1.5 格）时引爆 —— 第 92 轮口径。
## 友军从旁边飞过不炸、沙盒元素也不炸（但引爆时的造伤仍然会打到范围内的沙盒元素）。
## 飞满 32 格自动引爆不在这里 —— 那走弹道的落地事件（_land_shell）。
func tick_loiter_fuse() -> void:
	if _st.field == null:
		return
	for it in _st.field.items.duplicate():
		var p: Projectile = it["p"]
		if p.kind != Projectile.KIND_LOITER or not p.alive:
			continue
		# 第 104 轮 · 安全引信：**飞出去 3 格才开近炸**（刚出膛时还在发射器/车体旁边）
		if not Loiter.armed(p):
			continue
		var ctr := p.pos3()
		var why := ""
		for u in _st.units:
			if Loiter.fuse_touches_unit(ctr, u):
				why = u.name
				break
		if why == "":
			continue
		_st._log("  💥 巡飞弹近炸引信：感应范围内出现 %s → 引爆" % why)
		p.kill("fuse")
		loiter_burst(p, ctr)


## 轮式齐射午餐盒的技能【巡飞弹】（第 104 轮）：
## "作为技能向选定的目标释放，目标必须在 32 格内；初始角度的随机范围与沙盒元素的
##  巡飞弹发射器一致；技能耗费 12 点精力；记得设置安全引信，飞出去三格才开碰撞和近炸。"
##
## 实现：`aim` 是拖拽落点 -> 取"落点附近 32 格内最近的那个敌人"当选定目标；
## 初始航向走 `Loiter.launch_heading`（**与沙盒发射器同一个随机范围**）；
## 安全引信由 `Loiter.armed`（飞够 ARM_DIST 格）保证 —— 未武装前不近炸、不碰撞。
## 返回 false = 没放出（没目标 / 超距）。
func launch_loiter_skill(caster: Unit, aim: Vector2) -> bool:
	var d := Skills.get_def("loiter_launch")
	var reach := float(d.get("range_max", 32.0))
	var base := GridMath.unit_pos(caster)
	if base.distance_to(aim) > reach:
		_st._log("  🚙 %s 的巡飞弹打不到那么远（%.1f > %.1f 格）" % [
			caster.name, base.distance_to(aim), reach])
		return false
	# 选定目标 = 落点附近最近的敌方角色（拖拽落点 -> 目标）
	var tgt: Unit = null
	var best := 1.0e9
	for u in _st.units:
		if u == null or not u.is_alive() or u.side == caster.side:
			continue
		var dd := GridMath.unit_pos(u).distance_to(aim)
		if dd < best:
			best = dd
			tgt = u
	var to := GridMath.unit_pos(tgt) if tgt != null else aim
	if base.distance_to(to) > reach:
		_st._log("  🚙 %s 的巡飞弹目标超出 %.0f 格，放弃" % [caster.name, reach])
		return false
	var heading := Loiter.launch_heading(base, to, _st.rng)      # 与沙盒发射器同一套随机初始角
	var p := Ordnance.make_loiter(caster.side, caster.name, base, heading, _st.rng, Loiter.ARM_DIST)
	p.shot.target = tgt
	_st.field.register(p)
	_st._log("  🚙 %s 放出巡飞弹：目标 %s（%.1f 格），初始航向 %.1f°，安全引信 %.0f 格" % [
		caster.name, tgt.name if tgt != null else "落点", base.distance_to(to),
		rad_to_deg(heading), Loiter.ARM_DIST])
	return true




## 巡飞弹引爆：**直径两格的三维球**（角色按"现在真的在哪"的高度判）+ 沙盒元素按沾格判。
## 不分敌我（沙盒武器），40 破甲 + 40 力量，无视 50% 物抗。
func loiter_burst(p: Projectile, ctr: Vector3) -> void:
	var sh: Ordnance.Shot = p.shot
	var opts: Dictionary = sh.opts if sh != null else {}
	if opts.is_empty():
		opts = Loiter.opts(_st.rng)
	_st.fx.flash_sphere(ctr, Loiter.BLAST_R * 1.7, 0.42)
	_st._log("  💥 巡飞弹引爆 (%.1f, %.1f) 高度 %.2f：直径 %.0f 格的球，%d 破甲 + %d 力量（不分敌我）" % [
		ctr.x, ctr.z, ctr.y, Loiter.BLAST_R * 2.0, int(Loiter.BREAK), int(Loiter.POWER)])
	var hits: Array = Damage.air_burst(null, ctr, opts, _st.units, null, Loiter.BLAST_R)
	hits.append_array(Damage.blast(null, Vector2(ctr.x, ctr.z), Loiter.BLAST_R, opts,
		[] as Array[Unit], _st.placeables, null, -1, true))
	if hits.is_empty():
		_st._log("  （造伤范围内没有目标）")
	for h in hits:
		_st._log(h.text)
		if h.unit != null:
			_st._after_damage_to_unit(h.unit)
		else:
			_st._after_damage_to_placeable(h.placeable)




## Q/E 制导（用户口径第 90 轮）：Q = 左转、E = 右转。
## 按得越久转得越快（Loiter.want_rate 有上下限），松手带惯性滑回 0（Loiter.step_rate）。
## **Q/E 在这之外没有别的用途**（只有弹反 QTE 内部会用，那时整棵树是暂停的）。
func tick_loiter_steer(delta: float) -> void:
	var p := loiter_pick_control()
	if p == null:
		return
	var left := Input.is_key_pressed(KEY_Q)
	var right := Input.is_key_pressed(KEY_E)
	var dir := 0.0
	if left and not right:
		dir = -1.0
	elif right and not left:
		dir = 1.0
	loiter_steer_apply(p, dir, delta)




## 真正施加转向：dir = -1 左转（Q）/ +1 右转（E）/ 0 松手。
## 单独抽出来是为了让无头测试能"按住 Q/E"（headless 里造不出真实按键）。
func loiter_steer_apply(p: Projectile, dir: float, delta: float) -> void:
	if p == null or not p.alive:
		return
	if dir < 0.0:
		p.hold_l += delta
		p.hold_r = 0.0
	elif dir > 0.0:
		p.hold_r += delta
		p.hold_l = 0.0
	else:
		p.hold_l = 0.0
		p.hold_r = 0.0
	var hold := 0.0
	if dir < 0.0:
		hold = p.hold_l
	elif dir > 0.0:
		hold = p.hold_r
	var want := dir * Loiter.want_rate(hold)
	p.turn_w = Loiter.step_rate(p.turn_w, want, delta)
	if absf(p.turn_w) > 0.01:
		var axes := Loiter.screen_axes(_st._cam_yaw)
		p.heading = Loiter.steer(p.heading, axes[0], axes[1], p.turn_w, delta)




## 玩家当前制导的那一发（第 91/92 轮口径）：
##   · 场上"非多余"且**最早发射**的那一发受控（多余 = 发射时场上已经有别的巡飞弹，永远不受控）
##   · 受控那发爆炸后：之前那些"多余的"仍然不受控，但**之后新发射的一发会重新受控**
func loiter_pick_control() -> Projectile:
	if _st._loiter_control != null and _st._loiter_control.alive:
		return _st._loiter_control
	_st._loiter_control = null
	if _st.field == null:
		return null
	for it in _st.field.items:
		var p: Projectile = it["p"]
		if p.kind == Projectile.KIND_LOITER and p.alive and not p.no_control:
			_st._loiter_control = p
			break
	return _st._loiter_control




func heli_shadow(u: Unit) -> void:
	var node: Node3D = _st._heli_shadows.get(u, null)
	if node == null or not is_instance_valid(node):
		node = Node3D.new()
		var disc := MeshInstance3D.new()
		var cy := CylinderMesh.new()
		cy.top_radius = 0.42
		cy.bottom_radius = 0.42
		cy.height = 0.02
		disc.mesh = cy
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.0, 0.0, 0.0, 0.34)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		disc.material_override = m
		node.add_child(disc)
		_st.add_child(node)
		_st._heli_shadows[u] = node
	var h: float = maxf(0.0, u.visual.position.y)
	node.position = Vector3(u.visual.position.x, 0.02, u.visual.position.z)
	var k: float = clampf(h / 2.0, 0.0, 1.5)
	node.scale = Vector3(1.0 + 0.25 * k, 1.0, 1.0 + 0.25 * k)





func tick_heli_fx(delta: float) -> void:
	for u in _st.units:
		if u == null or u.visual == null:
			continue
		if not Unit.base_name(u.name).begins_with(_st.HELI_PREFIX):
			continue
		HeliFx.tick(u.visual, u, delta)
		heli_shadow(u)
	# AI 回合看门狗：万一某条异步路径没结束回合，也不许把游戏卡死。
	# 第 93 轮：直升机 8 波齐射要 7 秒（还有走路），看门狗必须让位，否则会把齐射砍断、
	# 再由齐射的收尾去结束下一个人的回合。
	if _st.active != null and _st._is_ai_unit(_st.active) and not _st.get_tree().paused \
			and _st._dive.is_empty() and _st._salvo_u == null:
		_st._turn_watch_t += delta
		if _st._turn_watch_t > 9.0:
			_st._log("  ⚠ AI 回合超时（%.0f 秒未结束），强制结束以免软锁：%s" % [_st._turn_watch_t, _st.active.name])
			_st._turn_watch_t = 0.0
			_st._dive = {}
			_st.active.tags.erase("diving")
			_st._finish_turn()
	else:
		_st._turn_watch_t = 0.0




## 【坠机】被动：直升机的力量池**归零**时才坠机（加速下坠 -> 2.5 格炮击 -> 死亡）。
##
## 用户口径（第 97 轮）：**删掉"半血自毁"** —— 以前 `crash_threshold = 21`（力量低于 21 就坠机），
## 于是直升机还剩 20 点力量时就会自己炸掉。现在阈值 = 0：只有力量池真的被打空（= 阵亡）才坠机。
## 第 89 轮的口径不变：**就算这一下直接把它打空，也要走坠机的死亡附加伤害**。
## 所以这里只看 `is_alive()`（= `power_cur > 0`），不能像以前那样要求"还活着"再另判阈值。
func check_heli_crash(u: Unit) -> bool:
	if u == null:
		return false
	if not Unit.base_name(u.name).begins_with(_st.HELI_PREFIX):
		return false
	if u.tags.has("crashing"):
		return false
	if u.is_alive():
		return false                      # 力量池还有剩 -> 不坠机
	start_crash(u)
	return true




func start_crash(u: Unit) -> void:
	u.tags["crashing"] = true
	u.tags.erase("diving")
	u.tags.erase("dive_ready")
	u.body_y = -1.0                 # 坠机 = 从悬停高度往下掉
	_st.skills_mod.dive_clear(u)
	_st._log("  💥 %s 力量归零 —— 坠机！" % u.name)
	var from_h: float = u.visual.position.y if u.visual != null else u.hover
	var tw: Tween = _st.create_tween()
	tw.tween_property(u.visual, "position:y", 0.0, 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(func() -> void: crash_impact(u))




func crash_impact(u: Unit) -> void:
	var cfg := Level.heli()
	var center := Vector2(float(u.cell.x) + 0.5, float(u.cell.y) + 0.5)
	_st.fx.flash_sphere(Vector3(center.x, 0.6, center.y), 2.0, 0.45)
	var opts := Combat.opts({
		"power": int(cfg["crash_power"]) * 1000,
		"armor_break": int(cfg["crash_break"]) * 1000,
		"ignore_res": float(cfg["crash_res"]),
		"rng": _st.rng,
	})
	_st._log("  💥 %s 坠机落地 (%.1f, %.1f)：半径 %.1f 格内所有角色吃 %d 力 + %d 破甲（无视 50%% 物抗）" % [
		u.name, center.x, center.y, float(cfg["crash_r"]),
		int(cfg["crash_power"]), int(cfg["crash_break"])])
	var hits: Array = Damage.blast(u, center, float(cfg["crash_r"]), opts, _st.units, _st.placeables,
		null, u.side, true)
	for h in hits:
		if h.unit != null:
			_st._log(h.text)
			_st._after_damage_to_unit(h.unit)
	u.power_cur = 0
	if u.visual != null:
		u.visual.position.y = 0.0
	_st._on_unit_died(u)




## 【坠机】被动钩子（Passives 里声明 "heli_crash"，挂在直升机这一族名字上）
func hook_heli_crash(u: Unit) -> bool:
	return check_heli_crash(u)




## 轮到它的回合：开始【爬升轰炸】（返回 true 表示本回合由它接管）
## 用户口径（第 86 轮）：不再俯冲下去，而是**均匀爬升到不会自伤的高度** ——
## 爬到目标上方（升到 climb_h）-> 停 0.5 秒 -> 投弹（弹下落 bomb_fall_sec 秒）-> 原路返回并降回悬停高度。
## 第 103 轮：climb_h 4 → 7（投弹球半径 3 → 6，球顶升到 6.15 格），bomb_fall_sec 1.0 → 1.33。
func dive_begin(u: Unit) -> bool:
	if not u.tags.has("dive_ready"):
		return false
	var cfg := Level.heli()
	var target: Vector2i = u.tags["dive_ready"]
	_st.skills_mod.dive_clear(u)
	u.tags["diving"] = true
	_st._dive = {
		"u": u, "phase": "up",
		"from": _st._cc(u.cell),
		"to": _st._cc(target),
		"t": 0.0, "speed": float(cfg["climb_speed"]), "hold": 0.0,
		"hi": float(cfg["climb_h"]),
	}
	_st.gm.on_move_begin(u)          # 哨兵：这次"技能移动"的已触发闩清零（用户口径第 89 轮）
	if u.visual != null:
		u.visual.position.y = u.hover
	_st._log("  🚁 %s 开始爬升轰炸 -> (%d, %d)（升到 %.1f 格，%.1f 格/秒）" % [
		u.name, target.x, target.y, float(cfg["climb_h"]), float(cfg["climb_speed"])])
	return true




func dive_tick(delta: float) -> void:
	if _st._dive.is_empty():
		return
	var u: Unit = _st._dive["u"]
	if u == null or not u.is_alive() or not u.tags.has("diving"):
		_st._dive = {}
		if u != null:
			u.body_y = -1.0                  # 临时高度作废，回到悬停高度
		return
	var cfg := Level.heli()
	var phase := String(_st._dive["phase"])
	var from: Vector2 = _st._dive["from"]
	var to: Vector2 = _st._dive["to"]
	var speed: float = float(_st._dive["speed"])
	var hi: float = float(_st._dive["hi"])
	var total := maxf(0.5, from.distance_to(to))
	if phase == "up":
		_st._dive["t"] = minf(1.0, float(_st._dive["t"]) + speed * delta / total)
		var k: float = float(_st._dive["t"])
		var pos := from.lerp(to, k)
		place_diving(u, pos, lerpf(u.hover, hi, k))          # 均匀爬升
		if k >= 1.0:
			_st._dive["phase"] = "hold"
			_st._dive["hold"] = float(cfg["drop_hold"])
			_st._log("  🚁 %s 爬到目标上方 %.1f 格，停 %.2f 秒投弹" % [
				u.name, hi, float(cfg["drop_hold"])])
	elif phase == "hold":
		_st._dive["hold"] = float(_st._dive["hold"]) - delta
		if float(_st._dive["hold"]) <= 0.0:
			_st._dive["phase"] = "wait_bomb"
			_st._dive["hold"] = float(_st._dive["hold"]) + float(cfg["bomb_fall_sec"])
			start_bomb_fall(u, to)                            # 投弹：弹下落 bomb_fall_sec 秒
	elif phase == "wait_bomb":
		# 用户口径（第 89 轮）：**投弹后先留在高空等炸弹落地**再返航 ——
		# 不然返航途中降到爆心球顶（第 103 轮 = 6.15 格）以下，会被自己的炸弹炸到。
		# 停满 bomb_fall_sec（= 炸弹触地那一刻）才切 back ✓ 与 start_bomb_fall 的 Tween 同一个时钟。
		_st._dive["hold"] = float(_st._dive["hold"]) - delta
		place_diving(u, to, hi)
		if float(_st._dive["hold"]) <= 0.0:
			_st._dive["phase"] = "back"
			_st._dive["t"] = 1.0
	elif phase == "back":
		_st._dive["t"] = maxf(0.0, float(_st._dive["t"]) - speed * delta / total)
		var k2: float = float(_st._dive["t"])
		var pos2 := from.lerp(to, k2)
		place_diving(u, pos2, lerpf(u.hover, hi, k2))         # 返航时均匀降回
		if k2 <= 0.0:
			u.tags.erase("diving")
			u.body_y = -1.0                                    # 回到悬停高度
			_st._dive = {}
			if u.visual != null:
				u.visual.position.y = u.hover
			_st._log("  🚁 %s 返航完成" % u.name)
			_st._finish_turn()




## 把炸弹从直升机脚下丢下去：下落 bomb_fall_sec 秒后触地结算（用户口径第 86 轮）
func start_bomb_fall(u: Unit, at: Vector2) -> void:
	var cfg := Level.heli()
	var fall := float(cfg["bomb_fall_sec"])
	var h0: float = u.visual.position.y if u.visual != null else u.hover
	var bomb := MeshInstance3D.new()
	var bm := SphereMesh.new()
	bm.radius = 0.36                       # 投掷手普攻模型直径翻倍
	bm.height = 0.72
	bomb.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.18, 0.18, 0.20)
	mat.metallic = 0.5
	bomb.material_override = mat
	bomb.position = Vector3(at.x, h0, at.y)
	_st.add_child(bomb)
	_st._log("  💣 %s 投弹：炸弹从 %.1f 格下落（%.2f 秒后触地）" % [u.name, h0, fall])
	var tw: Tween = _st.create_tween()
	tw.tween_property(bomb, "position:y", 0.15, fall).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(func() -> void:
		if is_instance_valid(bomb):
			bomb.queue_free()
		drop_bomb(u, at))




## 俯冲中的位置同步（格坐标 + 高度）
func place_diving(u: Unit, pos: Vector2, h: float) -> void:
	u.cell = _st._clamp_cell(Vector2i(int(floor(pos.x)), int(floor(pos.y))))
	u.body_y = h                  # 第 89 轮：三维判定按"它现在真的在哪"算（否则会被自己的炸弹炸到）
	if u.visual != null:
		u.visual.position = Vector3(clampf(pos.x, float(_st.PX) + 0.5, float(_st.PX + _st.PW) - 0.5), h,
			clampf(pos.y, float(_st.PY) + 0.5, float(_st.PY + _st.PH) - 0.5))
	check_heli_crash(u)          # 用户口径：俯冲期间会受伤、也会触发被动
	# 哨兵（用户口径第 89 轮）：**技能移动和走路一样要触发哨兵** ——
	# 以前只有 walk_path 的视觉位移会采样，技能飞行完全不惊动哨兵（一次移动最多入队一次）。
	var sample := pos
	if u.visual != null:
		sample = Vector2(u.visual.position.x, u.visual.position.z)
	_st.sentry.lock(u, sample)




## 投弹：投掷手普攻模型直径翻倍、**半径 drop_blast_r 的三维球**（第 103 轮：3 → 6）、
## 20 破甲 + 120 力量（第 103 轮：40/20 → 20/120）、不触发哨兵。
## 用户口径（第 86 轮）：判定是**三维球**（球心在离地 0.15 格、半径 drop_blast_r）——
## 所以爬升高度必须 > 球顶（`climb_h > 0.15 + drop_blast_r`，第 103 轮 = 6.15 → 取 7.0）才炸不到自己。
## 第 95 轮：爆炸表现也照这个半径画（以前只有一个 1.2 的小闪光，看不出范围）。
func drop_bomb(u: Unit, at: Vector2) -> void:
	var cfg := Level.heli()
	var radius := float(cfg["drop_blast_r"])
	_st.fx.flash_sphere(Vector3(at.x, 0.8, at.y), radius, 0.42)
	var opts := Combat.opts({
		"power": int(cfg["drop_power"]) * 1000,
		"armor_break": int(cfg["drop_break"]) * 1000,
		"ignore_res": 0.0,
		"rng": _st.rng,
	})
	_st._log("  💣 %s 投弹 (%.1f, %.1f)：半径 %.1f 格（三维球），%d 破甲 + %d 力量（不触发哨兵）" % [
		u.name, at.x, at.y, radius, int(cfg["drop_break"]), int(cfg["drop_power"])])
	# skip = null：不分敌我（用户口径）；球心在离地 0.15 格
	var hits: Array = Damage.air_burst(u, Vector3(at.x, 0.15, at.y), opts, _st.units, null, radius)
	for h in hits:
		if h.unit != null:
			_st._log(h.text)
			_st._after_damage_to_unit(h.unit)
	# 沙盒道具：照旧按格子判定（道具没有高度轴）
	for pl in _st.placeables:
		if not pl.is_alive():
			continue
		if Vector2(float(pl.cell.x) + 0.5, float(pl.cell.y) + 0.5).distance_to(at) > radius:
			continue
		var r2 := Combat.deal_to_placeable(pl, opts)
		_st._log("  [道具] %s：%s" % [pl.name, Combat.describe(r2, pl.pr, 0.0)])
		_st._after_damage_to_placeable(pl)
	_st.fx.show_impact(at)


