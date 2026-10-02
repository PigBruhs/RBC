# ══════════════════════════════════════════════════════════════════════════════
# 伤害结算：**谁掉了多少血，只在这里算**
#
# 设计（用户口径："伤害结算单独一个模块"）：
#   · 这里只做"结算"，不做"表现"：不闪白、不刷 UI、不播动画、不结束回合。
#   · 每次结算返回一个 Hit（或一组 Hit），battle_scene 拿到后负责演出来。
#   · 因此本模块无 Node 依赖，可以无头测试。
#
# 三种入口：
#   blast()        爆心范围内全体（炮弹 / 轨道炮 / 地毯式轰炸）
#   strike()       对单个角色的一次攻击（近战立即 / 箭矢命中）
#   prop_strike()  箭矢打中沙盒道具
# ══════════════════════════════════════════════════════════════════════════════
class_name Damage
extends RefCounted


## 一次结算的结果。battle_scene 靠它决定"演什么"
class Hit extends RefCounted:
	var unit: Unit = null                 # 挨打的是角色（和 placeable 二选一）
	var placeable: Placeable = null       # 挨打的是沙盒道具
	var result: Combat.Result = null      # Combat 的原始结果
	var pr_before: int = 0                # 挨打前的物抗（日志要显示"80%→40%"）
	var ignore_res: float = 0.0
	var friendly: bool = false            # 是不是友军（日志要标出来）
	var died: bool = false                # 这一下打死了
	var text: String = ""                 # 人话日志，调用方直接 _log(text)


# ══════════════════════════════════════════════════════════════════════════════
# 参数组装
# ══════════════════════════════════════════════════════════════════════════════
## 投掷手炮击的参数：破甲 + 力量，无视 50% 物抗
## （用户口径：不再有"用精力加伤害"，所以这里没有 k）
static func blast_opts(attacker: Unit, rng) -> Dictionary:
	return Combat.opts({
		"power": attacker.power_cur,
		"armor_break": attacker.armor_break,
		"ignore_res": 0.5,
		"rng": rng,
	})


# ══════════════════════════════════════════════════════════════════════════════
# 范围结算
# ══════════════════════════════════════════════════════════════════════════════
## 爆心范围内全体结算。
##   touch_cells = true  -> "红圈沾到格子就算命中"（用户口径，普攻炮击用）
##   touch_cells = false -> "圆心到格中心"（老轨道炮的严格判定，保留兼容）
## skip        = 不打自己（普攻炮击用；轨道炮不分敌我，传 null）
## caster_side = 日志里标"友军"用的阵营
static func blast(attacker: Unit, ctr: Vector2, radius: float, opts: Dictionary,
		units: Array[Unit], placeables: Array[Placeable],
		skip: Unit = null, caster_side: int = -1, touch_cells: bool = true) -> Array[Hit]:
	var out: Array[Hit] = []
	var side: int = caster_side if caster_side >= 0 else (attacker.side if attacker != null else -1)
	for u in units:
		if not u.is_alive() or u == skip:
			continue
		if not _covered(ctr, u.cell, radius, touch_cells):
			continue
		var h := Hit.new()
		h.unit = u
		h.pr_before = u.pr
		h.ignore_res = float(opts.get("ignore_res", 0.0))
		h.friendly = (side >= 0 and u.side == side)
		h.result = Combat.deal_to_unit(u, opts)
		h.died = not u.is_alive()
		h.text = "  %s%s：%s" % ["[color=#8f8]友军[/color] " if h.friendly else "",
			u.name, Combat.describe(h.result, h.pr_before, h.ignore_res)]
		out.append(h)
	for pl in placeables:
		if not pl.is_alive():
			continue
		if not _covered(ctr, pl.cell, radius, touch_cells):
			continue
		var h2 := Hit.new()
		h2.placeable = pl
		h2.pr_before = pl.pr
		h2.ignore_res = float(opts.get("ignore_res", 0.0))
		h2.result = Combat.deal_to_placeable(pl, opts)
		h2.died = not pl.is_alive()
		h2.text = "  [道具] %s：%s" % [pl.name,
			Combat.describe(h2.result, h2.pr_before, h2.ignore_res)]
		out.append(h2)
	return out


static func _covered(ctr: Vector2, cell: Vector2i, radius: float, touch_cells: bool) -> bool:
	if touch_cells:
		return Targeting.circle_touches_cell(ctr, cell, radius)
	return ctr.distance_to(Vector2(float(cell.x) + 0.5, float(cell.y) + 0.5)) <= radius


# ══════════════════════════════════════════════════════════════════════════════
# 空爆（炮弹在半空被打爆）
# ══════════════════════════════════════════════════════════════════════════════
## 用户口径：三维判定 + **范围恒定为一格球**（半径 0.5）。
## 所以"在头顶上炸开但飞得高"是打不到人的；贴地炸也只能擦到身边那一圈。
const AIR_BURST_R := 0.5
const BODY_R := 0.30                 # 角色身体半径（与箭矢判定一致）
const BODY_H := 1.00                 # 角色身体高度（单位身高）

