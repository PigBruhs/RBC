# ══════════════════════════════════════════════════════════════════════════════
# Reaper（Boss-3）的**纯决策**：三循环（召唤 → 横扫 → 竖切）+ 每回合前移一格 + 6 格范围被动。
#
# 本文件不碰 Node、不碰 view：只算"该做什么、打哪里、每格挨多少帧"。
# 真正把激光生成出来、把伤害落到单位上，由 battle_scene / GameMaster 执行。
#
# ── 三循环状态放哪 ────────────────────────────────────────────────────────────
# `cycle_step` 存在 **GameMaster** 的一个字典里（`reaper_cycle`，键 = 单位名）——
# 理由：GM 已经是"不属于任何角色的场上状态"的持有者（pending / sentries / death_order），
# 而 Reaper 的循环是**跨回合的调度状态**，不是角色自身属性；放 GM 也不会被 view 遮挡。
#
# ── "距离越远，扫过的格子越多但每格伤害越低" 怎么落地（用户口径）──────────────
# 一条**匀速旋转**的光束 + **固定的每帧伤害**，两个效果同时自然出现：
#   · 距离 d 处，一格张开的角宽 ≈ atan(1/d)（1 格宽的弧长 1 除以半径 d）
#   · 光束角速度恒定 => 该格被覆盖的帧数 ∝ atan(1/d) ≈ 1/d   -> 越远帧数越少 -> 伤害越低
#   · 而 d 处扫过的**格子数** = 弧长 d·θ / 1 = d·θ            -> 越远格数越多
# 所以本文件只提供 `frames_at(dist, total_frames, total_angle)` 这一个换算，
# 伤害 = 帧数 × 每帧伤害（"reaper_laser" = 2 点/帧），**不需要任何按距离查表**。
#
# ── 高度差（用户原话）────────────────────────────────────────────────────────
# 激光**从离地 BASE_HEIGHT=6 格发射，但末端是攻击目标** -> 光束永远是
# "Reaper 身上（离地 6）→ 目标身上（离地 6）"的一条**水平线**；横扫时**终点沿弧线走**。
# ══════════════════════════════════════════════════════════════════════════════
class_name Reaper
extends RefCounted

## 三循环。顺序即数组顺序，`next_step` 就是环形推进。
enum Step { SUMMON, SWEEP, SLICE }
const CYCLE: Array = [Step.SUMMON, Step.SWEEP, Step.SLICE]

## 激光基准高度（与 Laser.BASE_HEIGHT 对齐；激光模块由 mod-sentry-2 建设，这里是打桩期常量）
const BASE_HEIGHT := 6.0

## 横扫：中轴 = "Reaper → 最近敌人"，从中轴一侧扫到另一侧（**从左往右** = 角度从 -half 递增到 +half）
const SWEEP_HALF_DEG := 60.0
const SWEEP_SEC := 2.0

## 竖切：中轴 = "Reaper → 最近敌人"的连线；**固定 ±30°**；"从前向后" = 从**远端扫回近端**
## （定义：以中轴为 0°，光束先指向 +30°（靠外/远侧），匀速扫到 -30°（靠内/近侧）。
##  选"远→近"是因为敌人多在远处，先扫到的应该是它所在的那一层，视觉上像一刀切下来。）
const SLICE_HALF_DEG := 30.0
const SLICE_SEC := 1.6

## 帧率与帧伤（与 Laser 的 "reaper_laser" 约定一致：2 点/帧）
const FRAME_HZ := 60.0
const FRAME_DMG_MILLI := 2000

## 攻击前预警：环变红多久（用户口径：2 秒）
const WARN_SEC := 2.0

## 范围被动：6 格内每回合 20 点护甲 + 10 点**物理**力量（GM 在回合边界执行）
const PASSIVE_RANGE := 6.0
const PASSIVE_ARMOR_MILLI := 20000
const PASSIVE_POWER_MILLI := 10000
const PASSIVE_POWER_POINTS := 10          # Combat.opts 收的是**点**


static func step_name(s: int) -> String:
	match s:
		Step.SUMMON: return "召唤"
		Step.SWEEP: return "横扫"
		Step.SLICE: return "竖切"
	return "?"


## 环形推进：召唤 → 横扫 → 竖切 → 召唤 …
static func next_step(s: int) -> int:
	var i := CYCLE.find(s)
	return CYCLE[(i + 1) % CYCLE.size()]


## 距离 d 处一格被光束覆盖的**帧数**（"越远格数越多、每格伤害越低"的唯一换算）
static func frames_at(dist: float, total_frames: float, total_angle_deg: float) -> float:
	var ang := atan2(1.0, maxf(dist, 0.001))                       # 该格张开的角度（弧度）
	var total := deg_to_rad(maxf(total_angle_deg, 0.001))
	return ang / total * total_frames


