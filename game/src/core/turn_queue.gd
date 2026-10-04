# ══════════════════════════════════════════════════════════════════════════════
# 回合队列（用户口径第 87 轮：**两条循环队列，队头先动**）
#
#   · 双方各一条队列，开战时一次性随机排好，之后一直按这个顺序循环。
#   · **队头 = 下一个行动的人**；一个回合结束后，把刚行动的人【出队再入队尾】，
#     然后换边（这就是"执行出队入队尾"）。
#   · **阵亡 = 当场移出队列**（不是跳到队尾）—— 死人不再占位置，也不再让整圈变长。
#   · **复活 = 压进自己这条队列的队头**（一个回合边界复活多人就压进多个队头元素），
#     所以他下一次立刻能动，不用等一整圈。
#     用户报的"复活导致的饥饿"就是这里：以前死人的位置还留在环上，
#     而且一方全灭时对面会一直动，活过来的人却排在环的后面一直轮不到。
#   · **一方队列空了 -> 自动跳过那一方的回合**（另一方连续行动，直到有人复活）。
#
# 最后一人连击（用户规则）：一方只剩 1 人时，孤军 → 对面每人各一次 → 孤军 …
#   连击一旦进入就保持（对面复活也不退出）。
#
# 【回合顺序模式】（第 99 轮，用户口径）：
#   · `MODE_ALTERNATE`（缺省）= 严格交替：一个人行动完就换边。**除 Reaper 战外的所有场景都用这个。**
#   · `MODE_BY_SIDE`         = **一边所有角色都行动完，才轮到另一边**。
#     用户原话：「一边所有角色进行完回合才轮到另一边；只有这个场景是这样的」——
#     所以它由【场景元数据】`Level.DEFS[<场景>]["turn_mode"]` 声明，**不是全局改动**。
#     实现 = `advance()` 里判断"本边还剩几个没行动的人"：还有就不换边，
#     一个场景里只有声明了 by_side 的那一个会走到这条分支。
# ══════════════════════════════════════════════════════════════════════════════
class_name TurnQueue
extends RefCounted

const MODE_ALTERNATE := "alternate"        # 严格交替（缺省）
const MODE_BY_SIDE := "by_side"            # 一边全行动完才换边（Reaper 战）

var p_queue: Array[Unit] = []        # 玩家方队列（[0] = 队头）
var e_queue: Array[Unit] = []        # 敌方队列（[0] = 队头）
var turn_side: int = 0               # 下一个该行动的阵营
var order: Array[Unit] = []          # 给 UI 看：接下来 N 个行动者（预测，含当前）
var index: int = 0                   # order 里的位置（仅供 UI/测试）
var round_no: int = 0
var rng: RngService
var last_stand: bool = false
var lone: Unit = null
## 回合顺序模式（`MODE_ALTERNATE` / `MODE_BY_SIDE`）—— 由场景元数据的 `turn_mode` 决定
var mode: String = MODE_ALTERNATE
## by_side 专用：这一"圈"里已经行动过的人（键 = 单位，本圈结束就清空）。
## 用"谁还没动"而不是"数人头"来判换边 —— 阵亡/复活中途改过队列长度也不会算错。
var _acted: Dictionary = {}


func _init(rng_service: RngService) -> void:
	rng = rng_service


# ══════════════════════════════════════════════════════════════════════════════
# 建队 / 重排
# ══════════════════════════════════════════════════════════════════════════════
## 开战/重排：双方各自随机排好循环队列
func rebuild(units: Array[Unit]) -> int:
	var players: Array[Unit] = []
	var enemies: Array[Unit] = []
	for u in units:
		# 假人不行动、不进队列（用户要求）；公主/国王是 no_turn，也不进
		if u.is_alive() and u.has_turn():
			if u.side == UnitData.Side.PLAYER:
				players.append(u)
			else:
				enemies.append(u)
	_shuffle(players)
	_shuffle(enemies)
	p_queue = players
	e_queue = enemies
	turn_side = UnitData.Side.PLAYER
	round_no += 1
	# 连击状态不在这里清（常规重排不该把连击抹掉）。
	# 但如果连击开着，重排后必须恢复成"孤军 + 对面"的结构，
	# 否则一次普通 rebuild 就会把连击结构冲掉（UI 与规则都会错）。
	if last_stand and lone != null and lone.is_alive():
		_rebuild_last_stand(lone, _others_of(lone))
	_purge_dead()
	_refresh_preview()
	return p_queue.size() + e_queue.size()


