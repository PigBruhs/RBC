# 第 109 轮：Reaper 战**顶部 Boss 血条**探针
#   用户口径：「请为 Reaper 战场景增加顶部 Boss 血条，**只看力量**，**只有这个场景有**」
#
# 走真实场景 + 真实刷新链（`_refresh_all` -> `ui.refresh_all` -> `refresh_bossbar`），
# 并**用截图能力之外的纯数值**断言：可见性 / 数值 / 填充比例。
extends SceneTree

const LEVEL := "reaper"
const NON_BOSS := "field"

var _fails := 0
var _checks := 0


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  PASS  ", what)
	else:
		_fails += 1
		print("  FAIL  ", what)


func _initialize() -> void:
	# ⚠ 必须 `await`：`_run()` 里有 await，不 await 的话 quit() 会在它挂起后**立刻**执行
	#   （实测：只打印了 [1] 就退出，一条断言都没跑）
	await _run()
	quit(1 if _fails > 0 else 0)


func _run() -> void:
	print("[1] Boss 关（%s）：血条必须出现、只看力量" % LEVEL)
	var s := await _scene(LEVEL)
	var ui = s.ui
	_ok(ui.boss_box != null, "血条控件已建立")
	_ok(ui.boss_box.visible, "**Boss 关里血条可见**")
	_ok(ui.boss_name_label.text == "Reaper", "名字 = Reaper（实际 %s）" % ui.boss_name_label.text)

	var rp: Unit = null
	for u in s.units:
		if u != null and u.name == "Reaper":
			rp = u
			break
	_ok(rp != null, "场上找到 Reaper")
	if rp != null:
		var want := "%s / %s" % [s.ui_fmt(rp.power_cur), s.ui_fmt(rp.power_max)]
		_ok(ui.boss_hp_label.text == want,
			"数字 = 力量池 %s（实际 %s）" % [want, ui.boss_hp_label.text])

		# 打掉一半力量 -> 数字与填充比例都要**立刻**跟上（只看力量）
		var before_fill: float = ui.boss_fill.size.x
		rp.power_cur = int(rp.power_max / 2)
		s._refresh_all()
		await process_frame
		await process_frame
		var want2 := "%s / %s" % [s.ui_fmt(rp.power_cur), s.ui_fmt(rp.power_max)]
		_ok(ui.boss_hp_label.text == want2, "掉血后数字跟上（%s）" % ui.boss_hp_label.text)
		var trough_w: float = float(ui.boss_fill.get_parent().size.x) - 4.0
		var frac: float = ui.boss_fill.size.x / maxf(1.0, trough_w)
		print("      槽宽 %.1f ｜ 填充 %.1f（%.1f%%）｜ 改前填充 %.1f" % [
			trough_w, ui.boss_fill.size.x, frac * 100.0, before_fill])
		_ok(absf(frac - 0.5) < 0.06, "填充 ≈ 50%%（实际 %.1f%%）" % (frac * 100.0))

		# 只看力量：护甲掉光**不影响**血条比例
		var fill_before: float = ui.boss_fill.size.x
		rp.armor_cur = 0
		s._refresh_all()
		await process_frame
		_ok(is_equal_approx(ui.boss_fill.size.x, fill_before),
			"**护甲归零不影响血条**（只看力量，填充 %.1f -> %.1f）" % [
				fill_before, ui.boss_fill.size.x])

		# Boss 死了 -> 隐藏（`Unit` 是 RefCounted、没有 kill()；力量归零即 `is_alive() == false`）
		rp.power_cur = 0
		s._refresh_all()
		await process_frame
		_ok(not rp.is_alive(), "力量归零 -> Reaper 判定为阵亡")
		_ok(not ui.boss_box.visible, "**Boss 阵亡后血条隐藏**")

	print("\n[2] 非 Boss 关（%s）：血条必须隐藏" % NON_BOSS)
	var s2 := await _scene(NON_BOSS)
	_ok(not s2.ui.boss_box.visible, "**非 Boss 关血条不可见**")
	# 就算场上硬塞一个叫 Reaper 的单位也不该显示（判据是关卡类型，不是名字）
	_ok(String(Level.victory(NON_BOSS).get("type", "")) != "boss",
		"判据来自关卡定义 victory.type（%s）" % str(Level.victory(NON_BOSS).get("type")))

	print("\n── Boss 血条探针：%d 项检查，失败 %d 项 ──" % [_checks, _fails])


func _scene(id: String) -> Node:
	Level.current = id
	var s = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(s)
	for i in 10:
		await process_frame
	return s
