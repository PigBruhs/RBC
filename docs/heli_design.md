# 俯冲轰炸直升机（不要问那么多）—— 可施工设计稿

> 角色名就是 **`俯冲轰炸直升机（不要问那么多）`**：括号及其内容是**名字的一部分**，任何
> `base_name` / `owner` / 元数据 key 匹配都必须用全名。
> 套皮**投掷手**（`UnitData.Role.THROWER`，因此自动继承 `Passives.BY_ROLE` 的「装填」）。
>
> 本文只讲"怎么算、怎么切状态、接口长什么样"。数值来源见 `bc_stat.md`，已落地部分见
> `level.gd` / `unit_data.gd` 与 `docs/规格.md` 第十三节。
>
> **命名约定**：本文中出现的新标识符（`HeliMath`、`HeliState`、`Level.heli` 等）是**建议名**，
> 施工时可以换，但**语义与签名必须保持**，否则无头测试无法只测纯函数。
>
> 相关既有模块：`Ordnance`（弹药工厂 + 发射单）、`Projectile`（纯物理）、
> `Damage`（唯一结算入口）、`Combat.opts`（攻击特性）、`Ai.Ctx`（AI 世界快照）、
> `GameMaster`（回合边界 / 复活计时）、`Level`（场景元数据）。

---

## 0. 总览：需要新增/接入的接缝

| 需求 | 落点 | 形态 |
|---|---|---|
| 火箭变速 | `HeliMath`（新，纯静态） | `v(s)` / `t_of_s(s)` / `s_of_t(t)` |
| 火箭弹射物 | `Projectile.KIND_ROCKET` + `Ordnance.make_rocket()` | 距离参数化，不走 `dur` 匀速 |
| 8 发散布 | `HeliMath.spread_points()`（新，纯函数） | 半径 4 圆内 8 点，最小间距 |
| 普攻 | `Ordnance` 一发 8 枚火箭 + 发射单 `group` | 两枚齐射 ×4 波 ×250ms |
| 俯冲状态机 | `HeliState`（新，纯数据）+ `Unit` 上一个 `heli` 引用 | 5 状态，view 只做演出 |
| AI 可读接口 | `HeliState.is_ready()` / `HeliState.threatened_cells()` + `Ai.Ctx` 两个字段 | 纯函数，无头可测 |
| 关卡元数据 | `Level.DEFS[*].respawn_turns`（已落地）+ `Level.DEFS[*].heli`（新增） | 缺省回退常量 |
| 坠机 AOE | `Damage.blast(...)` + `Combat.opts` | `power` + `armor_break` + `ignore_res = 0.5` |

---

## 1. 火箭速度函数（飞行速度与飞行时间/距离正相关）

### 1.1 口径翻译

> 初始 **2 格/秒**；**飞满 12 格后到上限 6 格/秒**。

这是一个**一阶自治常微分方程**：速度只跟"已经飞了多远"有关，跟时间无关。

```
d s / d t = v(s) = min( V_MAX , V0 + a·s )        s = 已飞水平距离（格），t = 秒
V0 = 2.0 格/秒        V_MAX = 6.0 格/秒        S_RAMP = 12.0 格
```

**为什么取线性斜坡 `a = (V_MAX − V0) / S_RAMP = 4/12 = 1/3`**：
它让 `s = 12` 这一格**恰好**是斜坡与平台的交界点——
`v(12) = 2 + 12/3 = 6 = V_MAX`。于是"飞满 12 格后到上限"不是近似，而是**等式上的精确点**；
斜坡段唯一参数 `a` 由两个边界条件 `v(0)=2`、`v(12)=6` 唯一确定，没有自由度可调。

```gdscript
static func v(s: float) -> float:
	return minf(V_MAX, V0 + A * s)          # A = (V_MAX - V0) / S_RAMP = 1.0/3.0
```

### 1.2 闭式解（解析解）

对 `ds/dt = v(s)` 分离变量 `dt = ds / v(s)`，从 0 积到 s：

**① 斜坡段（0 ≤ s ≤ 12）**

```
t(s) = (1/a) · ln( (V0 + a·s) / V0 ) = 3 · ln(1 + s/6)          [a = 1/3]
```

反解（已知 t 求 s，施工时用这个）：

```
s(t) = (V0/a) · ( e^(a·t) − 1 ) = 6 · ( e^(t/3) − 1 )
v(t) = V0 · e^(a·t)             = 2 · e^(t/3)
```

**② 平台段（s ≥ 12）**

```
T_12 = t(12) = 3 · ln(3) ≈ 3.2958368660 秒          ← 常量，直接写成 const
s(t) = 12 + V_MAX · (t − T_12)
v(t) = V_MAX = 6
```

**统一入口（实现就写这个）**：

```gdscript
const V0 := 2.0
const V_MAX := 6.0
const S_RAMP := 12.0
const A := (V_MAX - V0) / S_RAMP                    # 1/3，编译期常量
const T_RAMP := 3.295836866004329                   # = ln(3)/A = 6·ln 3；也可写 log(3.0)/A

static func v(s: float) -> float:
	return V_MAX if s >= S_RAMP else V0 + A * s

## 飞过 s 格需要多少秒（距离 -> 时间）
static func t_of_s(s: float) -> float:
	if s <= S_RAMP:
		return log(1.0 + A * s / V0) / A            # = 3·ln(1 + s/6)
	return T_RAMP + (s - S_RAMP) / V_MAX

## t 秒后飞了多远（时间 -> 距离，逐帧推进用这个）
static func s_of_t(t: float) -> float:
	if t <= T_RAMP:
		return (V0 / A) * (exp(A * t) - 1.0)        # = 6·(e^(t/3) − 1)
	return S_RAMP + V_MAX * (t - T_RAMP)

## 已飞 s 格时的瞬时速度（= 逐帧积分用的右端项）
static func v_of_progress(s: float) -> float:
	return v(s)
```

### 1.3 数值表（解析解，已用 RK4 交叉验证）

