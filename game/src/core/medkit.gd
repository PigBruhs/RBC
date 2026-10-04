# ══════════════════════════════════════════════════════════════════════════════
# 医疗包（萨尼铁塔【圣萨尼】被动，第 98 轮新口径）：**纯规则**，不碰 Node、可无头测试。
#
# 用户口径：
#   · **不再复活队友** —— 每个轮到萨尼铁塔的回合，都会**随机向一名受了伤的队友**投掷医疗包
#   · **命中则恢复 10 点血**（第 103 轮：20 → 10）
#   · 建模用**绿色箭头**
#   · ~~散布函数用杰拉德反弹的那个~~（第 98 轮口径）→ **第 100 轮改成：散布固定 1 格**
#     （用户原话："把医疗包的散步缩小为一格"；反弹曲线远距离必失手，见本文件末尾的说明）
#   · **会给飞行中碰到的沙盒元素或敌人回血**（刻意的搞笑口径，不要"修正"它）
#
# 本文件只有"选谁 / 往哪儿扔 / 回多少血"这三件纯计算；
# 真正的飞行、碰撞与回血在 `view/battle_scene.gd`（每帧推进 + 绿色箭头外观）。
# ══════════════════════════════════════════════════════════════════════════════
class_name Medkit
extends RefCounted

## 被动表的 key（数值与说明都挂在 passives.gd 的那一行上）
const DEF_ID := "holy_sani"
## 缺省回血点数（被动表没写时的兜底；真值在 `Passives.def("holy_sani")["heal_points"]`）。
## 第 103 轮用户口径：20 → **10**（两处保持同值）。
const DEFAULT_HEAL_POINTS := 10


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
# 投掷散布：**固定 1 格**（第 100 轮用户口径："把医疗包的散步缩小为一格"）
#
# 历史：第 98 轮按用户要求复用了杰拉德弹反那条**惩罚性**曲线（r = 0.48·t²），
# 结果 24 格时散布 4.40 格 → 远距离基本必失手。第 100 轮改成固定半径 1 格、与距离无关。
# ══════════════════════════════════════════════════════════════════════════════

## 散布半径（格）—— 与距离无关
const SCATTER_R := 1.0


## 落点 = 目标格心 + 半径 1 格圆盘内的均匀随机偏移。
## · 圆内**均匀**（半径按 sqrt(u) 取，否则会堆在圆心 —— 与 Spread 同款做法）；
## · 方向均匀随机，随机数走项目的 `RngService`（**确定性**，不用 randf）；
## · 落点天然不超过"目标格心 1 格"（= 圆盘半径），所以不再额外做地形/边界钳制
##   —— 目标本身一定在场内，1 格偏移最多擦到相邻格；真飞出去就自然飘走（有日志）。
## 参数 `dist` 保留仅为签名兼容（第 100 轮起散布与距离无关）。
static func scatter_landing(target: Unit, dist: float, rng: RngService) -> Vector2:
	var dest := Vector2(float(target.cell.x) + 0.5, float(target.cell.y) + 0.5)
	if rng == null:
		return dest
	var ang := rng.next_float() * TAU
	var rr := SCATTER_R * sqrt(rng.next_float())
	return dest + Vector2(cos(ang) * rr, sin(ang) * rr)


## 这个距离上的散布半径（格）—— 第 100 轮起恒为 1.0（参数保留仅为签名兼容）
static func scatter_radius(dist: float) -> float:
	return SCATTER_R
