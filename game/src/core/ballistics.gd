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
			or kind == Projectile.KIND_FRAGMENT:
		# 木刺 block_ranged=false -> 不拦；土堆 block_ranged=true -> 一定拦
		# （用户强调：不看箭矢是否"碰撞"到它，只看是否从它上空飞过）
		return Block.ALWAYS if pl.block_ranged else Block.NEVER
	# 炮弹 / 召唤球：抛物线，土堆挡不住
	return Block.NEVER


## 这一发是不是"直接命中型"（撞到角色就算命中：箭矢 / 加农炮弹）
static func is_direct_hit(kind: String) -> bool:
	return kind == Projectile.KIND_ARROW or kind == Projectile.KIND_CANNON \
		or kind == Projectile.KIND_FRAGMENT


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