| 已飞距离 s（格） | v(s)（格/秒） | 累计时间 t(s)（秒） | 该段耗时（秒） | 是否已达上限 |
|---:|---:|---:|---:|:--:|
| 0 | **2.0000** | 0.000000 | — | 否 |
| 4 | **3.3333** | 1.532477 | 1.532477 | 否 |
| 8 | **4.6667** | 2.541894 | 1.009417 | 否 |
| **12** | **6.0000** | **3.295837** | 0.753943 | **刚好到上限** |
| 16 | 6.0000 | 3.962504 | 0.666667 | 是 |
| 24 | 6.0000 | 5.295837 | 1.333333 | 是 |
| 32 | 6.0000 | 6.629170 | 1.333333 | 是 |

参考值（射程 6~40 格的两端）：6 格 **2.0794 秒**；40 格 **7.9625 秒**。
"12 格后到上限"在图上的表现：**t(12) = 3.2958 秒之后曲线是直线**，v 恒为 6；
若把斜坡换成别的形状（比如二次、指数），`v(12)=6` 这一点就会被破坏——这是本方案唯一要守的约束。

**验收断言（无头测试直接抄）**：

```
v(0)        == 2.0
v(12)       == 6.0            # 精确相等，不是 ≈
v(12.0001)  == 6.0
v(40)       == 6.0            # 上限，不随距离继续涨
t_of_s(0)   == 0.0
t_of_s(12)  ≈ 6·ln3 = 3.295836866
|s_of_t(t_of_s(s)) − s| < 1e-9     for s ∈ {0,1,4,8,12,16,24,32,40}
单调：v(s) 在 [0,12] 上严格递增；t_of_s 全局严格递增
```

### 1.4 实现方案：用哪一种积分

| 方案 | 60 帧误差（飞 40 格） | 结论 |
|---|---:|---|
| 逐帧前向欧拉 `s += v(s)·dt` | +0.0208 秒（+0.26%） | 不单独用（除非路径中途变化） |
| 逐帧 RK2 中点 `s += v(s + ½k₁dt)·dt` | +0.0042 秒 | 可接受，但没必要 |
| **解析反解 `s = s_of_t(t)`** | **0（精确到浮点）** | **主用** |

**结论，按这个顺序实现：**

1. **主路径（唯一推荐）：解析反解。** 火箭不做"每帧累加"，而是把 `t` 从 0 推到 `dur`，
   每帧直接 `s = HeliMath.s_of_t(elapsed)`。因为两点之间的**水平路径是直线**，
   `s` 就是沿直线的弧长，于是：
   - 水平位置 `p = from.lerp(to, s / total_s)`（`total_s = from.distance_to(to)`）
   - 高度仍走 `Projectile` 的抛物线 `y = lerp(y0, y1, k) + apex·4k(1−k)`，`k = s / total_s`
   - `dur = HeliMath.t_of_s(total_s)` —— 即"按本速度函数飞完全程需要的时间"，这样
     `progress()` 与 `pos()` 与既有 `Projectile` 语义完全兼容，`ProjectileField` 不用改。
   - 由 `s_of_t` 得到的 `k = s/total_s` **天然单调且 ≤ 1**，不会过冲。

2. **备用路径：逐帧积分。** 只在"路径中途被改写"时使用——本项目里就是**坠机**：
   被动触发瞬间速度被锁死，之后走直线匀速撞地，此时用
   `s += HeliMath.v(s_of_progress) · dt`（欧拉，误差 0.26%，肉眼不可见且这一段只有几格）。
   **不要**为了备用路径去改主路径的精度。

3. **不要**用"每格查表 + 线性插值"：表只有 7 个点，插值误差（4 格段内 v 变化 1.33）比 RK2 还大，
   属于凭空引入误差。

### 1.5 火箭弹射物接缝（施工提示）

`Projectile` 现在是"`from`/`to` + `dur` + 线性 `lerp`"，是**匀速**的；火箭需要**变速**。
两种接法，**推荐 B**：

- **A（最小改动）**：`dur = HeliMath.t_of_s(dist)`，把 `progress()` 覆盖成 `s_of_t(t·dur)/dist`。
  优点：`ProjectileField` 一行不改。缺点：`pos()` 语义被改写，别的弹种共享代码时有风险。
- **B（推荐）**：保留 `Projectile` 匀速语义，新增 `KIND_ROCKET` 并在 `Projectile` 上加两个字段
  `speed_profile: int`（0=匀速 / 1=火箭）与 `dist_total: float`；`pos()`/`height()` 里
  按 `speed_profile` 分支。既有弹种 `speed_profile = 0`，行为**逐位不变**。
  这样"变速"是一个**可选物理属性**，将来加别的变速弹（导弹、滑翔弹）不用再改语义。

无论 A/B，**伤害参数只放在发射单 `Projectile.shot` 里**（`Ordnance.Shot`），
弹道物自身不带伤害——这是 `ordnance.gd` 开头的硬规则。

---

## 2. 俯冲状态机

### 2.1 状态列表与迁移

```
                 ┌──────────────────────── 返航到发起格 ────────────────────────┐
                 │                                                             │
  idle ──玩家选格(≤20格)──> ready ──下一次轮到它──> diving ──到位──> dropping ──┴──> returning ──> idle
   ▲                        │                        │                     (0.5s 投弹)
   │                        │                        └── 受伤致力量<21 ──> crashing ──撞地──> dead
   └────────────────────────┴── 阵亡 / 关卡重置 ─────────────────────────────────────────────┘
```

| 状态 | id | 进入条件 | 退出条件 | 语义 |
|---|---|---|---|---|
| 待机 | `idle` | 初始；返航结束；复活 | 玩家用主动技选定目标格 | 正常单位：悬浮 2 格、可移动可普攻 |
| 准备 | `ready` | 玩家**选定 20 格内一格**且精力 ≥ 技能消耗 | ① 下一次轮到它 → `diving`；② 阵亡 → 清状态 | 只是"记下目标格"，**本回合照常结束**；敌方 AI 从这里读威胁 |
| 俯冲 | `diving` | 轮到它的回合开始，且 `ready` | 水平到达目标格上方 → `dropping`；中途触发被动 → `crashing` | 以 6 格/秒扑向目标格，高度 2 → 0.5 **均匀**下降 |
| 投弹 | `dropping` | `diving` 到位 | 停留 **0.5 秒**后投弹完成 → `returning` | 悬停 0.5 秒，投下一枚"直径翻倍的投掷手炮弹" |
| 返航 | `returning` | 投弹完成 | 回到**发起格**（水平）→ `idle` | 原路返回，速度 = 俯冲速度（6 格/秒），高度 0.5 → 2 |
| 坠毁 | `crashing` | `diving`/`dropping`/`returning` 中力量 < 21 | 撞地（高度 ≤ 0）→ 结算 AOE → 本角色死亡 | 模型换成"投掷手炮弹但直径翻倍"，**保持触发瞬间速度直线撞地** |
| 阵亡 | `dead` | 任何状态力量池归零（含坠机自伤/被打死） | `GameMaster` 计时到点复活 → `idle` | 清空所有状态 |

