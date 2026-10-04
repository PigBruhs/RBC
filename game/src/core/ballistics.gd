# ══════════════════════════════════════════════════════════════════════════════
# 弹道规则表 —— **谁能拦截谁，只在这里定义**
#
# 为什么要单独一个文件：
#   以前这些判断散在三处，改一处必漏另外两处，已经出过两次事故：
#     · battle_scene._arrow_hit_check   （箭矢 vs 沙盒道具）
#     · battle_scene._proj_collision    （弹道物互相击落）
#     · GameMaster.check_projectile     （谁能惊动哨兵）
#   现在全部收敛到这里，任何"谁能拦谁"的改动只改这一个文件。
#
# 用户口径（写死在下面的规则里，有断言锁着）：
#   · 木刺：无论箭矢是否"碰撞"到它，都不拦截（尖桩之间有缝，箭从上面过）
#   · 土堆：只要箭矢从它上空飞过就拦截（够高，挡住弹道）
#   · 投掷物（炮弹 / 召唤球）走抛物线，土堆挡不住
#   · 箭矢不惊动哨兵（否则"箭生箭"会指数爆炸）
#   · 炮弹 / 召唤球惊动哨兵，且不分敌我
#   · 激光（第 98 轮，第三种类型）：**光束**，不进 ProjectileField —— 不能被击落、
#     不惊动哨兵；只吃地形阻挡，且与箭矢同款（土堆拦、木刺不拦）。见 LASER_LIKE。
# ══════════════════════════════════════════════════════════════════════════════
class_name Ballistics
extends RefCounted

## 沙盒道具的拦截方式
enum Block { NEVER, ALWAYS, BY_HEIGHT }


## 某个沙盒道具会不会拦截这一类弹道物（按"弹道经过它所在格"判定）
static func placeable_block_mode(pl: Placeable, kind: String) -> int:
	if pl == null or not pl.is_alive():
		return Block.NEVER
	if kind == Projectile.KIND_ARROW or kind == Projectile.KIND_CANNON \
			or kind == Projectile.KIND_FRAGMENT or kind == Projectile.KIND_BULLET \
			or kind == Projectile.KIND_LASER:
		# 木刺 block_ranged=false -> 不拦；土堆 block_ranged=true -> 一定拦
		# （用户强调：不看箭矢是否"碰撞"到它，只看是否从它上空飞过）
		# 激光类同款（用户口径：激光"可以被木刺和土堆阻挡"——实际生效的是土堆，
		# 因为木刺的 block_ranged = false，这是既有数据口径，不改 bc_stat.md）。
		return Block.ALWAYS if pl.block_ranged else Block.NEVER
	# 炮弹 / 召唤球 / 手榴弹：抛物线，土堆挡不住
	return Block.NEVER


## 这一发是不是"直接命中型"（撞到角色就算命中：箭矢 / 加农炮弹）
static func is_direct_hit(kind: String) -> bool:
	return kind == Projectile.KIND_ARROW or kind == Projectile.KIND_CANNON \
		or kind == Projectile.KIND_FRAGMENT or kind == Projectile.KIND_BULLET


# ══════════════════════════════════════════════════════════════════════════════
# 【炮弹类】飞行物的统一模板（用户口径第 84 轮：这类东西一视同仁，别再一个个特判）
#
#   炮弹（迫击炮）/ 火箭（37mm）/ 枪榴弹 —— 三者共享同一套规则：
#     · 惊动哨兵（不分敌我）
#     · 可以被箭击落
#     · 被箭打掉（还在半空）-> 就地空爆
#     · 撞到角色（还没落地）-> **当成在命中处落地**，照常结算伤害（用户口径第 87 轮；
#       火箭还要撒破片）—— 以前这里被当成"被拦下"，火箭常常整发作废、落地没伤害。
#   唯一的例外是枪榴弹：它本来就"落地才炸"，所以撞到角色 = 在那个格子落地开始计时。
#   加一种新的炮弹 = 在 SHELL_LIKE 里加一行 + 工厂里调 shell_like_defaults()。
# ══════════════════════════════════════════════════════════════════════════════
const SHELL_LIKE := [Projectile.KIND_SHELL, Projectile.KIND_ROCKET, Projectile.KIND_GRENADE,
	Projectile.KIND_LOITER]


