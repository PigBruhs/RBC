# 重构方案：拆掉 `battle_scene.gd`（4587 行 / 239 函数）

> **用户口径（2026-10-04 确认）：只拆 `battle_scene.gd`，行为零变化，并同步改测试。**
> 本文是下一轮施工的依据。所有数字都是本机实测值，不是估计；证据文件见各节标注。
> 施工顺序按 §4 的阶段表走，**每个阶段结束都必须跑 §5 的验收**。

---

## 0. 一句话结论

`core/` 层不用动（健康）。**膨胀全部集中在视图层的 `battle_scene.gd`**，
而它同时是"唯一一个什么都管"的类：状态、搭场景、UI、输入、回合机、弹道结算、哨兵、
直升机、巡飞弹、日志、测试接口。拆分的真正障碍不是行数，是**四件事**：

1. **120 个私有成员被 `playtest.gd` 当公开 API 用**（1019 处引用）—— 先收口，再拆。
2. **10 个成员变量被 7~13 个职责块共享**（`units` / `gm` / `active` / `rng` / `phase` / 矩形 / …）—— 先归位，再拆。
3. **5 个私有方法已经是 Callable 事实接口**（注册进 field / gm / hooks / timer）—— 改名即断。
4. **`battle_ui.gd` 号称"只走 `ui_*`"，实际直接读宿主字段**（`host.selected` / `host.active` / 魔数比 `phase`）。

---

## 1. 实测现状

### 1.1 规模

| 文件 | 行数 | 说明 |
|---|---|---|
| `game/src/view/battle_scene.gd` | **4587**（有效代码 3330 / 空行 671 / 注释 586） | **239 个函数**（234 实例 + 5 static）；**108 个成员变量** |
| `game/tools/playtest.gd` | 3172 | 563 项检查；`_s.xxx` 引用 **1019 处** |
| `game/tests/run.gd` | 1267 | **对 battle_scene 零引用**（纯 core 测试）|
| `game/src/view/battle_ui.gd` | 870 | 40 个 `ui_*` 契约 + 若干直接读宿主字段 |
| `game/src/core/*.gd`（21 个） | 4434 | 全部 `RefCounted`，零 `get_node()` / `get_parent()` |

`game/` 合计 17717 行：core 4434 / view 7901 / tools 4115 / tests 1267。

### 1.2 依赖方向（健康，不要破坏）

- `view → ai → core` 单向成立。
- core→view 只有 3 处渗漏，都是**注入的 `Node3D` 弱引用**，不是结构性反向依赖：
  - `unit.gd:65` `var visual: Node3D`、`placeable.gd:29` 同上；
  - `game_master.gd:80-81` `Target.pos()` 读 `unit.visual.position`（行走中用视觉位置算哨兵距离）；
  - `game_master.gd:30,36` `Pending.pylon` / `Pending.model` 持 `Node3D`。
- `GameMaster` 里塞了 `ai_enabled` / `ai_autoplay_player`（`game_master.gd:455-456`）——**职责越界**，属于 AI 驱动层。

### 1.3 前任自己留的备注（`battle_scene.gd:10-12`）

> 拆分方案（继承链：状态/场景/UI 归父类）已经验证可行，但父类里对子类方法的引用必须逐处改成
> `self.call(...)`，需要一次完整的、非正则的改写，留作单独一轮处理。

**本方案不走继承链**（那会让父类依赖子类、并且把 3330 行有效代码重新糊在一起）。
改用「**薄继承 + 模块组合**」：见 §2.1。

---

## 2. 拆分设计

### 2.1 目标形态

