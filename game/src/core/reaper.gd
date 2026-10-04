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

## 激光基准高度（= 蓝环离地高度，与 Laser.BASE_HEIGHT 对齐）
const BASE_HEIGHT := 6.0

## 横扫：中轴 = "Reaper → 最近敌人"，落点从左扫到右；总时长固定 2 秒。
## ⚠️ 旧的 `SWEEP_HALF_DEG = 60`（固定半角）**已删除** —— 第 100 轮改成**固定弧长**：
##    单侧弧长 ARC_HALF_LEN = 3.5 格（R=40 时左右合计 7 格），所以角度随距离变小。
const SWEEP_SEC := 2.0

## 竖切：中轴同上，落点沿中轴 **从远侧扫回近侧**；总时长固定 1.6 秒。
## ⚠️ 旧的 `SLICE_HALF_DEG = 30`（固定半角）同样已删除（理由同上）。
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
# 动态光柱（第 100 轮用户口径：**一根连续存在的光柱，落点沿弧移动**）
#
# 用户的否定意见："reaper 的激光完全不应该是现在这种**静态超级大范围**的，而是
# **动态的一个光柱从一个角度向另一个角度移动**"。
# 所以旧的 `sweep_specs()/slice_specs()`（N 条离散静态光束）**已删除**，换成：
#   · **同一根 beam** 活满整个动画（`view/laser_beam.gd` 每帧按 `arc_point()` 重算落点）
#   · 落点 E(t) 沿"以 P 为圆心、R = |P - T| 为半径的圆"的一小段移动：
#     T 左边一点 → 经过 T → T 右边一点
#   · 光柱直径 0.5 格（判定半径 `Laser.HIT_R = 0.25`）
#   · **弧长固定**：以 R = 40 格为基准左右合计 ≈ 7 格 → 半角 = 3.5 / R（**角度随距离变小**）
#   · 角速度恒定、总时长恒定（SWEEP_SEC / SLICE_SEC）
#   · 伤害 = 动画期间被光柱碰到的帧数 × 每帧伤害（有友伤：不做阵营过滤）
#
# 切线平移 vs 真弧：**这里用真弧**（落点始终落在半径 R 的圆上，与用户"半径为 reaper
# 到目标的距离的圆的一小部分"逐字一致，误差 0）。切线平移只是它在小角度下的近似
# （R=40 时两者相差 < 0.1 格，R=4 时差 1.5 格，所以近距离真弧更稳）。
# ══════════════════════════════════════════════════════════════════════════════

## 落点单侧扫过的**弧长**（格）：R = 40 时左右合计 2×3.5 = 7 格（用户建议值）
const ARC_HALF_LEN := 3.5
## 近距离保护①：单侧半角上限。R 小的时候 3.5/R 会爆炸（R=1 时 200°），
## 所以角度封顶 30° —— 近距离扫过的弧长自然变短（R=4 时约 4.2 格），但不会甩一整圈。
const ARC_MAX_HALF_DEG := 30.0
## 近距离保护②：R 小于它就直接把落点钉在 T 上（不扫）—— 贴脸时"扫过 7 格"没有意义。
const ARC_MIN_R := 1.0


