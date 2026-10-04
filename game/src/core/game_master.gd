# ══════════════════════════════════════════════════════════════════════════════
# GameMaster（游戏主持）—— v2：**没有自己的隐藏回合了**
#
# 用户修正：
#   · 旧的"每个角色回合结束后 GM 走一步"模型作废。
#   · 现在 GM 在【任意回合】都可以行动，分两类：
#       ① 环境型（ambient）：随时响应场上事件，**不暂停、不打断**当前回合。
#          目前是「哨兵」——一条 FIFO 队列记下进入射界的角色/投掷物，
#          每 150ms 只放出一支箭打队头，打完把队头轮转到队尾（用户口径：不并行、不饿死）。
#       ② 调度型（scheduled）：在【回合边界】暂停回合并执行，执行完继续回合。
#          目前是「轨道空爆打击」——到点后在下一个角色回合开始前落下。
#       ③ 角色被动：目前是杰拉尔德的「箭矢弹反」——箭矢命中时先扣下伤害，
#          让玩家打一次 QTE，全对就把箭弹回射手（散步落点也在这里算）。
#
# GM 还负责登记"属于谁的状态"（例如阿莱特的哨兵），因为这些状态不属于当下那一回合。
# ══════════════════════════════════════════════════════════════════════════════
class_name GameMaster
extends RefCounted

## 一条待释放的延时效果（调度型）
class Pending extends RefCounted:
	var skill_id: String = ""
	var caster_name: String = ""
	var caster_side: int = 0
	var caster_power: int = 0
	var center: Vector2i = Vector2i.ZERO
	var float_pos: Vector2 = Vector2.ZERO
	var ticks: int = -1                  # 已经过了几个"回合边界"
	var delay: int = 0
	var pylon: Node3D = null             # 这一发自己的紫色光柱（允许多个在途打击）
	## 落地后与投出者【解耦】（用户口径第 87 轮：枪榴弹落地就是场上的一个物件）：
	## 解耦之后，投出者阵亡也不会把它取消掉 —— 照常到点爆炸。
	var decoupled: bool = false
	## 落地模型（枪榴弹的弹体）：爆炸时按这个引用回收，
	## 不靠"格子 -> 模型"的字典（同格两发会互相顶掉）。
	var model: Node3D = null


## 哨兵状态（环境型）：登记在 GM 上，因为它要跨回合存活
class Sentry extends RefCounted:
	var owner: Unit = null
	var owner_name: String = ""
	var side: int = 0
	var rng_min: int = 1
	var rng_max: int = 8
	var cost_paid: bool = false
	var fired_units: Dictionary = {}     # 单位名 -> true（本次移动已入队过）
	var queue: Array = []                # FIFO 目标队列（Target），队头先打
	var cooldown: float = 0.0            # 距离下一支箭还差多少秒

	## 浮点射界：欧氏距离落在 [rng_min, rng_max] 内
	func in_range(center: Vector2, p: Vector2) -> bool:
		var d := center.distance_to(p)
		return d >= float(rng_min) - 0.0001 and d <= float(rng_max) + 0.0001


## 哨兵队列里的一个目标：角色或投掷物。
## 位置是【轮到它的时候现查】的 —— 用户口径：每次瞄准其被瞄准时的位置，
## 所以快速飞行的炮弹可能已经不在原来的点上（打空是正常的）。
class Target extends RefCounted:
	var unit: Unit = null
	var proj: Projectile = null
	var label: String = ""
	var wait: float = SENTRY_TRIGGER_DELAY       # 进入射界后的开火延迟（第 92 轮：800ms）
	var last_pos := Vector2.ZERO             # 上一次被射击时的位置（判定"静止目标"）

	func alive() -> bool:
		if proj != null:
			return proj.alive
		if unit != null:
			return unit.is_alive()
		return false

	## 目标当前位置（浮点格坐标）。
	##
	## ⚠️ 这里**刻意**读 `unit.visual.position`（core → view 的依赖），不要"顺手清理"成 unit.cell：
	##   逻辑格子 `unit.cell` 在移动发起的那一刻就瞬移到终点了，只有视觉位置才知道角色
	##   **此刻**走到哪一格之间 —— 而哨兵的射界判定是**连续的**（用户口径第 92 轮：
	##   格与格之间也算在界内，直升机边走边打时必须能被锁定），所以这里必须问 view。
	##   本项目 core → view 的依赖**总共只有两处**，这是其中之一（另一处是
	##   core/grid_math.gd 的 `unit_pos()`，给"从当前位置出膛"的弹道用）——
	##   两处口径必须一致：都读 visual.position，取不到才退回格中心。
	func pos() -> Vector2:
		if proj != null:
			return proj.pos()
		if unit == null:
			return Vector2.ZERO
		# 行走中的角色用视觉位置：格与格之间也算在射界里
		if unit.visual != null:
			return Vector2(unit.visual.position.x, unit.visual.position.z)
		return Vector2(float(unit.cell.x) + 0.5, float(unit.cell.y) + 0.5)

	## 该瞄多高（高度轴）。用户口径第 83 轮：悬空单位（直升机）要瞄它的身体中心，
	## 弹道物则瞄它当前飞行高度 —— 否则哨兵箭永远从直升机下面穿过去。
	func aim_y() -> float:
		if proj != null:
			return proj.height()
		if unit != null:
			return Targeting.aim_height(unit)
		return 0.55



