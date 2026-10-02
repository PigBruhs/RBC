# 《战棋 RPG》第一版（v1）开发方案 · 文档索引

本目录是"第一版开发方案制定"的完整交付物。**从 `docs/design_v1.md` 开始读**，它是主方案；其余文件是它的卫星文档。

> **规则已在第二轮澄清后更新**：物抗/魔抗是**五档离散固有属性**（无/低/中/高/免疫 = 0/0.2/0.4/0.8/1.0，不可加点），伤害公式为 **`D = (力量-护甲) × (1-物抗)`**（乘算，物抗是真减伤）。
> 权威定义见 **[docs/design_v1.md](docs/design_v1.md) 的 §0.5 规则澄清增补**；`docs/spec_rules.md` 正在按此出 v1.2。

## 文档地图

| 文件 | 内容 | 什么时候读 |
|---|---|---|
| **[docs/design_v1.md](docs/design_v1.md)** | **主方案**：§0.5 规则澄清（权威）、架构决策（Godot 4.7.2 + 正交相机 2.5D）、无美术资源的程序化表现方案、v1 功能范围、目录结构、存档设计、测试策略、**里程碑计划与验收标准**、风险登记册、开放问题 | 先读这个 |
| [docs/godot_handbook.md](docs/godot_handbook.md) | **Godot 上手手册**（1071 行）：心智模型、安装、Web 导出模板、编辑器界面、GDScript 最小必要知识、完整开发循环、headless/命令行、Web 导出流程、版本管理、**你手工要做的清单**、新手 10 个坑、学习资源 | **你从没写过 Godot，就先读这个** |
| [docs/harness_godot_interaction.md](docs/harness_godot_interaction.md) | **AI × Godot 交互程度实测报告**：我能独立做到哪、哪些必须你来、真实协作流程、我在本机实测踩掉并修好的 4 个真实 bug、每个里程碑谁干活 | **想知道"我到底能帮你多少"，读这个** |
| [docs/spec_rules.md](spec_rules.md) | **规则形式化规格**：属性语义、伤害管线、破甲线、移动/邻接、弹道抛物线瞄准、回合结构、精力、升级、8 个兵种原型数值表、E[D]/TTK 推演、边界清单、决策登记表 | 要开工写代码时读 |
| [docs/data_schema.md](data_schema.md) | **数据契约**：`UnitData`/`LevelData`/`UnitState`/`ActionRequest`/`BattleEvent` 定义、事件流规范、存档 JSON Schema 与迁移、跨层接口契约、命名约定 | 要写代码/存档时读 |
| [docs/appendix_balance_findings.md](appendix_balance_findings.md) | **数值体系的蒙特卡洛实算报告**：护甲死锁、TTK 唯一旋钮、概率规则可达性、精力过强、AI 站桩、先手碾压，每条都改动了主方案 | 想理解"为什么数值这么定"时读 |
| [docs/research/tech_feasibility.md](research/tech_feasibility.md) | **技术可行性验证**：Godot 版本与实测下载体积、COOP/COEP 真相、Compatibility 渲染器能力边界、Web 存档落点（IndexedDB）与丢档场景、备选架构六维对比、14 条技术风险 | 要落地/打包时读 |
| [docs/verification_report.md](verification_report.md) | **独立验证报告**：只读审计，8 条阻断级问题（已全部修复）、逐格实算复核、残余中低问题 | 想确认文档可靠性时读 |
| [docs/img/](docs/img/) | 我实际跑出来的 2.5D 场景截图（`smoke_yaw0.png` / `smoke_yaw90.png`） | 想看"没有美术资源能长什么样"时看 |
| [tools/godot/](tools/godot/) | 我下载的 Godot 4.7.2 绿色版（免安装）+ Web 导出模板 + **可运行的骨架项目 `_smoke/`** | 想立刻试跑时用 |
| [tools/balance_probe_new_rules.py](tools/balance_probe_new_rules.py) | 按新规则（乘算 + 五档）实算的探针 | 想复算数值时用 |

## 一页纸结论

