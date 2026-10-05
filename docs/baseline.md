# 验证基线（改动前必须对得上的那条线）

> 用途：任何重构 / 数值改动之后，用同一组命令复跑一遍，结果必须与下表一致。
> 这些数字是 **2026-10-04** 在本机（Godot 4.7.2 stable）实际跑出来的，不是估计值。
> 复跑方式见文末"命令"。**改了数值就更新本表**，否则它就变成了误导。

## 一、当前基线（全绿）

| # | 入口 | 项目 | 实测结果 |
|---|---|---|---|
| 1 | `tests/run.gd` | 规则自检 | ✅ 全部通过（纯 core，不加载场景） |
| 2 | `tools/playtest.gd` | 试玩链路 | ✅ **570 项检查，失败 0 项** |
| 3 | `tools/probe_arena.gd` | 竞技场探针 | ✅ 失败 0 项（含复活点落位、枪榴弹被击落整发消失） |
| 4 | `tools/probe_r89.gd` | 火箭探针 | ✅ 3 项检查，失败 0 项 |
| 5 | `tools/probe_r92.gd` | 制导探针 | ✅ 11 项检查，失败 0 项 |
| 5c | `tools/probe_laser.gd` | **激光类探针** | ✅ 52 项检查，失败 0 项（HIT_R 0.25=直径 0.5 格/起点高度 3⑥环仍 6/帧伤累计/统一结算/地形阻挡/魔法伤害无视护甲吃魔抗） |
| 5d | `tools/probe_reaper.gd` | **Reaper 碰撞与建模** | ✅ 40 项检查，失败 0 项（圆柱 3/12、包围盒 12/6、蓝环离地 6.0 —— 第 102 轮起点高度降到 3 但环不变） |
| 5e | `tools/probe_reaper_ai.gd` | **Reaper 三循环 AI** | ✅ 19 项检查，失败 0 项（循环顺序/前移/召唤/6 格被动-物理线/红环预警/动态光柱真的会打死人） |
| 5p | `tools/probe_summon_rel.gd` | **Reaper 召唤点相对性探针** | ✅ 4 项检查，失败 0 项（6 个 Reaper 位置 × 3 落点全在体外、最小中心距 4.47 > 3.0、落点严格跟随平移） |
| 5s | `tools/probe_bar_height.gd` | **条子高度 vs 炮管扫掠顶探针** | ✅ 8 项检查，失败 0 项（条子下边 3.731 > 任意仰角最高点 3.490；普通角色走原路径；量完姿态还原） |
| 5t | `tools/probe_bar_height2.gd` | **`max_height()` 有效性探针** | ✅ 8 项检查，失败 0 项（把发射器/立柱移开后仍报 2.956 = 炮管 60° 扫掠顶，而当前姿态只有 2.340） |
| 5r | `tools/shot_level.gd` / `tools/shot_unit.gd` | **截图工具**（关卡俯瞰 / 单位特写） | ⚠ **不要 `--headless`**（渲染桩拿不到 framebuffer）；`get_image()` 拿的是**上一帧**，设完相机要**隔几帧再截** |
| 5q | `tools/probe_boss_bar.gd` | **Boss 血条探针** | ✅ 12 项检查，失败 0 项（只显示在 Boss 关、只看力量、护甲归零不影响、比例跟随、阵亡隐藏） |
| 5o | `tools/probe_floor.gd` | **子弹地板碰撞探针** | ✅ 9 项检查，失败 0 项（403000 次样本反弹 24.96% ≈ 25%、线段穿越不漏、上限 1 次、无重力） |
| 5n | `tools/probe_burst_spread.gd` | **连发散布探针（已解耦）** | ✅ 9 项检查，失败 0 项（第 107 轮反转：**萨尼=圆盘**（`y0==y1`、无方差、无高度<0）／车=球（`E[r²]/R²=0.598`、带俯仰）） |
| 5l | `tools/probe_unit_target.gd` | **午餐盒点选目标探针** | ✅ 23 项检查，失败 0 项（含"车普攻**不弹**力量/破甲菜单、第二次点直接开打"）（**走真实点击路径** `t_click_cell`：选技能→点敌人→巡飞弹真放出+扣 12 精力+结束回合；普攻同理） |
| 5k | `tools/probe_turret.gd` | **午餐盒炮塔建模探针** | ✅ 32 项检查，失败 0 项（棱柱长 1.20／支点 2:1／中轴线=瞄准轴／**离车顶 1 格**／支撑圆柱跨度／**炮口=支点+朝向×炮管长**／热量→颜色+亮度双映射平滑） |
| 5j | `tools/probe_arrow.gd` | **箭矢/子弹口径** | ✅ 0 失败（子弹已按第 104 轮改口径：删恒定高度、衰减只作用于力量） |
| 5i | `tools/probe_menu_gate.gd` | **行动菜单门禁探针** | ✅ 15 项检查，失败 0 项（AI 操控的单位不弹行动菜单、但照常选中看属性；我方照常弹） |
| 5h | `tools/probe_level_ui.gd` | **关卡按钮探针** | ✅ 27 项检查，失败 0 项（三个关卡按钮都在调试面板里、宽度占满一行、文字放得下） |
| 5g | `tools/probe_medkit.gd` | **医疗包探针** | ✅ 30 项检查，失败 0 项（不再复活/绿色箭头/回 20 血/碰谁给谁回/确定性；散布改 1 格后改成扫种子断言） |
| 5f | `tools/probe_boss_scene.gd` | **Boss 关端到端** | ✅ 27 项检查，失败 0 项（真实加载 Reaper 战、999/99、41×81 斜对角、出生点不压 Reaper、by_side、环色、6 格被动、非对称胜负） |
| 5b | `tools/probe_marker.gd` | **轨道空爆标记探针** | ✅ 9 项检查，失败 0 项（专测"标记球落地 → 立光柱"；**这条链路原先没有断言，带着一个崩溃进了第 97 轮收口版本**） |
| 6 | `tools/sim_ai.gd --games=2 --seed=1` | AI 自动演算 | ✅ 2/2 局打完（第 1 局敌方胜 / 边界 89 ｜ 第 2 局玩家方胜 / 边界 72） |
| 7 | `python tools/make_unit_data.py` | 数据流水线 | ✅ **幂等**：重跑后 `game/src/core/unit_data.gd` 哈希不变 |