## 该格吃到的伤害（千分比）
static func cell_damage_milli(dist: float, total_frames: float, total_angle_deg: float) -> int:
	return int(round(frames_at(dist, total_frames, total_angle_deg) * FRAME_DMG_MILLI))


# ══════════════════════════════════════════════════════════════════════════════
# 目标与移动
# ══════════════════════════════════════════════════════════════════════════════

## 最近的敌人（用浮点真实距离，和哨兵判界同一套口径）
static func nearest_enemy(reaper: Unit, units: Array[Unit]) -> Unit:
	var best: Unit = null
	var best_d := 1e18
	var rp := GridMath.unit_pos(reaper)
	for u in units:
		if u == null or not u.is_alive() or u == reaper:
			continue
		if u.side == reaper.side:
			continue
		var d: float = rp.distance_to(GridMath.unit_pos(u))
		if d < best_d:
			best_d = d
			best = u
	return best


## 每回合"向前移动一格"：朝最近敌人靠一格。
## ⚠ body_r = 3 的大块头：**不许压进任何单位的格子**（含友方召唤物）。
## 返回 {cell: Vector2i（想去/能去的格）, moved: bool, blocked: String（没动的原因）}
static func plan_forward(reaper: Unit, units: Array[Unit]) -> Dictionary:
	var tgt := nearest_enemy(reaper, units)
	if tgt == null:
		return {"cell": reaper.cell, "moved": false, "blocked": "场上没有敌人"}
	var rp := GridMath.unit_pos(reaper)
	var tp := GridMath.unit_pos(tgt)
	var d := tp - rp
	if d.length() < 0.001:
		return {"cell": reaper.cell, "moved": false, "blocked": "已经贴脸"}
	# 朝目标取"主轴那一格"（move=1）：谁的变化量大就先走谁，避免斜着跳
	var step := Vector2i.ZERO
	if absf(d.x) >= absf(d.y):
		step.x = signi(int(round(d.x)))
	else:
		step.y = signi(int(round(d.y)))
	var want := reaper.cell + step
	# 目标格被占（任何活着的单位）-> 原地不动（用户口径：被占就停，别硬挤）
	for u in units:
		if u == null or not u.is_alive() or u == reaper:
			continue
		if u.cell == want:
			return {"cell": reaper.cell, "moved": false,
					"blocked": "前方格 %s 被 %s 占着（body_r=3 不硬挤）" % [str(want), u.name]}
	if not Level.in_play(want):
		return {"cell": reaper.cell, "moved": false, "blocked": "前方格 %s 出界" % str(want)}
	return {"cell": want, "moved": true, "blocked": ""}


# ══════════════════════════════════════════════════════════════════════════════
# 召唤
# ══════════════════════════════════════════════════════════════════════════════

## 两种配置（二选一，由调用方给 seed 决定；确定性）
##   甲：两个【没有技能的近战】+ 一个【带哨兵技能的远程】
##       —— 用现成花名册：Gerald 是唯一近战（无主动技能），公主·左/右 带 always_sentry（哨兵被动）。
##       ⚠ 不能新建角色数据行（`unit_data.gd` 不在本任务写区），所以复用现成单位再改阵营。
##   乙：三名【萨尼铁塔】
const SUMMON_KITS := [
	{"id": "A", "desc": "2 近战(无技能) + 1 远程(带哨兵)",
	 "names": ["Gerald", "Gerald", "公主·左"]},
	{"id": "B", "desc": "3 名萨尼铁塔",
	 "names": ["萨尼铁塔", "萨尼铁塔", "萨尼铁塔"]},
]


## 挑召唤位：**确定性**螺旋外扩，从 Reaper 周围一圈开始找空格
## （不用字典/数组的迭代顺序，避免"每次跑落点都不一样"）
static func summon_cells(reaper: Unit, units: Array[Unit], count: int) -> Array[Vector2i]:
	var occupied := {}
	for u in units:
		if u != null and u.is_alive():
			occupied[u.cell] = true
	var out: Array[Vector2i] = []
	var r := 1
	while out.size() < count and r <= 12:
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var c := reaper.cell + Vector2i(dx, dy)
				if occupied.has(c) or not Level.in_play(c):
					continue
				occupied[c] = true
				out.append(c)
				if out.size() >= count:
					break
			if out.size() >= count:
				break
		r += 1
	return out


# ══════════════════════════════════════════════════════════════════════════════
# 激光（打桩：只算起终点与帧数，不真的发射）
# ══════════════════════════════════════════════════════════════════════════════

