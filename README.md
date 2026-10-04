# BattleChess（RBC）· 项目索引

回合制战棋 RPG 原型：**Godot 4.7.2** + 3D 场景 + 正交固定角度相机（2.5D）+ 全程序化图元（无美术资源）。
代码在 `game/`，2017 年式的"文档先行"产物在 `docs/`。

---

## 先读这一份：`docs/规格.md`

**[`docs/规格.md`](docs/规格.md) 是本项目的记忆文档** —— 上下文丢失时以它为准。
它记录**当前生效**的每一条口径：伤害与数值、角色、投射物、高度轴、被动、散步、关卡、胜负与回合队列、AI、UI、日志。
每次改完代码就把口径补进去；被推翻的旧口径直接改写或标"已废弃"。

配套的两份：

| 文件 | 作用 | 什么时候读 |
|---|---|---|
| **[`docs/规格.md`](docs/规格.md)** | **记忆文档**：当前生效的全部口径 | 每次开工前 |
| [`bc_stat.md`](bc_stat.md) | **数值唯一来源**（只有表格，不许写散文）。改完跑 `python tools/make_unit_data.py` 重新生成 `game/src/core/unit_data.gd` | 要改任何数值时 |
| [`docs/baseline.md`](docs/baseline.md) | **验证基线**：7 个验证入口的实测结果 + 命令 + 纪律 | 改动前后各跑一次 |

---

## 目录

```
game/                      Godot 项目（引擎本体不入库，见下）
  project.godot            主场景 = res://src/view/battle_scene.tscn
  src/core/                21 个文件，全部 RefCounted，无 get_node()（纯规则/数据层）
  src/view/                11 个文件，场景、UI、表现层
  tests/run.gd             规则自检（纯 core，不加载场景）
  tools/                   试玩链路 + 5 个探针 + AI 自动演算
docs/                      文档（含 img/ 实机截图）
tools/                     Python 工具（bc_stat.md -> unit_data.gd）+ Godot 引擎（不入库）
bc_stat.md                 数值表（改数值只改这里）
.tmp_for_deepseek/         临时脚本与测试输出统一落点（已 gitignore）
```

---

## 跑起来

引擎不入库（180 MB）。换机器按此版本重新下载，解到 `tools/godot/`：

> **Godot 4.7.2 stable · win64**（仓库里的命令用的是 `tools/godot/Godot_v4.7.2-stable_win64_console.exe`）

```powershell
# 打开编辑器试玩
tools\godot\Godot_v4.7.2-stable_win64.exe --path game

# 规则自检（最快，纯 core）
tools\godot\Godot_v4.7.2-stable_win64_console.exe --headless --path game --script res://tests/run.gd --quit-after 3000

# 试玩链路（563 项，最重要的一张网）
tools\godot\Godot_v4.7.2-stable_win64_console.exe --headless --path game --script res://tools/playtest.gd --quit-after 400000
```

全部 7 个入口、基线数值与两条命令行纪律（**必须带 `--quit-after`**、**中文输出先 `Out-File -Encoding utf8` 再读**）见 **[`docs/baseline.md`](docs/baseline.md)**。

---

## 文档地图

`docs/` 里的文档分成三代，**读之前先看它顶部的状态标注**：

### 现行（以这些为准）

| 文件 | 内容 |
|---|---|
| [`docs/规格.md`](docs/规格.md) | **记忆文档**，当前全部口径 |
| [`bc_stat.md`](bc_stat.md) | 数值唯一来源（三张表：我方角色 / 敌方镜像+假人 / 可放置物） |
| [`docs/baseline.md`](docs/baseline.md) | 验证基线（7 个入口的实测结果与命令） |
| [`docs/heli_design.md`](docs/heli_design.md) | 俯冲轰炸直升机的可施工设计稿（已实现，保留作口径依据） |
| [`docs/harness_godot_interaction.md`](docs/harness_godot_interaction.md) | AI × Godot 交互程度实测：我能独立做到哪、哪些必须你来 |

### 已过时（顶部有 ⚠️ 头注，保留仅供追溯早期设计）

| 文件 | 为什么过时 |
|---|---|
| [`docs/spec_rules.md`](docs/spec_rules.md) | 实装前的规则规格：8 个兵种原型 / 12×12 / 一方全灭判负 / 精力可加伤害 —— 全部被推翻。**仍有效的只剩取整、双池、确定性、分层等约定**（头注里逐条列了） |
| [`docs/design_v1.md`](docs/design_v1.md) | 实装前的开发方案：目录结构、`.tres` 数据、存档设计（**从未实装**）、里程碑 |
| [`docs/data_schema.md`](docs/data_schema.md) | 实装前的数据契约：`BattleState`/`ActionRequest`/`BattleEvent[]` 均未实装 |
| [`docs/appendix_balance_findings.md`](docs/appendix_balance_findings.md) | 早期蒙特卡洛实算（用的是十倍粗粒度尺度），结论已并入现行数值 |
| [`docs/verification_report.md`](docs/verification_report.md) | 对上述旧文档的只读审计报告 |
| [`docs/research/tech_feasibility.md`](docs/research/tech_feasibility.md) | 技术选型依据（Godot 版本、Web 导出、渲染器边界）—— 结论已被采用，正文是当时的证据 |
| [`BATTLE_CHESS.md`](BATTLE_CHESS.md) | 用户最初的 13 行口述规则（原始需求，保留） |

---

## 代码现状与已知问题

**核心层是健康的**：`game/src/core/` 21 个文件全部 `RefCounted`，零 `get_node()` / `get_parent()`，
`view → ai → core` 单向依赖成立，每个文件顶部都写了职责。三层伤害（`Rules` 公式 → `Combat` 唯一造伤入口 → `Damage` 范围结算）
与三张行为表（`AttackProfile` 普攻 / `Skills` 技能 / `Passives` 被动）都是数据驱动 + 单一入口。

**膨胀集中在视图层**：`game/src/view/battle_scene.gd` 一个类 **4587 行 / 239 个函数**
（状态 + 搭场景 + UI + 输入 + 回合机 + 弹道结算 + 直升机 + 巡飞弹 + 哨兵）。
`game/tools/playtest.gd`（3172 行）访问它的 **120 个私有成员**（1019 处引用），
所以拆分必须先把这套耦合面收口 —— 方案见 [`docs/refactor_plan.md`](docs/refactor_plan.md)。

其余已知项（死变量、重复实现、`_smoke` 旧原型残留等）也在那份方案里逐条分级。

---

## 版本控制约定

- 只提交**源码与文字资料**：引擎本体（`tools/godot/`）、Godot 导入缓存（`game/.godot/`）、
  临时脚本与测试输出（`.tmp_for_deepseek/`）、AI 会话转录（`DHS's/`）都不入库。见 [`.gitignore`](.gitignore)。
- 提交信息写**这一轮改了什么、为什么**（历史里的中文长提交信息就是范例）。
- 临时测试输出**统一放 `.tmp_for_deepseek/`**，别散落到仓库根或 `tools/`。
