# ══════════════════════════════════════════════════════════════════════════════
# 战场 UI（重写版）
#
# 设计原则：UI 不碰游戏规则，只做两件事 ——
#   ① 读宿主状态（host.xxx）并把界面画出来
#   ② 用户操作时调宿主意图（host.ui_xxx()）
# 所以这个文件可以整体替换、单独调试，不影响回合机与伤害结算。
#
# 宿主（battle_scene）需要提供：
#   只读： units placeables queue active selected round_no phase energy_spend
#          hint_text skill_info place_left place_kind is_placing
#   意图： ui_click_unit / ui_click_blank / ui_move / ui_attack / ui_skill / ui_rest
#          ui_end_turn / ui_finish_placement / ui_pick_place
#          ui_set_zoom / ui_pick_skill / ui_confirm_attack / ui_upgrade
#          ui_reset_upgrades / ui_camera / ui_collect_log
# ══════════════════════════════════════════════════════════════════════════════
class_name BattleUI
extends RefCounted

const QUEUE_SHOWN := 10
const QUEUE_ICON := 34.0
const QUEUE_LINE := 14.0
const QUEUE_SLOT := QUEUE_ICON + QUEUE_LINE
const QUEUE_ANIM_SEC := 0.5
const ICON_PX := 84.0

var host = null                      # 动态类型：宿主提供 ui_xxx 接口（静态类型会编译报错）

# ── 根节点 ──
var layer: CanvasLayer = null
var bottom: PanelContainer = null
var topbar: PanelContainer = null
var zoom_slider: HSlider = null
var queue_label: Label = null
var hint_label: Label = null
var status: Label = null
var detail: RichTextLabel = null
var panel: PanelContainer = null
var upgrade_box: HFlowContainer = null
var sandbox_box: VBoxContainer = null
var place_buttons: Dictionary = {}

# ── 菜单 ──
var action_menu: PanelContainer = null
var attack_menu: PanelContainer = null
var skill_menu: PanelContainer = null
var btn_rest: Button = null
var btn_skill: Button = null
var btn_power: Button = null
var btn_break: Button = null
var btn_next: Button = null

# ── 队列条 ──
var queue_strip: Control = null
var queue_bar: PanelContainer = null
var queue_slots: Array = []                 # [{unit, btn, line}]
var queue_anim_lock: float = 0.0
var queue_need_refresh: bool = false

# ── 胜者界面 ──
var result_box: PanelContainer = null
var result_label: Label = null
var result_sub: Label = null

# ── 菜单跟随的角色 ──
var menu_anchor: Unit = null


# ══════════════════════════════════════════════════════════════════════════════
# 构建
# ══════════════════════════════════════════════════════════════════════════════
func build(p_host) -> void:
	host = p_host
	layer = CanvasLayer.new()
	host.add_child(layer)
	_build_topbar()
	_build_next_button()
	_build_action_menu()
	_build_attack_menu()
	_build_skill_menu()
	_build_bottom()
	_build_result()
	_build_debug()


func _menu_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.10, 0.14, 0.97)
	sb.border_color = Color(0.45, 0.50, 0.60, 1.0)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(10)
	return sb


func _panel_node() -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _menu_style())
	return p


## 顶部信息条：回合数 / 当前行动者 / 精力投入 / 缩放
func _build_topbar() -> void:
	topbar = _panel_node()
	topbar.position = Vector2(12, 10)
	topbar.custom_minimum_size = Vector2(760, 0)
	layer.add_child(topbar)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	topbar.add_child(hb)

	queue_label = Label.new()
	queue_label.text = "队列"
	hb.add_child(queue_label)
	hb.add_child(VSeparator.new())

	# 用户口径：删掉"精力 0/1/2/3 投注加伤害"，精力现在只用来付技能费
	var el := Label.new(); el.text = "精力只用于技能"; hb.add_child(el)
	hb.add_child(VSeparator.new())

	var zl := Label.new(); zl.text = "缩放:"; hb.add_child(zl)
	zoom_slider = HSlider.new()
	zoom_slider.min_value = 6.0            # 与鼠标滚轮的夹取范围保持一致
	zoom_slider.max_value = 30.0
	zoom_slider.step = 0.5
	zoom_slider.value = 15.0
	zoom_slider.custom_minimum_size = Vector2(180, 0)
	zoom_slider.value_changed.connect(func(v: float) -> void: host.ui_set_zoom(v))
	hb.add_child(zoom_slider)


