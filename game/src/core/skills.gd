# ══════════════════════════════════════════════════════════════════════════════
# 技能表（v1：目前只有 Gerald 的「轨道空爆打击」）
#
# 每个技能声明自己的类型、消耗与参数；战斗场景按 kind 分派表现。
# 技能用"tag"把效果延后到下一个回合 —— 例如轨道空爆打击：
#   · 本回合：瞄准 -> 扔出一枚小球 -> 落点竖起紫色光柱 -> 回合结束
#   · 给施法者打上 tag
#   · 下一次轮到施法者时：先放轨道炮击动画（5 发），然后才正常开始他的回合
# ══════════════════════════════════════════════════════════════════════════════
class_name Skills
extends RefCounted

## 用 tag 记录"下一次自己回合开始时要先结算什么"
const TAG_ORBITAL := "orbital_incoming"

## ── 技能的两个正交属性（用户要求：玩家路径与 AI 路径必须是同一条生产线）──────
## cast：施放方式（battle_scene._perform_skill 按它分派，只此一处）
##   "self"    不需要瞄准，点一下就用（哨兵）
##   "cell"    点一格（俯冲轰炸）
##   "drag"    拖拽瞄准后松手（投掷类）
## aim：UI 该怎么让玩家选目标（battle_scene._choose_skill 按它分派）
##   "self" / "cell" / "drag"
## 加新技能 = DEFS 加一条（带 cast/aim）+ 一个 cast 实现，玩家与 AI 自动同步。
const CAST_SENTRY := "sentry"
const CAST_DIVE := "dive"
const CAST_CARPET := "carpet"
const CAST_GRENADE := "grenade"
const CAST_MARKER := "marker"
const CAST_LOITER := "loiter"                        # 第 104 轮：巡飞弹（午餐盒的技能）
const CAST_ALL := [CAST_SENTRY, CAST_DIVE, CAST_CARPET, CAST_GRENADE, CAST_MARKER, CAST_LOITER]

const AIM_SELF := "self"
const AIM_CELL := "cell"
const AIM_DRAG := "drag"
const AIM_UNIT := "unit"                             # 第 104 轮：点一个**角色**（巡飞弹选目标）
const AIM_ALL := [AIM_SELF, AIM_CELL, AIM_DRAG, AIM_UNIT]

