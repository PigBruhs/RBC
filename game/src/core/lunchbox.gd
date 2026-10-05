# ══════════════════════════════════════════════════════════════════════════════
# 轮式齐射午餐盒（第 104 轮 · 新角色）—— **纯决策**，不碰 Node、可无头测试
#
# 用户口径（逐字，按段落）：
#   · 车顶左手边一个 0.3 格高支架支起来的正六边形棱柱；**引入方向机和高低机**
#     → "棱柱永远在指向要射击的方向后才能发射子弹"；"方向机和高低机速度决定从当前的
#        theta 和 phi 变化到目标航向角和俯仰角的延迟"；"每次射击完毕后角度都保留在
#        最后一次射击时的角度"；方向机 10°/s、高低机 5°/s；**最终角度也要有限制**
#   · 齐射：一轮 6 发、散布 1 格、间隔 133ms；**每 12 轮冷却 3 秒**；棱柱逐渐发红，
#     第 12 波最红，冷却 1 秒后恢复黑色
#   · 普攻 24 格；瞄准时以"车→目标"连线为中轴在 **-10°~+10°** 之间左右摇动，共 **12 波 72 发**
#   · 哨兵模式 24 格：**索敌队列只有一个位置**（锁第一个进范围的，直到它**停下**或被摧毁
#     才转火）；每个目标有**双机延迟 + 固定 500ms 反应延迟**；没有提前量，靠 1 格散布
#   · 哨兵模式**每 12 轮仍要冷却 3 秒**；**没满 12 轮就停火 500ms 则开始散热**，
#     **每 250ms 减 1 轮**（= 4 轮/秒）直到恢复能连发 12 轮
#
# 本文件只算"该不该转、转到哪、能不能开火、热量多少"；
# 真正的子弹生成/建模/动画在 `view/lunchbox_model.gd` 与 `view/battle_scene.gd`。
# ══════════════════════════════════════════════════════════════════════════════
class_name Lunchbox
extends RefCounted

# ── 双机（方向机 / 高低机）───────────────────────────────────────────────────
## 方向机转速（度/秒，用户口径：先给 10，试了再调）
const TRAVERSE_DEG_PER_SEC := 10.0
## 高低机转速（度/秒，用户口径：先给 5）
const ELEV_DEG_PER_SEC := 5.0

## 最低俯角（度，负 = 压炮口向下）。**Lead 已按用户"你来决定"定好 -15°**：
##   枪口离地 1.3 格、炮塔横向偏 0.6 格 -> 横移 0.6 格处高度 = 1.3 - 0.6·tan15° = 1.14 格 > 车顶 1.0 ✅
##   -25° 时 1.02 格（擦车顶）、-40° 时 0.80 格（打到自己）-> 取 -15°。
const PHI_MIN_DEG := -15.0
## 最高仰角 60°：足够打到 1 格外贴脸目标（atan(1.3/1) ≈ 52°）
const PHI_MAX_DEG := 60.0

## 枪口离地高度（格）——建模里炮塔轴心在 1.3 格
const MUZZLE_Y := 1.3
## 炮塔轴心相对车体中心的横向偏移（格，左手边 0.6）
const TURRET_SIDE_OFFSET := 0.6

# ── 齐射（普攻）─────────────────────────────────────────────────────────────
const SALVO_WAVES := 12              # 一次普攻 12 波（用户口径）
const SALVO_PER_WAVE := 6            # 每波 6 发
const SALVO_TOTAL := 72              # 12 × 6 = 72 发
const SALVO_GAP := 0.133             # 波间隔 133ms（用户口径）
const SALVO_COOLDOWN := 3.0          # 每 12 轮冷却 3 秒
const SALVO_SPREAD_R := 1.0          # 散布 1 格
const SALVO_SWING_DEG := 10.0        # 瞄准时方向机左右摇动 ±10°（以"车→目标"连线为中轴）
const SALVO_RANGE := 24.0            # 普攻范围 24 格

## 棱柱变红：第 `SALVO_WAVES` 波最红（heat_ratio = 1），冷却开始 1 秒后恢复黑
const HEAT_RESET_SEC := 1.0

# ── 哨兵模式 ────────────────────────────────────────────────────────────────
const SENTRY_RANGE := 24.0           # 哨兵范围 24 格（用户口径）
const REACT_SEC := 0.5               # 对准后固定 500ms 反应延迟
## 散热：停火 500ms 后开始，**每 250ms 减 1 轮**（= 4 轮/秒）
const COOL_IDLE_SEC := 0.5
const COOL_TICK_SEC := 0.25
const COOL_PER_TICK := 1


## 车体的瞄准状态（双机）：theta = 水平朝向（度，绕 +y），phi = 俯仰（度，正 = 抬）。
## 初值 0/0 = 朝 +y、水平。
class Aim:
	var theta: float = 0.0
	var phi: float = 0.0

	func duplicate_aim() -> Aim:
		var a := Aim.new()
		a.theta = theta
		a.phi = phi
		return a


