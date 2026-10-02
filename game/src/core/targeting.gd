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


## 当前位置能打到的所有格子。
##   近战   = 4 邻格
##   远程/投掷 = 曼哈顿距离 [rng_min, rng_max] 的环带
static func attack_range_cells(u: Unit, gw: int, gh: int) -> Dictionary:
	var res := {}
	if u.has_acted:
		return res
	if u.role == UnitData.Role.MELEE:
		for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var c: Vector2i = u.cell + off
			if c.x >= 0 and c.y >= 0 and c.x < gw and c.y < gh:
				res[c] = true
		return res
	for y in gh:
		for x in gw:
			var d: int = absi(x - u.cell.x) + absi(y - u.cell.y)
			if d >= u.rng_min and d <= u.rng_max:
				res[Vector2i(x, y)] = true
	return res


## 当前打得到的【敌人所在格】（用 in_range_of，和实际结算同一条规则）
static func attackable_cells(u: Unit, units: Array[Unit]) -> Dictionary:
	var res := {}
	if u.has_acted:
		return res
	for o in units:
		if o.is_alive() and o.side != u.side and u.in_range_of(o.cell):
			res[o.cell] = true
	return res


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
## 角色身体按一根【竖直圆柱】算：半径 body_r，高 body_h。
## 用户口径：空爆做三维判定、范围恒定为一格球（半径 0.5）——所以"在头顶上炸但飞得高"
## 是打不到的；同时贴着地面炸也够不到隔壁一整格。
static func sphere_hits_body(ctr: Vector3, radius: float, cell: Vector2i,
		body_r: float, body_h: float) -> bool:
	var cx := float(cell.x) + 0.5
	var cz := float(cell.y) + 0.5
	var dy := 0.0
	if ctr.y < 0.0:
		dy = -ctr.y
	elif ctr.y > body_h:
		dy = ctr.y - body_h
	var hd := maxf(0.0, Vector2(ctr.x - cx, ctr.z - cz).length() - body_r)
	return hd * hd + dy * dy <= radius * radius


## 箭矢在这一小段路径上打到了哪个角色（细圆柱 vs 脚下小圆）。
## 用线段采样：细判定配大步长会漏检，所以沿路径取若干点。
## body_r = 这一发自己的"身体"半径（箭矢 0.075、加农炮弹 0.25）
static func arrow_body_hit_seg(from: Vector3, to: Vector3, attacker: Unit,
		units: Array[Unit], unit_body_r: float, body_r: float = ARROW_BODY_R) -> Unit:
	var rr := body_r + unit_body_r
	var steps := maxi(2, int(from.distance_to(to) / 0.05) + 1)
	for s in steps + 1:
		var p := from.lerp(to, float(s) / float(steps))
		for o in units:
			if not o.is_alive() or o == attacker:
				continue
			var dx := p.x - (float(o.cell.x) + 0.5)
			var dz := p.z - (float(o.cell.y) + 0.5)
			if dx * dx + dz * dz <= rr * rr:
				return o
	return null


## 欧氏环带（射界）覆盖的【格子】：格心到圆心的距离落在 [rmin, rmax] 内。
## 判定本身仍然是浮点欧氏距离（GameMaster.Sentry.in_range），这里只是把它画出来。
static func ring_cells(ctr: Vector2, rmin: float, rmax: float, gw: int, gh: int) -> Dictionary:
	var res := {}
	var x0: int = maxi(0, int(floor(ctr.x - rmax)) - 1)
	var x1: int = mini(gw - 1, int(ceil(ctr.x + rmax)) + 1)
	var y0: int = maxi(0, int(floor(ctr.y - rmax)) - 1)
	var y1: int = mini(gh - 1, int(ceil(ctr.y + rmax)) + 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
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