## 一次动态光柱的规格（**一根 beam** 用它活满整个动画）。
##   mode = "arc"    -> 横扫：落点在圆上按角度扫（左 → 右）
##   mode = "radial" -> 竖切：落点沿中轴平移（**远侧 → 近侧**，即从 T 外侧扫回 T 内侧）
## 返回的字段里 `from` / `to` / `dist` / `frames` / `dmg_milli` / `angle_deg` 是给探针看的
## 兼容字段（`to` = t=0 的落点）；弧形参数在 `center / pivot / axis / r / half_angle / half_len / sec`。
static func beam_arc_spec(reaper: Unit, target_pos: Vector2, tgt: Unit = null,
		slice: bool = false) -> Dictionary:
	var p := GridMath.unit_pos(reaper)
	var axis := target_pos - p
	var r := axis.length()
	if axis.length() < 0.0001:
		axis = Vector2(0.0, 1.0)
	else:
		axis = axis.normalized()
	var sec: float = SLICE_SEC if slice else SWEEP_SEC
	# 半角：固定弧长 3.5 格 / R，再被 ARC_MAX_HALF_DEG 封顶（近距离保护①）
	var half_angle: float = ARC_HALF_LEN / maxf(r, ARC_MIN_R)
	half_angle = minf(half_angle, deg_to_rad(ARC_MAX_HALF_DEG))
	if r < ARC_MIN_R:
		half_angle = 0.0                     # 近距离保护②：贴脸 -> 落点钉在 T 上
	var end_y: float = BASE_HEIGHT
	if tgt != null:
		end_y = Targeting.aim_height(tgt)     # 末端落在目标身上（斜射，不是水平线）
	var spec := {
		"mode": "radial" if slice else "arc",
		"from": Vector3(p.x, BASE_HEIGHT, p.y),
		"center": target_pos,                # 落点所在圆/中轴的参考点 T
		"pivot": p,                          # 圆心 P.xz
		"axis": axis,                        # 单位：P -> T
		"tangent": Vector2(-axis.y, axis.x), # 单位：中轴的左手法线（横扫的"左→右"方向）
		"r": r,
		"half_angle": half_angle,
		"half_len": r * half_angle,          # 单侧弧长（格）—— 日志/探针用
		"sec": sec,
		"frames": int(sec * FRAME_HZ),
		"dist": r,
		"angle_deg": rad_to_deg(half_angle),
		"dmg_milli": cell_damage_milli(maxf(r, 1.0), sec * FRAME_HZ, rad_to_deg(half_angle) * 2.0),
		"slice": slice,
		"target_name": tgt.name if tgt != null else "",
		"end_y": end_y,
	}
	spec["to"] = arc_point(spec, 0.0)
	return spec


## 动画进度 t ∈ [0,1] 时的落点 E(t)（3D；y 恒为 `end_y` = 目标身体高度）。
## · arc    ：**以 P（Reaper 蓝环）为圆心、R 为半径**的圆上取角度
##            `angle(T-P) + lerp(-half, +half, t)` —— 角速度恒定；
##            t = 0.5 时角度正好是中轴 -> 落点正好落在 T 上（左 → 目标 → 右）
## · radial ：沿中轴的偏移 u = lerp(+half_len, -half_len, t) —— **远侧 → 近侧**，匀速
static func arc_point(spec: Dictionary, t: float) -> Vector3:
	var k := clampf(t, 0.0, 1.0)
	var center: Vector2 = spec["center"]      # T（中轴上的参考点；t=0.5 时落点在这）
	var pivot: Vector2 = spec["pivot"]        # P.xz（圆弧的圆心）
	var axis: Vector2 = spec["axis"]
	var r: float = float(spec["r"])
	var half: float = float(spec["half_angle"])
	var pos := center
	if String(spec.get("mode", "arc")) == "radial":
		var u := lerpf(float(spec["half_len"]), -float(spec["half_len"]), k)
		pos = center + axis * u
	else:
		var ang := axis.angle() + lerpf(-half, half, k)
		pos = pivot + Vector2(cos(ang), sin(ang)) * r
	return Vector3(pos.x, float(spec["end_y"]), pos.y)


## 落点在 t 时刻相对中轴的偏移量（格）—— 探针核对"扫过多少格"用
static func arc_offset(spec: Dictionary, t: float) -> float:
	var k := clampf(t, 0.0, 1.0)
	if String(spec.get("mode", "arc")) == "radial":
		return lerpf(float(spec["half_len"]), -float(spec["half_len"]), k)
	return float(spec["half_angle"]) * (2.0 * k - 1.0) * float(spec["r"])


## 注：旧的 `sweep_specs()` / `slice_specs()`（N 条离散静态光束）**已删除** ——
## 用户明确否定了那种"静态超级大范围"的效果，改成上面的 `beam_arc_spec()` + `arc_point()`。
## 上方 `frames_at()` / `cell_damage_milli()` 是遗留纯函数（动画不再用它们算伤害），
## 保留只因为 `probe_reaper_ai.gd` 仍在断言 `d6 > d12`（tools 不在本轮写区）。


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
