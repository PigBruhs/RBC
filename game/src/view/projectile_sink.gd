# ══════════════════════════════════════════════════════════════════════════════
# 弹道物与爆炸结算：弹道物理只负责"打没打中"，后果全在这里（用户口径）
#
# 职责边界：
#   · ProjectileField 只管物理与上报（EV_OUT / EV_HIT_PROJ / EV_HIT_TARGET /
#     EV_HIT_BODY / EV_LANDED / EV_REMOVED），后果由本模块处理
#   · 伤害数值与命中规则来自 core/*（Damage / Ballistics / Targeting / Ordnance）
#   · 表现（红圈 / 闪光）来自兄弟模块 ViewFx，通过 _st.fx 调用
#   · 【唯一落地入口】land_shell：正常落地（EV_LANDED）与"飞行中撞到角色"
#     （EV_HIT_BODY，落点 = 命中处）都走它，所以两条路的伤害口径永远一致
#
# 宿主是 battle_scene（Node3D）。**故意用动态类型**：宿主提供的 units / gm / rng /
# field / _log / _apply_attack … 是战场场景自己的成员，把 _st 静态标成 Node3D 会在
# 编译期报 "Cannot find member ... in base Node3D"（同 battle_ui.gd / SentryRunner /
# ViewFx）。_init 的参数仍标 Node3D：接口契约不变。
#
# 测试直读的字段（_salvo_u / _salvo_dbg / _grenade_models / _proj_groups /
# _orbital_marks）**声明仍然留在 battle_scene**，本模块通过 _st._xxx 读写，
# 所以 playtest / 探针的 `_s._xxx` 一行都不用改。
# ══════════════════════════════════════════════════════════════════════════════
class_name ProjectileSink
extends RefCounted

var _st = null                 # 宿主（battle_scene）；动态类型见文件头


func _init(host: Node3D) -> void:
	_st = host


# ══════════════════════════════════════════════════════════════════════════════
# 弹道生成（物理参数来自 Ordnance，伤害/落点放进发射单）
# ══════════════════════════════════════════════════════════════════════════════

## 炮弹（普攻 / 地毯式轰炸共用）。速度恒定 Ordnance.SHELL_TILES_PER_SEC 格/秒。
func spawn_shell(caster: Unit, to: Vector2, ends_turn: bool,
		pre: float = 0.0, group: String = "", blast_r: float = Ordnance.DEFAULT_BLAST_R) -> Projectile:
	var p := Ordnance.make_shell(caster, to, ends_turn, _st.rng, pre, group, blast_r)
	_st.field.register(p)
	return p


func spawn_marker(caster: Unit, to: Vector2) -> Projectile:
	var p := Ordnance.make_marker(caster, to)
	_st.field.register(p)
	return p


func spawn_fragment(caster: Unit, from: Vector3, dir: Vector2) -> Projectile:
	var p := Ordnance.make_fragment(caster, from, dir)
	_st.field.register(p)
	return p


## 轨道信标的召唤球落地 -> 登记 GM 计时并立光柱
func fire_skill_at(sh: Ordnance.Shot, fpos: Vector2) -> void:
	var caster: Unit = sh.caster if sh != null else null
	if caster == null:
		return
	var d := Skills.get_def("orbital_strike")
	var cell := Vector2i(int(floor(fpos.x)), int(floor(fpos.y)))
	_st.gm.schedule("orbital_strike", caster, cell, fpos, int(d["delay_turns"]))
	_st._orbital_marks.append(fpos)
	# 光柱挂在这一发身上：允许多个在途打击同时存在（用户要求）
	var pend: GameMaster.Pending = _st.gm.pending[_st.gm.pending.size() - 1]
	# 光柱归技能模块（它原本在 battle_scene 里，第 97 轮随 SkillRunner 一起搬走）——
	# 跨模块调用必须指向**新家**，不能还调宿主上那个已经搬走的 `_raise_pylon_at`
	# （否则运行时报 Nonexistent function，而编译期查不出来）。
	pend.pylon = _st.skills_mod.raise_pylon_at(fpos)
	_st._log("%s 使用【%s】：标记落点 (%d, %d)，剩余 %d" %
		[caster.name, d["name"], cell.x, cell.y, caster.energy_points()])
	_st._log("  ⏳ 轨道火力已锁定：%d 个回合后落下 %d 发（GameMaster 计时：%s）" % [
		int(d["delay_turns"]), d["shells"], _st.gm.pending_desc()])


