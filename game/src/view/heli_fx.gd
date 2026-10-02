# ══════════════════════════════════════════════════════════════════════════════
# 俯冲轰炸直升机的表现层动画：旋翼自转 / 悬浮高度 / 坠机加速下坠 / 俯冲压机头。
#
# 全部是纯 static（RefCounted 不持有任何状态），只读写传进来的节点 + 只读 Unit，
# 不发信号、不引用 battle_scene、不碰 Unit 的逻辑字段。
#
# 坐标/角度约定（与 heli_model.gd 一致）：
#   · 机头 = 模型局部 +Z，上 = +Y，左右 = ±X
#   · rotation.y = 偏航（朝向）；rotation.x > 0 = 低头（+Z 被压向 −Y）；
#     rotation.z > 0 = 右倾（机顶偏向机身自身右侧，即 −X）
#
# 高度策略（关键，避免和 UnitVisual 自己的待机 Tween 打架）：
#   · tick 里高度一律【直接赋值】position.y = unit.hover，不逐帧建 Tween
#   · crashing：让位给 crash_fall 的 Tween（高度 + 姿态都由它接管）
#   · diving  ：battle_scene._place_diving 每帧写 position（俯冲 2 → 0.5 格），
#               这里再顶 hover 会让直升机永远降不下去，所以同样让位
#   · 空中落位 Tween（spawn_descent）还没跑完时也让位
#   · 非直升机（找不到 MainRotor）第一行就 return：零开销
# ══════════════════════════════════════════════════════════════════════════════
class_name HeliFx
extends RefCounted

# ── 可调参数 ──────────────────────────────────────────────────────────────────
const SPIN_MAIN := TAU * 6.0            # 主旋翼：6 圈/秒
const SPIN_TAIL := TAU * 10.0           # 尾桨：10 圈/秒
const LEVEL_RATE := 8.0                 # 机身回正速度（每秒插值系数，0.5 秒内摆平）
const DIVE_PITCH_DEFAULT := 22.0        # 只打了 diving 标记、没给角度时的默认俯角（度）
const DIVE_ROLL_DEFAULT := 4.0          # 同上：默认侧倾（度）
const CRASH_SPIN_TURNS := 1.0           # 坠机过程中的尾部自旋圈数
const CRASH_PITCH_DEG := 30.0           # 坠机落地瞬间的机头下压（度）
const CRASH_ROLL_DEG := 12.0            # 坠机落地瞬间的侧翻（度）
const MIN_ACCEL := 0.05                 # accel <= 0 时的兜底加速度，保证一定能落地
const MAX_FALL_SEC := 8.0               # 下坠时长安全阀（秒）
const MAX_STEP := 0.25                  # 单帧 dt 上限（掉帧保护，防止旋翼瞬移）

const META_PITCH := "heli_fx_pitch"     # 姿态目标：俯角（度）
const META_ROLL := "heli_fx_roll"       # 姿态目标：侧倾（度）
const META_DESCENT := "heli_fx_descent" # 正在跑的落位 Tween

const HELI_ROOT := "HeliModel"          # UnitVisual 底下挂的模型根节点名


# ── 每帧表现 ──────────────────────────────────────────────────────────────────
## 每帧表现：把节点高度顶到 unit.hover、旋翼自转、坠机/俯冲姿态。
## 由 UnitVisual._process 每帧调用；非直升机立即返回（零开销）。
static func tick(visual: Node3D, unit: Unit, dt: float) -> void:
	if not is_instance_valid(visual):
		return
	# 直升机之外的单位在这里就结束：一次 get_node_or_null 而已
	var main := _part(visual, "MainRotor")
	if main == null:
		return

	var step := clampf(dt, 0.0, MAX_STEP)

	# ── ① 旋翼自转（和 dt 挂钩，与帧率无关）──
	# 用 fposmod 把角度收在 [0, TAU)：转起来完全一样，但长时间跑不会掉精度。
	main.rotation.y = fposmod(main.rotation.y + SPIN_MAIN * step, TAU)
	var tail := _part(visual, "TailRotor")
	if tail != null:
		tail.rotation.x = fposmod(tail.rotation.x + SPIN_TAIL * step, TAU)

	if unit == null:
		return

	# ── ② 坠机：高度和姿态都交给 crash_fall 的 Tween 接管 ──
	if unit.tags.has("crashing"):
		return

	var diving: bool = unit.tags.has("diving")

	# ── ③ 高度：直接赋值（不建 Tween）──
	if not diving and not _descent_running(visual):
		var h: float = unit.hover
		visual.position.y = h if h > 0.0 else 0.0

	# ── ④ 姿态：俯冲中压向目标姿态，其余时候缓缓回正 ──
	var want_pitch := 0.0
	var want_roll := 0.0
	if diving:
		want_pitch = float(visual.get_meta(META_PITCH, DIVE_PITCH_DEFAULT))
		want_roll = float(visual.get_meta(META_ROLL, DIVE_ROLL_DEFAULT))
	var k := clampf(LEVEL_RATE * step, 0.0, 1.0)
	if k > 0.0:
		visual.rotation.x = lerp_angle(visual.rotation.x, deg_to_rad(want_pitch), k)
		visual.rotation.z = lerp_angle(visual.rotation.z, deg_to_rad(want_roll), k)