## 一次哨兵触发（view 拿到后负责真的把箭射出去）
class Shot extends RefCounted:
	var is_projectile: bool = false      # 目标是弹道物（哨兵要精确瞄）
	var sentry: Sentry
	var at: Vector2 = Vector2.ZERO        # 触发点（浮点）
	var y: float = 0.55                   # 触发点的高度（悬空单位/弹道物都要按高度瞄）
	var target_name: String = ""
	var reason: String = ""


## 弹道物理只负责"打没打中"，后果交给这里处理（用户口径）。
## battle_scene 注册这一个回调即可，事件名见 ProjectileField.EV_*。
var on_projectile_event: Callable = Callable()


## 弹道物场的上报入口
func report_projectile(event: String, p: Projectile, extra = null) -> void:
	if on_projectile_event.is_valid():
		on_projectile_event.call(event, p, extra)


var pending: Array[Pending] = []
var sentries: Array[Sentry] = []

## 回合边界时钟 + 复活计时（P4a 拆出，见 core/game_clock.gd）。
## 真实状态在 clock 里；下面的 `turn_count` / `revive_at` 都是**转发属性**，
## 保证 `gm.turn_count`（battle_scene）、`gm.revive_at[u] = ...`（probe_arena）照旧可用。
var clock := GameClock.new()

## 走了多少个回合边界（调试用）。真实值在 clock.turn_count —— 只读转发。
var turn_count: int:
	get:
		return clock.turn_count


# ══════════════════════════════════════════════════════════════════════════════
# 调度型：延时效果
# ══════════════════════════════════════════════════════════════════════════════
func schedule(skill_id: String, caster: Unit, center: Vector2i, float_pos: Vector2,
		delay: int) -> void:
	var p := Pending.new()
	p.skill_id = skill_id
	p.caster_name = caster.name
	p.caster_side = caster.side
	p.caster_power = caster.power_cur
	p.center = center
	p.float_pos = float_pos
	p.ticks = -1
	p.delay = delay
	pending.append(p)


## 回合边界（下一个角色回合开始前）调用：计数并返回到点的效果。
## 调用方必须 await 演出结束后再继续回合 —— 这就是"暂停回合"。
func dispatch_turn_boundary() -> Array[Pending]:
	clock.advance()          # 时钟真实状态在 GameClock；本函数只负责"到点的效果"
	var due: Array[Pending] = []
	for p in pending:
		p.ticks += 1
		if p.ticks >= p.delay:
			due.append(p)
	for p in due:
		pending.erase(p)
	return due


func has_pending(skill_id: String) -> bool:
	for p in pending:
		if p.skill_id == skill_id:
			return true
	return false


func pending_desc() -> String:
	var parts: Array[String] = []
	for p in pending:
		parts.append("%s@(%d,%d) 计时 %d/%d" % [
			p.skill_id, p.center.x, p.center.y, p.ticks, p.delay])
	return "无" if parts.is_empty() else " ｜ ".join(parts)


# ══════════════════════════════════════════════════════════════════════════════
# 环境型：哨兵
# ══════════════════════════════════════════════════════════════════════════════
func add_sentry(u: Unit, rng_min: int, rng_max: int) -> Sentry:
	clear_sentry_for(u)
	var s := Sentry.new()
	s.owner = u
	s.owner_name = u.name
	s.side = u.side
	s.rng_min = rng_min
	s.rng_max = rng_max
	s.cost_paid = true
	sentries.append(s)
	return s