# ══════════════════════════════════════════════════════════════════════════════
# 命中判定
# ══════════════════════════════════════════════════════════════════════════════

## 箭矢在这一段路径里撞到了什么。返回 {unit: Unit} / {placeable: Placeable} / {}
func arrow_hit_check(p: Projectile, prev: Vector3, cur: Vector3) -> Dictionary:
	# 跳过谁：默认是自己的箭不打自己；弹反箭跳过的是"出手位置的那个人"（杰拉尔德）
	var skip: Unit = null if p.hit_self else (p.ignore_unit if p.ignore_unit != null else p.owner_unit)
	# ① 角色（细圆柱判定；沿线采样，保证不漏）。判定半径用这一发自己的身体半径
	#    （箭矢 0.075 / 加农炮弹 0.25）
	#    一切按物理碰撞判定（第 84 轮）：必须真的碰到身体 —— 碰到谁就伤谁（不分敌我）
	var u := Targeting.arrow_body_hit_seg(prev, cur, skip, _st.units, _st.UNIT_BODY_R, p.hit_r)
	if u != null:
		if p.shot != null:
			p.shot.last_hit_dist = p.from.distance_to(p.pos())   # 破片伤害要用"飞了多远"
		return {"unit": u}
	# ② 沙盒道具：拦不拦由 Ballistics 一处说了算
	#    （木刺永不拦箭；土堆只要箭从它上空飞过就拦；投掷物土堆挡不住）
	#    注意这里看的是【伤害归属】（owner_unit），不是上面那个"跳过谁"
	var locked: Placeable = p.shot.target_placeable if p.shot != null else null
	if locked != null and locked.is_alive():
		var lc: Placeable = _st._placeable_near(cur)
		if lc == locked or Vector2(cur.x, cur.z).distance_to(
				Vector2(float(locked.cell.x) + 0.5, float(locked.cell.y) + 0.5)) <= 0.6:
			return {"placeable": locked}          # 玩家/AI 明确锁定的道具：一定打得中
	if p.owner_unit != null and p.owner_unit.role == UnitData.Role.THROWER:
		return {}
	var pl: Placeable = _st._placeable_near(cur)
	if pl != null and Ballistics.placeable_blocks(pl, p.kind):
		return {"placeable": pl}
	return {}


## 箭矢命中角色/道具之后的结算（蓄势 / 子弹衰减 / 破片衰减 / 弹反 / 反弹箭）
func resolve_arrow_hit(sh: Ordnance.Shot, what: Dictionary) -> void:
	var attacker: Unit = sh.caster
	var silent: bool = not sh.ends_turn
	# 弓箭手被动「蓄势」：只吃"选普攻选目标"的那一发（哨兵箭 tint_sentry、技能都不算）
	var is_basic: bool = sh.target != null and not sh.tint_sentry
	var bonus: int = Passives.focus_bonus_milli(attacker) if is_basic else 0
	var mult: float = sh.power_mult
	if what.has("unit"):
		var victim: Unit = what["unit"]
		# 被动：箭矢弹反。先扣下伤害，暂停全局打 QTE，结果出来再结算（用户口径）。
		if _st.gm.claim_arrow_deflect(victim):
			if is_basic:
				Passives.clear_focus(attacker)      # 这一发算命中了：蓄势清零
			_st._start_arrow_qte(victim, sh, bonus)
			return
		# 子弹：阶梯衰减（0-12 格 100% / 12-16 格 60% / 16-24 格 20% / >24 格 0）
		if sh.kind == Projectile.KIND_BULLET:
			var bd: float = sh.last_hit_dist
			var bmult: float = Damage.bullet_mult(bd)
			var bpw: int = int(floor(float(attacker.power_cur) * bmult))
			var bbr: int = int(floor(float(attacker.armor_break) * bmult))
			_st._apply_attack(attacker, victim, true, silent, 0, 1.0, bpw, bbr)
			_st._log("  ✦ 子弹命中 %s：飞行 %.1f 格 ×%.0f%% → 力 %d / 甲 %d" % [
				victim.name, bd, bmult * 100.0, bpw / 1000, bbr / 1000])
			return
		# 破片：伤害按"离生成点走了多远"衰减（0 格 25/25 ｜ 3 格 12/12 ｜ 16 格 0）
		if sh.kind == Projectile.KIND_FRAGMENT:
			var fd: float = sh.last_hit_dist
			_st._apply_attack(attacker, victim, true, silent, 0, 1.0,
				Damage.fragment_power_milli(fd), Damage.fragment_break_milli(fd))
			_st._log("  ✦ 破片命中 %s：飞行 %.1f 格 → 力 %d / 甲 %d" % [
				victim.name, fd,
				Damage.fragment_power_milli(fd) / 1000, Damage.fragment_break_milli(fd) / 1000])
			return
		# 反弹回来的箭：命中一定要有明确日志（用户报过"命中却没伤害、也没日志"）
		if sh.reflected:
			_st._log("  ↩ 反弹箭命中 %s（力量系数 %.0f%%）" % [victim.name, mult * 100.0])
		_st._apply_attack(attacker, victim, sh.break_armor, silent, bonus, mult)
	elif what.has("placeable"):
		_st._damage_placeable(attacker, what["placeable"], silent)
	if is_basic:
		# 用户口径：命中之后清零（打空不算）
		if bonus > 0:
			_st._log("  🏹 %s 的【蓄势】打出 +%d 力量后清零" % [attacker.name, bonus / 1000])
		Passives.clear_focus(attacker)


