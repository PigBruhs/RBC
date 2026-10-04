# 验证基线（改动前必须对得上的那条线）

> 用途：任何重构 / 数值改动之后，用同一组命令复跑一遍，结果必须与下表一致。
> 这些数字是 **2026-10-04** 在本机（Godot 4.7.2 stable）实际跑出来的，不是估计值。
> 复跑方式见文末"命令"。**改了数值就更新本表**，否则它就变成了误导。

## 一、当前基线（全绿）

| # | 入口 | 项目 | 实测结果 |
|---|---|---|---|
| 1 | `tests/run.gd` | 规则自检 | ✅ 全部通过（纯 core，不加载场景） |
| 2 | `tools/playtest.gd` | 试玩链路 | ✅ **565 项检查，失败 0 项** |
| 3 | `tools/probe_arena.gd` | 竞技场探针 | ✅ 失败 0 项（含复活点落位、枪榴弹被击落整发消失） |
| 4 | `tools/probe_r89.gd` | 火箭探针 | ✅ 3 项检查，失败 0 项 |
| 5 | `tools/probe_r92.gd` | 制导探针 | ✅ 11 项检查，失败 0 项 |
| 6 | `tools/sim_ai.gd --games=2 --seed=1` | AI 自动演算 | ✅ 2/2 局打完（第 1 局敌方胜 / 边界 89 ｜ 第 2 局玩家方胜 / 边界 72） |
| 7 | `python tools/make_unit_data.py` | 数据流水线 | ✅ **幂等**：重跑后 `game/src/core/unit_data.gd` 哈希不变 |

> **项数会随口径变更而增加**：`playtest` 从 563 → **565**（第 97 轮：删掉"半血自毁"后，
> 坠机链路新增 "还剩 15 点力量【不】坠机" / "受伤路径也【不】坠机" 两条反向断言）。
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

### 第 0 步：改完 `view/` 先跑编译快检（几秒钟）

**`tests/run.gd` 根本不加载 `battle_scene.gd`** —— 它只测 `UnitData` / `Rules` / `Damage` 这些纯 core。
所以 `✅ 全部通过` **完全不能证明视图层编译得过**。改完 `game/src/view/` 下任何 `.gd`，先跑这个：

```powershell
$exe = "tools\godot\Godot_v4.7.2-stable_win64_console.exe"
& $exe --headless --path game --check-only --script res://src/view/battle_scene.gd --quit-after 200
```

- `exit 0` 且**输出里没有 `Parse Error` / `SCRIPT ERROR`** 才算过。
- **不过就别跑试玩链路**：场景建不起来但进程不退出，会被 `--quit-after 400000` 吊死十几分钟。
- 视图层最常见的坑：**模块里对动态类型宿主（`_st`）的调用推不出返回类型**，
  于是 `var x := _st._some_func()` 报推断错误 —— 一律写成显式类型 `var x: T = _st._some_func()`。

### 新增 `class_name` 之后

`.godot/global_script_class_cache.cfg` 需要重建，否则 `--script` 直跑会报 `Identifier "Xxx" not declared`：

```powershell
& $exe --headless --path game --editor --quit-after 3000
```

### 退出码

`0` = 通过，`1` = 有失败。脚本末尾会打印 `失败 N 项`，**以那个为准**（`RID leaked` 之类的噪声不影响退出码）。