> **项数会随口径变更而增加**：`playtest` 从 563 → 565（第 97 轮：删掉"半血自毁"后，
> 坠机链路新增 "还剩 15 点力量【不】坠机" / "受伤路径也【不】坠机" 两条反向断言）
> → **569**（第 104 轮：新增角色「轮式齐射午餐盒」进竞技场/Reaper 战名单，
> 连带多出若干"每技能都要有测试施法者""每场景都要能行动"类断言；§38c 还就地造了一辆车
> 以覆盖新技能 `loiter_launch`）。
> 所以判断回归的标准是**"失败 0 项 + 项数 ≥ 记录值"**；项数**变少**说明有检查被静默跳过，必须查。
> `tests/run.gd` 是纯语句断言，没有总数，只看 `✅ 全部通过`。


### 已知无害噪声

- 每个探针退出时都会打印一批 `RID allocations ... were leaked at exit` / `ObjectDB instances were leaked`。
  这是 Godot 在 `--headless` 下退出时的常规报告，**退出码仍是 0**，不代表测试失败。
- `sim_ai` 单局很慢（arena 第 1 局跑了约 100 秒真实时间 / 596 秒游戏内时间）。它是**收尾用的**，不要放进快速循环。

## 二、代码量现状（重构的靶子）

| 文件 | 行数 | 有效代码 | 说明 |
|---|---|---|---|
| `game/src/view/battle_scene.gd` | **4587** | 3330 | 状态 + 搭场景 + UI + 输入 + 回合机 + 弹道结算 + 直升机 + 巡飞弹 + 哨兵，全在一个类里 |
| `game/tools/playtest.gd` | 3172 | — | 访问 `battle_scene` 的 **159 个不同成员**（含大量 `_` 私有） |
| `game/tests/run.gd` | 1267 | — | **完全不依赖 battle_scene**（只测 core） |
| `game/src/view/battle_ui.gd` | 870 | — | 宿主接口是干净的 `ui_*` 契约，本身可以整体替换 |
| `game/src/core/*.gd`（21 个） | ~3300 | — | 全部 `RefCounted`，**没有任何 `get_node()` / `get_parent()`** |

