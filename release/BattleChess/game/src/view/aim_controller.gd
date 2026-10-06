# ══════════════════════════════════════════════════════════════════════════════
# 瞄准 / 拖拽输入 / 相机 / 鼠标拾取
#
# 职责：
#   · 拖拽瞄准：charge_from_drag 把屏幕位移映射成力度，aim_range 映射成射程
#     （手感常量来自 UnitData.THROW_DRAG_MIN/MAX 与 ARROW_LEN_MIN/MAX）
#     ⚠️ 直升机的「瞄准结果翻倍」（Level.heli()["aim_mult"] = 2.0）**不在这一层** ——
#        它在**发射时**应用（projectile_sink.rocket_salvo 里的 doubled）。
#        这里只算出原始落点，**别在这里加倍**，否则会翻成 4 倍。
#   · update_aim 算浮点落点（**不做格子吸附**）与 _planned_cell
#   · fire 是拖拽松手那条入口：只负责"算出打哪里"，然后交给唯一入口 perform_basic
#   · 相机：_cam_yaw 来自 Level.cam_yaw()、注视点来自 Level.cam_center()；
#     WASD 平移 / 滚轮缩放；**Q/E 不负责升降**（第 90 轮起专给巡飞弹制导）
#   · 鼠标拾取：pick_cell / hover_cell
#
# 二次确认（第一次出黄勾）用的是放置状态机 _set_pending / _same_pending ——
# 那是 sandbox_runner 的地盘，本模块**只读不搬**（调用点在宿主的输入处理里）。
#
# 宿主是 battle_scene（Node3D）。_st 动态类型（写 `: Node3D` 编译不过），同其它模块。
# ══════════════════════════════════════════════════════════════════════════════
class_name AimController
extends RefCounted

var _st = null                 # 宿主（battle_scene）；动态类型见文件头


func _init(host: Node3D) -> void:
	_st = host

## 进入拖拽瞄准（普攻与技能共用同一套手感；具体打什么由调用方决定）
func begin_aim() -> void:
	_st._action_menu.visible = false
	_st.phase = _st.Phase.AIMING
	_st._aim_active = true
	_st._aim_valid = false
	_st._planned_cell = Vector2i(-1, -1)     # 必须重置！否则残留上一发的落点/默认 (0,0) 会被当成有效目标
	_st._aim_origin = _st.get_viewport().get_mouse_position()
	_st._aim_now = _st._aim_origin
	_st._arrow_root.visible = true
	_st.reachable = {}
	_st.attackable = {}
	_st.fx.clear_hints()
	_st._refresh_all()




func charge_from_drag(px: float) -> float:
	return clampf((px - UnitData.THROW_DRAG_MIN) / (UnitData.THROW_DRAG_MAX - UnitData.THROW_DRAG_MIN), 0.0, 1.0)




func aim_range(t: float) -> float:
	return UnitData.THROW_RANGE_MIN + (UnitData.THROW_RANGE_MAX - UnitData.THROW_RANGE_MIN) * t * t




func arrow_len_for_t(t: float) -> float:
	var mult := UnitData.ARROW_LEN_MIN + (UnitData.ARROW_LEN_MAX - UnitData.ARROW_LEN_MIN) * t * t
	return mult * UnitData.UNIT_HEIGHT



