# ══════════════════════════════════════════════════════════════════════════════
# 哨兵射界高亮：蓝色发光【描边】（只画环带轮廓，不填充）
#
# 用户口径：
#   · 判定仍然是浮点欧氏距离（GameMaster.Sentry.in_range），这里只负责把它画出来
#   · 高亮沿【方格边缘】走，让玩家觉得这是战棋，而不是一个圆
#   · 只要边缘（描边），不要填充
#
# 一个哨兵一个节点；角色换格（例如用调试面板搬人）时自动重建。
# 几何算在 Targeting.ring_cells / ring_outline_edges（纯函数，可无头测试）里。
# ══════════════════════════════════════════════════════════════════════════════
class_name SentryRange
extends RefCounted

const LINE_W := 0.075         # 亮芯宽度（格）
const GLOW_W := 0.30          # 外圈柔光宽度（格）
const Y_LINE := 0.072         # 抬离地面，避免和棋盘共面打架
const Y_GLOW := 0.068

var parent: Node3D = null
var grid_w: int = 48
var grid_h: int = 48
## 可行动区域左上角（竞技场扩了空场之后：只画真格子，不许画到空场）
var grid_x0: int = 0
var grid_y0: int = 0
## owner_name -> {"node": Node3D, "cell": Vector2i, "rmin": int, "rmax": int, "edges": int}
var items: Dictionary = {}


func setup(p_parent: Node3D) -> void:
	parent = p_parent


func clear() -> void:
	for k in items.keys():
		_free_one(k)


## 每帧同步：哨兵没了就删；角色换格 / 射界变了就重建
func sync(sentries: Array) -> void:
	var live := {}
	for s in sentries:
		if s == null or s.owner == null or not s.owner.is_alive():
			continue
		var key: String = s.owner_name
		live[key] = true
		var cell: Vector2i = s.owner.cell
		var it = items.get(key)
		if it != null and it["cell"] == cell \
				and it["rmin"] == s.rng_min and it["rmax"] == s.rng_max:
			continue
		if it != null:
			_free_one(key)
		items[key] = make_item(s.rng_min, s.rng_max, cell, grid_w, grid_h, parent, grid_x0, grid_y0)
	for key in items.keys():
		if not live.has(key):
			_free_one(key)


func _free_one(key: String) -> void:
	var it = items.get(key)
	items.erase(key)
	if it == null:
		return
	var node: Node3D = it["node"]
	if is_instance_valid(node):
		if node.get_parent() != null:
			node.get_parent().remove_child(node)
		node.queue_free()


## 建一个哨兵的描边节点。返回条目字典（测试会看 edges / cells）。
## x0/y0 = 可行动区域左上角（竞技场扩了空场之后，只画真格子）。
static func make_item(rmin: int, rmax: int, cell: Vector2i, gw: int, gh: int,
		p_parent: Node3D, x0: int = 0, y0: int = 0) -> Dictionary:
	var ctr := Vector2(float(cell.x) + 0.5, float(cell.y) + 0.5)
	var cells := Targeting.ring_cells(ctr, float(rmin), float(rmax), gw, gh, x0, y0)
	var edges := Targeting.ring_outline_edges(cells)
	var root := Node3D.new()
	if p_parent != null:
		p_parent.add_child(root)
	root.add_child(_band(edges, GLOW_W, Y_GLOW, Color(0.10, 0.28, 1.0, 0.22)))
	root.add_child(_band(edges, LINE_W, Y_LINE, Color(0.26, 0.56, 1.0, 0.95)))
	return {"node": root, "cell": cell, "rmin": rmin, "rmax": rmax,
		"edges": edges.size(), "cells": cells.size()}


## 把一组边变成一条带子（每段边一个四边形）
static func _band(edges: Array, width: float, y: float, col: Color) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := width * 0.5
	for e in edges:
		var a: Vector2 = e[0]
		var b: Vector2 = e[1]
		var n := Vector2(b.y - a.y, a.x - b.x)
		if n.length() > 0.0001:
			n = n.normalized() * h
		var a0 := Vector3(a.x + n.x, y, a.y + n.y)
		var a1 := Vector3(a.x - n.x, y, a.y - n.y)
		var b0 := Vector3(b.x + n.x, y, b.y + n.y)
		var b1 := Vector3(b.x - n.x, y, b.y - n.y)
		st.add_vertex(a0); st.add_vertex(b0); st.add_vertex(b1)
		st.add_vertex(a0); st.add_vertex(b1); st.add_vertex(a1)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = col
	mi.material_override = m
	return mi
