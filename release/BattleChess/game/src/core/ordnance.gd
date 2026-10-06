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
## 用户口径（第 104 轮修正后）：12 格/秒、**不受重力**、32 格模型消失；
## 伤害**阶梯衰减只作用于力量伤害**（破甲不再衰减）：
## 0-12 格 100% / 12-16 格 60% / 16-24 格 20% / >24 格无伤害（仍可命中）。
## ⚠ 旧的"全程离地 0.5 格"**已删除**（第 104 轮用户口径）：高度只由发射时的瞄准高度决定。
const BULLET_TILES_PER_SEC := 12.0
## ⚠ 第 111 轮用户口径：「**子弹速度翻倍**」—— 只对**齐射车**的子弹翻倍（12 -> 24），
##   萨尼的连发（`KIND_BULLET`）保持 12 不动。
const CART_BULLET_TILES_PER_SEC := 24.0
## ⚠ 第 111 轮用户口径：「子弹**模型消失距离似乎小于 64 格**」—— 32 -> **64**
##   （与 `Damage.BULLET_MAX_DIST` 一致：飞满 64 格模型消失、伤害归零）
const BULLET_MAX_DIST := 64.0
## 子弹兜底高度（只在调用方既没给 `aim_y`、也没有射手时用）：
## **地面角色的身体中心**（= 0.5 格）。正常路径见 `_bullet_fly_y`（取射手身体中心）。
const BULLET_FLOOR_Y := 0.5
const BULLET_LEN := 0.2
const BULLET_R := 0.025              # 直径 0.05 -> 半径 0.025
## 午餐盒子弹的**固定破甲**（点）。
## 不吃攻方 `armor_break`、不吃距离衰减 —— 结算在 `projectile_sink.resolve_arrow_hit`。
## 第 104 轮：用户口径从 4 调到 **2**（同时车的力量 24 -> 12、护甲 90 -> 110）。
const CART_BULLET_BREAK := 2
## ⚠ 第 111 轮用户口径：车用子弹**不走造伤公式**，每发**直接 -2 护甲 / -2 力量**
##   （各自夹在 0 以上，不看物抗/魔抗）。见 `projectile_sink` 的 `KIND_CART_BULLET` 分支。
const CART_BULLET_POWER := 2

## ── 37mm 火箭（炮弹类）──────────────────────────────────────────────────────
## 用户口径（第 83 轮）：直径 0.185（原来是 0.37 的一半）、长 0.7（不变）；
## **飞行速度与飞行距离正相关**：初始速度 -> 飞满 12 格后达到上限；
## 落地范围直径 2 格；落点同时随机两个方向生成 2 枚破片。
## 第 92 轮：初始 1 -> **4 格/秒**，上限 8 -> **12 格/秒**（公式不变，只改这两个数）。
##   ds/dt = v(s) = min(12, 4 + 8s/12)
##   · 闭式解 t(s) = (12/8)·ln(1 + 8s/12)
##   · 反解   s(t) = (12/8)·(e^(8t/12) − 1)
##   · 平台段 s = 12 + 12·(t − t_ramp)
const ROCKET_DIAMETER := 0.185
const ROCKET_LEN := 0.7
const ROCKET_R := ROCKET_DIAMETER * 0.5
const ROCKET_V0 := 4.0
const ROCKET_VMAX := 12.0
const ROCKET_RAMP_DIST := 12.0
const ROCKET_ACCEL_K := (ROCKET_VMAX - ROCKET_V0) / ROCKET_RAMP_DIST   # v = v0 + k·s（爬坡段）
const ROCKET_BLAST_R := 1.0          # 落地范围直径 2 格
## 每发火箭生成的破片数。第 110 轮用户口径：2 -> **4**。
const ROCKET_FRAGMENTS := 4


## 爬坡段结束的时刻（速度达到上限那一刻）
static func rocket_t_ramp() -> float:
	return log(ROCKET_VMAX / ROCKET_V0) / ROCKET_ACCEL_K


