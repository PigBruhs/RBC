# ══════════════════════════════════════════════════════════════════════════════
# 关卡定义（地形 + 出生点 + 相机）
#
# 用户口径：
#   · 现有测试场保留，另外新增「皇室竞技场」；调试页里切换。
#   · 竞技场 21×41，前后左右对称，相机垂直于宽面、沿长轴看。
#   · 中间一道 3 格宽、21 格长的河：角色走不进去、不拦投掷物，
#     炮弹/召唤球落进河里直接消失。
#   · 两座宽 2 格的桥（左起 4 格、右起 4 格），桥就是正常地板。
#   · 双方老国王居中在两条宽边上；**一边两个公主**，在国王前方 3 格、左右各 5 格，
#     左右是相对摄像机看过去的方向（lateral 一律给"屏幕右方"）。
#     三个英雄出生/复活在两公主之间的固定三格（由这里的几何推出来，两边对称）。
#
# 出生点推导（每边只需要给国王的位置和朝向）：
#   pad_left  = king + forward*3 - lateral*5      （lateral = 屏幕右）
#   pad_right = king + forward*3 + lateral*5
#   hero      = king + forward*3 + lateral*{-1, 0, +1}
# ══════════════════════════════════════════════════════════════════════════════
class_name Level
extends RefCounted

## 当前关卡 id。**静态**：场景 reload 之后还记得，调试页切关卡就是改它。
static var current: String = "field"