> `crashing` 与 `dead` 建议**合并进同一个枚举**（`crashing` = 死亡的动画前段），
> 因为对外语义都是"这条命结束了"；分开只是为了演出。

### 2.2 状态数据（建议放 `HeliState`，纯数据、可无头）

```gdscript
class_name HeliState
extends RefCounted

enum Phase { IDLE, READY, DIVING, DROPPING, RETURNING, CRASHING, DEAD }

# ── 输入（玩家/AI 写入）──
var phase: int = Phase.IDLE
var target_cell: Vector2i = Vector2i(-1, -1)   # ready 时记录的目标格
var origin_cell: Vector2i = Vector2i(-1, -1)   # 俯冲发起格（返航终点，= 进 diving 时的 cell）

# ── 运动学（每帧写）──
var pos: Vector2 = Vector2.ZERO                # 水平位置（浮点格坐标，格中心为 +0.5）
var altitude: float = 2.0                      # 离地高度（格）：2.0 悬浮 / 0.5 投弹高度
var dir: Vector2 = Vector2.RIGHT               # 当前水平单位方向
var speed: float = 0.0                         # 当前水平速度（格/秒）
var vel: Vector3 = Vector3.ZERO                # 坠机用：触发瞬间锁定的三维速度
var hold: float = 0.0                          # dropping 的 0.5 秒计时器

# ── 里程碑 ──
var dived_leg: float = 0.0                     # 俯冲段总长（= origin→target 的格数）
var traveled: float = 0.0                      # 本段已走距离
var payload_fired: bool = false                # 防重复投弹
```

**单位上挂一个引用**（`Unit` 加一行 `var heli: HeliState = null`，只有直升机非空）：
这样"是不是直升机" = `HeliState.for_unit(u) != null`，不必按名字匹配，敌方镜像自动同款。

### 2.3 每帧要更新的量

常量集中在一处（建议 `HeliState` 顶部，数值全部来自用户口径）：

```gdscript
const HOVER_H := 2.0          # 稳定悬浮高度（格）—— 移动中也维持 2.0
const DIVE_H := 0.5           # 俯冲终点高度（格）
const DIVE_SPEED := 6.0       # 俯冲速度（格/秒，用户口径）
const DROP_HOLD := 0.5        # 到位后停留（秒）
const MOVE_MULT := 2.0        # 移动速度为一般角色两倍
const DIVE_RANGE := 20.0      # 选格上限（格）
```

| 状态 | 每帧更新 | 公式 |
|---|---|---|
| `ready`/`idle` | `altitude` 恒为 `HOVER_H`；移动结算时把 `move` 当 `move × MOVE_MULT` | `altitude = HOVER_H` |
| `diving` | `speed = DIVE_SPEED`；`traveled += speed·dt`；`pos += dir·speed·dt` | `altitude = lerp(HOVER_H, DIVE_H, traveled / dived_leg)` ← **均匀下降** |
| `dropping` | `hold += dt`；`pos` 不动；`speed = 0`；`altitude = DIVE_H` | `hold ≥ DROP_HOLD` → 投弹 → `returning` |
| `returning` | `speed = DIVE_SPEED`；沿 `target → origin` 反向走；`traveled` 归零 | `altitude = lerp(DIVE_H, HOVER_H, traveled / dived_leg)` |
| `crashing` | `pos += Vector2(vel.x, vel.z)·dt`；`altitude -= vel.y·dt` | **匀速直线**：`vel` 在触发瞬间锁定后不再改 |
| 全部 | 结算前先 `_sync_cell()`：`cell = Vector2i(floor(pos.x), floor(pos.y))` | 受伤/哨兵/命中判定都读 `pos`（浮点），只有格子语义读 `cell` |

**要点**：

- **`diving` 的"到位"判定用水平距离**，不要用格相等：
  `if pos.distance_to(_cell_center(target_cell)) <= speed * dt → 夹到格心，进入 dropping`。
  否则 6 格/秒 × 1/60 秒 = 0.1 格/帧，永远跨不过格心。
- **`dived_leg == 0`（原地俯冲）**：除法要防零，`altitude` 直接取 `DIVE_H`，
  俯冲段耗时 0，立即进入 `dropping`（选自己脚下那一格是合法的）。
- **高度不是格子属性**：`altitude` 只影响表现与"是不是悬空"，
  **不参与投掷瞄准/射程计算**（射程一律按格子算），否则 6~40 格会漂移。
- **悬浮与移动速度**：`move = 20`、`MOVE_MULT = 2.0` → 单回合 40 格。
  建议**不要在元数据里再存一遍**，直接从 `Unit.move × MOVE_MULT` 推；
  若怕 AI 的 `reachable` 生成与移动结算两处不一致，就把 `40` 作为
  `Level.heli(id)["move_tiles"]` 显式存下来（见 §4），以元数据为唯一真相。

### 2.4 分支：俯冲中受伤 → 触发被动「坠机」

**触发判定（唯一入口，纯函数）**：

```gdscript
static func crash_threshold_milli() -> int:
	return Rules.points_to_milli(21)               # 力量 < 21 → 坠机

static func should_crash(u: Unit) -> bool:
	return u != null and u.is_alive() and u.power_cur < crash_threshold_milli()
```

**每一处会改到直升机力量的代码路径之后都要调它**（`take_power_damage` 之后、AOE 之后、
被箭射中之后、被击落之后）——最省事的做法是在 `Unit.take_power_damage()` 里加一个
`if heli != null and power_cur > 0 and power_cur < 21000: heli.mark_crashing(...)` 的钩子，
**但更推荐**由 `HeliState` 自己每帧检查：`if phase in (DIVING, DROPPING, RETURNING) and should_crash(u): enter_crashing()`。
逐帧检查天然覆盖所有伤害来源，不会漏；代价是"触发到生效"最多晚 1 帧（16ms，肉眼不可见）。

