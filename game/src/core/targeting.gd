# ══════════════════════════════════════════════════════════════════════════════
# 命中与范围判定（纯几何，无 Node 依赖，可无头测试）
#
# 这些函数原本长在 battle_scene 里，和"伤害结算"混在一起。
# 拆出来之后：谁被谁打到 = 这里说了算；打到了掉多少血 = Combat 说了算；
# 掉血之后表现成什么样 = battle_scene 说了算。
# ══════════════════════════════════════════════════════════════════════════════
class_name Targeting
extends RefCounted

## 箭矢"身体"判定半径（用户口径：直径 0.15 格）
const ARROW_BODY_R := 0.075

## 角色身高（和 Damage.BODY_H / UnitData 的口径一致）
const BODY_H := 1.0

## 缺省碰撞圆柱（格）：**与 Damage.BODY_R / Damage.BODY_H 必须同值**。
## 这里写字面量、不引 Damage —— 避免 core 内的环依赖。probe_reaper.gd 有断言锁着三者相等。
const BODY_R_DEFAULT := 0.30
const BODY_H_DEFAULT := 1.00


## 这个角色的碰撞圆柱半径（格）。缺省 0.30 = BODY_R_DEFAULT = Damage.BODY_R。
## 大头目 Reaper 的数据行写了 body_r = 3.0，于是它是一根半径 3 格的大圆柱。
static func unit_body_r(u: Unit, fallback: float = BODY_R_DEFAULT) -> float:
	return fallback if u == null else u.body_r


## 这个角色的碰撞圆柱高（格）。缺省 1.00 = BODY_H_DEFAULT = Damage.BODY_H。
## ⚠ Unit 上的字段叫 body_height（body_h 这个名字被"身体底面高度"的方法占了）。
static func unit_body_h(u: Unit, fallback: float = BODY_H_DEFAULT) -> float:
	return fallback if u == null else u.body_height


## 角色身体在【高度轴】上的区间 [下, 上]。
## 用户口径（第 83 轮）：悬空单位（直升机 hover = 2 格）整个身体抬高 ——
## 所以"瞄得对不对"必须考虑高度轴：瞄地面高度是打不到悬停的直升机的。
## 第 89 轮：临时高度（爬升轰炸）由 Unit.body_h() 给出 —— 身体在哪就按哪算。
## 第 98 轮：身高改成**按单位取**（Reaper 12 格）—— 缺省单位与以前逐字相同。
static func body_span(u: Unit) -> Vector2:
	var y0 := u.body_h()
	return Vector2(y0, y0 + unit_body_h(u))


## 瞄准一个角色时应该瞄的高度 = 身体中心（跟着临时高度走）
static func aim_height(u: Unit) -> float:
	return u.body_h() + unit_body_h(u) * 0.5


## 当前位置能打到的所有格子。
##   近战   = 4 邻格
##   远程/投掷 = 曼哈顿距离 [rng_min, rng_max] 的环带
## 只扫【可行动区域】矩形（x0,y0,w,h）——空场没有格子，不能打也不高亮。
static func attack_range_cells_rect(u: Unit, x0: int, y0: int, w: int, h: int) -> Dictionary:
	var res := {}
	if u.has_acted:
		return res
	if u.role == UnitData.Role.MELEE:
		for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var c: Vector2i = u.cell + off
			if in_rect(c, x0, y0, w, h):
				res[c] = true
		return res
	for y in range(y0, y0 + h):
		for x in range(x0, x0 + w):
			var d: int = absi(x - u.cell.x) + absi(y - u.cell.y)
			if d >= u.rng_min and d <= u.rng_max:
				res[Vector2i(x, y)] = true
	return res


static func attack_range_cells(u: Unit, gw: int, gh: int) -> Dictionary:
	return attack_range_cells_rect(u, 0, 0, gw, gh)


## 格子在矩形里吗
static func in_rect(c: Vector2i, x0: int, y0: int, w: int, h: int) -> bool:
	return c.x >= x0 and c.y >= y0 and c.x < x0 + w and c.y < y0 + h