const DEFS := {
	"field": {
		"name": "测试场 48×48",
		# 名字要**短**：它会直接做调试面板里的按钮文字，而面板只有 308px 宽。
		# 详细尺寸放进 `desc`（按钮 tooltip 用），别把描述塞进 name。
		"desc": "全图 48×48，双方满编 + 三个假人靶子",
		"gw": 48, "gh": 48,
		"play": [0, 0, 48, 48],                 # 可行动区域 = 整张图
		"cam_yaw": 225.0,                       # 对角俯视：玩家那一方落在屏幕【左下方】
		"player": {"king": Vector2i(2, 20), "forward": Vector2i(1, 0), "lateral": Vector2i(0, -1)},
		"enemy": {"king": Vector2i(45, 20), "forward": Vector2i(-1, 0), "lateral": Vector2i(0, -1)},
		# 三个假人靶子（夹在两军中间）
		"dummies": [Vector2i(21, 8), Vector2i(21, 11), Vector2i(21, 14)],
		# 英雄【出生点 = 重生点】：没有河，就用地图正中那条线两侧各三格
		"spawn": {
			"player": [Vector2i(23, 23), Vector2i(24, 23), Vector2i(25, 23)],
			"enemy": [Vector2i(23, 25), Vector2i(24, 25), Vector2i(25, 25)],
		},
		# 本场景有哪些角色、各自在哪（花名册只放定义，场景自己决定出场名单）
		"roster": [
			["Gerald", 0, 23, 23], ["Alette", 0, 24, 23], ["Airburst mortar", 0, 25, 23],
			["萨尼铁塔", 0, 22, 23], ["俯冲轰炸直升机（不要问那么多）", 0, 21, 23], ["老国王", 0, 2, 20],
			["公主·左", 0, 5, 25], ["公主·右", 0, 5, 15],
			["Dummy Melee", 1, 21, 8], ["Dummy Ranged", 1, 21, 11], ["Dummy Thrower", 1, 21, 14],
			["Gerald (E)", 1, 23, 25], ["Alette (E)", 1, 24, 25], ["Airburst mortar (E)", 1, 25, 25],
			["萨尼铁塔 (E)", 1, 22, 25], ["俯冲轰炸直升机（不要问那么多） (E)", 1, 21, 25], ["老国王 (E)", 1, 45, 20],
			["公主·左 (E)", 1, 42, 25], ["公主·右 (E)", 1, 42, 15],
		],
		# 重生回合（第 100 轮用户口径）：**直升机 20 回合，其余角色 15 回合**
		"respawn_default": 15,
		"respawn_turns": {"俯冲轰炸直升机（不要问那么多）": 20},
		"river_rows": [],                       # 没有河
		"bridge_cols": [],
		# 胜负条件（各场景独立声明；这里是测试场）
		"victory": {"type": "king"},
	},
	"arena": {
		"name": "皇室竞技场",
		"desc": "可行动 21×41（四周 100×100 空场），中间一条 3 格宽的河 + 两座桥",
		# 用户口径（第 83 轮）：物理边界扩到 100×100，所以炮弹不会再"飞出竞技场就消失"；
		# 但**只有 play 这块矩形是有格子的**（能走、能放、能画地形），外面是空场：
		# 没有格子划分，炮弹照飞、照常触发碰撞，枪榴弹/信标落进去则作废。
		"gw": 100, "gh": 100,
		"play": [0, 0, 21, 41],                 # 真正的竞技场：x 0~20、y 0~40（和以前完全一样）
		"cam_yaw": 225.0,                       # 和测试场同一个角度（玩家在左下方）
		"player": {"king": Vector2i(10, 0), "forward": Vector2i(0, 1), "lateral": Vector2i(1, 0)},
		"enemy": {"king": Vector2i(10, 40), "forward": Vector2i(0, -1), "lateral": Vector2i(1, 0)},
		# 假人只出现在测试场（用户口径：竞技场没有假人）
		"dummies": [],
		# 英雄【重生点】（用户口径第 86/87 轮）：**老国王前方 3 格那一行**，三格彼此间隔一个、
		# 整体居中在两个公主之间。开局的出场位置仍由 roster 决定（在河边）——
		# 两者是分开的：竞技场重生 = 国王面前，出场 = 河边。
		"spawn": {
			"player": [Vector2i(8, 3), Vector2i(10, 3), Vector2i(12, 3)],
			"enemy": [Vector2i(8, 37), Vector2i(10, 37), Vector2i(12, 37)],
		},
		# 本场景有哪些角色、各自在哪（没有假人）
		"roster": [
			["Gerald", 0, 9, 18], ["Alette", 0, 10, 18], ["Airburst mortar", 0, 11, 18],
			["萨尼铁塔", 0, 8, 18], ["俯冲轰炸直升机（不要问那么多）", 0, 12, 18], ["老国王", 0, 10, 0],
			["公主·左", 0, 5, 3], ["公主·右", 0, 15, 3],
			# 第 104 轮新角色：轮式齐射午餐盒（**玩家侧**，人类试玩用）。
			# 它占 1×2（碰撞体沿 +y 排），所以 (13,17) 那一行 = 占 (13,17)+(13,18)：
			#   · 与直升机 (12,18) **相邻不重叠**（x 不同）；y=17/18 都不在河 river_rows 里。
			["轮式齐射午餐盒", 0, 13, 17],
			["Gerald (E)", 1, 9, 22], ["Alette (E)", 1, 10, 22], ["Airburst mortar (E)", 1, 11, 22],
			["萨尼铁塔 (E)", 1, 8, 22], ["俯冲轰炸直升机（不要问那么多） (E)", 1, 12, 22], ["老国王 (E)", 1, 10, 40],
			["公主·左 (E)", 1, 5, 37], ["公主·右 (E)", 1, 15, 37],
		],
		# 场景特有的重生回合数 + 统一口径（第 100 轮用户口径）：
		# **所有场景**都是「直升机 20 回合、其余角色 15 回合」
		"respawn_default": 15,
		"respawn_turns": {"俯冲轰炸直升机（不要问那么多）": 20},
		"river_rows": [19, 20, 21],             # 3 格宽、跨满 21 格
		"bridge_cols": [[4, 5], [15, 16]],      # 左起 4 格 / 右起 4 格，各宽 2
		# 胜负条件（各场景独立声明；这里与测试场同为"击毙对方老国王"）
		# 换玩法只改这一行，例如：
		#   {"type": "annihilate"}                                  一方全灭即分胜负
		#   {"type": "king", "also": [{"type": "survive", "rounds": 20, "side": 1}]}
		#                                                           我方 20 个回合内没被打死也算赢
		#   {"type": "reach", "side": 0, "cells": [Vector2i(10, 20)]} 我方有人站到 (10,20) 即胜
		"victory": {"type": "king"},
	},
	# ══════════════════════════════════════════════════════════════════════════
	# Reaper 战（第 99 轮）—— 第一个 Boss 关
	#   · 物理边界 100×100；**可到达格子 65×81**（play 矩形）
	#   · 左边尽头与皇室竞技场一致：玩家老国王 + 两个公主 + 对应的五个重生点
	#   · 最右边是 Reaper 和三个重生点
	#   · 胜负：**玩家老国王死 = 败；Reaper 死 = 胜**（非对称，走 `victory.type = "boss"`）
	#   · 回合顺序：**一边所有角色行动完才轮到另一边**（`turn_mode = "by_side"`，只有本场景这样）
	# ══════════════════════════════════════════════════════════════════════════
	"reaper": {
		"name": "Reaper 战",
		"desc": "可行动 41×65（四周 100×100 空场）。第一个 Boss 关：击毙 Reaper 通关，老国王阵亡即失败；双方斜对角（玩家左下 / 敌方右上），敌方出生点在 Reaper 前方 7 格",
		"gw": 100, "gh": 100,
		# 用户口径（第 102/103 轮）：**可到达区 65×81 -> 41×81 -> 41×65**（物理边界仍是 100×100）。
		# x 0~40、y 0~64。
		"play": [0, 0, 41, 65],
		"cam_yaw": 225.0,                       # 与竞技场同一个角度（玩家在左下方）
		# 用户口径（第 102 轮）：**初始位置排在长的两端 —— 左下角和右上角**。
		# 本关"长"是纵向 81，两端即左下角 / 右上角 -> 双方沿**对角**摆（不再是左右各占一端）：
		#   玩家（老国王 + 2 公主 + 5 英雄）在**左下角**，forward 指向右上 (1,1)；
		#   敌方（Reaper）在**右上角**，forward 指向左下 (-1,-1)。
		# lateral 取 forward 的垂向 (1,-1)，两侧展开都还在 41×81 内。
		# ⚠ Reaper 的 body_r = 3：站在 (36,60) -> 右边界 36+3=39 ≤ 40、上边界 60+3=63 ≤ 64，都不出界（留 1 格余量）。
		"player": {"king": Vector2i(4, 4), "forward": Vector2i(1, 1), "lateral": Vector2i(1, -1)},
		"enemy": {"king": Vector2i(36, 60), "forward": Vector2i(-1, -1), "lateral": Vector2i(1, -1)},
		"dummies": [],
		# 玩家【五个英雄的重生点】（用户口径「对应的五个重生的」）——
		# 左下角、老国王前方 2 格那一行，沿 lateral 两侧各两格居中排开。
		# ⚠ 必须真的有英雄：**老国王与公主都是 no_turn**，玩家侧若只有他们俩，
		#   队列里就一个可行动单位都没有 → Reaper 会直接先手连动（实测过）。
		"spawn": {
			# 老国王 (4,4) + forward(1,1)*2 = (6,6)，沿 lateral(1,-1) 展开 -2..+2
			"player": [Vector2i(4, 8), Vector2i(5, 7), Vector2i(6, 6),
				Vector2i(7, 5), Vector2i(8, 4)],
			# 用户口径（第 102 轮）：敌**三个**出生点放在 **Reaper 前方 7 格**。
			# Reaper 在 (36,60)、forward = (-1,-1)：沿对角走 5 步 = (31,55)，
			# 与 Reaper 中心 (36.5,60.5) 的距离 = √(5²+5²) ≈ 7.07 > body_r(3) + 0.5 ✅
			# 所以不会再生成在它 6 格宽的身体底下。沿 lateral(1,-1) 展开 -1..+1 -> 3 个点。
			"enemy": [Vector2i(30, 56), Vector2i(31, 55), Vector2i(32, 54)],
		},
		# 出场名单：玩家方 = 老国王 + 两个公主 + **五个英雄**；
		# 敌方 = 只有 Reaper（它的召唤物由它自己的召唤回合产生）。
		"roster": [
			# 玩家：左下角。老国王 (4,4)；两位公主 = king + forward*3 ± lateral*5（与 Level.pad_cells 同一口径，
			# 五个英雄在老国王前方 7 格 = (11,11) 那一行（沿 lateral 展开 -2..+2）。
			["老国王", 0, 4, 4],
			["公主·左", 0, 2, 12], ["公主·右", 0, 12, 2],
			["Gerald", 0, 9, 13], ["Alette", 0, 10, 12], ["Airburst mortar", 0, 11, 11],
			["萨尼铁塔", 0, 12, 10], ["俯冲轰炸直升机（不要问那么多）", 0, 13, 9],
			# 第 104 轮新角色：轮式齐射午餐盒（玩家侧）。占 1×2 -> (14,8)+(14,9)：
			#   · 沿"x+y=22"那条英雄斜线再往外一格，与直升机 (13,9) **相邻不重叠**
			#   · x≤40、y≤64 都在 play 区内；本关没有河。
			["轮式齐射午餐盒", 0, 14, 8],
			# 敌方：右上角（Reaper 单挑，召唤物由它自己的召唤回合产生）
			["Reaper", 1, 36, 60],
		],
		# 重生回合（第 100 轮用户口径）：**直升机 20 回合，其余角色 15 回合**
		"respawn_default": 15,
		"respawn_turns": {"俯冲轰炸直升机（不要问那么多）": 20},
		"river_rows": [],
		"bridge_cols": [],
		# 胜负条件：非对称（玩家老国王死 = 败；Reaper 死 = 胜）
		"victory": {"type": "boss", "boss_name": "Reaper", "king_side": 0},
		# 回合顺序：一边所有角色行动完才轮到另一边（**只有本场景这样**）
		"turn_mode": "by_side",
	},
}


