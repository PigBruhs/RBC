# ══════════════════════════════════════════════════════════════════════════════
# 哨兵：表现与编排层（数据与算法仍然在 core/game_master.gd）
#
# 职责边界：
#   · GameMaster 持有哨兵的数据与规则：sentries 数组、Sentry / Shot、sentry_tick()
#   · 这里只负责"谁调用 tick、拿到 Shot 后怎么真的把箭生成出来、走路中如何采样锁定"
#   · 箭矢工厂 _spawn_arrow 留在 battle_scene：它同时服务远程普攻（测试也直接调它），
#     本模块通过宿主调用 _st._spawn_arrow(...)
#
# 宿主是 battle_scene（Node3D）。**故意用动态类型**：宿主提供的 gm / rng / _log /
# _spawn_arrow 是战场场景自己的成员，把 _st 静态标成 Node3D 会在编译期报
# "Cannot find member ... in base Node3D"（与 battle_ui.gd 的 host 同一处理方式）。
# _init 的参数仍然标 Node3D：接口契约不变，只是不做静态成员解析。
# ══════════════════════════════════════════════════════════════════════════════
class_name SentryRunner
extends RefCounted

## 哨兵瞄准球半径（用户口径第 93 轮：1 格 -> 2 格）。
## 刻意不引用 battle_scene 里的常量：反过来让 battle_scene 的
## SENTRY_AIM_BALL_R 指向这里，保证只有一份真值，也避免 class_name 互相循环引用。
const AIM_BALL_R := 2.0

var _st = null                 # 宿主（battle_scene）；动态类型见文件头


func _init(host: Node3D) -> void:
	_st = host


## 每帧：GM 的 FIFO 队列每 150ms 放出一支箭（不再有 200ms 延迟）。
## 一次一支、轮流瞄准：队头是谁就打谁此刻的位置，打完轮到队尾；
## 队头已经消失或飞出射界就剔除，接着看下一个。规则全在 GameMaster.sentry_tick 里。
func tick(delta: float) -> void:
	for sh in _st.gm.sentry_tick(delta):
		fire(sh)


## 放出一支哨兵箭（GM 的队列决定什么时候、打哪里）
func fire(sh: GameMaster.Shot) -> void:
	var a: Unit = sh.sentry.owner
	if a == null or not a.is_alive():
		return
	# 用户口径：不再瞄准对象当前位置，而是【以它当前位置为球心、半径 1 格的球内随机一点】
	# 用户口径：拦弹道物也吃同一套散布 —— 炮弹有速度，随机性正好允许"提前量"出现，多抽几次总有一次是对的
	var j := Spread.ball_offset(AIM_BALL_R, _st.rng)
	# 高度轴（第 83 轮）：瞄悬空单位要抬到它的身体中心；拦弹道物则瞄它当前飞行高度
	var aim := Vector3(sh.at.x + j.x, sh.y + j.y * 0.5, sh.at.y + j.z)
	_st._log("  🎯 哨兵射击（%s）：%s 实际位置 (%.2f, %.2f) → 瞄准 (%.2f, %.2f)｜队列剩余 %d" %
		[sh.reason, sh.target_name, sh.at.x, sh.at.y, aim.x, aim.z, _st.gm.sentry_queue_size()])
	_st._spawn_arrow(a, Vector3(float(a.cell.x) + 0.5, 0.75, float(a.cell.y) + 0.5),
		aim, null, false, false, true)


## 角色进入射界 -> 入队尾（真的射箭由 150ms 节奏的队列决定，不再"立刻一发"）
func lock(u: Unit, pos: Vector2) -> void:
	if _st.gm.check_unit(u, pos):
		_st._log("  🎯 哨兵锁定：%s 进入射界（队列 %d）" % [u.name, _st.gm.sentry_queue_size()])
