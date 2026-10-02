# ══════════════════════════════════════════════════════════════════════════════
# 弹道物场：模型 + 朝向 + 尾迹 + **每帧推进**（出界/互撞/命中/哨兵/落地）
#
# 用户口径：弹道物理只负责"打没打中"，然后把结果**上报给 GameMaster**，
# 由 GameMaster（实为 battle_scene 注册的处理函数）去决定后果。
# 所以这个类：
#   · 不知道回合、伤害、红圈、光柱、编组 —— 一律通过 hub.report_projectile() 上报
#   · 只依赖 Projectile / Ordnance / Ballistics（纯核心层），可以被单独测试
#
# 需要的三个外部依赖都由外部注入：
#   parent    挂载视觉节点的父节点
#   hub       GameMaster（上报结果 + forget_projectile）
#   hit_test  箭矢命中判定回调 (p, prev, cur) -> {"unit": Unit} / {"placeable": Placeable} / {}
#   log_fn    日志回调（可选）
# ══════════════════════════════════════════════════════════════════════════════
class_name ProjectileField
extends RefCounted

# ── 炮弹外观参数 ──
## 内球半径。整体（内球 + 光晕）直径 = 0.30 格（用户口径：原来 0.72 太夸张了）。
const SHELL_BALL_R := 0.075
const SHELL_HALO_R := 0.15        # 光晕半径 = 2 × 内球
## 尾迹的粗细基准。用户口径：**尾迹保持原样**，不跟着炮弹一起缩，所以它有自己的参考半径。
const TAIL_REF_R := 0.25
const TAIL_SEGS := 10             # 尾迹珠数量
const TAIL_MAX_MULT := 3.0        # 尾迹最长 = 3 倍基准直径（铺满速度参考值时为 2.16 格）
## 速度参考：炮弹本身的巡航速度就是 3 格/秒，在这里让它铺满。
const TAIL_SPEED_REF := 3.0
const TAIL_ALPHA := 0.40          # 单颗尾迹珠的透明度（珠子大，加法混合要压一压）
## 箭矢插在地上后，模型留存多久再消失（期间不做任何判定）
const ARROW_LINGER_SEC := 2.0

# 上报给 hub 的事件名
const EV_OUT := "out_of_bounds"       # 飞出边界
const EV_HIT_PROJ := "hit_projectile" # 打中另一发弹道物
const EV_HIT_TARGET := "hit_target"   # 打中角色/沙盒道具
const EV_LANDED := "landed"           # 落地
const EV_REMOVED := "removed"         # 任何一次消亡（最后必然发一次）

var parent: Node3D = null
var hub: GameMaster = null
var hit_test: Callable = Callable()
var log_fn: Callable = Callable()
var grid_w: int = 48
var grid_h: int = 48

## 每一条：{"p": Projectile, "node": Node3D, "prev": Vector2, "linger_until": float}
var items: Array = []
var clock: float = 0.0            # 场自己的时间（箭矢留存计时用）


func setup(p_parent: Node3D, p_hub: GameMaster, p_hit_test: Callable) -> void:
	parent = p_parent
	hub = p_hub
	hit_test = p_hit_test


func _log(line: String) -> void:
	if log_fn.is_valid():
		log_fn.call(line)


func _report(event: String, p: Projectile, extra = null) -> void:
	if hub != null:
		hub.report_projectile(event, p, extra)


# ══════════════════════════════════════════════════════════════════════════════
# 增删查
# ══════════════════════════════════════════════════════════════════════════════
## 登记一发弹道物；视觉节点按 kind 自动选
func register(p: Projectile) -> void:
	var node: Node3D = null
	match p.kind:
		Projectile.KIND_SHELL:
			node = make_shell_node(parent)
		Projectile.KIND_MARKER:
			node = make_marker_node(parent)
		Projectile.KIND_ARROW:
			var tint: bool = p.shot != null and p.shot.tint_sentry
			node = make_arrow_node(parent, p.from.distance_to(p.to), tint)
		Projectile.KIND_CANNON:
			node = make_cannon_node(parent)
		Projectile.KIND_FRAGMENT:
			node = make_fragment_node(parent)
	items.append({"p": p, "node": node, "prev": p.pos()})


## 消亡：拆掉视觉节点 + 通知 hub 忘记它 + 上报 removed
func retire(e: Dictionary, report: bool = true) -> void:
	var node = e.get("node")
	if node != null and is_instance_valid(node):
		if parent != null:
			parent.remove_child(node)
		node.queue_free()
	var p: Projectile = e.get("p")
	if p != null:
		if hub != null:
			hub.forget_projectile(p.id)
		if report:
			_report(EV_REMOVED, p)


