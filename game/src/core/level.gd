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
		"river_rows": [],                       # 没有河
		"bridge_cols": [],
	},
	"arena": {
		"name": "皇室竞技场 21×41（四周 100×100 空场）",
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
			["Gerald (E)", 1, 9, 22], ["Alette (E)", 1, 10, 22], ["Airburst mortar (E)", 1, 11, 22],
			["萨尼铁塔 (E)", 1, 8, 22], ["俯冲轰炸直升机（不要问那么多） (E)", 1, 12, 22], ["老国王 (E)", 1, 10, 40],
			["公主·左 (E)", 1, 5, 37], ["公主·右 (E)", 1, 15, 37],
		],
		# 场景特有的重生回合数（缺省 = 10）
		"respawn_turns": {"俯冲轰炸直升机（不要问那么多）": 25},
		"river_rows": [19, 20, 21],             # 3 格宽、跨满 21 格
		"bridge_cols": [[4, 5], [15, 16]],      # 左起 4 格 / 右起 4 格，各宽 2
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


static func gw(id: String = "") -> int:
	return int(def(id).get("gw", 48))


static func gh(id: String = "") -> int:
	return int(def(id).get("gh", 48))


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


## 这个角色在本场景要等几个回合重生（场景元数据；缺省 10）
static func respawn_turns(unit_name: String, id: String = "") -> int:
	var m: Dictionary = def(id).get("respawn_turns", {})
	if m.has(unit_name):
		return int(m[unit_name])
	var base := Unit.base_name(unit_name)          # 敌方镜像 "… (E)" 靠基础名命中
	if m.has(base):
		return int(m[base])
	return GameMaster.HERO_REVIVE_TURNS


## 直升机的场景参数（缺省值写在代码里，关卡元数据可逐键覆盖）
const HELI_DEFAULTS := {
	"hover_h": 2.0,          # 稳定悬浮离地 2 格（移动中也 2 格）
	"move_mult": 2.0,        # 移动速度为一般角色两倍（数据行里已给 20 格）
	"basic_cost": 4,         # 普攻（吊射 37mm 火箭）精力消耗
	"aim_mult": 2.0,         # 瞄准结果翻倍：先前飞 x 格，现在 2x
	"salvo_pairs": 4,        # 一共四次
	"salvo_gap": 1.0,        # 每次间隔 1 秒（用户口径第 83 轮：250ms -> 1s）
	"scatter_r": 8.0,        # 落点：半径 8 格圆内随机（用户口径第 83 轮：4 -> 8，散布翻倍）
	"rockets": 8,            # 一共 8 发
	"crash_threshold": 21,   # 力量低于 21 坠机
	"crash_r": 2.5,          # 坠机炮击半径
	"crash_power": 20,
	"crash_break": 40,
	"crash_res": 0.5,        # 无视 50% 物抗
	"dive_range": 20.0,      # 俯冲目标格最远 20 格
	"climb_speed": 2.5,      # 技能移动速度 = 悬停移动速度 2.5 格/秒（用户口径第 86 轮）
	"climb_h": 4.0,          # 爬升到 4 格再投弹（投弹是三维球判定，4 格以上炸不到自己）
	"drop_hold": 0.5,        # 到位后停 0.5 秒投弹（用户口径第 86 轮）
	"bomb_fall_sec": 1.0,    # 投弹下落耗时 1 秒（用户口径第 86 轮）
	"drop_blast_r": 3.0,     # 投弹半径 3 格（三维球）
	"drop_power": 20,
	"drop_break": 40,
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
