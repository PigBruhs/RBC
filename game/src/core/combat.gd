# ══════════════════════════════════════════════════════════════════════════════
# 统一的造伤入口（用户要求：把散落各处的造伤逻辑整合起来，不要各自为政）
#
# 之前的问题：角色、沙盒道具、炮弹、箭矢、空爆 各自写了一套结算，
# 于是"无视 50% 物抗"只写在空爆里，投掷手普攻打道具、空爆打道具全都不生效。
#
# 现在所有伤害都走这两个函数：
#   deal_to_unit(...)      对角色
#   deal_to_placeable(...) 对沙盒道具
# 参数用 opts 字典描述"这次攻击有什么特性"，默认值就是最朴素的一次攻击：
#   power       攻方力量（千分比）
#   armor_break 破甲值（千分比，0 = 不带破甲）
#   ignore_res  无视多少比例的物抗，默认 0（例：0.5 = 无视 50%）
#   fixed_power 力量伤害用固定值（空爆用），给了就不看攻方力量
#   rng         随机源
# ══════════════════════════════════════════════════════════════════════════════
class_name Combat
extends RefCounted


## 一次攻击结算的结果（给日志/UI 用）
class Result extends RefCounted:
	var hit: bool = false
	var break_dmg: int = 0          # 实际造成的破甲（千分比）
	var power_dmg: int = 0          # 实际造成的伤害（千分比）
	var note: String = ""           # 人类可读的补充说明
	var branch: int = 0             # Rules.Branch
	var hit_percent: int = 0


## 把 opts 补全成规范形式
static func opts(d: Dictionary) -> Dictionary:
	return {
		"power": int(d.get("power", 0)),
		"armor_break": int(d.get("armor_break", 0)),
		"ignore_res": float(d.get("ignore_res", 0.0)),
		"fixed_power": int(d.get("fixed_power", 0)),
		"rng": d.get("rng", null),
	}


## 计算"被削减后的物抗档"
static func effective_res(pr: int, ignore_res: float) -> int:
	var eff: int = int(pr * (1.0 - clampf(ignore_res, 0.0, 1.0)))
	return clampi(eff, 0, 1000)


## 对【角色】造伤：破甲 + 力量，返回 Result
static func deal_to_unit(target: Unit, o: Dictionary) -> Result:
	var r := Result.new()
	if target == null or not target.is_alive():
		return r
	# ① 破甲：固定值，无视物抗、无视护甲
	if o["armor_break"] > 0:
		r.break_dmg = o["armor_break"]
		target.take_armor_damage(r.break_dmg)
	# ② 力量伤害
	var eff := effective_res(target.pr, o["ignore_res"])
	var base_power: int = o["fixed_power"] if o["fixed_power"] > 0 else o["power"]
	if o["fixed_power"] > 0:
		# 固定值伤害：只按抗性折算，不看护甲（空爆用）
		if eff >= 1000:
			r.power_dmg = 0
			r.note = "被抗性完全抵消"
			r.branch = Rules.Branch.NO_DAMAGE
		else:
			r.power_dmg = Rules.points_to_milli(
				int(floor(float(base_power) / 1000.0 * (1000 - eff) / 1000.0)))
			r.hit = r.power_dmg > 0
	else:
		var p: Rules.Preview = Rules.resolve(base_power, target.armor_cur, eff, o["rng"])
		r.branch = p.branch
		r.hit_percent = p.hit_percent
		if p.branch == Rules.Branch.NO_DAMAGE:
			r.note = "力量线打不动"
		elif p.damage == 0:
			r.note = "未命中(%d%%)" % p.hit_percent
		else:
			r.power_dmg = Rules.points_to_milli(p.damage)
			r.hit = true
			if p.branch == Rules.Branch.ROLL:
				r.note = "概率命中 %d%%" % p.hit_percent
	if r.power_dmg > 0:
		target.take_power_damage(r.power_dmg)
	return r


## 对【沙盒道具】造伤：同一套规则（道具没有"未命中"，抗性与护甲照算）
static func deal_to_placeable(target: Placeable, o: Dictionary) -> Result:
	var r := Result.new()
	if target == null or not target.is_alive():
		return r
	if o["armor_break"] > 0:
		r.break_dmg = o["armor_break"]
		target.take_armor_damage(r.break_dmg)
	var eff := effective_res(target.pr, o["ignore_res"])
	var base_power: int = o["fixed_power"] if o["fixed_power"] > 0 else o["power"]
	var raw: int = base_power
	if o["fixed_power"] <= 0:
		raw = maxi(0, base_power - target.armor_cur)     # 力量线：先扣护甲
	if eff >= 1000:
		r.power_dmg = 0
		r.note = "被抗性完全抵消"
	else:
		var pts := int(floor(raw / 1000.0 * (1000 - eff) / 1000.0))
		r.power_dmg = Rules.points_to_milli(maxi(0, pts))
		r.hit = r.power_dmg > 0
	if r.power_dmg > 0:
		target.take_power_damage(r.power_dmg)
	return r


## 组装一份"攻方 → 本次攻击特性"的 opts（普通攻击 / 投掷手炮击用）
static func opts_from_attacker(u: Unit, rng: RngService) -> Dictionary:
	return opts({"power": u.power_cur, "armor_break": u.armor_break, "rng": rng})


## 空爆/轨道炮：固定 12 破甲 + 固定 12 力量，无视 50% 物抗
static func opts_orbital(d: Dictionary, rng: RngService) -> Dictionary:
	return opts({
		"armor_break": Rules.points_to_milli(int(d["shell_break"])),
		"fixed_power": Rules.points_to_milli(int(d["shell_power"])),
		"ignore_res": float(d["shell_ignore_res"]),
		"rng": rng,
	})


## 人话描述一次结果（日志统一格式）
static func describe(r: Result, pr_before: int, ignore_res: float) -> String:
	var eff := effective_res(pr_before, ignore_res)
	var parts: Array[String] = []
	if r.break_dmg > 0:
		parts.append("破甲 %s" % _fmt(r.break_dmg))
	if r.branch == Rules.Branch.NO_DAMAGE:
		parts.append("力量打不动")
	elif r.power_dmg > 0:
		parts.append("力量 %s" % _fmt(r.power_dmg))
	else:
		parts.append("力量 0")
	var tail := ""
	if ignore_res > 0.0:
		tail = "（物抗 %d%%→%d%%）" % [pr_before / 10, eff / 10]
	return " + ".join(parts) + tail


static func _fmt(milli: int) -> String:
	if milli % 1000 == 0:
		return str(milli / 1000)
	return "%.1f" % (milli / 1000.0)