func clear() -> void:
	for e in items:
		retire(e, not e.has("linger_until"))
	items.clear()


func live_count() -> int:
	var n := 0
	for e in items:
		var p: Projectile = e["p"]
		if p.alive:
			n += 1
	return n


func _index_of(p: Projectile) -> int:
	for i in items.size():
		if items[i]["p"] == p:
			return i
	return -1


# ══════════════════════════════════════════════════════════════════════════════
# 每帧推进
# ══════════════════════════════════════════════════════════════════════════════
func step(delta: float) -> void:
	clock += delta
	for i in range(items.size() - 1, -1, -1):
		var e: Dictionary = items[i]
		var p: Projectile = e["p"]
		# ① 插在地上的箭：只留模型，不做任何判定，到点才消失
		if e.has("linger_until"):
			if clock >= float(e["linger_until"]):
				retire(e, false)
				items.remove_at(i)
			continue
		if not p.alive:
			retire(e)
			items.remove_at(i)
			continue
		var node: Node3D = e["node"]
		var sh: Ordnance.Shot = p.shot
		var prev := p.pos3()
		e["prev"] = p.pos()                 # 扫掠碰撞用的上一帧水平位置
		p.step(delta)
		if not p.ready():
			continue
		var cur := p.pos3()
		if node != null and is_instance_valid(node):
			node.visible = true
			node.position = cur
			orient(node, cur, prev, p.from.distance_to(p.to) / maxf(0.05, p.dur))

		# ① 出界：飞到边界处直接移除（保留飞到边界的动画，不越界）
		var q := p.pos()
		if q.x < 0.0 or q.y < 0.0 or q.x > float(grid_w) or q.y > float(grid_h):
			var cq := Vector2(clampf(q.x, 0.0, float(grid_w)), clampf(q.y, 0.0, float(grid_h)))
			p.removed_at = cq
			if node != null and is_instance_valid(node):
				node.position = Vector3(cq.x, p.height(), cq.y)
			p.kill("out_of_bounds")
			_report(EV_OUT, p)
			retire(e)
			items.remove_at(i)
			continue

		# ② 弹道物之间碰撞（箭矢击落炮弹）
		var hit_proj := collision(p)
		if hit_proj != null:
			p.kill("shot_down")
			hit_proj.kill("spent")
			_report(EV_HIT_PROJ, p, hit_proj)
			retire(e)
			items.remove_at(i)
			continue

		# ③ 直接命中型弹道物（箭矢 / 加农炮弹）命中角色 / 挡道道具
		if Ballistics.is_direct_hit(p.kind) and hit_test.is_valid():
			var what: Dictionary = hit_test.call(p, prev, cur)
			if not what.is_empty():
				_report(EV_HIT_TARGET, p, what)
				retire(e)
				items.remove_at(i)
				continue

		# ④ 哨兵：只是把这一发"送进队列"（真的射箭由 GM 的 150ms 节奏决定）
		if p.sentry_trigger and hub != null:
			hub.check_projectile(p)

		# ⑤ 落地
		if p.finished():
			_report(EV_LANDED, p)
			if p.kind == Projectile.KIND_ARROW:
				# 箭矢没打中东西就是插在地上：模型留 2 秒再消失。
				# 回合/编组照常**立刻**结算（不能因为留存而拖后回合）。
				_report(EV_REMOVED, p)
				e["linger_until"] = clock + ARROW_LINGER_SEC
				p.kill("landed_on_ground")
				continue
			retire(e)
			items.remove_at(i)


## 这一发是否撞上了别的弹道物（只有带对应 tag 的才吃）。
## 用【上一帧 -> 这一帧】的线段做扫掠采样：相对速度下一帧能走 0.23 格，
## 而两者半径和才 0.225 —— 点采样会直接穿过去。
func collision(p: Projectile) -> Projectile:
	var pa := p.pos()
	var pb := pa
	var idx := _index_of(p)
	if idx >= 0:
		pb = items[idx].get("prev", pa)
	for e in items:
		var f: Projectile = e["p"]
		if f == p or not f.alive:
			continue
		if not Ballistics.can_shoot_down(f.kind, p):
			continue
		var qb := f.pos()
		var qa: Vector2 = e.get("prev", qb)
		var rr: float = Ballistics.touch_radius(p, f)
		var steps := 6
		var done := false
		for i in steps + 1:
			var a := pa.lerp(pb, float(i) / float(steps))
			for j in steps + 1:
				var b := qa.lerp(qb, float(j) / float(steps))
				if a.distance_to(b) <= rr:
					done = true
					break
			if done:
				break
		if done:
			return f
	return null


