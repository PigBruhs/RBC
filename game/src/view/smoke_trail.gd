# 第 111 轮：**白色烟雾轨迹**（用户口径：「火箭经过的轨迹上要出现白色烟雾，逐渐变淡**两秒**散去」）
#
# 设计：**对象池** —— 预建 `POOL` 个白色小球，只用"隐藏/显示 + 改 alpha/scale"，
# 运行期**不 new/free**（火箭一次齐射好几发，每帧 new 会抖）。
#   · `step(delta, emitters)` 每帧调一次：先推进所有在飞的烟雾（淡出 + 略微膨胀），
#     再给每个 `emitters` 位置按 `EMIT_GAP` 的节奏冒一颗新的。
#   · `LIFE = 2.0` 秒：alpha 从 `ALPHA0` 线性降到 0，半径从 `R0` 涨到 `R1`（烟会散开）。
class_name SmokeTrail
extends Node3D

const POOL := 160                     # 池容量（够 1~2 发火箭的 2 秒拖尾）
const LIFE := 2.0                     # 每颗烟的生命（用户口径：**两秒**散去）
const EMIT_GAP := 0.035               # 冒烟间隔（秒）
const R0 := 0.16                      # 初始半径（格）
const R1 := 0.55                      # 消散时的半径（格）—— 看着像"散开"
const ALPHA0 := 0.55                  # 初始透明度（白烟，不要糊住画面）
const COLOR_SMOKE := Color(1.0, 1.0, 1.0)

var _nodes: Array[MeshInstance3D] = []
var _mats: Array[StandardMaterial3D] = []
var _life: PackedFloat32Array = PackedFloat32Array()
var _emit_t := 0.0
var _next := 0                        # 环形游标（池里找下一个可用的）


static func make(host: Node3D) -> SmokeTrail:
	var t := SmokeTrail.new()
	t._build()
	host.add_child(t)
	return t


func _build() -> void:
	var mesh := SphereMesh.new()
	mesh.radial_segments = 6
	mesh.rings = 3
	mesh.radius = 1.0
	mesh.height = 2.0
	for i in POOL:
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(COLOR_SMOKE.r, COLOR_SMOKE.g, COLOR_SMOKE.b, 0.0)
		mat.no_depth_test = false             # 烟要参与深度（不然会浮在所有东西前面）
		mi.material_override = mat
		mi.visible = false
		add_child(mi)
		_nodes.append(mi)
		_mats.append(mat)
		_life.append(0.0)


## 每帧调用。`emitters` = 本帧要冒烟的世界坐标列表（一般是"在飞的制导火箭"）。
func step(delta: float, emitters: Array) -> void:
	# ① 推进已有烟雾：淡出 + 膨胀
	for i in POOL:
		if _life[i] <= 0.0:
			continue
		_life[i] -= delta
		if _life[i] <= 0.0:
			_life[i] = 0.0
			_nodes[i].visible = false
			_mats[i].albedo_color = Color(COLOR_SMOKE.r, COLOR_SMOKE.g, COLOR_SMOKE.b, 0.0)
			continue
		var k: float = 1.0 - _life[i] / LIFE          # 0（刚冒）-> 1（快没了）
		var a: float = ALPHA0 * (1.0 - k)
		var r: float = lerpf(R0, R1, k)
		_mats[i].albedo_color = Color(COLOR_SMOKE.r, COLOR_SMOKE.g, COLOR_SMOKE.b, a)
		_nodes[i].scale = Vector3(r, r, r)
	# ② 按节奏给每个发射点冒一颗新的
	if emitters.is_empty():
		_emit_t = 0.0
		return
	_emit_t += delta
	while _emit_t >= EMIT_GAP:
		_emit_t -= EMIT_GAP
		for e in emitters:
			_spawn(e)


func _spawn(pos: Vector3) -> void:
	# 环形游标：优先找空位，找不到就覆盖最老的那颗（宁可丢旧烟也不扩张池）
	var idx := -1
	for i in POOL:
		var j := (_next + i) % POOL
		if _life[j] <= 0.0:
			idx = j
			break
	if idx < 0:
		idx = _next
	_next = (idx + 1) % POOL
	var mi: MeshInstance3D = _nodes[idx]
	mi.position = pos
	mi.scale = Vector3(R0, R0, R0)
	mi.visible = true
	_mats[idx].albedo_color = Color(COLOR_SMOKE.r, COLOR_SMOKE.g, COLOR_SMOKE.b, ALPHA0)
	_life[idx] = LIFE


# ── 测试门面 ───────────────────────────────────────────────────────────────
func t_live_count() -> int:
	var n := 0
	for i in POOL:
		if _life[i] > 0.0:
			n += 1
	return n


## 第 `i` 个池位的剩余寿命（探针用；不关心可见性）
func t_life(i: int) -> float:
	return _life[i] if i >= 0 and i < POOL else 0.0


## 当前"活着"的烟雾里最大的那颗的 alpha（探针用来验证"在变淡"）
func t_max_alpha() -> float:
	var a := 0.0
	for i in POOL:
		if _life[i] > 0.0:
			a = maxf(a, _mats[i].albedo_color.a)
	return a


## 活着的烟雾里最"老"的那颗的 alpha（应当最小 = 最淡）
func t_min_alpha_live() -> float:
	var a := 1.0
	var any := false
	for i in POOL:
		if _life[i] > 0.0:
			a = minf(a, _mats[i].albedo_color.a)
			any = true
	return a if any else -1.0


func t_life_const() -> float: return LIFE

func t_pool() -> int: return POOL