# ══════════════════════════════════════════════════════════════════════════════
# 弹道事件 -> 后果
# ══════════════════════════════════════════════════════════════════════════════

## ── 弹道物的后果处理：弹道物理只上报，具体做什么全在这里（用户口径）──
func on_projectile_event(event: String, p: Projectile, extra = null) -> void:
	var sh: Ordnance.Shot = p.shot
	match event:
		ProjectileField.EV_OUT:
			_st._log("  ✈ %s 的%s飞到边界 (%.1f, %.1f)，直接移除（无爆炸）" %
				[p.owner_name, ProjectileField.kind_cn(p.kind), p.removed_at.x, p.removed_at.y])
		ProjectileField.EV_HIT_PROJ:
			var victim: Projectile = extra
			_st._log("  💥 %s的%s 被%s击落" % [p.owner_name, ProjectileField.kind_cn(p.kind),
				ProjectileField.kind_cn(victim.kind)])
			# 用户口径：炮弹类在半空被打掉 -> 走统一的"被拦下"收尾（炮弹/火箭就地空爆，
			# 枪榴弹就地落地开始计时）；召唤球不走这条路（被击落只是整发作废，不炸）。
			for pr in [p, victim]:
				if pr != null and not pr.alive and Ballistics.is_shell_class(pr.kind):
					shell_intercepted(pr, "在半空被打爆")
			# 弓箭手被动「蓄势」：哨兵箭每摧毁一枚投掷物 +1 层
			for pr2 in [p, victim]:
				if pr2 != null and pr2.kind == Projectile.KIND_ARROW \
						and pr2.shot != null and pr2.shot.tint_sentry:
					Passives.add_focus(pr2.shot.caster)
					if Passives.focus_stacks(pr2.shot.caster) > 0:
						_st._log("  🏹 %s【蓄势】+1（下一发普攻 +%d 力量，当前 %d 层）" % [
							pr2.shot.caster.name,
							int(Passives.def("arrow_focus")["power_bonus"]),
							Passives.focus_stacks(pr2.shot.caster)])
		ProjectileField.EV_HIT_TARGET:
			resolve_arrow_hit(sh, extra)
		ProjectileField.EV_HIT_BODY:
			# 用户口径（第 87 轮）：炮弹类飞行途中撞到角色 = **当成在命中处落地**：
			# 照常结算伤害（火箭还要撒破片），不再被当成"被拦下"而整发作废。
			var hit_u: Unit = extra.get("unit", null) if extra is Dictionary else null
			var hit_at := p.pos()
			_st._log("  🛑 %s的%s还没落地就撞到 %s：当成在 (%.1f, %.1f) 落地结算" % [
				p.owner_name, ProjectileField.kind_cn(p.kind),
				hit_u.name if hit_u != null else "障碍物", hit_at.x, hit_at.y])
			land_shell(p, hit_at)
		ProjectileField.EV_LANDED:
			on_proj_landed(p)
		ProjectileField.EV_REMOVED:
			after_projectile_gone(sh)