func update_aim(mouse: Vector2) -> void:
	_st._aim_now = mouse
	var origin3 := Vector3(float(_st.active.cell.x) + 0.5, 0.0, float(_st.active.cell.y) + 0.5)
	var from: Vector3 = _st._camera.project_ray_origin(mouse)
	var dir: Vector3 = _st._camera.project_ray_normal(mouse)
	if absf(dir.y) < 0.0001:
		return
	var t := -from.y / dir.y
	if t < 0.0:
		return
	var target := from + dir * t
	var flat := Vector2(target.x - origin3.x, target.z - origin3.z)
	if flat.length() < 0.15:
		_st._arrow_root.visible = false
		_st._aim_valid = false
		return
	var dir2 := flat.normalized()
	var drag_px: float = _st._aim_origin.distance_to(mouse)
	var charge: float = charge_from_drag(drag_px)
	var dist: float = aim_range(charge)
	_st._planned_cell = Vector2i(int(floor(origin3.x + dir2.x * dist)), int(floor(origin3.z + dir2.y * dist)))
	_st._aim_valid = true
	_st._aim_float_pos = Vector2(origin3.x + dir2.x * dist, origin3.z + dir2.y * dist)

	_st._arrow_root.visible = true
	# 箭头从【投掷手身前】沿方向贴地伸出，长度 = 射程（3~20 格 → 1~3 倍身高）
	var start := Vector3(origin3.x, 0.32, origin3.z) + Vector3(dir2.x, 0, dir2.y) * 0.34
	var d := Vector3(dir2.x, 0.0, dir2.y).normalized()
	var bx := d.cross(Vector3.UP).normalized()
	var bz := bx.cross(d).normalized()
	_st._arrow_root.position = start
	_st._arrow_root.basis = Basis(bx, d, bz)      # b.y = d（杆的轴向）
	var total_len: float = arrow_len_for_t(charge)
	var head_len := clampf(total_len * 0.34, 0.42, 0.85)   # 箭头三角锥长度
	var shaft_len := maxf(0.12, total_len - head_len)
	_st._shaft.scale = Vector3(1.0, shaft_len, 1.0)
	_st._shaft.position = Vector3(0, shaft_len * 0.5, 0)
	_st._head.scale = Vector3(1.0, head_len, 1.0)
	_st._head.position = Vector3(0, shaft_len + head_len * 0.5, 0)
	_st._status.text = "力度 %d%%  射程 %.1f 格（箭头 %.1f 倍身高）  %s" % [
		int(round(charge * 100.0)), dist, total_len / UnitData.UNIT_HEIGHT,
		aim_preview_text(_st._planned_cell)]




func aim_preview_text(center: Vector2i) -> String:
	if center.x < 0 or _st.active == null:
		return ""
	var parts: Array[String] = []
	for o in _st.units:
		if not o.is_alive() or o == _st.active:
			continue
		if not Targeting.blast_covers(Vector2(float(center.x) + 0.5, float(center.y) + 0.5), o.cell, _st.BLAST_RADIUS):
			continue
		var eff_res: int = o.pr / 2                      # 炮击无视 50% 物抗
		var p: Rules.Preview = Rules.preview(_st.active.power_cur, o.armor_cur, eff_res)
		var seg := "%s:破甲%s" % [o.name, _st._fmt(_st.active.armor_break)]
		if p.branch == Rules.Branch.NO_DAMAGE:
			seg += "+力量打不动"
		elif p.branch == Rules.Branch.ROLL:
			seg += "+力量1(%d%%)" % p.hit_percent
		else:
			seg += "+力量%d" % p.damage
		if o.side == _st.active.side:
			seg = "[友军]" + seg
		parts.append(seg)
	if parts.is_empty():
		return "落点无单位"
	return "影响→ " + " ｜ ".join(parts)




func fire() -> void:
	if not _st._aim_active or _st.active == null:
		return
	# 还没算出有效落点（例如按下就松开、鼠标没动过）：不消耗回合，继续瞄准
	if not _st._aim_valid:
		return
	var thrower: Unit = _st.active
	var fpos: Vector2 = _st._aim_float_pos
	var skill_id: String = _st._aim_skill_id
	_st._arrow_root.visible = false
	_st._aim_active = false
	_st._aim_valid = false
	_st._planned_cell = Vector2i(-1, -1)

	# ── 技能：交给唯一的技能入口（玩家与 AI 同一条生产线）──
	if skill_id != "":
		_st._aim_skill_id = ""
		_st._skill_info_text = ""
		if not _st.skills_mod.perform_skill(thrower, skill_id, fpos, Vector2i(int(floor(fpos.x)), int(floor(fpos.y)))):
			_st.action_menu.show_action_menu()
		return

	# ── 普攻：交给唯一的普攻入口（近战/弓箭/连发/投掷/火箭齐射都在里面分派）──
	# 用户口径：投掷手是"玩家操作决定上下限"的角色，**一定要允许失误**：
	# 这里不做任何射程/边界检查 —— 打偏、打出界都照打（炮弹飞到边界处消失）。
	if not _st.attack.perform_basic(thrower, fpos):
		_st.action_menu.show_action_menu()




