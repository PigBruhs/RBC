# 通用截图工具（第 108 轮）：**带真实窗口**跑，才能拿到 framebuffer。
#
# ⚠ 两个坑，都是实测踩出来的：
#   ① **不要用 `--headless`** —— 那是渲染桩，`get_texture().get_image()` 返回 null。
#      正确命令：
#        Godot_..._console.exe --path game --rendering-driver opengl3 \
#            --resolution 1600x900 --script res://tools/shot_level.gd
#   ② **`get_image()` 拿的是"上一帧"** —— 设完相机参数**在同一帧截图**的话，
#      拍到的是**改之前**那一帧（实测：改 zoom 后图与改之前 sha256 完全一致）。
#      所以流程是：第 SET_FRAME 帧设好参数 → 等几帧 → 第 SHOT_FRAME 帧才截。
#
# 用法：改 LEVEL（field/arena/reaper）。
extends SceneTree

const LEVEL := "reaper"          # field / arena / reaper
const OUT_PREFIX := "shot_"
const SET_FRAME := 12            # 这一帧调整相机（注视点 + 视野）
const SHOT_FRAME := 20           # 这一帧才截图（比 SET 晚几帧，避开"上一帧"问题）
const FIT_FRAC := 0.75           # 视野 = 可到达区最长边 × 这个系数

var _s: Node
var _f := 0


func _initialize() -> void:
	Level.current = LEVEL
	_s = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(_s)


func _process(_d: float) -> bool:
	_f += 1
	if _f == SET_FRAME:
		_setup_camera()
		return false
	if _f != SHOT_FRAME:
		return _f > SHOT_FRAME
	_do_shot()
	return true


func _setup_camera() -> void:
	# 相机注视点 = 可到达区中心（`_cam_focus` 初值是世界原点，大地图会对着空地形）
	var pr := Level.play_rect(LEVEL)
	_s._cam_focus = Vector3(float(pr[0]) + float(pr[2]) * 0.5, 0.0,
		float(pr[1]) + float(pr[3]) * 0.5)
	# 视野按可到达区最长边放大（否则 41×65 的地图、zoom 15 只看得见约 27×15 格）
	var need: float = maxf(float(pr[2]), float(pr[3])) * FIT_FRAC
	if need > _s._zoom:
		_s._zoom = need
	_s.aim.update_camera()
	print("[shot] 相机就位：注视点=%s ｜ 视野 size=%.1f ｜ 可到达区 %dx%d" % [
		str(_s._cam_focus), _s._camera.size, pr[2], pr[3]])


func _do_shot() -> void:
	print("[shot] level=%s ｜ 视口 %s" % [LEVEL, str(root.get_visible_rect().size)])
	var pr := Level.play_rect(LEVEL)
	# 单位投影到相机空间，确认它们**真的在画面里**（不然图是空的也看不出来）
	var half_h: float = _s._camera.size * 0.5
	var half_w: float = half_h * 1.7778
	var inside := 0
	for u in _s.units:
		var p := Vector3(float(u.cell.x) + 0.5, 0.5, float(u.cell.y) + 0.5)
		var cs: Vector3 = _s._camera.global_transform.affine_inverse() * p
		if absf(cs.x) < half_w and absf(cs.y) < half_h and cs.z < 0.0:
			inside += 1
	print("   单位 %d 个，其中 %d 个在画面内（可到达区 %s）" % [
		_s.units.size(), inside, str(pr)])
	for u in _s.units:
		print("     %-28s side=%d cell=%s" % [u.name, u.side, str(u.cell)])
	_shot("%s%s_overview.png" % [OUT_PREFIX, LEVEL])


func _shot(n: String) -> void:
	var img: Image = root.get_texture().get_image()
	if img == null:
		print("  ⚠ get_image() 返回 null —— 没在真实窗口里跑（别用 --headless）")
		return
	img.save_png("user://%s" % n)
	print("  [shot] 已保存 user://%s" % n)
