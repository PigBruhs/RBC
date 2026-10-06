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
# 第四种（第 98 轮）：magic_hit() 魔法伤害 —— 只吃魔抗、无视护甲（激光 / Reaper 被动）
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
	## 第 105 轮：批量结算时"这一波打中了几发"（逐发路径恒为 1）
	var hits_landed: int = 1
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
		# 第 104 轮：占两格的角色（轮式齐射午餐盒）**任一格被覆盖**就算被炸到；
		# 缺省单格（unit_cells 只返回锚点格）-> 既有角色逐字不变。
		var covered := false
		for c in Targeting.unit_cells(u):
			if _covered(ctr, c, radius, touch_cells):
				covered = true
				break
		if not covered:
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
		# 身体底面 = 它【现在】的高度（悬停 2 格 / 爬升到 4 格都按真实高度算，第 89 轮）
		# 碰撞圆柱**按单位取**（第 98 轮）：Reaper 半径 3 / 高 12；既有角色走缺省 = BODY_R/BODY_H
		# 同值 -> 行为与"全项目一个尺寸"逐字相同。
		# 第 104 轮：一个角色可以有**多个**碰撞圆柱（轮式齐射午餐盒 1×2）——
		# 任一圆柱被球碰到即算命中；缺省单圆柱 -> 既有角色逐字不变。
		if not Targeting.sphere_hits_unit(ctr, radius, u):
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
## ── 子弹伤害阶梯（**只作用于力量伤害**）────────────────────────────────────
##   0-12 格 100% ｜ 12-16 格 60% ｜ 16-24 格 20% ｜ 24-64 格 20% -> 0% 线性衰减
##   ｜ **>= 64 格伤害 = 0 且弹道物**模型消失**（用户口径）
## ⚠ 第 104 轮用户口径修正：这个倍率**只乘力量**，**不再乘破甲**
##   （旧口径"同时作用于破甲与力量伤害"已废弃，见 `docs/规格.md` §12.2）。
##   调用点只有一个：`projectile_sink.resolve_arrow_hit` 的子弹分支。
## ⚠ 第 111 轮用户口径：「**子弹伤害衰减修改至 24 格外保留 20% 伤害，
##   64 格模型消失（64 格伤害为 0）**」—— 以前 `> 24` 直接返回 0，
##   所以"锁定齐射"打射程外的目标永远 0 伤害；现在 24~64 之间按线性保留一部分。
const BULLET_FULL_DIST := 12.0
const BULLET_MID_DIST := 16.0
const BULLET_LOW_DIST := 24.0
## 子弹的**最大飞行距离**：到这里模型消失、伤害归零（用户口径的"64 格模型消失"）
const BULLET_MAX_DIST := 64.0
## 24 格处保留的伤害倍率（用户口径的"24 格外保留 20% 伤害"）
const BULLET_FAR_MULT := 0.2

static func bullet_mult(dist: float) -> float:
	var d: float = maxf(0.0, dist)
	if d <= BULLET_FULL_DIST:
		return 1.0
	if d <= BULLET_MID_DIST:
		return 0.6
	if d <= BULLET_LOW_DIST:
		return BULLET_FAR_MULT
	# 24 -> 64 格：从 20% **线性**衰减到 0（64 格起伤害为 0）
	if d < BULLET_MAX_DIST:
		var k: float = (d - BULLET_LOW_DIST) / (BULLET_MAX_DIST - BULLET_LOW_DIST)
		return BULLET_FAR_MULT * (1.0 - k)
	return 0.0


## ── 破片伤害曲线（用户口径，单位：格 / 点数）────────────────────────────────
##   0 格：16 力 + 8 甲 ｜ 3 格：8 力 + 4 甲 ｜ 16 格：0（仍可命中）｜ 20 格：模型消失
const FRAG_NEAR_DIST := 3.0
const FRAG_FAR_DIST := 16.0
## 第 93 轮：**8 破甲 + 16 力量**（0 格），3 格减半（8 力 / 4 甲），16 格归零
const FRAG_NEAR_POWER := 16.0
const FRAG_NEAR_BREAK := 8.0
const FRAG_MID_POWER := 8.0
const FRAG_MID_BREAK := 4.0

static func fragment_power_milli(dist: float) -> int:
	return _frag_lerp(dist, FRAG_NEAR_POWER, FRAG_MID_POWER, 0)
	
static func fragment_break_milli(dist: float) -> int:
	return _frag_lerp(dist, FRAG_NEAR_BREAK, FRAG_MID_BREAK, 0)

