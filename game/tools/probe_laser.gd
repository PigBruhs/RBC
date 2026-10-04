# ══════════════════════════════════════════════════════════════════════════════
# 激光类（光束）探针（第 98 轮 · Boss-1）
#
# 为什么单独一个探针：激光**不是 Projectile**（不进 ProjectileField），它的三条特有口径
# 在既有测试网里完全没有覆盖：
#   ① 帧伤：每个物理帧累加、光束结束时**统一结算一次**（30 帧 × 2 点/帧 = 60）
#   ② 魔法伤害：**无视护甲**、只吃魔抗（`Damage.magic_hit`）
#   ③ 地形阻挡：土堆拦（停在那一格）、木刺不拦 —— 与箭矢同一处口径
# 另外把"光束在 6 格高、末端是攻击目标"的三维几何也断言掉
# （这条决定 Reaper 的激光到底能不能打到地面单位）。
#
# 运行： Godot_v4.7.2-stable_win64_console.exe --headless --path game \
#            --script res://tools/probe_laser.gd --quit-after 60000
# ══════════════════════════════════════════════════════════════════════════════
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


## 造一条穿过该单位的水平光束，推进 frames 帧后统一结算，返回力量池掉的血（千分比）。
## 测试用：把单位临时抬到"光束高度 ± 0.5"，让水平光束确实穿过它的身体。
## ⚠ 光束高度是 `Laser.BASE_HEIGHT`（第 102 轮：6 -> 3），**别再写死 5.5/6** ——
##   写死的话光束(3.0)会从身体([0,1])上方飞过，覆盖 0 帧、后面一串断言全部级联失败。
func _beam_drop(u: Unit, frames: int) -> int:
	u.hover = Laser.BASE_HEIGHT - 0.5
	var cx := float(u.cell.x) + 0.5
	var cz := float(u.cell.y) + 0.5
	var beam: LaserBeam = _s.t_spawn_laser("reaper_laser",
		Vector3(cx, Laser.BASE_HEIGHT, cz - 3.0), Vector3(cx, Laser.BASE_HEIGHT, cz + 3.0))
	var before: int = u.power_cur
	for i in frames:
		beam.tick(1.0 / 60.0)
	_s.t_settle_all_lasers()
	u.hover = 0.0
	return before - u.power_cur


## 场上按名字找一个沙盒道具（激光对道具造伤要用）
func _find_placeable(nm: String) -> Placeable:
	for pl in _s.placeables:
		if pl != null and pl.name.begins_with(nm) and pl.is_alive():
			return pl
	return null