static func is_shell_class(kind: String) -> bool:
	return SHELL_LIKE.has(kind)


# ══════════════════════════════════════════════════════════════════════════════
# 【激光类】（用户口径第 98 轮 · Boss-1）：与箭矢类 / 炮弹类**同级**的第三种弹射物类型。
#
#   激光不是"飞过去命中"，而是"存在一段时间的光束"：逐物理帧累计帧伤、结束统一结算
#   （规则见 core/laser.gd，表现见 view/laser_beam.gd）。因为它根本不飞：
#     · 不能被任何东西击落（`intercept_result` = ""）
#     · 不惊动哨兵（`sentry_trigger` = false）
#     · 不参与"飞行中撞到角色"的判定（`body_impact` = ""）
#     · 挡不挡只看地形 —— 与箭矢**同一处口径**：土堆拦、木刺不拦
#   所以它只在下面这几张表里登记，不进 SHELL_LIKE、不进 shell_like_defaults()。
# ══════════════════════════════════════════════════════════════════════════════
const LASER_LIKE := [Projectile.KIND_LASER]


static func is_laser_class(kind: String) -> bool:
	return LASER_LIKE.has(kind)


## 这一类【在半空被箭打掉】时怎么收尾：
##   "burst"  -> 就地空爆（炮弹 / 火箭 / 巡飞弹）
##   ""       -> 整发作废、**模型直接消失**（枪榴弹 / 召唤球）
## 用户口径（第 96 轮）：枪榴弹被击落不再"就地落地" ——
##   以前它会在当前格立起弹体、登记 GM 计时、然后照样爆炸（打掉了还照炸）；
##   现在和轨道空爆的召唤球一样：打掉就是没了（不落地、不立模型、不计时、不爆炸）。
static func intercept_result(kind: String) -> String:
	if kind == Projectile.KIND_SHELL or kind == Projectile.KIND_ROCKET \
			or kind == Projectile.KIND_LOITER:
		return "burst"
	return ""


## 炮弹类飞行物的出厂默认值：命中标签 / 惊动哨兵 / 被击落时的收尾方式，只在这里定义一次
## ⚠️ 只对**炮弹类**有效：别的类型（激光 / 召唤球）调用它会拿到一份"什么都不吃"的空模板，
## 不会莫名其妙获得 `hit_tags = ["arrow"]`（那会让光束看起来"可以被箭击落"）。
static func shell_like_defaults(kind: String) -> Dictionary:
	if not is_shell_class(kind):
		return {"hit_tags": [], "sentry_trigger": false, "intercept": ""}
	return {
		"hit_tags": ["arrow"],                    # 可以被箭击落
		"sentry_trigger": true,                   # 惊动哨兵（不分敌我）
		"intercept": intercept_result(kind),
	}


## 飞行途中撞到角色会怎样：
##   "direct" -> 直接命中，按命中结算（箭矢 / 加农炮弹 / 破片 / 子弹）
##   "land"   -> **当成在命中处落地**（炮弹类：炮弹 / 火箭 / 枪榴弹）
##   ""       -> 不撞（召唤球：它只是个信标，穿过去）
static func body_impact(kind: String) -> String:
	if is_direct_hit(kind):
		return "direct"
	if is_shell_class(kind):
		return "land"
	return ""


static func placeable_blocks(pl: Placeable, kind: String) -> bool:
	return placeable_block_mode(pl, kind) == Block.ALWAYS


## 这一发能不能把另一发打掉（只有目标声明了自己怕什么）
static func can_shoot_down(shooter_kind: String, target: Projectile) -> bool:
	if target == null or not target.alive:
		return false
	return target.hit_tags.has(shooter_kind)


## 这一发进入哨兵射界时会不会惊动哨兵
static func triggers_sentry(p: Projectile) -> bool:
	return p != null and p.alive and p.sentry_trigger


## 两发弹道物"贴上了"的判定半径
static func touch_radius(a: Projectile, b: Projectile) -> float:
	return a.hit_r + b.hit_r