## 一发弹道物彻底消失之后的收尾：编组计数，或者按发射单结束回合
func after_projectile_gone(sh: Ordnance.Shot) -> void:
	var gid: String = sh.group if sh != null else ""
	if gid != "" and _st._proj_groups.has(gid):
		_st._proj_groups[gid] = int(_st._proj_groups[gid]) - 1
		if int(_st._proj_groups[gid]) <= 0:
			_st._proj_groups.erase(gid)
			_st._finish_turn()
		return
	if sh != null and sh.ends_turn:
		_st._finish_turn()


## 炮弹类【被箭击落】的统一收尾（用户口径第 83/84/96 轮）：
##   · 炮弹 / 火箭 -> 就地空爆（一格球三维判定，真的造成伤害）
##   · 巡飞弹       -> 战斗部就地炸开
##   · 枪榴弹       -> **整发作废：模型直接消失**（第 96 轮用户口径）
##                     不落地、不立模型、不登记 GM 计时、不爆炸 —— 和轨道空爆的召唤球一个待遇。
## 注意（第 87 轮）：**飞行中撞到角色不走这里**，那是"在命中处落地"（land_shell）。
func shell_intercepted(p: Projectile, why: String) -> void:
	if p == null:
		return
	if p.kind == Projectile.KIND_LOITER:
		# 巡飞弹被箭打掉：整发战斗部就地炸开（造伤范围还是它自己的直径两格球）
		_st._loiter_burst(p, p.pos3())
		return
	if Ballistics.intercept_result(p.kind) == "":
		# 被打掉就没了：飞行模型随弹道物一起回收，地上不留东西、GM 里不排队。
		var gc := Vector2i(int(floor(p.pos().x)), int(floor(p.pos().y)))
		_st._log("  🛑 %s的%s%s，整发直接消失（(%d, %d) 不落地、不爆炸）" % [
			p.owner_name, ProjectileField.kind_cn(p.kind), why, gc.x, gc.y])
		return
	_st.fx.flash_sphere(p.pos3(), 0.6, 0.25)
	air_burst(p, why)


## 半空被打爆的炮弹：落点就是它当时的位置。
## 用户口径：三维判定 + 爆炸范围恒定为一格球（半径 0.5）——在头顶上炸但飞得高就没伤害。
## why：日志措辞（现在只有一种：在半空被打爆），伤害口径固定。
func air_burst(p: Projectile, why: String = "被打爆") -> void:
	var sh: Ordnance.Shot = p.shot
	var ctr: Vector3 = p.pos3()
	_st._log("  💥 炮弹在半空%s：(%.2f, %.2f) 高度 %.2f 空爆（一格球，三维判定）" %
		[why, ctr.x, ctr.z, ctr.y])
	_st.fx.show_impact(Vector2(ctr.x, ctr.z), ctr.y)
	var ring: MeshInstance3D = _st.fx.make_impact_ring(Vector2(ctr.x, ctr.z),
		sh.blast_r if sh != null else _st.BLAST_RADIUS)
	ring.position.y = maxf(0.05, ctr.y)
	_st.fx.flash_impact(ring)
	var attacker: Unit = sh.caster if sh != null else null
	# 火箭这类"落地才算威力"的弹种也有 opts 了（第 89 轮：发射那一刻的快照）；
	# 空爆时若发射单里没有（测试构造的），按发射者现算一份（口径与落地一致）。
	var opts: Dictionary = sh.opts if sh != null else {}
	if opts.is_empty() and attacker != null:
		opts = Damage.blast_opts(attacker, _st.rng)
	var hits: Array = Damage.air_burst(attacker, ctr, opts, _st.units, attacker, Damage.AIR_BURST_R)
	if hits.is_empty():
		_st._log("  （一格球内没有角色）")
		return
	for h in hits:
		_st._log(h.text)
		if h.unit != null:
			_st._after_damage_to_unit(h.unit)


## 落地事件（弹道物理上报）
func on_proj_landed(p: Projectile) -> void:
	land_shell(p, p.pos())