## t(s)：注意闭式解里带 v0 —— dt = ds/(v0 + k·s)，所以 t = (1/k)·ln(1 + k·s/v0)。
## （第 92 轮把 v0 从 1 提到 4 时这里必须带上 /v0，否则时间会被算长一倍多）
static func rocket_t_of_s(s: float) -> float:
	var d: float = maxf(0.0, s)
	if d <= ROCKET_RAMP_DIST:
		return log(1.0 + ROCKET_ACCEL_K * d / ROCKET_V0) / ROCKET_ACCEL_K
	return rocket_t_ramp() + (d - ROCKET_RAMP_DIST) / ROCKET_VMAX


static func rocket_s_of_t(t: float) -> float:
	var tt: float = maxf(0.0, t)
	var t_ramp: float = rocket_t_ramp()
	if tt <= t_ramp:
		return ROCKET_V0 * (exp(tt * ROCKET_ACCEL_K) - 1.0) / ROCKET_ACCEL_K
	return ROCKET_RAMP_DIST + ROCKET_VMAX * (tt - t_ramp)


static func rocket_speed_at(s: float) -> float:
	return minf(ROCKET_VMAX, ROCKET_V0 + s * ROCKET_ACCEL_K)


## 巡飞弹（发射器发射，玩家用 Q/E 制导）：炮弹类 —— 可被箭击落、惊动哨兵、撞人=在命中处引爆。
## 不受重力（定高 1.5 格）、恒速 3 格/秒、飞满 32 格自动引爆；近炸引信在 battle_scene 每帧判。
## side = 发射方（沙盒发射器传 -1：不分敌我）；owner_name 只用于日志。
static func make_loiter(side: int, owner_name: String, from: Vector2, heading: float, rng,
		arm_dist: float = 0.0) -> Projectile:
	var dir := Vector2(cos(heading), sin(heading))
	var p := Projectile.make(Projectile.KIND_LOITER, from, from + dir * Loiter.MAX_DIST, 1.0)
	p.steering = true
	p.steer_pos = from
	p.heading = heading
	p.steer_speed = Loiter.SPEED
	p.steer_h = Loiter.HEIGHT
	p.max_dist = Loiter.MAX_DIST
	# 第 104 轮：安全引信（0 = 一直武装 = 沙盒发射器的既有行为）
	p.arm_dist = arm_dist
	p.hit_r = Loiter.BODY_R                     # 碰撞体积 = 直径一格的球
	p.side = side
	p.owner_name = owner_name
	p.owner_unit = null
	var tpl := Ballistics.shell_like_defaults(Projectile.KIND_LOITER)
	p.hit_tags.assign(tpl["hit_tags"])
	p.sentry_trigger = bool(tpl["sentry_trigger"])
	p.shot = _shot(Projectile.KIND_LOITER, null, false, Loiter.BLAST_R, Loiter.opts(rng), "")
	return p


## 火箭：从 from 飞向 to；总时长 = 解析解 t(s)。
## rng：给了就把**发射那一刻的伤害参数快照**写进发射单（第 89 轮）——
## 火箭是"落地才算威力"的弹种，中途发射者阵亡/坠机不该让已经出膛的这一发变成 0 伤害
## （以前发射单里没有 opts，落地时按死者现算 -> 力量 0 -> 日志"力量打不动"）。
static func make_rocket(caster: Unit, from: Vector3, to: Vector2, ends_turn: bool = true,
		rng = null) -> Projectile:
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
	var opts: Dictionary = {}
	if rng != null:
		opts = Combat.opts({
			"power": caster.power_cur,
			"armor_break": caster.armor_break,
			"ignore_res": 0.5,
			"rng": rng,
		})
	p.shot = _shot(Projectile.KIND_ROCKET, caster, ends_turn, ROCKET_BLAST_R, opts, "")
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


