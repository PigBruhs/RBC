# AI 自动演算：两边都交给 AI，跑完整局，看会不会卡住 / 谁赢 / 打了多久。
#   Godot_v4.7.2-stable_win64.exe --headless --path game --script res://tools/sim_ai.gd --quit-after 200000
# 想换关卡/随机种子：-- 后面跟 --level=arena --seed=7 --games=3
extends SceneTree

var _s: Node = null
var _t := 0.0
var _games := 1
var _done := 0
var _level := "arena"
var _seed := 20261002
var _results: Array[String] = []
var _guard_t := 0.0
var _last_turn := -1
var _stall := 0.0
var _need_start := true


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var s := String(a)
		if s.begins_with("--level="): _level = s.substr(8)
		elif s.begins_with("--seed="): _seed = int(s.substr(7))
		elif s.begins_with("--games="): _games = int(s.substr(8))
	print("── AI 自动演算：关卡 %s，种子 %d，跑 %d 局 ──" % [_level, _seed, _games])
	_start()


func _start() -> void:
	Level.current = _level
	_s = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(_s)
	Engine.time_scale = 6.0                       # 加速：动画/计时器一起快 6 倍
	_s.gm.ai_enabled = true
	_s.gm.ai_autoplay_player = true               # 我方也交给 AI（自动演算）
	_s.rng = RngService.new(_seed + _done)
	_s._ai_turn = false
	_need_start = true                            # 摆放阶段等第一帧再结束（场景初始化有先后）
	_t = 0.0
	_stall = 0.0
	_last_turn = -1


func _process(d: float) -> bool:
	if _s == null:
		return false
	_t += d
	# 第一帧：结束摆放阶段，正式开打
	if _need_start:
		if _s.phase != 4:                         # Phase.PLACE
			return false
		_s._finish_placement()
		_need_start = false
		print("   摆放结束：队列 %d 人" % (_s.queue.order.size() if _s.queue != null else -1))
		return false
	if _s.game_over:
		var who := "玩家方" if _s.ui_result_win() else "敌方"
		var msg := "第 %d 局：%s胜｜轮 %d｜回合边界 %d｜%d 秒(真实 %.1f)" % [
			_done + 1, who, _s.round_no, _s.gm.turn_count, int(_t * 6.0), _t]
		print(msg)
		_results.append(msg)
		_done += 1
		if _done >= _games:
			print("── 全部结束：%d/%d 局都打完了 ──" % [_done, _games])
			return true
		_s.queue_free()
		_s = null
		call_deferred("_restart")
		return false
	# 卡死检测：回合边界很久不推进就是 AI 卡住了
	if _s.gm.turn_count == _last_turn:
		_stall += d
		if _stall > 150.0:
			print("❌ 卡住了：回合边界 %d 已经 %.0f 秒没动（phase=%d，当前 %s）" % [
				_last_turn, _stall, _s.phase,
				_s.active.name if _s.active != null else "-"])
			_print_state()
			return true
	else:
		_last_turn = _s.gm.turn_count
		_stall = 0.0
	return false


func _restart() -> void:
	_start()


func _print_state() -> void:
	print("   场上弹道物 %d ｜ 暂停 %s ｜ GM busy %s" % [
		_s.live_projectiles(), _s.get_tree().paused, _s._gm_busy])
	for u in _s.units:
		print("   %s %s 力%s 甲%s 位置 %s %s" % [
			u.name, "活" if u.is_alive() else "死", u.power_cur / 1000, u.armor_cur / 1000,
			u.cell, "（AI）" if _s._is_ai_unit(u) else ""])
