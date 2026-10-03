# ══════════════════════════════════════════════════════════════════════════════
# 单位 AI：索敌打分 + 回合规划（纯决策，不碰任何 Node，可无头测试）
#
# 用户口径：
#   · 全图视野，没有战争迷雾。
#   · 每个 AI 给所有敌对目标打分（距离 / 职业 / 能造成的伤害 / 是不是国王），
#     锁定最高分；并列时随机取一个。
#   · 追求"削弱对面战斗力"与"打掉对面老国王拿胜利"之间的平衡。
#   · 投掷手避免把技能丢进敌方哨兵射界（那种情况最多打一发普攻）。
#   · AI 的普攻与技能都套"普通散步"（5 格内准、20 格直径 3 格）。
#
# 输出一份"回合计划"交给 battle_scene 执行：
#   {action: "attack"/"skill"/"rest"/"move"/"end", move_to, target, placeable,
#    break_armor, aim, skill, note}
# ══════════════════════════════════════════════════════════════════════════════
class_name Ai
extends RefCounted

## 决策需要的世界快照（由 battle_scene 组装）
class Ctx extends RefCounted:
	var me: Unit = null
	var foes: Array[Unit] = []                 # 敌对单位（全图）
	var foe_king: Unit = null
	var reachable: Dictionary = {}             # 格 -> true（这一回合能走到的格子）
	var sentry_cells: Dictionary = {}          # 敌方哨兵覆盖的格 -> true
	var placeables: Array = []                 # 场上的沙盒道具（可锁定）
	var me_has_sentry: bool = false            # 我自己是不是已经在哨兵状态
	var rng: RngService = null


# 评分权重（想调 AI 性格就动这里）
const W_KING := 2.6            # 国王 = 胜利条件，永远优先
const W_THROWER := 1.3         # 投掷手一发能打一群人，威胁最大
const W_RANGED := 1.15
const W_MELEE := 1.0
const W_PLACEABLE := 0.30      # 清障碍：比打人低一档
const SENTRY_RISK := 0.45      # 远程/投掷站在敌方哨兵射界里的惩罚
const KILL_BONUS := 1.6        # 这一下能打死 -> 额外加权
const DIST_PENALTY := 0.55     # 近战：每远一格的扣分
const EDGE_PENALTY := 2.4      # 远程/投掷：离【最大射程的 2/3】每差一格的扣分（用户口径：在 2/3 射程处攻击）
const AIM_SPREAD := true       # AI 的弹道吃散步（用户口径：先用普通散步那版）