```
BattleScene (Node3D)                 ← 只剩"接线"：生命周期、_process 排程、输入分派、信号
  └─ BattleState (Node3D / 继承)     ← 持有跨模块共享状态与几何（§2.2），不含业务逻辑
       ├─ TurnMachine    回合机（队列推进 / 回合边界 / 胜负 / 连击）
       ├─ AiDriver       AI 决策执行
       ├─ BasicAttack    普攻唯一入口 _perform_basic 及其 basic 实现
       ├─ SkillRunner    技能唯一入口 _perform_skill 及各 cast 实现
       ├─ ProjectileSink 弹道物事件、落地/空爆/爆炸结算、破片、齐射
       ├─ SentryRunner   哨兵队列推进与射击
       ├─ HeliRunner     直升机：悬浮 / 坠机 / 爬升轰炸全流程
       ├─ LoiterRunner   巡飞弹制导与发射器
       ├─ PlacementRunner 沙盒放置
       ├─ MoveService    寻路 / 可达 / 走位
       ├─ ViewFx         高亮 / 待确认标记 / 落点环 / 闪光 / 日志
       └─ (battle_ui.gd 不动，只把越界的直接读宿主改成走 ui_*)
```

**模块一律 `RefCounted`，不继承 Node，构造函数注入 `BattleState` 引用。**
理由：避免又造一个 God object 的继承链；模块拿 `st.units` / `st.gm` / `st.rng` 这样的显式路径，
依赖关系在构造函数那一行就看得见。

### 2.2 必须先归位的共享状态（拆分主障碍）

| 状态 | 被几个职责块共享 | 归位 |
|---|---|---|
| `units` | 13 | `BattleState`（只读为主） |
| `gm`（GameMaster） | 11 | `BattleState`，但**先瘦身**（§3.4） |
| `active` | 10 | `BattleState` |
| `rng` | 9 | `BattleState` |
| `phase` | 8 | `BattleState` |
| `PX/PY/PW/PH` + `GW/GH`（可行动区域/物理边界） | 各 7-8 | `BattleState` 缓存，来源仍是 `Level` |
| `_camera` | 7 | `BattleState`（表现层引用） |
| `placeables` | 7 | `BattleState` |
| `ui`（BattleUI） | 7 | `BattleState` |
| `field`（ProjectileField） | 7 | `BattleState` |
| `reachable` / `attackable` / `selected` / `_place_kind` / `_action_menu` / `_arrow_root` / `cell_targets` / `_aim_skill_id` / `_pending_*` | 各 4-5 | 就近归到对应模块 |

### 2.3 五个"事实接口"（改名即断，必须保留原名或同步改注册处）

| 私有方法 | 注册点 |
|---|---|
| `_arrow_hit_check` | `field.setup(self, gm, _arrow_hit_check)` — `battle_scene.gd:712` |
| `_on_projectile_event` | `gm.on_projectile_event = _on_projectile_event` — `:716` |
| `_hook_heli_crash` | `_passive_hooks = {"heli_crash": _hook_heli_crash}` — `:3099-3101` |
| `_on_revive_timeout` | `tm.timeout.connect(_on_revive_timeout.bind(u))` — `:3171` |
| （箭矢 QTE 收尾） | `q.finished.connect(...)` — `:2651` |

### 2.4 测试耦合面（`playtest.gd` 的 120 个私有成员）

`playtest.gd` 调用私有方法 **81 个** + 读写私有字段 **39 个**，共 1019 处 `_s.xxx`。典型：

```gdscript
_s._hint_layer.get_children()          # playtest.gd:14
_s._salvo_u != null                    # :34  （轮询私有状态做同步）
_s._turn_just_finished = null          # :108
_s.phase = _s.Phase.IDLE               # :109
_s._fire()                             # :120
_s._rocket_salvo / _s._loiter_pick_control / _s._dive_tick / _s._pending_root / _s._gm_busy
```

探针也有：`probe_arena` 12 个、`probe_v14` 17 个、`probe_r92` 4 个、`probe_r89` 3 个、`sim_ai` 4 个私有成员。

**处理策略（阶段 0，必须先做）**：在 `battle_scene.gd` 里加一段"**测试门面**"区，
把测试真正需要的东西显式暴露成**公开**名字（`for_test_*` 方法 + 只读属性），
然后**逐个把 playtest 的 `_s.xxx` 换成门面调用**。之后再搬函数时，门面里改一行即可，
不会一次改崩 1019 处。

> 注意：`_s.phase = _s.Phase.IDLE` 这类**写私有字段**的用法，要在门面里给一个
> `for_test_set_phase(p)`，而不是继续裸写字段。

---

## 3. 附带清理（用户口径：允许死代码清理，但必须行为零变化）