**进入 `crashing` 时要做四件事（顺序固定）**：

```
① 模型替换：换成"投掷手炮弹但直径翻倍"的模型（= 现有 shell 模型 ×2 缩放）
   —— 直升机本体模型立即隐藏，炮弹模型接管同一 transform
② 速度锁定：vel = 触发瞬间的速度，之后永不再改
     水平分量 = dir * max(DIVE_SPEED, 当前 speed)（沿当前朝向）
     垂直分量 = -max(HOVER_H - DIVE_H, 0) / max(俯冲总时长, 0.05)
                 —— 即"保持俯冲时的高度下降率"；若没有下降率（例如在 ready 被打死）
                    就用 -DIVE_SPEED 兜底，保证一定会撞地
③ 直线撞地：pos += Vector2(vel.x, vel.z) * dt; altitude -= vel.y * dt
   不追目标格、不受任何外力；直到 altitude <= 0 → 撞地点 = pos
④ 造伤（见 §5）：以撞地点为圆心、半径 2.5 格结算 AOE，然后该角色死亡
```

**必须写进代码注释的三条**：

1. **速度"保持"= 保持触发瞬间的大小与方向**，不是"保持朝向目标格"。触发后目标格作废。
2. **必须保留坠落过程**（不能直接消失）：模型一路飞到底再结算，
   否则"加速下坠动画"就没得演。这段时间**仍可受伤**（再来一发也不会二次触发，
   `phase == CRASHING` 时直接返回）。
3. **造伤顺序：先 AOE，后死亡。** 理由：
   （a）口径里 AOE 的圆心是"落点"，落点必须先存在，而落点只在撞地那一刻确定；
   （b）直升机自己会被自己的 AOE 覆盖（它就在圆心），此时它还没死，于是日志里能看到
   "直升机 破甲 40 + 力量 20"，与"玩家看到它摔下去"的直觉一致；
   （c）如果先死亡再结算，它会先被 `Passives.forget_*` / `clear_states()` 清干净，
   AOE 就要挂在一个尸体上算，`Damage.blast` 的 `skip` 参数也得特判，容易出 bug。
   **代价**：AOE 打死直升机自己是"重复致死"，实现时在 `Damage.blast` 里传 `skip = null`
   （**不要**传 `skip = 自己`），并在结算后无论 `died` 与否都调用一次 `_kill_heli(u)` 幂等收尾。

---

## 3. AI 可读的准备状态接口

### 3.1 设计原则

- **纯函数、无 Node**：判定只吃 `HeliState` 与格子坐标，可以在 `game/tests/run.gd` 里
  无头断言（这是本项目所有 core 模块的既有要求：`damage.gd` / `ai.gd` 开头都明确写了）。
- **AI 只读，不写**：AI 不允许修改 `phase`；它只能"读到准备状态并做决断"（用户口径）。
- **镜像通用**：敌方 `俯冲轰炸直升机（不要问那么多） (E)` 走同一套状态，AI 读自己的
  `heli` 或对手的 `heli` 用的是同一批函数。

### 3.2 建议字段与签名

```gdscript
# ── HeliState 上的对外接口（全部 static，纯函数）──

## 取单位身上的俯冲状态（不是直升机 → null）
static func for_unit(u: Unit) -> HeliState

## 是否处于"准备状态"（玩家已选格、还没轮到它）—— AI 主判据
static func is_ready(u: Unit) -> bool
#   return for_unit(u) != null and for_unit(u).phase == Phase.READY

## 是否正在俯冲链路中（diving / dropping / returning / crashing）
static func is_airborne_action(u: Unit) -> bool

## 准备状态的目标格；不在 ready 时返回 (-1,-1)
static func ready_target_cell(u: Unit) -> Vector2i

## 它"威胁到哪些格"：ready 时 = 以目标格为圆心、半径 dive_blast_r 的圆覆盖的格
##                      diving/dropping 时 = 以【当前位置】为圆心、半径 dive_blast_r 的圆
##                      crashing 时 = 以【预测撞地点】(pos + vel水平 × 剩余下落时间) 为圆心
##                      idle/returning → 空
## ★ 这是弓箭手 AI 唯一需要调的函数
static func threatened_cells(u: Unit, cfg: Dictionary) -> Array[Vector2i]

## 单格版本：这一格会不会被它的俯冲投弹打到（含 0 距离 = 直接命中）
static func threatens_cell(u: Unit, cell: Vector2i, cfg: Dictionary) -> bool

## 它此刻是不是"容易被打中的移动靶"（俯冲中 flag 为 true；used by 弓箭手/哨兵策略）
static func is_dive_vulnerable(u: Unit) -> bool

## 预测撞地点（crashing 时才有意义；否则返回当前位置）
static func predicted_impact(u: Unit) -> Vector2
```

`cfg` 用 `Level.heli(id)` 的字典（§4），这样"半径多少格"是**关卡参数**而不是硬编码。

### 3.3 `Ai.Ctx` 要补的两个字段

```gdscript
# Ai.Ctx 内新增
## 敌方（对手方）正在准备俯冲的直升机 → 它的目标威胁格集合
var foe_dive_threat: Dictionary = {}      # 格 -> true
## 正在俯冲链路中的敌方直升机（含 (E) 镜像），供弓箭手判断"这是活靶"
var foe_divers: Array[Unit] = []
```

组装（`battle_scene._build_ai_ctx()`，与既有 `sentry_cells` 同一处）：

```gdscript
for f in foes_of(u):
	var hs := HeliState.for_unit(f)
	if hs == null:
		continue
	if HeliState.is_ready(f):
		for c in HeliState.threatened_cells(f, Level.heli()):
			c.foe_dive_threat[c] = true
	if HeliState.is_airborne_action(f):
		c.foe_divers.append(f)
```

### 3.4 弓箭手 AI：据此开哨兵（伪代码）