static func kind_cn(kind: String) -> String:
	match kind:
		Projectile.KIND_SHELL: return "炮弹"
		Projectile.KIND_ARROW: return "箭矢"
		Projectile.KIND_CANNON: return "加农炮弹"
		Projectile.KIND_FRAGMENT: return "破片"
	return "标记球"


# ══════════════════════════════════════════════════════════════════════════════
# 材质
# ══════════════════════════════════════════════════════════════════════════════
## 炮弹内球：亮稻草黄 + 强自发光（像铁匠刚从炉子里拿出来的剑）
static func shell_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.88, 0.48)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.74, 0.24)
	m.emission_energy_multiplier = 3.4
	return m


## 发光壳 / 尾迹的通用材质：无光照 + 加法混合（深色地面上才看得见）
static func glow_mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = col
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


# ══════════════════════════════════════════════════════════════════════════════
# 模型
# ══════════════════════════════════════════════════════════════════════════════
## 投掷手炮弹：内球 + 光晕（厚度 = 内球半径）+ 尾迹珠（粗细按光晕算）
static func make_shell_node(parent: Node3D) -> Node3D:
	var root := Node3D.new()
	parent.add_child(root)
	root.visible = false

	var ball := MeshInstance3D.new()
	var sp := SphereMesh.new()
	sp.radius = SHELL_BALL_R
	sp.height = SHELL_BALL_R * 2.0
	ball.mesh = sp
	ball.material_override = shell_mat()
	root.add_child(ball)

	# 光晕：外半径 = 2 × 内球半径，所以壳厚正好等于内球半径
	var halo := MeshInstance3D.new()
	var hs := SphereMesh.new()
	hs.radius = SHELL_HALO_R
	hs.height = SHELL_HALO_R * 2.0
	halo.mesh = hs
	halo.material_override = glow_mat(Color(1.0, 0.82, 0.36, 0.62))
	root.add_child(halo)

	var tail: Array = []
	for i in TAIL_SEGS:
		var seg := MeshInstance3D.new()
		seg.mesh = SphereMesh.new()
		seg.material_override = glow_mat(Color(1.0, 0.80, 0.32, 0.72))
		root.add_child(seg)
		tail.append(seg)
	root.set_meta("tail", tail)
	return root


## 破片：棱形（双棱锥），无重力、平飞在离地 0.5 格处。
static func make_fragment_node(parent: Node3D) -> Node3D:
	var root := Node3D.new()
	parent.add_child(root)
	var mi := MeshInstance3D.new()
	var pm := PrismMesh.new()
	pm.size = Vector3(Ordnance.FRAGMENT_R * 2.0, Ordnance.FRAGMENT_R * 2.4, Ordnance.FRAGMENT_R * 2.0)
	mi.mesh = pm
	mi.rotation_degrees = Vector3(90, 0, 45)      # 立起来 -> 看起来是棱形
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.85, 0.86, 0.92)
	m.metallic = 0.7
	m.roughness = 0.25
	m.emission_enabled = true
	m.emission = Color(0.35, 0.42, 0.55)
	m.emission_energy_multiplier = 0.6
	mi.material_override = m
	root.add_child(mi)
	return root


## 加农炮弹：黑色实心球，直径 0.5 格（半径 = Ordnance.CANNON_R），不发光、没有尾迹。
static func make_cannon_node(parent: Node3D) -> Node3D:
	var root := Node3D.new()
	parent.add_child(root)
	var ball := MeshInstance3D.new()
	var sp := SphereMesh.new()
	sp.radius = Ordnance.CANNON_R
	sp.height = Ordnance.CANNON_R * 2.0
	ball.mesh = sp
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.06, 0.06, 0.08)      # 黑
	m.roughness = 0.55
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.emission_enabled = false                     # 明确不发光
	ball.material_override = m
	root.add_child(ball)
	return root