唯一一处 core→view 的穿透是 `Unit.visual` / `Placeable.visual`（由 view 注入的 `Node3D` 弱引用）。

## 三、命令

```powershell
# 引擎（不入库，换机器按此版本重新下载）
$exe = "tools\godot\Godot_v4.7.2-stable_win64_console.exe"

# 1 规则自检
& $exe --headless --path game --script res://tests/run.gd --quit-after 3000
# 2 试玩链路
& $exe --headless --path game --script res://tools/playtest.gd --quit-after 400000
# 3 竞技场探针
& $exe --headless --path game --script res://tools/probe_arena.gd --quit-after 200000
# 4 火箭探针
& $exe --headless --path game --script res://tools/probe_r89.gd --quit-after 200000
# 5 制导探针
& $exe --headless --path game --script res://tools/probe_r92.gd --quit-after 200000
# 5b 轨道空爆标记（标记球落地 -> 立光柱）
& $exe --headless --path game --script res://tools/probe_marker.gd --quit-after 60000
# 6 AI 演算（慢，收尾用）
& $exe --headless --path game --script res://tools/sim_ai.gd --quit-after 600000 -- --games=2 --seed=1
# 7 重新生成数据
python tools/make_unit_data.py
```

### 命令行的两条纪律

1. **一定要带 `--quit-after`**：脚本中途报错会跳过 `quit()`，进程会一直挂着。
2. **无头输出含中文时**，先落盘再读，否则 PowerShell 管道里是乱码：
   `... 2>&1 | Out-File -Encoding utf8 ".tmp_for_deepseek\xxx.txt"`，再用 read/Select-String 看。
   临时输出**统一放 `.tmp_for_deepseek/`**（已 gitignore），不要散落到仓库根或 `tools/`。

### 第 0 步：改完 `view/` 先跑三个门禁（都只要几秒）

**`tests/run.gd` 根本不加载 `battle_scene.gd`** —— 它只测 `UnitData` / `Rules` / `Damage` 这些纯 core。
所以 `✅ 全部通过` **完全不能证明视图层编译得过**。

```powershell
$exe = "tools\godot\Godot_v4.7.2-stable_win64_console.exe"

# 门禁 1：编译检查（0.5 秒）
& $exe --headless --path game --check-only --script res://src/view/battle_scene.gd --quit-after 200

# 门禁 2：包装层一致性（见下）
& $exe --headless --path game --script res://tests/check_wrappers.gd --quit-after 3000

# 门禁 3：门禁 2 的自检 —— 只在**改动 check_wrappers.gd 本身**时需要
& $exe --headless --path game --script res://tests/check_wrappers_selftest.gd --quit-after 60000
```

- 三个都必须 `exit 0`，且输出里没有 `Parse Error` / `SCRIPT ERROR`。
- **不过就别跑试玩链路**：场景建不起来但进程不退出，会被 `--quit-after 400000` 吊死十几分钟。
- 视图层最常见的坑：**模块里对动态类型宿主（`_st`）的调用推不出返回类型**，
  于是 `var x := _st._some_func()` 报推断错误 —— 一律写成显式类型 `var x: T = _st._some_func()`。

