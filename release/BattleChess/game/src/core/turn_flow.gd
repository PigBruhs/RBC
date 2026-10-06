# ══════════════════════════════════════════════════════════════════════════════
# 回合机（纯决策部分）
#
# 只回答四个问题，不碰任何 Node：
#   ① 双方还剩几个【英雄】（假人不算战力）
#   ② 该不该进入 / 保持 / 退出"最后一人连击"，孤军是谁、对手是谁
#   ③ 分胜负了没有，谁赢 —— **胜负条件来自【场景元数据】**（用户口径第 97 轮：
#      不同场景的胜负条件相互独立，见 `docs/规格.md` 与 `Level.victory()`）
#   ④ 该不该弹胜者界面（附一句人话理由）
#
# 具体动作（重排队列、弹胜者界面、结束回合）由 battle_scene 执行 ——
# 这里的函数都是纯函数，可以无头测试。
# ══════════════════════════════════════════════════════════════════════════════
class_name TurnFlow
extends RefCounted

const NONE := -1
const PLAYER := 0
const ENEMY := 1

## ── 胜负条件的类型（场景元数据里的 `victory.type`）──────────────────────────
##   "king"       一方老国王阵亡即分胜负（**缺省**，即 96 轮以前唯一的规则）
##   "annihilate" 一方**全部可行动单位**阵亡即分胜负（英雄不会重生时用）
##   "survive"    某一方撑满 `rounds` 个回合边界还没输（= 该方获胜）
##   "reach"      某一方有人站到 `cells` 里的任意一格（= 该方获胜）
## "reach" / "survive" 可以叠加在 "king" 之上：元数据写成
##   `{"type": "king", "also": [{"type": "survive", "rounds": 20, "side": 1}]}`
const TYPE_KING := "king"
const TYPE_ANNIHILATE := "annihilate"
const TYPE_SURVIVE := "survive"
const TYPE_REACH := "reach"
## "boss"：**非对称胜负** —— 打 Boss 的关卡用它（第 99 轮，Reaper 战）。
##   元数据：{"type": "boss", "boss_name": "Reaper", "king_side": 0}
##     · 敌方那个叫 `boss_name` 的单位阵亡 -> 玩家胜
##     · `king_side`（缺省 = 玩家方 0）的老国王阵亡 -> 该方失败
##   为什么要单独一种：`king` 是"谁家国王死谁输"，非对称；Boss 关是
##   "玩家国王死 = 败，Boss 死 = 胜"，两个条件针对不同单位。
const TYPE_BOSS := "boss"
const DEFAULT_TYPE := TYPE_KING


## 双方存活英雄数：[玩家, 敌方]。假人（has_turn() == false）不算战力。
static func hero_counts(units: Array[Unit]) -> Array[int]:
	var p := 0
	var e := 0
	for u in units:
		if u.is_alive() and u.has_turn():
			if u.side == UnitData.Side.PLAYER:
				p += 1
			else:
				e += 1
	return [p, e]


## 【老国王】条件：一方老国王死掉即分胜负（96 轮以前唯一的规则，现在是缺省值）
static func winner(units: Array[Unit]) -> int:
	var pk: Unit = null
	var ek: Unit = null
	for u in units:
		if not u.is_king:
			continue
		if u.side == UnitData.Side.PLAYER:
			pk = u
		else:
			ek = u
	if ek == null or not ek.is_alive():
		return PLAYER
	if pk == null or not pk.is_alive():
		return ENEMY
	return NONE


# ══════════════════════════════════════════════════════════════════════════════
# 场景胜负条件（用户口径第 97 轮：**胜负条件写进场景元数据，各场景相互独立**）
#
# 想加一种新玩法，只需要：
#   ① 在 `Level.DEFS[<场景>]["victory"]` 里声明；
#   ② 如果是一种全新的类型，在下面 `check()` 的 match 里加一个分支。
# 不需要任何场景侧 if。
# ══════════════════════════════════════════════════════════════════════════════

## 一方还有几个"可行动单位"活着（假人不算、no_turn 的公主/国王不算）。
static func actor_counts(units: Array[Unit]) -> Array[int]:
	return hero_counts(units)