## ── 齐射批次（第 105 轮）─────────────────────────────────────────────────────
## 同一波的 N 发子弹共享**一份伤害参数快照**（单发力量/破甲），命中只累计"打中了几发"，
## 由 `battle_scene` 在合适时机**一次性结算**（`Damage.strike_volley`）。
## 为什么要它：用户口径 —— 齐射的意义就是"同一波到同一目标的衰减参数相等"，
## 所以不需要每碰撞一次都走一遍完整造伤路径（实测 72 发里 61% 的时间花在
## 日志字符串 + `_after_damage_to_unit` 的收尾上，见临时脚本的性能对照表）。
class Volley extends RefCounted:
	var per_power: int = 0                   # 单发力量（已乘距离衰减，波发射时快照）
	var per_break: int = 0                   # 单发破甲（车用子弹 = 固定值）
	var caster: Unit = null
	var hits: Dictionary = {}                # 目标 instance_id -> 命中数
	var targets: Dictionary = {}             # 目标 instance_id -> Unit
	var total_hits: int = 0
	var settled: bool = false
	var born_at: float = 0.0                 # 发射时刻（秒，用于兜底超时）
	var last_hit_at: float = 0.0             # 最近一次命中的时刻（用于"这一波打完了"的判定）

	func add_hit(u: Unit, now: float) -> void:
		var id := u.get_instance_id()
		hits[id] = int(hits.get(id, 0)) + 1
		targets[id] = u
		total_hits += 1
		last_hit_at = now


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
	## 第 105 轮：齐射批次。非空 = 这一发的命中**只计数**，由批次统一结算。
	var volley: Volley = null


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


## 子弹：从 from 沿 dir 平飞（**不受重力**），32 格后消失。
## ⚠ 第 104 轮用户口径：**删掉"全程维持 0.5 格高度"这个设定** ——
##   高度**只由发射那一刻的瞄准高度决定**（`aim_y`），之后保持水平。
##   `aim_y < 0`（调用方没给）时的兜底见 `_bullet_fly_y`：取**射手自己的身体中心**。
## 弹种差异（§12.2b）：`make_bullet` = 萨尼铁塔（破甲走攻方 armor_break）；
## `make_cart_bullet` = 午餐盒（破甲固定 +4）。两者共用速度/消失距离/衰减表。
static func make_bullet(caster: Unit, from: Vector3, to: Vector2,
		ends_turn: bool = true, aim_y: float = -1.0) -> Projectile:
	return _make_bullet(Projectile.KIND_BULLET, caster, from, to, ends_turn, aim_y)


## 午餐盒的齐射子弹（第 104 轮新弹种）：与 `make_bullet` 完全相同的弹道，
## 只有**破甲**不同 —— 每发固定 `CART_BULLET_BREAK` 点（结算在 `projectile_sink`，
## 那里按弹种取破甲值）。力量照旧 = 射手力量 × 距离衰减。
static func make_cart_bullet(caster: Unit, from: Vector3, to: Vector2,
		ends_turn: bool = false, aim_y: float = -1.0) -> Projectile:
	return _make_bullet(Projectile.KIND_CART_BULLET, caster, from, to, ends_turn, aim_y)


## 立体散布用（第 106 轮）：瞄准点是 **3D** 的 —— 弹道因此带上**俯仰角**，
## 但**仍然是直线、不受重力**（`arc_scale = 0`，斜率只来自 y0 ≠ y1）。
##
## 换算细节：`Projectile.height()` 按**整段飞行进度** `k = 已飞/总长` 线性插值 y0→y1，
## 而子弹固定飞 `BULLET_MAX_DIST`（32 格）。要让它在**目标距离 `dist`** 处正好是瞄准高度
## `to3.y`，就得把 y1 **外推**到 32 格处：
##   `y1 = y0 + (to3.y - y0) / (dist / BULLET_MAX_DIST)`
## 这样 32 格之内是一条斜率恒定的直线，没有引入任何重力项。
static func make_cart_bullet_at(caster: Unit, from: Vector3, to3: Vector3,
		ends_turn: bool = false) -> Projectile:
	return _bullet_at(Projectile.KIND_CART_BULLET, caster, from, to3, ends_turn)