## 右下角 >> ：放置阶段 = 结束放置；战斗中 = 结束回合
func _build_next_button() -> void:
	btn_next = Button.new()
	btn_next.text = ">>"
	btn_next.anchor_left = 1.0; btn_next.anchor_right = 1.0
	btn_next.anchor_top = 1.0; btn_next.anchor_bottom = 1.0
	btn_next.offset_left = -166; btn_next.offset_right = -12
	btn_next.offset_top = -72; btn_next.offset_bottom = -10
	btn_next.add_theme_font_size_override("font_size", 26)
	btn_next.pressed.connect(func() -> void: host.ui_end_turn())
	layer.add_child(btn_next)


## 二级菜单：移动 / 普攻 / 技能 / 休息
func _build_action_menu() -> void:
	action_menu = _panel_node()
	action_menu.visible = false
	layer.add_child(action_menu)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	action_menu.add_child(vb)
	var t := Label.new(); t.text = "行动"; vb.add_child(t)

	var b_move := Button.new(); b_move.text = "移动"
	b_move.pressed.connect(func() -> void: host.ui_move())
	vb.add_child(b_move)
	var b_atk := Button.new(); b_atk.text = "普攻"
	b_atk.pressed.connect(func() -> void: host.ui_attack())
	vb.add_child(b_atk)
	btn_skill = Button.new(); btn_skill.text = "技能"
	btn_skill.pressed.connect(func() -> void: host.ui_skill())
	vb.add_child(btn_skill)
	btn_rest = Button.new(); btn_rest.text = "休息"
	btn_rest.pressed.connect(func() -> void: host.ui_rest())
	vb.add_child(btn_rest)


## 攻击菜单：左蓝破甲 / 右红打力量，伤害直接写在按钮上
func _build_attack_menu() -> void:
	attack_menu = _panel_node()
	attack_menu.visible = false
	layer.add_child(attack_menu)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	attack_menu.add_child(vb)
	var t := Label.new(); t.text = "选择攻击方式"; vb.add_child(t)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	vb.add_child(hb)
	btn_break = Button.new()
	btn_break.custom_minimum_size = Vector2(150, 52)
	btn_break.add_theme_color_override("font_color", Color(0.62, 0.80, 1.0))
	btn_break.pressed.connect(func() -> void: host.ui_confirm_attack(true))
	hb.add_child(btn_break)
	btn_power = Button.new()
	btn_power.custom_minimum_size = Vector2(150, 52)
	btn_power.add_theme_color_override("font_color", Color(1.0, 0.58, 0.55))
	btn_power.pressed.connect(func() -> void: host.ui_confirm_attack(false))
	hb.add_child(btn_power)
	var c := Button.new(); c.text = "取消（Esc）"
	c.pressed.connect(func() -> void: host.ui_cancel())
	vb.add_child(c)


## 技能菜单（多技能单位才弹）
func _build_skill_menu() -> void:
	skill_menu = _panel_node()
	skill_menu.visible = false
	layer.add_child(skill_menu)


