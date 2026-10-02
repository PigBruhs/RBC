# ══════════════════════════════════════════════════════════════════════════════
# headless 规则自检：godot --headless --path <项目> --script res://tests/run.gd
# 退出码 0=全绿 / 1=有失败
# ══════════════════════════════════════════════════════════════════════════════
extends SceneTree

func _initialize() -> void:
	var fails: Array[String] = []

	# ── 1. bc_stat.md 解析结果是否被正确加载 ──
	var by_name := {}
	for d in UnitData.UNITS:
		by_name[d["name"]] = d
	_expect(by_name.has("Gerald"), "解析到 Gerald（注意用户文件用了全角冒号）", fails)
	var g: Dictionary = by_name.get("Gerald", {})
	_expect(g.get("power", 0) == 82, "Gerald 力量 = 82（非投掷手翻倍后）", fails)
	_expect(g.get("armor", 0) == 52, "Gerald 护甲 = 52（不能被 'armour break' 污染）", fails)
	_expect(g.get("armor_break", 0) == 16, "Gerald 破甲 = 16", fails)
	_expect(g.get("energy_max", 0) == 5, "Gerald 精力上限 = 5", fails)
	_expect(g.get("move", 0) == 5, "Gerald 移动 = 5", fails)
	_expect(g.get("role", -1) == UnitData.Role.MELEE, "Gerald 是近战", fails)
	_expect(g.get("pr", -1) == 800, "Gerald 物抗解析为 高（原文 physical resistence high）", fails)

	var a: Dictionary = by_name.get("Alette", {})
	_expect(a.get("role", -1) == UnitData.Role.RANGED, "Alette 是远程", fails)
	_expect(a.get("rng_max", 0) == 8, "Alette 射程 8", fails)
	_expect(a.get("mr", -1) == 400, "Alette 魔抗 mid", fails)

	var m: Dictionary = by_name.get("Airburst mortar", {})
	_expect(m.get("role", -1) == UnitData.Role.THROWER, "Airburst 是投掷", fails)
	_expect(m.get("rng_min", 0) == 3 and m.get("rng_max", 0) == 20, "Airburst 射程 3~20", fails)

	# ── 2. 伤害公式 D = (P-A)*(1-R) ──
	# 用户算例：差值 2、物抗 0.8 → 0.4 → 40%
	var p: Rules.Preview = Rules.preview(10000, 8000, 800)
	_expect(p.d_milli == 400, "用户算例 (10-8)×0.2 = 0.4（实际 %d‰）" % p.d_milli, fails)
	_expect(p.branch == Rules.Branch.ROLL and p.hit_percent == 40,
		"用户算例命中率 40%%（实际 %d）" % p.hit_percent, fails)

	# Gerald(41) 打 Dummy Melee(护甲 20, 物抗 高 0.8) → (41-20)×0.2 = 4.2
	var gp: Rules.Preview = Rules.preview(41000, 20000, 800)
	_expect(gp.d_milli == 4200, "Gerald→假人近战：4.2（实际 %d‰）" % gp.d_milli, fails)
	_expect(gp.branch == Rules.Branch.AUTO and gp.damage == 4, "→ 必中 4 点", fails)

	# Alette 翻倍后 52，打自己(护甲 24, 物抗 无) → (52-24)×1 = 28
	var ap: Rules.Preview = Rules.preview(52000, 24000, 0)
	_expect(ap.damage == 28, "Alette 打无抗：28 点（52-24，实际 %d）" % ap.damage, fails)

	# 免疫档
	_expect(Rules.preview(99999, 0, 1000).branch == Rules.Branch.NO_DAMAGE, "免疫档力量线无法造伤", fails)
	# 差值 0
	_expect(Rules.preview(10000, 10000, 0).branch == Rules.Branch.NO_DAMAGE, "差值 0 无法造伤", fails)

	# ── 3. 破甲线（用户口径：不再有"用精力加伤害"，破甲就是破甲值）──
	_expect(Rules.armor_break_damage_milli(16000, 0) == 16000, "无精力投注 = 16", fails)

	# ── 4. 加点池 ──
	var melee_opts: Array = Rules.upgrade_options(UnitData.Role.MELEE)
	_expect(not melee_opts.has(Rules.UPG_RANGE), "近战不能加射程", fails)
	var ranged_opts: Array = Rules.upgrade_options(UnitData.Role.RANGED)
	_expect(ranged_opts.has(Rules.UPG_RANGE), "远程可以加射程", fails)
	var thrower_opts: Array = Rules.upgrade_options(UnitData.Role.THROWER)
	_expect(thrower_opts.has(Rules.UPG_RANGE), "投掷可以加射程", fails)
	for opts in [melee_opts, ranged_opts]:
		_expect(not opts.has("move"), "移动力不可加点", fails)
		_expect(not opts.has("pr"), "物抗不可加点", fails)
		_expect(not opts.has("mr"), "魔抗不可加点", fails)

	# ── 5. 加点与重置（只重置当前单位） ──
	var u := Unit.from_data(by_name["Gerald"])
	var v := Unit.from_data(by_name["Alette"])
	var p0 := u.power_max
	var p1 := v.power_max
	Rules.apply_point(u, Rules.UPG_POWER)
	Rules.apply_point(u, Rules.UPG_ARMOR)
	Rules.apply_point(v, Rules.UPG_POWER)
	_expect(u.power_max == p0 + 1000, "Gerald 力量 +1", fails)
	_expect(v.power_max == p1 + 1000, "Alette 力量 +1", fails)
	Rules.reset_points(u)
	_expect(u.power_max == p0, "重置后 Gerald 力量还原", fails)
	_expect(v.power_max == p1 + 1000, "重置【不会】影响 Alette", fails)
	_expect(u.armor_max == Rules.points_to_milli(52), "重置后 Gerald 护甲还原", fails)

	# ── 6. 精力池（只用于付技能费，不再能加伤害）──
	var w := Unit.from_data(by_name["Gerald"])   # 精力上限 5
	w.spend_energy(3)
	_expect(w.energy_points() == 2, "花 3 点后剩 2 点", fails)
	w.begin_turn()
	_expect(w.energy_points() == 2, "新回合不会自动回精力", fails)

	# ── 7. 死亡规则 ──
	var d1 := Unit.from_data(by_name["Gerald"])
	d1.take_armor_damage(999000)
	_expect(d1.is_alive(), "护甲池归零不阵亡", fails)
	d1.take_power_damage(999000)
	_expect(not d1.is_alive(), "力量池归零才阵亡", fails)

	# ── Ballistics：拦截规则表（唯一一处定义"谁能拦谁"）──
	print("\n── 弹道拦截规则表 ──")
	var spike := Placeable.from_data(_pl_data("木刺"), Vector2i(5, 5))
	var mound := Placeable.from_data(_pl_data("土堆"), Vector2i(6, 6))
	_expect(Ballistics.placeable_block_mode(spike, Projectile.KIND_ARROW) == Ballistics.Block.NEVER,
		"木刺永不拦截箭矢（无论是否碰撞）", fails)
	_expect(Ballistics.placeable_block_mode(mound, Projectile.KIND_ARROW) == Ballistics.Block.ALWAYS,
		"土堆只要箭矢从它上空飞过就拦截", fails)
	_expect(not Ballistics.placeable_blocks(mound, Projectile.KIND_SHELL),
		"土堆挡不住投掷物（炮弹）", fails)
	_expect(not Ballistics.placeable_blocks(mound, Projectile.KIND_MARKER),
		"土堆挡不住投掷物（召唤球）", fails)
	var arrow_p := Projectile.make(Projectile.KIND_ARROW, Vector2.ZERO, Vector2.ONE, 1.0)
	var shell_p := Projectile.make(Projectile.KIND_SHELL, Vector2.ZERO, Vector2.ONE, 1.0)
	shell_p.sentry_trigger = true
	shell_p.hit_tags = ["arrow"]
	_expect(not Ballistics.triggers_sentry(arrow_p), "箭矢不惊动哨兵（否则箭生箭会炸）", fails)
	_expect(Ballistics.triggers_sentry(shell_p), "炮弹惊动哨兵", fails)
	_expect(Ballistics.can_shoot_down("arrow", shell_p), "箭矢可以击落炮弹", fails)
	_expect(not Ballistics.can_shoot_down("shell", arrow_p), "炮弹不会击落箭矢", fails)

	# ── Damage：爆炸覆盖规则（红圈沾到格子就算命中）──
	print("\n── 爆炸覆盖规则 ──")
	# 造一个靶子：格 (10,10)，格中心 (10.5,10.5)
	var tgt := Unit.from_data(UnitData.ENEMIES[0])
	tgt.cell = Vector2i(10, 10)
	tgt.power_cur = tgt.power_max
	# 爆心 (12,10)：到格中心距离 1.58（> 半径 1.0），但红圈边缘压到格子（最近点 1.0）
	var ctr := Vector2(12.0, 10.0)
	var opts := Combat.opts({"fixed_power": Rules.points_to_milli(1), "rng": RngService.new(1)})
	var touch_hits: Array = Damage.blast(null, ctr, 1.0, opts, [tgt] as Array[Unit],
		[] as Array[Placeable], null, -1, true)
	var center_hits: Array = Damage.blast(null, ctr, 1.0, opts, [tgt] as Array[Unit],
		[] as Array[Placeable], null, -1, false)
	print("    圆心到格中心 1.58 / 半径 1.0：沾格判定命中=%d，中心判定命中=%d" % [
		touch_hits.size(), center_hits.size()])
	_expect(touch_hits.size() == 1, "红圈沾到格子就算命中（用户口径）", fails)
	_expect(center_hits.is_empty(), "旧的'圆心到格中心'判定确实更严格（用来对比）", fails)
	# 远处一定不命中
	var far := Unit.from_data(UnitData.ENEMIES[0])
	far.cell = Vector2i(20, 20)
	far.power_cur = far.power_max
	var far_hits: Array = Damage.blast(null, ctr, 1.0, opts, [far] as Array[Unit],
		[] as Array[Placeable], null, -1, true)
	_expect(far_hits.is_empty(), "半径外不命中", fails)

	# ── 哨兵射界高亮：环带格子 + 沿格边的描边 ──
	print("\n── 哨兵射界描边 ──")
	# 圆心 (5.5,5.5)，射界 1~3：正中心那格是内圈空洞，(5,8) 距离正好 3 在内，(5,9) 距离 4 在外
	var ring := Targeting.ring_cells(Vector2(5.5, 5.5), 1.0, 3.0, 48, 48)
	_expect(not ring.has(Vector2i(5, 5)), "内圈空洞：距离 0 的中心格不在射界里", fails)
	_expect(ring.has(Vector2i(5, 8)), "距离正好等于 rmax 的格子应算在射界内", fails)
	_expect(not ring.has(Vector2i(5, 9)), "超出 rmax 的格子不算在射界内", fails)
	var edges := Targeting.ring_outline_edges(ring)
	# 描边的定义：每一段的两侧必须"一在内、一在外"（否则就是画进内部了）
	var bad_edges := 0
	var not_unit := 0
	for e in edges:
		var ea: Vector2 = e[0]
		var eb: Vector2 = e[1]
		if absf(ea.distance_to(eb) - 1.0) > 0.001:
			not_unit += 1
		var mid := (ea + eb) * 0.5
		var n := Vector2(eb.y - ea.y, ea.x - eb.x)
		var c1 := Vector2i(int(floor(mid.x + n.x * 0.5)), int(floor(mid.y + n.y * 0.5)))
		var c2 := Vector2i(int(floor(mid.x - n.x * 0.5)), int(floor(mid.y - n.y * 0.5)))
		if ring.has(c1) == ring.has(c2):
			bad_edges += 1
	print("    格数 %d，描边段 %d（非单位长 %d，两侧同在内/外 %d）" % [
		ring.size(), edges.size(), not_unit, bad_edges])
	_expect(not_unit == 0, "描边每一段都是一个格边长（沿方格边缘走）", fails)
	_expect(bad_edges == 0, "描边只画在'内格与外格之间'，不画内部、不漏外圈", fails)
	# 高亮节点：两个 MeshInstance3D（柔光 + 亮芯），只靠边缘不填充
	var srs := SentryRange.make_item(1, 3, Vector2i(5, 5), 48, 48, null)
	var srs_node: Node3D = srs["node"]
	var mesh_kids := 0
	for c in srs_node.get_children():
		if c is MeshInstance3D:
			mesh_kids += 1
	_expect(srs["edges"] == edges.size() and mesh_kids == 2, "高亮节点应只有两层描边网格", fails)
	print("    高亮：格 %d，描边 %d 段，网格 %d 层" % [srs["cells"], srs["edges"], mesh_kids])
	srs_node.free()

	# ── 距离散步（用户标定：5 格内无散步；20 格散步圆直径 3 格）──
	print("\n── 距离散步 ──")
	_expect(Spread.radius(5.0) == 0.0, "5 格以内完全没有散步", fails)
	_expect(Spread.radius(3.0) == 0.0, "更近当然也没有散步", fails)
	var r20 := Spread.radius(20.0)
	print("    半径：8格 %.3f ｜ 12格 %.3f ｜ 20格 %.3f ｜ 40格 %.3f" % [
		Spread.radius(8.0), Spread.radius(12.0), r20, Spread.radius(40.0)])
	_expect(absf(r20 - 1.5) < 0.0001, "20 格散步半径 = 1.5（直径 3 格）", fails)
	_expect(Spread.radius(40.0) > Spread.radius(20.0) * 3.4, "越远越飘（二次增长、不封顶）", fails)
	_expect(absf(Spread.radius_from_time(Spread.flight_time(20.0)) - r20) < 0.0001,
		"按飞行时间算与按距离算一致（用户口径：按飞行时间）", fails)
	var rng_s := RngService.new(7)
	var off_s := Spread.offset(20.0, Spread.ARROW_SPEED, rng_s)
	print("    一次抽样偏移 = (%.2f, %.2f)，长度 %.3f" % [off_s.x, off_s.y, off_s.length()])
	_expect(off_s.length() <= r20 + 0.0001, "抽样偏移必须落在散步圆内", fails)

	# ── 被动表 + 弹反受理（每轮一次）──
	print("\n── 被动 ──")
	var gerald_p: Unit = null
	for d in UnitData.UNITS:
		if String(d.get("name", "")) == "Gerald":
			gerald_p = Unit.from_data(d)
	_expect(gerald_p != null, "数据表里能构造出 Gerald", fails)
	if gerald_p != null:
		_expect(Passives.has(gerald_p, "arrow_deflect"), "杰拉尔德应有『箭矢弹反』被动", fails)
		var pd := Passives.def("arrow_deflect")
		_expect((pd.get("windows", []) as Array) == [2.0, 1.0, 1.0],
			"按键窗口 = 2 / 1 / 1 秒（用户口径：第一个宽松）", fails)
		_expect((pd.get("keys", []) as Array).size() == 6, "提示键从 qweasd 六个里随机取", fails)
		var fake := Unit.from_data(UnitData.ENEMIES[0])
		_expect(not Passives.has(fake, "arrow_deflect"), "别的单位没有这个被动", fails)
		var gm_p := GameMaster.new()
		_expect(gm_p.claim_arrow_deflect(gerald_p), "第一次被箭命中 -> 可以弹反", fails)
		_expect(not gm_p.claim_arrow_deflect(gerald_p), "弹反过一次就置 0（同一轮里十支箭也只有第一支给机会）", fails)
		_expect(not gm_p.claim_arrow_deflect(fake), "没有被动的单位永远不受理", fails)
		gm_p.on_turn_begin(fake)
		_expect(not gm_p.claim_arrow_deflect(gerald_p), "别人回合开始不会重置杰拉尔德的 flag", fails)
		gm_p.on_turn_begin(gerald_p)
		_expect(gm_p.claim_arrow_deflect(gerald_p), "轮到杰拉尔德自己的回合 -> flag 置 1", fails)
		# 弹反落点 = 射手格子 + 弹反专用散步（翻倍、且没有 100% 准确区）
		gerald_p.cell = Vector2i(5, 5)
		fake.cell = Vector2i(25, 5)                      # 正好 20 格
		var land := gm_p.reflect_landing(gerald_p, fake, RngService.new(11))
		var ld := Vector2(25.5, 5.5).distance_to(land)
		print("    弹反落点 %s，离射手 %.3f 格（20 格的弹反散步半径 %.3f）" % [
			land, ld, Spread.reflect_radius(20.0)])
		_expect(ld <= Spread.reflect_radius(20.0) + 0.0001, "弹反落点必须落在散步圆内", fails)
		_expect(absf(Spread.reflect_radius(20.0) - Spread.radius(20.0) * 2.0) < 0.0001,
			"弹反散步在 20 格处是普通散步的两倍（1.5 -> 3.0）", fails)
		_expect(Spread.reflect_radius(2.0) > 0.0, "弹反没有 100% 准确区（2 格也有散布）", fails)
		_expect(Spread.radius(2.0) == 0.0, "普通散步仍然有 5 格内的准确区", fails)

	# ── 空爆：三维判定 + 范围恒定为一格球 ──
	print("\n── 空爆（一格球，三维）──")
	var cell := Vector2i(5, 5)
	_expect(Targeting.sphere_hits_body(Vector3(5.5, 0.5, 5.5), 0.5, cell, 0.30, 1.0),
		"爆心在角色身上（高 0.5）-> 命中", fails)
	_expect(Targeting.sphere_hits_body(Vector3(5.9, 0.5, 5.5), 0.5, cell, 0.30, 1.0),
		"爆心偏 0.4 格 -> 仍命中（球半径 0.5 + 身体半径 0.3）", fails)
	_expect(not Targeting.sphere_hits_body(Vector3(6.5, 0.5, 5.5), 0.5, cell, 0.30, 1.0),
		"爆心偏 1 格 -> 不命中（一格球就这么大）", fails)
	_expect(not Targeting.sphere_hits_body(Vector3(5.5, 2.5, 5.5), 0.5, cell, 0.30, 1.0),
		"头顶 2.5 格高炸开 -> 打不到（三维判定）", fails)
	_expect(Targeting.sphere_hits_body(Vector3(5.5, 1.4, 5.5), 0.5, cell, 0.30, 1.0),
		"高 1.4 格还在身体高度里 -> 命中", fails)
	# 一体化：真的结算一次
	var ab_unit := Unit.from_data(UnitData.ENEMIES[0])
	ab_unit.cell = Vector2i(5, 5)
	ab_unit.power_cur = ab_unit.power_max
	ab_unit.armor_cur = Rules.points_to_milli(10)
	var ab_opts := Combat.opts({"power": Rules.points_to_milli(30), "rng": RngService.new(3)})
	var ab_hits: Array = Damage.air_burst(null, Vector3(5.5, 0.6, 5.5), ab_opts,
		[ab_unit] as Array[Unit])
	_expect(ab_hits.size() == 1, "贴地空爆应该打中（一格球内）", fails)
	var ab_unit2 := Unit.from_data(UnitData.ENEMIES[0])
	ab_unit2.cell = Vector2i(5, 5)
	ab_unit2.power_cur = ab_unit2.power_max
	var ab_hits2: Array = Damage.air_burst(null, Vector3(5.5, 3.0, 5.5), ab_opts,
		[ab_unit2] as Array[Unit])
	_expect(ab_hits2.is_empty(), "高空空爆打不到人", fails)

	# ── 加农炮弹 ──
	print("\n── 加农炮弹 ──")
	_expect(Ordnance.CANNON_TILES_PER_SEC == 12.0, "弹速 12 格/秒", fails)
	_expect(Ordnance.CANNON_RANGE == 15.0, "最大射程 15 格", fails)
	_expect(absf(Ordnance.CANNON_R * 2.0 - 0.5) < 0.0001, "大小 = 直径 0.5 格的球", fails)
	var can_caster := Unit.from_data(UnitData.ENEMIES[0])
	can_caster.cell = Vector2i(3, 3)
	var can_p := Ordnance.make_cannon(can_caster, Vector3(3.5, 0.8, 3.5), Vector3(12.5, 0.55, 3.5), true)
	_expect(can_p.kind == Projectile.KIND_CANNON, "是加农炮弹这一类", fails)
	_expect(absf(can_p.dur - 9.0 / 12.0) < 0.001, "9 格飞行 = 0.75 秒（12 格/秒）", fails)
	_expect(can_p.hit_tags.is_empty() and not can_p.sentry_trigger,
		"箭矢类：不会被击落、也不惊动哨兵", fails)
	_expect(absf(can_p.shot.power_mult - 0.5) < 0.0001, "发射单上写着：只吃 50% 力量", fails)
	_expect(Ballistics.is_direct_hit(Projectile.KIND_CANNON), "加农炮弹走直接命中判定", fails)
	# 50% 力量的那一刀：先乘 50% 再减护甲
	var can_target := Unit.from_data(UnitData.ENEMIES[1])
	can_target.armor_cur = Rules.points_to_milli(30)
	can_target.power_cur = can_target.power_max
	var can_opts := Combat.opts({
		"power": int(floor(200000.0 * Ordnance.CANNON_POWER_MULT)),
		"rng": RngService.new(5)})
	var can_res: Combat.Result = Combat.deal_to_unit(can_target, can_opts)
	print("    200 力的加农炮打 30 甲：实际 %d 点（(200×50%%)-30 = 70）" % (can_res.power_dmg / 1000))
	_expect(can_res.power_dmg == Rules.points_to_milli(70), "力量先乘 50% 再减护甲 = 70 点", fails)

	# ── 被动：投掷手「装填」/ 弓箭手「蓄势」/ 新角色 ──
	print("\n── 新被动 ──")
	var thrower_p: Unit = null
	for d in UnitData.UNITS:
		if String(d.get("name", "")) == "Airburst mortar":
			thrower_p = Unit.from_data(d)
	_expect(Passives.has(thrower_p, "loader"), "投掷手有【装填】", fails)
	thrower_p.begin_turn()
	_expect(Passives.end_turn_energy(thrower_p) == 2, "本回合没移动 -> 补 2 点精力", fails)
	thrower_p.has_moved = true
	_expect(Passives.end_turn_energy(thrower_p) == 0, "移动过就没有了", fails)
	# 休息叠加：休息补 rest_energy(2) + 装填 2 = 4
	thrower_p.begin_turn()
	var e0: int = thrower_p.energy
	thrower_p.energy = maxi(0, thrower_p.energy - 4000)
	thrower_p.rest()
	thrower_p.energy = mini(thrower_p.energy_max,
		thrower_p.energy + Rules.points_to_milli(Passives.end_turn_energy(thrower_p)))
	print("    投掷手休息+装填：精力 %d -> %d（共 +4）" % [e0 / 1000, thrower_p.energy / 1000])
	_expect(thrower_p.energy - (e0 - 4000) == Rules.points_to_milli(4), "休息 + 装填 = 共 4 点精力", fails)
	# 弓箭手「蓄势」
	var arch: Unit = null
	for d in UnitData.UNITS:
		if String(d.get("name", "")) == "Alette":
			arch = Unit.from_data(d)
	_expect(Passives.has(arch, "arrow_focus"), "弓箭手有【蓄势】", fails)
	_expect(Passives.focus_bonus_milli(arch) == 0, "没层数就没加成", fails)
	Passives.add_focus(arch)
	Passives.add_focus(arch)
	Passives.add_focus(arch)
	print("    蓄势 3 层 -> 下一发普攻 +%d 力量" % (Passives.focus_bonus_milli(arch) / 1000))
	_expect(Passives.focus_bonus_milli(arch) == Rules.points_to_milli(12), "3 层 = +12 力量", fails)
	Passives.clear_focus(arch)
	_expect(Passives.focus_bonus_milli(arch) == 0, "命中后清零", fails)
	# 加成加在"力量-护甲"那一段：52+12=64 力打 52 甲、物抗高(0.8) -> (64-52)*0.2 = 2.4 -> 2
	var aim := Unit.from_data(UnitData.ENEMIES[3])          # Gerald (E)：52 甲、物抗高
	aim.armor_cur = aim.armor_max
	aim.power_cur = aim.power_max
	var pv: Rules.Preview = Rules.preview(64000, aim.armor_cur, 800)
	print("    52力+12蓄势 打 52甲/物抗高：(64-52)×0.2 = %.1f -> %d 点" % [pv.d_milli / 1000.0, pv.damage])
	_expect(pv.damage == 2, "蓄势加在力量-护甲那一段（会被抗性减伤）", fails)
	# 新角色
	var king_data := {}
	var princess_data := {}
	var princess_n := 0
	for d in UnitData.UNITS:
		if String(d.get("name", "")) == "老国王": king_data = d
		if String(d.get("name", "")) == "公主·左": princess_data = d
	for d in UnitData.UNITS:
		if String(d.get("name", "")).begins_with("公主"): princess_n += 1
	for d in UnitData.ENEMIES:
		if String(d.get("name", "")).begins_with("公主"): princess_n += 1
	_expect(princess_n == 4, "一共 4 个公主（两边各 2）", fails)
	_expect(int(princess_data.get("power", 0)) == 25 and int(princess_data.get("armor", 0)) == 0,
		"公主 25 血 / 无甲", fails)
	_expect(int(princess_data.get("rng_max", 0)) == 12, "公主射界 12 格", fails)
	_expect(int(king_data.get("power", 0)) == 100 and int(king_data.get("armor", 0)) == 50,
		"老国王 100 血 / 50 甲", fails)
	_expect(int(king_data.get("rng_max", 0)) == 15 and int(king_data.get("role", -1)) == UnitData.Role.RANGED,
		"老国王是远程、射程 15（不能被解析成投掷手）", fails)
	var king_u := Unit.from_data(king_data)
	var princess_u := Unit.from_data(princess_data)
	_expect(Passives.has(king_u, "cannon_ai"), "老国王有加农炮 AI", fails)
	_expect(Passives.has(princess_u, "always_sentry") and not princess_u.no_turn,
		"公主带常驻哨兵标记（no_turn 由场景设置）", fails)
	princess_u.no_turn = true
	_expect(not princess_u.has_turn(), "公主没有自己的回合（不进队列、不算英雄）", fails)
	_expect(king_u.has_turn(), "老国王有自己的回合", fails)

	# ── 技能消耗 ──
	print("\n── 技能消耗 ──")
	_expect(int(Skills.get_def("carpet_bomb")["cost"]) == 6, "地毯式轰炸 = 6 精力", fails)
	_expect(int(Skills.get_def("orbital_strike")["cost"]) == 2, "轨道空爆 = 2 精力", fails)
	# 用户口径：近战不许用轨道空爆（技能按职业发，投掷手专属）
	var dummy_melee := Unit.from_data(by_name["Gerald"])
	var dummy_throw := Unit.from_data(by_name["Airburst mortar"])
	_expect(Skills.skills_for(dummy_melee).has("orbital_strike"), "轨道空爆是杰拉尔德（近战）的技能", fails)
	_expect(not Skills.skills_for(dummy_melee).has("carpet_bomb"), "近战没有地毯式轰炸", fails)
	_expect(Skills.skills_for(dummy_throw).has("carpet_bomb")
		and not Skills.skills_for(dummy_throw).has("orbital_strike"), "投掷手只有地毯式轰炸", fails)
	_expect(Skills.skills_for(Unit.from_data(by_name["Alette"])).has("sentry"), "弓箭手有哨兵", fails)

	# ── TurnFlow：胜负只看国王 / 最后一人 ──
	print("\n── 回合机决策 ──")
	var mk := func(nm: String, side: int, can_turn: bool) -> Unit:
		var d := (UnitData.UNITS[0] if side == UnitData.Side.PLAYER else UnitData.ENEMIES[0]).duplicate()
		d["name"] = nm
		d["side"] = side
		var uu := Unit.from_data(d)
		uu.controllable = can_turn
		return uu
	var a1: Unit = mk.call("P1", UnitData.Side.PLAYER, true)
	var a2: Unit = mk.call("P2", UnitData.Side.PLAYER, true)
	var b1: Unit = mk.call("E1", UnitData.Side.ENEMY, true)
	var dummy: Unit = mk.call("Dummy X", UnitData.Side.ENEMY, false)
	var pk: Unit = mk.call("P国王", UnitData.Side.PLAYER, true)
	var ek: Unit = mk.call("E国王", UnitData.Side.ENEMY, true)
	pk.is_king = true
	ek.is_king = true
	_expect(TurnFlow.winner([a1, a2, b1, dummy, pk, ek] as Array[Unit]) == TurnFlow.NONE,
		"双方国王都活着时不分胜负", fails)
	# 用户口径：英雄死光也没关系（能无限重生），**只看国王**
	var dead_heroes: Array[Unit] = [pk, ek, dummy]
	a1.power_cur = 0
	a2.power_cur = 0
	b1.power_cur = 0
	_expect(TurnFlow.winner([pk, ek, a1, a2, b1] as Array[Unit]) == TurnFlow.NONE,
		"英雄全灭但两个国王都在 -> 还不分胜负", fails)
	ek.power_cur = 0
	_expect(TurnFlow.winner([pk, ek] as Array[Unit]) == TurnFlow.PLAYER, "敌方国王死 -> 玩家胜", fails)
	ek.power_cur = ek.power_max
	pk.power_cur = 0
	_expect(TurnFlow.winner([pk, ek] as Array[Unit]) == TurnFlow.ENEMY, "我方国王死 -> 敌方胜", fails)
	pk.power_cur = pk.power_max
	a1.power_cur = a1.power_max
	b1.power_cur = b1.power_max
	dummy.is_king = false
	_expect(TurnFlow.winner([a1, b1, dummy] as Array[Unit]) == TurnFlow.PLAYER,
		"场上没有敌方国王（关卡没配）时按敌方失败处理", fails)
	# 1 vs 1（+假人）-> 不该进连击，应严格交替
	a2.power_cur = 0
	var du := TurnFlow.last_stand_plan([a1, b1, dummy] as Array[Unit], false, false)
	_expect(not bool(du["want"]), "1 英雄 vs 1 英雄不该进连击（假人不算）", fails)
	# 1 vs 2 -> 应进入连击，对手只含英雄
	b1.power_cur = b1.power_max          # 复活（前面测胜负时把它打死了）
	var b2: Unit = mk.call("E2", UnitData.Side.ENEMY, true)
	var hc: Array = TurnFlow.hero_counts([a1, b1, b2, dummy] as Array[Unit])
	print("    英雄数 P=%d E=%d ｜ a1.alive=%s b1.alive=%s b2.alive=%s" % [hc[0], hc[1], a1.is_alive(), b1.is_alive(), b2.is_alive()])
	var plan := TurnFlow.last_stand_plan([a1, b1, b2, dummy] as Array[Unit], false, false)
	_expect(bool(plan["want"]), "1 英雄 vs 2 英雄应进入最后一人连击", fails)
	_expect(bool(plan["changed"]), "状态变化时应报告 changed", fails)
	_expect((plan["opponents"] as Array).size() == 2, "对手列表应只含英雄（不含假人）", fails)
	_expect(plan["lone"] == a1, "孤军应是仅存的那个英雄", fails)
	# 已经在连击里、孤军还活着 -> 保持不变
	var keep := TurnFlow.last_stand_plan([a1, b1, b2, dummy] as Array[Unit], true, true)
	_expect(bool(keep["want"]) and not bool(keep["changed"]), "连击保持时不应重排", fails)
	# 对面复活到 3 人也必须保持
	var b3: Unit = mk.call("E3", UnitData.Side.ENEMY, true)
	var keep3 := TurnFlow.last_stand_plan([a1, b1, b2, b3] as Array[Unit], true, true)
	_expect(bool(keep3["want"]), "对面复活后连击必须保持", fails)
	# 孤军死了 -> 退出连击
	var gone := TurnFlow.last_stand_plan([a1, b1, b2] as Array[Unit], true, false)
	_expect(not bool(gone["want"]), "孤军阵亡后应退出连击", fails)

	# ── 破片（新增弹射物）──
	print("\n── 破片 ──")
	_expect(Projectile.KIND_FRAGMENT == "fragment", "破片是一种弹射物类型", fails)
	_expect(Ballistics.is_direct_hit(Projectile.KIND_FRAGMENT), "破片算直接命中（会打角色）", fails)
	var fr_c: Unit = Unit.from_data(by_name["Gerald"])
	var fr_p := Ordnance.make_fragment(fr_c, Vector3(5.5, 0.5, 5.5), Vector2(1, 0))
	_expect(absf(fr_p.y0 - 0.5) < 0.001 and absf(fr_p.y1 - 0.5) < 0.001, "破片全程离地 0.5 格", fails)
	_expect(fr_p.apex <= 0.001, "破片不受重力（没有拱高）", fails)
	_expect(absf(fr_p.dur * Ordnance.FRAGMENT_TILES_PER_SEC - Ordnance.FRAGMENT_MAX_DIST) < 0.01,
		"破片 4 格/秒，飞 20 格后消失", fails)
	_expect(fr_p.hit_tags.is_empty() and not fr_p.sentry_trigger, "破片是箭矢类：不会被击落、不惊动哨兵", fails)
	_expect(fr_p.from.distance_to(fr_p.pos()) < 0.01 and not fr_p.alive == false, "破片从生成点出发", fails)
	var fr_vals := [
		[0.0, 25, 25], [1.5, 18, 18], [3.0, 12, 12], [9.5, 6, 6], [16.0, 0, 0], [20.0, 0, 0]]
	for row in fr_vals:
		var d: float = row[0]
		var pw: int = Damage.fragment_power_milli(d) / 1000
		var bk: int = Damage.fragment_break_milli(d) / 1000
		print("    距离 %4.1f 格 → 力 %2d / 甲 %2d" % [d, pw, bk])
		_expect(pw == int(row[1]) and bk == int(row[2]), "破片 %.1f 格伤害 = %d/%d" % [d, row[1], row[2]], fails)

	# ── 俯冲轰炸直升机（第 1 步：数据 + 场景元数据）──
	print("\n── 直升机 ──")
	var heli_name := "俯冲轰炸直升机（不要问那么多）"
	var heli_d := {}
	for d in UnitData.UNITS:
		if String(d["name"]) == heli_name:
			heli_d = d
	_expect(not heli_d.is_empty(), "花名册里有直升机（名字含全角括号）", fails)
	_expect(int(heli_d.get("power", 0)) == 41 and int(heli_d.get("armor", 0)) == 12,
		"直升机 41 力 / 12 甲", fails)
	_expect(int(heli_d.get("energy_max", 0)) == 6 and int(heli_d.get("move", 0)) == 20,
		"精力 6 / 移动 20", fails)
	_expect(int(heli_d.get("role", -1)) == UnitData.Role.THROWER, "套皮投掷手", fails)
	_expect(int(heli_d.get("rng_min", 0)) == 6 and int(heli_d.get("rng_max", 0)) == 40,
		"普攻射程 6-40（投掷手的两倍）", fails)
	_expect(Unit.base_name(heli_name) == heli_name, "全角括号不会被当后缀剥掉", fails)
	_expect(Unit.base_name(heli_name + " (E)") == heli_name, "敌方镜像用 (E) 后缀", fails)
	# 场景元数据：竞技场 25 回合重生，测试场缺省 10
	_expect(Level.respawn_turns(heli_name, "arena") == 25, "皇室竞技场：直升机重生要 25 个回合", fails)
	_expect(Level.respawn_turns(heli_name, "field") == GameMaster.HERO_REVIVE_TURNS,
		"测试场没有覆盖 -> 用缺省 10 回合", fails)
	# 两个场景都要收录（本体 + 镜像）
	for lv in ["field", "arena"]:
		var names: Array = []
		for e in Level.roster(lv):
			names.append(String(e[0]))
		_expect(names.has(heli_name) and names.has(heli_name + " (E)"),
			"%s 场景名单里应有直升机本体与镜像" % lv, fails)

	# ── 火箭（37mm，变速炮弹）──
	print("\n── 火箭 ──")
	_expect(Projectile.KIND_ROCKET == "rocket", "火箭是独立弹种", fails)
	_expect(absf(Ordnance.ROCKET_DIAMETER - 0.37) < 0.001 and absf(Ordnance.ROCKET_LEN - 0.7) < 0.001,
		"火箭 直径 0.37 / 长 0.7", fails)
	# 速度函数：v(0)=2、v(12)=6、之后封顶 6；t(12)=3·ln3=3.295837
	var sp_vals := [[0.0, 2.0], [4.0, 10.0 / 3.0], [8.0, 14.0 / 3.0], [12.0, 6.0], [16.0, 6.0], [32.0, 6.0]]
	for row3 in sp_vals:
		var sv := Ordnance.rocket_speed_at(float(row3[0]))
		_expect(absf(sv - float(row3[1])) < 0.0001, "火箭 %.0f 格处速度 %.4f" % [float(row3[0]), float(row3[1])], fails)
	_expect(absf(Ordnance.rocket_t_of_s(12.0) - 3.0 * log(3.0)) < 0.0001, "飞满 12 格耗时 3·ln3 ≈ 3.2958 秒", fails)
	_expect(absf(Ordnance.rocket_s_of_t(Ordnance.rocket_t_of_s(12.0)) - 12.0) < 0.001,
		"反解与闭式解自洽（s(t(12)) = 12）", fails)
	# 单调性：距离越远总时长越长，且平均速度介于 2~6 之间
	var t4 := Ordnance.rocket_t_of_s(4.0)
	var t40 := Ordnance.rocket_t_of_s(40.0)
	_expect(t40 > t4 and t4 > 0.0, "总时长随距离单调增加", fails)
	_expect(4.0 / t4 > 2.0 and 4.0 / t4 < 6.0, "前 4 格平均速度在 2~6 之间", fails)
	# 工厂：半径/剖面/不惊动哨兵/落地半径 1 格
	var heli_u := Unit.from_data(heli_d)
	var rk := Ordnance.make_rocket(heli_u, Vector3(5.5, 2.0, 5.5), Vector2(25.5, 5.5), true)
	_expect(absf(rk.hit_r - 0.185) < 0.001, "火箭碰撞半径 = 直径的一半", fails)
	_expect(rk.speed_profile == Projectile.SPEED_ROCKET, "火箭走变速剖面", fails)
	_expect(rk.hit_tags.is_empty() and not rk.sentry_trigger, "火箭不被打掉、不惊动哨兵", fails)
	_expect(absf(rk.dur - Ordnance.rocket_t_of_s(20.0)) < 0.001, "总时长 = 解析解 t(20 格)", fails)
	_expect(absf(float(Ordnance.ROCKET_BLAST_R) - 1.0) < 0.001, "落地范围直径 2 格（半径 1）", fails)
	_expect(int(Ordnance.ROCKET_FRAGMENTS) == 2, "落地生成 2 枚破片", fails)
	# 位置映射：t=0 在起点、t=1 在终点，且 t=50% 时飞过的距离 < 一半（前半段更慢）
	var rk2 := Ordnance.make_rocket(heli_u, Vector3(5.5, 2.0, 5.5), Vector2(25.5, 5.5), true)
	rk2.t = 0.0
	var rd0 := rk2.from.distance_to(rk2.pos())
	rk2.t = 1.0
	var rd1 := rk2.from.distance_to(rk2.pos())
	rk2.t = 0.5
	var rdh := rk2.from.distance_to(rk2.pos())
	print("    位置映射：t=0 -> %.2f 格 ｜ t=0.5 -> %.2f 格 ｜ t=1 -> %.2f 格" % [rd0, rdh, rd1])
	_expect(absf(rd0) < 0.001 and absf(rd1 - 20.0) < 0.01, "火箭从起点飞到终点", fails)
	_expect(rdh < 10.0, "前半段飞得更慢（变速生效）", fails)
	# 场景元数据：镜像名靠 base_name 命中 25
	_expect(Level.respawn_turns(heli_name + " (E)", "arena") == 25,
		"敌方镜像的重生回合数也走场景元数据（base_name 兜底）", fails)

	# ── AI 会用新技能（防回归：这两条曾被一次并发写入冲掉）──
	print("\n── AI 技能选择 ──")
	var sani2 := Unit.from_data(by_name["萨尼铁塔"])
	sani2.cell = Vector2i(10, 10)
	sani2.energy = sani2.energy_max
	var f1 := Unit.from_data(by_name["Gerald (E)"]) if false else Unit.from_data(by_name["Gerald"])
	f1.cell = Vector2i(14, 10)
	var f2 := Unit.from_data(by_name["Alette"])
	f2.cell = Vector2i(15, 10)
	var gctx2 := Ai.Ctx.new()
	gctx2.rng = RngService.new(11)
	gctx2.me = sani2
	gctx2.foes = [f1, f2]
	gctx2.foe_king = null
	var gplan := Ai.plan(gctx2)
	print("    萨尼铁塔 AI：%s" % gplan.get("note", "-"))
	_expect(String(gplan.get("action", "")) == "skill" and String(gplan.get("skill", "")) == "grenade_launcher",
		"AI 会用枪榴弹（≥2 人挤在一起时）", fails)

	# ── 弓箭手 AI：在敌方投掷手射程内却够不着它 -> 开哨兵 ──
	print("\n── 弓箭手哨兵决策 ──")
	var arch2 := Unit.from_data(by_name["Alette"])            # 射程 1-8，有哨兵
	var mortar_e := {}
	for d in UnitData.ENEMIES:
		if String(d["name"]) == "Airburst mortar (E)":
			mortar_e = d
	var thrower_e := Unit.from_data(mortar_e)                # 敌方投掷手
	thrower_e.cell = Vector2i(30, 30)

	var mk_ctx := func(archer_cell: Vector2i, reach: Dictionary) -> Ai.Ctx:
		var c := Ai.Ctx.new()
		c.rng = RngService.new(5)
		c.me = arch2
		c.foes = [thrower_e]
		c.foe_king = null
		c.reachable = reach
		c.me_has_sentry = false
		arch2.cell = archer_cell
		arch2.energy = arch2.energy_max
		return c
	# ① 在投掷手射程内（3-20）、走位也够不着（射程只有 8）-> 开哨兵
	var far_cell := Vector2i(30, 45)                          # 距离 15
	var c1: Ai.Ctx = mk_ctx.call(far_cell, {Vector2i(30, 44): true, Vector2i(30, 43): true})
	var pl1 := Ai.plan(c1)
	print("    距离 15（打不到）：%s" % pl1.get("note", "-"))
	_expect(String(pl1.get("action", "")) == "skill" and String(pl1.get("skill", "")) == "sentry",
		"在敌方投掷手射程内却够不着 -> 开哨兵", fails)
	# ② 在投掷手射程内、但现位置就能打到它 -> 不应该开哨兵
	var near_cell := Vector2i(30, 36)                         # 距离 6，在弓手射程 1-8 内
	var c2: Ai.Ctx = mk_ctx.call(near_cell, {})
	var pl2 := Ai.plan(c2)
	print("    距离 6（打得到）：%s" % pl2.get("note", "-"))
	_expect(String(pl2.get("action", "")) == "attack",
		"够得着投掷手时应直接打，而不是开哨兵", fails)
	# ③ 不在投掷手射程内（距离 25 > 20）-> 不因此开哨兵
	var c3: Ai.Ctx = mk_ctx.call(Vector2i(30, 55), {})
	var pl3 := Ai.plan(c3)
	print("    距离 25（它够不着我）：%s" % pl3.get("note", "-"))
	_expect(not (String(pl3.get("action", "")) == "skill" and String(pl3.get("skill", "")) == "sentry"),
		"不在敌方投掷手射程内时不该因这条规则开哨兵", fails)

	# ── 萨尼铁塔：枪榴弹 / 圣萨尼 ──
	print("\n── 萨尼铁塔 ──")
	var sani := Unit.from_data(by_name["萨尼铁塔"])
	_expect(int(by_name["萨尼铁塔"]["power"]) == 26 and int(by_name["萨尼铁塔"]["armor"]) == 5,
		"萨尼铁塔 26 力 / 5 甲", fails)
	_expect(int(by_name["萨尼铁塔"]["move"]) == 6 and int(by_name["萨尼铁塔"]["energy_max"]) == 4,
		"移动 6 / 精力 4", fails)
	_expect(int(by_name["萨尼铁塔"]["armor_break"]) == 8, "破甲 8", fails)
	_expect(Skills.skills_for(sani).has("grenade_launcher"), "她有【枪榴弹】", fails)
	_expect(not Skills.skills_for(Unit.from_data(by_name["Alette"])).has("grenade_launcher"),
		"枪榴弹只有萨尼铁塔有", fails)
	var sani_e := {}
	for d in UnitData.ENEMIES:
		if String(d["name"]) == "萨尼铁塔 (E)":
			sani_e = d
	_expect(not sani_e.is_empty() and Skills.skills_for(Unit.from_data(sani_e)).has("grenade_launcher"),
		"敌方镜像也有【枪榴弹】", fails)
	# 每个技能的 summary / detail_text 都必须能构造出来（缺字段会当场崩，用户报过一次）
	for sid in Skills.DEFS.keys():
		var summ: String = Skills.summary(String(sid))
		var det: String = Skills.detail_text(String(sid))
		_expect(summ.length() > 0 and det.length() > 0,
			"技能 %s 的摘要与说明能正常生成" % String(sid), fails)
	var gd := Skills.get_def("grenade_launcher")
	_expect(int(gd["cost"]) == 2, "枪榴弹 2 精力", fails)
	_expect(int(gd["delay_turns"]) == 4, "落地后 4 个回合爆炸（GM 时钟）", fails)
	_expect(int(gd["fragments"]) == 8, "爆炸出 8 枚破片", fails)
	_expect(absf(float(gd["range_max"]) - 20.0) < 0.01 and absf(float(gd["range_min"]) - 3.0) < 0.01,
		"射程与投掷手一致（3-20）", fails)
	_expect(Passives.has(sani, "holy_sani"), "她有【圣萨尼】", fails)
	var hs := Passives.def("holy_sani")
	_expect(bool(hs.get("revive", false)) and int(hs.get("uses_per_life", 0)) == 1,
		"圣萨尼：每条命一次、用于复活", fails)
	# 子弹阶梯（同时作用于破甲与力量）
	for row2 in [[0.0, 1.0], [12.0, 1.0], [12.1, 0.6], [16.0, 0.6], [16.1, 0.2], [24.0, 0.2], [24.1, 0.0]]:
		_expect(absf(Damage.bullet_mult(float(row2[0])) - float(row2[1])) < 0.001,
			"子弹 %.1f 格倍率 = %.0f%%" % [float(row2[0]), float(row2[1]) * 100.0], fails)
	var bp := Ordnance.make_bullet(sani, Vector3(5.5, 0.5, 5.5), Vector2(6.5, 5.5), true)
	_expect(absf(bp.dur * Ordnance.BULLET_TILES_PER_SEC - Ordnance.BULLET_MAX_DIST) < 0.05,
		"子弹 12 格/秒，32 格消失", fails)
	_expect(absf(bp.y0 - 0.5) < 0.001 and bp.apex <= 0.001, "子弹无重力、离地 0.5 格", fails)
	_expect(bp.hit_tags.is_empty() and not bp.sentry_trigger, "子弹是箭矢类：不会被击落、不惊动哨兵", fails)
	# 线性散布：12 格 -> 1 格
	_expect(absf(Spread.linear_radius(12.0) - 1.0) < 0.001, "玩家侧散布 12 格 = 1 格半径", fails)
	_expect(absf(Spread.linear_radius(6.0) - 0.5) < 0.001, "线性：6 格 = 0.5 格", fails)
	# 手榴弹：空中按炮弹（能被击落、惊动哨兵）
	var gr := Ordnance.make_grenade(sani, Vector2(9.5, 9.5), true)
	_expect(gr.hit_tags.has("arrow") and gr.sentry_trigger, "枪榴弹空中=炮弹：会被击落、惊动哨兵", fails)
	_expect(gr.kind == Projectile.KIND_GRENADE, "枪榴弹是独立类型", fails)
	# 破片自伤：hit_self 关掉"跳过自己"
	var fr2 := Ordnance.make_fragment(sani, Vector3(3.5, 0.5, 3.5), Vector2(1, 0))
	_expect(not fr2.hit_self, "默认破片不打自己", fails)
	fr2.hit_self = true
	_expect(fr2.hit_self, "手榴弹破片可以打自己（用户口径）", fails)
	# GM：阵亡顺序 + 圣萨尼取人 + 手榴弹排程
	var gmh := GameMaster.new()
	var mate := Unit.from_data(by_name["Alette"])
	var other := Unit.from_data(by_name["Airburst mortar"])
	var king2 := Unit.from_data(by_name["老国王"])
	king2.is_king = true
	king2.no_turn = true
	other.power_cur = 0
	gmh.note_death(other)
	mate.power_cur = 0
	gmh.note_death(mate)
	var pool: Array[Unit] = [mate, other, king2]
	_expect(gmh.last_dead_teammate(UnitData.Side.PLAYER, pool) == mate,
		"圣萨尼取【最后一个阵亡】的队友", fails)
	gmh.note_death(king2)
	_expect(gmh.last_dead_teammate(UnitData.Side.PLAYER, pool) == mate,
		"老国王不算可复活队友（要跳过它取上一个）", fails)
	gmh.schedule_grenade(Vector2i(4, 4), "萨尼铁塔", UnitData.Side.PLAYER, 4)
	var due_g: Array = []
	for i in 4:
		due_g = gmh.dispatch_turn_boundary()
	_expect(due_g.size() == 1 and String(due_g[0].skill_id) == "grenade",
		"手榴弹 4 个回合边界后到期（GM 计时）", fails)

	# ── 关卡：测试场 + 皇室竞技场 ──
	print("\n── 关卡 ──")
	_expect(Level.ids().size() == 2 and Level.ids().has("field") and Level.ids().has("arena"),
		"两个关卡：测试场 + 皇室竞技场", fails)
	_expect(Level.gw("field") == 48 and Level.gh("field") == 48, "测试场 48×48", fails)
	_expect(Level.gw("arena") == 21 and Level.gh("arena") == 41, "竞技场 21×41", fails)
	_expect(not Level.has_river("field"), "测试场没有河", fails)
	# 竞技场：河 3 格宽、跨满 21 格；两座宽 2 的桥（左起 4 / 右起 4）
	var river := Level.river_cells("arena")
	var river_rows := {}
	for c in river.keys():
		river_rows[(c as Vector2i).y] = true
	_expect(river_rows.size() == 3 and river_rows.has(20), "河是中间 3 行（19/20/21）", fails)
	_expect(river.size() == 21 * 3 - 2 * 3 * 2, "河面格数 = 3×21 去掉两座桥（%d）" % river.size(), fails)
	_expect(not Level.is_river(Vector2i(4, 20), "arena") and not Level.is_river(Vector2i(5, 20), "arena"),
		"左桥（x=4,5）是正常地板", fails)
	_expect(not Level.is_river(Vector2i(15, 20), "arena") and not Level.is_river(Vector2i(16, 20), "arena"),
		"右桥（x=15,16）是正常地板", fails)
	_expect(Level.is_river(Vector2i(3, 20), "arena") and Level.is_river(Vector2i(17, 20), "arena"),
		"桥两侧是水", fails)
	_expect(not Level.is_river(Vector2i(10, 18), "arena") and not Level.is_river(Vector2i(10, 22), "arena"),
		"河只占中间 3 行，上下都是地板", fails)
	# 对称性：左右 / 前后都对称
	_expect(Level.is_river(Vector2i(0, 20), "arena") == Level.is_river(Vector2i(20, 20), "arena")
		and Level.is_river(Vector2i(2, 19), "arena") == Level.is_river(Vector2i(18, 19), "arena"),
		"竞技场左右对称", fails)
	# 出生点：国王居中在两条宽边上，公主在前 3 格左右各 5 格，英雄在两公主之间
	var pk_cell := Level.king_cell(UnitData.Side.PLAYER, "arena")
	var ek_cell := Level.king_cell(UnitData.Side.ENEMY, "arena")
	_expect(pk_cell == Vector2i(10, 0) and ek_cell == Vector2i(10, 40),
		"双方国王居中在两条宽边上（%s / %s）" % [pk_cell, ek_cell], fails)
	var pads: Array = Level.pad_cells(UnitData.Side.PLAYER, "arena")
	var heroes: Array = Level.hero_cells(UnitData.Side.PLAYER, "arena")
	print("    我方：国王 %s ｜ 公主 %s / %s ｜ 英雄 %s" % [pk_cell, pads[0], pads[1], heroes])
	_expect(pads[0] == Vector2i(5, 3) and pads[1] == Vector2i(15, 3),
		"公主在国王前 3 格、左右各 5 格", fails)
	_expect(heroes[0] == Vector2i(9, 18) and heroes[1] == Vector2i(10, 18) and heroes[2] == Vector2i(11, 18),
		"英雄出生点/重生点在河边居中三格", fails)
	var epads: Array = Level.pad_cells(UnitData.Side.ENEMY, "arena")
	var eheroes: Array = Level.hero_cells(UnitData.Side.ENEMY, "arena")
	_expect(epads[0] == Vector2i(5, 37) and eheroes[1] == Vector2i(10, 22),
		"敌方镜像对称（公主 3 格前、英雄在河另一侧居中三格）", fails)
	_expect(absf(Level.cam_yaw("arena") - Level.cam_yaw("field")) < 0.001, "两个关卡相机角度一致（与测试场同角度）", fails)

	# ── 英雄重生（GM 记 10 个回合）──
	print("\n── 英雄重生 ──")
	var gm_r := GameMaster.new()
	var hero_r := Unit.from_data(UnitData.UNITS[0])
	gm_r.schedule_hero_revive(hero_r)
	_expect(gm_r.revive_countdown(hero_r) == GameMaster.HERO_REVIVE_TURNS,
		"阵亡后要等 %d 个回合" % GameMaster.HERO_REVIVE_TURNS, fails)
	_expect(gm_r.due_revives().is_empty(), "还没到点不该复活", fails)
	for i in GameMaster.HERO_REVIVE_TURNS:
		gm_r.dispatch_turn_boundary()
	var back: Array = gm_r.due_revives()
	_expect(back.size() == 1 and back[0] == hero_r, "%d 个回合后该复活" % GameMaster.HERO_REVIVE_TURNS, fails)
	_expect(gm_r.due_revives().is_empty(), "复活只发一次（不会重复）", fails)

	# ── 汇总 ──
	print("── 规则自检 ──")
	if fails.is_empty():
		print("✅ 全部通过")
		quit(0)
	else:
		print("❌ 失败 %d 项：" % fails.size())
		for f in fails:
			print("   - ", f)
		quit(1)


func _expect(cond: bool, label: String, fails: Array[String]) -> void:
	if cond:
		print("  PASS  ", label)
	else:
		print("  FAIL  ", label)
		fails.append(label)


## 按名字取可放置物的数据（规则自检用）
func _pl_data(nm: String) -> Dictionary:
	for d in UnitData.PLACEABLES:
		if d["name"] == nm:
			return d
	return {}
