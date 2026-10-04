# ══════════════════════════════════════════════════════════════════════════════
# 回合边界时钟 + 英雄复活计时（从 game_master.gd 拆出，P4a）
#
# 为什么单独一个模块：
#   `turn_count` 是**全项目唯一的时钟**，同时驱动四件事 ——
#     · 英雄复活倒计时（本文件）
#     · 枪榴弹 / 轨道空袭的延时（GameMaster.Pending）
#     · 老国王每 5 个边界开一炮（battle_scene）
#     · 巡飞弹发射器的 5 边界冷却（Loiter.LAUNCH_COOLDOWN_TURNS）
#   把它和"复活该不该发生"放在一起，是因为两者的耦合最紧（`revive_at` 存的就是
#   到期的 turn_count）；其余三件事只**读**这个计数，不需要跟着搬家。
#
# 与 GameMaster 的关系：GameMaster 持有 `var clock := GameClock.new()`，
# 并把 turn_count / revive_at / 三个方法**原样转发**出去 —— 公开 API 一个字没变，
# 所以 battle_scene 的 `gm.turn_count` / playtest 的 `t_gm().due_revives()` 照旧可用。
# ══════════════════════════════════════════════════════════════════════════════
class_name GameClock
extends RefCounted

## 英雄阵亡后要等几个回合边界才复活。
## ⚠️ `GameMaster.HERO_REVIVE_TURNS` 是这个常量的转发（`const X := GameClock.HERO_REVIVE_TURNS`），
## 外部（playtest / run.gd / level.gd）习惯写 `GameMaster.HERO_REVIVE_TURNS`，两边永远相等。
const HERO_REVIVE_TURNS := 10

## 走了多少个回合边界（调试用）—— 全项目唯一的时钟。
var turn_count: int = 0

## Unit -> 到期的 turn_count
var revive_at: Dictionary = {}


## 推进一个回合边界，返回推进后的计数。
## 调用方（GameMaster.dispatch_turn_boundary）不关心返回值，保留返回只是方便测试/日志。
func advance() -> int:
	turn_count += 1
	return turn_count


# ══════════════════════════════════════════════════════════════════════════════
# 英雄重生（用户口径：三个英雄可以无限满血满护甲重生，每次要等 10 个回合）
#
# "回合"用回合边界计数（turn_count），和轨道炮击共用同一套时钟。
# 本模块只负责"谁该回来了"；真的把单位放回场上由 view 做（要动视觉节点）。
# ══════════════════════════════════════════════════════════════════════════════

func schedule_hero_revive(u: Unit, turns: int = -1) -> void:
	if u == null:
		return
	var d: int = HERO_REVIVE_TURNS if turns < 0 else turns
	revive_at[u] = turn_count + d


## 到点该复活的英雄（view 在每个回合边界之后调用）
func due_revives() -> Array[Unit]:
	var out: Array[Unit] = []
	for u in revive_at.keys():
		if int(revive_at[u]) <= turn_count:
			out.append(u)
	for u in out:
		revive_at.erase(u)
	return out


## 还要等几个回合（日志 / UI 用）；没排过复活返回 -1
func revive_countdown(u: Unit) -> int:
	if u == null or not revive_at.has(u):
		return -1
	return maxi(0, int(revive_at[u]) - turn_count)
