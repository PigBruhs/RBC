# ══════════════════════════════════════════════════════════════════════════════
# 弹道物（Projectile）—— **纯物理对象**
#
# 用户口径（重要）：
#   · 这个对象的【固有属性只决定它的物理弹道】，不含任何伤害/效果数据。
#   · 伤害取决于发射者，落点也由发射者给定 —— 这些放在上层的"发射单"里
#     （battle_scene 的 _projs 条目），以后加子弹/飞刀只需要新增一个 kind。
#   · 于是敌方 AI 只需要构造一张发射单，不必关心弹道物内部。
#
# 物理量：
#   from/to  水平起终点（浮点格坐标，落点由发射者决定）
#   y0/y1    两端的基准高度；apex 是叠加在中间的抛物线拱高
#   dur      飞行时间（秒）—— 速度 = 水平距离 / dur
#   hit_r    碰撞体积（水平半径）
#   kind     我是什么（shell / arrow / marker）
#   hit_tags 谁能击落我（比如炮弹的 hit_tags = ["arrow"]）
#   sentry_trigger  我进入哨兵射界时要不要触发哨兵（箭矢 = false，用户明确）
# ══════════════════════════════════════════════════════════════════════════════
class_name Projectile
extends RefCounted

const KIND_SHELL := "shell"      # 投掷手炮弹（普攻 / 地毯式轰炸）
const KIND_ARROW := "arrow"      # 箭矢（远程普攻 / 哨兵）
const KIND_MARKER := "marker"    # 轨道标记召唤球
## 加农炮弹：箭矢类（直线快弹、不会被击落、不惊动哨兵），但只吃 50% 力量
const KIND_CANNON := "cannon"
const KIND_FRAGMENT := "fragment"  # 破片（箭矢类：无重力、平飞、按距离衰减伤害）
const KIND_BULLET := "bullet"      # 子弹（萨尼铁塔：箭矢类、无重力、阶梯衰减）
## 第 104 轮：**午餐盒的齐射子弹**（与 `KIND_BULLET` 区分）。
## 相同的：箭矢类、无重力平飞、12 格/秒、32 格消失、同一张**只作用于力量**的阶梯衰减表。
## 不同的：破甲 = **每发固定 +4 点**（不吃攻方 `armor_break`、不吃衰减）。
## 见 `docs/规格.md` §12.2b 与 `Ordnance.make_cart_bullet`。
const KIND_CART_BULLET := "cart_bullet"
const KIND_GRENADE := "grenade"    # 枪榴弹（空中=炮弹规则，落地变模型，GM 计时爆炸）
const KIND_ROCKET := "rocket"      # 37mm 火箭（炮弹类：落地直径 2 格 + 2 枚破片）
const KIND_LOITER := "loiter"      # 巡飞弹（炮弹类 + 可制导：定高 1.5、恒速 3、近炸引信）
## 激光（光束类：存在一段时间、逐物理帧累计帧伤、结束**统一结算一次**）。
## 注意：它不是"飞行物"，**不进 ProjectileField**（不参与互相击落、不能被箭打掉、不惊动哨兵），
## 这个 kind 只是"弹射物类型"的登记名（见 Ballistics.LASER_LIKE 与 core/laser.gd）。
const KIND_LASER := "laser"

## 速度剖面（0 = 匀速；老弹种一律 0，行为逐位不变）
const SPEED_UNIFORM := 0
const SPEED_ROCKET := 1            # v(s) = min(6, 2 + s/3)，闭式解见 Ordnance.rocket_*

var id: int = 0
var kind: String = KIND_SHELL
var side: int = 0                    # 发射方阵营（只用于显示/日志）
var owner_name: String = ""
var owner_unit: Unit = null          # 可能中途阵亡，所以只当弱引用用
var speed_profile: int = 0            # 速度剖面（见 SPEED_*）

# ── 弹道 ──
var from: Vector2 = Vector2.ZERO
var to: Vector2 = Vector2.ZERO
var y0: float = 0.85
var y1: float = 0.10
var apex: float = 2.0
var t: float = 0.0                   # -pre/dur .. 1；<0 表示还没起飞
var dur: float = 1.0
var pre: float = 0.0                 # 起飞前的延迟（地毯式轰炸的间隔用）
var arc_scale: float = 0.45
var arc_min: float = 0.8
var arc_max: float = 3.6

# ── 碰撞 ──
var hit_r: float = 0.26
var hit_tags: Array[String] = []     # 谁能击落我
var sentry_trigger: bool = false     # 进射界要不要惊动哨兵
## 安全引信距离（格，第 104 轮）：飞够这么远才开碰撞与近炸。
## **0 = 一直武装**（既有弹种行为逐字不变）；只有"出膛后要先安全飞一段"的弹种才设它
## （轮式齐射午餐盒的技能巡飞弹 = `Loiter.ARM_DIST`）。见 `Loiter.armed()`。
var arm_dist: float = 0.0
## 命中判定要跳过谁。默认 null = 跳过 owner_unit（自己的箭不打自己）。
## 弹反箭例外：它的 owner_unit 是【原射手】（用来算伤害），但物理上是从杰拉尔德身上
## 出手的，所以要跳过的是杰拉尔德而不是射手 —— 否则永远打不回射手身上。
var ignore_unit: Unit = null
## 破片要能打到自己人（含自伤）：true = 命中判定不跳过任何人
var hit_self: bool = false

