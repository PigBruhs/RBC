# ══════════════════════════════════════════════════════════════════════════════
# 单位运行时状态。统一用「千分比」内部单位：力量 41 → 41000。
# 死亡规则：只有力量池归零才阵亡；护甲池归零只失去减免。
# ══════════════════════════════════════════════════════════════════════════════
class_name Unit
extends RefCounted

var name: String = ""
var side: int = 0                     # UnitData.Side
var role: int = 0                     # UnitData.Role
var cell: Vector2i = Vector2i.ZERO

var power_max: int = 0
var power_cur: int = 0                # 力量池（生命）
var armor_max: int = 0
var armor_cur: int = 0                # 护甲池（减免）
var armor_break: int = 0              # 破甲伤害
var energy_max: int = 0               # 精力上限（千分比，1 点 = 1000）
var energy: int = 0
var energy_used_this_turn: int = 0
var rest_power: int = 0
var rest_armor: int = 0
var rest_energy: int = 0
var move: int = 3
var rng_min: int = 0
var rng_max: int = 0
var pr: int = 0                       # 物抗档（0/200/400/800/1000）
var mr: int = 0                       # 魔抗档（v1 不参与结算）

var allocated: Dictionary = {}        # 加点记录，用于重置
var tags: Dictionary = {}             # 技能/状态标记（例：orbital_incoming = 下回合先遭炮击）

## 阵亡时清空一切状态：buff / 标记 / 未结算的技能（用户口径）
func clear_states() -> void:
	tags.clear()
	focus_stacks = 0
	has_moved = false
	has_acted = false
	energy_used_this_turn = 0
var has_moved: bool = false
var has_acted: bool = false
## 阵营仍然是 side，但"这一位由玩家手动操作"（用户要求：敌方阵营里也有可控角色）
var controllable: bool = false
## 弓箭手「蓄势」层数：哨兵每摧毁一枚投掷物 +1，下一发普攻命中后清零
var focus_stacks: int = 0
## 没有自己的回合（公主这类"常驻哨兵"）：不进队列、不算英雄
var no_turn: bool = false
## 老国王：唯一的胜负判定对象（死一个国王就结束）
var is_king: bool = false
## 出生/复活格（英雄阵亡后回到这里）
var home_cell: Vector2i = Vector2i(-1, -1)
## 悬浮高度（直升机 = 2 格，其它 = 0）：只影响表现与弹道起点
var hover: float = 0.0
## 当前身体底面高度（第 89 轮）：**-1 = 用 hover**。
## 爬升轰炸这类"临时离开悬停高度"的动作由 view 每帧写进来 ——
## 因为三维判定（投弹球 / 空爆 / 箭矢高度轴）必须按【它现在真的在哪】算：
## 以前直升机爬到 4 格投弹，身体却还按 hover=2 判定，于是被自己的炸弹炸到（41 → 21）。
var body_y: float = -1.0

## 身体底面高度（格）：默认 hover；临时高度生效时用 body_y
func body_h() -> float:
	return hover if body_y < 0.0 else body_y

# 表现层引用（由 battle_scene 注入）
var visual: Node3D = null

static func from_data(d: Dictionary) -> Unit:
	var u := Unit.new()
	u.name = d["name"]
	u.side = d["side"]
	u.role = d["role"]
	u.power_max = Rules.points_to_milli(d["power"])
	u.power_cur = u.power_max
	u.armor_max = Rules.points_to_milli(d["armor"])
	u.armor_cur = u.armor_max
	u.armor_break = Rules.points_to_milli(d["armor_break"])
	u.energy_max = Rules.points_to_milli(d["energy_max"])
	u.energy = u.energy_max
	# 休息恢复值来自 bc_stat.md 表格；表格没写则兜底：力/甲 = 0，精力 = 1（用户指定）
	u.rest_power = Rules.points_to_milli(d.get("rest_power", 0))
	u.rest_armor = Rules.points_to_milli(d.get("rest_armor", 0))
	u.rest_energy = Rules.points_to_milli(d.get("rest_energy", 1))
	u.move = d["move"]
	u.rng_min = d["rng_min"]
	u.rng_max = d["rng_max"]
	u.pr = d["pr"]
	u.mr = d["mr"]
	u.controllable = bool(d.get("controllable", false))
	return u


## 基础名：敌方镜像带 " (E)"、左右分身带 "·左/·右"，技能/表现层按基础名匹配。
## 例：Alette (E) -> Alette ｜ 公主·左 (E) -> 公主
static func base_name(n: String) -> String:
	var s := n.strip_edges()
	var changed := true
	while changed:
		changed = false
		for suffix in [" (E)", "(E)", "·E", " E", "·左", "·右"]:
			if s.ends_with(suffix):
				s = s.substr(0, s.length() - suffix.length()).strip_edges()
				changed = true
				break
	return s


## 这一位会不会进入回合队列。
## 假人（Dummy*）是纯靶子：不行动、不进队列、不占回合（用户要求）。
## 公主这类"常驻哨兵"由 no_turn 标记：同样不进队列、不算英雄。
func has_turn() -> bool:
	return not no_turn and not name.begins_with("Dummy")


## 这一位是不是"玩家手动操作"的（我方全员 + 敌方里标记可控的）
func is_manual() -> bool:
	return side == UnitData.Side.PLAYER or controllable

func is_alive() -> bool:
	return power_cur > 0

func begin_turn() -> void:
	has_moved = false
	has_acted = false
	energy_used_this_turn = 0

## 精力用来**支付行动费**：技能要精力，**普攻也可能要精力**（直升机火箭齐射 = 4）。
## 用户口径（第 97 轮）：删掉"精力只用来付技能费"的说法 —— 那是自相矛盾的旧文案。
## 仍然成立的是：**精力不能用来加伤害**（早期"投入精力加伤害"整套已删除，代码里没有任何入口）。
func spend_energy(points: int) -> void:
	var cost: int = points * 1000
	energy -= cost
	energy_used_this_turn += cost

func take_power_damage(amount_milli: int) -> void:
	power_cur = maxi(0, power_cur - amount_milli)

func take_armor_damage(amount_milli: int) -> void:
	armor_cur = maxi(0, armor_cur - amount_milli)

func rest() -> void:
	power_cur = mini(power_max, power_cur + rest_power)
	armor_cur = mini(armor_max, armor_cur + rest_armor)
	energy = mini(energy_max, energy + (rest_energy if rest_energy > 0 else 1000))

## 射程是否够得着（近战 = 4 邻格，曼哈顿距离 1）
func in_range_of(target_cell: Vector2i) -> bool:
	var d: int = absi(cell.x - target_cell.x) + absi(cell.y - target_cell.y)
	if role == UnitData.Role.MELEE:
		return d == 1
	return d >= rng_min and d <= rng_max

func power_points() -> float: return power_cur / 1000.0
func armor_points() -> float: return armor_cur / 1000.0
func power_max_points() -> float: return power_max / 1000.0
func armor_max_points() -> float: return armor_max / 1000.0
func energy_points() -> int: return energy / 1000
func energy_max_points() -> int: return energy_max / 1000

static func tier_name(t: int) -> String:
	match t:
		0: return "无"
		200: return "低"
		400: return "中"
		800: return "高"
		1000: return "免疫"
	return "?"

static func role_name(r: int) -> String:
	match r:
		UnitData.Role.MELEE: return "近战"
		UnitData.Role.RANGED: return "远程"
		UnitData.Role.THROWER: return "投掷"
	return "?"
