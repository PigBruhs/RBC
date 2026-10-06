# 第 111 轮：**雷达引导火箭**（新需求）
#   用户口径：「锁定后引导火箭弹飞向被锁定目标，无论初始瞄准方向是哪
#   （**加个加速度限制**，合理范围内能被吸附过去，偏差太大则会往那边拐但是无法命中）」
#
# 本探针量三件事：
#   ① 被连接友军的火箭**散布被降低**（锁前 ×0.5）
#   ② 偏差**小**时：火箭方向被"吸"向锁定目标（夹角收敛）
#   ③ 偏差**大**时：方向确实往那边拐了，但**受每帧转角上限限制、追不上**（夹角仍大）
extends SceneTree

const LEVEL := "arena"
const HELI := "俯冲轰炸直升机（不要问那么多）"

var _f := 0
var _n := 0


func _ok(c: bool, w: String) -> void:
	_n += 1
	if c:
		print("  PASS  ", w)
	else:
		_f += 1
		print("  FAIL  ", w)


func _initialize() -> void:
	Level.current = LEVEL
	var s: Node = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(s)
	for i in 8:
		await process_frame
	_run(s)
	quit(1 if _f > 0 else 0)


func _run(s: Node) -> void:
	var radar: Unit = null
	var heli: Unit = null
	var foe: Unit = null
	for u in s.units:
		if u == null:
			continue
		if u.name == "雷达午餐盒":
			radar = u
		if u.name == HELI:
			heli = u
		if foe == null and u.is_alive() and u.side != 0:
			foe = u
	_ok(radar != null and heli != null and foe != null, "找到 雷达 / 直升机 / 敌人")
	if radar == null or heli == null or foe == null:
		return

	print("\n[1] 被连接后，直升机的火箭**散布被降低**")
	print("      直升机 scatter_r = %.1f" % float(Level.heli("arena")["scatter_r"]))
	var base_r: float = float(Level.heli("arena")["scatter_r"])
	var no_link: float = s._radar_spread(base_r, heli)
	_ok(absf(no_link - base_r) < 1e-6, "**没被连接时散布不动**（%.1f）" % no_link)
	s.t_radar_add_link("雷达午餐盒", HELI)
	var linked: float = s._radar_spread(base_r, heli)
	print("      连接后 scatter = %.2f（基准 %.1f）" % [linked, base_r])
	_ok(absf(linked - base_r * 0.5) < 1e-6, "**连接后散布 ×0.5**（%.2f）" % linked)

	print("\n[2] 锁定完成后：**偏差小** -> 被吸附（夹角收敛）")
	# 让雷达锁定该敌人
	s.t_radar_begin_lock("雷达午餐盒", foe.name)
	var rst: Radar.State = s.t_radar_state("雷达午餐盒")
	while not rst.locked():
		s._radar_on_turn_begin(radar)
	_ok(rst.locked(), "雷达已锁定 %s" % foe.name)

	# 造一发火箭：起点在直升机旁边，落点方向**故意偏离锁定目标 10°**
	var from := Vector3(10.5, heli.hover + 0.5, 10.5)
	foe.cell = Vector2i(10, 26)
	foe.visual.position = Vector3(10.5, foe.visual.position.y, 26.5)
	var to_tgt := GridMath.unit_pos(foe)
	var want_dir := (to_tgt - Vector2(10.5, 10.5)).normalized()
	var small_off := want_dir.rotated(deg_to_rad(10.0))
	var near_to := Vector2(10.5, 10.5) + small_off * 16.0
	var p := Ordnance.make_rocket(heli, from, near_to, false, s.rng)
	s.field.register(p)
	var a0 := _angle_to_target(p, foe)
	# 推 12 帧（每帧 1/60 秒）
	for i in 12:
		s._radar_guide_rockets(1.0 / 60.0)
	var a1 := _angle_to_target(p, foe)
	print("      小偏差：与目标的夹角 %.1f° -> %.1f°" % [a0, a1])
	_ok(a1 < a0 - 5.0, "**小偏差被吸附**（夹角收敛 %.1f° -> %.1f°）" % [a0, a1])
	_ok(a1 < 3.0, "收敛到很接近目标方向（%.1f°）" % a1)
	var d_small := _rocket_landing_dist(p, foe)
	print("      12 帧后落点仍偏 %.2f 格" % d_small)

	print("\n[3] **偏差大**（90°）-> 会往那边拐，但**追不上**（受转角上限限制）")
	s.clear_projectiles()
	var big_off := want_dir.rotated(deg_to_rad(90.0))
	var far_to := Vector2(10.5, 10.5) + big_off * 16.0
	var q := Ordnance.make_rocket(heli, from, far_to, false, s.rng)
	s.field.register(q)
	var b0 := _angle_to_target(q, foe)
	for i in 12:
		s._radar_guide_rockets(1.0 / 60.0)
	var b1 := _angle_to_target(q, foe)
	print("      大偏差：与目标的夹角 %.1f° -> %.1f°" % [b0, b1])
	_ok(b1 < b0 - 5.0, "**确实往目标拐了**（夹角减小 %.1f° -> %.1f°）" % [b0, b1])
	_ok(b1 > 30.0, "**但追不上**（仍然偏 %.1f° > 30°）—— 正是用户要的手感" % b1)
	# 转角上限：12 帧最多转 80°/s × 0.2s = 16°
	var turned := b0 - b1
	print("      12 帧共转过 %.1f°（上限 80°/s × 12/60s = 16°）" % turned)
	_ok(turned <= 16.5, "**每帧转角受上限约束**（%.1f° ≤ 16°）" % turned)

	print("\n[4] 没被连接的友军火箭 / 雷达没锁定时：**不引导**")
	s.clear_projectiles()
	var r := Ordnance.make_rocket(heli, from, near_to, false, s.rng)
	s.field.register(r)
	Radar.clear_lock(rst)
	for i in 6:
		s._radar_guide_rockets(1.0 / 60.0)
	_ok(absf(_angle_to_target(r, foe) - a0) < 0.01,
		"**雷达没锁定时火箭方向不变**（%.1f°）" % _angle_to_target(r, foe))

	print("\n── 雷达引导火箭探针：%d 项检查，失败 %d 项 ──" % [_n, _f])


## 火箭当前落点方向 与 "火箭 -> 目标" 方向的夹角（度）
func _angle_to_target(p: Projectile, t: Unit) -> float:
	var cur: Vector2 = p.to - p.pos()
	var want: Vector2 = GridMath.unit_pos(t) - p.pos()
	if cur.length() < 0.01 or want.length() < 0.01:
		return 0.0
	return absf(rad_to_deg(cur.angle_to(want)))


## 火箭落点到目标的距离（格）—— 用来判断"能不能命中"
func _rocket_landing_dist(p: Projectile, t: Unit) -> float:
	return p.to.distance_to(GridMath.unit_pos(t))
