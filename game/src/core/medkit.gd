# ══════════════════════════════════════════════════════════════════════════════
# 医疗包（萨尼铁塔【圣萨尼】被动，第 98 轮新口径）：**纯规则**，不碰 Node、可无头测试。
#
# 用户口径（逐字）：
#   · **不再复活队友** —— 每个轮到萨尼铁塔的回合，都会**随机向一名受了伤的队友**投掷医疗包
#   · **命中则恢复 20 点血**
#   · 建模用**绿色箭头**
#   · **散布函数用杰拉德反弹的那个**（= `Spread.reflect_scatter`，r(t) = 0.48·t²）
#   · **会给飞行中碰到的沙盒元素或敌人回血**（刻意的搞笑口径，不要"修正"它）
#
# 本文件只有"选谁 / 往哪儿扔 / 回多少血"这三件纯计算；
# 真正的飞行、碰撞与回血在 `view/battle_scene.gd`（每帧推进 + 绿色箭头外观）。
# ══════════════════════════════════════════════════════════════════════════════
class_name Medkit
extends RefCounted

## 被动表的 key（数值与说明都挂在 passives.gd 的那一行上）
const DEF_ID := "holy_sani"
## 缺省回血点数（被动表没写时的兜底；真值在 `Passives.def("holy_sani")["heal_points"]`）
const DEFAULT_HEAL_POINTS := 20


## 回血点数 —— **唯一来源是被动表**（改数值只改 passives.gd 那一处）
static func heal_points() -> int:
	return int(Passives.def(DEF_ID).get("heal_points", DEFAULT_HEAL_POINTS))


## 回血量（千分比）
static func heal_milli() -> int:
	return Rules.points_to_milli(heal_points())


## ── "受了伤"的判定口径 ────────────────────────────────────────────────────────
## **力量池不满**。为什么不算护甲池：医疗包恢复的是**力量池（血）**，若把"满血但护甲有损"
## 的人选进来，命中时会回 0 血（被上限吃掉）—— 玩家看到的是"扔了包没回血"，像 bug。
## 所以"受伤"的判定与治疗量用同一条口径（都看力量池）；护甲靠休息恢复，不归医疗包管。
static func is_wounded(u: Unit) -> bool:
	return u != null and u.is_alive() and u.power_cur < u.power_max


## 萨尼铁塔能治的"队友"：**同阵营**、活着、有自己的回合、力量池不满。
## · `has_turn()` 排除公主 / 老国王 / 假人 —— 与旧版圣萨尼"可操作队友"的口径一致
##   （公主与国王是 no_turn，假人是靶子，它们不会"受伤等治疗"）。
## · 返回顺序 = `units` 的数组顺序，**不做字典遍历**，保证随机可复现。
static func wounded_mates(sani: Unit, units: Array[Unit]) -> Array[Unit]:
	var out: Array[Unit] = []
	if sani == null:
		return out
	for u in units:
		if u == null or u == sani or u.side != sani.side:
			continue
		if not u.has_turn():
			continue
		if not is_wounded(u):
			continue
		out.append(u)
	return out


## 随机挑一名受伤的队友（**确定性**：池子按 units 顺序，随机数走项目的 RngService，
## 不用 randf()）。没人受伤 -> null。
static func pick_target(sani: Unit, units: Array[Unit], rng: RngService) -> Unit:
	var pool := wounded_mates(sani, units)
	if pool.is_empty() or rng == null:
		return null
	return pool[rng.next_int(pool.size())]


# ══════════════════════════════════════════════════════════════════════════════
# 投掷散布：**复用杰拉德弹反那条曲线**（用户口径）
# ══════════════════════════════════════════════════════════════════════════════

## 落点 = 目标格心 + `Spread.reflect_scatter(...)` 的随机偏移。
## 传参：`dest` = 目标格心（浮点格坐标）；`dist` = 投掷距离（格）；
##       `speed` = `Spread.ARROW_SPEED`（8.0，曲线标定用的参考速度，与真实飞行速度无关）。
## 于是散布半径 r(dist) = 0.48 · (dist/8)²：2 格 0.03 ｜ 5 格 0.19 ｜ 10 格 0.75 ｜ 20 格 3.0。
static func scatter_landing(target: Unit, dist: float, rng: RngService) -> Vector2:
	var dest := Vector2(float(target.cell.x) + 0.5, float(target.cell.y) + 0.5)
	return Spread.reflect_scatter(dest, dist, Spread.ARROW_SPEED, rng)


## 这个距离上的散布半径（格）—— 日志与测试用
static func scatter_radius(dist: float) -> float:
	return Spread.reflect_radius(dist, Spread.ARROW_SPEED)