## 本场景的出场名单：[角色名, 阵营(0我方/1敌方), x, y]
## 花名册（UnitData.UNITS/ENEMIES）只放"定义"，场景决定"谁出场、站哪"——
## 所以不是每个场景都得有所有角色。
static func roster(id: String = "") -> Array:
	return def(id).get("roster", [])


static func ids() -> Array[String]:
	var out: Array[String] = []
	for k in DEFS.keys():
		out.append(String(k))
	return out


static func def(id: String = "") -> Dictionary:
	var key := id if id != "" else current
	return DEFS.get(key, DEFS["field"])


static func name_of(id: String = "") -> String:
	return String(def(id).get("name", id))


## 一句话描述（调试面板的按钮 tooltip 用）。名字要短、详细尺寸放这儿。
static func desc_of(id: String = "") -> String:
	return String(def(id).get("desc", ""))


static func gw(id: String = "") -> int:
	return int(def(id).get("gw", 48))


static func gh(id: String = "") -> int:
	return int(def(id).get("gh", 48))


## ── 胜负条件（用户口径第 97 轮：**写进场景元数据，各场景相互独立**）────────────
## 每个场景在 DEFS 里写一行 `"victory": {...}`；不写则用缺省的「一方老国王阵亡」。
## 可用的 type 与字段见 `core/turn_flow.gd` 顶部（king / annihilate / survive / reach），
## 判定是纯函数 `TurnFlow.check()`，所以加场景不用改任何场景侧代码。
const VICTORY_DEFAULT := {"type": "king"}


