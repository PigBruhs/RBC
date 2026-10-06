# ══════════════════════════════════════════════════════════════════════════════
# 行动菜单状态机：二级行动菜单 / 普攻菜单 / 技能入口 / 沙盒道具详情
#
# 只负责"菜单怎么显示、点了哪个意图"；真正的执行交给各模块：
#   普攻 -> _st.attack.perform_basic / attack_target_unit
#   技能 -> _st.skills_mod.*（唯一入口 perform_skill）
# 宿主共享方法（_refresh_all / _place_menu_near / _compute_reachable / _log …）一律走 _st.xxx。
#
# 口径（不能破）：
#   · 第 89 轮：普攻也可能花精力 —— 按 AttackProfile.cost_of(active) 置灰并写明消耗；
#     _menu_attack 里另有一道兜底（防热键/脚本绕过）。
#   · 拒绝类文案（精力不足 / 不能休息）只进提示，不许写 _log —— 日志只记既定事实。
#
# 宿主是 battle_scene（Node3D）。_st 用动态类型（写 `: Node3D` 编译不过），同其它模块。
# ══════════════════════════════════════════════════════════════════════════════
class_name ActionMenu
extends RefCounted

var _st = null                 # 宿主（battle_scene）；动态类型见文件头


func _init(host: Node3D) -> void:
	_st = host

func show_action_menu() -> void:
	if _st.active == null:
		return                              # 没有当前行动者就没有菜单（以前会拿 null 去算可达格）
	_st._cell_targeting = false
	_st.cell_targets = {}
	if _st._ai_turn:
		return                              # AI 回合不弹菜单
	# 用户口径（第 103 轮）：被 AI 操控的单位也不许弹**行动菜单**。
	# 上面那道只拦住了「当前是不是 AI 回合」，漏了「我点的这个单位是不是 AI 在操控」——这里补后半句。
	# ⚠ 只拦弹菜单这一步：点单位看属性走 _select_for_detail / _refresh_all，不受影响。
	if _st._is_ai_unit(_st.active):
		return
	_st.phase = _st.Phase.MENU
	_st.reachable = _st._compute_reachable(_st.active)
	_st.attackable = {}
	_st.fx.draw_hints()
	_st._action_menu.visible = true
	_st._place_menu_near(_st.active)
	# 刚移动过就不允许休息（用户规则）；且已行动过就不能再动
	if _st._btn_rest_menu != null:
		var can_rest: bool = _st.active != null and not _st.active.has_moved and not _st.active.has_acted
		_st._btn_rest_menu.disabled = not can_rest
		_st._btn_rest_menu.tooltip_text = "" if can_rest else "本回合已经移动过，不能再休息"
	# 技能按钮：有技能的才亮，且精力不够时置灰并写明原因
	if _st._btn_skill != null:
		if _st.active == null:
			_st._btn_skill.disabled = true
		else:
			var ids := Skills.skills_for(_st.active)
			if ids.is_empty():
				_st._btn_skill.disabled = true
				_st._btn_skill.text = "技能（无）"
				_st._btn_skill.tooltip_text = ""
			else:
				var d := Skills.get_def(ids[0])
				_st._btn_skill.disabled = _st.active.energy_points() < int(d["cost"])
				_st._btn_skill.text = "%s（%d 精力）" % [d["name"], d["cost"]]
				_st._btn_skill.tooltip_text = "%s\n%s" % [d["name"], d["desc"]]
	# 普攻按钮（用户口径第 89 轮）：普攻也可能花精力（直升机 4 点）——
	# 精力不够就置灰，按钮上直接写清要几点，不许点进去才发现打不了。
	if _st._btn_attack != null:
		var b_cost: int = 0 if _st.active == null else AttackProfile.cost_of(_st.active)
		var b_ok: bool = _st.active != null and _st.active.energy_points() >= b_cost
		_st._btn_attack.disabled = not b_ok
		_st._btn_attack.text = "普攻" if b_cost <= 0 else "普攻（%d 精力）" % b_cost
		_st._btn_attack.tooltip_text = "" if b_ok else "精力 %d/%d 不够：普攻需要 %d 点" % [
			_st.active.energy_points() if _st.active != null else 0,
			_st.active.energy_max_points() if _st.active != null else 0, b_cost]
	_st._refresh_all()



func hide_action_menu() -> void:
	if _st.ui != null:
		_st.ui.hide_menus()




