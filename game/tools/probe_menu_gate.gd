# 行动菜单门禁探针（第 103 轮用户报的 UI bug）
#
# 用户原话（澄清后）：
#   「我是说**敌人的回合时，敌人在被 AI 操控的过程中我仍然能点开敌人的二级菜单**
#     （移动、普攻、技能这些），不是指瞄准时选攻击力量还是护甲的三级菜单」
#
# 所以判据是：**被 AI 操控的单位不弹行动菜单**，但**点它看属性仍然要正常**。
# 这个探针把四种情形都实测一遍（mod-fx 交代码时只做了静态论证，没跑运行时证据）。
#
# 运行： exe --headless --path game --script res://tools/probe_menu_gate.gd --quit-after 90000
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


## 行动菜单节点在 host 与 ui 上各有一份引用（历史命名），两处都要看
func _menu_visible() -> bool:
	return (_s._action_menu != null and _s._action_menu.visible) \
		or (_s.ui.action_menu != null and _s.ui.action_menu.visible)
func _menu_node() -> PanelContainer:
	return _s._action_menu if _s._action_menu != null else _s.ui.action_menu


func _detail_text_len() -> int:
	return _s.ui_detail_text(_s.selected).length() if _s.selected != null else 0


func _find(nm: String, side: int) -> Unit:
	for u in _s.units:
		if u.name == nm and u.side == side and u.is_alive():
			return u
	return null


func _initialize() -> void:
	_s = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(_s)
	for i in 8:
		await process_frame

	var foe := _find("Gerald (E)", UnitData.Side.ENEMY)
	var mine := _find("Gerald", UnitData.Side.PLAYER)
	_chk(foe != null and mine != null, "场上找得到敌方与我方各一个英雄")

	print("\n[1] 敌方被 AI 操控：点它**不弹**行动菜单，但**看属性照常**")
	_s.t_set_ai_enabled(true)
	_s.t_set_autoplay_player(false)
	_s.active = foe                       # 假设当前轮到它
	if _menu_node() != null:
		_menu_node().visible = false
	_chk(_s._is_ai_unit(foe), "敌方单位被判定为 AI 操控（_is_ai_unit = true）")
	_s.ui_click_unit(foe)
	await process_frame
	_chk(not _menu_visible(), "AI 操控的敌人：点它**不弹**行动菜单")
	_chk(_s.selected == foe, "但**仍然被选中**（看属性那条路没被拦）")
	_chk(_detail_text_len() > 0, "属性栏文本正常生成（长度 %d）" % _detail_text_len())

	print("\n[2] 从**队列条**点同一个敌人 -> 同样不弹")
	if _menu_node() != null:
		_menu_node().visible = false
	_s.ui_click_unit(foe, true)
	await process_frame
	_chk(not _menu_visible(), "队列条点 AI 操控的敌人也不弹菜单")
	_chk(_s.selected == foe, "队列条点击仍然选中了他")

	print("\n[3] 玩家自己回合、点自己人 -> 菜单**必须照常弹**（不能把我方一起拦了）")
	_s.t_set_autoplay_player(false)
	_s.active = mine
	if _menu_node() != null:
		_menu_node().visible = false
	_chk(not _s._is_ai_unit(mine), "我方单位不被判定为 AI 操控（autoplay=false）")
	# ⚠ 用**真实点击入口** `ui_click_unit`，不要用 `t_show_action_menu()` ——
	#   后者是绕过 `can_menu` 判据直接调菜单，测不到"点自己人"这条路径（也不该测它：
	#   它本身就是给测试用的裸入口，UI 不这么调）。
	_s.ui_click_unit(mine)
	await process_frame
	_chk(_menu_visible(), "点我方当前单位：行动菜单正常弹出")
	_chk(_s.selected == mine, "并且选中了他")

	print("\n[4] ai_autoplay_player = true（我方交给 AI）-> 我方也不弹")
	_s.t_set_autoplay_player(true)
	_s.active = mine
	if _menu_node() != null:
		_menu_node().visible = false
	_s.selected = null
	_chk(_s._is_ai_unit(mine), "autoplay=true 时我方也被判定为 AI 操控")
	_s.ui_click_unit(mine)
	await process_frame
	_chk(not _menu_visible(), "autoplay=true：点我方当前单位也不弹菜单")
	_chk(_s.selected == mine, "但选中与属性仍然正常（%d 字）" % _detail_text_len())
	_s.t_set_autoplay_player(false)

	print("\n[5] 非当前行动者：点它只选中、不弹菜单（既有口径不能被破坏）")
	_s.active = mine
	if _menu_node() != null:
		_menu_node().visible = false
	_s.ui_click_unit(foe)                  # foe 不是 active
	await process_frame
	_chk(not _menu_visible(), "点一个**不是当前行动者**的单位不弹菜单")
	_chk(_s.selected == foe, "但仍然选中它（看属性）")

	print("\n── 行动菜单门禁探针：%d 项检查，失败 %d 项 ──" % [_checks, _fails.size()])
	for f in _fails:
		print("   - ", f)
	quit(1 if _fails.size() > 0 else 0)