static func victory(id: String = "") -> Dictionary:
	var v: Dictionary = def(id).get("victory", {})
	return VICTORY_DEFAULT.duplicate() if v.is_empty() else v


## 这个场景的胜利条件用一句话怎么说（调试面板 / 胜者界面用）
static func victory_text(id: String = "") -> String:
	var v := victory(id)
	match String(v.get("type", "king")):
		"annihilate":
			return "消灭对方全部可行动单位"
		"survive":
			return "守满 %d 个回合" % int(v.get("rounds", 0))
		"reach":
			return "抵达目标格"
		"boss":
			return "击毙 %s" % String(v.get("boss_name", "Boss"))
		_:
			return "击毙对方老国王"


## ── 回合顺序模式（第 99 轮，用户口径）────────────────────────────────────────
## 用户原话：「一边所有角色进行完回合才轮到另一边；**只有这个场景是这样的**」——
## 所以它是**场景元数据**（`turn_mode`），不是全局改动：没声明 = 严格交替（既有行为）。
##   "alternate"（缺省）一个人行动完就换边
##   "by_side"           一边所有角色都行动完，才轮到另一边
static func turn_mode(id: String = "") -> String:
	return String(def(id).get("turn_mode", TurnQueue.MODE_ALTERNATE))


## ── 可行动区域（用户口径第 83 轮）────────────────────────────────────────────
## 返回 [x0, y0, w, h]（格）。兵、地形、路径、各种高亮都只在这个矩形里；
## 矩形之外是"空场"：没有格子划分，但炮弹可以飞过去、也能正常触发碰撞。
## 默认 = 整张图（测试场就是这样），竞技场把它设成真正的 21×41。
static func play_rect(id: String = "") -> Array:
	var r: Array = def(id).get("play", [])
	if r.size() == 4:
		return [int(r[0]), int(r[1]), int(r[2]), int(r[3])]
	return [0, 0, gw(id), gh(id)]