## 从 (theta, phi) 平滑转到 (want_theta, want_phi)，**两轴同时动**（用户硬约束：
## "高低机和方向机可以一起调"，不要串行）。
## 返回是否已经到位（到位后调用方才允许开火）。
## `traverse_deg` / `elev_deg` 每帧的可用角度 = 转速 × dt（也可以传非均匀值做测试）。
static func step_aim(aim: Aim, want_theta: float, want_phi: float, dt: float,
		traverse_deg: float = -1.0, elev_deg: float = -1.0) -> bool:
	var t_step := traverse_deg if traverse_deg >= 0.0 else TRAVERSE_DEG_PER_SEC * dt
	var e_step := elev_deg if elev_deg >= 0.0 else ELEV_DEG_PER_SEC * dt
	# 方向机：**走最短弧**（+179° 与 -179° 只差 2°），不然会绕一大圈
	var d_theta := wrapf(want_theta - aim.theta, -180.0, 180.0)
	aim.theta = wrapf(aim.theta + clampf(d_theta, -t_step, t_step), -180.0, 180.0)
	var want_phi_c := clampf(want_phi, PHI_MIN_DEG, PHI_MAX_DEG)
	aim.phi = clampf(aim.phi + clampf(want_phi_c - aim.phi, -e_step, e_step),
		PHI_MIN_DEG, PHI_MAX_DEG)
	return absf(wrapf(want_theta - aim.theta, -180.0, 180.0)) < 0.01 \
		and absf(want_phi_c - aim.phi) < 0.01


## 从车指向目标所需的 (theta, phi)：枪口在 1.3 格，目标取身体中心高度。
## theta 用**世界坐标**角度（0° = +y 方向，顺时针为正 —— 与 Vector2.angle() 同一套）。
static func aim_to(from_pos: Vector2, from_y: float, to_pos: Vector2, to_y: float) -> Array:
	var d := to_pos - from_pos
	var theta := rad_to_deg(d.angle())
	var horiz := maxf(d.length(), 0.0001)
	var phi := rad_to_deg(atan2(to_y - from_y, horiz))
	return [theta, phi]


## 双机从当前角度转到"能打到目标"需要多少秒（= 两轴里慢的那一个）——
## 哨兵模式的"反应延迟"就是在这之上再加 `REACT_SEC`。
static func aim_seconds(aim: Aim, want_theta: float, want_phi: float) -> float:
	var d_theta := absf(wrapf(want_theta - aim.theta, -180.0, 180.0))
	var want_phi_c := clampf(want_phi, PHI_MIN_DEG, PHI_MAX_DEG)
	var d_phi := absf(want_phi_c - aim.phi)
	return maxf(d_theta / TRAVERSE_DEG_PER_SEC, d_phi / ELEV_DEG_PER_SEC)


# ── 热量（连发轮数）─────────────────────────────────────────────────────────
## 已连发的轮数（0..SALVO_WAVES）。打满 12 轮要冷却 3 秒；没打满就停火 500ms 开始散热。
class Heat:
	var rounds: int = 0                  # 已连发轮数
	var idle: float = 0.0                # 停火计时
	var cool_left: float = 0.0           # 冷却剩余（打满 12 轮时生效）
	var red_sec: float = 0.0             # 距"上次开火"过了多久（棱柱颜色用）
	var cool_done: int = 0               # **已经散掉的轮数**（防止每帧重复扣）

	func ratio() -> float:
		return clampf(float(rounds) / float(SALVO_WAVES), 0.0, 1.0)


## 记一轮开火：轮数 +1，停火计时清零。
static func heat_fire(h: Heat) -> void:
	h.rounds = mini(h.rounds + 1, SALVO_WAVES)
	h.idle = 0.0
	h.red_sec = 0.0
	h.cool_done = 0


## 打满 12 轮后进入 3 秒冷却（用户口径：每 12 轮冷却 3 秒）。
static func heat_start_cooldown(h: Heat) -> void:
	h.cool_left = SALVO_COOLDOWN
	h.rounds = 0


## 每帧推进热量：冷却 -> 停火 500ms 后每 250ms 减 1 轮。返回这一帧減了几轮（测试用）。
static func heat_tick(h: Heat, dt: float) -> int:
	h.red_sec += dt
	if h.cool_left > 0.0:
		h.cool_left = maxf(0.0, h.cool_left - dt)
		# 冷却期间棱柱 1 秒后恢复黑色（用户口径：冷却 1 秒后恢复黑色）
		if h.cool_left <= SALVO_COOLDOWN - HEAT_RESET_SEC:
			h.rounds = 0
		return 0
	h.idle += dt
	if h.idle < COOL_IDLE_SEC:
		return 0
	# 散热：每攒满 250ms 减 1 轮。**用"该散几轮 - 已经散了几轮"**，
	# 不能每帧都拿累计值去扣（那样会一帧扣一轮，6 轮 0.1 秒就散光了）。
	var want := int(floor((h.idle - COOL_IDLE_SEC) / COOL_TICK_SEC))
	var step := want - h.cool_done
	if step <= 0:
		return 0
	h.cool_done = want
	var before := h.rounds
	h.rounds = maxi(0, h.rounds - step * COOL_PER_TICK)
	return before - h.rounds


