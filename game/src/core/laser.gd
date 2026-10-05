# ══════════════════════════════════════════════════════════════════════════════
# 激光类弹射物（第 98 轮 · Boss-1）：**不是"飞过去命中"，而是"存在一段时间的光束"**
#
# 与既有两类弹道物的区别（这是"第三种类型"，与箭矢类 / 炮弹类同级）：
#   · 箭矢类 / 炮弹类 = `Projectile`（纯物理对象：飞、撞、落地、可被击落）
#   · 激光类 = **光束**：在一段时间里，每个物理帧对覆盖到的目标累加【帧伤】，
#     光束结束时【统一结算一次】—— 一次结算 = 一次伤害，而不是每帧各打一次。
#   因此它**不进 ProjectileField**：不参与互相击落、不会被箭打掉、不惊动哨兵。
#
# 用户口径：
#   · 高度：光柱**起点离地 3 格**（第 102 轮："激光初始高度减为 3"；第 98 轮曾是 6）。
#     ⚠️ **蓝环离地 6 格是另一件事**（第 99 轮口径，在 `view/reaper_model.gd` 的 `RING_Y`）——
#     环是发射口的外观、光柱起点是判定几何，两者**已解耦**，改一个不会动另一个。
#     "末端是攻击目标"，所以终点可以比起点低（斜射），判定是**三维线段 vs 竖直圆柱**。
#   · 阻挡：**可以被地形挡住** —— 与箭矢同一处口径（`Ballistics.placeable_block_mode`）：
#     木刺 `block_ranged = false` 不拦、土堆 `block_ranged = true` 拦，撞到就停在它那一格。
#   · 伤害：**魔法伤害**（只吃魔抗、无视护甲）—— 见 `Damage.magic_hit`。
#
# 本文件是**纯规则**（RefCounted、不碰 Node、可无头测试）：几何 + 帧伤 + 结算。
# 表现与推进（光束节点、每帧 tick、统一结算的收尾）在 `view/laser_beam.gd`。
# ══════════════════════════════════════════════════════════════════════════════
class_name Laser
extends RefCounted

## 光柱**起点**离地高度（用户口径第 102 轮："激光初始高度减为 3"；第 98 轮曾是 6）。
## ⚠️ **这不是蓝环高度**：蓝环离地 6 格写在 `view/reaper_model.gd` 的 `ReaperModel.RING_Y`
## 里，两者**解耦**（环 = 发射口外观，这里是判定几何）。
const BASE_HEIGHT := 3.0

## 光束粗细（判定半径）= **0.25 格 → 直径 0.5 格**
## （用户口径第 100 轮："把光柱理解为直径 0.5 格的圆柱"；第 98 轮曾是 0.5 = 直径 1 格）。
## 命中判据 = 光束到角色竖轴的距离 <= HIT_R + 角色自己的 body_r
const HIT_R := 0.25

## 帧伤的单位帧：1 帧 = 1/60 秒（与 `Reaper.FRAME_HZ` 对齐）。
## 伤害按 delta 折算成帧数，所以掉帧不会改变每秒伤害。
const FRAME_HZ := 60.0

## 激光 id -> 每帧伤害（点）。**帧伤由激光 id 决定**，不按距离查表。
## 第 103 轮用户口径："把每帧伤害减半，但是动画持续时间翻倍" → reaper_laser 2 → **1 点/帧**
## （同时 `Reaper.SWEEP_SEC` 2→4、`SLICE_SEC` 1.6→3.2，帧数 ×2 —— **总伤害不变**，
##  只是分摊到两倍时长；实测对照表见本轮的临时脚本输出）。
const DMG_PER_FRAME := {
	"reaper_laser": 1,
}
const DEFAULT_DMG_PER_FRAME := 1


## 这个激光 id 的每帧伤害（点）。没登记的 id 走缺省 1 点/帧。
static func dmg_per_frame_of(id: String) -> int:
	return int(DMG_PER_FRAME.get(id, DEFAULT_DMG_PER_FRAME))


# ══════════════════════════════════════════════════════════════════════════════
# 地形截断
# ══════════════════════════════════════════════════════════════════════════════