### 3.1 全仓零引用函数（可直接删）

`_refresh_upgrades`(:695)、`_on_result_continue`(:1776)、`_spawn_fragment`(:2577)、
`_pending_cell_mark`(:3953)、`_any_placeable_in_blast`(:3135)。

### 3.2 死成员变量（声明后无引用）

`_ui_layer`(:131)、`_hint_label`(:116)、`_queue_label`(:118)、`_upgrade_box`(:120)、
`_attack_hint`(:122)、`_btn_end_turn`(:126)、`_result_box`(:186)、`_result_label`(:188)、
`_result_sub`(:190)、`_menu_anchor`(:209)。

> ⚠️ 删之前逐个 grep 确认；有些是"UI 已按用户要求移除、变量留着免得调用崩"的**刻意**残留
> （规格 §九："左下角只保留队列可视化，`ui_` 调用不会崩"）。**这类保留并加一行注释说明为什么留。**

### 3.3 死信号

`unit_died`(:20) 从未 emit/connect；`round_started`(:1308) 无监听；`turn_started`(:1402) 仅测试连接。

### 3.4 `GameMaster` 瘦身（四合一 → 三合一）

它现在同时管：调度型 `Pending` + 环境型哨兵 + 弹反被动 + 复活/死亡顺序，另带 AI 开关。

| 现在 | 去处 |
|---|---|
| `pending` 调度 + `revive_at` + `death_order` + `turn_count` | 留 GM，但 `turn_count` 抽成显式的 `GameClock`（现在是唯一时钟，同时驱动复活 :510 / 枪榴弹延时 / 老国王开炮 :1688 / 发射器冷却 :508） |
| 哨兵 `sentries` / `check_*` / `sentry_tick` | 候选：`SentryRunner`（视图侧驱动者）+ GM 只留数据 |
| `ai_enabled` / `ai_autoplay_player`(:455-456) | 移到 AI 驱动层 |
| `Target.pos()` 读 `unit.visual`(:80-81) | 保留（行走中的真实位置只能问 view），但**写进注释说明这是刻意的表现层依赖** |

### 3.5 重复实现（合并到一处）

- `_fmt` 三份逐字相同：`combat.gd:146` / `damage.gd:223` / `battle_scene.gd:4195` → 收敛到 `Rules` 或新建 `Fmt`。
- `_cc`(:3338) ≡ `Ordnance._cell_center`：`battle_scene.gd:3338`。
- `_placeable_at`(:892) ≈ `_placeable_near`(:3536)。
- `ColorCycle.color_at`(:24) ≡ `edge_at`(:30)。
- `battle_scene._placeable_data`(:823) ≡ `run.gd:_pl_data`(:1263)。
- **身体半径/身高写了 6 处**：`Targeting:12,15` / `Damage:101-102` / `Ordnance:152-153` / `battle_scene:243` / `UnitData:12` → 全部引用 `Targeting` 的常量。
- 4 份探针样板 `_chk` / `_unit` / `_move` / `_shot` → 抽 `game/tools/probe_common.gd`。

### 3.6 数值多源（P1，拆完之后再做，别再混进同一轮）

现在数值有**四个来源**：`UnitData`（bc_stat 生成）/ `AttackProfile`+`Skills`+`Passives` 三张表 /
`Level.HELI_DEFAULTS` / 散在 `Ordnance`、`Loiter`、`Spread`、`GameMaster` 里的常量。
`AttackProfile.cost_of` 与 `Level.heli()["basic_cost"]` 就是一对双源。

**这一轮不动**（会改变数值口径），只登记为下一轮的课题。

---

## 4. 施工阶段（每阶段一个可回滚的提交）

