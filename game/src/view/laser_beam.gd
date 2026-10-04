# ══════════════════════════════════════════════════════════════════════════════
# 激光光束（场景侧）：一条"活着的激光" = 推进 + 表现 + **统一结算**
#
# 形态：`RefCounted` + 构造注入宿主（battle_scene），模块内用 `_st.xxx` 显式访问宿主状态
# —— 与 SentryRunner / ViewFx / ProjectileSink 同一套做法。`_st` **故意用动态类型**
# （宿主没有 class_name，静态标成 Node3D 会在分析期报 Cannot find member）。
#
# 生命周期（调用方驱动）：
#   `LaserBeam.Runner.spawn(id, a, b)`  -> 造一条激光（终点按地形截断）
#   宿主 `_process(delta)` 里 `laser_mod.tick(delta)` -> 每个物理帧累加帧伤
#   光束结束（寿命到 / 被显式结算）   -> `settle()` **统一结算一次**，然后 `alive = false`
#
# 帧伤模型：每帧每个被覆盖的角色 +1 帧，伤害 = 帧数 × 每帧伤害（由激光 id 决定：
# `"reaper_laser"` = 2 点/帧）。所以"扫得慢/停留久"的格子自然吃更多帧数、伤害更高 ——
# Reaper 的"越远扫过的格子越多但每格伤害越低"就靠这条自然出现，不需要按距离查表。
#
# 命中几何与地形截断在 core/laser.gd（纯规则，可无头测试）；伤害在 Damage.magic_hit
# （魔法伤害：只吃魔抗、**无视护甲**）。
# ══════════════════════════════════════════════════════════════════════════════
class_name LaserBeam
extends RefCounted

## 激光 id（决定帧伤）—— Reaper 用 "reaper_laser"
var id: String = ""
## 每帧伤害（点）。spawn / make_beam 会按 id 从 Laser.DMG_PER_FRAME 取
var dmg_per_frame: int = 2
## 起点（Reaper 的蓝环：离地 Laser.BASE_HEIGHT）
var a: Vector3 = Vector3.ZERO
## 终点（**已按地形截断**；Reaper 的"末端是攻击目标"，所以可以比起点低）
var b: Vector3 = Vector3.ZERO
var alive: bool = true
## 角色 instance_id -> 被光束覆盖的物理帧数
var frames_by_id: Dictionary = {}
## Reaper 蓝环同色；攻击前变红由调用方控制（set_color）
var color: Color = Color(0.35, 0.6, 1.0)

## 寿命（秒）：<= 0 表示不自动结算，由调用方显式 settle()
var life: float = 0.0
var age: float = 0.0
## 不参与帧伤的角色（例如发射者自己：Reaper 太胖，光束起点就在它身体里）
var ignore_units: Array[Unit] = []
## 光束不是飞行物：不能被击落、也不惊动哨兵。这两项只是把口径显式写出来（供测试核对），
## 它根本不进 ProjectileField，所以没有任何"被打掉"的路径。
var hit_tags: Array[String] = []
var sentry_trigger: bool = false

## ── 动态光柱（第 100 轮 · Reaper）────────────────────────────────────────────
## 非空时 = 这根 beam 的**落点每帧沿弧移动**（规格来自 `Reaper.beam_arc_spec`）；
## 空 = 静态光束（行为与第 98/99 轮完全一致）。
## **整个动画只有这一根 beam**（用户否定了"N 条离散静态光束"那种一大片的效果）。
var arc_spec: Dictionary = {}
var arc_t: float = 0.0              # 动画进度 0..1
var arc_sec: float = 0.0            # 总时长（秒）

var _st = null                       # 宿主 battle_scene（动态类型，见文件头）
var _node: MeshInstance3D = null      # 光束表现（细长圆柱）
var _mat: StandardMaterial3D = null
var _carry: Dictionary = {}           # instance_id -> 不足一帧的余量（掉帧时补齐）


func _init(host: Node3D) -> void:
	_st = host


## 造一条激光（工厂）：按 id 取每帧伤害，并建出光束表现。
## 便于测试直接造一条；注册进 Runner 走 `Runner.spawn()`（它会先做地形截断）。
static func make_beam(host: Node3D, id: String, a: Vector3, b: Vector3) -> LaserBeam:
	var beam := LaserBeam.new(host)
	beam.id = id
	beam.dmg_per_frame = Laser.dmg_per_frame_of(id)
	beam.a = a
	beam.b = b
	beam.build_visual()
	return beam