## 轨道标记召唤球：紫色小球 + 光晕
static func make_marker_node(parent: Node3D) -> Node3D:
	var root := Node3D.new()
	parent.add_child(root)

	var ball := MeshInstance3D.new()
	var sp := SphereMesh.new()
	sp.radius = 0.20
	sp.height = 0.40
	ball.mesh = sp
	var bm := StandardMaterial3D.new()
	bm.albedo_color = Color(0.72, 0.45, 1.0)
	bm.emission_enabled = true
	bm.emission = Color(0.62, 0.22, 1.0)
	bm.emission_energy_multiplier = 3.0
	ball.material_override = bm
	root.add_child(ball)

	var halo := MeshInstance3D.new()
	var hs := SphereMesh.new()
	hs.radius = 0.52
	hs.height = 1.04
	halo.mesh = hs
	halo.material_override = glow_mat(Color(0.72, 0.42, 1.0, 0.50))
	root.add_child(halo)
	return root


## 箭矢：沿局部 -Z 建（配合 Basis.looking_at 的朝向约定），
## 这样把 basis 对准速度方向就是"平抛出去"，而不是竖着飞。
static func make_arrow_node(parent: Node3D, dist_tiles: float, tint_sentry: bool) -> Node3D:
	var arrow := Node3D.new()
	var shaft := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.035
	cyl.bottom_radius = 0.035
	cyl.height = 1.0
	shaft.mesh = cyl
	shaft.rotation.x = PI * 0.5               # 圆柱轴 Y -> Z
	shaft.position = Vector3(0, 0, -0.5)
	var head := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.09
	cone.height = 0.24
	head.mesh = cone
	head.rotation.x = -PI * 0.5               # 锥尖朝 -Z
	head.position = Vector3(0, 0, -1.12)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.45, 1.0, 0.95) if tint_sentry else Color(1.0, 0.86, 0.35)
	mat.emission_enabled = true
	mat.emission = mat.albedo_color
	mat.emission_energy_multiplier = 1.4
	shaft.material_override = mat
	head.material_override = mat
	arrow.add_child(shaft)
	arrow.add_child(head)
	arrow.scale = Vector3.ONE * clampf(dist_tiles * 0.22, 0.6, 1.4)
	parent.add_child(arrow)
	return arrow


# ══════════════════════════════════════════════════════════════════════════════
# 朝向 + 尾迹
# ══════════════════════════════════════════════════════════════════════════════
## 把 node 对准速度方向；炮弹顺便按速度重排尾迹。
## speed = 当前速度（格/秒），尾迹长度线性增长：0 速度 -> 0，TAIL_SPEED_REF -> 铺满。
## 尾迹以 TAIL_REF_R 为准（炮弹本体缩小时尾迹不变，用户口径）。
## 起点 inner = 光晕半径：第一颗尾迹珠会包住内球和光晕，球就不会"跑到光晕前面"。
static func orient(node: Node3D, cur: Vector3, prev: Vector3, speed: float = 0.0) -> void:
	var dir := cur - prev
	if dir.length() < 0.0001:
		return
	# 用三维速度（含竖直分量）定朝向：箭矢会跟着抛物线先仰后俯，这才是"平抛出去"。
	# 注意保留原有缩放：looking_at 返回单位正交阵，直接赋值会把 scale 抹掉。
	var sc := node.scale
	node.basis = Basis.looking_at(dir.normalized(), Vector3.UP).scaled(sc)

	if not node.has_meta("tail"):
		return
	var tail = node.get_meta("tail")
	if not (tail is Array):
		return
	var segs: Array = tail
	var diam := TAIL_REF_R * 2.0
	var span: float = clampf(diam * TAIL_MAX_MULT * (speed / TAIL_SPEED_REF), 0.0, diam * TAIL_MAX_MULT)
	var inner := SHELL_HALO_R
	for i in segs.size():
		var seg: MeshInstance3D = segs[i]
		if not is_instance_valid(seg):
			continue
		var f := 1.0 - float(i) / float(segs.size())
		# 局部空间：looking_at 之后局部 -Z 是前进方向，所以 +Z 是速度的反方向。
		seg.position = Vector3(0, 0, inner + (span - inner) * (float(i) / float(maxi(1, segs.size() - 1))))
		var ss := seg.mesh as SphereMesh
		if ss != null:
			ss.radius = TAIL_REF_R * f
			ss.height = TAIL_REF_R * 2.0 * f
		var m := seg.material_override as StandardMaterial3D
		if m != null:
			m.albedo_color = Color(1.0, 0.80, 0.32, TAIL_ALPHA * f)
		seg.visible = span > inner + 0.01
