# 午餐盒炮塔建模探针（第 105 轮用户口径）
#
# 用户原话：
#   「我是想**一根棍子支撑着一个水平放置的六边形棱柱炮管的 2/3 处**（**前 2/3 后 1/3**），
#     **六边形棱柱长 0.7 格并且要比现在大**，
#     **六边形棱柱的中轴线（从上面的六边形的中心点到底面六边形的中心点）为瞄准方向**，
#     **变红的时候整根一起变红**同时**冷却的时候也要逐渐变黑**，
#     **变红的同时要变亮**（**你在加一个热量与亮度的映射**）」
#
# 运行： exe --headless --path game --script res://tools/probe_turret.gd --quit-after 60000
extends SceneTree

var _fails: Array[String] = []
var _checks := 0


func _chk(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("  PASS  ", label)
	else:
		print("  FAIL  ", label)
		_fails.append(label)


func _initialize() -> void:
	var m: LunchboxModel = LunchboxModel.make()
	root.add_child(m)
	await process_frame

	print("[1] 炮管 = 水平放置的正六边形棱柱，长 0.70 格，比旧值大")
	# ⚠ 必须用模块自己的门面定位炮管：车顶右侧的巡飞弹发射器**也有一圈六边形光环**
	#   （同样 radial_segments == 6），靠"找六边形"会抓错东西。
	var prism: MeshInstance3D = m.t_prism()
	_chk(prism != null, "找得到六边形棱柱炮管（按模块门面，不是『找六边形』）")
	_chk(prism == null or prism.name == LunchboxModel.BARREL_PRISM_NAME,
		"炮管节点有稳定名字 %s" % LunchboxModel.BARREL_PRISM_NAME)
	if prism == null:
		_finish()
		return
	var cm := prism.mesh as CylinderMesh
	_chk(cm.radial_segments == 6, "炮管截面是正六边形（radial_segments = 6）")
	_chk(absf(cm.height - 0.70) < 0.0001, "棱柱长 = %.3f 格（要求 0.70）" % cm.height)
	_chk(cm.top_radius > 0.30 and cm.bottom_radius > 0.30,
		"棱柱半径 %.3f 比旧值 0.24 大（用户要求『要比现在大』）" % cm.top_radius)
	# 水平放置：轴要沿**水平**方向（局部 +z），不能是竖直的 +y
	_chk(absf(prism.rotation_degrees.x - 90.0) < 0.001,
		"棱柱轴已从 +y 转到 +z（水平放置，rotation.x = 90°）")

	print("\n[2] 支点在棱柱的**前 2/3 / 后 1/3** 处")
	# 量棱柱在「瞄准轴」上的两端到支点（= _barrel 的原点）的距离
	var pivot: Node3D = prism.get_parent() as Node3D
	var z_c: float = prism.position.z                    # 棱柱中心相对支点的偏移
	var half := cm.height * 0.5
	var back: float = -(z_c - half)                      # 尾端到支点（正数）
	var front: float = z_c + half                        # 前端到支点
	print("      棱柱中心相对支点 z = %.4f ｜ 尾端距支点 %.4f ｜ 前端距支点 %.4f" % [z_c, back, front])
	_chk(back > 0.0 and front > 0.0, "支点**落在棱柱内部**（不是支在端点或外面）")
	var ratio: float = front / back
	print("      前 : 后 = %.3f : 1（期望 2.000 : 1）" % ratio)
	_chk(absf(ratio - 2.0) < 0.02, "支点在前 2/3 处（前:后 = %.3f:1，要求 2:1）" % ratio)
	_chk(absf((front + back) - 0.70) < 0.0001,
		"两端间距 = 棱柱长 %.4f" % (front + back))

	print("\n[3] 支架是一根**棍子**（不是方块底座）")
	var stick: MeshInstance3D = null
	for c in m.get_children():
		if c is MeshInstance3D:
			var mm := (c as MeshInstance3D).mesh
			if mm is CylinderMesh and (mm as CylinderMesh).radial_segments == 8:
				stick = c
	_chk(stick != null, "支架是圆柱（棍子），不是 BoxMesh 方块")
	if stick != null:
		var scm := stick.mesh as CylinderMesh
		_chk(scm.top_radius < 0.1 and scm.bottom_radius < 0.1,
			"棍子很细（半径 %.3f）" % scm.top_radius)

	print("\n[4] 瞄准轴 = 棱柱中轴线（给 theta/phi 后，棱柱前端朝那个方向）")
	# theta=0, phi=0 -> 方向应为本地 +x（车头朝 +z 时 theta 从 +x 起算，见 set_aim 的 90-theta）
	m.set_aim(0.0, 0.0)
	var fwd := _prism_axis_world(m, prism)
	print("      theta=0  phi=0  棱柱轴世界方向 = %s" % str(fwd))
	_chk(absf(fwd.y) < 0.02, "phi=0 时中轴线是**水平**的（y 分量 %.3f ≈ 0）" % fwd.y)
	m.set_aim(0.0, 30.0)
	var up := _prism_axis_world(m, prism)
	print("      theta=0  phi=30 棱柱轴世界方向 = %s" % str(up))
	_chk(up.y > 0.4, "phi=+30° 时中轴线**抬起来**了（y 分量 %.3f）" % up.y)
	m.set_aim(90.0, 0.0)
	var other := _prism_axis_world(m, prism)
	_chk(absf(other.x) < 0.02 and absf(other.z) > 0.9 or absf(other.z - 1.0) < 0.05,
		"theta=90° 时中轴线转向另一条水平轴（%s）" % str(other))
	_chk(absf(fwd.dot(other)) < 0.05, "theta 0° 与 90° 的中轴线**互相垂直**（%.3f）" % fwd.dot(other))

	print("\n[5] 热量 -> 颜色 + 亮度（整根一起变红、变红同时变亮）")
	var mat: StandardMaterial3D = prism.material_override as StandardMaterial3D
	_chk(mat != null, "棱柱用**单一材质**覆盖整根 -> 天然『整根一起变红』")
	var samples: Array = []
	for i in 6:
		var r := float(i) / 5.0
		m.set_heat_ratio(r)
		var lum: float = mat.albedo_color.r * 0.299 + mat.albedo_color.g * 0.587 + mat.albedo_color.b * 0.114
		var em: float = mat.emission_energy_multiplier
		samples.append({"r": r, "col": mat.albedo_color, "lum": lum, "em": em})
		print("      热量 %.1f -> 颜色(%.3f, %.3f, %.3f) 亮度(材质亮度 %.4f ｜ 自发光倍率 %.3f)" % [
			r, mat.albedo_color.r, mat.albedo_color.g, mat.albedo_color.b, lum, em])
	# 颜色：红分量单调增、绿蓝单调减（越来越红）
	var col_ok := true
	var em_ok := true
	for i in range(1, samples.size()):
		if samples[i]["col"].r < samples[i - 1]["col"].r - 0.0001:
			col_ok = false
		if samples[i]["em"] < samples[i - 1]["em"] - 0.0001:
			em_ok = false
	_chk(col_ok, "红色分量随热量**单调增**（越来越红）")
	_chk(em_ok, "**亮度**（自发光倍率）随热量**单调增**（变红的同时变亮）")
	_chk(samples[0]["col"].r < 0.10 and samples[5]["col"].r > 0.95,
		"热量 0 近黑（r=%.3f）、热量 1 最红（r=%.3f）" % [samples[0]["col"].r, samples[5]["col"].r])
	_chk(samples[5]["em"] > samples[0]["em"] * 3.0,
		"最红时亮度显著高于冷却时（%.2f vs %.2f）" % [samples[5]["em"], samples[0]["em"]])
	# 冷却平滑：取 5 个中间点验证不是跳变
	var max_step := 0.0
	for i in range(1, samples.size()):
		max_step = maxf(max_step, absf(samples[i]["lum"] - samples[i - 1]["lum"]))
	print("      相邻采样点最大亮度跳变 = %.4f（5 等分采样 -> 平滑则不应有大跳变）" % max_step)
	_chk(max_step < 0.25, "亮度是**平滑**变化（最大单步跳变 %.4f < 0.25）" % max_step)
	# 材质在热量 0 时也处于"开启自发光"状态 -> 冷却过程连续变暗而不是某一刻突然跳黑
	m.set_heat_ratio(0.0)
	_chk(mat.emission_enabled, "热量 0 时自发光仍**开启**（靠倍率连续降到最低，不会中途跳黑）")
	m.set_heat_ratio(1.0)
	_chk(mat.emission_enabled, "热量 1 时自发光开启")

	_finish()


## 在整棵子树里找 radial_segments == 6 的 CylinderMesh
func _find_hex(n: Node) -> MeshInstance3D:
	for c in n.get_children():
		if c is MeshInstance3D:
			var mm := (c as MeshInstance3D).mesh
			if mm is CylinderMesh and (mm as CylinderMesh).radial_segments == 6:
				return c
		var got := _find_hex(c)
		if got != null:
			return got
	return null


## 棱柱中轴线在**世界**里的方向（顶面中心 - 底面中心）
## ⚠ 必须用 `global_transform`：`prism.transform` 是**相对父节点 (高低机)** 的，
##    用它量出来的中轴线**不含方向机/高低机的旋转**（第一版探针就是这么假失败的 ——
##    模型其实是对的，量错了）。
func _prism_axis_world(m: LunchboxModel, prism: MeshInstance3D) -> Vector3:
	var half := (prism.mesh as CylinderMesh).height * 0.5
	var top_w: Vector3 = prism.global_transform * Vector3(0.0, half, 0.0)
	var bot_w: Vector3 = prism.global_transform * Vector3(0.0, -half, 0.0)
	return (top_w - bot_w).normalized()


func _finish() -> void:
	print("\n── 炮塔建模探针：%d 项检查，失败 %d 项 ──" % [_checks, _fails.size()])
	for f in _fails:
		print("   - ", f)
	quit(1 if _fails.size() > 0 else 0)