**为什么开哨兵能反制**：俯冲中的直升机是**每帧移动的角色**，会走
`GameMaster.check_unit(u, pos)` 这条路 —— 于是只要它一路飞进/飞在阿莱特的 8 格射界里，
哨兵队列就会连续触发（`check_unit` 对"入界"和"界内移动"都触发一次；停下来的 0.5 秒
投弹窗口不触发，因为 `sentry_tick` 会剔除"没在动"的目标）。
**所以弓箭手的正确姿势是"站在目标格 8 格以内**并**开哨兵**"，而不是站着挨炸。

```gdscript
func _plan_heli_defense(ctx: Ai.Ctx) -> Dictionary:
	var me := ctx.me
	if ctx.foe_dive_threat.is_empty() and ctx.foe_divers.is_empty():
		return {}
	var ds := Skills.get_def("sentry")
	if ds.is_empty() or not Skills.skills_for(me).has("sentry"):
		return {}
	if ctx.me_has_sentry or me.energy_points() < int(ds["cost"]):
		return {}

	# ① 最坏情况：我这一格就在它的投弹圈里（半径 dive_blast_r）→ 必开哨兵
	if ctx.foe_dive_threat.has(me.cell):
		return {"action": "skill", "skill": "sentry",
			"note": "直升机 %s 已瞄准我这一格，开哨兵等它俯冲下来" % _heli_name(ctx)}

	# ② 我正在被俯冲 → 它是活靶：先看这回合能不能直接射它（俯冲中它不在格心上，
	#    所以用浮点位置算距离；能射就射，不浪费回合开哨兵）
	for h in ctx.foe_divers:
		var hp := HeliState.for_unit(h).pos                       # 浮点格坐标
		if _dist(me.cell, hp) <= float(me.rng_max) and _dist(me.cell, hp) >= float(me.rng_min):
			return {"action": "attack", "target": h,
				"aim":       Ai.aim_at(me, Vector2i(floor(hp.x), floor(hp.y)), ctx),
				"break_armor": true,
				"note": "直升机正在俯冲（%d 格）→ 直接点它" % int(_dist(me.cell, hp))}

	# ③ 它的目标格在我射界内（8 格）→ 开哨兵，等它飞进来时连射
	for cell in ctx.foe_dive_threat.keys():
		var d := Ai.manhattan(me.cell, cell)
		if d <= me.rng_max:
			return {"action": "skill", "skill": "sentry",
				"note": "直升机瞄准 (%d,%d)（离我 %d 格）→ 开哨兵拦它的俯冲" % [cell.x, cell.y, d]}

	# ④ 目标格够不着 → 朝目标格方向挪一步（挪到射界里），挪不动就开哨兵赌它会飞近
	var approach := _closest_threat_cell(ctx, me)
	if approach != Vector2i(-1, -1) and not me.has_moved:
		var step := _step_toward(ctx, me, approach)     # 复用既有 reachable 选格
		if step != me.cell:
			return {"action": "move", "move_to": step,
				"note": "朝直升机目标格 (%d,%d) 靠拢" % [approach.x, approach.y]}
	return {"action": "skill", "skill": "sentry",
		"note": "直升机已进入准备状态 → 提前开哨兵"}
```

**接入点**：在 `Ai._plan_skill()` 的弓箭手分支**最前面**调用
`_plan_heli_defense(ctx)`，非空就直接返回；空则落回既有逻辑
（"身处敌方投掷手射程内却够不着它 → 开哨兵"那段**保持不动**，直升机是 THROWER，
`t0.role == UnitData.Role.THROWER` 那条件本来就会命中它，两套判断互为兜底）。

**更新频率**：`ready` 会持续**整整一个对方回合**（从玩家按下确认到下次轮到它），
所以 AI 一定读得到；`diving`/`dropping` 只持续约 0.5~3.3 秒，
**弓箭手如果在俯冲途中才轮到它，读到的就是这个瞬时状态**——这也是为什么要同时
暴露 `foe_divers`（否则"能读到但没法用"）。

**验收断言**：

```
ready 且目标格在阿莱特 8 格内  → 计划里 skill == "sentry"
ready 且目标格在 9 格外、可达格里有 8 格内的 → action == "move" 且朝该格
无直升机 / 直升机 idle          → _plan_heli_defense 返回 {}（不影响既有行为）
```

---

## 4. 关卡元数据 schema

### 4.1 已落地（`level.gd`）

```gdscript
"respawn_turns": {"俯冲轰炸直升机（不要问那么多）": 25},
```

```gdscript
## 这个角色在本场景要等几个回合重生（场景元数据；缺省 10）
static func respawn_turns(unit_name: String, id: String = "") -> int:
	var m: Dictionary = def(id).get("respawn_turns", {})
	return int(m.get(unit_name, GameMaster.HERO_REVIVE_TURNS))
```

**缺省行为**：字段缺失、或字段在但**没有这个角色的 key** → 回退
`GameMaster.HERO_REVIVE_TURNS`（当前 = 10）；`battle_scene` 阵亡分支写的是
`gm.schedule_hero_revive(u, Level.respawn_turns(u.name))`，所以**其他关卡/其他角色
一个字都不用改**。计时时钟是 `GameMaster.turn_count`（回合边界计数），
与轨道空爆/枪榴弹共用同一套，不需要新的计时器。

> **风险点（施工时务必处理）**：`respawn_turns` 的 key 是**全名**，
> 但敌方是 `俯冲轰炸直升机（不要问那么多） (E)`。`Unit.base_name()` 的循环后缀表
> 只认 `" (E)"`，对全名是有效的（`base_name("俯冲轰炸直升机（不要问那么多） (E)")`
> == `"俯冲轰炸直升机（不要问那么多）"`）。所以**读取时写两次兜底**：
> `Level.respawn_turns(u.name)`，命中不了再试 `Level.respawn_turns(Unit.base_name(u.name))`。
> 建议直接改 `Level.respawn_turns` 内部：
> ```gdscript
> static func respawn_turns(unit_name: String, id: String = "") -> int:
> 	var m: Dictionary = def(id).get("respawn_turns", {})
> 	if m.has(unit_name):
> 		return int(m[unit_name])
> 	var base := Unit.base_name(unit_name)          # 敌方镜像 / 左右分身
> 	if m.has(base):
> 		return int(m[base])
> 	return GameMaster.HERO_REVIVE_TURNS
> ```

### 4.2 新增（`heli` 子字典）