static func play_x0(id: String = "") -> int:
	return int(play_rect(id)[0])


static func play_y0(id: String = "") -> int:
	return int(play_rect(id)[1])


static func play_w(id: String = "") -> int:
	return int(play_rect(id)[2])


static func play_h(id: String = "") -> int:
	return int(play_rect(id)[3])


## 这个格在可行动区域里吗（= 有格子划分）
static func in_play(cell: Vector2i, id: String = "") -> bool:
	var r := play_rect(id)
	return cell.x >= int(r[0]) and cell.y >= int(r[1]) \
		and cell.x < int(r[0]) + int(r[2]) and cell.y < int(r[1]) + int(r[3])


## 空场（可行动区域之外）：没有格子，但炮弹照飞照炸
static func is_void(cell: Vector2i, id: String = "") -> bool:
	return not in_play(cell, id)


## 相机注视的中心点 = 可行动区域的中心 —— 所以扩了空场以后相机**一动不动**
static func cam_center(id: String = "") -> Vector2:
	var r := play_rect(id)
	return Vector2(float(r[0]) + float(r[2]) * 0.5, float(r[1]) + float(r[3]) * 0.5)


static func cam_yaw(id: String = "") -> float:
	return float(def(id).get("cam_yaw", 45.0))


static func king_cell(side: int, id: String = "") -> Vector2i:
	var d: Dictionary = def(id).get("player" if side == UnitData.Side.PLAYER else "enemy", {})
	return d.get("king", Vector2i(2, 2))


## 两个公主的格子：[屏幕左, 屏幕右]
static func pad_cells(side: int, id: String = "") -> Array[Vector2i]:
	var d: Dictionary = def(id).get("player" if side == UnitData.Side.PLAYER else "enemy", {})
	var king: Vector2i = d.get("king", Vector2i(2, 2))
	var fwd: Vector2i = d.get("forward", Vector2i(1, 0))
	var lat: Vector2i = d.get("lateral", Vector2i(0, 1))
	var mid: Vector2i = king + fwd * 3
	return [mid - lat * 5, mid + lat * 5]          # [左, 右]（lat = 屏幕右）


