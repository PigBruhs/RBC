# ══════════════════════════════════════════════════════════════════════════════
# 被动表
#
# 为什么单独放一张表而不是写进 bc_stat.md：
#   · 被动是【行为】不是数值，表格里塞不下（窗口时间、按键集、每回合次数）。
#   · 挂在单位名或职业上，加一个被动只需要动 BY_NAME / BY_ROLE 一行。
# 目前有：
#   · 杰拉尔德  箭矢弹反   —— 每角色回合第一次被箭矢命中时打一次 QTE
#   · 投掷手    装填       —— 本回合没移动，回合结束 +2 精力（和休息叠加）
#   · 阿莱特    蓄势       —— 哨兵每摧毁一枚投掷物，下一发普攻 +4 力量伤害（可叠，命中清零）
#   · 老国王    加农炮 AI  —— 自己的回合朝最近的敌对单位打一发加农炮弹
#   · 公主      常备哨兵   —— 永远处于哨兵状态（没有自己的回合）
# ══════════════════════════════════════════════════════════════════════════════
class_name Passives
extends RefCounted

const DEFS := {
	## 用户口径：每条命一次，轮到她的回合时立刻复活"她回合前最后一个阵亡的可操作队友"
	"holy_sani": {
		"name": "圣萨尼",
		"desc": "每条命一次：轮到萨尼铁塔的回合时，立即复活她回合开始前最后一个阵亡的可操作队友"
			+ "（公主、老国王、沙盒元素不算）。",
		"per": "own_turn",
		"revive": true,
		"uses_per_life": 1,
	},
	"arrow_deflect": {
		"name": "箭矢弹反",
		"keys": ["q", "w", "e", "a", "s", "d"],   # 每次提示从这 6 个键里随机取一个
		"windows": [2.0, 1.0, 1.0],                # 三次按键各自的窗口（秒）：第一个宽 2 秒，之后各 1 秒
		"per": "own_turn",                          # 只有【杰拉尔德自己的回合开始】时才重置这个 flag
		"reflect": true,                           # 三次全对 -> 把箭反弹回射手
		"desc": "每回合第一次被箭矢命中时，暂停时间进行 3 次按键判定；全对则把箭反弹回射手",
	},
	"loader": {
		"name": "装填",
		"per": "turn",
		"energy": 2,                               # 本回合没移动 -> 回合结束 +2 精力
		"desc": "本回合没有移动，回合结束时额外恢复 2 点精力（和休息叠加，休息共 4 点）",
	},
	"arrow_focus": {
		"name": "蓄势",
		"power_bonus": 4,                          # 每层 +4 点力量（在"力量-护甲"那一段加上去，会被抗性减伤）
		"desc": "哨兵每摧毁一枚投掷物，下一发普攻额外造成 4 点力量伤害；"
			+ "命中前可以无限叠加，命中后清零（技能/哨兵箭不吃这个加成）",
	},
	"cannon_ai": {
		"name": "加农炮",
		"desc": "自己的回合：朝距离最近的敌对单位发射一枚加农炮弹，无视射程、障碍与友军",
	},
	"always_sentry": {
		"name": "常备哨兵",
		"desc": "永远处于哨兵状态（没有自己的回合）",
	},
}

## 单位名 -> 被动 id 列表。查表时会同时试【全名】和【base_name】，
## 所以 "公主·左 (E)" 这种会自动落到 "公主" 上（一共 4 个公主都吃同一条）。
const BY_NAME := {
	"Gerald": ["arrow_deflect"],
	"Alette": ["arrow_focus"],
	"老国王": ["cannon_ai"],
	"公主": ["always_sentry"],
	"萨尼铁塔": ["holy_sani"],
}

## 职业 -> 被动 id 列表（投掷手都有装填）
const BY_ROLE := {
	UnitData.Role.THROWER: ["loader"],
}


static func def(id: String) -> Dictionary:
	return DEFS.get(id, {})


static func exists(id: String) -> bool:
	return DEFS.has(id)


## 这个单位身上有哪些被动（名字 + 职业两种来源合并）
static func for_unit(u: Unit) -> Array:
	if u == null:
		return []
	var out: Array = []
	out.append_array(BY_NAME.get(u.name, []))
	out.append_array(BY_NAME.get(Unit.base_name(u.name), []))
	out.append_array(BY_ROLE.get(u.role, []))
	return out


static func has(u: Unit, id: String) -> bool:
	return for_unit(u).has(id)


## 单位名 -> 被动中文名（详情栏用）
static func names_for_unit(u: Unit) -> Array[String]:
	var out: Array[String] = []
	for id in for_unit(u):
		var nm := String(def(id).get("name", id))
		if not out.has(nm):
			out.append(nm)
	return out


# ── 投掷手「装填」 ────────────────────────────────────────────────────────────
## 本回合没移动的话，回合结束能补回几点精力（0 = 没有这个被动）
static func end_turn_energy(u: Unit) -> int:
	if u == null or u.has_moved:
		return 0
	for id in for_unit(u):
		var d: Dictionary = def(id)
		if int(d.get("energy", 0)) > 0:
			return int(d["energy"])
	return 0


# ── 弓箭手「蓄势」 ────────────────────────────────────────────────────────────
## 攒了几层（哨兵每摧毁一枚投掷物 +1）
static func focus_stacks(u: Unit) -> int:
	return 0 if u == null else u.focus_stacks


## 下一发普攻的额外力量伤害（千分比）。加在"力量-护甲"那一段，所以会被抗性减伤。
static func focus_bonus_milli(u: Unit) -> int:
	if u == null or not has(u, "arrow_focus"):
		return 0
	return Rules.points_to_milli(int(def("arrow_focus")["power_bonus"]) * u.focus_stacks)


static func add_focus(u: Unit) -> void:
	if u != null and has(u, "arrow_focus"):
		u.focus_stacks += 1


static func clear_focus(u: Unit) -> void:
	if u != null:
		u.focus_stacks = 0
