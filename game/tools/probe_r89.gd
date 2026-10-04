# 第 89 轮排查探针：火箭齐射的"落点命运"统计 + 发射者阵亡后落地伤害。
# 为什么单开一个探针：用户报"火箭弹碰到地面后消失且无法造伤"，需要在【竞技场 + 跨河 + 真实齐射】下
# 把每一发的下场数出来（落地爆炸 / 落河 / 落空场 / 被击落 / 出界），再单独验"发射者中途阵亡"这一条。
#   Godot_v4.7.2-stable_win64.exe --headless --path game --script res://tools/probe_r89.gd --quit-after 60000
extends SceneTree

var _s: Node
var _t := 0.0
var _stage := 0
var _t0 := 0.0
var _fail := 0
var _checks := 0
var _heli: Unit = null
var _victim: Unit = null
var _hp0 := 0


func _initialize() -> void:
	Level.current = "arena"
	_s = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(_s)


func _chk(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("  PASS  %s" % what)
	else:
		_fail += 1
		print("  FAIL  %s" % what)


func _unit(nm: String) -> Unit:
	for u in _s.units:
		if u.name == nm:
			return u
	return null


func _move(u: Unit, c: Vector2i) -> void:
	u.cell = c
	if u.visual != null:
		u.visual.position = Vector3(float(c.x) + 0.5, u.hover, float(c.y) + 0.5)


## 日志里这一段的"落点命运"计数
func _fates() -> Dictionary:
	var out := {"落地爆炸": 0, "落河": 0, "落空场": 0, "被击落": 0, "出界": 0, "撞到角色落地": 0}
	for lg in _s._debug_log:
		var s := String(lg)
		if s.contains("火箭落地"):
			out["落地爆炸"] += 1
		elif s.contains("落进河里"):
			out["落河"] += 1
		elif s.contains("落在空场"):
			out["落空场"] += 1
		elif s.contains("在半空被打爆"):
			out["被击落"] += 1
		elif s.contains("还没落地就撞到"):
			out["撞到角色落地"] += 1
		elif s.contains("飞到边界"):
			out["出界"] += 1
	return out


func _process(d: float) -> bool:
	_t += d
	match _stage:
		0:
			if _t < 0.4:
				return false
			print("\n[1] 竞技场跨河齐射：8 发的落点命运（关掉哨兵，只看火箭自己）")
			_s.gm.clear_all_sentries()
			_heli = _unit("俯冲轰炸直升机（不要问那么多）")
			_victim = _unit("Gerald (E)")
			for u in _s.units:
				_move(u, Vector2i(1, 38))
			_move(_heli, Vector2i(12, 18))                 # 我方河边
			_move(_victim, Vector2i(10, 22))               # 对岸
			_heli.power_cur = _heli.power_max
			_heli.armor_cur = _heli.armor_max
			_victim.power_cur = 999000
			_victim.armor_cur = 0
			_victim.pr = 0
			_hp0 = _victim.power_cur
			_s._debug_log.clear()
			_s._rocket_salvo(_heli, Vector2(10.5, 22.5))   # 真实齐射（4 波 / 每波 1 秒）
			_t0 = _t
			_stage = 1
		1:
			if _t - _t0 >= 12.0:
				var f := _fates()
				var landed: int = int(f["落地爆炸"]) + int(f["落河"])
				print("    命运：%s" % [f])
				print("    对岸目标力量 %d -> %d（掉 %d）" % [
					_hp0, _victim.power_cur, _hp0 - _victim.power_cur])
				_chk(landed + int(f["被击落"]) + int(f["落空场"]) >= 8,
					"8 发全部有明确下场（落地/落河/被击落，没有「凭空消失」）")
				_chk(int(f["落地爆炸"]) >= 1, "至少有一发正常落地爆炸（火箭的落地结算是活的）")
				print("    说明：落河 = 口径如此（炮弹落水直接消失）；没伤害多半是散布 8 环打空")
				# ── 第二种情况：火箭在飞，发射者阵亡 ──
				print("\n[2] 发射者中途坠机：落地还有伤害吗")
				_s.clear_projectiles()
				_s._debug_log.clear()
				_move(_heli, Vector2i(12, 18))
				_heli.power_cur = _heli.power_max
				_heli.tags.erase("crashing")
				if _heli.visual != null:
					_heli.visual.visible = true
				_victim.power_cur = 999000
				var before: int = _victim.power_cur
				var rk := Ordnance.make_rocket(_heli, Vector3(12.5, _heli.hover + 0.25, 18.5),
					Vector2(10.5, 22.5), false, _s.rng)
				_s.field.register(rk)
				_heli.power_cur = 0
				_s._on_unit_died(_heli)                    # 出膛之后发射者立刻阵亡
				print("    发射者力量 %d（已阵亡）｜ 火箭在飞 %s" % [_heli.power_cur, rk.alive])
				_t0 = _t
				_stage = 2
		2:
			if _t - _t0 >= 3.0:
				var dmg := 999000 - _victim.power_cur
				print("    落地后对目标造成 %d 点伤害" % dmg)
				_chk(dmg >= 40000,
					"发射者阵亡后落地照样有伤害（发射单里是开火那一刻的快照）")
				print("\n── r89 探针：%d 项检查，失败 %d 项 ──" % [_checks, _fail])
				Level.current = "field"
				return true
	return false
