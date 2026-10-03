# ══════════════════════════════════════════════════════════════════════════════
# 弹药工厂 + 发射单
#
# 用户口径：
#   · 弹道物的【固有属性只决定物理弹道】，不含伤害。
#   · 伤害取决于发射者，落点由发射者给定 —— 这些放进"发射单"(Shot)。
#   · 以后加子弹/飞刀只需要在这里加一个 make_xxx，敌方 AI 也只构造发射单。
#
# 为什么要工厂：
#   以前 battle_scene 里三处手工 new Projectile 并逐个赋值字段，改一处忘一处，
#   已经出过两次事故（召唤球漏了 hit_tags / sentry_trigger，导致"哨兵不拦截"）。
#   现在"一发合法的炮弹需要哪些字段"只写一遍，游戏本体和测试走同一条路径。
# ══════════════════════════════════════════════════════════════════════════════
class_name Ordnance
extends RefCounted

# ── 弹道常量（速度和碰撞都只在这里定义）──
const SHELL_TILES_PER_SEC := 3.0     # 炮弹速度
## ── 破片（箭矢类）──────────────────────────────────────────────────────────
## 用户口径：
##   · 不受重力影响，全程维持在离地 0.5 格
##   · 速度 4 格/秒，飞到 20 格时模型消失
##   · 伤害按"离生成点的距离"衰减：0 格 25 甲/25 力 → 3 格 12/12 → 16 格 0（仍可命中）→ 20 格消失
const FRAGMENT_TILES_PER_SEC := 4.0
const FRAGMENT_MAX_DIST := 20.0
const FRAGMENT_HEIGHT := 0.5
const FRAGMENT_R := 0.09             # 碰撞体积和箭矢差不多（箭矢 0.075）

## ── 子弹（萨尼铁塔，箭矢类）────────────────────────────────────────────────
## 用户口径：12 格/秒、无重力、全程离地 0.5 格、32 格模型消失；
## 伤害阶梯衰减 0-12 格 100% / 12-16 格 60% / 16-24 格 20% / >24 格无伤害（仍可命中）。
const BULLET_TILES_PER_SEC := 12.0
const BULLET_MAX_DIST := 32.0
const BULLET_HEIGHT := 0.5
const BULLET_LEN := 0.2
const BULLET_R := 0.025              # 直径 0.05 -> 半径 0.025

## ── 37mm 火箭（炮弹类）──────────────────────────────────────────────────────
## 用户口径（第 83 轮）：直径 0.185（原来是 0.37 的一半）、长 0.7（不变）；
## **飞行速度与飞行距离正相关**：初始 1 格/秒，飞满 12 格后达到上限 8 格/秒；
## 落地范围直径 2 格；落点同时随机两个方向生成 2 枚破片。
##   ds/dt = v(s) = min(8, 1 + 7s/12)
##   · 闭式解 t(s) = (12/7)·ln(1 + 7s/12)      （飞满 12 格 ≈ 3.5648 秒）
##   · 反解   s(t) = (12/7)·(e^(7t/12) − 1)
##   · 平台段 s = 12 + 8·(t − 3.5648)
const ROCKET_DIAMETER := 0.185
const ROCKET_LEN := 0.7
const ROCKET_R := ROCKET_DIAMETER * 0.5
const ROCKET_V0 := 1.0
const ROCKET_VMAX := 8.0
const ROCKET_RAMP_DIST := 12.0
const ROCKET_ACCEL_K := 7.0 / 12.0     # v = 1 + k·s（爬坡段）
const ROCKET_BLAST_R := 1.0          # 落地范围直径 2 格
const ROCKET_FRAGMENTS := 2


## 爬坡段结束的时刻（飞满 12 格）
static func rocket_t_ramp() -> float:
	return log(1.0 + ROCKET_ACCEL_K * ROCKET_RAMP_DIST) / ROCKET_ACCEL_K


static func rocket_t_of_s(s: float) -> float:
	var d: float = maxf(0.0, s)
	if d <= ROCKET_RAMP_DIST:
		return log(1.0 + ROCKET_ACCEL_K * d) / ROCKET_ACCEL_K
	return rocket_t_ramp() + (d - ROCKET_RAMP_DIST) / ROCKET_VMAX


static func rocket_s_of_t(t: float) -> float:
	var tt: float = maxf(0.0, t)
	var t_ramp: float = rocket_t_ramp()
	if tt <= t_ramp:
		return (exp(tt * ROCKET_ACCEL_K) - 1.0) / ROCKET_ACCEL_K
	return ROCKET_RAMP_DIST + ROCKET_VMAX * (tt - t_ramp)