## 角色阵亡：把和他有关的被动机会记录一并清掉（用户口径：阵亡清除所有状态）
func forget_passives(u: Unit) -> void:
	if u == null:
		return
	for k in passive_used.keys():
		if String(k).begins_with("%s:" % u.name):
			passive_used.erase(k)


## 角色阵亡：取消他还没落下的技能（例：轨道空爆的标记）
## 例外：**已经落地并解耦的东西不算他的技能**（枪榴弹落地后就是场上的物件），
## 投出者阵亡也照常爆炸 —— 用户口径第 87 轮。
func cancel_pending_for(caster_name: String) -> void:
	if caster_name == "":
		return
	for i in range(pending.size() - 1, -1, -1):
		var p = pending[i]
		if bool(p.decoupled):
			continue
		if String(p.caster_name) == caster_name:
			pending.remove_at(i)

## 场上已经落地、跟投出者解耦的东西（自检/日志用）
func decoupled_count() -> int:
	var n := 0
	for p in pending:
		if bool(p.decoupled):
			n += 1
	return n


# ══════════════════════════════════════════════════════════════════════════════
# 阵亡顺序（圣萨尼要用）：GM 记录谁先死，萨尼铁塔的回合开始时取"最后一个阵亡的队友"
# ══════════════════════════════════════════════════════════════════════════════
var death_order: Array[String] = []


func note_death(u: Unit) -> void:
	if u == null:
		return
	death_order.append(u.name)
	if death_order.size() > 32:
		death_order = death_order.slice(death_order.size() - 32)


## 最后一个阵亡的、可操作的队友（不含公主/国王/假人/沙盒）
func last_dead_teammate(side: int, units: Array[Unit]) -> Unit:
	var by_name: Dictionary = {}
	for u in units:
		by_name[u.name] = u
	for i in range(death_order.size() - 1, -1, -1):
		var nm: String = death_order[i]
		if not by_name.has(nm):
			continue
		var u2: Unit = by_name[nm]
		if u2.side == side and u2.has_turn() and not u2.is_alive() and not u2.is_king:
			return u2
	return null


## 手榴弹排程：delay 个回合边界后到期（时钟由 GM 负责）
## 用户口径第 87 轮：**落地后就和投出者解耦** —— 所以登记时直接打上 decoupled，
## 投出者阵亡（cancel_pending_for）也不会把它清掉。返回这条 Pending，
## 方便 view 把落地的弹体模型挂在它身上（爆炸时按引用回收）。
func schedule_grenade(center: Vector2i, caster_name: String, caster_side: int,
		delay: int, skill_id: String = "grenade") -> Pending:
	var p := Pending.new()
	p.skill_id = skill_id
	p.caster_name = caster_name
	p.caster_side = caster_side
	p.center = center
	p.ticks = 0
	p.delay = delay
	p.decoupled = true
	pending.append(p)
	return p


## 清除某个角色的哨兵（阿莱特的下一回合开始时调用）
func clear_sentry_for(u: Unit) -> void:
	if u == null:
		return
	for i in range(sentries.size() - 1, -1, -1):
		if sentries[i].owner == u or sentries[i].owner_name == u.name:
			sentries.remove_at(i)


func clear_all_sentries() -> void:
	sentries.clear()


func has_sentry(u: Unit) -> bool:
	for s in sentries:
		if s.owner == u or s.owner_name == u.name:
			return true
	return false


func sentry_center(s: Sentry) -> Vector2:
	if s.owner == null:
		return Vector2.ZERO
	return Vector2(float(s.owner.cell.x) + 0.5, float(s.owner.cell.y) + 0.5)


func sentry_desc() -> String:
	var parts: Array[String] = []
	for s in sentries:
		var c := sentry_center(s)
		parts.append("%s@(%.1f,%.1f) 射界 %d~%d" % [
			s.owner_name, c.x, c.y, s.rng_min, s.rng_max])
	return "无" if parts.is_empty() else " ｜ ".join(parts)


## 某个单位开始一次移动：清掉"这次移动已经入队过"的闩
func on_move_begin(u: Unit) -> void:
	for s in sentries:
		s.fired_units.erase(u.name)