## 底边栏：队列条 + 沙盒放置区 + 状态文本 + 详情/加点
func _build_bottom() -> void:
	# ── ① 属性栏（左下角那一大块）：用户口径 —— 缩到原来的 2/3，点空白处隐藏 ──
	bottom = _panel_node()
	bottom.anchor_top = 1.0; bottom.anchor_bottom = 1.0
	bottom.anchor_left = 0.0; bottom.anchor_right = 2.0 / 3.0 * 2.0 / 3.0   # 宽 = 原来的 2/3
	bottom.offset_left = 8; bottom.offset_right = -8
	bottom.offset_top = -232          # 只剩"单位详情/加点"（提示行按用户要求删了）
	bottom.offset_bottom = -56
	# 用户口径：左下角所有文本框全部清掉，只保留队列可视化 —— 属性栏不再入树
	# （节点照旧搭好，只是不 add_child，所以任何 ui_ 调用都不会崩）
	# layer.add_child(bottom)

	var root_vb := VBoxContainer.new()
	root_vb.add_theme_constant_override("separation", 6)
	bottom.add_child(root_vb)

	# 状态文本 + 详情/加点
	var lower := HBoxContainer.new()
	lower.add_theme_constant_override("separation", 10)
	lower.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_vb.add_child(lower)

	var left_vb := VBoxContainer.new()
	left_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lower.add_child(left_vb)
	# 用户口径：这两行提示没用，删掉（变量保留，老赋值点不会崩，只是不显示）
	status = Label.new()
	hint_label = Label.new()

	panel = _panel_node()
	panel.size_flags_vertical = Control.SIZE_SHRINK_END
	panel.size_flags_horizontal = Control.SIZE_SHRINK_END
	panel.custom_minimum_size = Vector2(300, 0)
	panel.visible = false
	lower.add_child(panel)
	var pv := VBoxContainer.new()
	pv.add_theme_constant_override("separation", 3)
	panel.add_child(pv)
	var pt := Label.new(); pt.text = "单位详情 / 加点"; pt.add_theme_font_size_override("font_size", 12)
	pv.add_child(pt)
	detail = RichTextLabel.new()
	detail.bbcode_enabled = true
	detail.fit_content = true
	detail.scroll_active = false
	detail.add_theme_font_size_override("font_size", 11)
	detail.add_theme_font_size_override("normal_font_size", 11)
	detail.add_theme_font_size_override("bold_font_size", 11)
	detail.custom_minimum_size = Vector2(213, 0)
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pv.add_child(detail)
	upgrade_box = HFlowContainer.new()
	upgrade_box.add_theme_constant_override("h_separation", 5)
	upgrade_box.add_theme_constant_override("v_separation", 3)
	upgrade_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pv.add_child(upgrade_box)

	# ── ② 常驻细条（最底下）：沙盒 + 队列可视化，永远看得见 ──
	queue_bar = _panel_node()
	queue_bar.anchor_top = 1.0; queue_bar.anchor_bottom = 1.0
	queue_bar.anchor_left = 0.0; queue_bar.anchor_right = 0.0   # 动态宽度：跟着内容缩
	queue_bar.offset_left = 8; queue_bar.offset_right = 0
	queue_bar.offset_top = -64; queue_bar.offset_bottom = -6
	layer.add_child(queue_bar)
	var qh := HBoxContainer.new()
	qh.add_theme_constant_override("separation", 16)
	queue_bar.add_child(qh)
	sandbox_box = VBoxContainer.new()
	sandbox_box.add_theme_constant_override("separation", 3)
	sandbox_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	qh.add_child(sandbox_box)
	queue_strip = Control.new()
	queue_strip.custom_minimum_size = Vector2(QUEUE_SLOT * QUEUE_SHOWN, QUEUE_ICON + 12.0)
	queue_strip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	queue_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	qh.add_child(queue_strip)


## 胜者界面
func _build_result() -> void:
	result_box = _panel_node()
	result_box.visible = false
	result_box.anchor_left = 0.5; result_box.anchor_right = 0.5
	result_box.anchor_top = 0.5; result_box.anchor_bottom = 0.5
	result_box.offset_left = -180; result_box.offset_right = 180
	result_box.offset_top = -110; result_box.offset_bottom = 110
	layer.add_child(result_box)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	result_box.add_child(vb)
	result_label = Label.new()
	result_label.text = ""
	result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	result_label.add_theme_font_size_override("font_size", 46)
	vb.add_child(result_label)
	result_sub = Label.new()
	result_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	result_sub.add_theme_font_size_override("font_size", 17)
	vb.add_child(result_sub)
	var b := Button.new(); b.text = "继续"
	b.custom_minimum_size = Vector2(0, 52)
	b.add_theme_font_size_override("font_size", 22)
	b.pressed.connect(func() -> void: host.ui_restart())
	vb.add_child(b)


# ══════════════════════════════════════════════════════════════════════════════
# 队列条（首结点淡出 + 其余左移 + 队尾补位，0.5 秒，带最小间隔）
# ══════════════════════════════════════════════════════════════════════════════
func _queue_tip(u: Unit, is_now: bool) -> String:
	var t := "%s（%s）" % [u.name, host.ui_faction_cn(u)]
	if is_now:
		t += " — 正在行动"
	return t


