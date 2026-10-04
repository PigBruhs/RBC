# ══════════════════════════════════════════════════════════════════════════════
# 医疗包探针（第 98 轮 · 圣萨尼被动改版）
#
# 为什么单独一个探针：这条被动**从"复活队友"整条换成了"投医疗包"**，而既有测试网里
# 关于它的断言全是旧口径（playtest §33 ③ / run.gd 的 revive 断言）。新口径的三条特有行为
# 在别处完全没有覆盖：
#   ① 随机向一名"受伤的队友"投掷，命中回 20 点力量（不超上限）
#   ② 飞行中碰到**任何人**都给对方回血（含敌人）—— 友伤变成"友疗"
#   ③ 没有受伤的队友 -> 不投（且有日志）
#   ④ 同一颗种子 -> 选中同一个目标（确定性，走 RngService 而不是 randf）
#   ⑤ 复活路径确实没了（旧逻辑整条删除）
#
# 运行： Godot_v4.7.2-stable_win64_console.exe --headless --path game \
#            --script res://tools/probe_medkit.gd --quit-after 60000
# ══════════════════════════════════════════════════════════════════════════════
extends SceneTree

var _s: Node
var _fails: Array[String] = []
var _checks := 0
var _sani: Unit
var _gerald: Unit
var _alette: Unit
var _enemy: Unit