func build_camera() -> void:
	_st._camera = Camera3D.new()
	_st._camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_st._camera.name = "Cam"
	_st.add_child(_st._camera)
	_st._cam_focus = Vector3(Level.cam_center().x, 0.0, Level.cam_center().y)
	update_camera()



func update_camera() -> void:
	if _st._camera == null:
		return
	_st._camera.size = _st._zoom
	var pitch: float = deg_to_rad(_st.CAM_PITCH)
	var yaw: float = deg_to_rad(_st._cam_yaw)
	var dir: Vector3 = Vector3(cos(pitch) * cos(yaw), -sin(pitch), cos(pitch) * sin(yaw))
	_st._camera.position = _st._cam_focus + dir * _st.CAM_DIST + Vector3(0, _st._cam_height, 0)
	_st._camera.look_at(_st._cam_focus + Vector3(0, _st._cam_height, 0), Vector3.UP)



func camera_process(delta: float) -> void:
	var move := Vector2.ZERO
	if Input.is_key_pressed(KEY_W): move.y -= 1.0
	if Input.is_key_pressed(KEY_S): move.y += 1.0
	if Input.is_key_pressed(KEY_A): move.x -= 1.0
	if Input.is_key_pressed(KEY_D): move.x += 1.0
	if move == Vector2.ZERO:
		return
	# 平移方向取自相机自身的朝向（投影到地面），所以按 W 就是"画面上方"，
	# 不会像之前那样按固定 45° 轴换算导致上下左右反向。
	var speed: float = _st._zoom * 0.9 * delta
	var basis: Basis = _st._camera.global_transform.basis
	var fwd := Vector3(basis.z.x, 0.0, basis.z.z)      # 相机看向的反方向 = 画面里的"上"
	var right := Vector3(basis.x.x, 0.0, basis.x.z)
	if fwd.length() > 0.001:
		fwd = fwd.normalized()
	if right.length() > 0.001:
		right = right.normalized()
	_st._cam_focus += (fwd * move.y + right * move.x) * speed
	# 平移只允许在【可行动区域】附近（空场没什么好看的，别让相机漂到 100×100 中间去）
	_st._cam_focus.x = clampf(_st._cam_focus.x, float(_st.PX) - 8.0, float(_st.PX + _st.PW) + 8.0)
	_st._cam_focus.z = clampf(_st._cam_focus.z, float(_st.PY) - 8.0, float(_st.PY + _st.PH) + 8.0)
	update_camera()



func hover_cell() -> Variant:
	var mp: Vector2 = _st.get_viewport().get_mouse_position()
	var from: Vector3 = _st._camera.project_ray_origin(mp)
	var dir: Vector3 = _st._camera.project_ray_normal(mp)
	if absf(dir.y) < 0.0001:
		return null
	var t := -from.y / dir.y
	if t < 0.0:
		return null
	var p := from + dir * t
	var c := Vector2i(int(floor(p.x)), int(floor(p.z)))
	if not Level.in_play(c):
		return null
	return c



func pick_cell(mouse: Vector2) -> Variant:
	var from: Vector3 = _st._camera.project_ray_origin(mouse)
	var dir: Vector3 = _st._camera.project_ray_normal(mouse)
	if absf(dir.y) < 0.0001:
		return null
	var t := -from.y / dir.y
	if t < 0.0:
		return null
	var p := from + dir * t
	var cell := Vector2i(int(floor(p.x)), int(floor(p.z)))
	if not Level.in_play(cell):
		return null
	return cell

