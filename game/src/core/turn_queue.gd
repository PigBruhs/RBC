# ══════════════════════════════════════════════════════════════════════════════
# 回合队列（用户口径：**开战时各排一条固定的循环队列，执行时两边交替取**）
#
#   · 战斗开始时，双方各自【一次性随机排好】自己内部的循环顺序，
#     之后一直按这个顺序循环，**不是每回合重新随机**。
#   · 执行时：从玩家队列取一个 -> 从敌方队列取一个 -> 再从玩家队列取一个 …
#     两条队列各自独立地往前走，走到底就从队头重新开始（循环）。
#   · 人少的一方先循环：2 人 vs 3 人时，P 队列第 3 次会回到第一个人。
#   · 任何情况下都不会出现"同一方连续两回合"。
#
# ── 指针语义（很重要，UI 直接依赖）──────────────────────────────────────────
#   turn_side : 下一个该行动的是哪一方（0=玩家 / 1=敌方）
#   p_idx/e_idx : 各自"下一个待取"的下标（循环取模）
#   current() : **只看不取**（幂等）—— 返回下一个该行动的单位
#   advance() : 真正取走当前单位，并把 turn_side 翻到对面
#   所以 preview()/UI 里 out[0] 永远 = current()，不需要在外部手动补当前单位。
#
# 最后一人连击（用户规则）：一方只剩 1 人时，孤军 → 对面每人各一次 → 孤军 …
#   连击一旦进入就保持（对面复活也不退出）。
# ══════════════════════════════════════════════════════════════════════════════
class_name TurnQueue
extends RefCounted

var p_queue: Array[Unit] = []        # 玩家方循环队列（开战时排一次）
var e_queue: Array[Unit] = []        # 敌方循环队列
var p_idx: int = 0                   # 各自走到哪了（循环取模）
var e_idx: int = 0
var turn_side: int = 0               # 下一个该行动的阵营
var order: Array[Unit] = []          # 给 UI 看：接下来 N 个行动者（预测，含当前）
var index: int = 0                   # order 里的位置（仅供 UI/测试）
var round_no: int = 0
var rng: RngService
var last_stand: bool = false
var lone: Unit = null


func _init(rng_service: RngService) -> void:
	rng = rng_service


## 开战/重排：双方各自随机排好循环队列，重置指针
func rebuild(units: Array[Unit]) -> int:
	var players: Array[Unit] = []
	var enemies: Array[Unit] = []
	for u in units:
		# 假人不行动、不进队列（用户要求）
		if u.is_alive() and u.has_turn():
			if u.side == UnitData.Side.PLAYER:
				players.append(u)
			else:
				enemies.append(u)
	_shuffle(players)
	_shuffle(enemies)
	p_queue = players
	e_queue = enemies
	p_idx = 0
	e_idx = 0
	turn_side = UnitData.Side.PLAYER
	round_no += 1
	# 连击状态不在这里清（常规重排不该把连击抹掉）。
	# 但如果连击开着，重排后必须恢复成"孤军 + 对面"的结构，
	# 否则一次普通 rebuild 就会把连击结构冲掉（UI 与规则都会错）。
	if last_stand and lone != null and lone.is_alive():
		_rebuild_last_stand(lone, _others_of(lone))
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
	p_idx = 0
	e_idx = 0
	round_no += 1
	_refresh_preview()


## 某个单位之外的所有存活单位
func _others_of(u: Unit) -> Array[Unit]:
	var out: Array[Unit] = []
	for x in p_queue + e_queue:
		if x != u and x.is_alive():
			out.append(x)
	return out


# ══════════════════════════════════════════════════════════════════════════════
# 取用
# ══════════════════════════════════════════════════════════════════════════════
## 下一个该行动的单位（**幂等，不消费**）
func current() -> Unit:
	for guard in 64:
		var u := _peek_side(turn_side)
		if u != null:
			return u
		# 这一方没活人了 -> 换另一边
		var other := 1 - turn_side
		if _peek_side(other) == null:
			return null
		turn_side = other
	return null


## 看一眼某一方的下一个活人（会把该方下标向前跳过死者，停在活人处）
func _peek_side(side: int) -> Unit:
	var q: Array[Unit] = p_queue if side == UnitData.Side.PLAYER else e_queue
	if q.is_empty():
		return null
	var i: int = p_idx if side == UnitData.Side.PLAYER else e_idx
	for guard in q.size():
		var u: Unit = q[i % q.size()]
		if u.is_alive():
			_set_idx(side, i % q.size())
			return u
		i += 1
	return null


func _set_idx(side: int, v: int) -> void:
	if side == UnitData.Side.PLAYER:
		p_idx = v
	else:
		e_idx = v


func _idx_of(side: int) -> int:
	return p_idx if side == UnitData.Side.PLAYER else e_idx


func _queue_of(side: int) -> Array[Unit]:
	return p_queue if side == UnitData.Side.PLAYER else e_queue


func _has_alive(q: Array[Unit]) -> bool:
	for u in q:
		if u.is_alive():
			return true
	return false


## 结束当前单位的回合 -> 取走它，换边
func advance() -> Unit:
	var cur := current()
	if cur != null:
		var side := turn_side
		var q := _queue_of(side)
		_set_idx(side, (_idx_of(side) + 1) % q.size())
	turn_side = 1 - turn_side
	_refresh_preview()
	return current()


## 预测接下来 n 个行动者（含当前，给底部队列条用）
func preview(n: int) -> Array[Unit]:
	var out: Array[Unit] = []
	if p_queue.is_empty() and e_queue.is_empty():
		return out
	var p_alive := _has_alive(p_queue)
	var e_alive := _has_alive(e_queue)
	if not p_alive and not e_alive:
		return out
	var pi := p_idx
	var ei := e_idx
	var side := turn_side
	# 落到"有活人的那一方"
	if not (p_alive if side == UnitData.Side.PLAYER else e_alive):
		side = 1 - side
	if not (p_alive if side == UnitData.Side.PLAYER else e_alive):
		side = UnitData.Side.PLAYER if p_alive else UnitData.Side.ENEMY
	var guard := 0
	while out.size() < n and guard < n * 4 + 16:
		guard += 1
		var q: Array[Unit] = p_queue if side == UnitData.Side.PLAYER else e_queue
		var idx: int = pi if side == UnitData.Side.PLAYER else ei
		var u: Unit = q[idx % q.size()]
		if side == UnitData.Side.PLAYER:
			pi = (pi + 1) % q.size()
		else:
			ei = (ei + 1) % q.size()
		# 只有真的排进去一个人才换边（跳过死人时不能换边，
		# 否则 UI 里会出现"同一方连着两个回合"——用户报过的显示 bug）
		if u.is_alive():
			out.append(u)
			if p_alive and e_alive:
				side = 1 - side
	return out


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


## 给 UI 用的可读输出
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
