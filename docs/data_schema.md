# 数据模型、接口与存档 Schema（v1）

> 配套 `docs/design_v1.md`。本文件定义 v1 的**数据契约**：兵种原型、关卡、战斗输入、战斗状态、行动请求、事件流、存档格式。规则判定细节见 `docs/spec_rules.md`。
>
> 设计原则：
> 1. **规则层零渲染依赖**：以下类型全部是 `Resource` / `RefCounted` / 纯 `Dictionary`，没有一个 `extends Node`。
> 2. **数值内部统一用整数千分比**（下文以 `‰` 标注）：`spec_rules.md` 里写的 `力量 9`（**点**）= 内部 `9000‰`；`物抗 0.2` = `200‰`。**文档与 UI 一律显示点，只有管线内部用 ‰**，避免浮点误差。
> 3. **存档 = BattleState 的 JSON 投影**，加版本号即可迁移。
> 4. 每个类型都标注了"是否进存档"。

---

## 1. 类型总览

```
UnitData (Resource, 静态原型)  ──┐
LevelData (Resource, 关卡)      ──┼──► BattleSetup ──► BattleCore ──► BattleEvent[] ──► BattleView
BalanceConfig (Resource, 全局) ──┘         │                              │
                                           ▼                              ▼
                                      UnitState[]                   SaveFile (JSON)
                                    （运行时状态，进存档）
```

| 类型 | 基类 | 文件 | 是否进存档 | 说明 |
|---|---|---|---|---|
| `UnitData` | `Resource` | `src/core/unit_data.gd` | ❌（只存 id） | 兵种原型 |
| `UnitState` | `RefCounted` | `src/core/unit_state.gd` | ✅ | 单位运行时状态 |
| `LevelData` | `Resource` | `src/core/level_data.gd` | ❌（只存 id） | 关卡定义 |
| `BalanceConfig` | `Resource` | `src/data/balance.tres` | ⚠️ 存哈希 | 全局平衡参数 |
| `BattleSetup` | `RefCounted` | `src/core/battle_setup.gd` | ✅（部分） | 战斗输入 |
| `BattleState` | `RefCounted` | `src/core/battle_state.gd` | ✅ | 战斗完整状态 |
| `ActionRequest` | `RefCounted` | `src/core/action_request.gd` | ❌ | 一次行动意图 |
| `BattleEvent` | `Dictionary` | — | ⚠️ 只存摘要 | 事件流（驱动动画 + 日志） |
| `SaveFile` | `Dictionary` | `src/save/save_service.gd` | ✅ | 存档根对象 |

---

## 2. 属性字典（`Stats`）

所有属性统一为整数千分比。`0.35 物抗` = `350`。

| 字段 | 含义 | 取值域（v1 校验） | 升级可加（R5） |
|---|---|---|---|
| `power` 力量 | 攻击力量时的攻方值；**同时是力量池上限，归零即阵亡** | 3000-30000（3-30 点；v1.2 上限由 20 上调到 30，见 `spec_rules.md` D31） | ✅ |
| `armor` 护甲 | 被攻击力量时的守方值；**同时是护甲池上限，归零只失去减免（不阵亡）** | 3000-24000（3-24 点） | ✅ |
| `phys_res_tier` 物抗档 | **五档离散固有属性，不可加点**：无/低/中/高/免疫 = 0/200/400/800/1000‰ | 枚举 `ResTier`（见下） | ❌ |
| `mag_res_tier` 魔抗档 | 同上；**v1 不参与结算**（魔法伤害只能由技能打出，技能系统在 v2） | 枚举 `ResTier` | ❌ |
| `phys_res_tier` 物抗 | 五档：无/低/中/高/免疫 = 0/200/400/800/1000‰ | 枚举 `ResTier` | ❌ |
| `mag_res_tier` 魔抗 | 同上；v1 不参与结算 | 枚举 `ResTier` | ❌ |
| `armor_break` 破甲伤害 | 攻击护甲时的固定伤害（无视物抗与力量） | 1000-18000（1-18 点；v1.2 上限 18） | ✅ |
| `energy_max` 精力上限 | 进入战局时满值；**上限 4 点**（`spec_rules.md` K3） | 2000-4000（2-4 点） | ✅ |
| `rest_power` 休息恢复力量 | 每次休息恢复 | 1000-8000 | ✅ |
| `rest_armor` 休息恢复护甲 | 每次休息恢复 | 1000-8000 | ✅ |
| `move` 移动力 | 每回合可移动格数 | 0-20（**整数，不用千分比**） | ❌ |
| `range_melee` | 近战攻击范围（格） | 固定 1（4 邻格） | ❌ |
| `range_ranged` 射程 | 远程攻击范围（格，曼哈顿距离） | 1-40（**整数**） | ✅（仅远程） |
| `radius_ballistic` 落地判定范围 | 弹道落点判定半径（格，整数） | 1-3（`SPL`） | ✅（仅弹道） |
| `initiative` ~~先攻~~ | **已移除**：v1 采用 IGOUGO 阶段制（我方阶段 → 敌方阶段），单位没有先攻属性（`spec_rules.md` §9.2 数值表无此列、决策 D9）。此前的"先攻排序行动条"设计已废弃 | — | — |

