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

var id: int = 0
var kind: String = KIND_SHELL
var side: int = 0                    # 发射方阵营（只用于显示/日志）
var owner_name: String = ""
var owner_unit: Unit = null          # 可能中途阵亡，所以只当弱引用用

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
## 命中判定要跳过谁。默认 null = 跳过 owner_unit（自己的箭不打自己）。
## 弹反箭例外：它的 owner_unit 是【原射手】（用来算伤害），但物理上是从杰拉尔德身上
## 出手的，所以要跳过的是杰拉尔德而不是射手 —— 否则永远打不回射手身上。
var ignore_unit: Unit = null

# ── 状态 ──
var alive: bool = true
var removed_reason: String = ""
var removed_at: Vector2 = Vector2.ZERO
## 发射单：伤害/落点/是否结束回合等，全部由发射者决定（弹道物自身只管飞）
var shot: Ordnance.Shot = null

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
func pos() -> Vector2:
	return from.lerp(to, progress())


## 高度：两端基准高度 + 中间一条抛物线（两端为 0）
func height() -> float:
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
