# ══════════════════════════════════════════════════════════════════════════════
# 规则层：伤害 / 精力 / 加点。不 extends Node，可在 --headless 下测试。
# 公式（用户澄清 C2）：D = (力量 - 护甲) × (1 - 物抗)，物抗为五档离散值。
#   0 < D_milli < 1000 → ceil(D_milli/10)% 概率造成 1 点
#   D_milli >= 1000    → 必中，造成 floor(D_milli/1000) 点
# 全部整数运算（千分比），禁止浮点比较。
# ══════════════════════════════════════════════════════════════════════════════
class_name Rules
extends RefCounted

enum Branch { NO_DAMAGE, ROLL, AUTO }

class Preview extends RefCounted:
	var d_milli: int = 0
	var damage: int = 0          # 命中时的伤害（ROLL 分支为 1）
	var hit_percent: int = 0
	var branch: int = Branch.NO_DAMAGE
	func is_lethal() -> bool: return branch != Branch.NO_DAMAGE

## 力量线：返回 D（千分比）
static func compute_d_milli(power_milli: int, armor_milli: int, res_tier: int) -> int:
	if res_tier >= 1000:
		return 0                              # 免疫：物理伤害恒为 0
	var delta: int = power_milli - armor_milli
	if delta <= 0:
		return 0                              # 打不动
	return delta * (1000 - res_tier) / 1000   # 整数除法 = 向下取整

## 命中率：ceil(D/10) 钳制到 [1,99]
static func hit_percent_of(d_milli: int) -> int:
	if d_milli >= 1000: return 100
	if d_milli <= 0: return 0
	return clampi((d_milli + 9) / 10, 1, 99)

## 预览（不掷骰）：UI 与伤害预览共用，保证"看到的"和"打出的"一致
static func preview(power_milli: int, armor_milli: int, res_tier: int) -> Preview:
	var p := Preview.new()
	p.d_milli = compute_d_milli(power_milli, armor_milli, res_tier)
	if p.d_milli <= 0:
		p.branch = Branch.NO_DAMAGE
		p.hit_percent = 0
		p.damage = 0
	elif p.d_milli < 1000:
		p.branch = Branch.ROLL
		p.hit_percent = hit_percent_of(p.d_milli)
		p.damage = 1
	else:
		p.branch = Branch.AUTO
		p.hit_percent = 100
		p.damage = p.d_milli / 1000
	return p

## 结算（要 RNG）
static func resolve(power_milli: int, armor_milli: int, res_tier: int, rng) -> Preview:
	var p := preview(power_milli, armor_milli, res_tier)
	if p.branch == Branch.ROLL and not rng.percent(p.hit_percent):
		p.damage = 0
	return p

## 破甲线：BD + 2×精力点，无视物抗/力量，打的是护甲池
static func armor_break_damage_milli(bd_milli: int, energy_points: int) -> int:
	return bd_milli + 2000 * energy_points

## 注：精力上限是"点"，内部 1 点 = 1000‰
static func points_to_milli(points: int) -> int:
	return points * 1000


# ── 加点（原型阶段：无限点数） ─────────────────────────────────────────────
const UPG_POWER := "power"
const UPG_ARMOR := "armor"
const UPG_BD := "armor_break"
const UPG_EMAX := "energy_max"
const UPG_REST_P := "rest_power"
const UPG_REST_A := "rest_armor"
const UPG_REST_E := "rest_energy"
const UPG_RANGE := "rng_max"

## 可加点的属性池：
##   力量 / 护甲 / 破甲 / 精力上限 / 休息恢复力量 / 休息恢复护甲 / 休息恢复精力 —— 所有人
##   射程 —— 仅远程与投掷（近战不能加）
## 明确不能加点：移动力、物抗、魔抗（用户要求）
static func upgrade_options(role: int) -> Array:
	var opts := [UPG_POWER, UPG_ARMOR, UPG_BD, UPG_EMAX, UPG_REST_P, UPG_REST_A, UPG_REST_E]
	if role == UnitData.Role.RANGED or role == UnitData.Role.THROWER:
		opts.append(UPG_RANGE)
	return opts

static func option_label(key: String) -> String:
	match key:
		UPG_POWER: return "力量"
		UPG_ARMOR: return "护甲"
		UPG_BD: return "破甲伤害"
		UPG_EMAX: return "精力上限"
		UPG_REST_P: return "休息恢复力量"
		UPG_REST_A: return "休息恢复护甲"
		UPG_REST_E: return "休息恢复精力"
		UPG_RANGE: return "射程"
	return key

## 每点加值的幅度（原型阶段：1 点 = +1 力量/护甲/破甲，精力上限 +1，射程 +1）
static func apply_point(u: Unit, key: String) -> bool:
	match key:
		UPG_POWER:
			u.allocated[key] = u.allocated.get(key, 0) + 1
			u.power_max += 1000
			u.power_cur += 1000
		UPG_ARMOR:
			u.allocated[key] = u.allocated.get(key, 0) + 1
			u.armor_max += 1000
			u.armor_cur += 1000
		UPG_BD:
			u.allocated[key] = u.allocated.get(key, 0) + 1
			u.armor_break += 1000
		UPG_EMAX:
			u.allocated[key] = u.allocated.get(key, 0) + 1
			u.energy_max += 1000
			u.energy = mini(u.energy + 1000, u.energy_max)
		UPG_REST_P:
			u.allocated[key] = u.allocated.get(key, 0) + 1
			u.rest_power += 1000
		UPG_REST_A:
			u.allocated[key] = u.allocated.get(key, 0) + 1
			u.rest_armor += 1000
		UPG_REST_E:
			u.allocated[key] = u.allocated.get(key, 0) + 1
			u.rest_energy += 1000
		UPG_RANGE:
			if u.role == UnitData.Role.MELEE:
				return false
			u.allocated[key] = u.allocated.get(key, 0) + 1
			u.rng_max += 1
		_:
			return false
	return true

## 重置：只还原这一个单位的加点（用户要求"重置当前英雄的点"）
static func reset_points(u: Unit) -> void:
	for key in u.allocated.keys():
		var n: int = u.allocated[key]
		match key:
			UPG_POWER:
				u.power_max -= n * 1000
				u.power_cur = mini(u.power_cur, u.power_max)
			UPG_ARMOR:
				u.armor_max -= n * 1000
				u.armor_cur = mini(u.armor_cur, u.armor_max)
			UPG_BD:
				u.armor_break -= n * 1000
			UPG_EMAX:
				u.energy_max -= n * 1000
				u.energy = mini(u.energy, u.energy_max)
			UPG_REST_P:
				u.rest_power -= n * 1000
			UPG_REST_A:
				u.rest_armor -= n * 1000
			UPG_REST_E:
				u.rest_energy -= n * 1000
			UPG_RANGE:
				u.rng_max -= n
	u.allocated.clear()