func _initialize() -> void:
	_s = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(_s)
	for i in 8:
		await process_frame

	# ⚠ 关掉场景自己的 _process：本探针要**手工**逐帧推进激光。
	# 否则场景每帧也在 `laser_mod.tick(delta)`，帧数被两条路径同时累加，断言不可复现。
	# AI 本来也由 _process 驱动，一并停掉（探针只测激光规则）。
	_s.set_process(false)
	_s.t_set_ai_enabled(false)
	_s.t_set_autoplay_player(false)
	_s.placeables.clear()

	print("\n[0] 类型登记与契约常量")
	# 第 102 轮用户口径「激光初始高度减为 3」；⚠ 蓝环**仍在 6 格**（ReaperModel.RING_Y），两者解耦
	_chk(absf(Laser.BASE_HEIGHT - 3.0) < 0.0001,
		"Laser.BASE_HEIGHT = 3.0（光柱起点；蓝环仍 6 = ReaperModel.RING_Y，实际 %.1f）" % Laser.BASE_HEIGHT)
	_chk(absf(ReaperModel.RING_Y - 6.0) < 0.0001,
		"ReaperModel.RING_Y = 6.0（环没跟着降，实际 %.1f）" % ReaperModel.RING_Y)
	# 第 101 轮：用户口径「光柱理解为**直径 0.5 格**的圆柱」→ 判定半径 0.25（原 0.5）
	_chk(absf(Laser.HIT_R - 0.25) < 0.0001 and absf(Laser.HIT_R * 2.0 - 0.5) < 0.0001,
		"Laser.HIT_R = 0.25（= 直径 0.5 格，实际 %.3f）" % Laser.HIT_R)
	_chk(Laser.dmg_per_frame_of("reaper_laser") == 2, "reaper_laser 的帧伤 = 2 点/帧")
	_chk(Laser.dmg_per_frame_of("没登记的 id") == Laser.DEFAULT_DMG_PER_FRAME,
		"未登记的 id 走缺省帧伤 = %d" % Laser.DEFAULT_DMG_PER_FRAME)
	_chk(Projectile.KIND_LASER == "laser", "Projectile.KIND_LASER = \"laser\"")
	_chk(Ballistics.is_laser_class(Projectile.KIND_LASER)
		and not Ballistics.is_shell_class(Projectile.KIND_LASER),
		"激光自成一类：is_laser_class = true、is_shell_class = false")

	var gerald: Unit = null
	for u in _s.units:
		if Unit.base_name(u.name) == "Gerald":
			gerald = u
			break
	_chk(gerald != null, "场上找得到 Gerald（魔抗 0，适合验魔法伤害）")
	if gerald == null:
		_finish()
		return
	var gid := gerald.get_instance_id()

	# ══════════════════════════════════════════════════════════════════════════
	print("\n[1] 帧伤：30 帧 × 2 点/帧 = 60 点魔法伤害，且只结算一次")
	gerald.power_cur = gerald.power_max
	gerald.cell = Vector2i(10, 10)
	gerald.hover = Laser.BASE_HEIGHT - 0.5   # 身体抬到"光束高度 ± 0.5"，让水平光束穿过去
	var p0: int = gerald.power_cur
	var beam: LaserBeam = _s.t_spawn_laser("reaper_laser",
		Vector3(10.5, Laser.BASE_HEIGHT, 6.5), Vector3(10.5, Laser.BASE_HEIGHT, 14.5))
	_chk(beam != null, "t_spawn_laser 返回一条激光")
	_chk(_s.t_laser_count() == 1, "在途激光数 = 1")
	_chk(beam.dmg_per_frame == 2, "这条激光的每帧伤害 = 2")
	_chk(beam.hit_tags.is_empty(), "LaserBeam.hit_tags 为空（没有任何东西能击落它）")
	_chk(beam.sentry_trigger == false, "LaserBeam.sentry_trigger = false（不惊动哨兵）")
	for i in 30:
		beam.tick(1.0 / 60.0)
	var fr: Dictionary = _s.t_laser_frames("reaper_laser")
	var nf := int(fr.get(gid, 0))
	_chk(nf == 30, "30 帧后覆盖帧数 = 30（实际 %d）" % nf)
	var hits: Array = _s.t_settle_all_lasers()
	_chk(hits.size() == 1, "统一结算返回 1 条 Hit（实际 %d）" % hits.size())
	_chk(gerald.power_cur == p0 - 60000, "力量池 -60 点（%d -> %d）" % [p0 / 1000, gerald.power_cur / 1000])
	_chk(hits.size() == 1 and String(hits[0].text).contains("点魔法伤害"),
		"日志写明魔法伤害：%s" % (String(hits[0].text).strip_edges() if hits.size() == 1 else "—"))
	_chk(_s.t_laser_count() == 0, "结算后在途激光数 = 0（不会二次结算）")
	_chk(gerald.is_alive(), "Gerald 还活着（82 - 60 = 22）")

	# ══════════════════════════════════════════════════════════════════════════
	print("\n[2] 把单位移出光束 -> 帧数不再增长")
	gerald.power_cur = gerald.power_max
	gerald.cell = Vector2i(20, 20)
	var beam2: LaserBeam = _s.t_spawn_laser("reaper_laser",
		Vector3(20.5, Laser.BASE_HEIGHT, 16.5), Vector3(20.5, Laser.BASE_HEIGHT, 24.5))
	for i in 10:
		beam2.tick(1.0 / 60.0)
	var n1 := int(_s.t_laser_frames("reaper_laser").get(gid, 0))
	gerald.cell = Vector2i(20, 28)      # 走开 8 格，彻底离开光束
	for i in 10:
		beam2.tick(1.0 / 60.0)
	var n2 := int(_s.t_laser_frames("reaper_laser").get(gid, 0))
	_chk(n1 == 10, "移出前覆盖 10 帧（实际 %d）" % n1)
	_chk(n2 == n1, "移出后帧数不再增长（%d -> %d）" % [n1, n2])
	var p1: int = gerald.power_cur
	_s.t_settle_all_lasers()
	_chk(gerald.power_cur == p1 - 20000, "最终按 10 帧结算 = 20 点（实际 %d）" % ((p1 - gerald.power_cur) / 1000))

	# ══════════════════════════════════════════════════════════════════════════
	print("\n[3] 地形阻挡：土堆拦（停在那一格）、木刺不拦")
	var soil := Placeable.from_data(UnitData.PLACEABLES[1], Vector2i(30, 30))    # 土堆 block_ranged=true
	var spike := Placeable.from_data(UnitData.PLACEABLES[0], Vector2i(30, 32))   # 木刺 block_ranged=false
	_s.placeables.append(soil)
	_s.placeables.append(spike)
	_chk(Ballistics.placeable_block_mode(soil, Projectile.KIND_LASER) == Ballistics.Block.ALWAYS,
		"土堆对激光 = Block.ALWAYS（拦）")
	_chk(Ballistics.placeable_block_mode(spike, Projectile.KIND_LASER) == Ballistics.Block.NEVER,
		"木刺对激光 = Block.NEVER（不拦，与箭矢同款：block_ranged=false）")
	# 这条线从 y=33.5 往 y=29.5 走：先穿木刺 (30,32)、再穿土堆 (30,30)
	var e1: Vector2 = _s.t_laser_clip(Vector2(30.5, 33.5), Vector2(30.5, 29.5))
	var e1_cell := Vector2i(int(floor(e1.x)), int(floor(e1.y)))
	_chk(e1_cell == soil.cell,
		"撞到土堆就停在土堆那一格（终点 %s / 土堆 %s）" % [str(e1_cell), str(soil.cell)])
	# 只穿木刺的线：终点不变
	var e2: Vector2 = _s.t_laser_clip(Vector2(30.5, 33.5), Vector2(30.5, 31.5))
	_chk(e2.is_equal_approx(Vector2(30.5, 31.5)), "木刺不拦：终点原样返回（%s）" % str(e2))
	# 走真实发射路径：t_spawn_laser 也必须截断
	var beam3: LaserBeam = _s.t_spawn_laser("reaper_laser",
		Vector3(30.5, Laser.BASE_HEIGHT, 33.5), Vector3(30.5, Laser.BASE_HEIGHT, 29.5))
	var bc := Vector2i(int(floor(beam3.b.x)), int(floor(beam3.b.z)))
	_chk(bc == soil.cell, "t_spawn_laser 走同一条截断（光束终点 %s）" % str(bc))
	print("    实测：土堆 %s（ALWAYS）｜ 木刺 %s（NEVER）｜ clip 终点 %s ｜ spawn 终点 %s" % [
		str(soil.cell), str(spike.cell), str(e1), str(Vector2(beam3.b.x, beam3.b.z))])
	_s.t_settle_all_lasers()

	# ══════════════════════════════════════════════════════════════════════════
	print("\n[4] 魔法伤害：无视护甲、吃魔抗")
	gerald.power_cur = gerald.power_max
	gerald.cell = Vector2i(40, 40)
	gerald.hover = 0.0
	gerald.mr = 0
	gerald.armor_cur = gerald.armor_max
	var d_full := _beam_drop(gerald, 10)
	gerald.armor_cur = 0
	var d_zero := _beam_drop(gerald, 10)
	_chk(d_full == 20000 and d_zero == 20000,
		"护甲拉满 / 清零的伤害一样（各 %d / %d 点）—— 无视护甲" % [d_full / 1000, d_zero / 1000])
	gerald.armor_cur = gerald.armor_max
	gerald.mr = 500
	var d_half := _beam_drop(gerald, 10)
	_chk(d_half == 10000, "mr = 500 -> 减半（20 -> %d 点）" % (d_half / 1000))
	gerald.mr = 1000
	var d_imm := _beam_drop(gerald, 10)
	_chk(d_imm == 0, "mr = 1000（免疫）-> 0 点（被魔抗完全抵消）")
	gerald.mr = 0
	# 直接走纯函数入口，顺带验证 Damage.magic_hit 的文本口径
	var one: Array[Unit] = [gerald]
	var hh := Laser.settle(one, {gid: 5}, 2, _s.rng)
	_chk(hh.size() == 1 and String(hh[0].text).contains("魔抗"),
		"Damage.magic_hit 的日志带魔抗：%s" % (String(hh[0].text).strip_edges() if hh.size() == 1 else "—"))

	# ══════════════════════════════════════════════════════════════════════════
	print("\n[5] 不能被击落 / 不惊动哨兵 / 不进 ProjectileField")
	_chk(Ballistics.intercept_result(Projectile.KIND_LASER) == "",
		"intercept_result(laser) = \"\"（没有'被击落'的收尾）")
	_chk(not Ballistics.is_direct_hit(Projectile.KIND_LASER), "激光不是'直接命中型'")
	_chk(Ballistics.body_impact(Projectile.KIND_LASER) == "", "激光没有'飞行中撞到角色'这条路径")
	_chk(Ballistics.shell_like_defaults(Projectile.KIND_LASER)["hit_tags"].is_empty(),
		"shell_like_defaults(laser) 不给它 hit_tags（不会莫名'可被箭击落'）")
	var live0: int = _s.field.live_count()
	var tmp: LaserBeam = _s.t_spawn_laser("reaper_laser", Vector3(5.5, 6.0, 5.5), Vector3(9.5, 6.0, 5.5))
	_chk(_s.field.live_count() == live0,
		"发一条激光不向 ProjectileField 注册任何东西（%d -> %d）" % [live0, _s.field.live_count()])
	_chk(tmp != null and tmp.alive, "这条激光本身是活的")
	_s.t_settle_all_lasers()

	# ══════════════════════════════════════════════════════════════════════════
	print("\n[6] 三维几何：6 格高的水平光束打不到地面身体；斜射到目标身上就打得到")
	gerald.power_cur = gerald.power_max
	gerald.hover = 0.0
	gerald.cell = Vector2i(24, 24)
	var beam_h: LaserBeam = _s.t_spawn_laser("reaper_laser",
		Vector3(24.5, Laser.BASE_HEIGHT, 20.5), Vector3(24.5, Laser.BASE_HEIGHT, 28.5))
	for i in 10:
		beam_h.tick(1.0 / 60.0)
	var f_h := int(_s.t_laser_frames(beam_h).get(gid, 0))
	_chk(f_h == 0, "水平光束（两端 y=6）扫过地面单位头顶 -> 0 帧（高度轴生效，实际 %d）" % f_h)
	_s.t_settle_all_lasers()
	var beam_s: LaserBeam = _s.t_spawn_laser("reaper_laser",
		Vector3(20.5, Laser.BASE_HEIGHT, 24.5), Vector3(24.5, 0.5, 24.5))
	for i in 10:
		beam_s.tick(1.0 / 60.0)
	var f_s := int(_s.t_laser_frames(beam_s).get(gid, 0))
	_chk(f_s == 10, "斜射（末端 = 目标身体中心）-> 10 帧命中（实际 %d）" % f_s)
	_s.t_settle_all_lasers()

	# ══════════════════════════════════════════════════════════════════════════
	# 【第 100 轮】激光对沙盒元素也要造伤
	#   用户口径：「激光对沙盒元素也要有伤害，当然我记得很久之前我给其中某个给了魔抗免疫，
	#             那么是没伤害的（当然**你还是得进造伤公式转一圈**）」
	#   ⚠ 核对后的事实：**木刺 / 土堆 / 巡飞弹发射器三个的魔抗都是 immune(1000)** ——
	#     所以按现有数据激光对三者都是 0 伤害；但**公式路径必须存在且可验证**。
	# ══════════════════════════════════════════════════════════════════════════
	print("\n[数据事实] 三个沙盒元素的魔抗")
	var pl_rows := {}
	for d in UnitData.PLACEABLES:
		pl_rows[String(d["name"])] = d
	for pn in ["木刺", "土堆", "巡飞弹发射器"]:
		var row: Dictionary = pl_rows.get(pn, {})
		_chk(int(row.get("mr", -1)) == 1000,
			"%s 的魔抗 = immune(1000)（实际 %d）" % [pn, int(row.get("mr", -1))])

	print("\n[1] 免疫目标：**走一遍公式**、结果是 0（不是提前 return）")
	var spike100: Placeable = _find_placeable("木刺")
	if spike100 == null:
		_chk(false, "场上找得到木刺")
	else:
		_chk(spike100.mr == 1000, "木刺 mr = 1000（实际 %d）" % spike100.mr)
		var hp_before: int = spike100.power_cur
		var h_imm: Damage.Hit = Damage.magic_hit_placeable(spike100, 40, "激光")
		_chk(h_imm != null, "免疫目标也返回了 Hit（证明没有提前 return）")
		if h_imm != null:
			_chk(h_imm.result.power_dmg == 0, "伤害 = 0（实际 %d）" % h_imm.result.power_dmg)
			_chk(h_imm.result.branch == Rules.Branch.NO_DAMAGE, "分支 = NO_DAMAGE")
			_chk(h_imm.text.contains("0 点魔法伤害"),
				"文案写明 0 点：%s" % h_imm.text.strip_edges())
		_chk(spike100.power_cur == hp_before, "力量池没掉（%d -> %d）" % [hp_before / 1000, spike100.power_cur / 1000])

	print("\n[2] 命中判定：光路上的道具命中、不在光路上的不命中")
	# ⚠ 顺序要紧：**先做命中判定，再造伤** —— 木刺只有 40 点力量，一发 40 点的激光会把它打空，
	#   而 `hits_placeable` / `magic_hit_placeable` 都要求 `is_alive()`，死了就什么都测不到
	#   （第一版就是这么红的：mr=500 那条读到 0，命中判定也失败）。
	if spike100 == null:
		_chk(false, "场上找得到木刺")
		_finish()
		return
	var sc := Vector2(float(spike100.cell.x) + 0.5, float(spike100.cell.y) + 0.5)
	_chk(Laser.hits_placeable(Vector3(sc.x - 3.0, Laser.BASE_HEIGHT, sc.y),
		Vector3(sc.x + 3.0, 0.5, sc.y), spike100), "光束穿过道具所在格 -> 命中")
	_chk(not Laser.hits_placeable(Vector3(sc.x - 3.0, Laser.BASE_HEIGHT, sc.y + 5.0),
		Vector3(sc.x + 3.0, 0.5, sc.y + 5.0), spike100), "光束离它 5 格远 -> 不命中")

	print("\n[3] 按魔抗缩放（mr=500 -> 减半，池子先补满再量）")
	var mr_save: int = spike100.mr
	spike100.power_cur = spike100.power_max           # 补满，保证测的是"扣多少"而不是"打空了"
	spike100.mr = 500
	var hp0c: int = spike100.power_cur
	Damage.magic_hit_placeable(spike100, 40, "激光")
	_chk(hp0c - spike100.power_cur == Rules.points_to_milli(20),
		"mr=500 时 40 点只掉 20（实际 %d）" % ((hp0c - spike100.power_cur) / 1000))

	print("\n[4] mr=0 -> 40 点全额（放最后：这一发会把它打空）")
	spike100.power_cur = spike100.power_max
	spike100.mr = 0
	var hp0b: int = spike100.power_cur
	var h_ok: Damage.Hit = Damage.magic_hit_placeable(spike100, 40, "激光")
	_chk(h_ok != null and h_ok.result.power_dmg == Rules.points_to_milli(40),
		"mr=0 时 40 点全额生效（%d -> %d）" % [hp0b / 1000, spike100.power_cur / 1000])
	spike100.mr = mr_save
	spike100.power_cur = spike100.power_max           # 还原，别影响后面的用例
	print("    （已还原 mr = %d，力量池补满）" % spike100.mr)

	_finish()


func _finish() -> void:
	print("\n── 激光探针：%d 项检查，失败 %d 项 ──" % [_checks, _fails.size()])
	for f in _fails:
		print("   - ", f)
	quit(1 if _fails.size() > 0 else 0)
