extends SceneTree
func _initialize() -> void:
	var s: Node = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(s)
	for i in 5:
		await process_frame
	s._finish_placement()
	s.turn_started.connect(func(u): print("  [turn] ", u.name, " side=", u.side))
	for i in 10:
		print("step %d: active=%s phase=%d queue.index=%d/%d" % [
			i, s.active.name if s.active else "-", s.phase, s.queue.index, s.queue.order.size()])
		if s.active != null and s.active.side == 0:
			s._finish_turn()
		await create_timer(0.8).timeout
	quit(0)