| 阶段 | 内容 | 交付判据 |
|---|---|---|
| **P0** | ① 写 `battle_scene` 测试门面（`for_test_*`）；② 把 `playtest.gd` 的 1019 处 `_s.xxx` 逐步换成门面；③ 删 §3.1 零引用函数、§3.2 死变量（逐个确认）、§3.3 死信号 | playtest 项数不减少且失败 0；run.gd、5 个探针、sim_ai 全绿 |
| **P1** ✅ | **已完成（第 97 轮第一期）**：`view/sentry_runner.gd`(57) 哨兵编排 ｜ `view/view_fx.gd`(364) 表现层 15 个函数 ｜ `core/grid_math.gd`(27) 格中心去重（`_cc` 与 `Ordnance._cell_center` 原本是逐字复制品，现唯一实现）。死代码 `_pending_cell_mark` 已删 | ✅ run 全过 ｜ playtest **565/0** ｜ arena 0 ｜ r89 3 项 ｜ r92 11 项 ｜ sim_ai 2/2 |
| **P2** ⏳ | **已完成两块（第 97 轮第二期）**：`view/projectile_sink.gd`(486) 弹道与爆炸结算（19 函数）｜ `view/basic_attack.gd`(258) 普攻唯一入口（14 函数）。**还剩**：技能（24 函数/576 行）、回合机、移动寻路、放置沙盒、巡飞弹 | ✅ 同上全绿 |
| **P3** | 提取最难的两块：UI 菜单与刷新（406 行 / 33 个成员）、瞄准与输入（366 行 / 29 个成员）；顺手把 `battle_ui.gd` 直接读宿主字段的 6 处改成走 `ui_*`（含把魔数 `phase == 0 + 4` 换成枚举比较） | 同上 + 手动开一次编辑器确认菜单/瞄准/队列条肉眼正常 |
| **P0** | **清账期**（务必做，别忘）：① 立测试门面（`for_test_*`），把 `playtest.gd` 的上千处 `_s.xxx` 换成门面调用；② 然后**批量删掉宿主的薄包装**（约 350 行过渡成本）；③ 删 §3.1 零引用函数、§3.2 死变量、§3.3 死信号 | playtest 项数不减少且失败 0；run.gd、5 个探针、sim_ai 全绿 |
| **P3** | 提取最难的两块：UI 菜单与刷新（406 行 / 33 个成员）、瞄准与输入（366 行 / 29 个成员）；顺手把 `battle_ui.gd` 直接读宿主字段的 6 处改成走 `ui_*`（含把魔数 `phase == 0 + 4` 换成枚举比较） | 同上 + 手动开一次编辑器确认菜单/瞄准/队列条肉眼正常 |
| **P4** | 拆 `GameMaster` 四合一（§3.4）；合并重复实现（§3.5）；`battle_scene.gd` 目标 **≤ 800 行** | 同上 |
| **P5** | 清理仓库：删 `tools/godot/_smoke/`（旧原型，未跟踪，39.8 MB build + 29 KB 源码）；把 §3.6 的"数值多源"单独开一轮 | `git status` 干净；`docs/规格.md` 更新 |

### 第一期 + 第二期实测效果（第 97 轮）

| 文件 | 行数 | 说明 |
|---|---|---|
| `game/src/view/battle_scene.gd` | **4587 → 3731**（目标 ≤800） | **−856 行** |
| `game/src/view/skill_runner.gd` | 483 | P2：技能唯一入口 `perform_skill` + 5 种 cast 实现 + 轨道空袭 / 地毯式轰炸 / 枪榴弹 / 爬升轰炸 / 点格子确认（19 个方法） |
| `game/src/view/projectile_sink.gd` | 486 | 弹道事件 / 落地 / 空爆 / 击落 / 爆炸结算 / 破片 / 齐射 / 枪榴弹模型（19 个函数） |
| `game/src/view/view_fx.gd` | 364 | 高亮 / 待确认标记 / 黄勾 / 落点环 / 闪光（15 个函数） |
| `game/src/view/basic_attack.gd` | 258 | 普攻唯一入口 + 5 种 basic 实现 + 三条路径分派（14 个函数） |
| `game/src/core/game_clock.gd` | 68 | P4a：回合边界时钟 + 复活计时（从 GameMaster 拆出） |
| `game/src/view/sentry_runner.gd` | 57 | 哨兵编排与表现 |
| `game/src/core/grid_math.gd` | 27 | 格中心与"单位现在在哪"的唯一实现 |

**P0 清账期已完成**（这一期是"先付代价、后收益"的典型）：

