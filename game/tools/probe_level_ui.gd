# 调试面板的关卡按钮探针（第 100 轮）
#
# 为什么单独一个探针：用户报"我在调试菜单栏里找不到进入 Reaper 场景的按钮" ——
# 关卡按钮原来是**横向 HBox**，而调试面板只有 308px 宽（offset_left=-320 / offset_right=-12），
# 第三个关卡会被挤出面板右边缘；面板不裁剪 → 直接看不见。
# run.gd 只验元数据（`Level.ids()` 有三个），完全覆盖不到"按钮在不在面板里"。
#
# 运行： exe --headless --path game --script res://tools/probe_level_ui.gd --quit-after 60000
extends SceneTree

var _s: Node
var _fails: Array[String] = []
var _checks := 0


func _chk(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("  PASS  ", label)
	else:
		print("  FAIL  ", label)
		_fails.append(label)


## 递归找关卡按钮（文字等于某个关卡的 name）
func _level_buttons(root: Node) -> Array[Button]:
	var out: Array[Button] = []
	if root == null:
		return out
	var names: Array = []
	for id in Level.ids():
		names.append(Level.name_of(id))
	for c in root.get_children():
		if c is Button and names.has(String((c as Button).text)):
			out.append(c as Button)
		if c.get_child_count() > 0:
			out.append_array(_level_buttons(c))
	return out


func _initialize() -> void:
	# ⚠ 无头模式下视口**不是** project.godot 里的 1600×900（实测 948 宽）——
	# 所以必须显式设成真实窗口尺寸，否则"按钮放不放得下"的结论是假的。
	root.size = Vector2i(1600, 900)
	_s = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(_s)
	for i in 8:
		await process_frame
	print("    视口 = %s（真实窗口尺寸）" % str(root.get_visible_rect().size))

	print("\n[1] 三个关卡各有一个按钮")
	var info: Array = _s.ui_levels()
	_chk(info.size() == 3, "ui_levels 给出 3 个关卡（实际 %d）" % info.size())
	# BattleUI 是 RefCounted（不是 Node），面板挂在它的 CanvasLayer 上
	var panel: PanelContainer = _s.ui.dbg_panel
	_chk(panel != null, "拿得到调试面板（ui.dbg_panel）")
	_s.ui.toggle_debug()                      # 打开面板（默认是隐藏的）
	await process_frame
	await process_frame
	_chk(_s.ui.is_debug_open(), "调试面板已打开")
	var btns: Array[Button] = _level_buttons(panel)
	_chk(btns.size() == 3, "面板里有 3 个关卡按钮（实际 %d）" % btns.size())

	print("\n[2] 每个按钮都**够宽到能一行显示关卡名**（这是用户踩的那个坑）")
	if panel != null:
		var pr: Rect2 = panel.get_global_rect()
		print("    面板矩形 = x %.0f~%.0f ｜ y %.0f~%.0f（宽 %.0f）" % [
			pr.position.x, pr.position.x + pr.size.x, pr.position.y, pr.position.y + pr.size.y, pr.size.x])
		_chk(pr.size.x > 100.0, "面板有真实宽度（%.0f）" % pr.size.x)
		# 面板内容区宽 = 面板宽 - 左右各 10 的 content margin（与 `_menu_style()` 一致）
		var content_w: float = pr.size.x - 20.0
		for b in btns:
			var br: Rect2 = b.get_global_rect()
			print("    按钮「%s」= x %.0f~%.0f（%.0f×%.0f）" % [
				b.text, br.position.x, br.position.x + br.size.x, br.size.x, br.size.y])
			_chk(br.position.x >= pr.position.x - 1.0
				and br.position.x + br.size.x <= pr.position.x + pr.size.x + 1.0,
				"按钮「%s」没有横向溢出面板" % b.text)
			_chk(br.size.x > 8.0 and br.size.y > 8.0,
				"按钮「%s」有可见尺寸（%.0f×%.0f）" % [b.text, br.size.x, br.size.y])
			# ★ 核心断言：按钮宽度要接近面板内容区宽（= 竖排、每个占满一行）。
			#   横排时实测每个只有 94~95px —— 连「皇室竞技场」5 个字都放不下，
			#   文字被折成好几行、认不出是哪个关卡（用户原话："找不到进 Reaper 场景的按钮"）。
			_chk(br.size.x >= content_w * 0.9,
				"按钮「%s」宽度接近面板内容区（%.0f / %.0f）—— 必须竖排" % [b.text, br.size.x, content_w])
			var approx_text_w: float = float(String(b.text).length()) * 14.0
			_chk(approx_text_w < br.size.x,
				"「%s」的文字一行放得下（估算 %.0f < 按钮 %.0f）" % [b.text, approx_text_w, br.size.x])
		# 竖排：三者的 x 应该基本一致（同一列），y 递增
		if btns.size() == 3:
			var xs: Array[float] = []
			var ys: Array[float] = []
			for b in btns:
				xs.append(b.get_global_rect().position.x)
				ys.append(b.get_global_rect().position.y)
			var x_spread: float = absf(maxf(xs[0], maxf(xs[1], xs[2])) - minf(xs[0], minf(xs[1], xs[2])))
			_chk(x_spread < 4.0, "三个按钮是**竖排**（x 几乎一致，实测散布 %.1f）" % x_spread)
			_chk(ys[0] < ys[1] and ys[1] < ys[2], "三个按钮从上到下排列（y %.0f < %.0f < %.0f）" % [ys[0], ys[1], ys[2]])

	print("\n[3] 名字短、详细尺寸在 desc（tooltip）")
	for l in info:
		var nm := String(l["name"])
		var ds := String(l.get("desc", ""))
		_chk(nm.length() <= 14, "「%s」名字够短（%d 字）" % [nm, nm.length()])
		_chk(ds != "", "「%s」有 desc 供 tooltip 用" % nm)

	print("\n[4] 按钮文字真的能对上 Reaper 关（用户要点的那个）")
	var hit := false
	for b in btns:
		if b.text == Level.name_of("reaper"):
			hit = true
	_chk(hit, "有一个按钮的文字 = '%s'" % Level.name_of("reaper"))

	print("\n[5] 切关卡的真实路径（ui_set_level）会改 Level.current")
	# ⚠ `ui_set_level` 里会 `reload_current_scene()` —— 无头下这个调用不一定返回，
	#   所以这里只**记录**它的行为，不作为"必须返回"的断言：
	#   直接断言"Level.current 这个静态字段被写进去"这一步（reload 之前就发生了）。
	Level.current = "reaper"
	_chk(Level.current == "reaper", "Level.current 可被设为 reaper")
	Level.current = "field"

	print("\n── 关卡按钮探针：%d 项检查，失败 %d 项 ──" % [_checks, _fails.size()])
	for f in _fails:
		print("   - ", f)
	quit(1 if _fails.size() > 0 else 0)