func menu_move() -> void:
	if _st.active == null:
		return
	_st._action_menu.visible = false
	_st._attack_menu.visible = false
	_st.phase = _st.Phase.MENU
	_st.selected = _st.active          # 必须有选中者，_draw_hints 才会画可移动格
	_st.reachable = _st._compute_reachable(_st.active)
	_st.attackable = {}
	_st._clear_pending()
	_st.fx.draw_hints()
	_st._refresh_all()



func menu_attack() -> void:
	if _st.active == null:
		return
	# 用户口径第 89 轮：精力不够时普攻按钮是灰的，这里再兜一道（防热键/脚本绕过）
	if _st.active.energy_points() < AttackProfile.cost_of(_st.active):
		return
	# 选了普攻/技能后**二级菜单立即消失**（用户强调）
	_st._action_menu.visible = false
	_st._clear_pending()          # 上一轮留下的黄勾不许残留
	# 关键：必须显式清掉技能 id。否则技能用过之后普攻会走技能分支
	# -> 不置 has_acted -> 一回合能打两次（用户报过的老 bug）。
	_st._aim_skill_id = ""
	_st._skill_info_text = ""
	# 走哪条瞄准流程由模板决定（AttackProfile.aim_of）：拖拽 / 点格子 / 点目标
	match AttackProfile.aim_of(_st.active):
		AttackProfile.AIM_DRAG:
			_st._begin_aim()
		AttackProfile.AIM_CELL:
			# 点格子类普攻（目前还没有角色用，留给以后"选一块地"的普攻模板）
			_st._cell_targeting = true
			_st.phase = _st.Phase.CHOOSE_TARGET
			_st.reachable = {}
			_st.attackable = {}
			_st.cell_targets = Targeting.disc_cells(_st._cc(_st.active.cell),
				float(_st.active.rng_max), _st.PW, _st.PH, _st.PX, _st.PY)
			_st.fx.clear_hints()
			_st.fx.draw_hints()
			_st._log("  🎯 选择【%s】落点：%d 格内共 %d 个可选格（粉色高亮）" % [
				AttackProfile.describe(_st.active), _st.active.rng_max, _st.cell_targets.size()])
			_st._refresh_all()
		_:
			_st.phase = _st.Phase.CHOOSE_TARGET
			_st.reachable = {}
			if AttackProfile.basic_of(_st.active) == AttackProfile.BASIC_LOCK:
				# ⚠ 第 111 轮修的恶性 bug（用户报「雷达车普攻无法选择目标」）：
				#   雷达的普攻是**锁定**，用户口径「**只有连接有距离限制，目标选择没有**」。
				#   但这里原来一律走 `attack_range_cells_rect` —— 而雷达数据行射程是 `0-0`
				#   （它没有武器）-> 可选集合**空** -> 一个目标都点不了。
				#   所以锁定模板改成"**全场敌人**都可选"。
				_st.attackable = {}
				_st._radar_all_enemy_cells(_st.attackable)
			else:
				# 只显示"当前位置能打到的格子"（紫色高亮）
				_st.attackable = Targeting.attack_range_cells_rect(_st.active, _st.PX, _st.PY, _st.PW, _st.PH)
				_st.attack.prune_air_cells()       # 近战：够不着的空中单位那格不亮（第 96 轮）
			# ── 难点 2 接入（第 111 轮）：被连接的友军可**无视距离**点选"被雷达锁定的目标" ──
			_st._radar_add_locked_targets(false, _st.active, _st.attackable)
			_st.fx.draw_hints()
			_st._refresh_all()



func menu_rest() -> void:
	if _st.active == null or _st.active.has_moved:
		if _st._ai_turn:
			_st._finish_turn()                   # AI 没有菜单可点，必须自己收尾，否则回合卡死
		return
	var before_p: int = _st.active.power_cur
	var before_a: int = _st.active.armor_cur
	var before_e: int = _st.active.energy
	_st.active.rest()
	# 雷达午餐盒（第 111 轮）：休息 -> **锁定进度重置**（用户口径之一）
	_st._radar_clear_lock(_st.active, "休息")
	# 关键：立刻把三池的变化推到表现层与详情栏，不要等下一回合
	push_unit_stats(_st.active)
	_st._log("%s 休息：力量 %s→%s  护甲 %s→%s  精力 %s→%s（回合结束）" % [
		_st.active.name, _st._fmt(before_p), _st._fmt(_st.active.power_cur),
		_st._fmt(before_a), _st._fmt(_st.active.armor_cur),
		_st._fmt(before_e), _st._fmt(_st.active.energy)])
	_st._finish_turn()