### 门禁 2 是什么：包装层一致性（`tests/check_wrappers.gd`）

把 `battle_scene.gd` 拆成模块后，宿主里留了一批**同名薄包装**。这批包装有一种
**"测试全绿但语义已经悄悄变了"** 的 bug，playtest 抓不到：

> **包装的"协程性"必须与被包装的模块函数逐字一致。**
> - 模块函数是协程（体内的 await 语句决定）＋有返回值 → 包装写 `return await mod.fn(...)`
> - 模块函数是协程 ＋ `-> void` → 包装写 `await mod.fn(...)`
> - 模块函数是同步的 → 包装写 `return mod.fn(...)` / `mod.fn(...)`，**绝对不许加 await**
>   （加了会把"调用即完成"变成"下一帧才完成"，而且测试往往还是绿的）
> - `var r = await mod.fn(...)` + `return r` 是**合法**写法（与 `return await` 等价），不得误杀

第 97 轮第二期两边各踩过一次（`_rocket_salvo` 漏 await、捕获形态被误杀），所以做成了常驻门禁。
当前覆盖 **52 个包装 / 6 个模块，全部合规**。

**6 个模块里有 2 个不是本轮拆出来的**（`projectile_field.gd` / `battle_ui.gd`）：
门禁真正该管的不是"谁被拆出来了"，而是"**谁的包装在转发**" —— 它们已经有薄包装
（`clear_projectiles` → `field.clear()`、`_refresh_detail` → `ui.refresh_detail()`…），
以前从来没人检查过。顺手把它们纳入（用 `scan_only` 只查确认为包装的那几个函数名，
免得把 `field.items` / `ui.layer` 这类数据访问也当转发找）。

**新增模块时怎么接入**：在 `check_wrappers.gd` 的 `MODULES` 数组里加一行
（模块路径 + 宿主路径；若模块函数名与宿主包装名不同用 `rename`，只想查部分函数用 `scan_only`），
**并在 `FORWARDING_MEMBERS` 里加一行**声明"宿主哪个成员有薄包装"。

**覆盖自检（防止"忘了登记"这种静默失效）**：门禁会断言
`FORWARDING_MEMBERS` 里每个成员都在 `MODULES` 有对应条目，否则 **exit 1**。
另外用"注入形态"（`.new(self)` / `.new()`+`setup(self)`）做一次**高精度提示**：
出现未列入表的候选就打一行 note 请你确认（实测零假阳性，真实树 7 个候选全部已覆盖/已豁免）。
> ⚠️ 试过"从代码长相自动推导覆盖面"，**三条路都不成立，别再走**：
> 按 `.new(self)` 会漏掉 `.new()`+`setup()` 那种注入风格；
> 按"单语句转发"松了在 `battle_scene.gd` 上误报 40 个（局部变量、循环体一行调用、
> 连 `signal turn_started` 都长得一样），紧了又漏掉守卫式与三元式的真转发
> （`if field != null:` + `field.clear()`、`return 0 if field == null else field.live_count()`）。

**门禁的牙口（5 条红线 + 1 个合法形态，由 `check_wrappers_selftest.gd` 固化成可复跑回归）**：

| 场景 | 期望 |
|---|---|
| ① 同步模块 + await 包装（同步变异步、时序漂移） | exit 1 |
| ② 模块协程 / 包装同步（漏 await） | exit 1 |
| ③ 签名收窄（`-> bool` 改成 `-> void`）+ 裸 await | exit 1 |
| ④ 签名一致 + 裸 await（丢返回值） | exit 1 |
| ⑤ 捕获了 await 结果却不 `return` 出去 | exit 1 |
| ⑥ 合法：`var r = await …` + `return r` | exit 0 |