## 单条条件的判定。返回 NONE = 还没满足，PLAYER/ENEMY = 该方获胜。
##   spec  : 条件字典，见上方 TYPE_* 说明
##   ctx   : {"turn_count": int（已推进的回合边界数）, "units": Array[Unit]}
static func check_one(spec: Dictionary, units: Array[Unit], turn_count: int) -> int:
	var t := String(spec.get("type", DEFAULT_TYPE))
	match t:
		TYPE_KING:
			return winner(units)
		TYPE_ANNIHILATE:
			var c := hero_counts(units)
			if c[0] <= 0 and c[1] <= 0:
				return NONE                       # 两边同时全灭：不算分胜负（交给上层兜底）
			if c[1] <= 0:
				return PLAYER
			if c[0] <= 0:
				return ENEMY
			return NONE
		TYPE_SURVIVE:
			# 撑满 rounds 个回合边界：该方获胜。side 缺省 = 敌方（最常见的"守住 N 回合"）
			var side := int(spec.get("side", UnitData.Side.ENEMY))
			if turn_count < int(spec.get("rounds", 0)):
				return NONE
			return PLAYER if side == UnitData.Side.ENEMY else ENEMY
		TYPE_REACH:
			# 某一方有人站进 cells 里的任意一格：该方获胜。
			# 没写 side = 谁先站到谁赢。
			var want := int(spec.get("side", -1))
			var cells: Array = spec.get("cells", [])
			for u in units:
				if not u.is_alive() or not u.has_turn():
					continue
				if want >= 0 and u.side != want:
					continue
				if cells.has(u.cell):
					return u.side
			return NONE
		TYPE_BOSS:
			# 非对称：玩家老国王死 = 败；那只 Boss 死 = 胜。
			var boss_name := String(spec.get("boss_name", ""))
			var king_side := int(spec.get("king_side", UnitData.Side.PLAYER))
			for u in units:
				if boss_name != "" and String(u.name).begins_with(boss_name):
					if u.side != king_side and not u.is_alive():
						return king_side                 # Boss 阵亡 -> 玩家胜
			for u in units:
				if u.is_king and u.side == king_side and not u.is_alive():
					return 1 - king_side                 # 玩家老国王阵亡 -> 败
			return NONE
	return NONE


## 一条场景的完整胜负判定。
##   cfg   : `Level.victory()` 的返回值（缺省 = {"type": "king"}）
##   ctx   : {"turn_count": int}
## 返回 NONE = 还没结束，否则是获胜方（TurnFlow.PLAYER / TurnFlow.ENEMY）。
static func check(units: Array[Unit], cfg: Dictionary, turn_count: int = 0) -> int:
	if cfg.is_empty():
		return winner(units)
	var w := check_one(cfg, units, turn_count)
	if w != NONE:
		return w
	# 叠加条件：只要有一条满足就分胜负
	for extra in cfg.get("also", []):
		var w2 := check_one(extra as Dictionary, units, turn_count)
		if w2 != NONE:
			return w2
	return NONE


## 为什么结束（日志/胜者界面用的人话）。返回 "" = 还没结束。
static func reason_text(cfg: Dictionary, winner_side: int) -> String:
	var t := String(cfg.get("type", DEFAULT_TYPE))
	match t:
		TYPE_ANNIHILATE:
			return "一方全部可行动单位阵亡"
		TYPE_SURVIVE:
			return "守满 %d 个回合" % int(cfg.get("rounds", 0))
		TYPE_REACH:
			return "有人抵达目标格"
		TYPE_BOSS:
			return "击毙 %s" % String(cfg.get("boss_name", "Boss"))
		_:
			return "老国王阵亡"


## 最后一人连击的决策。
## 返回 {want: bool, lone: Unit, opponents: Array[Unit], changed: bool}
##   want      : 最终该不该处于连击状态
##   changed   : 和当前状态不同（调用方需要真的重排）
## 用户规则：
##   · 一方只剩 1 人、另一方 >= 2 人 -> 进入连击（孤军 -> 对面每人 -> 孤军 -> …）
##   · 连击一旦进入就保持：对面即使靠复活变回多人，也仍然是连击
##   · 双方都只剩 1 人 -> 退出连击，回到严格交替
static func last_stand_plan(units: Array[Unit], was_last_stand: bool,
		lone_alive: bool) -> Dictionary:
	var p := 0
	var e := 0
	var lone_p: Unit = null
	var lone_e: Unit = null
	for x in units:
		if not (x.is_alive() and x.has_turn()):
			continue
		if x.side == UnitData.Side.PLAYER:
			p += 1
			lone_p = x
		else:
			e += 1
			lone_e = x
	var one_each: bool = (p == 1 and e == 1)
	var lone_vs_many: bool = (p == 1 and e >= 2) or (e == 1 and p >= 2)
	var stay: bool = was_last_stand and lone_alive and (lone_vs_many or one_each)
	var want: bool = stay or (not was_last_stand and lone_vs_many)
	var out := {"want": want, "changed": want != was_last_stand, "lone": null,
		"opponents": [] as Array[Unit]}
	if not want:
		return out
	var lone: Unit = lone_p if p == 1 else lone_e
	var opps: Array[Unit] = []
	for x in units:
		if x != lone and x.is_alive() and x.has_turn():
			opps.append(x)
	out["lone"] = lone
	out["opponents"] = opps
	return out