func _make_slot(u: Unit, index: int, is_now: bool) -> Dictionary:
	var x := float(index) * QUEUE_SLOT
	var btn := TextureButton.new()
	btn.texture_normal = Icons.make(u.role, u.side, u.name.begins_with("Dummy"), is_now, not u.is_alive())
	btn.ignore_texture_size = true
	btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	btn.size = Vector2(QUEUE_ICON, QUEUE_ICON)
	btn.position = Vector2(x + QUEUE_LINE, 6.0)
	btn.pivot_offset = Vector2(QUEUE_ICON * 0.5, QUEUE_ICON * 0.5)
	btn.pressed.connect(func() -> void: host.ui_click_unit(u, true))
	btn.tooltip_text = _queue_tip(u, is_now)
	queue_strip.add_child(btn)
	if index <= 0:
		return {"unit": u, "btn": btn, "line": null}
	var ln := ColorRect.new()
	ln.color = Color(0.55, 0.58, 0.65, 0.9)
	ln.size = Vector2(QUEUE_LINE, 3)
	ln.position = Vector2(x, 6.0 + QUEUE_ICON * 0.5 - 1.5)
	ln.mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_strip.add_child(ln)
	return {"unit": u, "btn": btn, "line": ln}


func _slot_units() -> Array[Unit]:
	var out: Array[Unit] = []
	for s in queue_slots:
		out.append(s["unit"])
	return out


func _clear_slots() -> void:
	for c in queue_strip.get_children():
		queue_strip.remove_child(c)
		c.queue_free()
	queue_slots.clear()


func _rebuild_slots(seq: Array[Unit]) -> void:
	_clear_slots()
	for i in seq.size():
		queue_slots.append(_make_slot(seq[i], i, i == 0))


func _apply_slot_textures(seq: Array[Unit]) -> void:
	for i in mini(queue_slots.size(), seq.size()):
		var s: Dictionary = queue_slots[i]
		var u: Unit = s["unit"]
		var b: TextureButton = s["btn"]
		if not is_instance_valid(b):
			continue
		var is_now := i == 0
		b.texture_normal = Icons.make(u.role, u.side, u.name.begins_with("Dummy"), is_now, not u.is_alive())
		b.tooltip_text = _queue_tip(u, is_now)


func _seq_same(seq: Array[Unit]) -> bool:
	var cur := _slot_units()
	if cur.size() != seq.size():
		return false
	for i in seq.size():
		if cur[i] != seq[i]:
			return false
	return true


func _can_slide(seq: Array[Unit]) -> bool:
	var cur := _slot_units()
	if cur.size() < 2 or seq.size() < 2 or cur[0] == seq[0]:
		return false
	for i in mini(cur.size(), seq.size()) - 1:
		if cur[i + 1] != seq[i]:
			return false
	return true


func refresh_queue() -> void:
	if queue_strip == null:
		return
	var seq: Array = host.ui_upcoming(QUEUE_SHOWN)
	# 队列条宽度跟着实际人数缩（用户口径：不要一个老长的空框）
	queue_strip.custom_minimum_size.x = float(maxi(1, seq.size())) * QUEUE_SLOT
	if queue_anim_lock > 0.0:
		queue_need_refresh = true
		return
	if _seq_same(seq):
		_apply_slot_textures(seq)
		return
	if _can_slide(seq):
		_start_slide(seq)
	else:
		_rebuild_slots(seq)


func _start_slide(seq: Array[Unit]) -> void:
	var n := queue_slots.size()
	var new_slot := _make_slot(seq[seq.size() - 1], n, false)
	new_slot["btn"].modulate.a = 0.0
	new_slot["btn"].position.x = float(n) * QUEUE_SLOT + QUEUE_LINE
	if new_slot["line"] != null:
		new_slot["line"].modulate.a = 0.0
		new_slot["line"].position.x = float(n) * QUEUE_SLOT

	var tw: Tween = host.create_tween()
	tw.set_parallel(true)
	for s in queue_slots:
		var b: TextureButton = s["btn"]
		var ln: ColorRect = s["line"]
		if is_instance_valid(b):
			tw.tween_property(b, "position:x", b.position.x - QUEUE_SLOT, QUEUE_ANIM_SEC)
		if ln != null and is_instance_valid(ln):
			tw.tween_property(ln, "position:x", ln.position.x - QUEUE_SLOT, QUEUE_ANIM_SEC)
	var fb: TextureButton = queue_slots[0]["btn"]
	if is_instance_valid(fb):
		tw.tween_property(fb, "modulate:a", 0.0, QUEUE_ANIM_SEC)
	var fl: ColorRect = queue_slots[0]["line"]
	if fl != null and is_instance_valid(fl):
		tw.tween_property(fl, "modulate:a", 0.0, QUEUE_ANIM_SEC)
	tw.tween_property(new_slot["btn"], "modulate:a", 1.0, QUEUE_ANIM_SEC)
	tw.tween_property(new_slot["btn"], "position:x", float(n - 1) * QUEUE_SLOT + QUEUE_LINE, QUEUE_ANIM_SEC)
	if new_slot["line"] != null:
		tw.tween_property(new_slot["line"], "modulate:a", 1.0, QUEUE_ANIM_SEC)
		tw.tween_property(new_slot["line"], "position:x", float(n - 1) * QUEUE_SLOT, QUEUE_ANIM_SEC)
	queue_slots.append(new_slot)          # 先入列，收尾时再丢掉队头
	queue_anim_lock = QUEUE_ANIM_SEC