三个关卡各自的字典都是手写 `const`，**只给 `arena` 写 `heli` 块就会漏掉 `field`**，
所以：**入口给默认值（`Level.heli()` 做逐键兜底），同时在 `field` 与 `arena` 都显式写一遍**。
好处是"每关的重生回合数"这类场景特有参数能一眼看到，而不是埋在代码常量里。

```gdscript
"arena": {
	...
	# 场景特有的重生回合数（缺省 = GameMaster.HERO_REVIVE_TURNS = 10）
	"respawn_turns": {"俯冲轰炸直升机（不要问那么多）": 25},
	# 俯冲轰炸直升机的场景参数（缺省见 Level.heli 的默认值；两关都写一遍，便于调参）
	"heli": {
		"respawn_turns": 25,        # 本场景该角色的重生回合数（与 respawn_turns 同值）
		"dive_range": 20.0,         # 主动技：玩家最多选 20 格内一格
		"dive_speed": 6.0,          # 俯冲速度（格/秒）
		"hover_h": 2.0,             # 稳定悬浮高度（格），移动中也维持
		"dive_h": 0.5,              # 俯冲终点高度（格）
		"drop_hold": 0.5,           # 到位后停留（秒）
		"move_mult": 2.0,           # 移动速度倍率（一般角色两倍）
		"move_tiles": 40,           # = move 20 × 2，写死一份给 AI 算 reachable 用
		"dive_blast_r": 3.0,        # 俯冲投弹作用半径（格）—— AI 的"威胁格"用这个
		"dive_break": 40,           # 投弹破甲
		"dive_power": 20,           # 投弹力量
		"crash_r": 2.5,             # 坠机 AOE 半径（格）
		"crash_power": 20,          # 坠机力量
		"crash_break": 40,          # 坠机破甲
		"crash_res": 0.5,           # 坠机无视物抗比例（与现有炮弹同款）
		"crash_threshold": 21,      # 力量 < 21 → 坠机
		"fragments": 2,             # 火箭落地生成的破片数
		"rockets": 8,               # 普攻一次投下的火箭数
		"salvo_pairs": 4,           # 动画：一次两枚 ×4 次
		"salvo_gap": 0.25,          # 每次间隔（秒）
	},
},
"field": {
	...
	"respawn_turns": {"俯冲轰炸直升机（不要问那么多）": 25},
	"heli": { ...同上，两关保持一致... },
},
```

**读取入口（默认值只在一处）**：

```gdscript
## 本场景的俯冲轰炸直升机参数（缺省值全部集中在这里）
const HELI_DEFAULTS := {
	"respawn_turns": GameMaster.HERO_REVIVE_TURNS,   # 10
	"dive_range": 20.0, "dive_speed": 6.0,
	"hover_h": 2.0, "dive_h": 0.5, "drop_hold": 0.5,
	"move_mult": 2.0, "move_tiles": 40,
	"dive_blast_r": 3.0, "dive_break": 40, "dive_power": 20,
	"crash_r": 2.5, "crash_power": 20, "crash_break": 40,
	"crash_res": 0.5, "crash_threshold": 21,
	"fragments": 2, "rockets": 8, "salvo_pairs": 4, "salvo_gap": 0.25,
}

static func heli(id: String = "") -> Dictionary:
	var out := HELI_DEFAULTS.duplicate()
	for k in def(id).get("heli", {}):
		out[k] = def(id)["heli"][k]
	return out
```

**缺省行为汇总**：

| 情况 | 结果 |
|---|---|
| 关卡没有 `heli` 字段 | 全部走 `HELI_DEFAULTS` |
| `heli` 只写了一部分 key | 未写的 key 走 `HELI_DEFAULTS`（逐键 merge，不是整块替换） |
| 关卡没有 `respawn_turns` | 回退 `GameMaster.HERO_REVIVE_TURNS = 10` |
| `respawn_turns` 没这个角色的 key | 同上回退 10 |
| 角色不在 `roster` 里 | 根本不生成，与元数据无关 |
| 敌方镜像 `... (E)` | 走 `base_name()` 兜底命中同一份参数 |
| `heli.respawn_turns` 与 `respawn_turns` 冲突 | **以 `respawn_turns` 为准**（那是重生计时的唯一真相），`heli.respawn_turns` 只作镜像可读值 |

**不要在 `field` 关卡给直升机改位置**：`field` 的 `roster` 已把
`俯冲轰炸直升机（不要问那么多）` 放在 `(21,23)`（我方）与 `(21,25)`（敌方），
正好补上原三英雄中间那格；`arena` 放在 `(12,18)` / `(12,22)`。

---

## 5. 伤害结算顺序（全部走现有 `Damage` / `Combat` 体系）

### 5.1 坠机 AOE：`20 力量 + 40 破甲`，带"降低 50% 物抗"

现有炮弹的表达式（`ordnance.gd` 的 `make_shell` / `damage.gd` 的 `blast_opts`）：

```gdscript
Combat.opts({
	"power": caster.power_cur,        # 攻方力量（千分比）
	"armor_break": caster.armor_break,# 破甲（千分比）
	"ignore_res": 0.5,                # 无视 50% 物抗
	"rng": rng,
})
```

坠机 AOE 就是**把前两项换成固定值**（因为是"摔下来的炸弹"，不该吃直升机的力量属性；
用户口径给的是"20 力量 + 40 破甲"两个**定值**）：

```gdscript
static func crash_opts(cfg: Dictionary, rng: RngService) -> Dictionary:
	return Combat.opts({
		"power":       Rules.points_to_milli(int(cfg["crash_power"])),   # 20 → 20000
		"armor_break": Rules.points_to_milli(int(cfg["crash_break"])),   # 40 → 40000
		"ignore_res":  float(cfg["crash_res"]),                          # 0.5
		"rng":         rng,
	})
```

结算调用（**爆心 = 撞地点（浮点格坐标），半径 = 2.5 格，`skip = null`**）：

```gdscript
var hits := Damage.blast(u, impact_pos, float(cfg["crash_r"]), crash_opts(cfg, rng),
		units, placeables,
		null,          # skip = null：直升机自己也在圈里，一起挨这一下（先造伤后死亡）
		u.side,        # caster_side：日志里把友军标出来
		true)          # touch_cells = true：与投掷手普攻同款"红圈沾到格子就算"
```