static func _frag_lerp(dist: float, near_v: float, mid_v: float, far_v: float) -> int:
	var d: float = maxf(0.0, dist)
	if d <= FRAG_NEAR_DIST:
		var t: float = d / FRAG_NEAR_DIST
		return int(round(lerpf(near_v, mid_v, t) * 1000.0))
	if d >= FRAG_FAR_DIST:
		return int(far_v * 1000.0)
	var t2: float = (d - FRAG_NEAR_DIST) / (FRAG_FAR_DIST - FRAG_NEAR_DIST)
	return int(round(lerpf(mid_v, far_v, t2) * 1000.0))


## 对单个角色的一次攻击（近战立即生效 / 直接命中弹道物命中）
## break_armor = true 走破甲线（固定伤害 = 攻方破甲值，无视物抗，打护甲池）
## bonus_milli = 额外力量（弓箭手「蓄势」）：加在"力量-护甲"那一段，所以会被抗性减伤
## power_mult  = 攻方力量的倍率（加农炮 = 0.5，先乘再减护甲）
## fixed_power = true：power_override 是**已经算好的固定力量伤害**，按"只过抗性、不减护甲"结算（破片用）
static func strike(attacker: Unit, target: Unit, break_armor: bool, rng,
		bonus_milli: int = 0, power_mult: float = 1.0,
		power_override: int = -1, break_override: int = -1,
		fixed_power: bool = false) -> Hit:
	if attacker == null or target == null or not target.is_alive():
		return null
	var power: int = power_override if power_override >= 0 else int(floor(attacker.power_cur * power_mult)) + bonus_milli
	var o := Combat.opts({
		"power": power if not fixed_power else 0,
		# ⚠ fixed_power 分支下 `power` 走的是"固定力量伤害"口径（只过抗性、不减护甲），
		#   所以必须放进 fixed_power 字段，不能放进 power —— 否则又会去减护甲。
		"fixed_power": power if fixed_power else 0,
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


## 齐射**按波批量结算**（第 105 轮用户口径："计命中数再传递给造伤模块"）。
##
## 为什么可以批量：同一波的 6 发是同一瞬间朝同一方向打出去的，到同一个目标的距离
## 基本相同 -> `bullet_mult(dist)` 的衰减参数相同 -> **单发伤害参数只需要算一次**
## （调用方 `_lb_fire_wave` 每波算一次快照），命中只累计"打中了几发"。
##
## **逐点等价怎么保证**：这里对 `hits` 发**逐个调用同一个 `Combat.deal_to_unit`**
## （破甲先、力量后、各发独立掷 RNG —— 与"每发各自走一遍 `strike`"的调用序列完全一致），
## 只是不再为每一发生成 `Hit` / `describe` / 日志 / 收尾。实测 72 发里：
## 公式 0.011 ms/发，而日志+收尾 0.017 ms/发 —— 批量把这部分从 72 次压到 12 次。
static func strike_volley(attacker: Unit, target: Unit, hits: int,
		per_power: int, per_break: int, rng) -> Hit:
	if attacker == null or target == null or not target.is_alive() or hits <= 0:
		return null
	var armor0: int = target.armor_cur
	var power0: int = target.power_cur
	var landed := 0
	var sum := Combat.Result.new()
	for i in hits:
		if not target.is_alive():
			break                       # 中途打死了，后面的子弹不再结算（与逐发一致）
		# ⚠ **每发都重建一份 opts**：与"逐发各自走一遍 strike"的调用序列逐字一致
		#   （`Combat.opts` 里带 rng，复用同一个 dict 会改变掷骰/字段语义）。
		var r := Combat.deal_to_unit(target, Combat.opts({
			"power": per_power, "armor_break": per_break, "rng": rng,
		}))
		sum.break_dmg += r.break_dmg
		sum.power_dmg += r.power_dmg
		sum.hit = sum.hit or r.hit
		landed += 1
	var h := Hit.new()
	h.unit = target
	h.pr_before = target.pr
	h.ignore_res = 0.0
	h.hits_landed = landed
	sum.note = "齐射 ×%d 发" % landed
	h.result = sum
	h.died = not target.is_alive()
	h.text = "%s 齐射命中 %s ×%d 发：力 -%s / 甲 -%s%s" % [
		attacker.name, target.name, landed,
		_fmt(power0 - target.power_cur), _fmt(armor0 - target.armor_cur),
		"（已阵亡）" if h.died else ""]
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


## ── 魔法伤害（第 98 轮 · Boss-1 激光）────────────────────────────────────────
## 只吃【魔法抗性 mr】，**无视护甲**（与破片的"固定力量"同族，但抗性换成 mr）。
## 也就是：不走 Combat.deal_to_unit 的力量线（那条要先减护甲），而是自己按固定值折算。
##   points = 结算前的伤害点数（例：激光 30 帧 × 2 点/帧 = 60）
##   label  = 日志里的来源词（激光 = "激光"；Reaper 的 6 格被动用缺省 "魔法"）
## 实现照 `Combat.deal_to_unit` 的 `fixed_power` 分支：只按抗性乘 (1 - eff/1000)、不碰护甲池。
static func magic_hit(attacker: Unit, target: Unit, points: int, rng, label: String = "魔法") -> Hit:
	if target == null or not target.is_alive() or points <= 0:
		return null
	var eff: int = clampi(target.mr, 0, 1000)
	# ⚠ 公式**无条件走一遍**（用户口径第 100 轮：不能"看到魔抗免疫就 return" ——
	#   免疫时 `points × 0 / 1000 = 0`，结果自然为 0，但这一步确实算过了）
	var pts: int = int(floor(float(points) * float(1000 - eff) / 1000.0))
	var h := Hit.new()
	h.unit = target
	h.pr_before = target.pr                  # 魔法伤害不看物抗，这里只是给日志留个上下文
	h.ignore_res = 0.0
	h.result = Combat.Result.new()
	h.result.power_dmg = Rules.points_to_milli(maxi(0, pts))
	h.result.hit = pts > 0
	if eff >= 1000:
		h.result.branch = Rules.Branch.NO_DAMAGE
		h.result.note = "被魔抗完全抵消"
	if pts > 0:
		target.take_power_damage(Rules.points_to_milli(pts))
	h.died = not target.is_alive()
	var tail := "（被魔抗完全抵消）" if eff >= 1000 else ""
	h.text = "  ✦ %s命中 %s：%d 点魔法伤害（魔抗 %d‰）%s" % [label, target.name, pts, eff, tail]
	return h


## ── 魔法伤害（沙盒元素版，第 100 轮用户口径："激光对沙盒元素也要有伤害"）──────────
## 与 `magic_hit` 同一套公式，只是目标换成 `Placeable`（它的池子 API 与 Unit 同级：
## `mr` / `power_cur` / `power_max` / `take_power_damage` / `is_alive`，只用它已有的，没新造）。
##
## 为什么不走 `Combat.deal_to_placeable`：那条路吃的是**物抗 pr**（力量线），
## 而魔法伤害的轴是**魔抗 mr** —— 用 pr 会算错轴。所以这里与 `magic_hit` 一样，
## 照 `Combat.deal_to_unit` 的 `fixed_power` 分支自己折算（只过抗性、不碰护甲池）。
##
## ⚠ 用户口径："**你还是得进造伤公式转一圈**" —— 所以**不对"魔抗免疫"提前 return**：
## 公式先算完（免疫 → 0），Hit 照样返回、日志照样写"0 点魔法伤害（魔抗 1000‰）"。
static func magic_hit_placeable(pl: Placeable, points: int, label: String = "激光") -> Hit:
	if pl == null or not pl.is_alive() or points <= 0:
		return null
	var eff: int = clampi(pl.mr, 0, 1000)
	# 公式照走（免疫时结果为 0）
	var pts: int = int(floor(float(points) * float(1000 - eff) / 1000.0))
	var h := Hit.new()
	h.placeable = pl
	h.pr_before = pl.pr
	h.ignore_res = 0.0
	h.result = Combat.Result.new()
	h.result.power_dmg = Rules.points_to_milli(maxi(0, pts))
	h.result.hit = pts > 0
	if eff >= 1000:
		h.result.branch = Rules.Branch.NO_DAMAGE
		h.result.note = "被魔抗完全抵消"
	if pts > 0:
		pl.take_power_damage(Rules.points_to_milli(pts))
	h.died = not pl.is_alive()
	var tail := "（被魔抗完全抵消）" if eff >= 1000 else ""
	h.text = "  ✦ %s命中 [道具] %s：%d 点魔法伤害（魔抗 %d‰）%s" % [label, pl.name, pts, eff, tail]
	return h


## 千分比 -> 显示文本。实现唯一一份在 Rules.milli_text()（去重，原来本文件与 combat.gd 各一份）
static func _fmt(milli: int) -> String:
	return Rules.milli_text(milli)