func show_attack_menu(t: Unit) -> void:
	_st._attack_target = t
	_st._action_menu.visible = false
	_st._attack_menu.visible = true

	# 力量线（用户口径：没有"用精力加伤害"了，预览就是纯力量对护甲）
	var pw: int = _st.active.power_cur
	var p: Rules.Preview = Rules.preview(pw, t.armor_cur, t.pr)
	var power_txt := ""
	match p.branch:
		Rules.Branch.NO_DAMAGE:
			power_txt = "打力量\n0（打不动）"
		Rules.Branch.ROLL:
			power_txt = "打力量\n1（%d%%概率）" % p.hit_percent
		Rules.Branch.AUTO:
			power_txt = "打力量\n%d" % p.damage

	# 破甲线：固定伤害 = 攻方破甲值，无视物抗，打护甲池
	var bd: int = _st.active.armor_break
	var break_txt := "破甲\n%s" % _st._fmt(bd)
	if t.armor_cur <= 0:
		break_txt = "破甲\n（护甲已空）"

	_st._btn_power.text = power_txt
	_st._btn_break.text = break_txt
	# 用户要求：即使"打不动"也**保留选择打力量的权力**（以后可能有上 buff 之类的设计），
	# 所以力量按钮永不置灰，只在文案上标出"打不动"。
	_st._btn_power.disabled = false
	_st._btn_break.disabled = (t.armor_cur <= 0)      # 对面没护甲时禁止破甲 —— 这条保留

	# 菜单贴着被点的敌人显示
	var sp: Vector2 = _st._camera.unproject_position(t.visual.global_position + Vector3(0, 0.5, 0))
	var vp: Vector2 = _st.get_viewport().get_visible_rect().size
	_st._attack_menu.position = Vector2(
		clampf(sp.x + 30.0, 8.0, vp.x - 350.0),
		clampf(sp.y - 50.0, 60.0, vp.y - 220.0))
	_st._refresh_all()



func confirm_attack(break_armor: bool) -> void:
	var t: Unit = _st._attack_target
	_st._attack_menu.visible = false
	_st._attack_target = null
	if t != null and t.is_alive():
		# 第 111 轮：把**待确认的点击格**传下去当瞄准点（大单位锚点 ≠ 点击格）
		_st.attack.attack_target_unit(t, break_armor, _st._pending_cell)



func push_unit_stats(u: Unit) -> void:
	if u != null and u.visual != null:
		u.visual.update_orb()
	_st._refresh_detail()




func show_placeable_info(p: Placeable) -> void:
	_st._placeable_info_text = placeable_info(p)
	_st._refresh_detail()




## 道具信息文字（UI 直接显示）
func placeable_info(p: Placeable) -> String:
	var txt := "[b][color=#9fe8ff]%s[/color][/b]（沙盒道具 · %dx%d）\n" % [p.name, p.w, p.h]
	txt += "位置 (%d, %d)\n" % [p.cell.x, p.cell.y]
	txt += "[b]力量[/b] %s / %s　　[b]护甲[/b] %s / %s\n" % [
		_st._fmt(p.power_cur), _st._fmt(p.power_max), _st._fmt(p.armor_cur), _st._fmt(p.armor_max)]
	txt += "物抗 %s　魔抗 %s\n" % [Unit.tier_name(p.pr), Unit.tier_name(p.mr)]
	txt += "阻挡移动：%s　　阻挡远程：%s\n" % [
		"是" if p.block_move else "否", "是" if p.block_ranged else "否"]
	txt += "[color=#ffd866]说明：[/color]"
	if p.name == "木刺":
		txt += "尖桩拒马，挡住地面单位；但箭矢可以从上方越过，不阻挡远程。"
	elif Loiter.is_launcher(p):
		txt += "巡飞弹发射器：判定范围 %d 格，只打**进入范围的正在移动的敌方角色**，" % int(Loiter.LAUNCH_RANGE)
		txt += "每 %d 个回合边界发射一枚；发射方向 = 目标方向 ±%d° 内随机。" % [
			Loiter.LAUNCH_COOLDOWN_TURNS, int(Loiter.CONE_DEG)]
		txt += "巡飞弹可以被玩家用 Q/E 制导（左/右转弯），近炸引信 + 飞满 %d 格自动引爆。" % int(Loiter.MAX_DIST)
	else:
		txt += "土堆够高，能挡住箭矢；但投掷手的抛物线攻击不受影响。"
	return txt




func ui_open_skill_menu(ids: Array[String]) -> void:
	if _st.ui != null:
		_st.ui.show_skill_menu(ids, _st.active)