**结算顺序（`Combat.deal_to_unit` 内部，必须按这个解释写注释）**：

```
① 破甲线：固定 armor_break，无视物抗、无视护甲，直接打护甲池
      target.take_armor_damage(40000)
② 有效物抗：eff = clamp(pr × (1 − ignore_res), 0, 1000)
      0.5 → 物抗 80% 变 40%，正好是口径里的"降低 50% 物抗"
③ 力量线：Rules.resolve(power = 20000, armor_cur, eff, rng)
      先减护甲、再过抗性、再掷命中；打力量池
④ 死判定：目标 power_cur == 0 → died
```

**为什么不是 `ignore_res = 0.5` 的 `fixed_power`**：`Combat.opts_orbital` 用的
`fixed_power` 会**跳过护甲**（只按抗性折算）。坠机口径是"投掷手炮击同款"，
炮击是**吃护甲**的（`Rules.resolve(power, armor_cur, eff)`）。
所以要用 `power` 而不是 `fixed_power` —— 这一点写错会让 12 甲以下的角色白吃 20 点全额伤害。

**日志（`Damage.Hit.text` 已经支持，直接透传）**：
`Combat.describe(result, pr_before, ignore_res)` 会输出
`破甲 40 + 力量 X（物抗 0%→0%）`；直升机的 `pr = 0`，所以物抗段显示 0%→0% 是正常的。

### 5.2 俯冲投弹（主动技落下的那枚弹）

口径：投掷手普攻模型**直径翻倍**、作用**半径 3 格**、**40 破甲 + 20 力量**、
**不触发哨兵**、**下落速度与轨道空爆一致**。

```gdscript
# 复用同一套 opts（与坠机同源，避免两处数值漂移）：
var o := Combat.opts({
	"power":       Rules.points_to_milli(int(cfg["dive_power"])),    # 20
	"armor_break": Rules.points_to_milli(int(cfg["dive_break"])),    # 40
	"ignore_res":  0.5,                                             # 与炮击同款
	"rng":         rng,
})
# 作用范围：半径 3 格 → Damage.blast(..., radius = cfg["dive_blast_r"], touch_cells = true)
```

| 属性 | 投掷手普攻 | 俯冲投弹 |
|---|---|---|
| 模型 | `Projectile.KIND_SHELL` | 同款 **×2 缩放**（直径翻倍） |
| 作用半径 | 1.5 格（`Ordnance.DEFAULT_BLAST_R`） | **3.0 格** |
| 破甲 | 攻方 `armor_break` | **固定 40** |
| 力量 | 攻方 `power_cur` | **固定 20** |
| `ignore_res` | 0.5 | 0.5（同款） |
| `sentry_trigger` | `true` | **`false`** |
| `hit_tags` | `["arrow"]`（可被箭击落） | 建议 `[]`（它已经在俯冲，别再造二次坠机判定） |
| 下落速度 | `SHELL_TILES_PER_SEC = 3.0` | **与轨道空爆一致**（`Skills.orbital_strike.shell_fall_sec = 0.5` 秒/发） |
| 不分敌我 | 是（`skip = null`） | 是 |

> **"下落速度与轨道空爆一致"的落点**：轨道空爆是"5 发、每发下落 `shell_fall_sec = 0.5` 秒"。
> 俯冲投弹只有 1 发，所以直接取**下落时长 0.5 秒**：从 `altitude = DIVE_H = 0.5` 格
> 垂直落到地面，动画时长 0.5 秒，不额外加水平位移（`from == to`，纯垂直下落）。
> 建议把 `0.5` 写进 `Skills.get_def("orbital_strike")["shell_fall_sec"]` 的**引用**上
> （`float(Skills.get_def("orbital_strike")["shell_fall_sec"])`），而不是抄一个 0.5，
> 这样以后调轨道空爆会同步。

### 5.3 普攻：吊射 37mm 火箭

- **消耗 4 精力**；出不起就不能开火（`Unit.spend_energy(4)`；注意这推翻了
  "精力只用于技能"的 UI 文案，左上角那行字要删）。
- **瞄准同投掷手，结果翻倍**：`_aim_range(t) = 6 + (40 − 6)·t²`
  （即 `2 × (3 + 17·t²)`），同样的拖拽力度 → 落点距离翻倍。
  落点解算沿用 `_planned_cell` / `_aim_float_pos` 的同一套代码，只换曲线常量。
- **落点**：以瞄准落点为圆心、**半径 4 格圆内随机 8 个点**，每点一发火箭。
  实现为纯函数（可无头测）：

```gdscript
## 以 center 为圆心、radius 4 的圆内取 n 个点；任意两点距离 >= min_gap（格）
## 圆内均匀（半径按 sqrt(u) 取，否则会堆在圆心 —— 与 Spread.offset 同款做法）
static func spread_points(center: Vector2, radius: float, n: int,
		min_gap: float, rng: RngService) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for i in n:
		var pick := center
		var ok := false
		for tries in 200:                       # 有上限，保证终止
			var ang := rng.next_float() * TAU
			var rr := radius * sqrt(rng.next_float())
			var q := center + Vector2(cos(ang), sin(ang)) * rr
			if _far_enough(q, out, min_gap):    # 复用 Skills._far_enough 同款
				pick = q; ok = true; break
		if not ok:
			pick = _relax_gap(center, radius, out, min_gap)   # 兜底：缩小间距重试
		out.append(pick)
	return out
```

  `min_gap` 建议 **0.6 格**（8 个点、半径 4 的圆，面积 ≈ 50 格²，每点约占 6.3 格²，
  `0.6` 的间距约束几乎总能满足，不会退化到兜底分支）。
  **兜底分支必须存在**，否则极端随机下会死循环（`skills.py` 的 `carpet_points` 就是先例：
  `for tries in 600` + 兜底微调）。
- **每发直击范围 = 半径 1 格圆** ⇒ 每发独立调
  `Damage.blast(caster, point_i, 1.0, opts, units, placeables, caster, caster.side, true)`。
  伤害由直升机力量决定 ⇒ `"power": caster.power_cur`（= 41000），
  `"armor_break": caster.armor_break`（= 0，`bc_stat.md` 里直升机的破甲就是 0）、
  `"ignore_res": 0.5`（与炮击同款，保持"投掷手套皮"的一致性）。