static func rocket_speed_at(s: float) -> float:
	return minf(ROCKET_VMAX, ROCKET_V0 + s * ROCKET_ACCEL_K)


## 火箭：从 from 飞向 to；总时长 = 解析解 t(s)
static func make_rocket(caster: Unit, from: Vector3, to: Vector2, ends_turn: bool = true) -> Projectile:
	var start := Vector2(from.x, from.z)
	var dist: float = maxf(0.5, start.distance_to(to))
	var p := Projectile.make(Projectile.KIND_ROCKET, start, to, 1.0)
	p.dur = maxf(0.05, rocket_t_of_s(dist))
	p.speed_profile = Projectile.SPEED_ROCKET
	_config_owner(p, caster)
	p.y0 = from.y
	p.y1 = 0.15
	p.arc_scale = 0.22
	p.arc_min = 0.3
	p.arc_max = 2.4
	p.recalc_apex()
	p.hit_r = ROCKET_R
	# 炮弹类统一模板（用户口径第 84 轮）：可以被箭击落 + 惊动哨兵
	var tpl := Ballistics.shell_like_defaults(Projectile.KIND_ROCKET)
	p.hit_tags.assign(tpl["hit_tags"])
	p.sentry_trigger = bool(tpl["sentry_trigger"])
	p.shot = _shot(Projectile.KIND_ROCKET, caster, ends_turn, ROCKET_BLAST_R, {}, "")
	return p


const ARROW_TILES_PER_SEC := 6.5     # 箭矢速度（用户口径：8 -> 6 -> 11 -> 6.5 格/秒）
const GRENADE_HIT_R := 0.16          # 手榴弹空中阶段的碰撞半径

const CANNON_TILES_PER_SEC := 12.0   # 加农炮弹速度（用户口径）
const CANNON_RANGE := 15.0           # 加农炮最大射程（格）
const CANNON_R := 0.25               # 加农炮弹半径（直径 0.5 格）
const CANNON_POWER_MULT := 0.5       # 只造成 50% 力量伤害（先乘再减护甲）
const MARKER_SPEED_MULT := 2.0       # 轨道召唤球 = 炮弹的 2 倍
const SHELL_HIT_R := 0.16            # 炮弹碰撞半径
const MARKER_HIT_R := 0.15
const ARROW_BODY_R := 0.075          # 箭矢直径 0.15 格
const UNIT_BODY_R := 0.30            # 角色脚下判定半径
const CARPET_BLAST_R := 1.0          # 地毯式轰炸爆炸半径 = 轨道炮击同款
const DEFAULT_BLAST_R := 1.5         # 普攻炮击爆炸半径


## 一张发射单：弹道物飞完之后"打什么、打多大、要不要结束回合"全在这里
class Shot extends RefCounted:
	var kind: String = Projectile.KIND_SHELL
	var caster: Unit = null
	var opts: Dictionary = {}                 # Combat.opts(...)，伤害参数快照
	var blast_r: float = DEFAULT_BLAST_R
	var ends_turn: bool = true
	var group: String = ""                    # 编组：全部消失后才结束回合
	var target: Unit = null                   # 弓箭的预定目标（仅日志/参考）
	## 预定要打的沙盒道具（用户口径：近战/远程英雄也能锁定沙盒元素）
	var target_placeable: Placeable = null
	var break_armor: bool = false
	var tint_sentry: bool = false
	var reflected: bool = false               # 反弹回来的箭（日志与伤害口径都要认出来）
	var last_hit_dist: float = 0.0            # 命中瞬间离生成点走了多远（破片伤害用）
	## 攻方力量倍率（加农炮 = 0.5：先乘 50% 再减护甲、再过抗性）
	var power_mult: float = 1.0