> **没有 `max_hp` 字段** —— v1 不引入独立生命值（见下方说明）。

**`ResTier`（物抗/魔抗五档，用户 2026-09-30 澄清 C1）**

```gdscript
enum ResTier { NONE = 0, LOW = 200, MID = 400, HIGH = 800, IMMUNE = 1000 }  # 内部千分比
```

| 档位 | 减伤 | 伤害乘数 `(1-R)` | 对纯力量输出者的等效耐久 | 设计用途 |
|---|---|---|---|---|
| `NONE` 无 | 0 | ×1.0 | ×1.00 | 脆皮输出（弓手/弩手） |
| `LOW` 低 | 0.2 | ×0.8 | ×1.25 | 标准兵种 |
| `MID` 中 | 0.4 | ×0.6 | ×1.67 | 重装/精英 |
| `HIGH` 高 | 0.8 | ×0.2 | **×5.00** | 专职肉盾（"必须用破甲或魔法"） |
| `IMMUNE` 免疫 | 1.0 | ×0 | **不可击杀** | ⚠️ 只能做 Boss 机制，v1 普通关卡不要用 |

> ⚠️ **档位不可加点**（升级池里没有它）。档位之间的耐久跳跃很大（低→高 是 4 倍），所以它表达的是**兵种身份**，不是成长曲线。
>
> ⚠️ **每方高抗（HIGH）单位建议 ≤ 1 个**（`spec_rules.md` D33）：高抗是 ×5 耐久，堆多了会把单场战斗拖到 7-15 回合，破坏"3-6 回合"的节奏目标。

**其他 v1.2 同步要点**（详见 `spec_rules.md` 的「v1.2 变更说明」）

| 项 | v1.2 规定 |
|---|---|
| 属性上限 | 力量 **30**、护甲 **24**、破甲伤害 **18**（五档乘法耐久 + 加法升级，旧上限只够升 2 级，故上调） |
| 精力上限 | 仍为 **≤ 4 点**（K3 约束）——因此 `EPmax` 已到 4 的原型**不能再靠"加精力上限"成长**，加点池里该选项对它应禁用 |
| 护甲池存储 | 因为破甲伤害可能出现 `.5` 点，**护甲池必须按千分比整数存**（不能按"点"存整数），否则伤害表不可复现 |
| 死锁处理 | `护甲 ≥ 力量 → D=0` 降为**调试面板提示级**，不设硬断言（PvE，玩家可回档） |
| 高低差 | 默认 **0**（关闭）；`HEIGHT_POWER_MOD` 可开启作为风味机制 |
| 免疫档 | v1 普通关卡**不使用**；只作 Boss 机制且需先有魔法技能 |

**`BalanceConfig.res_mode`（默认已改为 `MULTIPLY`）**

| 值 | 公式 | 说明 |
|---|---|---|
| `RES_MULTIPLY`（**v1 默认，用户澄清 C2**） | `(P'-A) * (1-R)` | **物抗 = 真减伤**：`2 点差值 × 高抗(0.2) = 0.4 → 40% 造成 1 点`（用户给的算例） |
| `RES_DIVIDE`（备选） | `(P'-A) / (1-R)` | 按原文除式；会让物抗变成"物理易伤"，仅作配置项保留 |
| `RES_FLAT`（备选） | `(P'-A) - R*P'` | 按攻击力比例削伤 |