func tick_queue_anim(delta: float) -> void:
	if queue_anim_lock <= 0.0:
		return
	queue_anim_lock = maxf(0.0, queue_anim_lock - delta)
	if queue_anim_lock > 0.0:
		return
	# 收尾：丢掉淡出的队头（动画期间它已经在列表里挂着了）
	if not queue_slots.is_empty():
		var gone: Dictionary = queue_slots[0]
		for k in ["btn", "line"]:
			var c = gone[k]
			if c != null and is_instance_valid(c):
				queue_strip.remove_child(c)
				c.queue_free()
		queue_slots.remove_at(0)
	for i in queue_slots.size():
		var s: Dictionary = queue_slots[i]
		var b: TextureButton = s["btn"]
		var ln: ColorRect = s["line"]
		if is_instance_valid(b):
			b.position = Vector2(float(i) * QUEUE_SLOT + QUEUE_LINE, 6.0)
			b.modulate.a = 1.0
		if ln != null and is_instance_valid(ln):
			ln.position = Vector2(float(i) * QUEUE_SLOT, 6.0 + QUEUE_ICON * 0.5 - 1.5)
			ln.modulate.a = 1.0
			ln.visible = i > 0
	if queue_need_refresh:
		queue_need_refresh = false
		refresh_queue()


# ══════════════════════════════════════════════════════════════════════════════
# 刷新
# ══════════════════════════════════════════════════════════════════════════════
func refresh_all() -> void:
	if queue_label != null:
		queue_label.text = host.ui_round_text()
	refresh_queue()
	refresh_sandbox()
	refresh_detail()
	refresh_menus()


func refresh_sandbox() -> void:
	if sandbox_box == null:
		return
	if not host.ui_is_placing():
		sandbox_box.visible = false
		return
	sandbox_box.visible = true
	if place_buttons.is_empty():
		var title := Label.new()
		title.text = "沙盒 · 放置（选道具后点地面，两次确认）"
		sandbox_box.add_child(title)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		sandbox_box.add_child(row)
		var any := false
		for d in UnitData.PLACEABLES:
			var nm: String = d["name"]
			any = true
			var b := Button.new()
			b.toggle_mode = true
			b.custom_minimum_size = Vector2(96, 0)
			b.pressed.connect(func() -> void: host.ui_pick_place(nm))
			row.add_child(b)
			place_buttons[nm] = b
		if not any:
			var none := Label.new()
			none.text = "（本关没有可放置物）"
			row.add_child(none)
	for nm in place_buttons:
		var left: int = int(host.ui_place_left().get(nm, 0))
		var b: Button = place_buttons[nm]
		b.text = "%s ×%d" % [nm, left]
		b.disabled = left <= 0 and host.ui_place_kind() != nm
		b.set_pressed_no_signal(nm == host.ui_place_kind())


func refresh_detail() -> void:
	if detail == null:
		return
	# 用户口径：点空白处（没有选中任何东西）-> 左下角这一大块整个收起来；
	# 摆放阶段/瞄准技能/点中道具/点中角色时才有内容，才显示。
	var si: String = host.ui_skill_info()
	var pi: String = host.ui_placeable_info()
	var u: Unit = host.selected
	bottom.visible = si != "" or pi != "" or u != null or host.phase == 0 + 4   # Phase.PLACE
	# ① 瞄准技能时优先显示技能说明
	if si != "":
		panel.visible = true
		detail.text = si
		upgrade_box.visible = false
		return
	# ② 选中沙盒道具时显示道具信息
	if pi != "":
		panel.visible = true
		detail.text = pi
		upgrade_box.visible = false
		return
	# ③ 正常：选中角色的属性
	upgrade_box.visible = u != null
	if u == null:
		panel.visible = false
		return
	panel.visible = true
	detail.text = host.ui_detail_text(u)
	refresh_upgrades(u)