## 一条光束的规格：**斜的光束** —— 起点在 Reaper 蓝环（离地 BASE_HEIGHT=6），
## **终点落在目标身上**（`Targeting.aim_height` = 身体高度，地面单位 ≈ 0.5）。
## ⚠️ 这条是用户原话"从离地 6 格处发射，但末端是攻击目标"的直接落法；
##    两端都放 y=6 会变成水平光束，而 laser.gd 的 `hits_unit` 是**三维**判定
##    （线段 vs 单位竖直圆柱）→ 对地面单位 0 帧 0 伤害（docs-keeper 探针实测锁过）。
static func beam_spec(reaper: Unit, target_pos: Vector2, angle_deg: float,
		total_frames: float, total_angle_deg: float, tgt: Unit = null) -> Dictionary:
	var from := Vector3(GridMath.unit_pos(reaper).x, BASE_HEIGHT, GridMath.unit_pos(reaper).y)
	var dir := target_pos - GridMath.unit_pos(reaper)
	var base := dir.angle()
	var a := base + deg_to_rad(angle_deg)
	# 终点：沿该角度走到目标距离再往外一点（"末端是攻击目标"）
	var reach: float = maxf(dir.length(), 1.0)
	var to2 := GridMath.unit_pos(reaper) + Vector2(cos(a), sin(a)) * reach
	var end_y: float = BASE_HEIGHT
	if tgt != null:
		end_y = Targeting.aim_height(tgt)          # 落到目标身体上（斜射）
	var to := Vector3(to2.x, end_y, to2.y)
	var dist := to2.distance_to(GridMath.unit_pos(reaper))
	return {"from": from, "to": to, "frames": int(total_frames), "angle_deg": angle_deg,
			"dist": dist, "dmg_milli": cell_damage_milli(dist, total_frames, total_angle_deg)}


## 横扫：中轴 = Reaper→最近敌人，从 -half 递增到 +half（从左往右），匀速
static func sweep_specs(reaper: Unit, target_pos: Vector2, steps: int, tgt: Unit = null) -> Array:
	var out := []
	var total_frames := SWEEP_SEC * FRAME_HZ
	for i in steps:
		var t := float(i) / float(maxi(steps - 1, 1))
		var ang := lerpf(-SWEEP_HALF_DEG, SWEEP_HALF_DEG, t)
		out.append(beam_spec(reaper, target_pos, ang, total_frames, SWEEP_HALF_DEG * 2.0, tgt))
	return out


## 竖切：中轴 = Reaper→最近敌人连线；固定 ±30°；**从远侧(+half)扫回近侧(-half)**
static func slice_specs(reaper: Unit, target_pos: Vector2, steps: int, tgt: Unit = null) -> Array:
	var out := []
	var total_frames := SLICE_SEC * FRAME_HZ
	for i in steps:
		var t := float(i) / float(maxi(steps - 1, 1))
		var ang := lerpf(SLICE_HALF_DEG, -SLICE_HALF_DEG, t)      # 远 → 近
		out.append(beam_spec(reaper, target_pos, ang, total_frames, SLICE_HALF_DEG * 2.0, tgt))
	return out


# ══════════════════════════════════════════════════════════════════════════════
# 6 格范围被动（GM 在**每个回合边界**执行，不在 Reaper 的行动回合里）
# ══════════════════════════════════════════════════════════════════════════════

## 判定口径：**中心到中心的浮点距离 ≤ 6**（**不把 body_r=3 算进去**）。
## 理由：a) 与哨兵判界完全同一套口径（`GridMath.unit_pos` + 浮点距离），可预测、好解释；
##       b) 若把 3 算进去，实际生效半径会变成 9，玩家看到的"6 格"和实际不符（用户口径写的是 6 格）。
##
## **第 100 轮口径改动**：**只对敌对角色触发** —— Reaper 是敌方，所以只打玩家方（含公主/老国王，
## 它们也是玩家方角色、也是可被打的目标）。**不再伤自己的召唤物**（上一轮是"不分敌我"）。
static func passive_targets(reaper: Unit, units: Array[Unit]) -> Array[Unit]:
	var out: Array[Unit] = []
	if reaper == null or not reaper.is_alive():
		return out
	var rp := GridMath.unit_pos(reaper)
	for u in units:
		if u == null or not u.is_alive() or u == reaper:
			continue
		if u.side == reaper.side:                 # 只打敌对角色（跳过自己的召唤物）
			continue
		if rp.distance_to(GridMath.unit_pos(u)) <= PASSIVE_RANGE:
			out.append(u)
	return out


## 物理力量伤害的 opts（第 100 轮：6 格被动是**物理伤害**）。
## 照 `Combat.opts` 的 shapes 走：先减护甲、再过物抗、**有命中判定**。
## ⚠ 物理线可能"未命中"（`Rules.resolve` 的 ROLL 分支）—— 这是固有行为，不绕开公式。
## 破甲给 0：这条被动只有力量那一段。
static func passive_opts(rng: RngService) -> Dictionary:
	return Combat.opts({"power": PASSIVE_POWER_POINTS, "armor_break": 0, "rng": rng})
