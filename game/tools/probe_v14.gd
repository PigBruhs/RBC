# 实机渲染探针 v14：9 人场 + 炮弹光晕尾迹 + 哨兵触发
#   Godot_v4.7.2-stable_win64.exe --path game --rendering-driver opengl3 \
#       --resolution 1600x900 --script res://tools/probe_v14.gd
extends SceneTree
var _s: Node
var _f := 0
var _t := 0.0
var _fail := 0
var _shots := 0
var _stage := 0
var _t0 := 0.0
var _mortar: Unit = null
var _alette: Unit = null
var _foe: Unit = null
var _pp: Projectile = null

func _initialize() -> void:
	_s = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(_s)

func _chk(ok: bool, what: String) -> void:
	if ok:
		print("  PASS  %s" % what)
	else:
		_fail += 1
		print("  FAIL  %s" % what)

func _shot(n: String) -> void:
	root.get_texture().get_image().save_png("user://%s" % n)
	_shots += 1
	print("[shot] %s" % n)

func _process(d: float) -> bool:
	_f += 1
	_t += d
	match _stage:
		0:
			if _t >= 0.2:
				_s.t_set_ai_enabled(false)        # 探针要确定性：关掉通用 AI
				var p := 0
				var e := 0
				for u in _s.units:
					if u.side == UnitData.Side.PLAYER: p += 1
					else: e += 1
					if u.name == "Airburst mortar": _mortar = u
					if u.name == "Alette": _alette = u
					if u.side == UnitData.Side.ENEMY and not u.controllable and not u.name.begins_with("Dummy"): _foe = u
					# 老国王 / 公主挪到角落：它们的 AI 与常备哨兵会干扰下面的检查
					if Unit.base_name(u.name) == "老国王" or Unit.base_name(u.name) == "公主":
						var far := Vector2i(2, 44) if u.side == UnitData.Side.PLAYER else Vector2i(45, 44)
						u.cell = far
						if u.visual != null:
							u.visual.position = Vector3(float(far.x) + 0.5, 0.0, float(far.y) + 0.5)
				print("\n[1] 场上：我方 %d 人，敌方 %d 人" % [p, e])
				# 人数改由关卡 roster 决定（场景解耦）：测试场 7 + 10
				_chk(p == 8 and e == 11, "场上应是我方 8 + 敌方 11（按关卡 roster）")
				_s.t_finish_placement()
				_s.t_set_cam_focus(Vector3(6.0, 0.0, 7.0))
				_s.t_set_zoom(22.0)
				_s.t_update_camera()
				_stage = 1
		1:
			if _t >= 0.6:
				_shot("v14_field.png")
				# 调试面板（重写版：选中即编辑）——先确认它真的能建出输入框
				_s.t_select_for_detail(_alette)
				_s.ui.toggle_debug()
				_s.ui.dbg_seen_unit = null
				_s.ui.refresh_debug()
				_chk(_s.ui.is_debug_open() and _s.ui.dbg_edits.size() == _s.DBG_FIELDS.size(),
					"调试面板：选中的单位应建齐 %d 个输入框" % _s.DBG_FIELDS.size())
				print("    调试面板字段 = %d ｜ 日志行数 = %d" % [
					_s.ui.dbg_edits.size(), _s.ui.dbg_log.text.split("\n").size()])
				_t0 = _t
				_stage = 4
		4:
			# 下一帧再截图：get_image() 拿到的是上一帧，同帧改可见性截不到
			if _t - _t0 >= 0.08:
				_shot("v14_debug.png")
				_s.ui.toggle_debug()
				_chk(not _s.ui.is_debug_open(), "再点调试按钮应收起面板")
				# 阿莱特开哨兵
				_alette.cell = Vector2i(7, 7)
				_alette.energy = _alette.energy_max
				_alette.begin_turn()
				_s.active = null
				_s.t_cast_sentry(_alette)
				_chk(_s.gm.has_sentry(_alette), "阿莱特应进入哨兵状态")
				print("    哨兵：%s" % _s.gm.sentry_desc())
				_t0 = _t
				_stage = 5
		5:
			# 下一帧才截得到高亮（get_image() 拿的是上一帧）
			if _t - _t0 >= 0.1:
				# 场上现在有 3 个哨兵（阿莱特 + 两个公主），阿莱特的那一份必须建出来
				_chk(_s.sentry_range.items.size() >= 1, "哨兵射界高亮应出现")
				var it = _s.sentry_range.items.get(_alette.name)
				print("    射界高亮：%s 格，描边 %d 段" % [
					it["cells"] if it != null else 0, it["edges"] if it != null else 0])
				_shot("v14_sentry.png")
				# 投掷手打一发炮弹：目标在阿莱特射界内 -> 应进哨兵队列
				_mortar.cell = Vector2i(2, 7)
				_mortar.power_cur = _mortar.power_max
				_mortar.begin_turn()
				_s.active = null
				_pp = _s.t_spawn_shell(_mortar, Vector2(13.0, 7.0), false)
				print("    spawn -> alive=%s dur=%.2f t=%.2f projs=%d" % [_pp.alive, _pp.dur, _pp.t, _s.field.items.size()])
				_t0 = _t
				_stage = 2
		2:
			if _t - _t0 >= 0.14:
				print("\n[2] 炮弹飞行 + 哨兵")
				var shells: int = _s.live_projectiles()
				print("    存活弹道物 = %d ｜ 该发: alive=%s 原因='%s' t=%.2f" % [shells, _pp.alive, _pp.removed_reason, _pp.t])
				for lg in _s.t_debug_log().slice(maxi(0, _s.t_debug_log().size() - 6)):
					print("    [日志] %s" % lg)
				_chk(shells >= 1, "炮弹应在飞（哨兵随后拦截，见下一项断言）")
				_shot("v14_shell.png")
				_stage = 3
		3:
			# 用户口径：哨兵瞄准点带 1 格随机球散步 -> 拦炮弹变成"多次抽奖"，
			# 所以这里给它足够多的抽奖次数（炮弹在哨兵射界里飞好几秒），只断言最终被击落。
			if _t - _t0 >= 3.5 or (_pp != null and not _pp.alive):
				print("\n[3] 落地")
				print("    存活弹道物 = %d，红圈 = %d ｜ 该发 alive=%s 原因='%s'" % [
					_s.live_projectiles(), _s.count_impact_rings(), _pp.alive, _pp.removed_reason])
				_chk(not _pp.alive and _pp.removed_reason == "shot_down",
					"哨兵箭应该能把炮弹击落（散布会漏几次，但总有一次提前量是对的）")
				_shot("v14_shotdown.png")
				_shot("v14_after.png")
				# 待确认黄勾：直接摆一个待确认格子（拉近看细节）
				_s.t_set_zoom(7.0)
				_s.t_set_cam_focus(Vector3(6.0, 0.0, 6.5))
				_s.t_update_camera()
				_s.t_set_pending("move", Vector2i(6, 7), _alette)
				_s.t_draw_hints()
				_t0 = _t
				_stage = 6
		6:
			# 下一帧再截图（get_image() 拿的是上一帧），顺便让它完成"面向摄像机"
			if _t - _t0 >= 0.12:
				_chk(_s.t_pending_root().visible and _s.t_check_mats().size() == 4, "待确认黄勾应出现")
				_shot("v14_check.png")
				_s.t_clear_pending()
				_s.t_draw_hints()
				# 杰拉尔德被箭命中 -> 弹反 QTE
				var g: Unit = null
				var a: Unit = null
				for u in _s.units:
					if u.name == "Gerald": g = u
					if u.name == "Alette": a = u
					if u.name != "Gerald" and u.name != "Alette":
						u.cell = Vector2i(1, 40)
						if u.visual != null:
							u.visual.position = Vector3(1.5, 0.0, 40.5)
				g.cell = Vector2i(6, 7)
				g.visual.position = Vector3(6.5, 0.0, 7.5)
				g.power_cur = g.power_max
				a.cell = Vector2i(6, 14)
				a.visual.position = Vector3(6.5, 0.0, 14.5)
				a.power_cur = Rules.points_to_milli(100)
				_s.t_set_cam_focus(Vector3(6.0, 0.0, 10.0))
				_s.t_update_camera()
				_s.clear_projectiles()
				_s.t_spawn_arrow(a, Vector3(6.5, 0.75, 14.5), Vector3(6.5, 0.55, 7.5), g, false, true)
				_t0 = _t
				_stage = 7
		7:
			if _s.t_qte_active():
				_chk(_s.get_tree().paused, "弹反 QTE 期间必须暂停时间")
				_chk(g_power_kept(), "QTE 期间不结算伤害")
				print("    弹反 QTE：按键 = %s，窗口 = %s" % [_find_qte_keys(), _find_qte_windows()])
				_t0 = _t
				_stage = 8
		8:
			# 隔一帧再截图：面板的位置/尺寸要等一次 _process 才成立
			if _t - _t0 >= 0.12:
				var q = _find_qte_node()
				print("    QTE 面板：字母='%s' 位置=%s 尺寸=%s" % [
					q._label.text if q != null else "-",
					q.position if q != null else Vector2.ZERO,
					q.size if q != null else Vector2.ZERO])
				_chk(q != null and q.running, "QTE 面板必须还在判定中")
				_chk(q != null and q._label.text != "", "QTE 面板上必须显示要按的键")
				_shot("v14_qte.png")
				_t0 = _t
				_stage = 9
		9:
			# QTE 还开着（世界暂停）：先把三次按键按对，让世界继续跑
			if _s.get_tree().paused:
				var q2 = _find_qte_node()
				if q2 != null and q2.running:
					for i in 3:
						q2.press(q2.keys[i])
				_t0 = _t
				return false
			if _t - _t0 >= 0.1:
				# 摆出新角色拍照：老国王（王冠 + 加农炮）+ 公主（王冠 + 常备哨兵）
				var king: Unit = null
				var princess: Unit = null
				for u in _s.units:
					if u.side == UnitData.Side.PLAYER and Unit.base_name(u.name) == "老国王": king = u
					if u.side == UnitData.Side.PLAYER and Unit.base_name(u.name) == "公主": princess = u
				king.cell = Vector2i(8, 10)
				king.visual.position = Vector3(8.5, 0.0, 10.5)
				princess.cell = Vector2i(9, 7)             # 站在炮口反方向，别被自己人的炮弹打死
				princess.visual.position = Vector3(9.5, 0.0, 7.5)
				_s.t_set_cam_focus(Vector3(8.5, 0.0, 10.0))
				_s.t_set_zoom(5.0)
				_s.t_update_camera()
				_t0 = _t
				_stage = 10
		10:
			if _t - _t0 >= 0.15:
				_shot("v14_king.png")
				var king: Unit = null
				for u in _s.units:
					if u.side == UnitData.Side.PLAYER and Unit.base_name(u.name) == "老国王": king = u
				_s.t_fire_cannon_ai(king)                 # 让他真的开一炮
				_t0 = _t
				_stage = 11
		11:
			if _t - _t0 >= 0.08:
				var n := 0
				var spd := 0.0
				for it in _s.field.items:
					var pp: Projectile = it["p"]
					if pp.kind == Projectile.KIND_CANNON and pp.alive:
						n += 1
						spd = pp.from.distance_to(pp.to) / maxf(0.01, pp.dur)
				print("    加农炮弹：在场 %d 发，弹速 %.0f 格/秒" % [n, spd])
				_chk(n >= 1, "老国王应打出一发加农炮弹")
				_chk(absf(spd - Ordnance.CANNON_TILES_PER_SEC) < 0.1, "弹速应为 12 格/秒")
				_shot("v14_cannon.png")
				print("\n── v14 探针：%d 张截图，失败 %d 项 ──" % [_shots, _fail])
				return true
			if _t - _t0 > 3.0:
				_chk(false, "箭矢命中杰拉尔德后应进入弹反 QTE")
				print("\n── v14 探针：%d 张截图，失败 %d 项 ──" % [_shots, _fail])
				return true
	return false


func _find_qte_node():
	return _s.t_find_arrow_qte()


func _find_qte_keys() -> Array:
	var q = _find_qte_node()
	return q.keys if q != null else []


func _find_qte_windows() -> Array:
	var q = _find_qte_node()
	return q.windows if q != null else []


func g_power_kept() -> bool:
	for u in _s.units:
		if u.name == "Gerald":
			return u.power_cur == u.power_max
	return false