# ── 构造器 ────────────────────────────────────────────────────────────────────
## 投掷手炮弹（普攻 / 地毯式轰炸共用）。速度恒定，进射界惊动哨兵，会被箭击落。
static func make_shell(caster: Unit, to: Vector2, ends_turn: bool, rng,
		pre: float = 0.0, group: String = "", blast_r: float = DEFAULT_BLAST_R) -> Projectile:
	var from := _cell_center(caster)
	var p := Projectile.make(Projectile.KIND_SHELL, from, to,
		maxf(0.25, from.distance_to(to) / SHELL_TILES_PER_SEC))
	_config_owner(p, caster)
	p.pre = pre
	p.t = -pre / p.dur
	p.hit_r = SHELL_HIT_R
	var tpl_s := Ballistics.shell_like_defaults(Projectile.KIND_SHELL)
	p.hit_tags.assign(tpl_s["hit_tags"])          # 可以被箭击落
	p.sentry_trigger = bool(tpl_s["sentry_trigger"])
	p.arc_scale = 0.45
	p.arc_min = 0.8
	p.arc_max = 3.6
	p.recalc_apex()
	p.shot = _shot(Projectile.KIND_SHELL, caster, ends_turn, blast_r,
		Combat.opts({
			"power": caster.power_cur,
			"armor_break": caster.armor_break,
			"ignore_res": 0.5,
			"rng": rng,
		}), group)
	return p


## 轨道标记召唤球：手感与投掷手普攻一致，紫色小球；出界/被击落则整发作废
static func make_marker(caster: Unit, to: Vector2) -> Projectile:
	var from := _cell_center(caster)
	var p := Projectile.make(Projectile.KIND_MARKER, from, to,
		maxf(0.2, from.distance_to(to) / (SHELL_TILES_PER_SEC * MARKER_SPEED_MULT)))
	_config_owner(p, caster)
	p.hit_r = MARKER_HIT_R
	# 召唤球：可被击落、惊动哨兵，但它**不是炮弹类**（被击落/撞人都只是整发作废，不炸）
	p.hit_tags = ["arrow"]
	p.sentry_trigger = true
	p.y0 = 0.90
	p.y1 = 0.12
	p.arc_scale = 0.40
	p.arc_min = 0.9
	p.arc_max = 3.2
	p.recalc_apex()
	p.shot = _shot(Projectile.KIND_MARKER, caster, true, DEFAULT_BLAST_R, {}, "")
	return p


## 哨兵箭的力量倍率（用户口径第 83 轮：力量只吃 25%，先乘再减护甲）
const SENTRY_POWER_MULT := 0.25

## 每两支箭之间的最小间隔（和 GameMaster.SENTRY_FIRE_INTERVAL 对应，日志/测试用）
const SENTRY_FIRE_INTERVAL_REF := 0.25


## 枪榴弹：空中阶段按【炮弹】处理（惊动哨兵、可被箭击落），落地后由 GM 计时爆炸
static func make_grenade(caster: Unit, to: Vector2, ends_turn: bool) -> Projectile:
	var from := _cell_center(caster)
	var p := Projectile.make(Projectile.KIND_GRENADE, from, to,
		maxf(0.25, from.distance_to(to) / SHELL_TILES_PER_SEC))
	_config_owner(p, caster)
	p.hit_r = GRENADE_HIT_R
	var tpl_g := Ballistics.shell_like_defaults(Projectile.KIND_GRENADE)
	p.hit_tags.assign(tpl_g["hit_tags"])           # 可以被箭击落
	p.sentry_trigger = bool(tpl_g["sentry_trigger"])   # 会惊动哨兵
	p.arc_scale = 0.55
	p.arc_min = 1.0
	p.arc_max = 4.0
	p.recalc_apex()
	p.shot = _shot(Projectile.KIND_GRENADE, caster, ends_turn, 0.0, {}, "")
	return p


## 子弹：从 from 沿 dir 平飞（无重力），32 格后消失。
## aim_y >= 0 时平飞高度改成 aim_y（瞄悬空的直升机要抬高，否则从它下面飞过去）
static func make_bullet(caster: Unit, from: Vector3, to: Vector2,
		ends_turn: bool = true, aim_y: float = -1.0) -> Projectile:
	var start := Vector2(from.x, from.z)
	# 瞄准点只决定【方向】：弹道一直飞到 32 格才消失（用户口径）
	var dir := (to - start)
	dir = dir.normalized() if dir.length() > 0.001 else Vector2.RIGHT
	var p := Projectile.make(Projectile.KIND_BULLET, start, start + dir * BULLET_MAX_DIST, 1.0)
	p.set_speed(BULLET_TILES_PER_SEC)
	_config_owner(p, caster)
	var fly_y: float = aim_y if aim_y >= 0.0 else BULLET_HEIGHT
	p.y0 = fly_y
	p.y1 = fly_y
	p.arc_scale = 0.0                 # 不受重力
	p.arc_min = 0.0
	p.arc_max = 0.0
	p.recalc_apex()
	p.hit_r = BULLET_R
	p.hit_tags = []                   # 箭矢类：不会被击落
	p.sentry_trigger = false
	p.shot = _shot(Projectile.KIND_BULLET, caster, ends_turn, 0.0, {}, "")
	return p


