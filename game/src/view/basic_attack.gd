# ══════════════════════════════════════════════════════════════════════════════
# 普攻唯一入口 + 三条路径的分派实现（第 82 轮口径的代码归宿）。
#
#   拖拽松手 _fire()               ─┐
#   点目标   _attack_target_unit() ─┼─ 都只负责"算出打哪里" -> perform_basic()
#   AI 出手  _ai_attack()          ─┘
#
# 普攻长什么样来自 core/attack_profile.gd（近战 / 弓箭 / 连发 / 投掷 / 火箭齐射），
# 所以"加一个角色"只需要在表里加一行，三条入口自动同步 —— 不再出现
# "拖拽那条接上了、点目标那条还在打普通炮弹"这类事故。
#
# 形态：RefCounted + 构造注入宿主（battle_scene），模块内一律用 _st.xxx 显式访问共享状态。
# 行为零变化：函数体从 battle_scene.gd 原样搬来，只做两种改写：
#   _xxx  ->  _st._xxx   （宿主成员/方法：active / attackable / field / rng / _log / _finish_turn …）
#   _xxx  ->  _xxx       （本模块成员；前导下划线去掉）
# 纯函数直接走全局类：GridMath.cell_center / Targeting.* / Spread.* / Ordnance.* / Damage.* /
# AttackProfile.*（原来就是静态调用，没有"宿主状态"这层）。
#
# 宿主保留同名薄包装，所以 playtest / probe 的 _s._perform_basic(...) 等直读直调照旧。
# ══════════════════════════════════════════════════════════════════════════════
class_name BasicAttack
extends RefCounted

## 宿主 BattleScene。**故意不加静态类型**：宿主没有 class_name，若静态写成 Node3D，
## _st.active / _st.attackable / _st.field 全部会在分析期报 Cannot find member
## （同 BattleUI.host、SentryRunner._st、ViewFx._st 的处理）。
var _st = null


func _init(host: Node3D) -> void:
	_st = host


# ══════════════════════════════════════════════════════════════════════════════
# 【唯一】普攻入口
# ══════════════════════════════════════════════════════════════════════════════

## 【唯一】普攻入口。返回 false = 这一击没打出去（精力不够 / 目标非法）。
##   aim         : 落点（浮点格坐标）。近战/锁敌时传目标中心即可
##   target      : 锁定的角色（可空）
##   placeable   : 锁定的沙盒道具（可空）
##   guard_acted : true = 本回合已出手就拒绝（玩家路径，防"一回合打两次"）
##
## 三段顺序是红线（第 82 轮，规格 §14.2），不许合并/调换：
##   ① 先查精力（不够就什么都不做、不占行动，也不写日志）
##      ①' 第 96 轮追加的近战拒绝：够不着空中单位时同样在扣费**之前**拒绝
##   ② 再统一置"已行动"、扣精力、刷新属性栏
##   ③ 最后按 prof["basic"] 分派到实现函数
func perform_basic(u: Unit, aim: Vector2, target: Unit = null, placeable: Placeable = null,
		break_armor: bool = false, guard_acted: bool = false) -> bool:
	if u == null or not u.is_alive():
		return false
	if guard_acted and u.has_acted:
		return false
	var prof := AttackProfile.for_unit(u)
	var cost := int(prof["cost"])
	# 精力不足：**什么都不做**（不置已行动、不结束回合），由调用方决定怎么收尾。
	# 拒绝类文案不写日志（用户口径：日志只记既定事实，提示只留在状态栏/菜单）。
	if u.energy_points() < cost:
		return false
	# 近战够不着空中的单位（用户口径第 96 轮：近战攻击不能瞄准直升机）——
	# 和"精力不足"同一档的**拒绝**：不置已行动、不扣精力，由调用方收尾。
	if String(prof["basic"]) == AttackProfile.BASIC_MELEE and target != null \
			and not Targeting.melee_reaches(u, target):
		return false
	u.has_acted = true
	u.has_moved = true
	if cost > 0:
		u.spend_energy(cost)
	_st._push_unit_stats(u)          # 同步精力条与属性栏
	match String(prof["basic"]):
		AttackProfile.BASIC_MELEE:
			return basic_melee(u, target, placeable, break_armor)
		AttackProfile.BASIC_ARROW:
			return basic_arrow(u, aim, target, placeable, break_armor)
		AttackProfile.BASIC_BURST:
			return basic_burst(u, aim, target, placeable, break_armor, prof)
		AttackProfile.BASIC_SHELL:
			return basic_shell(u, aim)
		AttackProfile.BASIC_SALVO:
			return basic_salvo(u, aim)
	push_error("未知普攻模板：%s（%s）" % [prof["basic"], u.name])
	return false