## 角色移动中的一次采样。进入射界就把它【加入队尾】，返回是否入队。
## 规则（用户口径）：敌对角色从射界外进入射界内、或已在射界内继续移动，都会触发一次；
## 一次移动最多入队一次（fired_units 闩），入队之后由队列按 150ms 节奏反复瞄准它。
func check_unit(u: Unit, pos: Vector2) -> bool:
	if u == null or not u.is_alive():
		return false
	var any := false
	for s in sentries:
		if s.owner == null or not s.owner.is_alive():
			continue
		if u.side == s.side:
			continue                       # 只有敌对角色会触发哨兵
		if s.fired_units.has(u.name):
			continue                       # 一次移动最多入队一次
		if not s.in_range(sentry_center(s), pos):
			continue
		s.fired_units[u.name] = true
		var t := Target.new()
		t.unit = u
		t.label = u.name
		s.queue.append(t)
		any = true
	return any


## 弹道物的一次采样：能惊动哨兵的、且此刻在射界内的，加入队尾（返回是否入队）。
## 用户口径：不分敌我（队友的炮弹/召唤球一样拦）；箭矢自身 sentry_trigger = false，不会被拦。
func check_projectile(p: Projectile) -> bool:
	if p == null or not p.alive:
		return false
	if not Ballistics.triggers_sentry(p):
		return false                      # 箭矢不会被拦（否则箭生箭会炸）
	var any := false
	for s in sentries:
		if s.owner == null or not s.owner.is_alive():
			continue
		if not s.in_range(sentry_center(s), p.pos()):
			continue
		if _queued(s, p.id):
			continue                      # 已经在队列里了，不重复入队
		var t := Target.new()
		t.proj = p
		t.label = _proj_label(p.kind)
		s.queue.append(t)
		any = true
	return any


## 哨兵日志里怎么称呼这一类弹道物（第 83 轮：火箭也算炮弹类，会惊动哨兵）
static func _proj_label(kind: String) -> String:
	match kind:
		Projectile.KIND_SHELL:
			return "炮弹"
		Projectile.KIND_ROCKET:
			return "火箭"
		Projectile.KIND_GRENADE:
			return "枪榴弹"
	return "召唤球"


## 这一发是否已经在该哨兵的队列里
func _queued(s: Sentry, id: int) -> bool:
	for t in s.queue:
		if t.proj != null and t.proj.id == id:
			return true
	return false


## 弹道物被移除时，把它的队列条目一起清掉（否则队列里会堆满死元素）
func forget_projectile(id: int) -> void:
	for s in sentries:
		for i in range(s.queue.size() - 1, -1, -1):
			var t: Target = s.queue[i]
			if t.proj != null and t.proj.id == id:
				s.queue.remove_at(i)


## 每两支箭之间至少间隔 65ms（用户口径第 93 轮：100 -> 65）
const SENTRY_FIRE_INTERVAL := 0.065
## 进入射界后先等这么久才射第一支（用户口径：0 -> 500ms -> 800ms -> **第 93 轮 1 秒**）
const SENTRY_TRIGGER_DELAY := 1.0


## 哨兵队列的每帧推进（view 每帧调用）。返回本次要发射的箭：每个哨兵最多 1 支。
##
## 用户口径的算法：
##   · 冷却没到 -> 什么都不做
##   · 冷却到了 -> 看队头：已经消失 / 已经飞出射界 -> 直接移出，接着看下一个队头
##   · 队头合法 -> 对它【此时的位置】射一支箭，然后把它移到队尾（不饿死，从前向后轮流拦）
##   · 有新的触发物进入射界 -> 加入队尾
func sentry_tick(dt: float) -> Array[Shot]:
	var out: Array[Shot] = []
	for s in sentries:
		if s.owner == null or not s.owner.is_alive():
			s.queue.clear()
			s.cooldown = 0.0
			continue
		s.cooldown = maxf(0.0, s.cooldown - dt)
		for t0 in s.queue:
			((t0 as Target).wait) = maxf(0.0, (t0 as Target).wait - dt)
		if s.cooldown > 0.0:
			continue
		while not s.queue.is_empty():
			var t: Target = s.queue[0]
			if not t.alive():
				s.queue.remove_at(0)      # 已经没了
				continue
			# 用户口径①：进入射界后先等 500ms 再射第一支
			if t.wait > 0.0:
				break
			# 用户口径②：角色一旦停下来就不再被哨兵追击（弹道物不算，它们一直在动）
			if t.unit != null and t.last_pos.distance_to(t.pos()) < 0.05:
				s.queue.remove_at(0)
				continue
			var at := t.pos()
			var at_y := t.aim_y()
			if not s.in_range(sentry_center(s), at):
				s.queue.remove_at(0)      # 出界就剔除，保持队列合法
				continue
			var sh := Shot.new()
			sh.sentry = s
			sh.at = at
			sh.y = at_y
			sh.is_projectile = t.proj != null   # 拦弹道物时必须精确瞄准（否则拦不住）
			sh.target_name = t.label
			sh.reason = "%s进入射界" % t.label
			out.append(sh)
			t.last_pos = at
			t.wait = 0.0                    # 轮转回队尾不再重新等（间隔由 SENTRY_FIRE_INTERVAL 管）
			s.queue.remove_at(0)
			s.queue.append(t)             # 轮转到队尾 -> 下一轮还能再拦它
			s.cooldown = SENTRY_FIRE_INTERVAL
			break
	return out