func _chk(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("  PASS  ", label)
	else:
		print("  FAIL  ", label)
		_fails.append(label)


func _find(nm: String, side: int) -> Unit:
	for u in _s.units:
		if u.name == nm and u.side == side and u.is_alive():
			return u
	return null


## 把除"主角"以外的所有单位挪到远处角落（避免它们站在弹道上抢命中）
func _clear_path(keep: Array) -> void:
	var c := Vector2i(40, 40)
	for u in _s.units:
		if u == null or keep.has(u):
			continue
		u.cell = c
		c.x += 1
		if c.x > 46:
			c.x = 40
			c.y += 1


func _heal_all_teammates() -> void:
	for u in _s.units:
		if u != null and u.side == UnitData.Side.PLAYER:
			u.power_cur = u.power_max


func _log_has(sub: String) -> bool:
	for line in _s.t_debug_log():
		if String(line).contains(sub):
			return true
	return false


## 手工推进医疗包直到落地（探针关掉了场景 _process，所以只有我们能推进它）
func _run_until_landed(max_frames: int = 600) -> int:
	var n := 0
	while _s.t_sani_medkit_count() > 0 and n < max_frames:
		_s.t_tick_medkits(1.0 / 60.0)
		n += 1
	return n


func _initialize() -> void:
	_s = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(_s)
	for i in 8:
		await process_frame

	# ⚠ 关掉场景自己的 _process：探针要**手工**推进医疗包（否则自动 tick 与手动 tick
	# 会一起推进，帧数不可复现）。AI 本来也由 _process 驱动，一并停掉。
	_s.set_process(false)
	_s.t_set_ai_enabled(false)
	_s.t_set_autoplay_player(false)

	print("\n[0] 被动口径本身（表里已不再有 revive）")
	var hs := Passives.def("holy_sani")
	_chk(Passives.exists("holy_sani"), "被动 id 仍是 holy_sani（测试引用它，不能改名）")
	_chk(not hs.has("revive") and not hs.has("uses_per_life"),
		"passives.gd 里 revive / uses_per_life 已删除")
	_chk(int(hs.get("heal_points", 0)) == 20, "回血 20 点写在被动表里（heal_points = 20）")
	_chk(String(hs.get("desc", "")).contains("医疗包") and not String(hs.get("desc", "")).contains("复活"),
		"说明文案已改成医疗包口径、且不含复活字样")

	_sani = _find("萨尼铁塔", UnitData.Side.PLAYER)
	_gerald = _find("Gerald", UnitData.Side.PLAYER)
	_alette = _find("Alette", UnitData.Side.PLAYER)
	_enemy = _find("Gerald (E)", UnitData.Side.ENEMY)
	_chk(_sani != null and _gerald != null and _alette != null and _enemy != null,
		"场上找得到 萨尼铁塔 / Gerald / Alette / Gerald (E)")
	if _sani == null or _gerald == null or _alette == null or _enemy == null:
		_finish()
		return

	# ══════════════════════════════════════════════════════════════════════════
	print("\n[1] 投出一枚绿色箭头的医疗包，命中回 20 点力量（不超上限）")
	_clear_path([_sani, _gerald])
	_sani.cell = Vector2i(10, 10)
	_gerald.cell = Vector2i(10, 12)          # 只隔 2 格 -> 散布半径 ~0.03，必中
	_heal_all_teammates()
	_gerald.power_cur = _gerald.power_max / 2
	var hp0: int = _gerald.power_cur
	_s.rng = RngService.new(20261004)
	_s.t_sani_throw_medkit()
	_chk(_s.t_sani_medkit_count() == 1, "在途医疗包 = 1（实际 %d）" % _s.t_sani_medkit_count())
	_chk(_s.t_sani_heal_roll() == "Gerald", "选中的是唯一受伤的队友 Gerald（实际 '%s'）" % _s.t_sani_heal_roll())
	# 绿色箭头：外观节点叫 MedkitArrow，杆与箭头共用一份绿色自发光材质
	var node := _s.find_child("MedkitArrow", true, false)
	_chk(node != null, "绿色箭头外观已挂进场景（MedkitArrow）")
	var col := Color.BLACK
	if node != null:
		for c in node.get_children():
			var mi := c as MeshInstance3D
			if mi != null and mi.material_override is StandardMaterial3D:
				col = (mi.material_override as StandardMaterial3D).albedo_color
				break
	_chk(col.g > 0.8 and col.r < 0.6, "箭头颜色是绿色（rgb = %.2f, %.2f, %.2f）" % [col.r, col.g, col.b])
	var frames := _run_until_landed()
	var hp1: int = _gerald.power_cur
	_chk(_s.t_sani_medkit_count() == 0, "落地后在途医疗包 = 0（飞了 %d 帧）" % frames)
	_chk(hp1 == hp0 + 20000, "命中回 20 点力量（%d -> %d）" % [hp0 / 1000, hp1 / 1000])
	_chk(hp1 <= _gerald.power_max, "不超过力量上限")
	_chk(_log_has("医疗包命中 Gerald"), "日志写了命中（探针可读）")
	# 差 5 点就满血：命中只能补到上限（不会溢出）
	_heal_all_teammates()
	_gerald.power_cur = _gerald.power_max - 5000
	_s.t_sani_throw_medkit()
	_run_until_landed()
	_chk(_gerald.power_cur == _gerald.power_max,
		"回血钳在力量上限（差 5 点时只补 5，%d）" % (_gerald.power_cur / 1000))

	# ══════════════════════════════════════════════════════════════════════════
	print("\n[2] 飞行中碰到敌人 -> 也给敌人回血（友伤变'友疗'）")
	_clear_path([_sani, _gerald, _enemy])
	_sani.cell = Vector2i(10, 10)
	_gerald.cell = Vector2i(10, 12)
	_enemy.cell = Vector2i(10, 11)            # 正卡在萨尼 -> Gerald 的弹道上
	_heal_all_teammates()
	_gerald.power_cur = _gerald.power_max / 2
	_enemy.power_cur = _enemy.power_max / 2
	var e0: int = _enemy.power_cur
	var g0: int = _gerald.power_cur
	_s.t_sani_throw_medkit()
	_run_until_landed()
	_chk(_enemy.power_cur == e0 + 20000, "敌人被医疗包回血（%d -> %d）" % [e0 / 1000, _enemy.power_cur / 1000])
	_chk(_gerald.power_cur == g0, "医疗包在敌人身上就用掉了，队友没被治（%d -> %d）" % [g0 / 1000, _gerald.power_cur / 1000])
	_chk(_log_has("医疗包命中 Gerald (E)"), "日志写明命中的是敌人")

	# ══════════════════════════════════════════════════════════════════════════
	print("\n[3] 盘面上没有受伤的队友 -> 不投，且有日志")
	_heal_all_teammates()
	var n_before: int = _s.t_sani_medkit_count()
	_s.t_sani_throw_medkit()
	_chk(_s.t_sani_medkit_count() == n_before, "没有受伤队友时不投（在途仍是 %d）" % _s.t_sani_medkit_count())
	_chk(_s.t_sani_heal_roll() == "", "选中目标为空（实际 '%s'）" % _s.t_sani_heal_roll())
	_chk(_log_has("没有受伤的队友"), "日志写明了原因（没有受伤的队友）")

	# ══════════════════════════════════════════════════════════════════════════
	print("\n[4] 同一颗种子 -> 选中同一个目标（确定性）")
	_heal_all_teammates()
	_gerald.power_cur = _gerald.power_max / 2
	_alette.power_cur = _alette.power_max / 2
	_s.rng = RngService.new(777)
	_s.t_sani_throw_medkit()
	var roll_a: String = _s.t_sani_heal_roll()
	_run_until_landed()
	_s.rng = RngService.new(777)
	_s.t_sani_throw_medkit()
	var roll_b: String = _s.t_sani_heal_roll()
	_run_until_landed()
	_chk(roll_a != "" and roll_a == roll_b,
		"同种子两次选中同一人（'%s' / '%s'）" % [roll_a, roll_b])
	_chk(roll_a == "Gerald" or roll_a == "Alette", "选中的确实是受伤的队友之一")
	# 顺带：纯函数入口也走同一套池子
	var pool := Medkit.wounded_mates(_sani, _s.units)
	_chk(pool.size() == 2, "受伤队友池 = 2（Gerald + Alette，实际 %d）" % pool.size())

	# ══════════════════════════════════════════════════════════════════════════
	print("\n[5] 复活路径确实没了")
	_alette.power_cur = 0
	_s.t_on_unit_died(_alette)
	_chk(not _alette.is_alive(), "Alette 已阵亡（力量池 0）")
	_s.t_holy_sani_check(_sani)
	var f2 := _run_until_landed()
	_chk(not _alette.is_alive(), "萨尼回合后 Alette **没有**复活（复活逻辑已删除）")
	_chk(not _sani.tags.has("holy_sani_used"), "旧的'每条命一次'标记不复存在")
	_chk(f2 >= 0 and _s.t_sani_heal_roll() != "Alette", "医疗包不会选中阵亡队友（选中 '%s'）" % _s.t_sani_heal_roll())

	_finish()


func _finish() -> void:
	print("\n── 医疗包探针：%d 项检查，失败 %d 项 ──" % [_checks, _fails.size()])
	for f in _fails:
		print("   - ", f)
	quit(1 if _fails.size() > 0 else 0)
