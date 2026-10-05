# 单位特写截图（第 109 轮）：把相机对准**某一个单位**拍近景，用来肉眼核对模型细节
#   （全局俯瞰图里 3 格高的发射器只有几个像素，看不出"连没连上"）
#
# ⚠ 同 `shot_level.gd` 的两个坑：① 不要 `--headless`；② 设完相机**等几帧**再截。
# 用法：
#   Godot_..._console.exe --path game --rendering-driver opengl3 --resolution 1600x900 \
#       --script res://tools/shot_unit.gd
extends SceneTree

const LEVEL := "reaper"
const TARGET := "轮式齐射午餐盒"
const ZOOM := 3.0                # 特写：视野 3 格（默认 15）
const SET_FRAME := 12
const SHOT_FRAME := 20
var _s: Node
var _f := 0
var _u: Unit = null


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
	for u in _s.units:
		if u != null and u.name == TARGET:
			_u = u
			break
	if _u == null:
		print("  ⚠ 找不到单位 %s" % TARGET)
		return
	# 注视点 = 该单位的**视觉位置**（走路中就是它真正所在），略抬高到模型中部
	var p := GridMath.unit_pos(_u)
	_s._cam_focus = Vector3(p.x, 1.5, p.y)
	_s._zoom = ZOOM
	_s.aim.update_camera()
	print("[shot] 特写 %s ｜ 格 %s ｜ 注视点 %s ｜ 视野 %.1f" % [
		TARGET, str(_u.cell), str(_s._cam_focus), ZOOM])


func _shot() -> void:
	var img: Image = root.get_texture().get_image()
	if img == null:
		print("  ⚠ get_image() 返回 null —— 别用 --headless")
		return
	var n := "shot_unit_%d.png" % Time.get_ticks_msec()
	img.save_png("user://%s" % n)
	print("  [shot] 已保存 user://%s" % n)