## 进入连击模式（对外 API）：孤军 + 对手列表（固定循环，孤军先手）
func enter_last_stand(lone_unit: Unit, opponents: Array[Unit]) -> void:
	last_stand = true
	lone = lone_unit
	_rebuild_last_stand(lone_unit, opponents)


## 退出连击，回到常规循环队列
func exit_last_stand(units: Array[Unit]) -> void:
	last_stand = false
	lone = null
	rebuild(units)


## 连击模式：孤军 + 对手列表（固定循环，**孤军先手**）
func _rebuild_last_stand(lone_unit: Unit, opponents: Array[Unit]) -> void:
	var opps: Array[Unit] = []
	for o in opponents:
		if o.is_alive() and o != lone_unit:
			opps.append(o)
	if lone_unit.side == UnitData.Side.PLAYER:
		p_queue = [lone_unit]
		e_queue = opps
		turn_side = UnitData.Side.PLAYER
	else:
		e_queue = [lone_unit]
		p_queue = opps
		turn_side = UnitData.Side.ENEMY
	round_no += 1
	_purge_dead()
	_refresh_preview()


## 某个单位之外的所有存活单位
func _others_of(u: Unit) -> Array[Unit]:
	var out: Array[Unit] = []
	for x in p_queue + e_queue:
		if x != u and x.is_alive():
			out.append(x)
	return out


# ══════════════════════════════════════════════════════════════════════════════
# 队列维护：阵亡移出 / 复活压队头
# ══════════════════════════════════════════════════════════════════════════════
## 阵亡：**当场移出队列**（用户口径第 87 轮：不是跳到队尾）
func remove(u: Unit) -> bool:
	if u == null:
		return false
	var hit := p_queue.has(u) or e_queue.has(u)
	p_queue.erase(u)
	e_queue.erase(u)
	if hit:
		_refresh_preview()
	return hit


## 复活：**压进自己这条队列的队头**（下一个立刻能动）
func push_front(u: Unit) -> bool:
	if u == null or not u.has_turn():
		return false
	remove(u)                                    # 不允许重复入队
	var q := _queue_of(u.side)
	q.insert(0, u)
	_refresh_preview()
	return true


## 这一方队列里还有人吗（空 = 自动跳过它的回合）
func has_side(side: int) -> bool:
	_purge_dead()
	return not _queue_of(side).is_empty()


## 兜底不变式：队列里不该有死人（阵亡时已经移出）。万一漏了一条路径，这里补一次。
func _purge_dead() -> void:
	_purge_arr(p_queue)
	_purge_arr(e_queue)


static func _purge_arr(arr: Array[Unit]) -> void:
	for i in range(arr.size() - 1, -1, -1):
		if not arr[i].is_alive():
			arr.remove_at(i)


# ══════════════════════════════════════════════════════════════════════════════
# 取用
# ══════════════════════════════════════════════════════════════════════════════
## 下一个该行动的单位（**幂等，不消费**）= 队头；自己这方空了就自动换对面
func current() -> Unit:
	_purge_dead()
	var u := _front(turn_side)
	if u != null:
		return u
	var other := 1 - turn_side
	if _front(other) == null:
		return null
	turn_side = other                            # 队空 -> 跳过这一方的回合
	return _front(other)


## 队头（空队列 = null）
func _front(side: int) -> Unit:
	var q := _queue_of(side)
	return q[0] if not q.is_empty() else null


func _queue_of(side: int) -> Array[Unit]:
	return p_queue if side == UnitData.Side.PLAYER else e_queue