自检用**合成的模块/宿主文本**（写在 `res://tests/_wrapfix/`，跑完自动删；
该目录已 gitignore，因为自检失败时会**故意保留** fixture 供排查）。
自检**刻意把目标函数放在非首位**（曾经有过"解析只对文件首个函数生效"的缺陷，
探针把目标放首位就区分不出"已修好"与"没踩到"，会给出虚假的"不复现"）。

**自检本身也验过"不空洞"**（用门禁**副本**做变异，本体不动）：
- M1 让门禁恒 `exit 0`（五条牙全废）→ 自检 **恰好 5 个 FAIL**（⑥ 仍 PASS）；
- M2 只废"协程性一致"一条 → 自检 **恰好 1 个 FAIL**（① 是**单点**依赖；② 被第二条规则兜住，有冗余）；
- M3a/M3b 覆盖漂移两个方向（删 MODULES 条目 / 注入幽灵成员）→ 均 **exit 1**。
> 这三条变异**目前是手工做的，没有自动化回归** —— 自检覆盖不到，原因是环境限制：
> 覆盖自检要构造漂移就得改 MODULES，而门禁读模块用 `res://`，
> **引擎启动后新建的文件在本次运行里对 `res://` 不可见**（实测 `FileAccess.file_exists` 返回 false）。

**已知边界**：`_has_await_stmt()` 只认本仓实际使用的写法
（行首 `await` / `x = await` / `return await`）。若将来出现 `if await f():` 这类表达式位置写法，
它会漏判成"同步" —— 那时改成"去掉行尾注释后做 `await` 词匹配"。

### 引用"正在被改的文件"时的纪律

这一轮 `check_wrappers.gd` 在 4 分钟里改了 7 次，团队前后三条结论**有两三条因为对着不同 revision
下判断而作废**。所以：

1. **引用某个文件的行为时必须带 `mtime + size + sha256`**；批跑前后各取一次哈希，不一致就作废重跑。
2. 要复现就**复制一份冻结副本**去跑，不要就地改正在被改的文件。
3. 校验"提交内容 == 验收内容"用 **`git rev-parse <rev>:<path>` vs `git hash-object <path>`**；
   **不要**用 `git show <rev>:<path> > file` 再对文件取哈希（PowerShell 重定向会 LF→CRLF、可能加 BOM，必然误报）。
4. 实验要**单因子**：一次只改一个变量。改两个因子就无法归因 —— 这一轮因此得出过错误结论，事后撤回。

**宿主引用校验（闭世界）**：模块里每一处 `_st.<name>` 都必须能在宿主的
`func` / `var` / `const` / `signal` / `enum` 声明里找到（Node 内建方法在白名单里）。
**为什么必须有这条**：`_st` 是**动态类型**，写错的 `_st._foo(...)` **编译期查不出来**，
只有执行到那一行才报 `Nonexistent function`。第 97 轮就因此漏了两处 ——
`_raise_pylon_at`（随 SkillRunner 搬走）与 `ui_open_skill_menu`（随 ActionMenu 搬走），
前者在正常游玩时会崩（"轨道空爆标记球被拦截"）。现在这条校验覆盖 **1000+ 处引用**。

**模块之间的调用无法静态校验**（`_st.skills_mod.xxx` 这类），只能靠行为探针兜底 ——
所以新增了 `tools/probe_marker.gd`（9 项）专测"标记球落地 → 立光柱"这条曾经没被断言的链路。

### 门禁 3：功能探针（`tools/probe_*.gd`）

```powershell
& $exe --headless --path game --script res://tools/probe_marker.gd --quit-after 60000
```n
`.godot/global_script_class_cache.cfg` 需要重建，否则 `--script` 直跑会报 `Identifier "Xxx" not declared`：

```powershell
& $exe --headless --path game --editor --quit-after 3000
```

### 退出码

`0` = 通过，`1` = 有失败。脚本末尾会打印 `失败 N 项`，**以那个为准**（`RID leaked` 之类的噪声不影响退出码）。