## 技能定义。key = 技能 id
const DEFS := {
	"dive_bomb": {
		"id": "dive_bomb",
		"name": "俯冲轰炸",
		"owner": "俯冲轰炸直升机（不要问那么多）",
		"cost": 6,                               # 用户口径：6 精力
		"kind": "marker",                        # 与投掷手同款拖拽瞄准；dive=true 时不投掷物，只落指示点
		"dive": true,
		"cast": CAST_DIVE,                       # 施放方式：点一格 -> 进入准备状态
		"aim": AIM_CELL,                         # 瞄准方式：直接点 0~20 格内的一格（不拖拽、不投标记球）
		"desc": "选定 20 格以内的一格作为目标，直升机进入准备状态。"
			+ "下一次轮到它的回合时会以 6 格/秒俯冲过去（高度 2 → 0.5 格），"
			+ "途中受伤可能触发坠机；抵达后停 0.5 秒投下一枚威力巨大的炸弹（半径 3 格、"
			+ "40 破甲 + 20 力量、不触发哨兵），随后原路返回。",
		"range_max": 20.0,
	},
	"grenade_launcher": {
		"id": "grenade_launcher",
		"name": "枪榴弹",
		"owner": "萨尼铁塔",                     # 她本人与敌方镜像都有
		"cost": 2,
		"kind": "marker",                        # 与投掷手同款：拖拽瞄准 + 抛物线
		"grenade": true,                         # 但落下去的是手榴弹（不召唤炮击）
		"cast": CAST_GRENADE,
		"aim": AIM_DRAG,
		"desc": "朝指定地点抛出一枚手榴弹。空中阶段按炮弹处理：会惊动哨兵、可被箭击落。"
			+ "落地后只是模型（不可交互），4 个回合后爆炸，向 12 个随机方向各射出一枚破片，"
			+ "破片不分敌我（会伤到自己人）。",
		"range_min": 3.0,                        # 与投掷手完全一致
		"range_max": 20.0,
		"delay_turns": 4,                        # GM 计时：4 个回合边界后爆炸
		"fragments": 12,                         # 一共 12 枚破片（第 98 轮：8 -> 12）
	},
	"orbital_strike": {
		"id": "orbital_strike",
		"name": "轨道空爆打击",
		"owner": "Gerald",                       # 用户口径：轨道空爆是杰拉尔德的技能
		"cost": 2,                               # 精力消耗（用户口径：回到 2）
		"kind": "marker",                        # marker = 先扔标记球，下回合召唤炮击
		"cast": CAST_MARKER,
		"aim": AIM_DRAG,
		"tag": TAG_ORBITAL,
		"desc": "向指定地点投出一枚轨道标记。5 个回合后，轨道火力将在该点周围 3 格"
			+ "（外圈直径 6 格）内随机落下 5 发炮弹；每发的作用范围是直径 3 格的圆。"
			+ "每发造成 12 点破甲与 12 点力量伤害，并无视 50% 物理抗性。炮弹不分敌我。",
		# 落点范围（与投掷手完全一致）
		"range_min": 3.0,
		"range_max": 20.0,
		# 后续炮击参数
		"marker_radius": 3.0,                    # 炮弹【散布】半径 3 格（= 外圈直径 6）
		"shells": 5,                             # 炮弹数量
		"shell_break": 12,                       # 每发破甲
		"shell_power": 12,                       # 每发力量伤害（固定值，不吃攻方力量）
		"shell_ignore_res": 0.5,                 # 无视 50% 物抗
		"delay_turns": 5,                        # 施法后还要等 5 个回合才落下（施法回合不算）
		"impact_radius": 1.5,                    # 每发的作用范围：直径 3 格（= 投掷手普攻同款）
		"shell_fall_sec": 0.5,                   # 单发下落时间（下落速度 +100%）
		"shell_gap_sec": 0.2,                    # 两发之间的间隔（-50%）
	},
	"carpet_bomb": {
		"id": "carpet_bomb",
		"name": "地毯式轰炸",
		"owner": "Airburst mortar",              # 投掷手专属（空爆迫击炮）
		"cost": 6,                               # 精力消耗（用户口径：3 -> 6）
		"kind": "carpet",                        # carpet = 立即在矩形内撒 7 发炮弹
		"cast": CAST_CARPET,
		"aim": AIM_DRAG,
		"desc": "以落点为中心、沿飞行方向铺开一片 5 格宽 7 格长的轰炸区，"
			+ "在区内随机撒下 7 发炮弹，由近及远依次落地。"
			+ "每发炮弹的威力与投掷手普攻完全一致，不分敌我。",
		"range_min": 3.0,
		"range_max": 20.0,
		"rect_len": 7.0,                         # 沿飞行方向（中轴线）的长度
		"rect_width": 5.0,                       # 垂直方向的宽度
		"shells": 7,                             # 落点数量
		"min_gap": 0.2,                          # 任意两个落点的最小间距（格）
		"flight_sec": 1.0,                       # 单发炮弹飞行时间
		"gap_sec": 0.2,                          # 两发之间的起飞间隔
	},
	## 第 104 轮：轮式齐射午餐盒的技能 —— 车顶右半边那台巡飞弹发射器。
	## 用户口径："作为技能向选定的目标释放，目标必须在 32 格内；初始角度的随机范围与
	## 沙盒元素的巡飞弹发射器一致；技能耗费 12 点精力；记得设置安全引信，飞出去三格才开碰撞和近炸"。
	"loiter_launch": {
		"id": "loiter_launch",
		"name": "巡飞弹",
		"owner": "轮式齐射午餐盒",
		"cost": 12,                              # 用户口径：耗 12 点精力
		"kind": "loiter",                        # loiter = 朝选定目标放一枚巡飞弹（可 Q/E 制导）
		"cast": CAST_LOITER,
		# 瞄准方式：**拖拽**（复用既有 UI 流程）。用户口径是"向选定的目标释放"，
		# 但"点角色"这种选目标流程要改 action_menu/battle_ui（mod-fx 的写区），
		# 所以这里走拖拽：**落点附近 32 格内最近的那个敌人 = 选定的目标**
		# （见 `air_runner.launch_loiter_skill`）。
		"aim": AIM_UNIT,                          # 第 105 轮：点选一个敌方角色（不是拖拽落点）
		"desc": "朝 32 格内选定的敌人放出一枚巡飞弹。巡飞弹可以用 Q/E 左右制导，"
			+ "带安全引信（飞出去 3 格后才开碰撞与近炸），近炸引信半径 0.75 格，"
			+ "飞满 64 格自动引爆。爆炸是直径两格的三维球，不分敌我。",
		"range_min": 1.0,
		"range_max": 32.0,                       # 用户口径：目标必须在 32 格内
		"arm_dist": 3.0,                         # 安全引信：飞出去 3 格才武装
	},
	"sentry": {
		"id": "sentry",
		"name": "哨兵",
		"owner": "Alette",
		"cost": 2,                               # 精力消耗
		"kind": "sentry",                        # sentry = 进入警戒状态，不瞄准
		"cast": CAST_SENTRY,
		"aim": AIM_SELF,
		"desc": "进入警戒状态，持续到阿莱特的下一个回合开始。"
			+ "期间只要有敌对角色【从射界外进入射界】或【在射界内移动】，"
			+ "或有不分敌我的炮弹（土堆挡不住的那种，箭矢不算）飞入射界，"
			+ "阿莱特就会朝触发位置射出一支与普攻数据完全一致的箭。"
			+ "箭按物理飞行，命中靠碰撞判定，不保证打中。",
		"range_min": 1.0,
		"range_max": 8.0,
		"arrow_flight_sec": 0.9,                 # 哨兵箭的飞行时间（按距离缩放）
		"arrow_life_sec": 3.0,                   # 箭的寿命上限（用户要求）
	},
}


