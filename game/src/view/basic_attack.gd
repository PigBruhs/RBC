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
	# ⚠ 第 109 轮修的 bug（用户报「0 精力选择完目标后普攻不会释放」）：
	#   这里原来读的是**模板里的原始 cost**（`int(prof["cost"])`），**绕过了按名覆盖**
	#   `AttackProfile.cost_of(u)` —— 午餐盒与直升机共用 `BASIC_SALVO`（模板 cost=4），
	#   于是车即使被覆盖成 0，这里仍按"4 精力"判定 → **0 精力时普攻被静默拒绝**。
	#   一律走 `cost_of(u)`：它是"这一次普攻扣多少"的唯一来源。
	var cost := AttackProfile.cost_of(u)
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
			# ⚠ 第 111 轮用户口径：**当目标"被雷达锁定、且自己是那台雷达的连接友军"时，
			#   换用【锁定齐射】模板**（无视射程 / 不甩头 / 只连发 3 波 / 散布 0.5）。
			#   用户原话：「你需要确保 1. **无视射程限制**（子弹飞不到无所谓，但一定要打出去）
			#   2. **不再甩头单纯对准目标连发 3 波**」
			if target != null and _st._radar_may_target(u, target):
				return basic_salvo_locked(u, aim, target)
			return basic_salvo(u, aim)
		AttackProfile.BASIC_LOCK:
			# 第 111 轮：雷达午餐盒的普攻 = **纯锁定**（无伤害、无距离限制）。
			# 用户口径：「选定一个敌对角色开始锁定，没有距离限制」。
			# 这里只登记锁定并推进一次进度（"选定当回合算第 1 回合"——见 `probe_radar.gd`）。
			if target == null:
				return false
			# 第 111 轮：`_radar_begin_lock` 改成收 **Unit**（内部取唯一编号当锁定标识）
			_st._radar_begin_lock(u, target)
			return true
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


## 齐射（BASIC_SALVO）：
##   · 直升机 = 吊射火箭（左右开弓，8 波 × 2 发）
##   · 轮式齐射午餐盒（第 104 轮）= 12 波 × 6 发子弹（方向机 ±10° 摇动 + 每波重算俯仰）
## 两者都"发射完即结束回合"，收尾各自在自己的协程里做。
func basic_salvo(u: Unit, aim: Vector2) -> bool:
	if Unit.base_name(u.name) == AttackProfile.LUNCHBOX_NAME:
		_st._lunchbox_salvo(u, aim)
		return true
	_st._rocket_salvo(u, aim)
	return true


## 【锁定齐射】—— 第 111 轮新模板（用户口径）
## 「当检测到选择目标**被雷达锁定且自己连接到雷达**时，**无视射程限制**
##   （子弹飞不到无所谓，但一定要打出去）并用**新普攻模板**覆盖原本的甩头模板；
##   新普攻模板：20 格处散布 0.5 格，**不甩头**但是**只连发 3 波**」
func basic_salvo_locked(u: Unit, aim: Vector2, t: Unit) -> bool:
	_st._lunchbox_salvo_locked(u, aim, t)
	return true