## 所有哨兵队列里待处理的目标总数（日志 / 测试用）
func sentry_queue_size() -> int:
	var n := 0
	for s in sentries:
		n += s.queue.size()
	return n


# ══════════════════════════════════════════════════════════════════════════════
# 角色被动（环境型）：目前只有杰拉尔德的「箭矢弹反」
#
# 用户口径：**触发与执行都归 GameMaster** —— 谁在什么时候能弹反、箭会被弹到哪里，
# 这里是唯一的裁判；view 只负责演出（暂停全局、按键提示、把箭真的生成出来）。
# ══════════════════════════════════════════════════════════════════════════════
var passive_used: Dictionary = {}         # "单位名:被动id" -> true（本回合机会已用掉）

# AI 开关（ai_enabled / ai_autoplay_player）已于 P4 迁出本类 —— 见
# battle_scene 的 `var ai_enabled` / `var ai_autoplay_player`（驱动层才是它的家）
# 与 `t_ai_enabled()` / `t_set_ai_enabled()` 测试门面。GameMaster 不再知道 AI。


# ══════════════════════════════════════════════════════════════════════════════
# Reaper（Boss-3）：三循环状态 + 6 格范围被动
#
# 用户口径：「Reaper 的回合按三个循环：召唤、横扫与竖切」；
#           「6 格内每回合造成 20 点护甲伤害和 10 点力量伤害（GM 负责）」。
#
# **为什么循环状态放 GM**：它是"跨回合的调度状态"，不属于角色自身属性；
# GM 已经是"不属于任何角色的场上状态"的持有者（pending / sentries / death_order）。
# 放这里也不会被 view 遮挡 —— view 只通过 `reaper_step_for()` 读。
#
# **为什么被动在 GM**：用户明确"GM 负责"，且它是**环境性**伤害（每个回合边界执行，
# 与 Reaper 自己的行动回合无关）→ 由 `_gm_step` 在回合边界调用 `reaper_passive_tick()`。
# ══════════════════════════════════════════════════════════════════════════════
const REAPER_NAME := "Reaper"

## 单位名 -> 当前循环步（Reaper.Step）。第一次轮到它时从"召唤"开始。
var reaper_cycle: Dictionary = {}


## 这是不是 Reaper（用 base_name 比，兼容 "Reaper (E)" 这种带阵营后缀的实例名）
static func is_reaper(u: Unit) -> bool:
	return u != null and Unit.base_name(u.name) == REAPER_NAME


## 取当前循环步（不推进）。没登记过 = 从召唤开始。
func reaper_step_for(u: Unit) -> int:
	return int(reaper_cycle.get(u.name, Reaper.Step.SUMMON))


## 推进到下一步并返回**推进前**的那一步（"这一回合该做哪件事"）。
func reaper_advance_cycle(u: Unit) -> int:
	var cur := reaper_step_for(u)
	reaper_cycle[u.name] = Reaper.next_step(cur)
	return cur