# ── 出生/复位的降落、起飞 ─────────────────────────────────────────────────────
## 复位的降落/起飞动画：把 y 从 from_h 平滑挪到 to_h，顺手把机身摆平。
## 返回 Tween（调用方可以 await，也可以直接忽略）；条件不具备时返回 null 并直接落位。
static func spawn_descent(visual: Node3D, from_h: float, to_h: float, dur: float) -> Tween:
	if not is_instance_valid(visual):
		return null
	_kill_meta_tween(visual, META_DESCENT)
	visual.position.y = from_h
	# 降落/起飞期间机身一定是平的：把姿态目标清零，tick 不会跟这段动画抢
	visual.set_meta(META_PITCH, 0.0)
	visual.set_meta(META_ROLL, 0.0)
	if dur <= 0.0 or is_equal_approx(from_h, to_h) or not visual.is_inside_tree():
		visual.position.y = to_h
		visual.rotation.x = 0.0
		visual.rotation.z = 0.0
		return null

	var pitch0 := visual.rotation.x
	var tw := visual.create_tween()
	visual.set_meta(META_DESCENT, tw)
	tw.set_trans(Tween.TRANS_SINE)
	# 下降：缓出（先快后慢，稳稳压到位）；上升：缓入缓出（起飞感）
	tw.set_ease(Tween.EASE_OUT if to_h < from_h else Tween.EASE_IN_OUT)
	tw.tween_property(visual, "position:y", to_h, dur)
	tw.parallel().tween_method(func(f: float) -> void:
		if is_instance_valid(visual):
			visual.rotation.x = lerpf(pitch0, 0.0, f)
			, 0.0, 1.0, dur)
	tw.chain().tween_callback(func() -> void:
		if is_instance_valid(visual):
			visual.position.y = to_h
			visual.rotation.x = 0.0
			visual.rotation.z = 0.0
			if visual.has_meta(META_DESCENT):
				visual.remove_meta(META_DESCENT))
	return tw


# ── 坠机 ──────────────────────────────────────────────────────────────────────
## 坠机：加速下坠，速度 v(t) = vy0 + accel·t²（随时间平方增长），
## 落点固定在 y = 0（模型最低点 = 雪橇底面，也就是地面；与 battle_scene 的
## _crash_impact 保持一致）。落地那一帧精确停在 0，不会陷进地里。
## 过程中尾部自旋 + 机头越压越低，落地时是"摔烂"的姿态。
static func crash_fall(visual: Node3D, from_h: float, vy0: float, accel: float) -> Tween:
	if not is_instance_valid(visual):
		return null
	var land_y := 0.0
	_kill_meta_tween(visual, META_DESCENT)   # 别和落位动画抢
	var drop := from_h - land_y
	if drop <= 0.0 or not visual.is_inside_tree():
		visual.position.y = land_y
		return null

	var v0 := maxf(vy0, 0.0)
	var a := maxf(accel, MIN_ACCEL)
	var dur := _fall_time(drop, v0, a)
	var yaw0 := visual.rotation.y
	var pitch0 := visual.rotation.x
	var roll0 := visual.rotation.z
	var pitch_end := deg_to_rad(CRASH_PITCH_DEG)
	var roll_end := deg_to_rad(CRASH_ROLL_DEG)

	var tw := visual.create_tween()
	tw.set_trans(Tween.TRANS_LINEAR)         # 下落曲线自己算，不能让缓动改 t
	tw.tween_method(func(t: float) -> void:
		if not is_instance_valid(visual):
			return
		# 位移 = ∫v = v0·t + a·t³/3
		visual.position.y = maxf(from_h - v0 * t - a * t * t * t / 3.0, land_y)
		var k := clampf(t / dur, 0.0, 1.0)
		visual.rotation.y = yaw0 + TAU * CRASH_SPIN_TURNS * k
		visual.rotation.x = lerpf(pitch0, pitch_end, k)
		visual.rotation.z = lerpf(roll0, roll_end, k)
		, 0.0, dur, dur)
	tw.tween_callback(func() -> void:
		if is_instance_valid(visual):
			visual.position.y = land_y
			visual.rotation.x = pitch_end
			visual.rotation.z = roll_end)
	return tw


