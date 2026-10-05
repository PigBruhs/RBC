# ══════════════════════════════════════════════════════════════════════════════
# 距离散步（dispersion）—— 以后 AI 和弹反都用它
#
# 用户口径：
#   · 按【飞行时间】算，不看格数本身：飞得越久越飘。
#   · 非线性：近距离完全没有散步，之后随距离增长**越来越快**（二次增长）。
#   · 不设上限。
#   · 两个标定：5 格以内无散步；20 格时散步圆直径 3 格（半径 1.5）。
#
# 于是（箭矢 8 格/秒）：
#     t_near = 5/8  = 0.625 秒  -> 半径 0
#     t_far  = 20/8 = 2.5   秒  -> 半径 1.5
#     半径(t) = K · (t - t_near)²   （t <= t_near 时为 0）
#     K = 1.5 / (2.5 - 0.625)² = 0.4267
#
# 参考值：8 格 0.04 格 ｜ 12 格 0.32 格 ｜ 20 格 1.50 格 ｜ 32 格 4.0 格（直径 8 格）
# ══════════════════════════════════════════════════════════════════════════════
class_name Spread
extends RefCounted

const CAL_NEAR_DIST := 5.0        # 这个距离以内：完全没有散步
const CAL_FAR_DIST := 20.0        # 这个距离：散步圆直径 3 格
const CAL_FAR_RADIUS := 1.5       # = 3 / 2
const ARROW_SPEED := 8.0          # 曲线标定用的参考速度（不是箭矢实际速度，曲线按【距离】标定）
const EXPONENT := 2.0             # 非线性指数：越大越"近处准、远处飘"

## 飞行时间（秒）。**参考速度固定为 ARROW_SPEED**：曲线是按距离标定的，
## 以后改箭矢实际飞行速度不会把散步曲线一起改掉。
static func flight_time(dist: float, speed: float = ARROW_SPEED) -> float:
	if speed <= 0.0:
		return 0.0
	return dist / ARROW_SPEED


## 由飞行时间得散步半径（格）。t 秒以内为 0，之后二次增长，不封顶。
static func radius_from_time(t: float) -> float:
	var t_near := CAL_NEAR_DIST / ARROW_SPEED
	if t <= t_near:
		return 0.0
	var t_far := CAL_FAR_DIST / ARROW_SPEED
	var k := CAL_FAR_RADIUS / pow(t_far - t_near, EXPONENT)
	return k * pow(t - t_near, EXPONENT)


## 由距离得散步半径（格）
static func radius(dist: float, speed: float = ARROW_SPEED) -> float:
	return radius_from_time(flight_time(dist, speed))


## 落在散步圆内的随机偏移（圆内均匀：半径按 sqrt(u) 取，否则会堆在圆心）
static func offset(dist: float, speed: float, rng: RngService) -> Vector2:
	var r := radius(dist, speed)
	if r <= 0.0 or rng == null:
		return Vector2.ZERO
	var ang := rng.next_float() * TAU
	var rr := r * sqrt(rng.next_float())
	return Vector2(cos(ang) * rr, sin(ang) * rr)


## ── 玩家侧线性散布（萨尼铁塔专用，用户口径）────────────────────────────────
## 与距离呈线性正相关，12 格时半径约 1 格 -> r = dist / 12
static func linear_radius(dist: float) -> float:
	return maxf(0.0, dist) / 12.0


static func linear_scatter(dest: Vector2, dist: float, rng: RngService) -> Vector2:
	if rng == null:
		return dest
	var r := linear_radius(dist)
	if r <= 0.0:
		return dest
	var ang := rng.next_float() * TAU
	var rr := r * sqrt(rng.next_float())
	return dest + Vector2(cos(ang) * rr, sin(ang) * rr)


## 半径 r 的球体内均匀随机一点（用于哨兵瞄准：以目标当前位置为球心、半径 1 格的球）
static func ball_offset(r: float, rng: RngService) -> Vector3:
	if r <= 0.0 or rng == null:
		return Vector3.ZERO
	# 方向在球面上均匀 + 半径用 cbrt 保证体均匀
	var z := 2.0 * rng.next_float() - 1.0
	var ang := rng.next_float() * TAU
	var rad := sqrt(maxf(0.0, 1.0 - z * z))
	var rr := r * pow(rng.next_float(), 1.0 / 3.0)
	return Vector3(rad * cos(ang), z, rad * sin(ang)) * rr


## 以 dest 为圆心散射：返回真正的落点
static func scatter(dest: Vector2, dist: float, speed: float, rng: RngService) -> Vector2:
	return dest + offset(dist, speed, rng)


# ══════════════════════════════════════════════════════════════════════════════
# 杰拉尔德弹反专用散步（用户口径：翻倍 + 取消"100% 准确区"）
#   · 旧口径：5 格以内完全准，20 格 -> 半径 1.5
#   · 新口径：任何距离都有一点散布（没有 0 区间），20 格 -> 半径 3.0（翻倍）
#     r(t) = A · t²      A = 3.0 / (20/8)² = 0.48
#   参考值：2 格 0.03 ｜ 5 格 0.19 ｜ 10 格 0.75 ｜ 20 格 3.0
# ══════════════════════════════════════════════════════════════════════════════
const REFLECT_FAR_RADIUS := CAL_FAR_RADIUS * 2.0      # 20 格处半径 = 3.0

static func reflect_radius(dist: float, speed: float = ARROW_SPEED) -> float:
	var t := flight_time(dist, speed)
	var a := REFLECT_FAR_RADIUS / pow(CAL_FAR_DIST / ARROW_SPEED, EXPONENT)
	return a * pow(t, EXPONENT)


static func reflect_offset(dist: float, speed: float, rng: RngService) -> Vector2:
	var r := reflect_radius(dist, speed)
	if r <= 0.0 or rng == null:
		return Vector2.ZERO
	var ang := rng.next_float() * TAU
	var rr := r * sqrt(rng.next_float())
	return Vector2(cos(ang) * rr, sin(ang) * rr)


static func reflect_scatter(dest: Vector2, dist: float, speed: float, rng: RngService) -> Vector2:
	return dest + reflect_offset(dist, speed, rng)