## 连发实现。间隔依次出膛，**每发各自判定命中**，
## 落点吃"玩家侧线性散布"（r = 距离/12，12 格 ≈ 1 格）——所以选中目标也不一定打中。
## ⚠ 第 106 轮用户口径：「**我需要立体球状散布**」——
##   连发也是**子弹**，所以散布与午餐盒齐射同为**立体球**（不是水平圆盘）：
##   瞄准点带 y 偏移 → 弹道带俯仰 → 远处会从头顶飞过、或者打进地里。
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
	var base_y: float = fly_y if fly_y >= 0.0 else from.y
	for i in count:
		# 雷达接入（第 111 轮）：被连接的友军散布受修正（锁前 ×0.5 / 锁后固定小半径）
		var a := Spread.linear_scatter(ctr, dist, _st.rng, _st.radar_spread_mult(u, dist))
		var last := i == count - 1
		# ⚠ 第 107 轮用户口径（解耦两种子弹的散布）：
		#   「萨尼的子弹按**圆盘**、车按**球**」—— 上一轮我给她也加了竖直偏移（球），
		#   结果她会打出向下的俯仰、**子弹穿越地图下方**。这里已经把 `vy` 删干净：
		#   萨尼回到**水平圆盘**（`Spread.linear_scatter`）+ **水平弹道**（`make_bullet`，y0 == y1）。
		#   立体球那条路只留给车（`Ordnance.make_cart_bullet_at`）。
		var r := Spread.linear_radius(dist)
		var p := Ordnance.make_bullet(u, from, a, last, base_y)
		p.shot.target = t
		p.shot.break_armor = break_armor
		if pl != null and pl.is_alive():
			p.shot.target_placeable = pl           # 锁定沙盒：子弹也一定打得中它
		_st.field.register(p)
		_st._log("  • %s 第 %d/%d 发子弹：目标 %s（%.1f 格，散布半径 %.2f）→ 瞄准 (%.2f, %.2f，高度 %.2f）" % [
			u.name, i + 1, count, t.name if t != null else pl.name if pl != null else "落点",
			dist, r, a.x, a.y, base_y])
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
	if t.side == _st.active.side:
		return false
	# ⚠ 第 111 轮：雷达的**锁定**没有距离限制（用户口径「只有连接有距离限制，目标选择没有」），
	#   而它的数据行射程是 `0-0`（没有武器）-> `in_range_of` 必然为假。
	#   所以锁定模板**跳过射程判定**；其余模板照旧。
	if AttackProfile.basic_of(_st.active) == AttackProfile.BASIC_LOCK:
		return true
	# ⚠ 第 111 轮用户口径：**目标被雷达锁定、且自己是那台雷达的连接友军时，无视射程限制**
	#   （`probe_cart_attack` / 用户实测："点第一下没反应" 就是被下面这句 `in_range_of` 拦掉的）。
	if _st._radar_may_target(_st.active, t):
		return true
	return _st.active.in_range_of(t.cell) and Targeting.melee_reaches(_st.active, t)


## 这个单位的普攻是否**跳过"打力量 / 破甲"三级菜单**（第二次点直接开打）。
## 用户口径（第 107 轮）：午餐盒的普攻是**齐射**，没有这个二选一 ——
## 它的 `armor_break = 0`，菜单里"破甲"那条对它是死的（实测点下去毫无反应），
## 而"打力量"虽然能出膛，却白让玩家多点一步。
## 第 111 轮：雷达的**锁定**同理（更彻底 —— 它没有任何伤害，两个选项都没有意义）。
## ⚠ 只对**齐射类 / 锁定类**生效：弓箭/近战/连发仍然保留三级菜单（那是它们真实的选择）。
func attack_skips_power_menu(u: Unit) -> bool:
	if u == null:
		return false
	var b := AttackProfile.basic_of(u)
	return b == AttackProfile.BASIC_SALVO or b == AttackProfile.BASIC_LOCK


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
func attack_target_unit(t: Unit, break_armor: bool, aim_cell: Vector2i = Vector2i(-1, -1)) -> void:
	if _st.active == null or t == null or not t.is_alive():
		return
	if _st.active.has_acted:
		return
	# ⚠ 第 111 轮用户口径：「为什么雷达锁定 Reaper 后齐射车瞄准的总是 Reaper 标定的格子
	#   （瞄准时紫色的那个）**左斜边一格**？……你看能不能改到**选目标时瞄准的那一格**上」
	#   原因：这里原来一律用 `t.cell`（**单位自己的锚点格**）。对 **Reaper 这种多格大单位**，
	#   锚点格 ≠ 玩家点的那一格 -> 瞄准点整体偏一格（观感"没打在我点的地方"）。
	#   现在：调用方把**点击的格**传进来，就以它为准；没传则退回单位锚点（行为不变）。
	var ac: Vector2i = aim_cell if aim_cell.x >= 0 and aim_cell.y >= 0 else t.cell
	if not perform_basic(_st.active, GridMath.cell_center(ac), t, null, break_armor):
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