1. **立测试门面**：`battle_scene.gd` 末尾新增 147 个 `t_*` 公开接口，覆盖 129 个私有成员
   （129 读 + 18 写 + 2 static，全部带类型，5 个协程接口带 `await`）。
   `playtest` + 5 个探针里的 `_s._xxx` 私有访问 **487 处 → 0**。
2. **删掉 45 个同名薄包装**：调用点改直连模块，53 个 `t_*` 转发目标跟着改。
   **保留 5 个**（`_apply_attack` / `_damage_placeable` / `_placeable_near` ← `projectile_sink`；
   `_rocket_salvo` / `_spawn_shell` ← `basic_attack`）——
   由此得到一条设计约束：**包装能不能删，取决于"有没有别的模块通过 `_st.` 调它"，而不是"测试要不要"**。
   5 个 `Callable` 事实接口改成直连模块（代价：5 个模块构造上移到 `field.setup` 之前，
   已验证安全——构造函数只注入 `_st`、无副作用）。
3. **门禁 `MODULES` 的语义随之改变**：它守的从"测试门面"变成**跨模块事实接口**。
4. **删死代码**：`_on_result_continue` / `_spawn_fragment` / `_any_placeable_in_blast`（全仓零引用），
   `_pending_cell_mark` 已随搬迁删除；`_refresh_upgrades` 因登记在门禁里，加注明原因后留待后续。

**P5 已完成**：删 `tools/godot/_smoke/`（35 文件 / 38.1 MB 旧原型）、`tools/__pycache__/`、`tools/_pt2.txt`；
`_fmt` 去重收敛到 `Rules.milli_text()`；`color_cycle.edge_at()` 转发 `color_at()`。
`balance_probe*.py` **保留** —— `docs/spec_rules.md:986` 有一条常设的跨语言对账要求点名它。

**这两期定下来的做法（后续每个模块都照抄，别再重新发明）：**

1. **模块 = `RefCounted` 子对象 + `_init(host)` 注入 + `var _st = null` 动态类型。**
   不能写 `var _st: Node3D` —— 宿主 battle_scene 没有 `class_name`，访问 `_st.gm` / `_st._log` 会在分析期报
   `Cannot find member ... in base 'Node3D'`。这与既有约定一致（`battle_ui.gd` 的 `host` 也是动态类型）。
2. **`t_*` 是测试唯一入口**：搬走函数后必须把宿主 `t_*` 的转发目标改到新模块，否则 playtest 断。
3. **测试直读的字段声明留在宿主**，模块通过 `_st._xxx` 读写（引用类型只给读接口就够了，
   因为 Array/Dictionary/Object 是引用语义 —— 但这也意味着这层"收口"对引用类型**并不真正封住写**）。
4. **纯函数走全局类，不绕宿主**：`GridMath.cell_center(...)` 直接用。

5. **⚠️ 搬函数前的第一步：`grep -rn '_st\._' game/src/view/*.gd`**
   这条是第 97 轮 P3 用一次 playtest 吊死 10 分钟换来的：
   mod-sentry 把 `_push_unit_stats` / `_show_action_menu` / `_hide_action_menu` 搬进 `action_menu.gd`，
   却没发现 `basic_attack.gd` 与 `skill_runner.gd` 正在通过 `_st._push_unit_stats(...)` 调它们 ——
   症状是运行时报 `Nonexistent function '_push_unit_stats' in base 'Node3D (battle_scene.gd)'`，
   而**编译期查不出来**（`_st` 是动态类型），playtest 就吊在那里。
   **规则**：一个函数只有在"没有别的模块通过 `_st.` 调它"时才能整个搬走；
   否则它必须**在宿主留一个公开转发行**（实现在模块），并注明"跨模块事实接口，别删"。
   这也解释了 45 个薄包装里为什么有 5 个删不掉。

6. **宿主 `t_*` 的转发目标要跟着改**：搬走函数后 `t_perform_skill()` 之类必须指向新模块，否则测试断。

