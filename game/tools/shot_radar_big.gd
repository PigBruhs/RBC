# 雷达锁定 HUD 的**肉眼核对二**（第 111 轮）：① 左侧带距离 ② 框大时字也大
# 拍两张：普通角色（1×1）与 **Reaper（体半径 3 -> 6×6 的大框）** 各一张。
extends SceneTree

const LEVEL := "reaper"
const SET_FRAME := 12
const SHOT_FRAME := 24
var _s: Node
var _f := 0
var _mode := 0          # 0 = Reaper 大框；1 = 普通角色


func _initialize() -> void:
	Level.current = LEVEL
	_s = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(_s)


func _process(_d: float) -> bool:
	_f += 1
	if _f == SET_FRAME:
		_setup()
		return false
	if _f != SHOT_FRAME:
		return _f > SHOT_FRAME
	_shot()
	return true


func _setup() -> void:
	var radar: Unit = null
	var reaper: Unit = null
	var foe: Unit = null
	for u in _s.units:
		if u == null:
			continue
		if u.name == "雷达午餐盒":
			radar = u
		if u.name == "Reaper":
			reaper = u
		if foe == null and u.is_alive() and u.side != 0 and u.name != "Reaper":
			foe = u
	if radar == null:
		print("  ⚠ 找不到雷达")
		return
	# 锁 Reaper（体半径 3 -> 大框），把它挪到雷达附近让两者同框
	var target: Unit = reaper if reaper != null else foe
	target.cell = radar.cell + Vector2i(4, 2)
	target.visual.position = Vector3(float(target.cell.x) + 0.5, target.visual.position.y,
		float(target.cell.y) + 0.5)
	_s.t_radar_begin_lock("雷达午餐盒", target.name)
	# 故意让它停在"锁定中"（才能同时看到剩余回合 + 距离）
	var st = _s.t_radar_state("雷达午餐盒")
	st.lock_left = 3
	_s._radar_tick_huds()
	print("[shot] 锁定 %s ｜ 框尺寸 %s ｜ 左上='%s' ｜ 右上='%s'" % [
		target.name, str(RadarHud.size_for(target)), "", ""])
	var hud = _s._radar_huds.get(target.name, null)
	if hud != null:
		print("      左上='%s' ｜ 右上='%s' ｜ 字号=%d" % [
			hud.t_left_text(), hud.t_right_text(), hud.t_left_font_size()])
	# 相机对准**被锁定目标本身**（大框很高，对准它才能把框+角标一起框进画面）
	var tp := GridMath.unit_pos(target)
	_s._cam_focus = Vector3(tp.x, Targeting.aim_height(target) + 1.0, tp.y)
	_s._zoom = 26.0
	_s.aim.update_camera()


func _shot() -> void:
	var img: Image = root.get_texture().get_image()
	if img == null:
		print("  ⚠ get_image() 返回 null —— 别用 --headless")
		return
	img.save_png("user://shot_radar_big.png")
	print("  [shot] 已保存 user://shot_radar_big.png")
