# ══════════════════════════════════════════════════════════════════════════════
# 回合机（纯决策部分）
#
# 只回答三个问题，不碰任何 Node：
#   ① 双方还剩几个【英雄】（假人不算战力）
#   ② 该不该进入 / 保持 / 退出"最后一人连击"，孤军是谁、对手是谁
#   ③ 分胜负了没有，谁赢 —— 用户口径：只看两边老国王，谁先死谁输
#
# 具体动作（重排队列、弹胜者界面、结束回合）由 battle_scene 执行 ——
# 这里的函数都是纯函数，可以无头测试。
# ══════════════════════════════════════════════════════════════════════════════
class_name TurnFlow
extends RefCounted

const NONE := -1
const PLAYER := 0
const ENEMY := 1


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


## 判断胜负。用户口径：**唯一结束条件是一方老国王死掉**（英雄可以无限重生）
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