`res_mode` 参与 `rules_config_hash`（§9 存档字段），改了它旧存档必须提示重开或重新平衡。`damage.gd` 是**唯一**读取该开关的地方，且必须被 `get_preview` 与 `submit` 共用（§11）。

> **关于"血量"**：原文未提"生命值"，但出现"休息恢复力量与护甲""力量作为攻防一体属性"。v1 采用最省解释、也最贴合原文的模型：
> **没有独立 HP；"力量"与"护甲"本身就是可被打掉的资源**（力量归零 = 单位失去战斗力 = 阵亡，护甲归零 = 不再能抵挡但仍然活着）。
> - 力量既是"输出值"也是"血条"（休息可恢复，与 R8 完全吻合）；
> - 护甲是"第二血条 + 减伤源"，被打穿后单位变得脆弱但未死；
> - 这让"每回合选择攻击力量还是护甲"成为**真正有意义的战术抉择**（打力量=击杀，打护甲=削弱防御/逼对方休息）。
>
> **备选（若用户本意是传统 HP）**：加一个 `hp_max` 字段，力量/护甲可被打掉但不致死，归零时只惩罚输出/防御。切换成本：只改 `damage.gd` 的"扣血目标"与 `unit_state.is_alive()`，**其余全部不动**。此点列入需用户确认清单（§11 Q1）。

---

## 3. UnitData（兵种原型，`Resource`）

```gdscript
class_name UnitData extends Resource

@export var id: StringName                    # "melee_grunt"
@export var display_name: String              # "盾兵"
@export var role: int                         # Role.MELEE / BALLISTIC / RANGED
@export var can_melee: bool = true
@export var can_ranged: bool = false
@export var can_ballistic: bool = false

@export_group("基础属性（千分比）")
@export var base_stats: Dictionary            # 见 §2 字段名
@export var growth_points_per_level: int = 3  # R5：每级 +3
@export var growable: Array[StringName]       # 该兵种允许加点的属性（R5 池子的子集）

@export_group("升级曲线")
# 口径（必须与 spec_rules.md §8.1 / §13.1 D10 一致）：
#   每一级"新增"人头阈值 = [1,2,4,8]（每级清零重新计数）
#   等价的"累计"阈值     = [1,3,7,15]（满级共 15 个人头）
# 本字段存【累计】阈值，实现只做一次比较：kills >= thresholds[level-1] 即升级。
@export var kill_thresholds_cumulative: Array[int] = [1, 3, 7, 15]
@export var max_level: int = 5
# 备选 LEVEL_THRESHOLD_MODE="per_level_reset"：存 [1,2,4,8] 并每级清零 kills。
# 注意：若把 [1,2,4,8] 当作"累计"阈值，满级只需 8 杀 —— 那是另一套成长曲线，不要混用。

@export_group("表现（程序化，无需素材）")
@export var body_shape: int                   # BodyShape.CAPSULE / BOX / PRISM ...
@export var body_color: Color
@export var body_scale: Vector3 = Vector3.ONE # 护甲越高越粗壮（表现层用）
@export var accent_shape: int
@export var weapon_shape: int
@export var move_speed_visual: float = 1.0

@export_group("AI")
@export var ai_profile: int                   # AIProfile.AGGRESSIVE / DEFENSIVE / RANGED_KITER ...
```

**v1 内置原型（10 个，数值见 `docs/spec_rules.md` 的基准表）**

| id | 名称 | 定位 | 特点 |
|---|---|---|---|
| `melee_grunt` | 民兵 | 近战 | 低属性，人头饲料，1 级 |
| `melee_soldier` | 剑士 | 近战 | 标准近战 |
| `melee_tank` | 盾卫 | 近战 | 高护甲、低力量、破甲低 |
| `melee_breaker` | 破甲手 | 近战 | 破甲伤害高，专门打护甲 |
| `ballistic_bomber` | 掷弹兵 | 弹道 | 落地判定范围大、可打多单位 |
| `ballistic_thrower` | 投石手 | 弹道 | 判定范围小、伤害高 |
| `ranged_archer` | 弓手 | 远程 | 必中、射程 6 |
| `ranged_sniper` | 弩手 | 远程 | 射程 10、脆 |
| `resist_wraith` | 虚体 | 特殊 | 高物抗（R=50%）低护甲 → 逼玩家用破甲 |
| `boss_captain` | 队长 | 精英 | 3 级开局、数值全面 |