func refresh_upgrades(u: Unit) -> void:
	for c in upgrade_box.get_children():
		upgrade_box.remove_child(c)
		c.queue_free()
	if u == null:
		return
	if u.side != UnitData.Side.PLAYER and not u.controllable:
		var l := Label.new(); l.text = "（敌方单位不可加点）"; upgrade_box.add_child(l)
		return
	var note := Label.new()
	note.text = "加点（无限，不能加：移动力/物抗/魔抗）:"
	note.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	upgrade_box.add_child(note)
	for key in Rules.upgrade_options(u.role):
		var b := Button.new()
		b.text = "+ " + Rules.option_label(key)
		b.custom_minimum_size = Vector2(0, 30)
		b.add_theme_font_size_override("font_size", 13)
		b.pressed.connect(func() -> void: host.ui_upgrade(u, key))
		upgrade_box.add_child(b)
	var reset := Button.new()
	reset.text = "重置此人加点"
	reset.custom_minimum_size = Vector2(0, 30)
	reset.add_theme_font_size_override("font_size", 13)
	reset.add_theme_color_override("font_color", Color(1.0, 0.75, 0.4))
	reset.pressed.connect(func() -> void: host.ui_reset_upgrades(u))
	upgrade_box.add_child(reset)


## 菜单按钮的可用性 + 跟随角色
func refresh_menus() -> void:
	var a: Unit = host.active
	if btn_next != null:
		btn_next.text = ">>"
		btn_next.disabled = host.ui_busy()
	if a == null:
		if btn_rest != null:
			btn_rest.disabled = true
		if btn_skill != null:
			btn_skill.disabled = true
		return
	if btn_rest != null:
		var can_rest: bool = not a.has_moved and not a.has_acted
		btn_rest.disabled = not can_rest
		btn_rest.tooltip_text = "" if can_rest else "本回合已经移动过，不能再休息"
	if btn_skill != null:
		var ids := Skills.skills_for(a)
		if ids.is_empty():
			btn_skill.disabled = true
			btn_skill.text = "技能（无）"
			btn_skill.tooltip_text = ""
		else:
			var d := Skills.get_def(ids[0])
			btn_skill.disabled = a.energy_points() < int(d["cost"])
			btn_skill.text = "%s（%d 精力）" % [d["name"], int(d["cost"])]
			btn_skill.tooltip_text = "%s\n%s" % [d["name"], d["desc"]]
	if hint_label != null and host.phase == 1:      # Phase.MENU
		var note := " 已移动(不能休息)" if a.has_moved else " 未移动"
		hint_label.text = "已选 %s ｜ 精力 %d/%d ｜%s ｜ 三选一后自动结束" % [
			a.name, a.energy_points(), a.energy_max_points(), note]


# ══════════════════════════════════════════════════════════════════════════════
# 菜单显示 / 隐藏 / 跟随
# ══════════════════════════════════════════════════════════════════════════════
func show_action_menu(u: Unit) -> void:
	menu_anchor = u
	action_menu.visible = true
	_sync_menu_pos()


func hide_menus() -> void:
	action_menu.visible = false
	attack_menu.visible = false
	skill_menu.visible = false


func _sync_menu_pos() -> void:
	if action_menu == null or not action_menu.visible or menu_anchor == null:
		return
	if not menu_anchor.is_alive():
		return
	var cam: Camera3D = host.ui_camera()
	if cam == null:
		return
	var sp := cam.unproject_position(Vector3(float(menu_anchor.cell.x) + 0.5, 1.2,
		float(menu_anchor.cell.y) + 0.5))
	var vp: Vector2 = host.get_viewport().get_visible_rect().size
	var sz := action_menu.size
	var x := sp.x + 46.0
	var y := sp.y + 26.0
	if x + sz.x > vp.x - 8.0:
		x = sp.x - 46.0 - sz.x
	if y + sz.y > vp.y - 8.0:
		y = sp.y - 26.0 - sz.y
	action_menu.position = Vector2(clampf(x, 8.0, maxf(8.0, vp.x - sz.x - 8.0)),
		clampf(y, 8.0, maxf(8.0, vp.y - sz.y - 8.0)))


