# ══════════════════════════════════════════════════════════════════════════════
# 可放置物（沙盒物件）：木刺、土堆这类"战场道具"。
#
# 与 Unit 的区别（用户要求单开一个对象来描述）：
#   · 没有回合、不进队列、没有精力、没有移动力、不会行动
#   · 只有：位置与占地、力量池、护甲池、双抗、是否阻挡移动、是否阻挡远程
#   · 力量归零即被摧毁（同 Unit 的死亡规则）
# 内部数值一律用千分比（力量 40 → 40000），与 Unit 保持一致。
# ══════════════════════════════════════════════════════════════════════════════
class_name Placeable
extends RefCounted

var name: String = ""
var w: int = 1                        # 占地宽（格）
var h: int = 1                        # 占地高（格）
var cell: Vector2i = Vector2i.ZERO    # 左上角所在格

var power_max: int = 0
var power_cur: int = 0
var armor_max: int = 0
var armor_cur: int = 0
var pr: int = 0                       # 物抗档（0/200/400/800/1000）
var mr: int = 0                       # 魔抗档
var block_move: bool = true           # 是否阻挡移动
var block_ranged: bool = true         # 是否阻挡远程（投掷手不吃这条）

var visual: Node3D = null             # 表现层引用（由 battle_scene 注入）

static func from_data(d: Dictionary, at: Vector2i) -> Placeable:
	var p := Placeable.new()
	p.name = d["name"]
	p.w = d.get("w", 1)
	p.h = d.get("h", 1)
	p.cell = at
	p.power_max = Rules.points_to_milli(d["power"])
	p.power_cur = p.power_max
	p.armor_max = Rules.points_to_milli(d["armor"])
	p.armor_cur = p.armor_max
	p.pr = d["pr"]
	p.mr = d["mr"]
	p.block_move = d.get("block_move", true)
	p.block_ranged = d.get("block_ranged", true)
	return p


func is_alive() -> bool:
	return power_cur > 0


## 占用的所有格子（支持 1x1 以上的占地）
func occupied_cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dy in h:
		for dx in w:
			out.append(cell + Vector2i(dx, dy))
	return out


func covers(c: Vector2i) -> bool:
	return c.x >= cell.x and c.y >= cell.y and c.x < cell.x + w and c.y < cell.y + h


func take_power_damage(milli: int) -> void:
	power_cur = maxi(0, power_cur - milli)


func take_armor_damage(milli: int) -> void:
	armor_cur = maxi(0, armor_cur - milli)