## 炮弹类【落地结算】的**唯一入口**（用户口径第 87 轮）：
## 正常落地（EV_LANDED）和"飞行中撞到角色"（EV_HIT_BODY，落点 = 命中处）都走这里 ——
## 所以"撞到人"跟"落地"的伤害口径永远一致，不会又出现"某一路忘了结算"。
## at = 落点（浮点，格坐标）；调用时这一发已经消亡，伤害/破片全靠发射单。
func land_shell(p: Projectile, at: Vector2) -> void:
	if p.kind == Projectile.KIND_LOITER:
		# 巡飞弹是"空中自爆"（近炸引信 / 飞满 32 格 / 被击落）：落河、空场照样炸，
		# 它不是"落进水里"，是炸在那里（用户口径第 90 轮）。
		_st._loiter_burst(p, Vector3(at.x, Loiter.HEIGHT, at.y))
		return
	var sh: Ordnance.Shot = p.shot
	var land_cell := Vector2i(int(floor(at.x)), int(floor(at.y)))
	# 用户口径：炮弹 / 召唤球落进河里直接消失（河里不拦弹道，只是落进去就没了）
	if Level.is_river(land_cell):
		_st._log("  🌊 %s的%s落进河里，直接消失（无爆炸）" % [
			p.owner_name, ProjectileField.kind_cn(p.kind)])
		return
	# 用户口径（第 83 轮）：竞技场外面的"空场"没有格子划分 ——
	#   · 投掷类（枪榴弹 / 轨道信标）落进去直接作废（套用河的规则）
	#   · **炮弹类照常落地结算**：炮弹不会再因为飞出竞技场边界就消失
	if Level.is_void(land_cell) \
			and (p.kind == Projectile.KIND_GRENADE or p.kind == Projectile.KIND_MARKER):
		_st._log("  🌫 %s的%s落在空场 (%d, %d)，直接消失（无效果）" % [
			p.owner_name, ProjectileField.kind_cn(p.kind), land_cell.x, land_cell.y])
		return
	match p.kind:
		Projectile.KIND_SHELL:
			_st.fx.show_impact(at)
			var ring: MeshInstance3D = _st.fx.make_impact_ring(at, sh.blast_r if sh != null else _st.BLAST_RADIUS)
			_st.fx.flash_impact(ring)
			resolve_blast(sh.caster if sh != null else null, at,
				sh.opts if sh != null else {}, sh.blast_r if sh != null else _st.BLAST_RADIUS)
		Projectile.KIND_MARKER:
			fire_skill_at(sh, at)
		Projectile.KIND_ARROW:
			pass
		Projectile.KIND_CANNON:
			pass                              # 加农炮弹打空就是打空，没有爆炸
		Projectile.KIND_ROCKET:
			_st.fx.show_impact(at)                                  # 落点提示（不含红圈也行，这里只是标记）
			resolve_blast(sh.caster if sh != null else null, at,
				sh.opts if sh != null else {}, Ordnance.ROCKET_BLAST_R)
			rocket_fragments(sh.caster if sh != null else null, at)
		Projectile.KIND_GRENADE:
			spawn_grenade_model(land_cell, p)
		Projectile.KIND_FRAGMENT:
			pass                              # 破片打空就是打空
		Projectile.KIND_BULLET:
			pass                              # 子弹打空就是打空


## 火箭落地：从落点随机两个方向生成 2 枚破片（破片口径与手榴弹一致：不分敌我）
func rocket_fragments(caster: Unit, at: Vector2) -> void:
	var from := Vector3(at.x, Ordnance.FRAGMENT_HEIGHT, at.y)
	for i in Ordnance.ROCKET_FRAGMENTS:
		var ang: float = _st.rng.next_float() * TAU
		var fp := Ordnance.make_fragment(caster, from, Vector2(cos(ang), sin(ang)), false)
		fp.hit_self = true
		fp.shot.group = "rocket_frag"
		_st.field.register(fp)
	_st._log("  🚀 火箭落地 (%.1f, %.1f)：直径 2 格爆炸 + %d 枚破片" % [
		at.x, at.y, Ordnance.ROCKET_FRAGMENTS])


## 一次炮击的结算（浮点圆心）。普攻炮击与地毯式轰炸共用这一份逻辑：
##   · 同时造成【破甲伤害】（= 攻方破甲值）与【力量伤害】
##   · 力量伤害无视 50% 物理抗性
##   · 圆沾到格子就算命中（所以圆心到格中心距离 <= BLAST_RADIUS + 0.5）
func resolve_blast(attacker: Unit, ctr: Vector2,
		pre_opts: Dictionary = {}, radius: float = 0.0) -> void:
	var r: float = radius if radius > 0.0 else float(_st.BLAST_RADIUS)
	var o: Dictionary = pre_opts
	if o.is_empty():
		o = Damage.blast_opts(attacker, _st.rng)
	var hits: Array = Damage.blast(attacker, ctr, r, o, _st.units, _st.placeables, attacker, attacker.side, true)
	if hits.is_empty():
		_st._log("  落点范围内没有目标（空爆）")
		return
	for h in hits:
		_st._log(h.text)
		if h.unit != null:
			_st._after_damage_to_unit(h.unit)
		else:
			_st._after_damage_to_placeable(h.placeable)