## 三个英雄的【出生点】= 关卡给的固定三格（用户口径：河两岸紧贴河沿居中，两边各一套）
static func hero_cells(side: int, id: String = "") -> Array[Vector2i]:
	var d: Dictionary = def(id)
	var sp: Dictionary = d.get("spawn", {})
	var key := "player" if side == UnitData.Side.PLAYER else "enemy"
	if sp.has(key):
		var out: Array[Vector2i] = []
		for c in sp[key]:
			out.append(c)
		return out
	# 兜底：按国王位置推（国王前方 3 格、左右各 1 格）
	var kd: Dictionary = d.get(key, {})
	var king: Vector2i = kd.get("king", Vector2i(2, 2))
	var fwd: Vector2i = kd.get("forward", Vector2i(1, 0))
	var lat: Vector2i = kd.get("lateral", Vector2i(0, 1))
	var mid: Vector2i = king + fwd * 3
	return [mid - lat, mid, mid + lat]


## 英雄【重生点】：和出生点同一处（关卡数据里的 spawn）。
## 注意（第 87 轮 bug）：**复活时优先用这里的格子**，home_cell（开局的出场格）只是兜底 ——
## 以前先试 home_cell，竞技场里那就是河边，于是关卡数据怎么改都没用。
static func respawn_cells(side: int, id: String = "") -> Array:
	return hero_cells(side, id)


## 这个角色在本场景要等几个回合重生。
## 优先看本场景的 `respawn_turns` 精确匹配（再退到基础名，敌方镜像 "… (E)" 靠它命中）；
## 没有就退回本场景的 `respawn_default`；再没有才用全局缺省 `GameMaster.HERO_REVIVE_TURNS`。
## 第 100 轮用户口径：**所有场景**统一为「直升机 20 回合、其余角色 15 回合」——
## 所以每个场景都显式写了 `respawn_default: 15` + 直升机 20，不再靠全局那个 10。
static func respawn_turns(unit_name: String, id: String = "") -> int:
	var d: Dictionary = def(id)
	var m: Dictionary = d.get("respawn_turns", {})
	if m.has(unit_name):
		return int(m[unit_name])
	var base := Unit.base_name(unit_name)          # 敌方镜像 "… (E)" 靠基础名命中
	if m.has(base):
		return int(m[base])
	if d.has("respawn_default"):
		return int(d["respawn_default"])
	return GameMaster.HERO_REVIVE_TURNS