**机械核对手法（这两期的质量保证，建议沿用）**：从 `git show HEAD:<file>` 抽出原函数体，
只允许事先写明的几类改写（去 `_st.` 前缀 / 去前导下划线 / 纯函数改走全局类 / 显式类型标注），
然后**逐行 diff**。两期结果：第一期 15/15 一致，第二期 14/14 + 19/19 一致（少数差异全部在事先写明的白名单里）。

**改 view 层必须先过编译门禁**（见 [`baseline.md`](baseline.md)）：`tests/run.gd` **不加载 `battle_scene.gd`**，
它绿不能证明视图层编译得过。第二期就因为这个漏掉了 8 处 `:=`-on-dynamic 类型推断错误，
直到跑 playtest 才炸（而且场景建不起来时进程不退出，会被 `--quit-after` 吊死十几分钟）：
```powershell
& $exe --headless --path game --check-only --script res://src/view/battle_scene.gd --quit-after 200
```

**新增 `class_name` 的副作用（新克隆必看）**：`.godot/global_script_class_cache.cfg` 需要重建，
否则 `--script` 直跑会报 `Identifier "Xxx" not declared`。跑一次即可：
```powershell
tools\godot\Godot_v4.7.2-stable_win64_console.exe --headless --path game --editor --quit-after 3000
```

---

## 5. 每阶段的验收（一条都不能少）

```powershell
$exe = "tools\godot\Godot_v4.7.2-stable_win64_console.exe"

& $exe --headless --path game --script res://tests/run.gd --quit-after 3000
& $exe --headless --path game --script res://tools/playtest.gd --quit-after 400000
& $exe --headless --path game --script res://tools/probe_arena.gd --quit-after 200000
& $exe --headless --path game --script res://tools/probe_r89.gd --quit-after 200000
& $exe --headless --path game --script res://tools/probe_r92.gd --quit-after 200000
& $exe --headless --path game --script res://tools/sim_ai.gd --quit-after 600000 -- --games=2 --seed=1
python tools/make_unit_data.py   # 必须幂等
```

**判据是"结果与 `docs/baseline.md` 逐项相同"，不是"全绿"就够了**：
- `playtest` 必须仍是 **563 项 / 失败 0 项**（项数掉了 = 有检查被静默跳过）；
- `probe_r89` 3 项、`probe_r92` 11 项；
- `sim_ai` 2/2 局跑完（每局的胜负与回合边界数允许因拆分的执行顺序变化而不同，但**不许卡死**）；
- 输出文件统一落 `.tmp_for_deepseek/`，并且**中文先 `Out-File -Encoding utf8`**。

重命名/拆分导致的**预期变化**（要显式确认，不算回归）：无。纯重构不改任何 observable 行为。

---

## 6. 风险与不做的事

| 风险 | 处置 |
|---|---|
| 一次改崩 1019 处测试引用 | **P0 先立门面**，之后每阶段只动门面里的一行 |
| 搬函数时漏掉事实接口（§2.3） | 5 处逐条对照；搬完 grep 这 5 个名字确认注册点还在 |
| `_process` 每帧串 13 件事（`:3562-3584`，注释还插在函数体里） | P3 拆成显式的 `_tick_*()` 列表，**保持调用顺序逐字不变**（顺序影响表现） |
| 回合机是软锁高发区 | P2 拆回合机时**不加任何新逻辑**；靠 playtest 第 39/47 节与 sim_ai 卡死检测兜底 |
| 顺手改数值 | **禁止**。这一轮任何数值变更都要单独一轮 + 更新 `bc_stat.md` + 重新生成 |

**明确不做**：不引入 `BattleContext` 之类的新抽象层去"统一"状态（那只是把 108 个成员换个地方放）；
不改 `Level.current` 这个 `static var` 全局态（改动会波及探针）；不改 AI 计划字典 schema（只加注释文档化）。

---

## 7. 参考

- 现状与命令：[`docs/baseline.md`](baseline.md)
- 当前口径（**权威**）：[`docs/规格.md`](规格.md)
- 数值唯一来源：[`bc_stat.md`](../bc_stat.md)
- 已过时的早期设计（顶部有 ⚠️ 头注，仅供追溯）：[`spec_rules.md`](spec_rules.md)、[`design_v1.md`](design_v1.md)、[`data_schema.md`](data_schema.md)