static func manhattan(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


## 从 from 这一格能不能打到 cell（近战 = 4 邻格；远程/投掷 = 曼哈顿区间）
static func can_hit_from(me: Unit, from: Vector2i, cell: Vector2i) -> bool:
	var d := manhattan(from, cell)
	if me.role == UnitData.Role.MELEE:
		return d == 1
	return d >= me.rng_min and d <= me.rng_max


## 估个伤害（点数）：力量线与破甲线取大者
static func est_damage(me: Unit, t: Unit) -> int:
	var pw: Rules.Preview = Rules.preview(me.power_cur, t.armor_cur, t.pr)
	var dmg: int = pw.damage if pw.branch != Rules.Branch.NO_DAMAGE else 0
	var brk: int = me.armor_break / 1000 if t.armor_cur > 0 else 0
	return maxi(dmg, brk)


## 打谁更该用破甲线
static func want_break_armor(me: Unit, t: Unit) -> bool:
	var pw: Rules.Preview = Rules.preview(me.power_cur, t.armor_cur, t.pr)
	var dmg: int = pw.damage if pw.branch != Rules.Branch.NO_DAMAGE else 0
	return (me.armor_break / 1000) > dmg and t.armor_cur > 0


## 给一个目标打分。from = 打算从哪一格出手
static func score(me: Unit, t: Unit, from: Vector2i, ctx: Ctx) -> float:
	var dmg := float(est_damage(me, t))
	var w := W_MELEE
	if t.is_king:
		w = W_KING
	elif t.role == UnitData.Role.THROWER:
		w = W_THROWER
	elif t.role == UnitData.Role.RANGED:
		w = W_RANGED
	var pool := float(t.power_cur + t.armor_cur) / 120000.0
	var s := (dmg + 0.4) * 3.0 * w * (0.65 + 0.6 * clampf(pool, 0.0, 1.5))
	if dmg >= t.power_cur / 1000:                     # 这一下能打死：优先收人头
		s *= KILL_BONUS
	if not can_hit_from(me, from, t.cell):
		s *= 0.5                                     # 这个位置还得再挪一步
	var d := float(manhattan(from, t.cell))
	if me.role == UnitData.Role.MELEE:
		s -= d * DIST_PENALTY                        # 近战：越近越好
	else:
		# 用户口径：远程/投掷追求【在射程边缘】输出（射程 8 就尽量待在 8 格附近）
		s -= absf(d - float(me.rng_max) * 2.0 / 3.0) * EDGE_PENALTY
		if d < me.rng_min:
			s *= 0.5
	if me.role != UnitData.Role.MELEE and ctx.sentry_cells.has(from):
		s *= (1.0 - SENTRY_RISK)                     # 远程别站在敌方哨兵射界里
	return s


# ══════════════════════════════════════════════════════════════════════════════
# 直升机的"准备状态"接口（用户口径：敌方 AI 必须能读到并做决断）
#   准备状态存在 unit.tags["dive_ready"] = Vector2i（目标格），俯冲中为 tags["diving"]
# ══════════════════════════════════════════════════════════════════════════════
const HELI_TAG_READY := "dive_ready"
const HELI_TAG_DIVING := "diving"


## 这个单位是不是正在准备俯冲（返回目标格；没准备返回 (-1,-1)）
static func heli_ready_target(u: Unit) -> Vector2i:
	if u == null or not u.tags.has(HELI_TAG_READY):
		return Vector2i(-1, -1)
	return u.tags[HELI_TAG_READY]


static func heli_is_ready(u: Unit) -> bool:
	return heli_ready_target(u) != Vector2i(-1, -1)


static func heli_is_diving(u: Unit) -> bool:
	return u != null and u.tags.has(HELI_TAG_DIVING)


## 这一格会不会被它的俯冲/投弹波及（投弹半径 3 格）
static func heli_threatens_cell(u: Unit, cell: Vector2i, blast_r: float = 3.0) -> bool:
	var t := heli_ready_target(u)
	if t == Vector2i(-1, -1):
		return false
	return manhattan(t, cell) <= int(ceil(blast_r))


## 场上所有"正在准备俯冲"的敌对直升机（给弓箭手等 AI 用）
static func ready_helis(foes: Array[Unit]) -> Array[Unit]:
	var out: Array[Unit] = []
	for f in foes:
		if f.is_alive() and heli_is_ready(f):
			out.append(f)
	return out


## 落点：目标格中心 + 普通散步（5 格内准、20 格直径 3）
static func aim_at(me: Unit, cell: Vector2i, ctx: Ctx) -> Vector2:
	var ctr := Vector2(float(cell.x) + 0.5, float(cell.y) + 0.5)
	if not AIM_SPREAD or ctx.rng == null:
		return ctr
	var from := Vector2(float(me.cell.x) + 0.5, float(me.cell.y) + 0.5)
	var speed := Ordnance.ARROW_TILES_PER_SEC if me.role == UnitData.Role.RANGED \
		else Ordnance.SHELL_TILES_PER_SEC
	return Spread.scatter(ctr, from.distance_to(ctr), speed, ctx.rng)


## 这一格能不能安全丢技能（投掷手：落点不能在敌方哨兵射界里）
static func safe_skill_spot(ctx: Ctx, cells: Array) -> bool:
	for c in cells:
		if ctx.sentry_cells.has(c):
			return false
	return true


## 回合规划：返回一份计划字典（battle_scene 负责执行）
static func plan(ctx: Ctx) -> Dictionary:
	var me := ctx.me
	if me == null or not me.is_alive():
		return {"action": "end", "note": "不在场"}
	var best: Dictionary = {}
	var best_s := -1e9
	var approach: Unit = null                 # 打不到任何人时，朝谁靠拢
	var approach_s := -1e9
	var spots: Array = [me.cell]
	for c in ctx.reachable.keys():
		spots.append(c)
	# ① 打分挑目标。**只有"站这里真能打到"的组合才算攻击**，
	#    否则会走一步然后打空气（AI 早期版本就是这个毛病）
	for from in spots:
		for t in ctx.foes:
			if not t.is_alive():
				continue
			var s := score(me, t, from, ctx)
			if s > approach_s:
				approach_s = s
				approach = t
			if not can_hit_from(me, from, t.cell):
				continue
			if s > best_s:
				best_s = s
				best = {"target": t, "from": from, "score": s}
	if best.is_empty():
		for from in spots:
			for pl in ctx.placeables:
				if not pl.is_alive():
					continue
				var d := manhattan(from, pl.cell)
				if me.role == UnitData.Role.MELEE and d != 1:
					continue
				if me.role != UnitData.Role.MELEE and (d < me.rng_min or d > me.rng_max):
					continue
				var s2 := 1.0 + float(pl.power_cur) / 40000.0 - float(d) * DIST_PENALTY
				if s2 > best_s:
					best_s = s2
					best = {"placeable": pl, "from": from, "score": s2}
	# 群体技能优先：如果有一团（≥2 人）敌人挤在范围技能里，先用技能（AoE 总收益更高）
	if not best.is_empty():
		var sk := _plan_skill(ctx)
		var sid0 := String(sk.get("skill", ""))
		if sid0 == "grenade_launcher" or sid0 == "carpet_bomb":
			return sk
	if not best.is_empty():
		var mv = best["from"]
		var move_to = mv if mv != me.cell else null
		if best.has("target"):
			var t: Unit = best["target"]
			return {"action": "attack", "move_to": move_to, "target": t,
				"break_armor": want_break_armor(me, t),
				"aim": aim_at(me, t.cell, ctx),
				"note": "打 %s（评分 %.1f，%s）" % [t.name, best_s,
					"现位置" if move_to == null else "走 %s" % move_to]}
		var pl2 = best["placeable"]
		return {"action": "attack", "move_to": move_to, "placeable": pl2,
			"aim": aim_at(me, pl2.cell, ctx),
			"note": "清沙盒 %s（评分 %.1f）" % [pl2.name, best_s]}

	# ② 没得打 -> 看技能
	var sk := _plan_skill(ctx)
	if not sk.is_empty():
		return sk

	# ③ 都没得做：还没移动 + 状态不满 -> 休息；否则朝评分最高的敌人靠过去
	if not me.has_moved and (me.power_cur < me.power_max * 3 / 4 or me.energy_points() < 2):
		return {"action": "rest", "note": "回血/回精力：休息"}
	if me.has_moved:
		return {"action": "end", "note": "已经动过了，这回合就这样"}   # 规则：移动后不能休息
	var far: Unit = approach
	if far == null:
		return {"action": "end", "note": "没有目标"}
	# 朝目标挪一步：在可达格里挑离它最近的
	var step: Vector2i = me.cell
	var sd := manhattan(me.cell, far.cell)
	for c in ctx.reachable.keys():
		var d2 := manhattan(c, far.cell)
		if d2 < sd and not ctx.sentry_cells.has(c):
			sd = d2
			step = c
	if step == me.cell:
		return {"action": "rest", "note": "走不动了：休息"}
	return {"action": "move", "move_to": step, "note": "向 %s 靠拢" % far.name}


## 技能决策（投掷手：地毯；有轨道空爆的（杰拉尔德）：埋标记；弓箭手：哨兵）
## 用户口径：**敌方近战也要用技能**（杰拉尔德的轨道空爆 AI 会用）
static func _plan_skill(ctx: Ctx) -> Dictionary:
	var me := ctx.me
	var energy := me.energy_points()
	var have := Skills.skills_for(me)
	# 有轨道空爆的人（杰拉尔德，不论近战远程）：朝敌方国王头上提前埋标记
	var d2 := Skills.get_def("orbital_strike")
	if have.has("orbital_strike") and not d2.is_empty() and energy >= int(d2["cost"]) \
			and ctx.foe_king != null and ctx.foe_king.is_alive():
		var kd := manhattan(me.cell, ctx.foe_king.cell)
		# 用户口径：投掷技能必须**在技能射程以内**（之前会隔着半张图乱扔）
		if kd >= int(d2["range_min"]) and kd <= int(d2["range_max"]):
			return {"action": "skill", "skill": "orbital_strike",
				"aim": aim_at(me, ctx.foe_king.cell, ctx),
				"note": "轨道空爆：埋在老国王 %s 头上（%d 格）" % [ctx.foe_king.name, kd]}
	# 俯冲轰炸（直升机）：优先砸敌方国王，其次砸人最密的一格
	#（准备状态是公开信息：对面弓箭手 AI 读到之后会开哨兵反制）
	var dd := Skills.get_def("dive_bomb")
	if have.has("dive_bomb") and not dd.is_empty() and energy >= int(dd["cost"]):
		var dr: float = float(dd.get("range_max", 20.0))
		var tgt_cell := Vector2i(-1, -1)
		if ctx.foe_king != null and ctx.foe_king.is_alive() \
				and float(manhattan(me.cell, ctx.foe_king.cell)) <= dr:
			tgt_cell = ctx.foe_king.cell
		else:
			var best_n := 0
			for t in ctx.foes:
				if not t.is_alive() or float(manhattan(me.cell, t.cell)) > dr:
					continue
				var nn := 0
				for o in ctx.foes:
					if o.is_alive() and manhattan(o.cell, t.cell) <= 2:
						nn += 1
				if nn > best_n:
					best_n = nn
					tgt_cell = t.cell
		if tgt_cell != Vector2i(-1, -1):
			return {"action": "skill", "skill": "dive_bomb", "cell": tgt_cell,
				"note": "俯冲轰炸：选定 (%d, %d)" % [tgt_cell.x, tgt_cell.y]}
	# 枪榴弹（萨尼铁塔）：朝"最挤的一团敌人"丢；没有集聚就丢敌方国王
	var dg := Skills.get_def("grenade_launcher")
	if have.has("grenade_launcher") and not dg.is_empty() and energy >= int(dg["cost"]):
		var best_c: Unit = null
		var best_m := 0
		for t2 in ctx.foes:
			if not t2.is_alive():
				continue
			var dcell := manhattan(me.cell, t2.cell)
			if dcell < int(dg["range_min"]) or dcell > int(dg["range_max"]):
				continue
			var n2 := 0
			for o2 in ctx.foes:
				if o2.is_alive() and manhattan(o2.cell, t2.cell) <= 2:
					n2 += 1
			if n2 > best_m:
				best_m = n2
				best_c = t2
		if best_c != null and (best_m >= 2 or best_c.is_king):
			return {"action": "skill", "skill": "grenade_launcher",
				"aim": aim_at(me, best_c.cell, ctx),
				"note": "枪榴弹：朝 %s 那边丢（附近 %d 人）" % [best_c.name, best_m]}
	# 投掷手：地毯式轰炸（≥2 个敌人挤在一起，且落点不在敌方哨兵射界里）
	if me.role == UnitData.Role.THROWER:
		var d := Skills.get_def("carpet_bomb")
		if have.has("carpet_bomb") and not d.is_empty() and energy >= int(d["cost"]):
			var half_w := float(d["rect_width"]) * 0.5
			var half_l := float(d["rect_len"]) * 0.5
			for t in ctx.foes:
				if not t.is_alive() or manhattan(me.cell, t.cell) < int(d["range_min"]):
					continue
				var n := 0
				var cells: Array = []
				for o in ctx.foes:
					if not o.is_alive():
						continue
					if absi(o.cell.x - t.cell.x) <= int(half_w) \
							and absi(o.cell.y - t.cell.y) <= int(half_l):
						n += 1
						cells.append(o.cell)
				if n >= 2 and safe_skill_spot(ctx, cells + [t.cell]):
					return {"action": "skill", "skill": "carpet_bomb",
						"aim": aim_at(me, t.cell, ctx),
						"note": "地毯式轰炸：%s 附近挤了 %d 个" % [t.name, n]}
		return {}
	# 弓箭手：没人可打时开哨兵（防御姿态，顺便给下一回合攒机会）
	if me.role == UnitData.Role.RANGED:
		var ds := Skills.get_def("sentry")
		if have.has("sentry") and not ds.is_empty() and energy >= int(ds["cost"]) and not ctx.me_has_sentry:
			# 用户口径：敌方直升机在准备俯冲、目标格会砸到我 -> 立刻开哨兵反制
			for h in ready_helis(ctx.foes):
				if heli_threatens_cell(h, me.cell):
					return {"action": "skill", "skill": "sentry",
						"note": "敌方 %s 准备俯冲到 (%d, %d)，会砸到我 -> 开哨兵" % [
							h.name, heli_ready_target(h).x, heli_ready_target(h).y]}
			# 用户口径：如果我现在处在【敌方投掷手的攻击范围】里，
			# 而这一回合（连走位都）打不到它 -> 开哨兵自保并反制它接下来的抛射
			for t0 in ctx.foes:
				if not t0.is_alive() or t0.role != UnitData.Role.THROWER:
					continue
				var dt := manhattan(me.cell, t0.cell)
				if dt < t0.rng_min or dt > t0.rng_max:
					continue                       # 它还够不着我
				var can_me := can_hit_from(me, me.cell, t0.cell)
				if not can_me:
					for c in ctx.reachable.keys():
						if can_hit_from(me, c, t0.cell):
							can_me = true
							break
				if not can_me:
					return {"action": "skill", "skill": "sentry",
						"note": "在敌方投掷手 %s 射程内（%d 格）却够不着它 -> 开哨兵" % [t0.name, dt]}
			for t in ctx.foes:
				if t.is_alive() and manhattan(me.cell, t.cell) <= me.rng_max + 2:
					return {"action": "skill", "skill": "sentry",
						"note": "开哨兵：%s 正在靠近" % t.name}
	return {}
