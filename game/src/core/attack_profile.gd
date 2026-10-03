# ══════════════════════════════════════════════════════════════════════════════
# 普攻模板表（用户要求：把"一次普攻"从散落各处的 if 链整合成【数据 + 一个入口】）
#
# 以前的问题：加一个角色要在三条入口里各插一个 if ——
#   拖拽松手 _fire() / 点目标 _attack_target_unit() / AI 出手 _ai_attack()
# 漏掉任何一条就会出 bug，而且**真实发生过**：
#   · 直升机火箭只接上拖拽那条 -> 点目标与 AI 还在打普通炮弹、不耗精力
#   · 坠机只挂在俯冲里 -> 正常挨打永远不触发
#
# 现在的分工：
#   · 这张表回答三个问题：普攻是什么（basic）、怎么瞄（aim）、要多少精力（cost）
#   · battle_scene._perform_basic() 是唯一入口，按 basic 分派到一个实现函数
#   · 三条入口只负责"算出打哪里"，然后调 _perform_basic
#   · 被动同理：见 Passives 的 on_damaged 钩子（battle_scene._after_damage_to_unit）
#
# 加新角色 = 表里加一行（+ 需要新玩法时加一个 basic 实现），三条入口自动同步。
# ══════════════════════════════════════════════════════════════════════════════
class_name AttackProfile
extends RefCounted

## ── 普攻实现种类 ─────────────────────────────────────────────────────────────
const BASIC_MELEE := "melee"     # 近战：贴上去直接结算
const BASIC_ARROW := "arrow"     # 弓箭：飞一支箭，命中后结算（可被弹反/击落）
const BASIC_BURST := "burst"     # 连发子弹：一次 N 发，各自散布各自判定
const BASIC_SHELL := "shell"     # 投掷炮弹：拖拽决定落点，抛物线 + 红圈 + 友伤
const BASIC_SALVO := "salvo"     # 火箭齐射：左右开弓多轮次，发射完即结束回合

## ── 瞄准方式（决定 UI 怎么让玩家选目标）─────────────────────────────────────
const AIM_TARGET := "target"     # 点单位/沙盒（近战、弓箭、连发）
const AIM_DRAG := "drag"         # 拖拽瞄准（投掷手感）
const AIM_CELL := "cell"         # 直接点一格（留给未来的"点地格"普攻）

## 单位名（基础名）-> 模板 id
const BY_NAME := {
	"Gerald": BASIC_MELEE,
	"Alette": BASIC_ARROW,
	"萨尼铁塔": BASIC_BURST,
	"老国王": BASIC_ARROW,
	"公主": BASIC_ARROW,
}

## 名字前缀 -> 模板 id（镜像/改型自动继承，例："俯冲轰炸直升机（不要问那么多） (E)"）
const HELI_PREFIX := "俯冲轰炸直升机"
const BY_PREFIX := {
	HELI_PREFIX: BASIC_SALVO,
}

## 职业 -> 模板 id（兜底：没写名字的角色按职业走）
const BY_ROLE := {
	UnitData.Role.MELEE: BASIC_MELEE,
	UnitData.Role.RANGED: BASIC_ARROW,
	UnitData.Role.THROWER: BASIC_SHELL,
}

## 每种普攻的默认参数。cost = 精力消耗（点）；
## "level" 非空时表示这几种数值以【关卡配置】为准（例：直升机的一切都在 Level.heli()），
## 免得同一份数值写两处、改一处漏一处。
const DEFS := {
	BASIC_MELEE: {"basic": BASIC_MELEE, "aim": AIM_TARGET, "cost": 0, "cn": "近战"},
	BASIC_ARROW: {"basic": BASIC_ARROW, "aim": AIM_TARGET, "cost": 0, "cn": "弓箭"},
	BASIC_BURST: {
		"basic": BASIC_BURST, "aim": AIM_TARGET, "cost": 0, "cn": "连发",
		"shots": 3, "gap": 0.1, "spread": "linear12",
	},
	BASIC_SHELL: {"basic": BASIC_SHELL, "aim": AIM_DRAG, "cost": 0, "cn": "投掷炮弹"},
	BASIC_SALVO: {
		"basic": BASIC_SALVO, "aim": AIM_DRAG, "cost": 4, "cn": "火箭齐射",
		"level": "heli",
	},
}

## 什么都没匹配上时的兜底（只会出现在"新加的、还没填表的单位"上）
const FALLBACK := {"basic": BASIC_MELEE, "aim": AIM_TARGET, "cost": 0, "cn": "近战"}


## 这个单位用哪张模板（id）
static func id_for(u: Unit) -> String:
	if u == null:
		return ""
	var base := Unit.base_name(u.name)
	if BY_NAME.has(base):
		return String(BY_NAME[base])
	for pre in BY_PREFIX:
		if base.begins_with(String(pre)):
			return String(BY_PREFIX[pre])
	if BY_ROLE.has(u.role):
		return String(BY_ROLE[u.role])
	return ""


## 这个单位的普攻配置（一定是完整字典，不会返回空）
static func for_unit(u: Unit) -> Dictionary:
	var id := id_for(u)
	var src: Dictionary = DEFS.get(id, FALLBACK) if id != "" else FALLBACK
	var out := src.duplicate()
	out["id"] = id if id != "" else "fallback"
	if String(out.get("level", "")) == "heli":
		var cfg := Level.heli()
		out["cost"] = int(cfg["basic_cost"])
		out["aim_mult"] = float(cfg["aim_mult"])
		out["rockets"] = int(cfg["rockets"])
		out["pairs"] = int(cfg["salvo_pairs"])
		out["gap"] = float(cfg["salvo_gap"])
		out["scatter_r"] = float(cfg["scatter_r"])
	return out


static func basic_of(u: Unit) -> String:
	return String(for_unit(u)["basic"])


static func aim_of(u: Unit) -> String:
	return String(for_unit(u)["aim"])


## 普攻的精力消耗。数值只有一处来源：写了 level 的看关卡配置，其余看表。
static func cost_of(u: Unit) -> int:
	return int(for_unit(u)["cost"])


## 给日志/详情栏用的一行中文：例 "火箭齐射（4 精力，拖拽瞄准）"
static func describe(u: Unit) -> String:
	var p := for_unit(u)
	var s := String(p.get("cn", "近战"))
	if int(p["cost"]) > 0:
		s += "（%d 精力" % int(p["cost"])
	else:
		s += "（免费"
	match String(p["aim"]):
		AIM_DRAG:
			s += "，拖拽瞄准）"
		AIM_CELL:
			s += "，点格子瞄准）"
		_:
			s += "，点目标）"
	return s


## 这一位是不是"直升机"（悬浮 + 火箭 + 坠机这一族）
static func is_heli(u: Unit) -> bool:
	return id_for(u) == BASIC_SALVO


## 自检用：表里声明了、但没有任何单位会用到的模板 id
static func unused() -> Array[String]:
	var used: Dictionary = {}
	for k in BY_NAME:
		used[String(BY_NAME[k])] = true
	for k in BY_PREFIX:
		used[String(BY_PREFIX[k])] = true
	for k in BY_ROLE:
		used[String(BY_ROLE[k])] = true
	var out: Array[String] = []
	for k in DEFS:
		if not used.has(String(k)):
			out.append(String(k))
	return out