func sync_menu_position() -> void:
	_sync_menu_pos()


## 攻击菜单：伤害值直接写在按钮上，让"看到的 = 打出的"（没有精力投注了）
func show_attack_menu(target: Unit) -> void:
	attack_menu.visible = true
	var u: Unit = host.active
	var p: Rules.Preview = Rules.preview(u.power_cur, target.armor_cur, target.pr)
	match p.branch:
		Rules.Branch.NO_DAMAGE:
			btn_power.text = "打力量\n0（打不动）"
		Rules.Branch.ROLL:
			btn_power.text = "打力量\n1（%d%%概率）" % p.hit_percent
		Rules.Branch.AUTO:
			btn_power.text = "打力量\n%d" % p.damage
	btn_power.disabled = false            # 打不动也保留选择权（以后可能有 buff 流）
	btn_break.text = "破甲\n%s" % host.ui_fmt(u.armor_break)
	btn_break.disabled = target.armor_cur <= 0
	var cam: Camera3D = host.ui_camera()
	if cam != null and target.visual != null:
		var sp := cam.unproject_position(target.visual.global_position + Vector3(0, 0.5, 0))
		var vp: Vector2 = host.get_viewport().get_visible_rect().size
		attack_menu.position = Vector2(clampf(sp.x + 30.0, 8.0, vp.x - 350.0),
			clampf(sp.y - 50.0, 60.0, vp.y - 220.0))


## 技能列表（多技能单位）
func show_skill_menu(ids: Array[String], u: Unit) -> void:
	for c in skill_menu.get_children():
		skill_menu.remove_child(c)
		c.queue_free()
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	skill_menu.add_child(vb)
	var t := Label.new(); t.text = "选择技能"; vb.add_child(t)
	for id in ids:
		var d := Skills.get_def(id)
		var b := Button.new()
		b.text = "%s（%d 精力）" % [d["name"], int(d["cost"])]
		b.disabled = u == null or u.energy_points() < int(d["cost"])
		b.tooltip_text = String(d["desc"])
		b.pressed.connect(func() -> void:
			skill_menu.visible = false
			host.ui_pick_skill(id))
		vb.add_child(b)
	var c2 := Button.new(); c2.text = "取消（Esc）"
	c2.pressed.connect(func() -> void: host.ui_cancel())
	vb.add_child(c2)
	skill_menu.visible = true
	var vp: Vector2 = host.get_viewport().get_visible_rect().size
	skill_menu.position = Vector2(vp.x * 0.5 - 150.0, vp.y * 0.5 - 110.0)


# ══════════════════════════════════════════════════════════════════════════════
# 顶部/状态文本（宿主直接调）
# ══════════════════════════════════════════════════════════════════════════════
func set_status(text: String) -> void:
	if status != null:
		status.text = text


func show_result(win: bool) -> void:
	if result_box == null or result_box.visible:
		return
	result_box.visible = true
	result_label.text = "胜  利" if win else "失  败"
	result_label.add_theme_color_override("font_color",
		Color(0.55, 1.0, 0.55) if win else Color(1.0, 0.45, 0.42))
	result_sub.text = "敌方英雄全灭" if win else "我方英雄全灭"
	set_status(result_sub.text + " — 点「继续」重开")


func hide_result() -> void:
	if result_box != null:
		result_box.visible = false


# ══════════════════════════════════════════════════════════════════════════════
# 调试面板（重写版：选中即编辑）
#
# 旧版给 6 个单位 × 13 个字段建了 78 个输入框，一屏塞不下也没法扩展。
# 现在只编辑"当前选中的那个单位"，字段列表从 host.ui_dbg_fields() 生成，
# 以后加字段只改那个数组。
# ══════════════════════════════════════════════════════════════════════════════
var dbg_button: Button = null
var dbg_panel: PanelContainer = null
var dbg_title: Label = null
var dbg_fields_box: VBoxContainer = null
var dbg_edits: Array = []                 # [{key, edit, unit}]
var dbg_log: RichTextLabel = null
var dbg_seen_unit: Unit = null


