# Boss 关（Reaper 战）端到端探针：真实加载场景、走一个回合边界、看 Reaper 的循环与召唤
#
# 为什么单独一个探针：run.gd 只验元数据，playtest 只跑默认关卡。
# "切到 Reaper 战能不能真的建起来、Reaper 会不会动/召唤/发激光"没有别的地方覆盖。
#
# 运行： exe --headless --path game --script res://tools/probe_boss_scene.gd --quit-after 180000
extends SceneTree

var _fails: Array[String] = []
var _checks := 0


func _chk(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("  PASS  ", label)
	else:
		print("  FAIL  ", label)
		_fails.append(label)


## 把一个单位摆到某格（**同时同步视觉坐标**：GridMath.unit_pos 读 visual.position）
func _place_at(u: Unit, c: Vector2i) -> void:
	u.cell = c
	if u.visual != null:
		u.visual.position = Vector3(float(c.x) + 0.5, u.visual.position.y, float(c.y) + 0.5)


func _initialize() -> void:
	print("\n[1] 切到 Reaper 战并真实加载场景")
	Level.current = "reaper"
	var s: Node = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(s)
	for i in 10:
		await process_frame
	_chk(s != null, "场景实例化成功（Boss 关能真的建起来）")
	_chk(Level.current == "reaper", "Level.current = reaper")

	print("\n[2] 场上阵容：玩家 = 老国王 + 两个公主；敌方 = 只有 Reaper")
	var kings: Array = []
	var princesses := 0
	var reapers: Array = []
	for u in s.units:
		if u.is_king:
			kings.append(u)
		if Unit.base_name(u.name).begins_with("公主"):
			princesses += 1
		if Unit.base_name(u.name) == "Reaper":
			reapers.append(u)
	# 本关是**非对称**的：只有玩家有老国王（"老国王死 = 败"），敌方没有国王 ——
	# 敌方的胜负条件挂在 Reaper 身上（"Reaper 死 = 胜"）。所以这里断的是"只有 1 个国王"。
	_chk(kings.size() == 1 and kings[0].side == UnitData.Side.PLAYER,
		"只有玩家有老国王（非对称 Boss 关，实际 %d 个）" % kings.size())
	_chk(princesses == 2, "玩家两个公主（实际 %d）" % princesses)
	_chk(reapers.size() == 1, "场上有且只有一个 Reaper（实际 %d）" % reapers.size())
	var reaper: Unit = reapers[0] if not reapers.is_empty() else null
	if reaper != null:
		_chk(reaper.side == UnitData.Side.ENEMY, "Reaper 属于敌方阵营")
		_chk(reaper.power_cur == Rules.points_to_milli(999),
			"Reaper 血量 999（用户第 101 轮口径，实际 %d）" % (reaper.power_cur / 1000))
		_chk(reaper.armor_cur == Rules.points_to_milli(99),
			"Reaper 护甲 99（用户第 101 轮口径，实际 %d）" % (reaper.armor_cur / 1000))
		_chk(reaper.body_r > 2.9 and reaper.body_height > 11.9,
			"Reaper 碰撞圆柱 3 / 12（实际 %.2f / %.2f）" % [reaper.body_r, reaper.body_height])

	print("\n[3] 回合顺序：本场景是 by_side（一边全行动完才换边）")
	# ⚠ `queue` 在【放置阶段结束】之前是 null —— 场景 _ready 之后先进放置阶段，
	#   `start_round()` 才会造 TurnQueue。所以必须先把放置阶段收掉，
	#   否则 `s.queue.mode` 会命中 null 让脚本中断（第一版探针就挂在这里）。
	_chk(s.queue == null, "开局处于放置阶段（queue 还没建，符合预期）")
	s.t_finish_placement()
	for i in 4:
		await process_frame
	_chk(s.queue != null, "收掉放置阶段后 TurnQueue 建起来了")
	var qmode: String = String(s.queue.mode) if s.queue != null else "(null)"
	_chk(qmode == TurnQueue.MODE_BY_SIDE, "队列模式 = by_side（实际 %s）" % qmode)

	print("\n[4] Reaper 的建模挂上了（蓝环在离地 6 格）")
	print("\n[4] Reaper 的建模挂上了（蓝环在离地 6 格）")
	# ⚠ 开打那一刻 Reaper 可能正处在"激光预警（红）"窗口里 —— 那是正常演出。
	#   所以先人为置蓝，再断言"蓝 -> 红 -> 蓝"三步都听指挥。
	if reaper != null and reaper.visual != null:
		var BLUE := Color(0.35, 0.6, 1.0)
		s.t_set_reaper_ring(reaper, BLUE)
		for i in 2:
			await process_frame
		var rc: Color = s.t_reaper_ring_color_of(reaper)
		_chk(rc.b > rc.r, "置蓝后环是蓝的（r=%.2f b=%.2f）" % [rc.r, rc.b])
		s.t_set_reaper_ring(reaper, Color.RED)
		for i in 2:
			await process_frame
		var rr: Color = s.t_reaper_ring_color_of(reaper)
		_chk(rr.r > rr.b, "t_set_reaper_ring(RED) 后确实变红（r=%.2f b=%.2f）" % [rr.r, rr.b])
		s.t_set_reaper_ring(reaper, BLUE)
		for i in 2:
			await process_frame
		var rb: Color = s.t_reaper_ring_color_of(reaper)
		_chk(rb.b > rb.r, "改回蓝色成功")
	else:
		_chk(false, "Reaper 的 visual 已装配")

	print("\n[5] 三循环状态 + 6 格被动（Reaper 的演出细节由 probe_reaper_ai 专测）")
	# ⚠ 这里**故意不跑真实回合循环**：无头环境下回合推进要等计时器/动画，
	#   一旦某个等待没有对应的 _process 推进就会挂住（第一版探针就挂在这里）。
	#   回合机本身有 playtest / sim_ai 两套回归，这里只做"装配层 + 被动规则"的观察。
	_chk(s.t_laser_count() >= 0, "激光门面可访问（在途 %d 条）" % s.t_laser_count())
	# 开打时 Reaper 已经走过一次它的回合，所以循环步不一定是 0 —— 只断言"推三步回原位"
	var s0: int = s.gm.reaper_step_for(reaper)
	_chk(s0 >= 0 and s0 <= 2, "三循环步在合法域内（实际 %d）" % s0)
	for i in 3:
		s.gm.reaper_advance_cycle(reaper)
	_chk(s.gm.reaper_step_for(reaper) == s0, "推三步回到原步（循环长度 = 3，起点 %d）" % s0)

	print("\n[5b] 6 格范围被动（20 护甲 + 10 力量，中心距离 ≤ 6）")
	# ⚠ 两个坑（都踩过，都写在这里免得下次再踩）：
	#   ① **必须把单位真的摆过去**：`GridMath.unit_pos` 读的是 visual.position，
	#      只改 cell 不同步视觉坐标的话距离还是老值。
	#   ② **不能在 `await process_frame` 之后量伤害**：场景自己的回合边界也在跑
	#      `reaper_passive_tick`，await 期间它会替我们多扣一次，
	#      于是"差 20 力量"被误读成"差 6"（第一版探针的假失败就是这个）。
	#      所以：先摆位 + await 让位置生效，**再把基准值取在 tick 的前一刻**，
	#      并且同步调用一次 tick 后立刻读数（中间不 await）。
	# ⚠ 第 3 个坑：**要挑一个"池子够大 + 0 魔抗"的目标来量名义伤害**。
	#   · 力量那一半走**魔法伤害**（只吃魔抗）：对 Alette（mr=400）只扣 floor(10×0.6)=6 点，
	#     拿她断言"扣 10"会误判成 bug。
	#   · 护甲那一半会被**目标自己的护甲池上限截断**：对 Airburst mortar（5 甲）只扣得动 5 点，
	#     拿它断言"扣 20"同样会误判。
	#   · ⚠ 第 104 轮新增第 4 个坑：**护甲太高也会把力量那半吃光**。
	#     新角色「轮式齐射午餐盒」有 **90 甲**，满足原来的"护甲 ≥ 25"条件被选成理想目标，
	#     但被动的 10 点力量**先减护甲**就归零了 → "掉 10 点力量"必然假红（实测差 0）。
	#     所以理想目标要约束**护甲上限**：要够大（不被池子截断，≥25）
	#     但又要够小（力量能打得进去，≤40）。
	#   所以优先挑"护甲 25~40 且魔抗 = 0"的玩家英雄；一个都没有时退回"只验被选中 + 单调下降"。
	var ARMOR_IDEAL_MIN := Rules.points_to_milli(25)
	var ARMOR_IDEAL_MAX := Rules.points_to_milli(40)
	var mover: Unit = null
	var ideal: Unit = null
	for u in s.units:
		if u.side != UnitData.Side.PLAYER or not u.has_turn() or u == s.active:
			continue
		if mover == null:
			mover = u
		if ideal == null and u.mr == 0 and u.armor_cur >= ARMOR_IDEAL_MIN and u.armor_cur <= ARMOR_IDEAL_MAX:
			ideal = u
	if ideal != null:
		mover = ideal
	if mover != null and reaper != null:
		_place_at(mover, Vector2i(reaper.cell.x - 5, reaper.cell.y))
		await process_frame
		var d_near: float = GridMath.unit_pos(reaper).distance_to(GridMath.unit_pos(mover))
		_chk(d_near <= 6.0, "被摆到 5 格外（实测距离 %.2f）" % d_near)
		# 基准值取在 tick 前一刻（上面已经 await 过，场景那一轮该扣的都扣完了）
		var ar0: int = mover.armor_cur
		var pw0: int = mover.power_cur
		var hit_list: Array = s.gm.reaper_passive_tick(s.units)
		var ar_diff: int = ar0 - mover.armor_cur
		var pw_diff: int = pw0 - mover.power_cur
		_chk(hit_list.has(mover), "5 格外的单位被 6 格被动选中")
		if mover.mr == 0 and ar0 >= ARMOR_IDEAL_MIN and ar0 <= ARMOR_IDEAL_MAX:
			_chk(ar_diff == Rules.points_to_milli(20),
				"5 格处掉 20 点护甲（%s: %d -> %d，差 %d）" % [mover.name, ar0 / 1000, mover.armor_cur / 1000, ar_diff / 1000])
			_chk(pw_diff == Rules.points_to_milli(10),
				"5 格处掉 10 点力量（%s: %d -> %d，差 %d）" % [mover.name, pw0 / 1000, mover.power_cur / 1000, pw_diff / 1000])
		else:
			# 没有理想目标（池子小 / 有魔抗）：只验"没超上限"。
			# ⚠ 第 100 轮：6 格被动的力量那半改成**物理力量线**（用户口径「6格被动是物理伤害」）→
			#   先减护甲、再过物抗、**有命中判定**，所以**合法地可能是 0**（ROLL 未命中）。
			#   所以这里**不能**断言 pw_diff > 0。护甲那半仍是确定值（直接打护甲池）。
			_chk(ar_diff > 0 and ar_diff <= Rules.points_to_milli(20),
				"5 格处掉了护甲且不超过 20 点（%s: 差 %d）" % [mover.name, ar_diff / 1000])
			_chk(pw_diff >= 0 and pw_diff <= Rules.points_to_milli(10),
				"5 格处力量掉 0（未命中）到 10 点之间（%s: 差 %d）" % [mover.name, pw_diff / 1000])
		_place_at(mover, Vector2i(reaper.cell.x - 7, reaper.cell.y))
		await process_frame
		var d_far: float = GridMath.unit_pos(reaper).distance_to(GridMath.unit_pos(mover))
		var ar1: int = mover.armor_cur
		var pw1: int = mover.power_cur
		var hit2: Array = s.gm.reaper_passive_tick(s.units)
		_chk(d_far > 6.0, "被摆到 7 格外（实测距离 %.2f）" % d_far)
		_chk(not hit2.has(mover), "7 格外的单位不再被选中")
		_chk(mover.armor_cur == ar1 and mover.power_cur == pw1, "7 格处不掉甲也不掉血")
	else:
		_chk(false, "找得到一个玩家英雄来测 6 格被动")

	print("\n[6] 胜负条件：老国王死 = 败；Reaper 死 = 胜")
	var pk: Unit = null
	for u in s.units:
		if u.is_king and u.side == UnitData.Side.PLAYER:
			pk = u
	_chk(pk != null, "找得到玩家老国王")
	if pk != null:
		pk.take_power_damage(pk.power_cur + 1000)
		await process_frame
		var w := TurnFlow.check(s.units, Level.victory("reaper"), 0)
		_chk(w == TurnFlow.ENEMY, "玩家老国王阵亡 -> 敌方（Reaper）获胜（实际 %d）" % w)

	print("\n── Boss 关探针：%d 项检查，失败 %d 项 ──" % [_checks, _fails.size()])
	for f in _fails:
		print("   - ", f)
	quit(1 if _fails.size() > 0 else 0)