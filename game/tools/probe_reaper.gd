# ══════════════════════════════════════════════════════════════════════════════
# Reaper 探针：碰撞圆柱（每单位尺寸）+ 质量效应风建模
#
#   Godot_v4.7.2-stable_win64_console.exe --headless --path game \
#       --script res://tools/probe_reaper.gd --quit-after 60000
#
# 五组断言：
#   ① 默认值等价（**硬判据**）：Unit 的缺省碰撞圆柱 == Damage.BODY_R/BODY_H == Targeting 的常量；
#      既有角色的等价性用"老口径的数值"直接验（body_span / aim_height / 空爆距离）
#      ② Reaper 从数据行读到 3.0 / 12.0
#   ② 横向：半径 3 格（3.2 打不到 / 2.8 打得到）
#   ③ 竖向：高 12 格（y=12.5 打不到 / y=11.5 打得到）
#   ④ 视觉包围盒：高 ≈ 12、横向直径 ≈ 6（**必须与碰撞圆柱一致**，否则"看着打到了却没伤害"）
#   ⑤ 蓝环中心离地 6.0（±0.05）；set_ring_color(红) 生效
# ══════════════════════════════════════════════════════════════════════════════
extends SceneTree

var _checks := 0
var _fail := 0


func _chk(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("  PASS  %s" % what)
	else:
		_fail += 1
		print("  FAIL  %s" % what)


func _row(nm: String) -> Dictionary:
	for d in UnitData.UNITS:
		if String(d["name"]) == nm:
			return d
	for d in UnitData.ENEMIES:
		if String(d["name"]) == nm:
			return d
	return {}


# ── ① 默认值等价（这一组是"既有角色行为不变"的锁）─────────────────────────────
func _part1_defaults() -> void:
	print("\n[1] 默认值等价：缺省碰撞圆柱必须与 Damage.BODY_R/BODY_H 同值")
	var plain := Unit.new()
	_chk(absf(Damage.BODY_R - 0.30) < 0.000001 and absf(Damage.BODY_H - 1.00) < 0.000001,
		"基线：Damage.BODY_R=0.30 / BODY_H=1.00（常量没被人改过）")
	_chk(absf(plain.body_r - Damage.BODY_R) < 0.000001,
		"Unit.new().body_r(%.2f) == Damage.BODY_R(%.2f)" % [plain.body_r, Damage.BODY_R])
	_chk(absf(plain.body_height - Damage.BODY_H) < 0.000001,
		"Unit.new().body_height(%.2f) == Damage.BODY_H(%.2f)" % [plain.body_height, Damage.BODY_H])
	_chk(absf(Targeting.BODY_R_DEFAULT - Damage.BODY_R) < 0.000001
		and absf(Targeting.BODY_H_DEFAULT - Damage.BODY_H) < 0.000001,
		"Targeting.BODY_R_DEFAULT/BODY_H_DEFAULT 与 Damage 同值（三处口径一致）")
	_chk(absf(Targeting.unit_body_r(plain) - Damage.BODY_R) < 0.000001
		and absf(Targeting.unit_body_h(plain) - Damage.BODY_H) < 0.000001,
		"Targeting.unit_body_r/unit_body_h(普通单位) 回落到缺省")
	# 数据行的既有角色：显式写了 0.3/1.0，读出来还是老口径
	var grd := Unit.from_data(_row("Alette"))
	_chk(absf(grd.body_r - 0.30) < 0.000001 and absf(grd.body_height - 1.00) < 0.000001,
		"既有角色 Alette 的碰撞圆柱 = 0.30/1.00（与改造前逐字相同）")
	# 用"老代码的数值"验等价：地面单位身体区间 [0,1]、瞄 0.5 高；悬停 2 格 -> [2,3]、瞄 2.5
	_chk(Targeting.body_span(grd) == Vector2(0.0, 1.0), "地面角色身体区间 [0,1]（老口径）")
	_chk(absf(Targeting.aim_height(grd) - 0.5) < 0.001, "地面角色瞄 0.5 高（老口径）")
	grd.hover = 2.0
	_chk(Targeting.body_span(grd) == Vector2(2.0, 3.0), "悬停 2 格身体区间 [2,3]（老口径）")
	_chk(absf(Targeting.aim_height(grd) - 2.5) < 0.001, "悬停 2 格瞄 2.5 高（老口径）")
	# 空爆：一格球（半径 0.5）+ 缺省身体 0.30 -> 打到 0.7 格内、打不到 0.9 格外
	var c := Vector2i(5, 5)
	_chk(Targeting.sphere_hits_body(Vector3(5.5 + 0.7, 0.5, 5.5), 0.5, c, 0.30, 1.0, 0.0),
		"贴脸空爆命中（半径 0.5 + 身体 0.30 -> 0.7 格内）")
	_chk(not Targeting.sphere_hits_body(Vector3(5.5 + 0.9, 0.5, 5.5), 0.5, c, 0.30, 1.0, 0.0),
		"隔一格空爆打不到（老口径：0.9 格外）")


# ── ② 横向半径 ──────────────────────────────────────────────────────────────
func _part2_radius(rep: Unit) -> void:
	print("\n[2] 横向：Reaper 半径 3 格")
	_chk(absf(rep.body_r - 3.0) < 0.000001 and absf(rep.body_height - 12.0) < 0.000001,
		"Unit.from_data(Reaper) -> body_r=%.1f / body_height=%.1f" % [rep.body_r, rep.body_height])
	_chk(absf(Targeting.unit_body_r(rep) - 3.0) < 0.000001
		and absf(Targeting.unit_body_h(rep) - 12.0) < 0.000001,
		"Targeting.unit_body_r/unit_body_h(Reaper) = 3.0 / 12.0")
	# 用小半径球把"身体半径"单独隔离出来测（大球会把 +radius 混进来，见下面 2b）
	var c := Vector2i(5, 5)
	var r_small := 0.05
	_chk(not Targeting.sphere_hits_body(Vector3(5.5 + 3.2, 0.5, 5.5), r_small, c,
			Targeting.unit_body_r(rep), Targeting.unit_body_h(rep), rep.body_h()),
		"离中心 3.2 格：打不到（半径 3 之外）")
	_chk(Targeting.sphere_hits_body(Vector3(5.5 + 2.8, 0.5, 5.5), r_small, c,
			Targeting.unit_body_r(rep), Targeting.unit_body_h(rep), rep.body_h()),
		"离中心 2.8 格：打得到（在半径 3 之内）")
	# 2b：真实空爆（半径 0.5）的边界 = 3.0 + 0.5 = 3.5
	_chk(Targeting.sphere_hits_body(Vector3(5.5 + 3.4, 0.5, 5.5), 0.5, c,
			Targeting.unit_body_r(rep), Targeting.unit_body_h(rep), rep.body_h()),
		"真实空爆（半径 0.5）在 3.4 格仍命中（边界 = 3.0 + 0.5）")
	_chk(not Targeting.sphere_hits_body(Vector3(5.5 + 3.6, 0.5, 5.5), 0.5, c,
			Targeting.unit_body_r(rep), Targeting.unit_body_h(rep), rep.body_h()),
		"真实空爆在 3.6 格打不到")

	# 对比：同样位置打普通角色（0.30）—— 证明"按单位取尺寸"真的生效了
	var grd := Unit.from_data(_row("Alette"))
	_chk(not Targeting.sphere_hits_body(Vector3(5.5 + 2.8, 0.5, 5.5), r_small, c,
			Targeting.unit_body_r(grd), Targeting.unit_body_h(grd), grd.body_h()),
		"同样 2.8 格，普通角色（半径 0.30）打不到 —— 尺寸确实按单位算了")


# ── ③ 竖向高度 ──────────────────────────────────────────────────────────────
func _part3_height(rep: Unit) -> void:
	print("\n[3] 竖向：Reaper 高 12 格（身体区间 [0, 12]）")
	var c := Vector2i(5, 5)
	var r_small := 0.05
	_chk(Targeting.body_span(rep) == Vector2(0.0, 12.0),
		"身体区间 = [0, 12]（拿到的实际值 %s）" % [Targeting.body_span(rep)])
	_chk(absf(Targeting.aim_height(rep) - 6.0) < 0.001,
		"瞄它要瞄 6.0 高（身体中心 = 蓝环高度）")
	_chk(not Targeting.sphere_hits_body(Vector3(5.5, 12.5, 5.5), r_small, c,
			Targeting.unit_body_r(rep), Targeting.unit_body_h(rep), rep.body_h()),
		"球心 y=12.5：打不到（高过 12 格）")
	_chk(Targeting.sphere_hits_body(Vector3(5.5, 11.5, 5.5), r_small, c,
			Targeting.unit_body_r(rep), Targeting.unit_body_h(rep), rep.body_h()),
		"球心 y=11.5：打得到（12 格之内）")
	# 贴地也打得到（它是从地面长出来的，不是悬浮）
	_chk(Targeting.sphere_hits_body(Vector3(5.5, 0.5, 5.5), r_small, c,
			Targeting.unit_body_r(rep), Targeting.unit_body_h(rep), rep.body_h()),
		"球心 y=0.5：打得到（触须接地，不是悬浮单位）")


# ── ④ 视觉包围盒 ────────────────────────────────────────────────────────────
func _corners(n: Node3D, xf: Transform3D, out: Array) -> void:
	for ch in n.get_children():
		if not (ch is Node3D):
			continue
		var c3 := ch as Node3D
		var cxf := xf * c3.transform
		if ch is MeshInstance3D:
			var a: AABB = (ch as MeshInstance3D).get_aabb()
			for i in 8:
				var p := a.position + Vector3(
					a.size.x * float(i & 1),
					a.size.y * float((i >> 1) & 1),
					a.size.z * float((i >> 2) & 1))
				out.append(cxf * p)
		_corners(c3, cxf, out)


func _part4_bounds() -> void:
	print("\n[4] 视觉包围盒必须与碰撞圆柱一致（否则看着打到了却没伤害）")
	var m := ReaperModel.make()
	var pts: Array = []
	_corners(m, Transform3D.IDENTITY, pts)
	_chk(pts.size() > 0, "模型有几何体（%d 个包围盒角点）" % pts.size())
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := Vector3(-1e9, -1e9, -1e9)
	for p in pts:
		var v := p as Vector3
		lo = Vector3(minf(lo.x, v.x), minf(lo.y, v.y), minf(lo.z, v.z))
		hi = Vector3(maxf(hi.x, v.x), maxf(hi.y, v.y), maxf(hi.z, v.z))
	var h := hi.y - lo.y
	var dx := hi.x - lo.x
	var dz := hi.z - lo.z
	var diam := maxf(dx, dz)
	print("    实测包围盒：y [%.3f, %.3f] 高 %.3f ｜ x 直径 %.3f ｜ z 直径 %.3f" % [lo.y, hi.y, h, dx, dz])
	_chk(absf(h - 12.0) <= 0.35, "高 %.3f ≈ 12（body_h）" % h)
	_chk(absf(diam - 6.0) <= 0.35, "横向直径 %.3f ≈ 6（body_r × 2）" % diam)
	_chk(lo.y >= -0.05 and lo.y <= 0.25, "最低点贴地（y=%.3f ≈ 0，触须接地）" % lo.y)
	_chk(hi.y >= 11.5, "最高点 %.3f 够到 12 格（上尖）" % hi.y)
	m.queue_free()


# ── ⑤ 蓝环 ──────────────────────────────────────────────────────────────────
func _part5_ring() -> void:
	print("\n[5] 蓝环：离地正好 6 格 + 红蓝切换")
	var m := ReaperModel.make()
	_chk(absf(m.ring_y() - 6.0) <= 0.05, "环中心离地 %.3f ≈ 6.0（Laser.BASE_HEIGHT）" % m.ring_y())
	_chk(absf(ReaperModel.RING_Y - 6.0) < 0.0001, "常量 ReaperModel.RING_Y = 6.0")
	var ring := m.find_child("Ring", true, false) as MeshInstance3D
	_chk(ring != null, "模型里找得到蓝环节点（Ring）")
	if ring != null:
		_chk(absf(ring.position.y - 6.0) <= 0.05, "蓝环节点实际 y=%.3f" % ring.position.y)
	var blue := m.ring_color()
	_chk(blue.b > blue.r, "常态是蓝的（r=%.2f b=%.2f）" % [blue.r, blue.b])
	m.set_ring_color(Color.RED)
	var red := m.ring_color()
	_chk(red.r > red.b and absf(red.r - Color.RED.r) < 0.01, "set_ring_color(红) 立刻生效（r=%.2f b=%.2f）" % [red.r, red.b])
	m.set_ring_color(Color(0.20, 0.62, 1.00))
	var back := m.ring_color()
	_chk(back.b > back.r, "调回蓝色也生效（激光打完复位）")
	# 自发光要开着（不然环看起来是块死板）
	var mat := ring.material_override as StandardMaterial3D if ring != null else null
	_chk(mat != null and mat.emission_enabled, "环材质开了自发光（emission）")
	m.queue_free()
	# 挂到 UnitVisual 上的路径也要通（真实装配走的是这条）
	var uv := UnitVisual.new()
	var fake := Unit.from_data(_row("Reaper"))
	uv.setup(fake)
	var attached := uv.find_child("ReaperModel", true, false) as ReaperModel
	_chk(attached != null, "UnitVisual.setup(Reaper) 后底下挂着 ReaperModel（真实装配路径）")
	if attached != null:
		_chk(absf(attached.ring_y() - 6.0) <= 0.05, "装配出来的环也在离地 6 格")
	uv.queue_free()


func _initialize() -> void:
	print("── Reaper 探针：碰撞圆柱 + 建模 ──")
	var rep := Unit.from_data(_row("Reaper"))
	_chk(not _row("Reaper").is_empty(), "unit_data 里有 Reaper 这一行")
	_part1_defaults()
	_part2_radius(rep)
	_part3_height(rep)
	_part4_bounds()
	_part5_ring()
	print("\n── Reaper 探针：%d 项检查，失败 %d 项 ──" % [_checks, _fail])
	quit(1 if _fail > 0 else 0)