# ══════════════════════════════════════════════════════════════════════════════
# 表现：一条细长圆柱，从 a 指到 b（光束粗细 = 判定半径 Laser.HIT_R，所见即所中）
# ══════════════════════════════════════════════════════════════════════════════

func build_visual() -> void:
	if _st == null:
		return
	var mi := MeshInstance3D.new()
	mi.name = "LaserBeam"
	var cyl := CylinderMesh.new()
	cyl.top_radius = Laser.HIT_R
	cyl.bottom_radius = Laser.HIT_R
	cyl.height = 1.0
	mi.mesh = cyl
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.albedo_color = Color(color.r, color.g, color.b, 0.85)
	_mat.emission_enabled = true
	_mat.emission = color
	_mat.emission_energy_multiplier = 2.0
	mi.material_override = _mat
	_st.add_child(mi)
	_node = mi
	refresh()


## 端点变了就重排这根圆柱（位置 = 中点；圆柱的 +Y 轴对齐 a->b）
func refresh() -> void:
	if _node == null:
		return
	var d := b - a
	var len := d.length()
	if len <= 0.0001:
		_node.visible = false
		return
	_node.visible = true
	var cyl := _node.mesh as CylinderMesh
	if cyl != null:
		cyl.height = len
	var y := d / len
	var x := Vector3.UP.cross(y)
	if x.length() < 0.001:
		x = Vector3.RIGHT
	x = x.normalized()
	var z := x.cross(y).normalized()
	_node.transform = Transform3D(Basis(x, y, z), (a + b) * 0.5)


## 蓝 <-> 红（激光预警由调用方控制：攻击前 set_color(Color.RED) 亮 2 秒再发）
func set_color(c: Color) -> void:
	color = c
	if _mat != null:
		_mat.albedo_color = Color(c.r, c.g, c.b, _mat.albedo_color.a)
		_mat.emission = c


## 光束消失（结算完就不该再看得见）
func fade_out() -> void:
	if _node != null:
		_node.queue_free()
		_node = null


# ══════════════════════════════════════════════════════════════════════════════
# 推进与结算
# ══════════════════════════════════════════════════════════════════════════════

## 动态光柱：按本帧进度重算落点（再按地形截断），并刷新表现。
## 落点 = `Reaper.arc_point(arc_spec, t)`；t 与寿命同步推进（t 到 1 时 age 正好到 life，
## 由 `Runner.tick` 统一结算）。每帧都做一遍 `clip_by_terrain` —— 既有口径不丢。
func _advance_arc(delta: float) -> void:
	if arc_spec.is_empty():
		return
	arc_t = clampf(arc_t + delta / maxf(arc_sec, 0.01), 0.0, 1.0)
	var e := Reaper.arc_point(arc_spec, arc_t)
	var flat := Laser.clip_by_terrain(Vector2(a.x, a.z), Vector2(e.x, e.z),
		_st.placeables, _st.GW, _st.GH)
	b = Vector3(flat.x, e.y, flat.y)
	refresh()


## 宿主每个物理帧调一次：**先把落点推进一帧**，再把本帧覆盖到的目标累加进 frames_by_id。
## **角色与沙盒元素共用这一张表**（实例 id 全局唯一）：第 100 轮用户口径 ——
## 激光对沙盒元素也要有伤害，所以光路上的道具与角色一样按帧累计。
## `delta` 折算成 60Hz 的"帧"（Laser.FRAME_HZ），所以掉帧不会改变每秒伤害；
## 不足一帧的余量存在 `_carry` 里，下一帧继续攒（不会因为 1/120 秒的帧而永远攒不出 1 帧）。
func tick(delta: float) -> void:
	if not alive or _st == null:
		return
	age += delta
	_advance_arc(delta)          # ★ 动态光柱：本帧先把落点沿弧挪一点，再判命中
	var per: float = delta * Laser.FRAME_HZ
	if per <= 0.0:
		return
	var units: Array[Unit] = _st.units
	for u in units:
		if u == null or not u.is_alive() or ignore_units.has(u):
			continue
		if not Laser.hits_unit(a, b, u):
			continue
		var key := u.get_instance_id()
		var acc: float = float(_carry.get(key, 0.0)) + per
		var whole := int(floor(acc))
		if whole > 0:
			frames_by_id[key] = int(frames_by_id.get(key, 0)) + whole
			acc -= float(whole)
		_carry[key] = acc
	# 沙盒元素（第 100 轮）：挡路的土堆与被穿过的木刺都算 —— 判据在 Laser.hits_placeable
	var placeables: Array[Placeable] = _st.placeables
	for pl in placeables:
		if pl == null or not pl.is_alive():
			continue
		if not Laser.hits_placeable(a, b, pl):
			continue
		var pkey := pl.get_instance_id()
		var pacc: float = float(_carry.get(pkey, 0.0)) + per
		var pwhole := int(floor(pacc))
		if pwhole > 0:
			frames_by_id[pkey] = int(frames_by_id.get(pkey, 0)) + pwhole
			pacc -= float(pwhole)
		_carry[pkey] = pacc