---

## 4. LevelData（关卡，`Resource`）

```gdscript
class_name LevelData extends Resource

@export var id: StringName
@export var display_name: String
@export var grid_type: int = GridType.SQUARE     # 预留 HEX
@export var width: int = 12
@export var height: int = 12
@export var tiles: PackedInt32Array               # 长度 width*height，值为高度阶（0/1/2）
@export var player_spawns: Array[Vector2i]
@export var enemy_spawns: Array[Vector2i]
@export var enemy_units: Array[StringName]        # UnitData id
@export var enemy_levels: Array[int]              # 与 enemy_units 对齐
@export var victory: int                          # Victory.ANNIHILATE / SURVIVE_ROUNDS / REACH
@export var victory_param: int = 0                # 例如 SURVIVE_ROUNDS 的回合数
@export var intro_text: String
```

---

## 5. BattleSetup（战斗输入）与 BattleResult（战斗输出）

```gdscript
class_name BattleSetup extends RefCounted
var level: LevelData
var player_units: Array[BattleUnitSpec]      # {unit_data_id, level, allocated_points, kills_carried}
var prng_seed: int                           # uint32（32 位 LCG；不是 Godot RandomNumberGenerator 的 64 位种子）
var prng_kind: StringName = &"lcg32"         # 必须与实现一致，否则跨语言黄金用例失效
var balance: BalanceConfig
var debug_flags: Dictionary                  # {"always_hit": true, "no_energy": true}

class_name BattleResult extends RefCounted
var victory: bool
var rounds_taken: int
var survivors: Array[BattleUnitReport]       # {unit_id, level, kills, hp_left, exp_progress}
var dead: Array[BattleUnitReport]
var unspent_points: Dictionary               # {unit_id: int} → 结算面板用
var level_ups: Array[Dictionary]             # {unit_id, from, to}
var rng_state: int                           # 便于继续战斗
```

---

## 6. UnitState（运行时状态，**进存档**）

```jsonc
{
  "uid": 3,                      // 战斗内唯一 id
  "data_id": "melee_soldier",    // 指向 UnitData
  "side": 0,                     // 0=玩家 1=敌方
  "attack_type": "MELEE",        // 固有攻击方式（MELEE/BALLISTIC/RANGED），冗余存储便于校验
  "pos": [4, 7],                 // [x, y] 格子坐标（高度由 tiles 决定）
  "facing": 2,                   // 朝向（表现用 + 弹道瞄准初始方向）

  "power_max": 9000,             // ★上限（原型 + 升级加点）—— 休息恢复的钳制目标、升级校验依据
  "armor_max": 6000,
  "power_cur": 7000,             // ★当前池（被打掉后的值）—— 进攻项与"生命"
  "armor_cur": 4500,             // ★当前池 —— 减免项

  "stats": {                     // 不随战斗变化的固定属性
    "phys_res_tier": 200,        // ★物抗档：无0/低200/中400/高800/免疫1000（不可加点）
    "mag_res_tier": 200,         // ★魔抗档：v1 不参与结算（魔法伤害只能由技能打出）
    "armor_break": 2000,         // = 破甲伤害 2 点（千分比）
    "energy_max": 4000,          // = 精力上限 4 点
    "rest_power": 2000,          // = 休息恢复力量 2 点
    "rest_armor": 2000,          // = 休息恢复护甲 2 点
    "move": 4,                   // 移动力（格，整数，不用千分比）
    "range_ranged": 0,           // 射程（格，整数；非远程为 0）
    "radius_ballistic": 0        // 弹道落地判定半径（格，整数）
    // 注意：v1 没有 initiative 字段（IGOUGO 阶段制，单位无先攻属性）
  },
  "base_stats": { ... },         // 原型基础值（升级加点基于它算，便于回溯）
  "allocated": { "power": 3000, "armor": 0, ... },  // 已分配的升级加点（用于回算上限与校验）

  "level": 2,
  "kills": 3,                    // ★累计人头（跨战斗累计，见 §11 Q8）
  "kills_this_level": 0,         // ★本级已累计人头（配合 kill_thresholds_cumulative）
  "unspent_points": 3,           // 待分配属性点
  "energy": 2000,                // 当前精力（千分比）= 2 点
  "energy_used_this_turn": 2000, // ★本回合已投入的精力 —— 缺这个字段会导致"存读档重置每回合 3 点额度"
  "alive": true,
  "has_moved_this_turn": false,
  "has_acted_this_turn": false,
  "status": {}                   // 预留：减速/燃烧等
}
```

