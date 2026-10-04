# 皇室竞技场探针：地形 / 出生点 / 河与桥 / 落河消失
#   Godot_v4.7.2-stable_win64.exe --path game --rendering-driver opengl3 \
#       --resolution 1600x900 --script res://tools/probe_arena.gd
extends SceneTree

var _s: Node
var _f := 0
var _t := 0.0
var _fail := 0
var _shots := 0
var _stage := 0
var _t0 := 0.0
var _shell: Projectile = null
var _guard: Unit = null


func _initialize() -> void:
	Level.current = "arena"                 # 切到竞技场再实例化场景
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
			if _t >= 0.25:
				print("\n[1] 竞技场地形")
				print("    物理 %d×%d ｜ 可行动 %d×%d @ %d,%d ｜ 关卡 %s ｜ 相机偏航 %.0f" % [
					_s.GW, _s.GH, _s.PW, _s.PH, _s.PX, _s.PY, Level.name_of(), _s._cam_yaw])
				_chk(_s.GW == 100 and _s.GH == 100, "竞技场物理边界是 100×100（炮弹不再飞出边界就消失）")
				_chk(_s.PW == 21 and _s.PH == 41, "真正有格子的还是 21×41")
				_chk(Level.play_rect("arena") == [0, 0, 21, 41], "可行动区域写在关卡元数据里")
				_chk(Level.is_void(Vector2i(60, 60), "arena") and Level.in_play(Vector2i(10, 20), "arena"),
					"空场判定：60,60 是空场，10,20 是真格子")
				_chk(not Level.is_river(Vector2i(60, 20), "arena"),
					"空场不算河（否则炮弹飞过去会被当成落水消失）")
				# 空场的落地规则（第 83 轮）：投掷类作废，炮弹照常爆炸
				var carrier = unit_by("Airburst mortar")
				var gp_void := Ordnance.make_grenade(carrier, Vector2(60.0, 60.0), true)
				gp_void.from = Vector2(60.0, 60.0)
				gp_void.to = Vector2(60.0, 60.0)
				var models0: int = _s._grenade_models.size()
				var pend0: int = _s.gm.pending.size()
				_s._on_proj_landed(gp_void)
				_chk(_s._grenade_models.size() == models0 and _s.gm.pending.size() == pend0,
					"枪榴弹落在空场：作废（不立模型、不登记 GM）")
				var sh_void: Projectile = Ordnance.make_shell(carrier, Vector2(60.0, 60.0), false, _s.rng)
				sh_void.from = Vector2(60.0, 60.0)
				sh_void.to = Vector2(60.0, 60.0)
				var rings0: int = _s.count_impact_rings()
				_s._on_proj_landed(sh_void)
				_chk(_s.count_impact_rings() == rings0 + 1,
					"炮弹落在空场：照常落地爆炸（不再因为飞出竞技场边界就消失）")
				# 河不可走，桥可走
				var blocked: Dictionary = _s._blocked_cells()
				_chk(blocked.has(Vector2i(10, 20)), "河面不可移动")
				_chk(not blocked.has(Vector2i(4, 20)) and not blocked.has(Vector2i(16, 20)),
					"两座桥是正常地板（可移动）")
				_chk(not blocked.has(Vector2i(10, 18)), "河外的地板可移动")
				# 出生点
				print("    国王 %s / %s ｜ 公主左 %s 右 %s ｜ 英雄 %s" % [
					pos_of("老国王"), pos_of("老国王 (E)"), pos_of("公主·左"), pos_of("公主·右"),
					[pos_of("Gerald"), pos_of("Alette"), pos_of("Airburst mortar")]])
				_chk(pos_of("老国王") == Vector2i(10, 0) and pos_of("老国王 (E)") == Vector2i(10, 40),
					"双方国王居中在两条宽边上")
				_chk(pos_of("公主·左") == Vector2i(5, 3) and pos_of("公主·右") == Vector2i(15, 3),
					"我方两个公主在国王前方左右各 5 格")
				_chk(pos_of("公主·左 (E)") == Vector2i(5, 37) and pos_of("公主·右 (E)") == Vector2i(15, 37),
					"敌方两个公主镜像对称")
				_chk(pos_of("Gerald") == Vector2i(9, 18) and pos_of("Alette") == Vector2i(10, 18)
					and pos_of("Airburst mortar") == Vector2i(11, 18),
					"三个英雄出生在河边居中三格")
				_chk(pos_of("Gerald (E)") == Vector2i(9, 22) and pos_of("Alette (E)") == Vector2i(10, 22),
					"敌方英雄在河另一侧的居中三格（两边一样）")
				# 公主常备哨兵 = 射界 12（4 个公主都在警戒）
				var pr = unit_by("公主·左")
				_chk(_s.gm.has_sentry(pr) and pr.rng_max == 12, "公主常备哨兵、射界 12 格")
				_chk(_s.gm.sentries.size() == 4, "场上应有 4 个常备哨兵（4 个公主）")
				_chk(Level.is_bridge(Vector2i(5, 20), "arena") and not Level.is_bridge(Vector2i(6, 20), "arena"),
					"桥格判定正确（x=5 是桥，x=6 是水）")
				_s._cam_focus = Vector3(10.0, 0.0, 20.0)
				_s._zoom = 26.0
				_s._update_camera()
				_t0 = _t
				_stage = 1
		1:
			if _t - _t0 >= 0.2:
				_shot("arena_top.png")
				# 近距离看一眼河道与桥
				_s._cam_focus = Vector3(10.0, 0.0, 20.0)
				_s._zoom = 12.0
				_s._update_camera()
				_t0 = _t
				_stage = 2
		2:
			if _t - _t0 >= 0.2:
				_shot("arena_river.png")
				print("\n[2] 打到河里")
				# 让迫击炮朝河里开一炮，河道上方站一个靶子看它挨不挨炸
				var mortar = unit_by("Airburst mortar")
				mortar.cell = Vector2i(10, 16)
				if mortar.visual != null:
					mortar.visual.position = Vector3(10.5, 0.0, 16.5)
				var guard = unit_by("Gerald")
				guard.cell = Vector2i(10, 18)          # 紧贴河岸
				if guard.visual != null:
					guard.visual.position = Vector3(10.5, 0.0, 18.5)
				guard.power_cur = guard.power_max
				guard.armor_cur = Rules.points_to_milli(10)
				_guard = guard
				_s.clear_projectiles()
				var rings: int = _s.count_impact_rings()
				_s._spawn_shell(mortar, Vector2(10.5, 20.5), false)   # 落点在河中央
				_t0 = _t
				_stage = 3
		3:
			if _t - _t0 >= 0.05:
				var alive: int = _s.live_projectiles()
				print("    飞行中：场上弹道物 %d ｜ 杰拉尔德力量 %d" % [alive, _guard.power_cur])
				_chk(alive >= 1, "炮弹在飞")
				_t0 = _t
				_stage = 4
		4:
			# 等炮弹落地（河道在 y=20 附近，3 格/秒 -> 2 秒足够）
			if _t - _t0 >= 2.2:
				var hit_river := false
				for lg in _s._debug_log:
					if String(lg).contains("落进河里"):
						hit_river = true
				print("    落河后：场上弹道物 %d ｜ 杰拉尔德力量 %d ｜ 日志命中=%s" % [
					_s.live_projectiles(), _guard.power_cur, hit_river])
				_chk(hit_river, "炮弹落进河里应记录「落进河里」")
				_chk(_guard.power_cur == _guard.power_max, "落河不产生爆炸伤害")
				_chk(_s.count_impact_rings() == 0, "落河不留红圈")
				_shot("arena_after.png")
				# ── 枪榴弹在空中被打掉：整发直接消失（第 96 轮；以前会就地落地/立模型）──
				print("\n[3] 枪榴弹在空中被打掉")
				var sani_g = unit_by("萨尼铁塔")
				var gp_r := Ordnance.make_grenade(sani_g, Vector2(10.5, 20.5), true)
				gp_r.from = Vector2(10.5, 20.5)
				gp_r.to = Vector2(10.5, 20.5)
				var models_before: int = _s._grenade_models.size()
				var pend_before: int = _s.gm.pending.size()
				_s._debug_log.clear()
				_s._shell_intercepted(gp_r, "在半空被打爆")
				var gone_log := false
				var river_log := false
				for lg in _s._debug_log:
					if String(lg).contains("直接消失"):
						gone_log = true
					if String(lg).contains("落进河里"):
						river_log = true
				print("    (10,20) 是河=%s ｜ 模型 %d -> %d ｜ GM %d -> %d ｜ 直接消失=%s ｜ 落河日志=%s" % [
					Level.is_river(Vector2i(10, 20), "arena"), models_before, _s._grenade_models.size(),
					pend_before, _s.gm.pending.size(), gone_log, river_log])
				_chk(gone_log and not river_log,
					"被击落的枪榴弹整发直接消失（不落地、不爆炸，连河面规则都不走）")
				_chk(_s._grenade_models.size() == models_before and _s.gm.pending.size() == pend_before,
					"不许立枪榴弹模型、也不登记 GM 计时（第 96 轮）")
				# ── 复活点（第 87 轮）：必须在老国王正前方那一行，不许回河边 ──
				print("\n[4] 英雄复活点")
				var gz = unit_by("Gerald")
				var roster_cell: Vector2i = gz.home_cell
				var hs: Array = Level.respawn_cells(gz.side)
				gz.power_cur = 0
				_s._on_unit_died(gz)
				_s.gm.revive_at[gz] = _s.gm.turn_count            # 立刻到点
				for ru in _s.gm.due_revives():
					_s._revive_hero(ru)
				print("    开局出场格 %s ｜ 关卡重生点 %s ｜ 复活格 %s ｜ 国王 %s" % [
					roster_cell, hs, gz.cell, pos_of("老国王")])
				_chk(hs.has(gz.cell), "复活回到关卡给的英雄重生点（%s）" % [hs])
				_chk(gz.cell.y == 3 and gz.cell.x >= 8 and gz.cell.x <= 12,
					"复活格在老国王正前方那一行（y=3），不再回河边")
				var mid_x := 0
				for c3 in hs:
					mid_x += (c3 as Vector2i).x
				mid_x = mid_x / hs.size()
				_chk(gz.cell == Vector2i(8, 3) and mid_x == 10,
					"第一个复活的落在 (8,3)，三个重生格的中心 = 两公主中点 (10,3)")
				_chk(roster_cell == Vector2i(9, 18) and gz.cell != roster_cell,
					"开局的出场格（河边）与复活格已经分开")
				var az = unit_by("Alette")
				az.power_cur = 0
				_s._on_unit_died(az)
				_s.gm.revive_at[az] = _s.gm.turn_count
				for ru2 in _s.gm.due_revives():
					_s._revive_hero(ru2)
				print("    第二个复活的人（Alette）→ %s" % [az.cell])
				_chk(az.cell != gz.cell and hs.has(az.cell), "第二个人换一格站（三格分开）")
				print("\n── 竞技场探针：%d 张截图，失败 %d 项 ──" % [_shots, _fail])
				Level.current = "field"            # 收尾：恢复默认关卡
				return true
	return false


func unit_by(nm: String) -> Unit:
	for u in _s.units:
		if u.name == nm:
			return u
	return null


func pos_of(nm: String) -> Vector2i:
	var u := unit_by(nm)
	return u.cell if u != null else Vector2i(-999, -999)