## 「地毯式轰炸」的落点约束：每个 5x1 长条里至少一个落点
static func carpet_bands(id: String) -> int:
	var d := get_def(id)
	if d.is_empty():
		return 0
	return int(float(d["rect_len"]))


## 地毯式轰炸的落点生成（纯几何 + 随机，便于单独测试）
##   center : 爆心（长方形的中心 = 瞄准落点）
##   dir    : 投掷手 -> 爆心 的方向 = 长方形的【中轴线】
##   返回   : 沿中轴线"由近及远"排好的若干落点
## 约束：
##   ① 长方形沿中轴线长 rect_len 格，垂直方向宽 rect_width 格
##   ② 沿中轴线切成 rect_len 个"宽 rect_width x 长 1"的长条，每条至少一个落点
##   ③ 任意两个落点的距离 >= min_gap
static func carpet_points(d: Dictionary, center: Vector2, dir: Vector2,
		rng: RngService) -> Array[Vector2]:
	var bands := int(float(d["rect_len"]))
	var half_w := float(d["rect_width"]) * 0.5
	var min_gap := float(d["min_gap"])
	var axis := dir.normalized()
	if axis.length() < 0.001:
		axis = Vector2.RIGHT
	var perp := Vector2(-axis.y, axis.x)
	var out: Array[Vector2] = []
	for b in bands:
		var t0 := float(b) - float(bands) * 0.5        # 0 号长条最靠近投掷手
		var t1 := t0 + 1.0
		var pick := center + axis * ((t0 + t1) * 0.5)
		var found := false
		for tries in 600:
			var along := t0 + _rand01(rng) * (t1 - t0)
			var across := (_rand01(rng) * 2.0 - 1.0) * half_w
			var q := center + axis * along + perp * across
			if _far_enough(q, out, min_gap):
				pick = q
				found = true
				break
		if not found:
			# 兜底：沿垂直方向左右微调，直到满足最小间距
			for i in 40:
				if _far_enough(pick, out, min_gap):
					break
				var s := 0.08 * float(i + 1)
				pick = center + axis * ((t0 + t1) * 0.5) + perp * (s if i % 2 == 0 else -s)
		out.append(pick)
	# 由近及远：按在（投掷手 -> 爆心）中轴线上的投影排序
	out.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		return (a - center).dot(axis) < (b - center).dot(axis))
	return out


static func _rand01(rng: RngService) -> float:
	return float(rng.next_int(100000)) / 100000.0


static func _far_enough(q: Vector2, out: Array[Vector2], min_gap: float) -> bool:
	for e in out:
		if q.distance_to(e) < min_gap:
			return false
	return true

static func get_def(id: String) -> Dictionary:
	return DEFS.get(id, {})


## 施放方式。老技能没写 cast 的话按 kind/标志位反推，保证向后兼容。
static func cast_of(id: String) -> String:
	var d := get_def(id)
	if d.is_empty():
		return ""
	var c := String(d.get("cast", ""))
	if c != "":
		return c
	match String(d.get("kind", "")):
		"carpet":
			return CAST_CARPET
		"sentry":
			return CAST_SENTRY
	if bool(d.get("dive", false)):
		return CAST_DIVE
	if bool(d.get("grenade", false)):
		return CAST_GRENADE
	return CAST_MARKER


## 瞄准方式（决定 UI 走哪条选目标流程）
static func aim_of(id: String) -> String:
	var d := get_def(id)
	if d.is_empty():
		return ""
	var a := String(d.get("aim", ""))
	if a != "":
		return a
	match cast_of(id):
		CAST_SENTRY:
			return AIM_SELF
		CAST_DIVE:
			return AIM_CELL
	return AIM_DRAG