## 当前打得到的【敌人所在格】（用 in_range_of，和实际结算同一条规则）
static func attackable_cells(u: Unit, units: Array[Unit]) -> Dictionary:
	var res := {}
	if u.has_acted:
		return res
	for o in units:
		if o.is_alive() and o.side != u.side and u.in_range_of(o.cell):
			res[o.cell] = true
	return res


## 【近战够不够得着这个单位】用户口径（第 96 轮）：**近战攻击不能瞄准直升机**。
## 规则只按高度轴算（和 body_span / aim_height 同一套口径）：近战是贴上去砍，
## 只能砍**脚踏在地上**的单位；身体离地（直升机 hover = 2 格，俯冲时 2~4 格）就够不着。
## 远程 / 投掷不受这条限制 —— 它们本来就瞄身体中心，能打空中目标。
static func melee_reaches(u: Unit, t: Unit) -> bool:
	if t == null:
		return false
	if u != null and u.role != UnitData.Role.MELEE:
		return true
	return t.body_h() <= 0.0001


## 圆与格子（边长 1 的正方形）是否相交：红圈沾到格子就算命中
static func circle_touches_cell(ctr: Vector2, cell: Vector2i, radius: float) -> bool:
	var nx := clampf(ctr.x, float(cell.x), float(cell.x) + 1.0)
	var ny := clampf(ctr.y, float(cell.y), float(cell.y) + 1.0)
	var dx := ctr.x - nx
	var dy := ctr.y - ny
	return (dx * dx + dy * dy) <= radius * radius


## 爆心到格中心的距离是否够近（浮点圆心版）
static func blast_covers(ctr: Vector2, cell: Vector2i, radius: float) -> bool:
	var pc := Vector2(float(cell.x) + 0.5, float(cell.y) + 0.5)
	return ctr.distance_to(pc) <= radius + 0.5


## 三维空爆：球心 ctr（带高度）+ 半径 radius，是否碰到角色的身体。
## 角色身体按一根【竖直圆柱】算：半径 body_r，高 body_h，底面在 body_y0（= 该单位的悬浮高度）。
## 用户口径：空爆做三维判定、范围恒定为一格球（半径 0.5）——所以"在头顶上炸但飞得高"
## 是打不到的；同时贴着地面炸也够不到隔壁一整格。
static func sphere_hits_body(ctr: Vector3, radius: float, cell: Vector2i,
		body_r: float, body_h: float, body_y0: float = 0.0) -> bool:
	var cx := float(cell.x) + 0.5
	var cz := float(cell.y) + 0.5
	var dy := 0.0
	if ctr.y < body_y0:
		dy = body_y0 - ctr.y
	elif ctr.y > body_y0 + body_h:
		dy = ctr.y - (body_y0 + body_h)
	var hd := maxf(0.0, Vector2(ctr.x - cx, ctr.z - cz).length() - body_r)
	return hd * hd + dy * dy <= radius * radius


## 弹道物在这一小段路径上打到了哪个角色（细圆柱 vs 脚下小圆）。
## 用线段采样：细判定配大步长会漏检，所以沿路径取若干点。
## body_r = 这一发自己的"身体"半径（箭矢 0.075、加农炮弹 0.25）
##
## 高度轴（用户口径第 83/84 轮）：**一切按物理碰撞判定** ——
## 角色身体是竖直圆柱 [hover, hover + BODY_H]（悬空单位整体抬高），
## 弹道物必须真的碰到它才算命中：从地面角色头顶飞过、从悬停单位下面穿过都不算；
## 但**只要碰到任何角色（不分敌我）就照常造伤**。
static func arrow_body_hit_seg(from: Vector3, to: Vector3, attacker: Unit,
		units: Array[Unit], unit_body_r: float, body_r: float = ARROW_BODY_R) -> Unit:
	var steps := maxi(2, int(from.distance_to(to) / 0.05) + 1)
	for s in steps + 1:
		var p := from.lerp(to, float(s) / float(steps))
		for o in units:
			if not o.is_alive() or o == attacker:
				continue
			# 第 98 轮：**按单位自己的碰撞圆柱**判（Reaper 半径 3 / 高 12）。
			# unit_body_r 参数保留为兜底：单位没自带尺寸时（= 既有角色）取它 ——
			# 既有调用方一律传 0.30，与 o.body_r 的缺省同值，所以行为逐字不变。
			var rr := body_r + unit_body_r(o, unit_body_r)
			var dx := p.x - (float(o.cell.x) + 0.5)
			var dz := p.z - (float(o.cell.y) + 0.5)
			if dx * dx + dz * dz > rr * rr:
				continue
			var span := body_span(o)
			if p.y < span.x - body_r or p.y > span.y + body_r:
				continue
			return o
	return null