## **统一结算一次**（同一束光只结算一次），然后把 alive = false。
## 伤害 = 帧数 × 每帧伤害，走魔法伤害（只吃魔抗、无视护甲）；角色与沙盒元素都结算。
func settle() -> Array[Damage.Hit]:
	if not alive or _st == null:
		return []
	var units: Array[Unit] = _st.units
	var placeables: Array[Placeable] = _st.placeables
	var rng = _st.rng
	var out: Array[Damage.Hit] = Laser.settle(units, frames_by_id, dmg_per_frame, rng, placeables)
	alive = false
	fade_out()
	return out


# ══════════════════════════════════════════════════════════════════════════════
# 场景里的激光管理器（宿主持有：`battle_scene.laser_mod`）
# ══════════════════════════════════════════════════════════════════════════════
class Runner extends RefCounted:
	var _st = null
	## 在途的激光（结算完的就移出去）
	var beams: Array[LaserBeam] = []

	func _init(host: Node3D) -> void:
		_st = host

	## 发一条激光。终点先按地形截断（土堆拦、木刺不拦，见 Laser.clip_by_terrain）。
	func spawn(id: String, a: Vector3, b: Vector3) -> LaserBeam:
		var clipped := Laser.clip_by_terrain(Vector2(a.x, a.z), Vector2(b.x, b.z),
			_st.placeables, _st.GW, _st.GH)
		var to := Vector3(clipped.x, b.y, clipped.y)
		var beam := LaserBeam.make_beam(_st, id, a, to)
		beams.append(beam)
		return beam

	## 每个物理帧推进：先累加帧伤，再把"寿命到点"的光束统一结算掉。
	func tick(delta: float) -> void:
		if beams.is_empty():
			return
		var keep: Array[LaserBeam] = []
		for beam in beams:
			if not beam.alive:
				continue
			beam.tick(delta)
			if beam.life > 0.0 and beam.age >= beam.life:
				_report(beam.settle())
				continue
			keep.append(beam)
		beams = keep

	## 在途激光数
	func count() -> int:
		var n := 0
		for beam in beams:
			if beam.alive:
				n += 1
		return n

	## 帧数表：传 LaserBeam = 它自己的；传 String = 合并同 id 的所有在途激光
	func frames(id_or_beam: Variant) -> Dictionary:
		if id_or_beam is LaserBeam:
			var b := id_or_beam as LaserBeam
			return b.frames_by_id.duplicate()
		var want := String(id_or_beam)
		var merged := {}
		for beam in beams:
			if beam.id != want:
				continue
			for k in beam.frames_by_id.keys():
				merged[k] = int(merged.get(k, 0)) + int(beam.frames_by_id[k])
		return merged

	## 把所有在途激光都结算掉（返回命中列表；每条的收尾与自动结算完全一致）
	func settle_all() -> Array:
		var out: Array = []
		for beam in beams:
			if beam.alive:
				out.append_array(_report(beam.settle()))
		beams.clear()
		return out

	## 结算之后必须走的收尾：写日志 + 受伤被动钩子（角色）/ 道具收尾（沙盒元素）
	func _report(hits: Array[Damage.Hit]) -> Array[Damage.Hit]:
		for h in hits:
			_st._log(h.text)
			if h.unit != null:
				_st._after_damage_to_unit(h.unit)
			elif h.placeable != null:
				# 第 100 轮：激光也会打沙盒元素（魔抗免疫的那三个走公式后是 0，
				# 但日志照样写；真被打掉时这里负责碎片/摧毁表现）
				_st._after_damage_to_placeable(h.placeable)
		return hits
