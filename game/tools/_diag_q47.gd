# 临时诊断：数组 [47] 的"阵亡当场移出队列"为什么红
extends SceneTree

func _initialize() -> void:
	Level.current = "field"
	var s: Node = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(s)
	for i in 10:
		await process_frame
	s.t_set_ai_enabled(false)
	s.t_finish_placement()
	for i in 6:
		await process_frame

	# 复现 playtest [47] 的前提
	var qv: Unit = null
	for u in s.units:
		if u.name == "Alette" and u.side == UnitData.Side.ENEMY:
			qv = u
	print("目标 = %s ｜ alive=%s ｜ power=%d/%d ｜ has_turn=%s" % [
		qv.name, qv.is_alive(), qv.power_cur, qv.power_max, qv.has_turn()])
	print("visual = %s" % ("有" if qv.visual != null else "null"))
	qv.power_cur = qv.power_max
	qv.armor_cur = qv.armor_max
	s.queue.rebuild(s.units)
	var in_q0: bool = s.queue.p_queue.has(qv) or s.queue.e_queue.has(qv)
	print("rebuild 后 in_q0 = %s" % in_q0)
	print("  e_queue 里有哪些：" )
	for u in s.queue.e_queue:
		print("    %s（alive=%s）" % [u.name, u.is_alive()])
	print("  uid_dead 里有他吗 = %s" % s.uid_dead.has(qv))
	qv.power_cur = 0
	s.t_on_unit_died(qv)
	var in_q1: bool = s.queue.p_queue.has(qv) or s.queue.e_queue.has(qv)
	print("阵亡后 in_q1 = %s（期望 false）" % in_q1)
	print("  uid_dead 里有他吗 = %s" % s.uid_dead.has(qv))
	print("  alive = %s ｜ visual.visible = %s" % [qv.is_alive(), qv.visual.visible if qv.visual != null else "?"])
	quit(0)
