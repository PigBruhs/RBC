extends SceneTree

var count := 0
var aabb := AABB()
var first := true
var lows: Array = []

func _init() -> void:
	var root := Node3D.new()
	get_root().add_child(root)
	var script: GDScript = load("res://src/view/heli_model.gd")
	var heli: Node3D = script.build(root, Color(0.35, 0.42, 0.3))
	_walk(heli, Transform3D())
	print("ROOT_NAME=", heli.name, " CHILD_COUNT=", root.get_child_count())
	print("MESH_COUNT=", count, " (limit 30)" if count > 30 else " (OK <=30)")
	print("AABB_POS=(", aabb.position.x, ", ", aabb.position.y, ", ", aabb.position.z, ")")
	print("AABB_END=(", aabb.end.x, ", ", aabb.end.y, ", ", aabb.end.z, ")")
	print("SIZE_X=", aabb.size.x, " SIZE_Y=", aabb.size.y, " SIZE_Z=", aabb.size.z)
	print("MIN_Y=", aabb.position.y, " CENTER_XZ=(", (aabb.position.x + aabb.end.x) * 0.5, ", ", (aabb.position.z + aabb.end.z) * 0.5, ")")
	lows.sort_custom(func(a, b): return a[0] < b[0])
	print("LOWEST_5:")
	for i in mini(5, lows.size()):
		print("   ", lows[i][1], " min_y=", lows[i][0])
	for n in ["MainRotor", "TailRotor"]:
		var node: Node3D = heli.get_node_or_null(NodePath(n))
		if node == null:
			print(n, " MISSING")
		else:
			print(n, " FOUND local_pos=(", node.position.x, ", ", node.position.y, ", ", node.position.z, ") children=", node.get_child_count())
	quit()

## 手动累积父链变换：脚本模式下节点不在树里，global_transform 不可靠
func _walk(n: Node, xf: Transform3D) -> void:
	if n is Node3D:
		xf = xf * (n as Node3D).transform
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		count += 1
		var box: AABB = (n as MeshInstance3D).mesh.get_aabb()
		var lo := INF
		for i in 8:
			var p: Vector3 = xf * box.get_endpoint(i)
			lo = minf(lo, p.y)
			if first:
				aabb = AABB(p, Vector3.ZERO)
				first = false
			else:
				aabb = aabb.expand(p)
		var nm: String = (n as Node).name
		var pn: String = (n as Node).get_parent().name
		lows.append([lo, pn + "/" + nm])
	for c in n.get_children():
		_walk(c, xf)