**不变量（必须由测试保护）**

1. `energy <= stats.energy_max`
2. `alive == (power_cur > 0)`（`DEATH_RULE="power_only"`：**护甲池归零不阵亡**）
3. `armor_cur >= 0`、`power_cur <= power_max`、`armor_cur <= armor_max`
4. `power_max == base_stats.power + allocated.power`、`armor_max == base_stats.armor + allocated.armor`（成长不写进 `base_stats`，而是累加到 `allocated`，这样"原型值"永远可回溯、上级校验可复算）
5. `level <= 5`，`sum(allocated) + unspent_points == (level-1) * 3`
6. `energy_used_this_turn <= 3000`（每回合 3 点上限；阶段推进时清零）
7. 两个存活单位的 `pos` 不同
8. `phys_res_tier` / `mag_res_tier` ∈ `{0, 200, 400, 800, 1000}`（五档枚举，**不是连续值**；`1000` = 免疫 → 力量线伤害恒为 0）

---

## 7. ActionRequest（行动意图）

规则层是"纯函数式"的：给一个 `ActionRequest`，产出事件数组与状态变更。

```gdscript
class_name ActionRequest extends RefCounted
enum Kind { MOVE, ATTACK, REST, END_TURN }
var kind: int
var actor_uid: int

# MOVE
var path: Array[Vector2i]

# ATTACK
var attack_type: int          # AttackType.MELEE / BALLISTIC / RANGED
var target_uid: int = -1      # 近战/远程：目标单位
var attack_stat: int          # AttackStat.POWER（打力量） / ARMOR（打护甲）
var energy_spent: int         # 0..3 点（R6）

# BALLISTIC 专用（R10）
var aim_dir: Vector2         # 水平单位方向向量（由朝向/角度决定）
var aim_elevation: float     # 仰角（弧度）
var aim_power: float         # 0..1 力度
```

**规则层校验**（不合法直接返回错误事件，不崩溃）：行动权、阶段顺序、精力上限、目标合法性、射程、邻接、路径合法性。

---

## 8. BattleEvent（事件流，驱动动画 + 日志）

所有表现层行为都由事件驱动，事件同时是战斗日志与回放基础。

| type | 字段 | 表现层反应 |
|---|---|---|
| `battle_start` | `order[]` | 播放开场、行动条初始化 |
| `turn_start` / `turn_end` | `uid`, `round` | 高亮行动单位、相机跟随 |
| `move_start` / `move_step` / `move_end` | `uid`, `path[]`, `pos` | 沿路径跳跃移动动画 |
| `attack_declare` | `uid`, `target`, `attack_type`, `attack_stat`, `energy` | 播攻击前摇、精力特效 |
| `ballistic_fire` | `uid`, `origin`, `velocity` | 生成弹体 + 拖尾 |
| `ballistic_land` | `pos`, `radius` | 落地爆炸粒子 + 相机抖动 |
| `damage` | `target`, `amount`, `damage_type`, `remaining_power/armor` | 伤害数字、闪白、抖动 |
| `miss` | `target`, `reason` (`no_damage`/`prob_miss`/`geometry`) | MISS 数字 + 尘土 |
| `heal` | `target`, `power`, `armor`, `energy` | 休息光圈 + "+1 精力" |
| `unit_died` | `uid`, `killer_uid` | 倾倒淡出、行动条移除 |
| `level_up` | `uid`, `from`, `to`, `points` | 升级光柱 + 提示 |
| `round_end` | `round` | 回合横幅 |
| `battle_end` | `victory`, `result` | 结算面板 |
| `error` | `code`, `message` | 调试提示（正式版静默） |