# ══════════════════════════════════════════════════════════════════════════════
# 五种普攻模板的实现（分派目标）
# ══════════════════════════════════════════════════════════════════════════════

## 近战：贴上去直接结算（打角色走 Damage.strike，打沙盒走道具那条）
func basic_melee(u: Unit, t: Unit, pl: Placeable, ba: bool) -> bool:
	if t != null and t.is_alive():
		apply_attack(u, t, ba, false)          # 内部会结束回合
		return true
	if pl != null and pl.is_alive():
		damage_placeable(u, pl, false)
		return true
	_st._finish_turn()
	return false


## 弓箭：恒定速度抛物线，命中靠碰撞判定（可能打空）。
## 高度轴（第 83 轮）：瞄角色就瞄【身体中心】—— 悬停 2 格的直升机要瞄 2.5 高，
## 否则箭从它下面穿过去（以前判定不看高度，看着就像穿模）。
func basic_arrow(u: Unit, aim: Vector2, t: Unit, pl: Placeable, ba: bool) -> bool:
	var from := Vector3(float(u.cell.x) + 0.5, 0.75, float(u.cell.y) + 0.5)
	var to := Vector3(aim.x, 0.55, aim.y)
	if t != null and t.is_alive():
		to = Vector3(float(t.cell.x) + 0.5, Targeting.aim_height(t), float(t.cell.y) + 0.5)
	elif pl != null and pl.is_alive():
		to = Vector3(float(pl.cell.x) + 0.5, 0.55, float(pl.cell.y) + 0.5)
	var p: Projectile = _st._spawn_arrow(u, from, to, t, ba, true)
	if pl != null and p != null and p.shot != null:
		p.shot.target_placeable = pl            # 明确锁定：箭一定打得中它
	return true


## 连发（萨尼铁塔）：发数 / 间隔 / 散布全来自模板。
## 注意：连发是协程（要等间隔出膛），这里不能 await 它的返回值，直接放走即可。
func basic_burst(u: Unit, aim: Vector2, t: Unit, pl: Placeable, ba: bool, prof: Dictionary) -> bool:
	volley_bullets(u, aim, t, pl, ba, prof)
	return true


## 投掷炮弹：落点吃拖拽结果，**出界也照打**（用户口径：投掷手一定要允许失误）
func basic_shell(u: Unit, aim: Vector2) -> bool:
	var from := GridMath.cell_center(u.cell)
	var d := from.distance_to(aim)
	var cell := Vector2i(int(floor(aim.x)), int(floor(aim.y)))
	_st._log("  %s 投掷，落点 (%d, %d)，距离 %.1f 格，飞行 %.2f 秒" % [
		u.name, cell.x, cell.y, d, d / Ordnance.SHELL_TILES_PER_SEC])
	_st._spawn_shell(u, aim, true)
	return true


## 火箭齐射（直升机）：耗精力、左右开弓、发射完即结束回合，全部在 _rocket_salvo 里
func basic_salvo(u: Unit, aim: Vector2) -> bool:
	_st._rocket_salvo(u, aim)
	return true


## 连发实现。间隔依次出膛，**每发各自判定命中**，
## 落点吃"玩家侧线性散布"（r = 距离/12，12 格 ≈ 1 格）——所以选中目标也不一定打中。
func volley_bullets(u: Unit, aim: Vector2, t: Unit, pl: Placeable,
		break_armor: bool, prof: Dictionary) -> bool:
	var count := int(prof.get("shots", 3))
	var gap := float(prof.get("gap", 0.1))
	var ctr := aim
	if t != null and t.is_alive():
		ctr = GridMath.cell_center(t.cell)
	elif pl != null and pl.is_alive():
		ctr = GridMath.cell_center(pl.cell)
	var from := Vector3(float(u.cell.x) + 0.5, 0.75, float(u.cell.y) + 0.5)
	var dist := GridMath.cell_center(u.cell).distance_to(ctr)
	# 高度轴（第 83 轮）：打悬空单位要把弹道抬到它的身体中心
	var fly_y: float = Targeting.aim_height(t) if t != null and t.is_alive() else -1.0
	for i in count:
		var a := Spread.linear_scatter(ctr, dist, _st.rng)
		var last := i == count - 1
		var p := Ordnance.make_bullet(u, from, a, last, fly_y)
		p.shot.target = t
		p.shot.break_armor = break_armor
		if pl != null and pl.is_alive():
			p.shot.target_placeable = pl           # 锁定沙盒：子弹也一定打得中它
		_st.field.register(p)
		_st._log("  • %s 第 %d/%d 发子弹：目标 %s（%.1f 格，散布半径 %.2f）→ 瞄准 (%.2f, %.2f）" % [
			u.name, i + 1, count, t.name if t != null else pl.name if pl != null else "落点",
			dist, Spread.linear_radius(dist), a.x, a.y])
		if not last:
			await _st.get_tree().create_timer(gap).timeout
	return true