## 结束一个单位的回合 -> 把它【出队再入队尾】，然后换边。
## who 缺省 = 当前队头；显式传入更稳（复活会把别人压到队头，那时队头已经不是他了）。
##
## 【换边规则】（第 99 轮）：
##   · `MODE_ALTERNATE`（缺省）：行动完就换边 —— 既有行为，一字未改
##   · `MODE_BY_SIDE`：**本边还有这一圈没行动过的人，就不换边**
##     （一边所有角色都行动完，才轮到另一边）。判据 = 标记"他动过了"，然后问
##     "本边队列里还有谁没动过"。用标记而不是数人头：阵亡/复活中途改队列长度也不会算错。
##     本圈结束（两边的队首都动过）时清空标记，下一圈重新开始。
func advance(who: Unit = null) -> Unit:
	var u: Unit = who if who != null else _front(turn_side)
	if u != null:
		var q := _queue_of(u.side)
		q.erase(u)
		if u.is_alive() and u.has_turn():
			q.append(u)                          # 出队入队尾 -> 下一圈还会轮到他
	if mode == MODE_BY_SIDE:
		if u != null:
			_acted[u] = true
			if _side_has_unacted(u.side):
				# 本边还有人没行动 -> 不换边，继续本边下一位
				# （如果本边队首是"已行动过"的人，说明这一圈本边走完了 →
				#   清空标记，让下一圈从队首重新开始）
				if _acted.has(_front(u.side)):
					_acted.clear()
				_refresh_preview()
				return current()
		_acted.clear()
	turn_side = 1 - turn_side
	_refresh_preview()
	return current()


## 本边队列里还有没有人这一圈没行动过
func _side_has_unacted(side: int) -> bool:
	var q := _queue_of(side)
	_purge_dead()
	for x in q:
		if not _acted.has(x):
			return true
	return false


## 预测接下来 n 个行动者（含当前，给底部队列条用）
## 完全按 advance() 的规则在副本上走一遍：出队入队尾 + 队空自动跳过。
func preview(n: int) -> Array[Unit]:
	var out: Array[Unit] = []
	var pq: Array[Unit] = p_queue.duplicate()
	var eq: Array[Unit] = e_queue.duplicate()
	_purge_arr(pq)
	_purge_arr(eq)
	var side := turn_side
	var guard := 0
	var acted := _acted.duplicate()          # 预测不污染真实状态
	while out.size() < n and guard < n * 4 + 32:
		guard += 1
		if pq.is_empty() and eq.is_empty():
			break
		if _size_of(side, pq, eq) == 0:
			side = 1 - side
			if _size_of(side, pq, eq) == 0:
				break
			continue
		var q: Array[Unit] = pq if side == UnitData.Side.PLAYER else eq
		var u: Unit = q[0]
		q.remove_at(0)
		q.append(u)                              # 出队入队尾（和 advance 一致）
		if u.is_alive():
			out.append(u)
		# 换边规则必须和 advance() 一致，否则底部队列条会骗人（第 99 轮）
		if mode == MODE_BY_SIDE:
			acted[u] = true
			var rest := false
			for x in q:
				if not acted.has(x):
					rest = true
					break
			if rest:
				if acted.has(q[0]):
					acted.clear()
				continue                         # 本边还有人没行动 -> 不换边
			acted.clear()
		side = 1 - side
	return out


static func _size_of(side: int, pq: Array[Unit], eq: Array[Unit]) -> int:
	return pq.size() if side == UnitData.Side.PLAYER else eq.size()


func _refresh_preview() -> void:
	order = preview(12)
	index = 0


func current_side() -> int:
	var u := current()
	return -1 if u == null else u.side


func is_round_over() -> bool:
	return current() == null


func all_units() -> Array[Unit]:
	return order


## 当前是否处于连击模式
func is_last_stand() -> bool:
	return last_stand


func _shuffle(arr: Array[Unit]) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j: int = rng.next_int(i + 1)
		var tmp: Unit = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


## 给 UI 用的可读输出（左边 = 队头，下一个行动）
func dump() -> String:
	var parts: Array[String] = []
	parts.append("P[" + ", ".join(p_queue.map(func(u: Unit) -> String: return u.name)) + "]")
	parts.append("E[" + ", ".join(e_queue.map(func(u: Unit) -> String: return u.name)) + "]")
	parts.append("next=" + ("P" if turn_side == UnitData.Side.PLAYER else "E"))
	if last_stand:
		parts.append("连击=" + (lone.name if lone != null else "?"))
	return " ".join(parts)


## 队列里不允许出现"同一方连续两回合"（自检用）
func alternation_ok() -> bool:
	var prev := -1
	for u in preview(24):
		if u.side == prev:
			return false
		prev = u.side
	return true
