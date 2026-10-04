# ══════════════════════════════════════════════════════════════════════════════
# 格子几何纯函数（无状态、可无头测试）
#
# 为什么单独一个文件：`battle_scene._cc` 与 `Ordnance._cell_center` 是**同一个换算**
# 的逐字复制品，散在 core / view 两边，改一处忘一处就会造成"看到的落点 ≠ 打到的落点"。
# 放 core 而不是 Targeting：Targeting 管的是"瞄准规则"（能不能打、覆盖了谁），
# 这里管的是"格 -> 浮点坐标"这一层纯几何；而且放 core 才能让 core 与 view 同时引用，
# 不会出现 core 反向依赖 view。
# ══════════════════════════════════════════════════════════════════════════════
class_name GridMath
extends RefCounted


## 格子中心（浮点）：落点统一用它，避免各入口各写一份 +0.5
static func cell_center(c: Vector2i) -> Vector2:
	return Vector2(float(c.x) + 0.5, float(c.y) + 0.5)


## 单位"现在在哪"（浮点格坐标）。**走路中的角色要用视觉位置** ——
## 逻辑格子（u.cell）在移动发起时就瞬移到终点了，视觉位置才是它当下真正所在的地方
## （用户口径第 83 轮：直升机边走边打时，火箭必须从"当前位置"出膛）。
static func unit_pos(u: Unit) -> Vector2:
	if u == null:
		return Vector2.ZERO
	if u.visual != null:
		return Vector2(u.visual.position.x, u.visual.position.z)
	return cell_center(u.cell)