## 光束从 a 到 b 的哪一段会被地形截断。返回 b 被截断后的终点（没截断就返回 b）。
##
## 判定入口是 `Ballistics.placeable_block_mode(pl, Projectile.KIND_LASER)` —— 只此一处：
##   · 土堆   `block_ranged = true`  -> `Block.ALWAYS`  拦，光束停在它那一格
##   · 木刺   `block_ranged = false` -> `Block.NEVER`   不拦（尖桩之间有缝，与箭矢同款）
## 返回的是【第一个进入阻挡物所在格的采样点】，所以 `floor(终点)` 一定是阻挡物那一格
## （光束视觉上抵到它的边缘，不会穿过去）。
static func clip_by_terrain(a: Vector2, b: Vector2, placeables: Array[Placeable],
		grid_w: int, grid_h: int) -> Vector2:
	if placeables.is_empty():
		return b
	var total := a.distance_to(b)
	if total <= 0.0001:
		return b
	var steps: int = maxi(1, int(ceil(total / 0.05)))
	for i in range(1, steps + 1):
		var t := float(i) / float(steps)
		var p := a + (b - a) * t
		var c := Vector2i(int(floor(p.x)), int(floor(p.y)))
		# 空场（可行动区域之外）没有地形
		if c.x < 0 or c.y < 0 or c.x >= grid_w or c.y >= grid_h:
			continue
		for pl in placeables:
			if pl == null or not pl.is_alive() or not pl.covers(c):
				continue
			if Ballistics.placeable_block_mode(pl, Projectile.KIND_LASER) != Ballistics.Block.ALWAYS:
				continue
			return p
	return b


# ══════════════════════════════════════════════════════════════════════════════
# 命中判定（三维）
# ══════════════════════════════════════════════════════════════════════════════

## 光束会不会**扫到这个沙盒元素**（第 100 轮用户口径：激光对沙盒元素也要有伤害）。
##
## 判定 = **水平覆盖**：光束经过它占用的任意一格即命中（步子 0.05 格，与 `clip_by_terrain` 同一套）。
## 为什么不做高度轴：`Placeable` 在数据里根本没有"高度"（只有占地格子），而阻挡判定
## `clip_by_terrain` 本来就是二维的 —— 两处必须同口径，否则会出现"土堆拦住了光束、
## 自己却不吃伤害"这种自相矛盾。
## **挡路的（土堆）与被穿过的（木刺）都算命中**：前者光束停在它那一格、后者光束继续走；
## 这与箭矢那条老路一致（箭被土堆拦下时，那一发就是打在土堆上的）。
static func hits_placeable(a: Vector3, b: Vector3, pl: Placeable) -> bool:
	if pl == null or not pl.is_alive():
		return false
	var p0 := Vector2(a.x, a.z)
	var p1 := Vector2(b.x, b.z)
	var total := p0.distance_to(p1)
	if total <= 0.0001:
		return pl.covers(Vector2i(int(floor(p0.x)), int(floor(p0.y))))
	var steps: int = maxi(1, int(ceil(total / 0.05)))
	for i in range(steps + 1):
		var p := p0.lerp(p1, float(i) / float(steps))
		if pl.covers(Vector2i(int(floor(p.x)), int(floor(p.y)))):
			return true
	return false


## 光束会不会打到这个角色。
##
## 三维口径：光束是 `a -> b` 的线段；角色是**竖直圆柱**
## （半径 `Targeting.unit_bodies(u)[i].r`、高 `.h`、底面 `u.body_h()`）。
## 做法分两步，精确解、不采样：
##   ① 把线段按圆柱的高度区间 [y0, y1] 裁一刀（`_clip_seg_y`）；
##   ② 算这一小段到"圆柱中轴"的**水平**距离 <= HIT_R + 角色半径 即命中（`_dist_point_to_seg_2d`）。
##
## 于是"贴地飞的水平光束"打不到地面角色（高度轴生效），而"从 6 格高处斜射到目标身上"
## 的线段一定在末端命中目标 —— 这正是 Reaper 激光的几何。
##
## 第 104 轮：身体从**单个**圆柱泛化成**一组**（`Targeting.unit_bodies`）——
## 任何一个圆柱被碰到就算命中。既有角色（组里只有一个 (0,0)）行为逐字不变。
static func hits_unit(a: Vector3, b: Vector3, u: Unit) -> bool:
	if u == null or not u.is_alive():
		return false
	var y0 := u.body_h()
	for body in Targeting.unit_bodies(u):
		if not _hits_body(a, b, u.cell + (body["offset"] as Vector2i),
				float(body["r"]), float(body["h"]), y0):
			continue
		return true
	return false