- **动画：一次发射两枚（左右各一）× 共四次，间隔 250ms** ⇒ 8 发火箭 = 4 波 × 2 枚。
  发射单用 `group`（`Ordnance.Shot.group` 已有"全部消失后才结束回合"的语义）：

```gdscript
var gid := "heli_salvo_%d" % Time.get_ticks_msec()
var pts := HeliMath.spread_points(aim_pos, 4.0, 8, 0.6, rng)
for wave in 4:                                    # 4 波
	var i0 := wave * 2
	_spawn_rocket(caster, pts[i0],     gid, wave * 0.25,  side = -1)   # 左手边
	_spawn_rocket(caster, pts[i0 + 1], gid, wave * 0.25, side = +1)    # 右手边
	caster.spend_energy(...)  # 见下
```

  偏移量（0.25 秒）直接落到 `Projectile.pre` 上（既有字段，地毯式轰炸就是用它做间隔的：
  `p.t = -pre / p.dur`），**不要**另建一个计时器数组。

### 5.4 精力怎么扣（4 精力换 8 发）

建议**整次普攻扣 4 点，一次扣完**（不是每发 0.5 点）。理由：
（a）精力内部单位是千分比整数（`Rules.points_to_milli`），每发扣 500 会让
`energy_used_this_turn` 出现半点的中间态，UI 显示与"装填"被动结算都容易看出破绽；
（b）口径说的是"普攻需 4 精力"，一次普攻 = 一次出手 = 8 发。
**开火前先判 `caster.energy_points() >= 4`**，不够就走既有"精力不足"的提示分支，不消耗回合。

### 5.5 火箭落地：直径 2 格的圈 + 2 枚破片

- **落地范围直径 2 格** ⇒ 半径 **1.0 格**，即每发直击范围（与 §5.3 的"每发直击范围"是同一个圈，
  不要重复算两遍）。落地时调 `Damage.blast(..., 1.0, ...)` 即可。
- **从落点随机两个方向生成 2 枚破片** ⇒ 复用 `Ordnance.make_fragment(caster, from, dir, ends_turn=false)`：

```gdscript
for k in 2:
	var ang := rng.next_float() * TAU                       # 两个方向各自独立随机
	var dir := Vector2(cos(ang), sin(ang))
	var fp := Ordnance.make_fragment(caster, Vector3(land.x, Damage.FRAGMENT_HEIGHT, land.y), dir, false)
	fp.shot.group = gid                                      # 与齐射同组，全清后才结束回合
	field.register(fp)
```

  破片**沿用既有曲线**（0 格 25 甲/25 力 → 3 格 12/12 → 16 格 0 → 20 格消失）、
  平飞 0.5 格高、4 格/秒、**不分敌我**（`Ordnance.make_fragment` 已经是这个语义，
  文档里 `规格.md` 12.7 也留了"后续还有一个会用到破片的角色"的接口 —— 就是它）。
  **两个方向独立随机**（不是固定 90°/180°），"随机两个方向"按字面理解。

---

## 6. 施工顺序与验收（建议）

| # | 内容 | 验收（无头，`game/tests/run.gd`） |
|---|---|---|
| 1 | `HeliMath`：`v` / `t_of_s` / `s_of_t` / `spread_points` | §1.3 那组断言全过；`t_of_s(12) ≈ 6ln3`；`s_of_t∘t_of_s` 误差 < 1e-9 |
| 2 | `Unit.heli` + `HeliState`（Phase 枚举 + 每帧 `tick(u, dt, cfg)`） | 状态迁移表逐条断言；`dived_leg = 0` 不除零；到位判定不过冲 |
| 3 | `Projectile.KIND_ROCKET` + `Ordnance.make_rocket` | 匀速弹种行为逐位不变（回归）；火箭 `dur == t_of_s(dist)`；`speed_profile` 分支 |
| 4 | 普攻 8 发 + 4 波 ×250ms + 2 枚破片 | 8 个落点全在半径 4 内、两两 ≥ 0.6 格；`pre` 序列 = 0/0.25/0.5/0.75；扣 4 精力；`group` 全清才结束回合 |
| 5 | 坠机被动 + AOE | 力量 20 阈值边界（21000 → 20000 触发、21000 不触发）；AOE `power=20000`/`armor_break=40000`/`ignore_res=0.5`；先造伤后死亡；直线撞地 |
| 6 | 俯冲主动技 + `Level.heli` 元数据 | 选 21 格外被拒；`ready` 持续一个回合；投弹 40/20、半径 3、`sentry_trigger=false`；`returning` 回原格 |
| 7 | AI 接口 + 弓箭手哨兵 | §3.4 的三条断言；无直升机时 `Ai.plan()` 结果与改动前逐字段一致（回归） |
| 8 | 重生 25 回合 | `Level.respawn_turns`（含 `(E)` 全名兜底）== 25；`field` 关卡缺省 == 10；`gm.turn_count` 走满 25 才 `due_revives()` |
| 9 | 表现层（模型/悬浮/旋翼/加速下坠） | `_spawn_units` 里把 `altitude` 接到 `visual.position.y`；无人机/直升机 ID 不参与数值判定 |

**回归红线**：任何第 3/7 项改动之后，
`game/tests/run.gd` 与 `game/tools/playtest.gd` 必须整体重跑一遍——
既有的"敌我交替""哨兵拦截""轨道空爆""枪榴弹"四组用例是这次改动最容易踩坏的邻居。

---

## 7. 待用户确认的两个口径（施工时先按本文，被推翻再改）

1. **"随机 8 个点"是否允许重叠**：本文按"两两 ≥ 0.6 格"实现（8 个半径 1 的圈不重叠太多，
   否则伤害会叠在一小片）。若用户要"完全独立随机、允许重叠"，把 `min_gap` 传 `0.0` 即可，
   函数签名不用改。
2. **坠机 AOE 是否伤到自己队友**：本文按"不分敌我、包含自己"实现（`skip = null`），
   与投掷手炮击 / 轨道空爆的既有口径一致。若要"只打敌人"，把 `Damage.blast(..., skip = u, ...)`
   的 `skip` 从 `null` 换成 `u` 即可。