static func air_burst(attacker: Unit, ctr: Vector3, opts: Dictionary, units: Array[Unit],
		skip: Unit = null, radius: float = AIR_BURST_R) -> Array[Hit]:
	var out: Array[Hit] = []
	var side: int = attacker.side if attacker != null else -1
	for u in units:
		if not u.is_alive() or u == skip:
			continue
		if not Targeting.sphere_hits_body(ctr, radius, u.cell, BODY_R, BODY_H):
			continue
		var h := Hit.new()
		h.unit = u
		h.pr_before = u.pr
		h.ignore_res = float(opts.get("ignore_res", 0.0))
		h.friendly = (side >= 0 and u.side == side)
		h.result = Combat.deal_to_unit(u, opts)
		h.died = not u.is_alive()
		h.text = "  %s%s：%s" % ["[color=#8f8]友军[/color] " if h.friendly else "",
			u.name, Combat.describe(h.result, h.pr_before, h.ignore_res)]
		out.append(h)
	return out


# ══════════════════════════════════════════════════════════════════════════════
# 单体结算
# ══════════════════════════════════════════════════════════════════════════════
## ── 子弹伤害阶梯（用户口径，同时作用于破甲与力量伤害）──────────────────────
##   0-12 格 100% ｜ 12-16 格 60% ｜ 16-24 格 20% ｜ >24 格 0（仍可命中）
const BULLET_FULL_DIST := 12.0
const BULLET_MID_DIST := 16.0
const BULLET_LOW_DIST := 24.0

static func bullet_mult(dist: float) -> float:
	var d: float = maxf(0.0, dist)
	if d <= BULLET_FULL_DIST:
		return 1.0
	if d <= BULLET_MID_DIST:
		return 0.6
	if d <= BULLET_LOW_DIST:
		return 0.2
	return 0.0


## ── 破片伤害曲线（用户口径，单位：格 / 点数）────────────────────────────────
##   0 格：25 力 + 25 甲 ｜ 3 格：12 力 + 12 甲 ｜ 16 格：0（仍可命中）｜ 20 格：模型消失
const FRAG_NEAR_DIST := 3.0
const FRAG_FAR_DIST := 16.0
const FRAG_NEAR_POWER := 25
const FRAG_NEAR_BREAK := 25
const FRAG_MID_POWER := 12
const FRAG_MID_BREAK := 12

static func fragment_power_milli(dist: float) -> int:
	return _frag_lerp(dist, FRAG_NEAR_POWER, FRAG_MID_POWER, 0)
	
static func fragment_break_milli(dist: float) -> int:
	return _frag_lerp(dist, FRAG_NEAR_BREAK, FRAG_MID_BREAK, 0)

static func _frag_lerp(dist: float, near_v: int, mid_v: int, far_v: int) -> int:
	var d: float = maxf(0.0, dist)
	if d <= FRAG_NEAR_DIST:
		var t: float = d / FRAG_NEAR_DIST
		return int(round(lerpf(float(near_v), float(mid_v), t) * 1000.0))
	if d >= FRAG_FAR_DIST:
		return far_v * 1000
	var t2: float = (d - FRAG_NEAR_DIST) / (FRAG_FAR_DIST - FRAG_NEAR_DIST)
	return int(round(lerpf(float(mid_v), float(far_v), t2) * 1000.0))


## 对单个角色的一次攻击（近战立即生效 / 直接命中弹道物命中）
## break_armor = true 走破甲线（固定伤害 = 攻方破甲值，无视物抗，打护甲池）
## bonus_milli = 额外力量（弓箭手「蓄势」）：加在"力量-护甲"那一段，所以会被抗性减伤
## power_mult  = 攻方力量的倍率（加农炮 = 0.5，先乘再减护甲）
static func strike(attacker: Unit, target: Unit, break_armor: bool, rng,
		bonus_milli: int = 0, power_mult: float = 1.0,
		power_override: int = -1, break_override: int = -1) -> Hit:
	if attacker == null or target == null or not target.is_alive():
		return null
	var power: int = power_override if power_override >= 0 else int(floor(attacker.power_cur * power_mult)) + bonus_milli
	var o := Combat.opts({
		"power": power,
		"armor_break": (break_override if break_override >= 0 else attacker.armor_break) if break_armor else 0,
		"rng": rng,
	})
	var h := Hit.new()
	h.unit = target
	h.pr_before = target.pr
	h.ignore_res = 0.0
	h.result = Combat.deal_to_unit(target, o)
	h.died = not target.is_alive()
	h.text = "%s %s → %s：%s" % [attacker.name, "破甲" if break_armor else "攻击",
		target.name, Combat.describe(h.result, h.pr_before, 0.0)]
	if bonus_milli > 0:
		h.text += "（含蓄势 +%s）" % _fmt(bonus_milli)
	return h


## 箭矢打中沙盒道具（力量线，吃道具自己的物抗与护甲）
static func prop_strike(attacker: Unit, pl: Placeable, rng) -> Hit:
	if attacker == null or pl == null or not pl.is_alive():
		return null
	var power: int = attacker.power_cur
	var pr: Rules.Preview = Rules.resolve(power, pl.armor_cur, pl.pr, rng)
	var h := Hit.new()
	h.placeable = pl
	h.pr_before = pl.pr
	h.ignore_res = 0.0
	if pr.branch == Rules.Branch.NO_DAMAGE:
		h.text = "  箭矢命中 %s，但打不动" % pl.name
	elif pr.damage == 0:
		h.text = "  箭矢命中 %s，未命中（%d%%）" % [pl.name, pr.hit_percent]
	else:
		pl.take_power_damage(Rules.points_to_milli(pr.damage))
		h.died = not pl.is_alive()
		h.text = "  %s 被箭矢击中：%d 点（剩余 %s）" % [pl.name, pr.damage, _fmt(pl.power_cur)]
	return h


static func _fmt(milli: int) -> String:
	if milli % 1000 == 0:
		return str(milli / 1000)
	return "%.1f" % (milli / 1000.0)