## 圆盘（含内部）覆盖的【格子】：格心到圆心的距离 <= rmax。
## 用户口径（第 84 轮）：直升机俯冲轰炸是"点 0~N 格内的一格" —— 这一格集合就是粉色高亮。
static func disc_cells(ctr: Vector2, rmax: float, gw: int, gh: int,
		x0: int = 0, y0: int = 0) -> Dictionary:
	var res := {}
	var cx0: int = maxi(x0, int(floor(ctr.x - rmax)) - 1)
	var cx1: int = mini(x0 + gw - 1, int(ceil(ctr.x + rmax)) + 1)
	var cy0: int = maxi(y0, int(floor(ctr.y - rmax)) - 1)
	var cy1: int = mini(y0 + gh - 1, int(ceil(ctr.y + rmax)) + 1)
	for y in range(cy0, cy1 + 1):
		for x in range(cx0, cx1 + 1):
			if ctr.distance_to(Vector2(float(x) + 0.5, float(y) + 0.5)) <= rmax + 0.0001:
				res[Vector2i(x, y)] = true
	return res


## 欧氏环带（射界）覆盖的【格子】：格心到圆心的距离落在 [rmin, rmax] 内。
## 判定本身仍然是浮点欧氏距离（GameMaster.Sentry.in_range），这里只是把它画出来。
## gw/gh = 可行动区域的宽高，x0/y0 = 它的左上角（竞技场扩了空场之后只画真格子）。
static func ring_cells(ctr: Vector2, rmin: float, rmax: float, gw: int, gh: int,
		x0: int = 0, y0: int = 0) -> Dictionary:
	var res := {}
	var cx0: int = maxi(x0, int(floor(ctr.x - rmax)) - 1)
	var cx1: int = mini(x0 + gw - 1, int(ceil(ctr.x + rmax)) + 1)
	var cy0: int = maxi(y0, int(floor(ctr.y - rmax)) - 1)
	var cy1: int = mini(y0 + gh - 1, int(ceil(ctr.y + rmax)) + 1)
	for y in range(cy0, cy1 + 1):
		for x in range(cx0, cx1 + 1):
			var d := ctr.distance_to(Vector2(float(x) + 0.5, float(y) + 0.5))
			if d >= rmin - 0.0001 and d <= rmax + 0.0001:
				res[Vector2i(x, y)] = true
	return res


## 环带的轮廓：只取"内格与外格之间"的公共边（外圈 + 内圈都算），格子在外的不画。
## 返回 [[a: Vector2, b: Vector2], ...]，坐标以格为单位（x, y 直接当世界的 x, z 用）。
## 用户口径：只要边缘（描边），不要填充 —— 这样看起来才像战棋的高亮范围。
static func ring_outline_edges(cells: Dictionary) -> Array:
	var out: Array = []
	for k in cells.keys():
		var c: Vector2i = k
		var x0 := float(c.x)
		var y0 := float(c.y)
		var x1 := x0 + 1.0
		var y1 := y0 + 1.0
		if not cells.has(c + Vector2i(0, -1)):
			out.append([Vector2(x0, y0), Vector2(x1, y0)])
		if not cells.has(c + Vector2i(0, 1)):
			out.append([Vector2(x0, y1), Vector2(x1, y1)])
		if not cells.has(c + Vector2i(-1, 0)):
			out.append([Vector2(x0, y0), Vector2(x0, y1)])
		if not cells.has(c + Vector2i(1, 0)):
			out.append([Vector2(x1, y0), Vector2(x1, y1)])
	return out
