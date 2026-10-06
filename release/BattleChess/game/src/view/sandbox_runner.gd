# ══════════════════════════════════════════════════════════════════════════════
# 放置/沙盒/待确认状态机（从 battle_scene.gd 拆出，P2c）
#
# 模块形态与其他一致：RefCounted 子对象 + 构造注入宿主，模块内用 _st.xxx 显式访问共享状态。
# 行为零变化：函数体逐字搬运，只做两类改写 ——
#   宿主成员（var/func/const/signal/枚举 Phase/继承自 Node 的方法） -> _st.<名字>
#   被搬走的函数互相调用 -> 直接调模块方法（去掉前导下划线）
#
# ⚠️ 跨模块事实接口（**宿主同名包装不许删**，别的模块正在通过 _st. 调它们）：
#   _set_pending / _same_pending / _clear_pending  <- skill_runner.gd、action_menu.gd
#   _can_place_at                                  <- view_fx.gd（放置高亮配色）
#   _placeable_at                                  <- basic_attack.gd（近战打道具）
#   _blocked_cells                                 <- turn_runner.gd（寻路占格）
#
# ⚠️ 口径（别重构）：place_left 的数量上限读 UnitData.PLACEABLES 的 count 列（巡飞弹 1 台/场景）；
#   _pending_kind / _pending_cell 的**字段声明留在宿主**（ViewFx 的黄勾可视化读它们）。
# ══════════════════════════════════════════════════════════════════════════════
class_name SandboxRunner
extends RefCounted

## 宿主 BattleScene。**故意不加静态类型**（宿主没有 class_name）。
var _st = null


func _init(host: Node3D) -> void:
	_st = host


func build_sandbox() -> void:
	# 沙盒数据在这里准备；按钮由 BattleUI 负责建（它自己按 place_left 刷新）
	_st.placeables.clear()
	_st.place_left.clear()
	for d in UnitData.PLACEABLES:
		_st.place_left[d["name"]] = d["count"]
	if _st.ui != null:
		_st.ui.refresh_sandbox()


func enter_placement() -> void:
	_st.phase = _st.Phase.PLACE
	_st.active = null
	_st.selected = null
	_st._place_kind = ""
	if _st.ui != null:
		_st.ui.refresh_sandbox()
	if _st._btn_next != null:
		_st._btn_next.visible = true
		_st._btn_next.text = ">>"
	if _st._action_menu != null:
		_st._action_menu.visible = false
	_st._refresh_all()


func pick_place_kind(nm: String) -> void:
	if _st.phase != _st.Phase.PLACE:
		return
	if _st.place_left.get(nm, 0) <= 0:
		if _st.ui != null:
			_st.ui.refresh_sandbox()
		return
	_st._place_kind = nm if _st._place_kind != nm else ""
	if _st.ui != null:
		_st.ui.refresh_sandbox()


func place_at(c: Vector2i) -> void:
	if _st._place_kind == "":
		return
	if _st.place_left.get(_st._place_kind, 0) <= 0:
		pass
		return
	if not can_place_at(c):
		pass
		return
	var data := placeable_data(_st._place_kind)
	if data.is_empty():
		return
	var p := Placeable.from_data(data, c)
	_st.placeables.append(p)
	var v := PlaceableView.new()
	_st.add_child(v)
	v.setup(p)
	v.set_preview(false, true)
	_st.place_left[_st._place_kind] = int(_st.place_left.get(_st._place_kind, 0)) - 1
	_st._log("放置 %s 于 (%d, %d)，剩余 %d" % [_st._place_kind, c.x, c.y, _st.place_left[_st._place_kind]])
	if _st.place_left[_st._place_kind] <= 0:
		_st._place_kind = ""
	if _st.ui != null:
		_st.ui.refresh_sandbox()


func can_place_at(c: Vector2i) -> bool:
	if not Level.in_play(c):          # 空场不能放（用户口径：那里没有格子）
		return false
	if Level.is_river(c):
		return false
	for u in _st.units:
		if u.is_alive() and u.cell == c:
			return false
	for p in _st.placeables:
		if p.is_alive() and p.covers(c):
			return false
	return true


func placeable_data(nm: String) -> Dictionary:
	for d in UnitData.PLACEABLES:
		if d["name"] == nm:
			return d
	return {}


func finish_placement() -> void:
	if _st.phase != _st.Phase.PLACE:
		return
	_st.phase = _st.Phase.IDLE
	_st._place_kind = ""
	if _st.ui != null:
		_st.ui.refresh_sandbox()
	_st._start_round()


func set_pending(kind: String, cell: Vector2i, actor: Unit = null) -> void:
	_st._pending_kind = kind
	_st._pending_cell = cell
	_st.fx.set_pending_actor(actor)
	_st.fx.update_pending_visual()          # 立刻刷新：不然调用方忘了 _draw_hints 就看不见黄勾


func clear_pending() -> void:
	_st._pending_kind = ""
	_st._pending_cell = Vector2i(-1, -1)
	_st.fx.set_pending_actor(null)
	_st.fx.update_pending_visual()


func same_pending(kind: String, cell: Vector2i) -> bool:
	return _st._pending_kind == kind and _st._pending_cell == cell


func blocked_cells() -> Dictionary:
	var out := Level.river_cells()          # 河：角色无法移动进去（桥是普通地板，已排除）
	for p in _st.placeables:
		if p.is_alive() and p.block_move:
			for c in p.occupied_cells():
				out[c] = true
	return out


func ranged_blocked_at(c: Vector2i, by_thrower: bool) -> bool:
	if by_thrower:
		return false
	for p in _st.placeables:
		if p.is_alive() and p.block_ranged and p.covers(c):
			return true
	return false


func placeable_at(c: Vector2i) -> Placeable:
	for p in _st.placeables:
		if p.is_alive() and p.covers(c):
			return p
	return null


func ui_place_left() -> Dictionary:
	return _st.place_left


func ui_place_kind() -> String:
	return _st._place_kind


func ui_is_placing() -> bool:
	return _st.phase == _st.Phase.PLACE


func ui_pick_place(nm: String) -> void:
	pick_place_kind(nm)