## 破片：从 from 沿 dir 平飞（无重力），20 格后自然结束
static func make_fragment(caster: Unit, from: Vector3, dir: Vector2,
		ends_turn: bool = false) -> Projectile:
	var d := dir.normalized() if dir.length() > 0.001 else Vector2.RIGHT
	var start := Vector2(from.x, from.z)
	var p := Projectile.make(Projectile.KIND_FRAGMENT, start,
		start + d * FRAGMENT_MAX_DIST, 1.0)
	p.set_speed(FRAGMENT_TILES_PER_SEC)
	_config_owner(p, caster)
	p.y0 = FRAGMENT_HEIGHT
	p.y1 = FRAGMENT_HEIGHT
	p.arc_scale = 0.0                 # 不受重力：平飞
	p.arc_min = 0.0
	p.arc_max = 0.0
	p.recalc_apex()
	p.hit_r = FRAGMENT_R
	p.hit_tags = []                   # 箭矢类：不会被击落
	p.sentry_trigger = false          # 也不惊动哨兵
	p.shot = _shot(Projectile.KIND_FRAGMENT, caster, ends_turn, 0.0, {}, "")
	return p


## 箭矢（远程普攻 / 哨兵共用）。恒定速度、真实抛物线、不会触发哨兵。
static func make_arrow(attacker: Unit, from: Vector3, to: Vector3, target: Unit,
		break_armor: bool, ends_turn: bool, tint_sentry: bool = false) -> Projectile:
	var p := Projectile.make(Projectile.KIND_ARROW, Vector2(from.x, from.z),
		Vector2(to.x, to.z), 1.0)
	p.set_speed(ARROW_TILES_PER_SEC)
	_config_owner(p, attacker)
	p.y0 = from.y
	p.y1 = to.y
	p.arc_scale = 0.34        # 拱高足够，能从其他角色头顶飞越
	p.arc_min = 0.55
	p.arc_max = 4.2
	p.recalc_apex()
	p.hit_r = ARROW_BODY_R
	p.hit_tags = []           # 箭矢不会被击落
	p.sentry_trigger = false  # 箭矢不惊动哨兵（否则箭生箭会指数爆炸）
	var sh := _shot(Projectile.KIND_ARROW, attacker, ends_turn, 0.0, {}, "")
	sh.target = target
	sh.break_armor = break_armor
	sh.tint_sentry = tint_sentry
	if tint_sentry:
		sh.power_mult = SENTRY_POWER_MULT        # 哨兵箭只有 25% 力量（用户口径）
	p.shot = sh
	return p


# ── 内部 ──────────────────────────────────────────────────────────────────────
static func _cell_center(u: Unit) -> Vector2:
	return Vector2(float(u.cell.x) + 0.5, float(u.cell.y) + 0.5)


## 加农炮弹（老国王）：箭矢类，直线快弹，不会被击落、不惊动哨兵，只吃 50% 力量。
## from/to 由发射者给（炮口在身前），速度恒定 12 格/秒，弹道几乎是直线。
static func make_cannon(caster: Unit, from: Vector3, to: Vector3, ends_turn: bool) -> Projectile:
	var p := Projectile.make(Projectile.KIND_CANNON, Vector2(from.x, from.z),
		Vector2(to.x, to.z), 1.0)
	p.set_speed(CANNON_TILES_PER_SEC)
	_config_owner(p, caster)
	p.y0 = from.y
	p.y1 = to.y
	p.arc_scale = 0.04        # 几乎是直线
	p.arc_min = 0.02
	p.arc_max = 0.25
	p.recalc_apex()
	p.hit_r = CANNON_R
	p.hit_tags = []           # 箭矢类：不会被任何东西击落
	p.sentry_trigger = false  # 也不惊动哨兵（和箭矢一样）
	var sh := _shot(Projectile.KIND_CANNON, caster, ends_turn, 0.0, {}, "")
	sh.power_mult = CANNON_POWER_MULT
	p.shot = sh
	return p


static func _config_owner(p: Projectile, u: Unit) -> void:
	p.side = u.side
	p.owner_unit = u
	p.owner_name = u.name


static func _shot(kind: String, caster: Unit, ends_turn: bool, blast_r: float,
		opts: Dictionary, group: String) -> Shot:
	var s := Shot.new()
	s.kind = kind
	s.caster = caster
	s.ends_turn = ends_turn
	s.blast_r = blast_r
	s.opts = opts
	s.group = group
	return s