# ── 状态 ──
var alive: bool = true
var removed_reason: String = ""
var removed_at: Vector2 = Vector2.ZERO
## 发射单：伤害/落点/是否结束回合等，全部由发射者决定（弹道物自身只管飞）
var shot: Ordnance.Shot = null

# ── 可制导弹种（巡飞弹，用户口径第 90 轮）──────────────────────────────────
## steering = true 的弹道物不走 from->to 插值：位置由 heading + 恒速逐帧积分，
## 高度恒定 steer_h，飞满 max_dist 记 finished（自动引爆）。
var steering: bool = false
var steer_pos: Vector2 = Vector2.ZERO
var heading: float = 0.0             # 水平方向（弧度，世界 xz 平面）
var steer_speed: float = 3.0         # 恒速（格/秒）
var steer_h: float = 1.5             # 定高（不受重力）
var max_dist: float = 32.0
var flown: float = 0.0
var turn_w: float = 0.0              # 当前角速度（度/秒，带惯性）
var hold_l: float = 0.0              # 左转键已按住多久（秒）
var hold_r: float = 0.0              # 右转键已按住多久（秒）
## 近炸引信要忽略的沙盒元素（发射它的那台发射器，否则一出生就自爆）
var ignore_placeable: Placeable = null
## 这一发不受玩家制导（第 91 轮：场上已经有别的巡飞弹时，新发射的那一发就是"多余的"）
var no_control: bool = false

static var _next_id: int = 1


static func make(p_kind: String, p_from: Vector2, p_to: Vector2, p_dur: float) -> Projectile:
	var p := Projectile.new()
	p.id = _next_id
	_next_id += 1
	p.kind = p_kind
	p.from = p_from
	p.to = p_to
	p.dur = maxf(0.02, p_dur)
	p.recalc_apex()
	return p


## 拱高按水平距离算（发射者改完 from/to 之后可以再调一次）
func recalc_apex() -> void:
	apex = clampf(from.distance_to(to) * arc_scale, arc_min, arc_max)


## 飞行时间按"恒定速度"设：speed 格/秒
func set_speed(tiles_per_sec: float) -> void:
	dur = maxf(0.05, from.distance_to(to) / maxf(0.05, tiles_per_sec))


## 当前进度（0..1，起飞前恒为 0）
func progress() -> float:
	return clampf(t, 0.0, 1.0)


## 是否已经起飞
func ready() -> bool:
	return t >= 0.0


func finished() -> bool:
	return t >= 1.0


## 水平位置
## 变速弹种：把归一化进度 t 映射成【已飞距离】（火箭用解析反解；匀速弹种等价于 t*total）
func flown_dist() -> float:
	var total := from.distance_to(to)
	if speed_profile == SPEED_ROCKET:
		var elapsed: float = clampf(t, 0.0, 1.0) * dur
		return clampf(Ordnance.rocket_s_of_t(elapsed), 0.0, total)
	return clampf(t, 0.0, 1.0) * total


func pos() -> Vector2:
	if steering:
		return steer_pos
	var total := from.distance_to(to)
	if total <= 0.0001:
		return to
	if speed_profile != SPEED_UNIFORM:
		return from.lerp(to, clampf(flown_dist() / total, 0.0, 1.0))
	return from.lerp(to, progress())


## 高度：两端基准高度 + 中间一条抛物线（两端为 0）；可制导弹种恒定高度
func height() -> float:
	if steering:
		return steer_h
	var k := progress()
	return lerpf(y0, y1, k) + apex * 4.0 * k * (1.0 - k)


func pos3() -> Vector3:
	var p := pos()
	return Vector3(p.x, height(), p.y)


## 水平单位方向
func dir_flat() -> Vector2:
	var d := to - from
	return d.normalized() if d.length() > 0.0001 else Vector2.RIGHT


func step(dt: float) -> void:
	if not alive:
		return
	if steering:
		# 可制导：恒速沿 heading 走，飞满 max_dist 就 finished（=> 自动引爆）
		var d := steer_speed * dt
		flown += d
		steer_pos += Vector2(cos(heading), sin(heading)) * d
		t = clampf(flown / maxf(0.001, max_dist), 0.0, 1.0)
		return
	t += dt / dur
	if t >= 1.0:
		t = 1.0


func kill(reason: String) -> void:
	alive = false
	removed_reason = reason


## 水平碰撞：半径之和
func hits(other: Projectile) -> bool:
	if not alive or not other.alive or other == self:
		return false
	return pos().distance_to(other.pos()) <= hit_r + other.hit_r


func dist_to(p: Vector2) -> float:
	return pos().distance_to(p)