**事件确定性要求**：给定 `(seed, setup, action[]序列)`，事件序列必须**逐字节一致**（这是回放与测试的基础）。

---

## 9. 存档 Schema（`user://saves/slot_N.json`）

```jsonc
{
  "schema_version": 1,
  "rules_version": 1,                  // 规则版本（与引擎版本解耦）
  "app_version": "0.1.0",
  "balance_hash": "a1b2c3d4",          // 平衡参数哈希：改了平衡数值后读旧档必须提示
  "rules_config_hash": "e5f6a7b8",     // res_mode / HEIGHT_POWER_MOD 等开关的哈希
  "created_at": "2026-09-30T18:40:00+08:00",
  "saved_at": "2026-09-30T19:12:33+08:00",
  "save_kind": "battle",               // battle | world（为 RPG 外层预留）

  "progress": {
    "cleared_levels": ["level_01"],
    "current_level": "level_02",
    "party": [
      { "unit_id": "u_hero_01", "data_id": "melee_soldier",
        "level": 2, "kills": 3, "kills_this_level": 0, "unspent_points": 0,
        "allocated": { "power": 3000, "armor": 3000 },
        "alive": true }
    ]
  },

  "battle": {
    "level_id": "level_02",
    "board_w": 12, "board_h": 12,
    "tiles": [0, 0, 1, 2, ...],        // 长度 board_w*board_h，值为高度阶（0/1/2）
    "prng_kind": "lcg32",              // 必须与实现一致，否则跨语言黄金用例失效
    "prng_seed": 123456789,            // ⚠️ uint32；同时满足 ≤ 2^53-1（Web 下 JSON 由 JS 解析为 double）
    "prng_state": 991827645,           // ⚠️ uint32，读取档后继续同一序列（不是 64 位状态）
    "phase": "PLAYER",                 // PLAYER | ENEMY | RESOLVE
    "turn_side": 0,
    "round": 3,
    "units": [ /* UnitState[] 见 §6 */ ],
    "battle_result": null,             // 结算后写入（victory / 存活 / 人头 / 升级）
    "log_tail": [ /* 最近 50 条事件的摘要，便于读档后重放 UI 状态 */ ]
  },

  "settings": { "volume_master": 0.8, "outline": true, "camera_pitch": 55 }
}
```

> **注意**：v1 采用 IGOUGO 阶段制，所以**不再有 `order`/`turn_index`**（那是"先攻排序"设计的残留）。当前进度由 `phase` + `turn_side` + 各单位自己的 `has_moved_this_turn`/`has_acted_this_turn` 表达。

### 9.1 存读档流程

```
保存：snapshot() → JSON.stringify(indent=1) → 写 slot_N.json.tmp → rename 覆盖 slot_N.json
读取：读 JSON → 检查 schema_version → 若旧：跑 migrations 链 → 校验不变量（§6）
      → validate(不通过则拒绝并提示，绝不半加载) → 重建 BattleState → 重建视图
```

### 9.2 版本迁移

```gdscript
const MIGRATIONS := {
  1: func(d: Dictionary) -> Dictionary:   # 1 → 2 的未来示例
      d["battle"]["units"].map(func(u): u["status"] = u.get("status", {}))
      d["schema_version"] = 2
      return d,
}
```

规则：只允许**加字段**（给默认值），不允许静默改变已有字段语义；语义确实要变时，必须写迁移函数并在 `CHANGELOG` 记录。

### 9.3 存档码（导出/导入）

```
json → gzip → base64 → "BC1:" + 结果        （BC1 = 格式前缀 + 版本）
```
用于：Web 下换浏览器、清缓存前备份、把存档发给朋友复现 bug。

### 9.4 Web 导出下的落点与风险

