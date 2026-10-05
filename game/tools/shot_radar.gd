# 雷达锁定 HUD 的**肉眼核对**截图（第 111 轮）
#   arena 关：把雷达放到 Gerald (E) 附近 -> 锁定 -> 拍一张，看荧光绿矩形 + 左上数字 / 右上状态。
# ⚠ 同 `shot_level.gd` 的两个坑：① 不要 `--headless`；② 设完相机**隔几帧**再截。
extends SceneTree

const LEVEL := "arena"
const SET_FRAME := 12
const SHOT_FRAME := 24
var _s: Node
var _f := 0
var _ok_lock := false


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
	# 找雷达与一个敌人；把相机对准它们之间
	var radar: Unit = null
	var foe: Unit = null
	for u in _s.units:
		if u != null and u.name == "雷达午餐盒":
			radar = u
		if foe == null and u != null and u.is_alive() and u.side != 0:
			foe = u
	if radar == null or foe == null:
		print("  ⚠ 找不到雷达或敌人（radar=%s foe=%s）" % [str(radar), str(foe)])
		return
	# 把敌人挪到雷达旁边（3 格），方便同框
	foe.cell = radar.cell + Vector2i(3, 0)
	foe.visual.position = Vector3(float(foe.cell.x) + 0.5, foe.visual.position.y,
		float(foe.cell.y) + 0.5)
	# 锁定（这个距离 -> 1 回合，选定即锁定，右上应显示"已锁定"）
	_s.t_radar_begin_lock("雷达午餐盒", foe.name)
	_s._radar_tick_huds()
	_ok_lock = _s._radar_huds.get(foe.name, null) != null
	print("[shot] 锁定 %s ｜ HUD 建立=%s ｜ 状态=%s" % [
		foe.name, str(_ok_lock), _s.t_radar_state("雷达午餐盒").desc()])
	# 相机：对准雷达与敌人中点，视野拉近到能看清 HUD
	var mid := (GridMath.unit_pos(radar) + GridMath.unit_pos(foe)) * 0.5
	_s._cam_focus = Vector3(mid.x, 1.2, mid.y)
	_s._zoom = 7.0
	_s.aim.update_camera()


func _shot() -> void:
	var img: Image = root.get_texture().get_image()
	if img == null:
		print("  ⚠ get_image() 返回 null —— 别用 --headless")
		return
	img.save_png("user://shot_radar_hud.png")
	print("  [shot] 已保存 user://shot_radar_hud.png")
