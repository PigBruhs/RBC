# 第 97 轮收口回归探针：轨道空爆【召唤球/标记】的落地路径
#
# 为什么单独一个探针：playtest 覆盖了大部分链路，但"标记球被拦/落地 -> 立光柱"这条
# **没有断言**，于是它带着一个 `Nonexistent function '_raise_pylon_at'` 崩进了收口版本
# ——（SkillRunner 把那根光柱函数搬走了，而 projectile_sink 还在调宿主上那个旧名字）。
# 本探针直接走 `fire_skill_at`（标记落地的唯一入口）并断言光柱真的立起来了。
#
# 运行： Godot_v4.7.2-stable_win64_console.exe --headless --path game \
#            --script res://tools/probe_marker.gd --quit-after 60000
extends SceneTree

var _s: Node
var _fails: Array[String] = []
var _checks := 0


func _chk(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("  PASS  ", label)
	else:
		print("  FAIL  ", label)
		_fails.append(label)


func _initialize() -> void:
	_s = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(_s)
	for i in 8:
		await process_frame

	print("\n[0] 关掉 AI 保证确定性")
	_s.t_set_ai_enabled(false)
	_s.t_set_autoplay_player(false)
	var gerald: Unit = null
	for u in _s.units:
		if Unit.base_name(u.name) == "Gerald":
			gerald = u
			break
	_chk(gerald != null, "场上找得到 Gerald（有【轨道空爆打击】的单位）")

	# ── 原崩溃点：标记球落地 -> 立紫色光柱 ──
	# `projectile_sink.fire_skill_at()` 里那一行曾写成 `_st._raise_pylon_at(fpos)`，
	# 而那个函数已随 SkillRunner 搬走 -> 运行时 `Nonexistent function` 直接崩。
	print("\n[1] 标记球落地必须立起光柱（原崩溃点）")
	_s.t_clear_pylons()
	var n0: int = _s.gm.pending.size()
	var at := Vector2(float(gerald.cell.x) + 4.5, float(gerald.cell.y) + 0.5)
	var m: Projectile = _s.t_spawn_marker(gerald, at)
	_chk(m != null, "spawn_marker 返回了弹道物")
	# field.step 推进弹道物；落地时会走 EV_LANDED -> land_shell -> fire_skill_at
	var guard := 0
	while m.alive and guard < 3000:
		_s.field.step(1.0 / 60.0)
		guard += 1
	_chk(not m.alive, "召唤球已落地（%d 帧）" % guard)
	_chk(_s.gm.pending.size() == n0 + 1, "落地后登记了一条 GM 计时（%d -> %d）" % [n0, _s.gm.pending.size()])
	var last: GameMaster.Pending = _s.gm.pending[_s.gm.pending.size() - 1]
	_chk(String(last.skill_id) == "orbital_strike", "登记的是 orbital_strike（轨道空爆）")
	# ⬇ 这一条就是崩溃点的判据
	_chk(last.pylon != null, "标记落地必须立起紫色光柱（pylon != null）")
	_chk(last.pylon != null and last.pylon.get_parent() != null, "光柱已进场景树（看得见）")

	print("\n[2] 被击落的召唤球 = 整发作废（不立光柱、不登记计时）")
	_s.t_clear_pylons()
	var n1: int = _s.gm.pending.size()
	var m2: Projectile = _s.t_spawn_marker(gerald, Vector2(float(gerald.cell.x) + 6.5, float(gerald.cell.y) + 0.5))
	_chk(m2 != null, "第二发也生成了")
	# 半空打掉：按口径召唤球不是炮弹类，被击落 = 整发作废
	m2.kill("shot_down")
	await process_frame
	_chk(_s.gm.pending.size() == n1, "被击落不登记 GM 计时（%d -> %d）" % [n1, _s.gm.pending.size()])

	print("\n── 轨道空爆标记探针：%d 项检查，失败 %d 项 ──" % [_checks, _fails.size()])
	for f in _fails:
		print("   - ", f)
	quit(1 if _fails.size() > 0 else 0)