## 单个圆柱的判定（见 `hits_unit` 的两步法）
static func _hits_body(a: Vector3, b: Vector3, cell: Vector2i, body_r: float, body_h: float,
		y0: float) -> bool:
	var seg := _clip_seg_y(a, b, y0, y0 + body_h)
	if seg.is_empty():
		return false
	var p0: Vector3 = seg[0]
	var p1: Vector3 = seg[1]
	var ctr := Vector2(float(cell.x) + 0.5, float(cell.y) + 0.5)
	var rr := HIT_R + body_r
	return _dist_point_to_seg_2d(ctr, Vector2(p0.x, p0.z), Vector2(p1.x, p1.z)) <= rr


## 线段落在高度区间 [y0, y1] 里的那一小段（返回 [Vector3, Vector3]，空数组 = 完全在区间外）。
static func _clip_seg_y(a: Vector3, b: Vector3, y0: float, y1: float) -> Array:
	var dy := b.y - a.y
	var t0 := 0.0
	var t1 := 1.0
	if absf(dy) <= 0.000001:
		# 水平光束：整条都在同一高度，要么全在区间里、要么全不在
		if a.y < y0 or a.y > y1:
			return []
		return [a, b]
	var ta := (y0 - a.y) / dy
	var tb := (y1 - a.y) / dy
	var lo := minf(ta, tb)
	var hi := maxf(ta, tb)
	t0 = maxf(t0, lo)
	t1 = minf(t1, hi)
	if t0 > t1:
		return []
	return [a.lerp(b, t0), a.lerp(b, t1)]


## 点到线段的距离（二维，水平面）。线段退化成一个点时就是点到点的距离。
static func _dist_point_to_seg_2d(p: Vector2, s0: Vector2, s1: Vector2) -> float:
	var d := s1 - s0
	var l2 := d.length_squared()
	if l2 <= 0.0000001:
		return p.distance_to(s0)
	var t := clampf((p - s0).dot(d) / l2, 0.0, 1.0)
	return p.distance_to(s0 + d * t)


# ══════════════════════════════════════════════════════════════════════════════
# 帧伤结算（光束结束时**统一结算一次**）
# ══════════════════════════════════════════════════════════════════════════════

## frames_by_id 是 {目标 instance_id: 被光束覆盖的物理帧数} —— 角色与**沙盒元素**共用这一张表
## （实例 id 全局唯一，不会撞）；
## dmg_per_frame 由【激光 id】决定（`"reaper_laser"` = **1 点/帧**，第 103 轮由 2 减半）。
## 伤害走 `Damage.magic_hit` / `Damage.magic_hit_placeable`（只吃魔抗、无视护甲），
## 返回 Array[Damage.Hit]。
## 已经阵亡 / 不在 units / 不在 placeables 里的目标：这一份帧伤作废（不给尸体结算）。
##
## 第 100 轮：加了 `placeables`（可选，缺省空 = 行为与以前逐字相同）。
## 沙盒元素走同一条"帧数 × 每帧伤害"的口径 —— 包括**魔抗免疫**的（用户口径：
## "还是要进造伤公式转一圈"）：公式算完自然为 0，但那条 Hit 照样返回、日志照样写。
static func settle(units: Array[Unit], frames_by_id: Dictionary, dmg_per_frame: int,
		rng, placeables: Array[Placeable] = []) -> Array[Damage.Hit]:
	var out: Array[Damage.Hit] = []
	if frames_by_id.is_empty() or dmg_per_frame <= 0:
		return out
	var units_by_id := {}
	for u in units:
		if u != null and u.is_alive():
			units_by_id[u.get_instance_id()] = u
	var pls_by_id := {}
	for pl in placeables:
		if pl != null and pl.is_alive():
			pls_by_id[pl.get_instance_id()] = pl
	for key in frames_by_id.keys():
		var frames := int(frames_by_id[key])
		if frames <= 0:
			continue
		var points := frames * dmg_per_frame
		var u: Unit = units_by_id.get(key, null)
		if u != null:
			var h := Damage.magic_hit(null, u, points, rng, "激光")
			if h != null:
				out.append(h)
			continue
		var pl: Placeable = pls_by_id.get(key, null)
		if pl != null:
			var h2 := Damage.magic_hit_placeable(pl, points, "激光")
			if h2 != null:
				out.append(h2)
	return out