## 6 格范围被动：**每个回合边界**结算一次（由 _gm_step 调）。
## 返回受影响的单位（供日志/测试）。
## 口径见 core/reaper.gd 的 `passive_targets`：中心距离 ≤ 6、不把 body_r=3 算进去、**不分敌我**。
func reaper_passive_tick(units: Array[Unit]) -> Array[Unit]:
	var out: Array[Unit] = []
	for r in units:
		if not is_reaper(r) or not r.is_alive():
			continue
		for u in Reaper.passive_targets(r, units):
			u.take_armor_damage(Reaper.PASSIVE_ARMOR_MILLI)
			# 10 点力量伤害 = **魔法伤害**（没有物理伤害来源，不走物抗/闪避）。
			# 10 点力量 = **魔法伤害**（只吃魔抗、无视护甲）。⚠ 第 3 个参数是**点**不是千分比，
			# 所以是 PASSIVE_POWER_MILLI / 1000；rng 只占位（魔法伤害是确定性的）。
			Damage.magic_hit(r, u, Reaper.PASSIVE_POWER_MILLI / 1000, null)
			out.append(u)
	return out


## 轮到某个角色【自己的回合】了：把他身上 per = "own_turn" 的被动重新置 1。
## 用户口径（杰拉尔德弹反）：只有他自己的回合开始才解锁，弹反一次立刻置 0，
## 所以别人一个回合里射十支箭也只有第一支进 QTE。
func on_turn_begin(u: Unit = null) -> void:
	if u == null:
		passive_used.clear()
		return
	for id in Passives.for_unit(u):
		if String(Passives.def(id).get("per", "")) == "own_turn":
			passive_used.erase("%s:%s" % [u.name, id])


## 这一发箭命中 victim 时，victim 身上有没有可以接的被动？
## 返回 true = 已经受理：view 必须暂停全局并进入 QTE，**先不要结算伤害**。
func claim_arrow_deflect(victim: Unit) -> bool:
	if victim == null or not victim.is_alive():
		return false
	for id in Passives.for_unit(victim):
		var d: Dictionary = Passives.def(id)
		if not bool(d.get("reflect", false)):
			continue
		var key := "%s:%s" % [victim.name, id]
		if passive_used.has(key):
			return false                  # 本回合的机会已经用掉了
		passive_used[key] = true
		return true
	return false


## 本回合的弹反机会用掉了吗（日志 / 测试用）
func deflect_used(victim: Unit) -> bool:
	return victim != null and passive_used.has("%s:arrow_deflect" % victim.name)


## 弹反落点：射手的格子 + 按两者距离算出来的散步（用户口径：落点由散步函数决定）
func reflect_landing(victim: Unit, shooter: Unit, rng: RngService) -> Vector2:
	if victim == null or shooter == null:
		return Vector2.ZERO
	var from := Vector2(float(victim.cell.x) + 0.5, float(victim.cell.y) + 0.5)
	var to := Vector2(float(shooter.cell.x) + 0.5, float(shooter.cell.y) + 0.5)
	return Spread.reflect_scatter(to, from.distance_to(to), Ordnance.ARROW_TILES_PER_SEC, rng)


# ══════════════════════════════════════════════════════════════════════════════
# 英雄重生（用户口径：三个英雄可以无限满血满护甲重生，每次要等 10 个回合）
#
# ★ 实现已搬到 core/game_clock.gd（P4a）；下面全是**转发**，语义逐字不变。
#   外部照旧写 `gm.schedule_hero_revive(...)` / `GameMaster.HERO_REVIVE_TURNS`。
# ══════════════════════════════════════════════════════════════════════════════
## 真值在 GameClock；转发是为了不让外部（playtest / run.gd / level.gd）的
## `GameMaster.HERO_REVIVE_TURNS` 断掉。
const HERO_REVIVE_TURNS := GameClock.HERO_REVIVE_TURNS

## Unit -> 到期的 turn_count。**转发属性**：返回的是 clock 里那个 Dictionary 本身，
## 所以 probe_arena 的 `gm.revive_at[u] = gm.turn_count`（下标写）照旧生效。
var revive_at: Dictionary:
	get:
		return clock.revive_at


func schedule_hero_revive(u: Unit, turns: int = -1) -> void:
	clock.schedule_hero_revive(u, turns)


## 到点该复活的英雄（view 在每个回合边界之后调用）
func due_revives() -> Array[Unit]:
	return clock.due_revives()


## 还要等几个回合（日志 / UI 用）；没排过复活返回 -1
func revive_countdown(u: Unit) -> int:
	return clock.revive_countdown(u)