func resolve_mortar_impact(attacker: Unit, center: Vector2i) -> void:
	resolve_blast(attacker, Vector2(float(center.x) + 0.5, float(center.y) + 0.5), {},
		float(_st.BLAST_RADIUS))


## ── 给自检/试玩用的影子 API（真实碰撞在 ProjectileField.collision 里）──
func proj_collision(p: Projectile) -> Projectile:
	return null if _st.field == null else _st.field.collision(p)


# ══════════════════════════════════════════════════════════════════════════════
# 直升机的吊射 37mm 火箭：8 发、4 次齐射（左右各一发）、每次间隔 1 秒
#   · 用户口径第 93 轮：**波次 4 -> 8**（每波仍然左右各一发 -> 一共 16 发）
#   · 8 波要 7 秒才打完，所以 _st._salvo_u 当"回合占用"标记：
#       AI 回合看门狗在齐射期间不计时；收尾时只有"这一发还是当前回合的主人"才结束回合
# ══════════════════════════════════════════════════════════════════════════════
func rocket_salvo(u: Unit, fpos: Vector2) -> void:
	var cfg := Level.heli()
	var base := GridMath.unit_pos(u)
	var dir := fpos - base
	var doubled := base + dir * float(cfg["aim_mult"])
	var max_d := float(u.rng_max)
	if doubled.distance_to(base) > max_d:
		doubled = base + dir.normalized() * max_d          # 不超过射程 40
	var scatter := float(cfg["scatter_r"])
	var rockets := int(cfg["rockets"])
	var pairs := int(cfg["salvo_pairs"])
	var gap := float(cfg["salvo_gap"])
	var per := maxi(1, rockets / maxi(1, pairs))
	_st._log("  🚁 %s 吊射火箭：瞄准 (%.1f, %.1f)（原始 (%.1f, %.1f) ×%.0f），%d 发 / %d 次齐射" % [
		u.name, doubled.x, doubled.y, fpos.x, fpos.y, float(cfg["aim_mult"]), rockets, pairs])
	# 每发火箭从"机侧"出膛：左手边一发、右手边一发（用户口径）
	var side := (doubled - base).normalized()
	if side.length() < 0.001:
		side = Vector2.RIGHT
	var perp := Vector2(-side.y, side.x)
	# 落点在开火瞬间一次性掷好（每波取其中两发）
	# 第 93 轮：**落点钳进可行动区域** —— "瞄准×2 + 散布 4" 很容易把落点算到竞技场外，
	# 那种落点会一路飞出物理边界（以前被"直接移除"，也就是敌方火箭凭空消失的主因）。
	var rolled: Array[Vector2] = []
	for i0 in rockets:
		var ang0: float = _st.rng.next_float() * TAU
		var rr0 := scatter * sqrt(_st.rng.next_float())        # 圆内均匀
		var pt := doubled + Vector2(cos(ang0) * rr0, sin(ang0) * rr0)
		pt.x = clampf(pt.x, float(_st.PX) + 0.5, float(_st.PX + _st.PW) - 0.5)
		pt.y = clampf(pt.y, float(_st.PY) + 0.5, float(_st.PY + _st.PH) - 0.5)
		rolled.append(pt)
	# 自检用：把这次齐射的基准与落点记下来（试玩直接读）
	_st._salvo_dbg = {"base": base, "rolled": rolled, "spawns": []}
	_st._salvo_u = u                                   # 齐射期间"占着回合"（看门狗让位）
	for k in pairs:
		(_st._salvo_dbg["spawns"] as Array).append(base)
		for i in per:
			var aim: Vector2 = rolled[k * per + i]
			var lateral := -0.32 if i % 2 == 0 else 0.32    # 左 / 右
			var from := Vector3(base.x + perp.x * lateral, u.hover + 0.25, base.y + perp.y * lateral)
			var p := Ordnance.make_rocket(u, from, aim, false, _st.rng)   # 不等落地；伤害快照在发射单里
			p.shot.target = null
			_st.field.register(p)
		_st._log("  🚁 %s 齐射 %d/%d：左右各一发（瞄准 (%.1f, %.1f)，散布半径 %.0f，出膛 (%.1f, %.1f)）" % [
			u.name, k + 1, pairs, doubled.x, doubled.y, scatter, base.x, base.y])
		if k < pairs - 1:
			await _st.get_tree().create_timer(gap).timeout
	_st._salvo_u = null
	# 用户口径：发射完即进入下一回合，无需等待落地。
	# 第 93 轮：**只有"这一发还是当前回合的主人"时才收尾** —— 8 波要 7 秒，
	# 中途可能已经被看门狗/阵亡/换人收过尾了，这里再去 _finish_turn 会结束【下一个人】的回合。
	if _st.active == u:
		_st._finish_turn()
	_st._log("  🚁 %s 的火箭齐射全部出膛（%d 波 / %d 发）" % [u.name, pairs, rockets])