- **架构**：Godot **4.7.2** + 3D 场景 + **正交固定角度相机（2.5D）** + 程序化图元角色/地形 + Tween 程序化动画；**单线程 Web 导出**首发，Windows 桌面版顺带产出。
- **无美术资源**：v1 不需要任何贴图或骨骼动画——形状/颜色/状态三语义 + Tween 三件套（位移、闪白、伤害数字）+ 描边即可。**已实际跑出截图验证**（见 `docs/img/`）。
- **规则要点**：力量=生命（归零才死）、护甲=第二资源（归零只失去减免）、物抗五档乘算减伤、概率命中在"高"档下经常触发。
- **v1 范围**：完整战棋规则（四属性、力量/破甲两条线、概率命中、精力、休息、三种普攻、升级）+ 可循环游戏流程 + 简易 AI + **多槽存档与存档码导出**。
- **工期**：约 **7.5-8.5 周**（6-10 小时/周）。
- **最大风险**：iOS Safari 内存 OOM、清站点数据丢档、弹道"无辅助瞄准"的可玩性。
- **现在需要你拍板的只剩**：Q3（是否接受 Godot 路线，已定）、Q9（概率命中是否再加强）、Q11（是否开启敌我交错行动）、Q13（破甲线不能直接击杀是否接受）——**其余都有可直接沿用的默认值，不回答也能开工**。

## 立即可做的下一步

1. **读 [docs/godot_handbook.md](docs/godot_handbook.md)**（你从没用过 Godot，这份就是为你写的）；
2. 试跑我留的骨架：`E:\新建文件夹\tools\godot\Godot_v4.7.2-stable_win64.exe --path "E:\新建文件夹\tools\godot\_smoke"`（双击编辑器打开这个项目，或直接按 F5 跑）；
3. 或者直接说"**做 M0.5**"——我用本机 Python 做可试玩的 ASCII 版规则原型（不需要 Godot）。

## 交付状态

| 文件 | 状态 |
|---|---|
| `docs/design_v1.md` | ✅ 主方案完成（含 §0.5 第二轮规则澄清） |
| `docs/godot_handbook.md` | ✅ 完成（1071 行） |
| `docs/harness_godot_interaction.md` | ✅ 完成（含本机实测证据） |
| `docs/data_schema.md` | ✅ 完成 |
| `docs/research/tech_feasibility.md` | ✅ 完成 |
| `docs/appendix_balance_findings.md` | ✅ 完成（含 2 处自我更正记录） |
| `docs/verification_report.md` | ✅ 独立验证完成，8 条阻断级问题已全部修复 |
| `docs/spec_rules.md` | ✅ **v1.2 完成**（977 行 / 54 张表，已纳入五档物抗 + 乘算公式；54 张表经公式复算 0 处不符） |
| `tools/godot/_smoke/` | ✅ 可运行骨架：headless 测试全绿 + 2.5D 截图已验证 + **Web 导出成功（38.0 MB 原始 / 9.8 MB gzip）** |
| `tools/godot/`（Godot 4.7.2 + 1.19 GiB 模板） | ✅ 已下载并**装好模板**（绿色版，删掉即可，不改系统） |

## 已知残余问题（不影响决策，开工前用 5 分钟处理）

| 问题 | 位置 | 处理建议 |
|---|---|---|
| 部署区"开局最近 6 格、最远 9 格"与实算不符（y∈[0,2] 与 y∈[9,11] 实算最近 7、最远 11/22） | `spec_rules.md` §9.3/§9.4 | 改部署区，或改文字为"最近 7 格、最远 11 格" |
| 关卡胜负条件只定义了"全灭"，`SURVIVE_ROUNDS`/`REACH` 无判定细节 | `spec_rules.md` §7 | M2 开工前补一节（约 20 行） |
| "47/64 破甲线更快"是 v1.0 数值表的历史值，不可复现 | `spec_rules.md` §1.1/D5/§13.4 | 已就地标注为历史值（v1.1 数值下为 36/64） |
| 精力数值是占位起点（用户尚未设定角色力量） | `spec_rules.md` §9.2 | 定角色数值后按比例放大，用 `balance_sim` 重新标定 |