func _build_debug() -> void:
	dbg_button = Button.new()
	dbg_button.text = "调试"
	dbg_button.anchor_left = 1.0; dbg_button.anchor_right = 1.0
	dbg_button.offset_left = -92; dbg_button.offset_right = -12
	dbg_button.offset_top = 10; dbg_button.offset_bottom = 46
	dbg_button.pressed.connect(func() -> void: toggle_debug())
	layer.add_child(dbg_button)

	dbg_panel = _panel_node()
	dbg_panel.visible = false
	dbg_panel.anchor_left = 1.0; dbg_panel.anchor_right = 1.0
	dbg_panel.offset_left = -320; dbg_panel.offset_right = -12
	dbg_panel.offset_top = 56; dbg_panel.offset_bottom = -290
	layer.add_child(dbg_panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	dbg_panel.add_child(vb)
	dbg_title = Label.new()
	dbg_title.text = "调试（点一个角色再改）"
	vb.add_child(dbg_title)
	# 关卡切换（用户要求：调试页里切场景）
	var lv := Label.new()
	lv.text = "关卡（点了立刻重载）"
	vb.add_child(lv)
	var lrow := HBoxContainer.new()
	lrow.add_theme_constant_override("separation", 6)
	vb.add_child(lrow)
	for l in host.ui_levels():
		var lb := Button.new()
		lb.text = String(l["name"])
		lb.toggle_mode = true
		lb.set_pressed_no_signal(bool(l["current"]))
		var lid: String = String(l["id"])
		lb.pressed.connect(func() -> void: host.ui_set_level(lid))
		lrow.add_child(lb)
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.custom_minimum_size = Vector2(0, 260)
	vb.add_child(sc)
	dbg_fields_box = VBoxContainer.new()
	dbg_fields_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(dbg_fields_box)
	var lv2 := Label.new(); lv2.text = "日志"
	vb.add_child(lv2)
	dbg_log = RichTextLabel.new()
	dbg_log.bbcode_enabled = false
	dbg_log.scroll_following = true
	dbg_log.custom_minimum_size = Vector2(0, 160)
	vb.add_child(dbg_log)


func toggle_debug() -> void:
	if dbg_panel == null:
		return
	dbg_panel.visible = not dbg_panel.visible
	if dbg_panel.visible:
		dbg_seen_unit = null
		refresh_debug()


func is_debug_open() -> bool:
	return dbg_panel != null and dbg_panel.visible


## 只在"选中的人变了"时重建输入框，否则每帧重建会打断输入
func refresh_debug() -> void:
	if not is_debug_open():
		return
	var u: Unit = host.selected
	if u != dbg_seen_unit:
		dbg_seen_unit = u
		_rebuild_debug_fields(u)
	else:
		# 只同步"没有焦点"的输入框：否则每帧都会把玩家正在敲的内容覆盖掉
		for e in dbg_edits:
			var unit: Unit = e["unit"]
			var le: LineEdit = e["edit"]
			if unit != null and not le.has_focus():
				le.text = str(host.ui_dbg_get(unit, e["key"]))
	var lines: PackedStringArray = host.ui_collect_log()
	dbg_log.text = "\n".join(lines)


func _rebuild_debug_fields(u: Unit) -> void:
	for c in dbg_fields_box.get_children():
		dbg_fields_box.remove_child(c)
		c.queue_free()
	dbg_edits.clear()
	if u == null:
		var l := Label.new()
		l.text = "（先点一个角色）"
		dbg_fields_box.add_child(l)
		dbg_title.text = "调试（点一个角色再改）"
		return
	dbg_title.text = "调试：%s（%s）" % [u.name, host.ui_faction_cn(u)]
	var fields: Array = host.ui_dbg_fields()
	for f in fields:
		var key: String = f[0]
		var label: String = f[1]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var lb := Label.new()
		lb.text = label
		lb.custom_minimum_size = Vector2(96, 0)
		row.add_child(lb)
		var le := LineEdit.new()
		le.text = str(host.ui_dbg_get(u, key))
		le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		le.text_submitted.connect(func(txt: String) -> void:
			host.ui_dbg_set(u, key, txt)
			dbg_seen_unit = null          # 强制重建，显示夹取/拒绝后的真实值
			refresh_debug())
		row.add_child(le)
		dbg_fields_box.add_child(row)
		dbg_edits.append({"key": key, "edit": le, "unit": u})
	var rb := Button.new()
	rb.text = "重置此单位全部字段"
	rb.pressed.connect(func() -> void:
		host.ui_dbg_reset(u)
		dbg_seen_unit = null
		refresh_debug())
	dbg_fields_box.add_child(rb)
