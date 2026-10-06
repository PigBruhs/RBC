# 雷达午餐盒的**纯逻辑**探针（第 111 轮）：锁定回合数 / 重置 / 连接 FIFO / 散布修正 / 可选中
#   —— 不碰场景，只测 `core/radar.gd`，跑得飞快。
extends SceneTree

var _f := 0
var _n := 0
var _done := false


func _ok(cond: bool, what: String) -> void:
	_n += 1
	if cond:
		print("  PASS  ", what)
	else:
		_f += 1
		print("  FAIL  ", what)


func _initialize() -> void:
	# ⚠ 第 111 轮：**每回合的格数由 20 改成 30**（用户口径）。
	#   断言改成**从常数推导**，以后再调 `LOCK_PER_TURNS` 就不会有一堆写死的期望值跟着红。
	var per: float = Radar.LOCK_PER_TURNS
	print("[1] 锁定所需回合数 = ceil(距离/%.0f)，至少 1" % per)
	for pair in [[10.0, 1], [per, 1], [per + 0.1, 2], [per * 2.0, 2],
			[81.0, int(ceil(81.0 / per))], [per * 4.0, 4], [per * 5.0, 5], [0.0, 1]]:
		var d: float = pair[0]
		var want: int = pair[1]
		var got := Radar.turns_for(d)
		_ok(got == want, "%.1f 格 -> %d 回合（实际 %d）" % [d, want, got])
	_ok(Radar.turns_for(81.0) == int(ceil(81.0 / per)),
		"81 格 -> %d 回合（按每 %.0f 格 1 回合）" % [int(ceil(81.0 / per)), per])

	print("\n[2] 选定 -> 每回合 -1 -> 到 0 已锁定（选定那一回合算第 1 回合）")
	var st := Radar.State.new()
	Radar.begin_lock(st, "Gerald (E)", 81.0)
	var want81: int = int(ceil(81.0 / per))
	_ok(st.lock_total == want81 and st.lock_left == want81 and st.locking(),
		"选定后：需 %d 回合、仍未锁定（lock_left=%d）" % [want81, st.lock_left])
	# 逐回合推进到 0（**次数跟着 `want81` 走**，不再写死 5 —— 第 111 轮把每回合的格数
	# 从 20 改成 30 之后，81 格只要 3 回合，写死 5 会多 tick 两次、序列里多两个 0）
	var seq: Array[int] = []
	for _i in want81:
		Radar.tick_turn(st)
		seq.append(st.lock_left)
	print("      逐回合 lock_left：%d -> %s" % [want81, str(seq)])
	var want_seq: Array = []
	for i in range(want81 - 1, -1, -1):
		want_seq.append(i)
	_ok(seq == want_seq, "%d 个自己的回合后到 0（序列 %s）" % [want81, str(seq)])
	_ok(st.locked(), "**判定为已锁定**（desc=%s）" % st.desc())
	_ok(Radar.tick_turn(st) == false, "已锁定后再 tick 不再返回'刚完成'")

	print("\n[3] 四种重置：换目标 / 目标死 / 休息 / 被摧毁")
	var s2 := Radar.State.new()
	Radar.begin_lock(s2, "A", 60.0)
	Radar.tick_turn(s2)
	_ok(s2.lock_left == s2.lock_total - 1, "先推进一格（lock_left=%d）" % s2.lock_left)
	Radar.begin_lock(s2, "B", 20.0)          # 换目标 -> 先重置再按新距离算
	_ok(s2.lock_name == "B" and s2.lock_total == 1 and s2.lock_left == 1,
		"**换目标重置**：新目标 20 格 -> 需 1 回合（实际 %s）" % s2.desc())
	Radar.clear_lock(s2)
	_ok(s2.lock_name == "" and s2.lock_left == 0 and not s2.locked(),
		"**clear_lock 彻底重置**（目标死/休息/被摧毁都走它）")

	print("\n[4] 连接：最多 2 名，FIFO 挤出最先连接的")
	var s3 := Radar.State.new()
	Radar.add_link(s3, "Gerald")
	Radar.add_link(s3, "Alette")
	_ok(s3.links == ["Gerald", "Alette"], "连两个：%s" % str(s3.links))
	Radar.add_link(s3, "萨尼铁塔")
	# ⚠ 第 111 轮：**FIFO 挤人现在发生在 `roster`（连接队列）上** ——
	#   `links` 只是"此刻在范围内的那几个"；挤人只挤 roster（走出范围也不会丢队列，
	#   回到范围内会自动重连，见 `probe_radar_scene`）。
	_ok(s3.roster == ["Alette", "萨尼铁塔"],
		"**第三个把最先的 Gerald 挤出队列**（%s）" % str(s3.roster))
	# `links` 的语义是"**此刻在范围内**的"，要靠 `prune_links` 同步（运行时每帧都调）。
	# 这里手动同步一次：让所有人都在范围内 -> `links` 应当等于 `roster`。
	Radar.prune_links(s3, Vector2.ZERO,
		func(_nm: String) -> Vector2: return Vector2.ZERO)
	_ok(s3.links == ["Alette", "萨尼铁塔"],
		"此刻在范围内的也是这两个（%s）" % str(s3.links))
	_ok(Radar.add_link(s3, "Alette") == false and s3.roster == ["Alette", "萨尼铁塔"],
		"重复连接同一个不重复加")

	print("\n[5] 连接与锁定**解耦**")
	var s4 := Radar.State.new()
	Radar.add_link(s4, "Gerald")
	_ok(s4.lock_name == "" and s4.links == ["Gerald"], "**未锁定但保持连接**")
	Radar.begin_lock(s4, "E1", 40.0)
	_ok(s4.locking() and s4.links == ["Gerald"], "锁定中不影响已有连接")
	Radar.clear_lock(s4)
	_ok(s4.lock_name == "" and s4.links == ["Gerald"], "**清锁定不清连接**")
	Radar.add_link(s4, "Alette")
	_ok(s4.links.size() == 2 and s4.lock_name == "", "**可只连接不锁定**")

	print("\n[6] 连接距离 16 格：持续检查、走远就断")
	var s5 := Radar.State.new()
	Radar.add_link(s5, "近")
	Radar.add_link(s5, "远")
	var pos := {"近": Vector2(0, 0), "远": Vector2(100, 0)}
	Radar.prune_links(s5, Vector2(0, 0), func(nm: String) -> Vector2:
		return pos.get(nm, Vector2.INF))
	_ok(s5.links == ["近"], "走远的被断掉，留在 16 格内的保留（%s）" % str(s5.links))
	var s6 := Radar.State.new()
	Radar.add_link(s6, "死了")
	Radar.prune_links(s6, Vector2.ZERO, func(nm: String) -> Vector2: return Vector2.INF)
	_ok(s6.links.is_empty(), "找不到（死亡/退场）也断")

	print("\n[7] 难点 2：散布修正")
	var s7 := Radar.State.new()
	Radar.add_link(s7, "友")
	var mod_pre := Radar.spread_modifier([s7], "友")
	_ok(absf(float(mod_pre["mult"]) - 0.5) < 1e-6 and not bool(mod_pre["has_abs"]),
		"**锁定完成前：半径 ×0.5**（%s）" % str(mod_pre))
	_ok(absf(Radar.apply_spread(1.5, mod_pre) - 0.75) < 1e-6,
		"1.5 格散布 -> 0.75")
	Radar.begin_lock(s7, "E1", 20.0)
	Radar.tick_turn(s7)
	_ok(s7.locked(), "该雷达车已锁定")
	var mod_post := Radar.spread_modifier([s7], "友")
	_ok(bool(mod_post["has_abs"]) and absf(float(mod_post["abs_r"]) - 0.05) < 1e-6,
		"**锁定完成后：固定半径 0.05（= 直径 0.1 格的球）**（%s）" % str(mod_post))
	_ok(absf(Radar.apply_spread(1.5, mod_post) - 0.05) < 1e-6, "1.5 -> 0.05")
	_ok(absf(float(Radar.spread_modifier([s7], "路人")["mult"]) - 1.0) < 1e-6,
		"**没被连接的友军不受影响**")

	print("\n[8] 难点 2：只有**被连接的友军**才能无视距离选被锁定目标")
	_ok(Radar.may_target([s7], "友", "E1"), "**被连接的友军可选**")
	_ok(not Radar.may_target([s7], "路人", "E1"), "没被连接的不可选")
	_ok(not Radar.may_target([s7], "友", "E2"), "不是被锁定的那个目标不可选")
	var s8 := Radar.State.new()
	Radar.add_link(s8, "友")
	Radar.begin_lock(s8, "E1", 40.0)
	_ok(not Radar.may_target([s8], "友", "E1"), "**还没锁定完成时不可选**（仍在计时）")

	print("\n── 雷达逻辑探针：%d 项检查，失败 %d 项 ──" % [_n, _f])
	quit(1 if _f > 0 else 0)
