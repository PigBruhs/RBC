# 烟雾拖尾的**肉眼核对**（第 111 轮）：让几发火箭在飞，拍一张看白烟。
extends SceneTree

const LEVEL := "arena"
const HELI := "俯冲轰炸直升机（不要问那么多）"
const SET_FRAME := 10
const DRIVE_FRAMES := 70          # 手动驱动多少帧（让烟拖出来）
const SHOT_FRAME := 22

var _s: Node
var _f := 0


func _initialize() -> void:
	Level.current = LEVEL
	_s = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(_s)


func _process(_d: float) -> bool:
	_f += 1
	if _f == SET_FRAME:
		_setup()
		_drive()
		return false
	if _f != SHOT_FRAME:
		return _f > SHOT_FRAME
	_shot()
	return true


func _setup() -> void:
	var heli: Unit = null
	for u in _s.units:
		if u != null and u.name == HELI:
			heli = u
			break
	if heli == null:
		print("  ⚠ 找不到直升机")
		return
	heli.cell = Vector2i(20, 20)
	heli.visual.position = Vector3(20.5, heli.hover, 20.5)
	_s.clear_projectiles()
	# 三发火箭朝不同方向，方便看拖尾
	var from := Vector3(20.5, heli.hover + 0.5, 20.5)
	for to in [Vector2(20.5, 44.5), Vector2(34.5, 34.5), Vector2(6.5, 34.5)]:
		_s.field.register(Ordnance.make_rocket(heli, from, to, false, _s.rng))
	# 相机对准发射点上方
	_s._cam_focus = Vector3(20.5, 3.0, 28.0)
	_s._zoom = 40.0
	_s.aim.update_camera()


## 手动驱动（不要 await 帧：arena 会判胜负并 quit）
func _drive() -> void:
	for i in DRIVE_FRAMES:
		_s.field.step(1.0 / 60.0)
		_s._tick_smoke(1.0 / 60.0)
	print("[shot] 驱动 %d 帧 ｜ 场上烟雾 = %d ｜ 在飞弹道物 = %d" % [
		DRIVE_FRAMES, _s._smoke.t_live_count(), _s.field.items.size()])


func _shot() -> void:
	var img: Image = root.get_texture().get_image()
	if img == null:
		print("  ⚠ get_image() 返回 null —— 别用 --headless")
		return
	img.save_png("user://shot_smoke.png")
	print("  [shot] 已保存 user://shot_smoke.png")
