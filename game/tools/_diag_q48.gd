# 临时诊断 2：直接测 TurnQueue.remove 与 on_unit_died 的移除
extends SceneTree

func _initialize() -> void:
	Level.current = "field"
	var s: Node = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(s)
	for i in 10:
		await process_frame

	# 找一个**敌方**单位：名字是 "Alette (E)"
	var qv: Unit = null
	for u in s.units:
		if u.name.begins_with("Alette") and u.side == UnitData.Side.ENEMY:
			qv = u
	if qv == null:
		print("！没找到敌方 Alette")
		quit(1)
		return
	print("目标 = %s ｜ alive=%s ｜ visual=%s" % [
		qv.name, qv.is_alive(), "有" if qv.visual != null else "null"])
	qv.power_cur = qv.power_max
	qv.armor_cur = qv.armor_max
	s.queue.rebuild(s.units)
	print("rebuild 后 e_queue 含他 = %s" % s.queue.e_queue.has(qv))
	print("uid_dead 含他 = %s" % s.uid_dead.has(qv))

	print("--- 直接测 queue.remove ---")
	var removed: bool = s.queue.remove(qv)
	print("remove() 返回 = %s ｜ 现在 e_queue 含他 = %s" % [removed, s.queue.e_queue.has(qv)])

	print("--- 再测完整路径 on_unit_died ---")
	s.queue.rebuild(s.units)
	print("rebuild 后含他 = %s" % s.queue.e_queue.has(qv))
	qv.power_cur = 0
	s.t_on_unit_died(qv)
	print("on_unit_died 后含他 = %s（期望 false）" % s.queue.e_queue.has(qv))
	print("uid_dead 含他 = %s ｜ alive = %s" % [s.uid_dead.has(qv), qv.is_alive()])
	quit(0)