## 直升机的场景参数（缺省值写在代码里，关卡元数据可逐键覆盖）
const HELI_DEFAULTS := {
	"hover_h": 2.0,          # 稳定悬浮离地 2 格（移动中也 2 格）
	"move_mult": 2.0,        # 移动速度为一般角色两倍（数据行里已给 20 格）
	"basic_cost": 4,         # 普攻（吊射 37mm 火箭）精力消耗
	"aim_mult": 2.0,         # 瞄准结果翻倍：先前飞 x 格，现在 2x
	"salvo_pairs": 8,        # 一共八次齐射（第 93 轮：4 -> 8）
	"salvo_gap": 0.5,        # 每次间隔 0.5 秒（第 83 轮 250ms -> 1s，第 95 轮 1s -> 0.5s）
	"scatter_r": 4.0,        # 落点：半径 4 格圆内随机（第 83 轮 4 -> 8，第 92 轮改回 4）
	"rockets": 16,           # 一共 16 发（8 波 × 左右各一发；第 93 轮随波次翻倍）
	"crash_threshold": 0,    # 坠机阈值：**力量池归零才坠机**（用户口径第 97 轮：原来的 21 = 半血自毁已删除）
	"crash_r": 2.5,          # 坠机炮击半径
	"crash_power": 20,
	"crash_break": 40,
	"crash_res": 0.5,        # 无视 50% 物抗
	## 俯冲轰炸的技能射程（用户口径第 110 轮：**20 -> 64 格**）。
	## ⚠️ 注意：这个键**目前没有任何读取者**（grep 全 `game/src` 只有这一行）——
	## 真正生效的射程是 `Skills.get_def("dive_bomb")["range_max"]`（`skills.gd` 里那条），
	## 被 `ai.gd`（挑目标）与 `skill_runner.gd` / `action_menu.gd`（高亮可选格）使用。
	## 所以"改射程"必须**两处一起**改（另一处在 Lead/mod-fx 的写区，已在报告里指出）；
	## 这里同步成同一个值，避免两个数字互相矛盾。
	"dive_range": 64.0,
	## 技能移动速度（爬升轰炸的**去程与返航**都用它：`air_runner.dive_tick` 的 up/back 两段）。
	## 用户口径第 110 轮：**技能时移速翻倍** -> 2.5 -> **5.0**（平飞/悬停速度不受影响）。
	"climb_speed": 5.0,
	## 爬升高度（第 103 轮：4 → **7**）。推导：投弹球的**球心离地 0.15 格**、半径 = drop_blast_r(6)
	## -> 竖直覆盖到 y = 6.15；直升机身体是圆柱 [body_h(), body_h()+1.0]，要整根都在球顶之上：
	##   climb_h + 1.0 > 6.15  =>  climb_h > 5.15  ->  取 7.0（整数、留 0.85 格余量）。
	## ⚠️ 改 drop_blast_r 必须重算这个不等式（run.gd 里有 `climb_h > 0.15 + drop_blast_r` 的断言）。
	"climb_h": 7.0,
	"drop_hold": 0.5,        # 到位后停 0.5 秒投弹（用户口径第 86 轮）
	## 投弹下落耗时（**纯动画时长**，不是物理：air_runner 用 Tween(TRANS_QUAD, EASE_IN) 把炸弹
	## 从投弹高度平滑拉到 y=0.15，并让直升机在 wait_bomb 阶段停在高空等这么久）。
	## 第 103 轮：4 → 7 格后，按"与旧值同一加速度"换算：a = 2×(4-0.15)/1.0² = 7.7 格/秒²
	## -> t = sqrt(2×(7-0.15)/7.7) ≈ **1.33 秒**（自由落体 t ∝ √h 的同一条曲线）。
	"bomb_fall_sec": 1.33,
	"drop_blast_r": 6.0,     # 投弹半径 6 格（三维球；第 103 轮：3 -> 6）
	"drop_power": 120,       # 力量伤害（第 103 轮：20 -> 120；走 Rules.resolve：先减护甲再过物抗）
	"drop_break": 40,        # 破甲伤害（第 103 轮 40，第 110 轮用户口径回到 **40**）
}


static func heli(id: String = "") -> Dictionary:
	var out := HELI_DEFAULTS.duplicate()
	for k in def(id).get("heli", {}).keys():
		out[k] = def(id).get("heli")[k]
	return out


static func dummy_cells(id: String = "") -> Array:
	return def(id).get("dummies", [])


## 这个格是不是水（河面，不含桥）。空场（可行动区域之外）永远不算水。
static func is_river(cell: Vector2i, id: String = "") -> bool:
	var d := def(id)
	var rows: Array = d.get("river_rows", [])
	if rows.is_empty():
		return false
	if not in_play(cell, id):
		return false                              # 空场没有格子，也就不可能是河
	if not rows.has(cell.y):
		return false
	for br in d.get("bridge_cols", []):
		var cols: Array = br
		if cols.size() >= 2 and cell.x >= int(cols[0]) and cell.x <= int(cols[1]):
			return false                          # 桥是正常地板
	return true


## 这个格是不是桥（河的那几行里、又不算水的格子 —— 用户口径：桥面铺金色）
static func is_bridge(cell: Vector2i, id: String = "") -> bool:
	var rows: Array = def(id).get("river_rows", [])
	return rows.has(cell.y) and not is_river(cell, id)


static func has_river(id: String = "") -> bool:
	return not (def(id).get("river_rows", []) as Array).is_empty()


## 河面覆盖的所有格子（只扫可行动区域，用于渲染/阻挡）
static func river_cells(id: String = "") -> Dictionary:
	var out := {}
	var d := def(id)
	var r := play_rect(id)
	for row in d.get("river_rows", []):
		for x in range(int(r[0]), int(r[0]) + int(r[2])):
			var c := Vector2i(x, int(row))
			if is_river(c, id):
				out[c] = true
	return out
