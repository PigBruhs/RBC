extends SceneTree
var _s: Node
var _f := 0
func _initialize() -> void:
	_s = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(_s)
func _process(_d: float) -> bool:
	_f += 1
	if _f == 8:
		for u in _s.units:
			if u.name == "Alette":
				u.energy = 0            # 精力归零
			if u.name == "Gerald":
				u.energy = int(u.energy_max * 0.4)
			if u.name == "Airburst mortar":
				u.energy = u.energy_max
			u.visual.update_orb()
		var ia: Image = null
		for u in _s.units:
			if u.name == "Alette": ia = u.visual._orb_image
		# 统计精力条区域的有色像素
		var e := 0
		var dark := 0
		for y in range(11, 8+44-3):
			for x in range(9, 327):
				var c := ia.get_pixel(x, y)
				if c.r > 0.85 and c.g > 0.7 and c.b < 0.35: e += 1
				elif c.r < 0.2 and c.g < 0.2: dark += 1
		print("Alette 精力 0/8：黄色像素=%d  黑色像素=%d" % [e, dark])
		var ig: Image = null
		for u in _s.units:
			if u.name == "Airburst mortar": ig = u.visual._orb_image
		var e2 := 0
		var d2 := 0
		for y in range(11, 8+44-3):
			for x in range(9, 327):
				var c := ig.get_pixel(x, y)
				if c.r > 0.85 and c.g > 0.7 and c.b < 0.35: e2 += 1
				elif c.r < 0.2 and c.g < 0.2: d2 += 1
		print("Mortar 精力 12/12：黄色像素=%d  黑色像素=%d" % [e2, d2])
		return false
	if _f == 26:
		root.get_texture().get_image().save_png("user://energy2.png")
		print("[shot] energy2.png")
		return true
	return false