## 萨尼铁塔的连发用同一个立体散布入口（第 106 轮：用户口径「我需要立体球状散布」，
## 连发也是**子弹**，所以散布形状与午餐盒齐射一致）。
## 与 `make_cart_bullet_at` 的唯一区别是**弹种** —— 破甲走攻方 `armor_break`（见 §12.2b）。
static func make_bullet_at(caster: Unit, from: Vector3, to3: Vector3,
		ends_turn: bool = true) -> Projectile:
	return _bullet_at(Projectile.KIND_BULLET, caster, from, to3, ends_turn)


static func _bullet_at(kind: String, caster: Unit, from: Vector3, to3: Vector3,
		ends_turn: bool) -> Projectile:
	var start := Vector2(from.x, from.z)
	var flat := Vector2(to3.x - start.x, to3.z - start.y)
	var dist := maxf(flat.length(), 0.001)
	var dir := flat / dist
	var p := Projectile.make(kind, start, start + dir * BULLET_MAX_DIST, 1.0)
	# ⚠ 第 111 轮用户口径「子弹速度翻倍」：**只对齐射车的子弹翻倍**（12 -> 24），
	#   萨尼的连发（`KIND_BULLET`）保持 12 不动。
	p.set_speed(CART_BULLET_TILES_PER_SEC if kind == Projectile.KIND_CART_BULLET \
		else BULLET_TILES_PER_SEC)
	_config_owner(p, caster)
	var k := clampf(dist / BULLET_MAX_DIST, 0.0001, 1.0)
	p.y0 = from.y
	p.y1 = from.y + (to3.y - from.y) / k            # 外推：在 dist 处正好等于瞄准高度
	p.arc_scale = 0.0                               # 不受重力
	p.arc_min = 0.0
	p.arc_max = 0.0
	p.recalc_apex()
	p.hit_r = BULLET_R
	p.hit_tags = []                                 # 箭矢类：不会被击落
	p.sentry_trigger = false
	p.shot = _shot(kind, caster, ends_turn, 0.0, {}, "")
	return p


## 子弹缺省飞行高度（`aim_y < 0` 时的兜底）：**射手自己的身体中心**。
## 为什么这么定：用户要求"删掉恒定 0.5 格"——高度由**发射那一刻的瞄准**决定；
## 调用方没给瞄准高度时，最自然的物理含义就是"从射手身上射出来"（地面角色 = 0.5 格、
## 悬停的直升机 = 2.5 格、爬升中的直升机 = 它当下的真实高度）。
## 射手也为空时退到地面角色身体中心 `BULLET_FLOOR_Y`。
static func _bullet_fly_y(caster: Unit, aim_y: float) -> float:
	if aim_y >= 0.0:
		return aim_y
	if caster != null:
		return Targeting.aim_height(caster)
	return BULLET_FLOOR_Y


static func _make_bullet(kind: String, caster: Unit, from: Vector3, to: Vector2,
		ends_turn: bool, aim_y: float) -> Projectile:
	var start := Vector2(from.x, from.z)
	# 瞄准点只决定【方向】：弹道一直飞到 32 格才消失（用户口径）
	var dir := (to - start)
	dir = dir.normalized() if dir.length() > 0.001 else Vector2.RIGHT
	var p := Projectile.make(kind, start, start + dir * BULLET_MAX_DIST, 1.0)
	p.set_speed(BULLET_TILES_PER_SEC)
	_config_owner(p, caster)
	var fly_y := _bullet_fly_y(caster, aim_y)
	p.y0 = fly_y
	p.y1 = fly_y
	p.arc_scale = 0.0                 # 不受重力
	p.arc_min = 0.0
	p.arc_max = 0.0
	p.recalc_apex()
	p.hit_r = BULLET_R
	p.hit_tags = []                   # 箭矢类：不会被击落
	p.sentry_trigger = false
	p.shot = _shot(kind, caster, ends_turn, 0.0, {}, "")
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
## 格中心换算：与 battle_scene._cc 是同一个式子，实现收敛到 core/grid_math.gd
static func _cell_center(u: Unit) -> Vector2:
	return GridMath.cell_center(u.cell)


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
