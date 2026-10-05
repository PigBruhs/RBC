# 第 111 轮：**AI 操控的单位绝不弹二级菜单**（用户报的 bug 的回归钉子）
#
# 用户口径：「把敌人 AI 操控角色时自动弹出来的二级菜单关闭，
#            确保每次敌方 AI 操控一个角色时不会弹一个二级菜单出来」
#
# 实测漏网点：`battle_scene._place_menu_near` 原来**只拦 `_ai_turn`**，
# 然后直接调 `battle_ui.show_action_menu(u)` —— 那个函数把 `action_menu.visible = true`
# **写死**，绕过了 `action_menu.show_action_menu` 里的 `_is_ai_unit(active)` 守卫。
# 本探针把"两个入口都要拦住"钉死。
extends SceneTree

const LEVEL := "field"

var _f := 0
var _n := 0


func _ok(c: bool, w: String) -> void:
	_n += 1
	if c:
		print("  PASS  ", w)
	else:
		_f += 1
		print("  FAIL  ", w)


func _initialize() -> void:
	Level.current = LEVEL
	var s: Node = (load("res://src/view/battle_scene.tscn") as PackedScene).instantiate()
	root.add_child(s)
	for i in 8:
		await process_frame
	_run(s)
	quit(1 if _f > 0 else 0)


func _run(s: Node) -> void:
	# 找一个**敌方**单位（= AI 操控）与一个**我方**单位（= 玩家操控）
	var enemy: Unit = null
	var mate: Unit = null
	for u in s.units:
		if u == null or not u.is_alive() or not u.has_turn():
			continue
		if enemy == null and u.side == UnitData.Side.ENEMY:
			enemy = u
		if mate == null and u.side == UnitData.Side.PLAYER:
			mate = u
	_ok(enemy != null, "找到一个敌方（AI 操控）单位")
	_ok(mate != null, "找到一个我方（玩家操控）单位")
	if enemy == null or mate == null:
		return
	s.ai_enabled = true
	_ok(s._is_ai_unit(enemy), "敌方单位被判定为 AI 操控（%s）" % enemy.name)
	_ok(not s._is_ai_unit(mate), "我方单位**不是** AI 操控（%s）" % mate.name)

	print("\n[1] 入口①：action_menu.show_action_menu()")
	s.active = enemy
	s._ai_turn = false
	s.action_menu.show_action_menu()
	_ok(not s.action_menu._st._action_menu.visible if false else
		not (s.ui != null and s.ui.action_menu != null and s.ui.action_menu.visible),
		"**AI 单位走入口①不弹菜单**")

	print("\n[2] 入口②：battle_scene._place_menu_near()（= 实测漏网的那条）")
	# 关键：**故意把 `_ai_turn` 设成 false**，模拟"不走通用 AI 的路径"（例如 Reaper 回合）
	s._ai_turn = false
	s.active = enemy
	s._place_menu_near(enemy)
	var vis_enemy: bool = s.ui.action_menu.visible
	_ok(not vis_enemy, "**_ai_turn=false 时 AI 单位也不弹菜单**（实际 visible=%s）" % str(vis_enemy))
	# AI 回合标记为真时同样不弹
	s._ai_turn = true
	s._place_menu_near(enemy)
	_ok(not s.ui.action_menu.visible, "_ai_turn=true 时也不弹")

	print("\n[3] 对照组：**玩家操控**的单位必须照常弹（别把功能改坏）")
	s._ai_turn = false
	s.active = mate
	s._place_menu_near(mate)
	var vis_mate: bool = s.ui.action_menu.visible
	_ok(vis_mate, "**玩家操控的单位仍然会弹菜单**（visible=%s）" % str(vis_mate))
	s.action_menu.show_action_menu()
	_ok(s.ui.action_menu.visible, "玩家走入口①也照常弹")

	# ⚠ [4] 原本想"真跑一段 AI 回合、逐帧检查菜单没亮"——但试玩场里 AI 打下去会**判胜负**，
	#   而胜负会调 `quit()`，把本探针在那一节静默掐断（实测 60 与 240 帧都如此）。
	#   所以这一节去掉：上面 [1][2][3] 已经**直接**覆盖了两个入口的守卫（bug 就是漏了其中一个），
	#   比"跑一会儿碰运气"更准确。
	print("\n── AI 不弹二级菜单探针：%d 项检查，失败 %d 项 ──" % [_n, _f])