## 现在能不能开火：不在冷却里，且轮数没打满。
static func can_fire(h: Heat) -> bool:
	return h.cool_left <= 0.0 and h.rounds < SALVO_WAVES


## 棱柱颜色比例（0 = 黑，1 = 最红）：连发轮数比例；冷却满 1 秒后归 0。
static func heat_ratio(h: Heat) -> float:
	if h.cool_left > 0.0:
		return 0.0 if h.cool_left <= SALVO_COOLDOWN - HEAT_RESET_SEC else 1.0
	return h.ratio()


# ── 哨兵：单目标锁定（索敌队列只有一个位置）───────────────────────────────
## 用户口径："车的索敌队列只有一个位置，即它会瞄准第一个进入范围的目标直到目标停下
## 或被摧毁，然后才会转火到第二个目标"。
## `u.tags["lb_target"]` 存锁定的目标名（用名字而不是实例，便于探针观察）。
class Sentry:
	var target_name: String = ""
	var react: float = 0.0               # 反应延迟计时（对准之后才开始走）
	var aimed: bool = false              # 双机是否已到目标角度

	## 每帧：返回"这一帧该不该开火"（由调用方生成子弹）。
	## moving = 目标这一帧是否在移动（停下 = !moving；停下才允许转火，见 lock_target）。
	func tick(dt: float, has_target: bool, at_aim: bool) -> bool:
		if not has_target:
			aimed = false
			react = 0.0
			return false
		if not at_aim:
			aimed = false
			react = 0.0                  # 目标动了 -> 重新对准，反应延迟重新计
			return false
		aimed = true
		react += dt
		if react >= REACT_SEC:
			react = 0.0                  # 开火后重新计（下一次瞄准还要再等 500ms）
			return true
		return false


## 选目标：**第一个进入 24 格范围的目标**，锁住不放；只有它**停下**或**被摧毁**才换下一个。
## `stopped` 由调用方给（battle_scene 判断"这一帧目标没有移动"）。
static func pick_sentry_target(current: String, current_alive: bool, current_stopped: bool,
		in_range_names: Array) -> String:
	if current != "" and current_alive and not current_stopped:
		return current                      # 还在动 -> 继续锁着它（哪怕后面又进来一个）
	if current != "" and current_alive and current_stopped:
		return ""                           # 它停下了 -> 放掉，下一帧重新挑第一个
	if current != "" and not current_alive:
		return ""                           # 它被摧毁了 -> 放掉
	return "" if in_range_names.is_empty() else String(in_range_names[0])


# ── 扫射（普攻）：以"车→目标"连线为中轴左右摇动 ─────────────────────────────
## 第 i 波（0..11）的方向机角度偏移：**-10° -> +10° 来回摇**（不是单向扫），
## 用户口径"一边左右摇动方向机一面射击"。
## 6 个来回（每 2 波换向）比单向扫更像"摇动"，且 12 波正好回到中轴。
static func swing_deg(i: int) -> float:
	var half := float(SALVO_WAVES) / 2.0
	var k := (float(i % int(half * 2.0)) / half)          # 0..2
	var tri := k if k <= 1.0 else 2.0 - k                 # 0->1->0 三角波
	return lerpf(-SALVO_SWING_DEG, SALVO_SWING_DEG, tri)


## 第 i 波的朝向角（世界坐标角度）：目标方向 + 摇动偏移。
static func wave_theta(base_theta: float, i: int) -> float:
	return wrapf(base_theta + swing_deg(i), -180.0, 180.0)


## 打这一波需要的仰角：**要让子弹真的能打到对面** —— 按"枪口 -> 目标身体中心"算，
## 再叠加摇动带来的横向偏移（摇出去之后距离变长，仰角要跟着抬一点）。
static func wave_phi(base_theta: float, i: int, dist: float, muzzle_y: float,
		target_y: float) -> float:
	var off := deg_to_rad(swing_deg(i))
	var d := Vector2(cos(deg_to_rad(base_theta)), sin(deg_to_rad(base_theta))) * dist
	var swung := d.rotated(off)
	var horiz := maxf(swung.length(), 0.0001)
	return rad_to_deg(atan2(target_y - muzzle_y, horiz))


## 散布 1 格：在落点周围半径 1 格内取一个随机偏移（用项目 RngService，可复现）。
static func spread_offset(rng: RngService) -> Vector2:
	var a := rng.next_float() * TAU
	var r := sqrt(rng.next_float()) * SALVO_SPREAD_R      # 面积均匀的圆盘
	return Vector2(cos(a), sin(a)) * r