- Godot Web 下 `user://` 由引擎映射到浏览器的 **IndexedDB**；**不要**假设它能被用户手动看到。
- 风险：用户清站点数据 / 隐私模式 / 配额清理 → 存档丢失。缓解：自动存档 + "存档码导出"提示（首次进入游戏与每次通关后各提示一次）。
- 具体行为与官方说明见 `docs/research/tech_feasibility.md`（含官方文档链接）。

---

## 10. AI 决策的输入输出（`src/ai/dumb_ai.gd`）

```gdscript
func decide(state: BattleState, uid: int, balance: BalanceConfig) -> Array[ActionRequest]
```

v1 评分函数（透明度优先于聪明）：

```
对所有可达格 g（BFS，move 点预算，ZOC 额外消耗）：
  对所有可攻击目标 t：
    对 attack_stat ∈ {POWER, ARMOR}：
      对 energy k ∈ {0..min(3 - energy_used_this_turn, 当前精力)}：   # 扣除本回合已投入的额度
        score = 期望伤害(E[D] 含命中概率)
              + 击杀奖励(50) + 越级击杀奖励
              + 目标威胁度权重          # 优先打高输出单位
              - 站位风险(站在多少敌人可攻击范围内)
              - 距离衰减(-1.6 × max(0, 距离-1))   # 防止远程单位站桩免费输出
              - 精力机会成本(留给后续回合)
        if t.armor_cur == 0: ARMOR 选项的 score = 0   # ★目标护甲池已空，破甲线不再有价值
若最高分 <= 休息阈值且自身力量 < 60% 上限 → REST
否则 → MOVE(到最佳格) + ATTACK(最佳组合)
# 硬要求：任何情况下都必须给出「移动 + 一个动作」，绝不站桩（实测站桩 AI 胜率 0%）
```

**AC**：AI 决策耗时 < 20 ms/单位（12×12 网格、标准 4v4 = 8 单位；大型 6v6 = 12 单位时放宽到 < 30 ms）。

---

## 11. 接口契约（跨层调用）

| 调用方 | 接口 | 返回 |
|---|---|---|
| 表现层 | `BattleCore.get_state() -> BattleState` | 只读快照（表现层不得修改） |
| 表现层 | `BattleCore.submit(req: ActionRequest) -> Array[BattleEvent]` | 事件数组 |
| 表现层 | `BattleCore.get_preview(req) -> Preview` | 移动范围 / 伤害预览 / 命中率（HUD 用） |
| RPG 外层 | `BattleScene.battle_finished -> BattleResult`（signal） | 见 §5 |
| 存档 | `SaveService.save(slot:int, state) -> bool` / `load(slot:int) -> BattleState` | 见 §9 |
| AI | `AIController.decide(state, uid) -> Array[ActionRequest]` | 与玩家走**同一套**校验，不能作弊 |

`get_preview` 与 `submit` 必须走**同一份伤害函数**（`damage.gd`），杜绝"预览显示 3 实际打 2"的经典 bug——这条要写进 code review checklist。

---

## 12. 命名与约定

- 文件：`snake_case.gd`；类：`PascalCase`（`class_name`）；常量枚举：`UPPER_SNAKE`。
- 坐标：`Vector2i(x, y)` 为格子坐标；世界坐标 `x` 向右、`z` 向前、`y` 向上（表现层用 `grid_to_world()` 单向转换，**规则层不知道世界坐标**）。
- 高度：`tiles[i]` 为高度阶，`0=地面, 1=高台, 2=城墙`；每阶 = 0.5 世界单位。
- 距离：所有"格数"均指**曼哈顿距离**（与"近战 4 邻格、无对角"一致）；**弹道落地判定也用曼哈顿菱形**（`spec_rules.md` 决策 D12：以落点格为中心、曼哈顿距离 ≤ `SPL` 的菱形；SPL=1 → 落点 + 4 邻格共 5 格），**不是圆形/欧氏距离**。理由：复用同一套 4 邻格函数、让"落地判定范围"升级项有清晰可数的价值、并在无辅助瞄准下让范围可预测。备选 `SPLASH_SHAPE="chebyshev"`（3×3）与 `"euclid"` 由配置项切换；无论选哪个，**全局只有一处实现**（`ballistics.gd`），测试名必须写明所用度量。
- 事件字段名一经发布不得重命名（迁移成本极高），新增只能加字段。
