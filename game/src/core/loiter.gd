# ══════════════════════════════════════════════════════════════════════════════
# 巡飞弹 + 巡飞弹发射器（用户口径第 90 轮）
#
# 【巡飞弹】炮弹类飞行物：
#   · 不受重力、**定高 1.5 格**、**恒速 3 格/秒**
#   · 模型与碰撞体积 = **直径一格的球**（半径 0.5）
#   · 造伤范围 = **直径两格的球**（半径 1.0）：40 破甲 + 40 力量（炮击口径，无视 50% 物抗）
#   · **近炸引信**：造伤范围内出现任何角色 / 沙盒元素就引爆
#   · 飞满 **32 格**自动引爆
#   · 方向由玩家用 **Q/E** 制导（水平面内的转向，速度大小不变）
#
# 【发射器】沙盒元素：射程 12 格，参考哨兵但**只打"进入范围的正在移动的角色"**，
#   **每 5 个回合边界**只能发射一枚（时钟用 GM 的 turn_count）。
#   发射方向 = 以"发射器 -> 目标"连线为中心线、左右各 45° 内随机一个角度。
#
# 【转向手感】用户口径：按得越久转得越快、有上下限、带惯性。
#   · want_rate(hold)  = 按住时长 -> 目标角速度（度/秒），下限 TURN_MIN、上限 TURN_MAX
#   · step_rate(...)   = 当前角速度带惯性逼近目标（k = TURN_INERTIA），松手后滑回 0
#   · steer(...)       = 在【屏幕平面】上按角速度转（右转 = 屏幕上顺时针，和相机 yaw 无关）
# ══════════════════════════════════════════════════════════════════════════════
class_name Loiter
extends RefCounted

# ── 弹体 ──
const SPEED := 3.0                 # 格/秒（恒定，只改方向）
const HEIGHT := 1.5                # 定高（不受重力）
const MAX_DIST := 32.0             # 飞满这么远自动引爆
const BODY_R := 0.5                # 模型/碰撞：直径一格的球
const BLAST_R := 1.0               # 造伤：直径两格的球
const BREAK := 40.0                # 破甲
const POWER := 40.0                # 力量
const IGNORE_RES := 0.5            # 炮击：无视 50% 物抗

# ── 制导（Q/E）──
const TURN_MIN := 25.0             # 刚按下时的角速度（度/秒）：转弯半径 6.9 格
const TURN_RAMP := 55.0            # 每按住 1 秒增加的角速度（度/秒²）
const TURN_MAX := 160.0            # 上限（度/秒）：转弯半径 1.1 格
const TURN_INERTIA := 3.5          # 惯性：当前角速度向目标逼近的速率（1/s），越大越跟手

# ── 发射器 ──
const LAUNCHER_NAME := "巡飞弹发射器"
const LAUNCH_RANGE := 12.0         # 射程（格）
const LAUNCH_COOLDOWN_TURNS := 5   # 每 5 个回合边界一枚（GM 计时）
const CONE_DEG := 45.0             # 初始方向：以"发射器 -> 目标"为中心线，左右各 45° 内随机
const SAMPLE_HZ := 12.0            # 每帧检测太浪费，按这个频率采样
const MOVE_EPS := 0.05             # 位移超过这么多就算"在动"（格）


static func is_launcher(pl: Placeable) -> bool:
	return pl != null and pl.name.begins_with(LAUNCHER_NAME)


## 按住时长 -> 目标角速度（度/秒，无符号）。刚开始转得慢，按久了转得快，有上下限。
static func want_rate(hold: float) -> float:
	return clampf(TURN_MIN + TURN_RAMP * maxf(0.0, hold), TURN_MIN, TURN_MAX)


## 带惯性：当前角速度向目标逼近（want = 0 表示松手 -> 慢慢滑回 0）
static func step_rate(cur: float, want: float, dt: float) -> float:
	var k := clampf(TURN_INERTIA * dt, 0.0, 1.0)
	return cur + (want - cur) * k


## 在屏幕平面上转 heading（弧度）。
## right / down = 相机在水平面上的"屏幕右 / 屏幕下"两个方向（单位向量，世界 xz 平面）。
## rate_deg > 0 = 屏幕上顺时针（也就是"向右转"）。
static func steer(heading: float, right: Vector2, down: Vector2, rate_deg: float, dt: float) -> float:
	var hv := Vector2(cos(heading), sin(heading))
	var sx := hv.dot(right)
	var sy := hv.dot(down)
	var ang := atan2(sy, sx) + deg_to_rad(rate_deg) * dt
	var out := right * cos(ang) + down * sin(ang)
	return atan2(out.y, out.x)


## 相机在水平面上的屏幕轴：[右, 下]（世界 xz 平面上的单位向量）
static func screen_axes(cam_yaw_deg: float) -> Array[Vector2]:
	var th := deg_to_rad(cam_yaw_deg)
	return [Vector2(cos(th), -sin(th)), Vector2(sin(th), cos(th))]


## 初始发射方向：目标方向 ±CONE_DEG 内随机（rng 是 RngService）
static func launch_heading(from: Vector2, to: Vector2, rng) -> float:
	var base := (to - from)
	var ang: float = base.angle() if base.length() > 0.0001 else 0.0
	var off: float = (rng.next_float() * 2.0 - 1.0) * deg_to_rad(CONE_DEG)
	return ang + off


## 伤害参数（发射那一刻的快照；attacker 由调用方给，null = 无主）
static func opts(rng) -> Dictionary:
	return Combat.opts({
		"power": int(POWER * 1000.0),
		"armor_break": int(BREAK * 1000.0),
		"ignore_res": IGNORE_RES,
		"rng": rng,
	})


## 巡飞弹会不会打到这个位置（近炸引信 / 造伤范围用的是同一个球）
static func ball_touches_unit(ctr: Vector3, u: Unit) -> bool:
	return Targeting.sphere_hits_body(ctr, BLAST_R, u.cell, Damage.BODY_R, Damage.BODY_H, u.body_h())


## 沙盒元素：只按"沾到格子"判定（道具没有高度轴）
static func ball_touches_placeable(ctr: Vector3, pl: Placeable) -> bool:
	return Targeting.circle_touches_cell(Vector2(ctr.x, ctr.z), pl.cell, BLAST_R)
