# 雷达午餐盒的**机制**（第 111 轮用户口径）——RefCounted 模块，不碰表现层。
#
# 用户原话摘要：
#   · 普攻：选定一个敌对角色开始锁定，**没有距离限制**；
#     选定时距离里有多少个 20 格就需要多少回合完成锁定
#     （81 格 -> 5 回合；**用开始锁定时的距离**，后续距离变化不影响）
#   · 锁定进度重置的四种情况：选择新锁定目标 / 锁定目标死亡 / 雷达车休息 / 雷达车被摧毁
#   · 技能：选一个友方角色连接（距离 16 格，**持续检查、走远就断**）；
#     **连接与锁定解耦**（可以只锁定不连接、也可以只连接不锁定）；**最多连接两名**，
#     超过两个时**把最先连接的挤出队列**（FIFO）
#   · 一回合只能"普攻选定锁定目标"**或**"技能连接友军"（二选一）
#
# 本模块只保存/推进状态，不做任何绘制与输入；表现层（HUD / 光柱）读这里的状态。
class_name Radar
extends RefCounted

const NAME := "雷达午餐盒"                 # 单位名（= 数据表里的名字）
const LOCK_PER_TURNS := 20.0               # 每 20 格 = 1 回合
const LINK_RANGE := 16.0                   # 连接距离上限（格，持续检查）
const MAX_LINKS := 2                       # 最多连接两名友军


## 一个雷达车的状态。字段名稳定（表现层与探针都直接读）。
class State:
	extends RefCounted
	var lock_name: String = ""             # 正在锁定的敌人名（"" = 没锁）
	var lock_total: int = 0                # 开始锁定时算出的"需要几回合"
	var lock_left: int = 0                 # 仍需回合数（0 且 lock_name != "" = 已锁定）
	var links: Array[String] = []          # 已连接的友军名（FIFO，最多 MAX_LINKS）

	func locked() -> bool:
		return lock_name != "" and lock_left <= 0

	func locking() -> bool:
		return lock_name != "" and lock_left > 0

	## 表现层/探针用的一行摘要
	func desc() -> String:
		if lock_name == "":
			return "未锁定"
		if locked():
			return "已锁定 %s" % lock_name
		return "锁定中 %s（仍需 %d 回合）" % [lock_name, lock_left]


## 开始锁定的所需回合数 = ceil(距离 / 20)，**至少 1**。
## 用户例子：81 格 -> ceil(4.05) = 5 回合 ✓
static func turns_for(dist: float) -> int:
	return maxi(1, int(ceil(maxf(0.0, dist) / LOCK_PER_TURNS)))


## 选定新目标：**先重置**（用户口径：选择新锁定目标时锁定进度重置），再按当前距离算回合数。
static func begin_lock(st: State, target_name: String, dist: float) -> void:
	st.lock_name = target_name
	st.lock_total = turns_for(dist)
	st.lock_left = st.lock_total


## 重置锁定进度（目标死亡 / 休息 / 被摧毁都走这里）。
## ⚠ **不动 `links`** —— 用户口径「连接与锁定解耦」。
static func clear_lock(st: State) -> void:
	st.lock_name = ""
	st.lock_total = 0
	st.lock_left = 0


## 轮到雷达车自己的回合：仍需回合数 -1（到 0 = 已锁定），返回是否刚刚完成。
## ⚠ `begin_lock` 也在**它自己的回合**里发生，所以调用方要在"选定"之后立刻调一次这里，
##   这样"81 格 -> 5 回合"才成立（选定那一回合本身算第 1 回合）。
static func tick_turn(st: State) -> bool:
	if st.lock_name == "" or st.lock_left <= 0:
		return false
	st.lock_left -= 1
	return st.lock_left <= 0


## 连接一个友军（FIFO：超过 `MAX_LINKS` 就把最先连接的挤掉）。
## 返回是否真的新增（重复连接同一个不重复加）。
static func add_link(st: State, friend_name: String) -> bool:
	if friend_name == "" or st.links.has(friend_name):
		return false
	st.links.append(friend_name)
	while st.links.size() > MAX_LINKS:
		st.links.pop_front()
	return true


## 每帧/每回合检查连接距离：**走远就断**（用户口径：持续检查）。
## `pos_of` 是 Callable(name) -> Vector2（返回 Vector2.INF 表示找不到 -> 也断）。
static func prune_links(st: State, radar_pos: Vector2, pos_of: Callable) -> void:
	var keep: Array[String] = []
	for nm in st.links:
		var p: Vector2 = pos_of.call(nm)
		if p == Vector2.INF:
			continue                            # 目标没了（死了/退场）-> 断
		if radar_pos.distance_to(p) <= LINK_RANGE:
			keep.append(nm)
	st.links = keep


# ── 难点 2：对"被连接友军"的增益 ────────────────────────────────────────────
## 锁定**完成前**：连接友军的弹道散布 **降低 50%**（= 半径 × 0.5）。
const PRE_LOCK_SPREAD_MULT := 0.5
## 锁定**完成后**：散布缩小到**直径 0.1 格的球**（= 半径 0.05）。
const POST_LOCK_SPREAD_R := 0.05


## 某个单位此刻该用的"散布半径倍率/绝对值"。返回 `{mult, abs_r, has_abs}`：
##   · 没被任何雷达车连接 -> `{mult 1.0, has_abs false}`（原样）
##   · 被连接、其雷达车**未锁定** -> `{mult 0.5, has_abs false}`
##   · 被连接、其雷达车**已锁定** -> `{mult 1.0, abs_r 0.05, has_abs true}`
## `states` 是所有雷达车的 `State`（通常只有一台）。
static func spread_modifier(states: Array, unit_name: String) -> Dictionary:
	var mult := 1.0
	var abs_r := -1.0
	for s in states:
		var st: State = s
		if not st.links.has(unit_name):
			continue
		if st.locked():
			abs_r = POST_LOCK_SPREAD_R            # 已锁定优先（更小）
		else:
			mult = minf(mult, PRE_LOCK_SPREAD_MULT)
	if abs_r >= 0.0:
		return {"mult": 1.0, "abs_r": abs_r, "has_abs": true}
	return {"mult": mult, "abs_r": -1.0, "has_abs": false}


## 把上面的修正施加到一个散布半径上（表现层与弹道层都调它，保证口径一致）。
static func apply_spread(base_r: float, mod: Dictionary) -> float:
	if bool(mod.get("has_abs", false)):
		return float(mod["abs_r"])
	return base_r * float(mod.get("mult", 1.0))


## 某单位是否可以把 `target_name` 当攻击对象 —— 用户口径：
## 「锁定完成后将该角色加入**所有连接友军**的普攻和技能的攻击对象中」。
## 也就是：**只有被连接的友军**才享受"无视距离选被锁定目标"。
static func may_target(states: Array, attacker_name: String, target_name: String) -> bool:
	for s in states:
		var st: State = s
		if st.locked() and st.lock_name == target_name and st.links.has(attacker_name):
			return true
	return false
