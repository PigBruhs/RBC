extends SceneTree
func _initialize() -> void:
	var s: Node = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(s)
	for i in 5:
		await process_frame
	var alette = null
	var enemy = null
	for u in s.units:
		if u.name == "Alette": alette = u
		if u.side == UnitData.Side.ENEMY and enemy == null: enemy = u
	s.active = alette
	alette.begin_turn()
	alette.cell = Vector2i(4, 4)
	enemy.cell = Vector2i(4, 8)
	print("call  : has_acted=", alette.has_acted, " active=", s.active.name)
	# 第 97 轮 P0：battle_scene 的私有访问一律走公开的 t_* 测试门面。
	# ⚠️ 这个文件当年用的是接收者 `s`（不是 playtest 的 `_s`），所以"把 `_s._xxx` 改成 `t_xxx`"
	#    那一轮批量改写漏了它 —— task-7 删掉 45 个薄包装后它才断（运行时报
	#    `Nonexistent function '_attack_target_unit'`，而编译期查不出来）。
	#    教训：收口时的匹配式不要绑死接收者名字。
	s.t_attack_target_unit(enemy, true)
	print("after : has_acted=", alette.has_acted, " active=", s.active.name if s.active else "-")
	await process_frame
	print("1f    : has_acted=", alette.has_acted, " active=", s.active.name if s.active else "-")
	await create_timer(0.6).timeout
	print("0.6s  : has_acted=", alette.has_acted, " active=", s.active.name if s.active else "-")
	await create_timer(0.8).timeout
	print("1.4s  : has_acted=", alette.has_acted, " active=", s.active.name if s.active else "-")
	print("enemy armor=", enemy.armor_cur / 1000.0)
	quit(0)