# ── 俯冲姿态 ──────────────────────────────────────────────────────────────────
## 俯冲姿态：按速度方向压机头（pitch_deg 为正 = 低头）+ 轻微侧倾。
## 立即生效，同时把姿态记成"目标"：diving 期间 tick 会保持它，
## 俯冲结束（标记被清掉）后 tick 会自动把机身缓缓摆平。
static func dive_pose(visual: Node3D, pitch_deg: float, roll_deg: float) -> void:
	if not is_instance_valid(visual):
		return
	visual.set_meta(META_PITCH, pitch_deg)
	visual.set_meta(META_ROLL, roll_deg)
	visual.rotation.x = deg_to_rad(pitch_deg)
	visual.rotation.z = deg_to_rad(roll_deg)


## 正在俯冲/坠机时每帧朝目标压机头（target = 落点格中心）：
## 偏航对准目标（模型 +Z 是机头），机头下压 pitch_deg 度，
## 并按"还差多少度转过来"给一点转弯侧倾（对准后自动归零）。
## 只动 rotation.x / y / z，不碰位置。
static func face_toward(visual: Node3D, from: Vector3, target: Vector3, pitch_deg: float) -> void:
	if not is_instance_valid(visual):
		return
	var dx := target.x - from.x
	var dz := target.z - from.z
	var yaw_want := visual.rotation.y
	var bank := 0.0
	if dx * dx + dz * dz > 0.00000001:
		yaw_want = atan2(dx, dz)                            # 局部 +Z -> 目标
		var turn := wrapf(yaw_want - visual.rotation.y, -PI, PI)
		bank = clampf(-rad_to_deg(turn) * 1.5, -22.0, 22.0)  # 未对准时侧倾进弯
	visual.rotation.y = yaw_want
	visual.rotation.x = deg_to_rad(pitch_deg)
	visual.rotation.z = deg_to_rad(bank)
	visual.set_meta(META_PITCH, pitch_deg)
	visual.set_meta(META_ROLL, bank)


# ── 内部工具 ──────────────────────────────────────────────────────────────────
## 取子装配：优先按"直接子节点"找（把模型根当 visual 传时就是这种情况），
## 找不到再按 UnitVisual 的真实层级 HeliModel/xxx 找。
static func _part(visual: Node3D, part: String) -> Node3D:
	var n := visual.get_node_or_null(part)
	if n is Node3D:
		return n
	n = visual.get_node_or_null(HELI_ROOT + "/" + part)
	return n if n is Node3D else null


## 数值解 v(t) = v0 + a·t² 落到 drop 深度所需的时间（60Hz 步进，够用且确定）
static func _fall_time(drop: float, v0: float, a: float) -> float:
	var t := 0.0
	var step := 1.0 / 60.0
	while t < MAX_FALL_SEC:
		if v0 * t + a * t * t * t / 3.0 >= drop:
			return t
		t += step
	return MAX_FALL_SEC


## 落位 Tween 是否还在跑（跑的时候 tick 不能顶高度，否则动画作废）
static func _descent_running(visual: Node3D) -> bool:
	if not visual.has_meta(META_DESCENT):
		return false
	var tw: Variant = visual.get_meta(META_DESCENT)
	if tw is Tween and is_instance_valid(tw):
		return (tw as Tween).is_valid() and (tw as Tween).is_running()
	return false


static func _kill_meta_tween(visual: Node3D, key: String) -> void:
	if not visual.has_meta(key):
		return
	var tw: Variant = visual.get_meta(key)
	if tw is Tween and is_instance_valid(tw) and (tw as Tween).is_valid():
		(tw as Tween).kill()
	visual.remove_meta(key)