# ══════════════════════════════════════════════════════════════════════════════
# 枪榴弹：地上的模型 + 4 回合后爆炸出 8 枚破片
# ══════════════════════════════════════════════════════════════════════════════

## 落地后立一个手榴弹模型（椭球 + 顶部削平长方体 + 经纬线凹槽），并让 GM 开始计时。
## 用户口径第 87 轮：**落地就和投出者解耦** —— GM 的计时器（Pending.decoupled）不再
## 属于投出者，萨尼铁塔扔完就阵亡也照常爆炸；模型引用挂在 Pending 上，
## 爆炸时按引用回收（同格两发也不会互相顶掉模型）。
func spawn_grenade_model(cell: Vector2i, p: Projectile) -> void:
	var d: Dictionary = Skills.get_def("grenade_launcher")
	var delay: int = int(d.get("delay_turns", 4))
	var caster_name := p.owner_name
	var caster_side: int = p.side
	var old = _st._grenade_models.get(cell, null)
	if old != null and is_instance_valid(old):
		(old as Node3D).queue_free()
	var root: Node3D = ProjectileField.build_grenade_model(_st)
	root.position = Vector3(float(cell.x) + 0.5, 0.0, float(cell.y) + 0.5)
	_st._grenade_models[cell] = root
	var pend: GameMaster.Pending = _st.gm.schedule_grenade(cell, caster_name, caster_side, delay)
	pend.model = root
	_st._log("  💣 手榴弹落地 (%d, %d)：%d 个回合后爆炸（%s 投出 ｜ 已与投出者解耦，他阵亡也照炸）" % [
		cell.x, cell.y, delay, caster_name])


## 爆炸：向 8 个方向各射出一枚破片（不分敌我，会伤到自己人）
## 用户口径第 87 轮：这一发**已经和投出者解耦** —— 投出者死了也照炸，
## 而且模型一定回收（按 Pending 上的引用收，不靠格子字典，同格两发不会互相顶掉）。
func explode_grenade(p: GameMaster.Pending) -> void:
	var cell: Vector2i = p.center
	var m: Node3D = p.model if (p.model != null and is_instance_valid(p.model)) else null
	if m == null and p.model == null:
		# 兜底：早期登记没有模型引用时，按格子回收
		var mm = _st._grenade_models.get(cell, null)
		if mm != null and is_instance_valid(mm):
			m = mm
	if m != null:
		m.queue_free()
		if _st._grenade_models.get(cell, null) == m:
			_st._grenade_models.erase(cell)
	var caster: Unit = null
	for u in _st.units:
		if u.name == p.caster_name:
			caster = u
	var d: Dictionary = Skills.get_def("grenade_launcher")
	var n: int = int(d.get("fragments", 8))
	var from := Vector3(float(cell.x) + 0.5, Ordnance.FRAGMENT_HEIGHT, float(cell.y) + 0.5)
	_st.fx.flash_sphere(Vector3(from.x, 0.55, from.z), 1.5, 0.38)      # 球状闪光（不要红圈）
	_st._log("  💥 手榴弹爆炸 (%d, %d)：向 %d 个方向撒出破片（模型已回收=%s）" % [
		cell.x, cell.y, n, "是" if m != null else "否"])
	# 用户口径第 89 轮：破片方向**随机**（和火箭落地一样每片现掷），不再均匀分角度
	for i in n:
		var ang: float = _st.rng.next_float() * TAU
		var dir := Vector2(cos(ang), sin(ang))
		var fp := Ordnance.make_fragment(caster, from, dir, false)
		fp.hit_self = true               # 用户口径：破片有友伤与自伤
		fp.shot.group = "grenade_frag"
		_st.field.register(fp)