## 自检用：所有技能的施放方式与瞄准方式都必须在这两张表里
static func unknown_casts() -> Array[String]:
	var out: Array[String] = []
	for k in DEFS:
		if not CAST_ALL.has(cast_of(String(k))) or not AIM_ALL.has(aim_of(String(k))):
			out.append(String(k))
	return out


## 技能的一行摘要（给按钮/详情面板用）
static func summary(id: String) -> String:
	var d := get_def(id)
	if d.is_empty():
		return ""
	return "%s（消耗 %d 精力）" % [d["name"], d["cost"]]


## 详细说明：名字 + 描述 + 关键数值（用户要求瞄准时在下方属性栏显示）
## 注意：%d%% 这种"数字+字面百分号"混写极易出错，所以拆成两段分别格式化。
static func detail_text(id: String) -> String:
	var d := get_def(id)
	if d.is_empty():
		return "（未定义技能）"
	var t := "[b][color=#d8a6ff]%s[/color][/b]  消耗 %d 精力\n" % [d["name"], d["cost"]]
	t += "%s\n" % d["desc"]
	if String(d.get("kind", "")) == "carpet":
		t += "[color=#ffd866]数值：[/color]射程 %d~%d 格 ｜ 轰炸区 %d×%d 格（中轴线对准落点）" % [
			int(d["range_min"]), int(d["range_max"]),
			int(d["rect_width"]), int(d["rect_len"])]
		t += "\n　　　炮弹 %d 发 ｜ 每发间隔 %.1f 秒 ｜ 落点最小间距 %.1f 格" % [
			int(d["shells"]), float(d["gap_sec"]), float(d["min_gap"])]
		t += "\n　　　每发威力 = 本人普攻（破甲 + 力量，无视 50% 物理抗性，不分敌我）"
		return t
	if String(d.get("kind", "")) == "sentry":
		t += "[color=#ffd866]数值：[/color]射界 %d~%d 格 ｜ 警戒持续到自己的下一个回合" % [
			int(d["range_min"]), int(d["range_max"])]
		t += "\n　　　触发：敌对角色入界 / 界内移动 ｜ 不分敌我的炮弹飞入"
		t += "\n　　　反应：射出一支普攻箭（按碰撞判定，可能打空）"
		return t
	# 枪榴弹：与轨道空爆共用"投掷"手感，但落地后是延时爆炸的手榴弹（字段完全不同）
	if bool(d.get("grenade", false)):
		t += "[color=#ffd866]数值：[/color]射程 %d~%d 格 ｜ 落地后 %d 个回合爆炸" % [
			int(d.get("range_min", 3)), int(d.get("range_max", 20)), int(d.get("delay_turns", 4))]
		t += "\n　　　爆炸向 8 个方向各射出一枚破片（破片不分敌我，会伤到自己人）"
		t += "\n　　　空中阶段按炮弹处理：会惊动哨兵、可能被箭击落"
		return t
	# 其余 kind == "marker" 的技能（轨道空爆）：字段一律带默认值，缺字段不再崩
	var ig := int(float(d.get("shell_ignore_res", 0.5)) * 100.0)
	t += "[color=#ffd866]数值：[/color]射程 %d~%d 格 ｜ 散布 直径 %.0f 格 ｜ 每发作用 直径 %.0f 格 ｜ 炮弹 %d 发" % [
		int(d.get("range_min", 3)), int(d.get("range_max", 20)),
		float(d.get("marker_radius", 3.0)) * 2.0,
		float(d.get("impact_radius", 1.5)) * 2.0, int(d.get("shells", 5))]
	t += "\n　　　每发 破甲 %d + 力量 %d ｜ 无视 %d%% 物理抗性 ｜ 爆炸半径 %.0f 格 ｜ 每发间隔 %.1f 秒" % [
		int(d.get("shell_break", 12)), int(d.get("shell_power", 12)), ig,
		float(d.get("impact_radius", 1.5)), float(d.get("shell_gap_sec", 0.2))]
	return t


## 某个单位有哪些技能可用。
## ① 带 role 的技能按【职业】发（投掷手专属：地毯式轰炸 / 轨道空爆打击 ——
##    用户口径：近战绝对不许用轨道空爆）
## ② 其余按【基础名】匹配，所以敌方镜像角色（Alette (E) 等）也有同样的技能。
static func skills_for(u: Unit) -> Array[String]:
	var out: Array[String] = []
	if u == null:
		return out
	var base := Unit.base_name(u.name)
	for k in DEFS:
		var d: Dictionary = DEFS[k]
		if d.has("role"):
			if int(d["role"]) == u.role:
				out.append(k)
			continue
		if String(d.get("owner", "")) == u.name or String(d.get("owner", "")) == base:
			out.append(k)
	return out