# ══════════════════════════════════════════════════════════════════════════════
# 三条入口里的两条（玩家点目标）+ AI 共用的目标闸门 / 高亮修剪
# ══════════════════════════════════════════════════════════════════════════════

## 点目标前的最后一道闸（口径与 perform_basic 里的拒绝完全一致）：
## 近战够不着空中的单位 —— 第 96 轮用户口径「近战攻击不应该能瞄准直升机」。
func can_aim_unit(t: Unit) -> bool:
	if _st.active == null or t == null:
		return false
	return t.side != _st.active.side and _st.active.in_range_of(t.cell) \
		and Targeting.melee_reaches(_st.active, t)


## 近战的高亮格：空中单位（够不着）那一格不点亮。
## 例外：那格上还站着可打的沙盒道具时保留（同一格里道具照样能砍）。
func prune_air_cells() -> void:
	if _st.active == null or _st.active.role != UnitData.Role.MELEE:
		return
	for c in _st.attackable.keys():
		var o: Unit = _st._unit_at(c)
		if o != null and o.side != _st.active.side and not Targeting.melee_reaches(_st.active, o) \
				and _st._placeable_at(c) == null:
			_st.attackable.erase(c)


## 点目标路径（玩家）：唯一差别是"已经出手过就不再响应"。
## 打不出（精力不足）时把行动菜单还给他，别把回合卡住。
func attack_target_unit(t: Unit, break_armor: bool) -> void:
	if _st.active == null or t == null or not t.is_alive():
		return
	if _st.active.has_acted:
		return
	if not perform_basic(_st.active, GridMath.cell_center(t.cell), t, null, break_armor):
		_st._show_action_menu()


## 锁定沙盒元素（用户口径：双方英雄都能打木刺/土堆）
func attack_target_placeable(pl: Placeable) -> void:
	if _st.active == null or pl == null or not pl.is_alive():
		return
	if _st.active.has_acted:
		return
	_st._log("%s 锁定沙盒：%s" % [_st.active.name, pl.name])
	if not perform_basic(_st.active, GridMath.cell_center(pl.cell), null, pl, false):
		_st._show_action_menu()


# ══════════════════════════════════════════════════════════════════════════════
# 结算（打角色 / 打沙盒）—— 弹道那边也复用这两个，所以宿主保留同名薄包装
# ══════════════════════════════════════════════════════════════════════════════

func apply_attack(attacker: Unit, t: Unit, break_armor: bool,
		silent: bool = false, bonus_milli: int = 0, power_mult: float = 1.0,
		power_override: int = -1, break_override: int = -1,
		fixed_power: bool = false) -> void:
	var h: Damage.Hit = Damage.strike(attacker, t, break_armor, _st.rng, bonus_milli, power_mult,
		power_override, break_override, fixed_power)
	if h == null:
		return
	_st._log(h.text)
	_st._after_damage_to_unit(t)
	if not silent:
		_st._finish_turn()


## 箭矢"身体"判定半径等常量见 Targeting / Ordnance

func placeable_near(pos: Vector3) -> Placeable:
	var c := Vector2i(int(floor(pos.x)), int(floor(pos.z)))
	for p in _st.placeables:
		if p.is_alive() and p.covers(c):
			return p
	return null


## 对沙盒道具结算一次普通伤害（力量线），实际计算在 Damage 里
func damage_placeable(attacker: Unit, p: Placeable, silent: bool = false) -> void:
	var h: Damage.Hit = Damage.prop_strike(attacker, p, _st.rng)
	if h == null:
		return
	_st._log(h.text)
	if h.died:
		_st._log("  🧱 %s 被摧毁" % p.name)
	_st._after_damage_to_placeable(p)
	if not silent:
		_st._finish_turn()          # 撞到道具也算用掉了这次行动（哨兵箭 silent）
