# Godot 4.7.2 上手手册（零引擎经验 → 跑通本项目）

> **读者**：会写代码、但从没打开过任何游戏引擎的单人开发者（6-10 小时/周，无美术资源，目标平台 Windows 桌面 + 浏览器 Web 导出）。
> **引擎版本**：**Godot 4.7.2 stable**（2026-08-18 发布，本机 Windows 未安装）。本手册所有版本号、菜单路径、命令均按 4.7.2 核对；无法核实的地方显式标注「未证实」。
> **配套文档**：`docs/design_v1.md`（主方案，§4 目录结构 / §5.5 回合结构 / ADR-1 / ADR-5）、`docs/data_schema.md`（数据契约）、`docs/research/tech_feasibility.md`（§9 环境准备 / §9.2 替代路径 / §10 风险）。
> **写作时间**：2026-09-30。核实来源见 §12。

---

## 1. 心智模型：Scene / Node / 资源 / 脚本

这一节解决的是最大的一次认知跳跃。**别把 Godot 想成"我写一堆代码"，它是"我摆一棵节点树，再给树上的节点挂代码"。**

### 1.1 四个东西分别是什么

| 概念 | 一句话定义 | 物理形态 | 类比 |
|---|---|---|---|
| **Node（节点）** | 引擎里最小的功能单元，一个节点干一件事 | 内存里的对象 | DOM 元素 / Qt Widget |
| **Scene（场景）** | **一棵 Node 树**，可以整体保存、实例化、复用 | `.tscn` 文本文件 | React 组件 / HTML 模板 |
| **资源（Resource）** | 可被多个地方共享的**纯数据** | `.tres`（文本）/ `.res`（二进制） | JSON 配置 / `@dataclass` 实例 |
| **脚本（Script）** | 挂在某个节点上、给这个节点加行为的代码 | `.gd` 文本文件 | 组件的 `methods` |

关键点：**Script 不是 Scene 的一部分，而是"贴"在某个 Node 上的。** 一个 Node 顶多挂一个脚本（脚本可以 `extends` 另一个脚本）。你可以在 `.tscn` 里看到 `[node name="Player" type="Node3D"]` 和紧随其后的 `script = ExtResource("...")` —— 这就是"挂上了"。

### 1.2 和"我写一堆代码"的直觉差在哪

你（懂编程）默认的心智大概是：

```
写 main() → 里面 new 出所有对象 → 每帧自己算 → 调绘制函数画出来
```

Godot 的心智是：

```
搭一棵树（编辑器里拖 / 代码里 add_child）
   └─ 引擎每帧自动遍历这棵树，按规则调用每个节点的 _ready / _process / _input
你要做的只是：选对节点类型 + 在脚本里覆写那几个回调
```

具体差异，逐条对齐：

| 你的直觉 | Godot 的现实 |
|---|---|
| 程序入口是 `main()` | 入口是**主场景**（Project Settings 里指定）。引擎实例化它，然后开始遍历树 |
| 自己维护对象列表、自己管理生命周期 | **树就是生命周期**。`add_child()` = 出生，`queue_free()` = 死亡 |
| 自己写事件循环 | `_process(delta)` 每帧调你一次；`_physics_process` 固定步长调 |
| 对象间直接互相调用 | 首选 **信号（signal）**：子节点 `emit_signal`，父节点 `connect`。避免 `get_node("../../X")` 这种脆弱引用 |
| 配置写死在代码里 | 配置写进 **`.tres` 资源**，编辑器里用 Inspector 填，代码里 `@export` 暴露字段 |
| 对象数据和行为是一体的 | **数据和行为分离**：`UnitData.tres` 是数据，`unit_visual.gd` 是行为 |

### 1.3 为什么这个项目的规则层可以完全不进引擎

看 `design_v1.md` §4 的目录，最关键的设计是 **ADR-4：规则层与表现层分离**：

```
BattleSetup(资源) ──► BattleCore(纯逻辑, 无节点) ──► BattleEvent[](数据) ──► BattleView(节点/动画/UI)
```

`src/core/` 里那些文件**不 extends Node**、不 `get_node`、不碰渲染。它们就是普通的 GDScript 类，继承 `RefCounted`（或 `Resource`）。这意味着：

1. **它们不需要场景树就能跑。** 用 `godot --headless --script res://tests/run_tests.gd` 就能在无显示器、无 GPU 的环境里跑完整单元测试。这是这个项目最重要的工程保障——「0.65 概率命中」这种统计正确性，人肉试玩永远测不出来。
2. **它们不依赖编辑器。** AI 可以纯文本生成 `.gd` 文件，不需要你在编辑器里点任何东西就能验证规则。
3. **它们是可移植的。** 以后想换引擎，`src/core/` 整体搬走、逐条对账 `tests/golden_vectors.json` 即可。

### 1.4 为什么表现层**必须**进编辑器

反过来，`src/view/` 必须用编辑器，原因是**它本质上是"空间关系的可视化编辑"**：

- `battle_scene.tscn` 里 `Camera3D` 的**位置、旋转、正交尺寸**、`DirectionalLight3D` 的角度——这些是三维空间里的数值。你在编辑器里拖一下、立刻用鼠标滚轮看到效果，是**秒级反馈**；改成代码里写 `camera.position = Vector3(0, 12, 8)`，你得运行、截图、再猜，慢 10 倍。
- 场景的**层级结构**（`Node3D > BattleView > Units > UnitVisual`）在 Scene 面板里是一棵可拖拽的树，改父子关系不用改代码。
- `.tscn` 是文本，AI 可以写；但**"这个相机俯角 55° 看起来对不对"只有你的眼睛能判断**。`design_v1.md` ADR-2 定的俯角 55°、四向旋转，必须在编辑器里试出来。

**一句话**：**规则层是"文字工作"，表现层是"空间工作"。** AI 把文字工作整包接走，空间工作必须你本人。

### 1.5 一个具体的例子（务必读一遍）

要画一个"拿盾的民兵"，场景树长这样：

```
UnitVisual (Node3D)              ← 挂 unit_visual.gd，负责装配与播放动画
 ├─ Body (MeshInstance3D)         ← mesh = CapsuleMesh, material = 蓝色
 ├─ Head (MeshInstance3D)         ← mesh = SphereMesh
 ├─ Shield (MeshInstance3D)       ← mesh = BoxMesh（盾卫用宽扁方块）
 └─ FacingMarker (MeshInstance3D) ← mesh = PrismMesh，朝向楔形（没它分不清面朝哪）
```

- 这四个 **Node** 是空间对象；它们的 `mesh` 指向 **Resource**（`CapsuleMesh` 等内置资源，**无需任何贴图文件**）；`material_override` 指向另一个 Resource（`StandardMaterial3D`，用颜色 + `grow` 做描边，见 `tech_feasibility.md` §6.4）；
- 行为写在 **Script** `unit_visual.gd` 里；整套组合存成 **Scene** `unit_visual.tscn`，被 `battle_scene.tscn` **实例化 8 次**（4v4）。

你在编辑器里拖的是前四个 Node；代码里算的是"该往哪个格子走、伤害多少"。

---

## 2. 安装（Windows，4.7.2）：三种方式对比

**先看结论**：

| 方式 | 命令/操作 | 体积 | 能否出 Web 包 | 适合你吗 |
|---|---|---|---|---|
| **winget** | `winget install --id GodotEngine.GodotEngine --exact` | 约 82 MiB | **要另外装模板** | ✅ **推荐**，一条命令、版本自动锁到 4.7.2 |
| **官网 green zip** | 下载 `win64.exe.zip` 解压 | 约 82 MiB | **要另外装模板** | ✅ 备选，完全免安装、可多版本并存 |
| **Steam** | 商店页安装 | 约 100+ MiB | **要另外装模板** | ⚠️ 自动更新会破坏版本锁定，不推荐 |

> **已核实**：winget 源中 `GodotEngine.GodotEngine` 当前版本正是 **4.7.2**（本机 `winget show` 实测输出 `Version: 4.7.2`）。官方 Windows x86_64 编辑器 zip 实测 **86,013,866 字节 ≈ 82.0 MiB**。

### 2.1 方式 A：winget（推荐）

```powershell
# 1) 先看 winget 源里是什么版本（确认是 4.7.2，不是 4.8-dev）
winget show --id GodotEngine.GodotEngine --exact

# 2) 安装（--silent 免交互；不要用 --scope machine，除非你要给全机器装）
winget install --id GodotEngine.GodotEngine --exact --silent

# 3) 关掉当前终端再开一个新终端，然后验证
godot --version
# 期望输出：4.7.2.stable.official.<commit>
```

安装位置（winget 默认，**已核实为常见约定，未在本机实测路径**）：`%LOCALAPPDATA%\Microsoft\WinGet\Packages\` 下的包目录，另有一个 `godot.exe` 的 shim 目录被加进 `PATH`。

**注意**：
- winget 的 `--id` **必须精确**。如果只写 `winget install godot`，可能装到 `GodotEngine.GodotEngine.Mono`（C# 版）或 `GodotLauncher.Launcher`（第三方启动器）。
- **不要装 `.Mono` 版本。** 本项目用 GDScript；而且 **Web 导出在 Godot 4 + C#/.NET 下不支持**（引擎源码里的原话：`Exporting to Web is currently not supported in Godot 4 when using C#/.NET.`）。
- winget 只装**编辑器**，**不含导出模板**（模板要单独下载，见 §3）。

### 2.2 方式 B：官网 green zip（完全免安装）

官方直链（**已实测 HEAD 200，最终重定向到官方对象存储**）：

```powershell
# 下载编辑器（约 82 MiB）。官方下载页是跳转链接，Invoke-WebRequest 会自动跟随
$dir = "$env:USERPROFILE\Godot"
New-Item -ItemType Directory -Force -Path $dir | Out-Null

Invoke-WebRequest -Uri 'https://downloads.godotengine.org/?version=4.7.2&flavor=stable&slug=win64.exe.zip&platform=windows.64' `
    -OutFile "$dir\Godot_v4.7.2-stable_win64.exe.zip"

# 解压（得到 Godot_v4.7.2-stable_win64.exe 和它的 _console.exe 两个文件）
Expand-Archive -Path "$dir\Godot_v4.7.2-stable_win64.exe.zip" -DestinationPath $dir -Force

# 校验版本
& "$dir\Godot_v4.7.2-stable_win64.exe" --version
```

**注意**：
- Godot 是**绿色免安装**软件，解压出来的 `.exe` 直接双击就是编辑器，不需要安装程序。
- 下载的是 `win64.exe.zip`（**不是** `win32.exe.zip`，也不是 `windows_arm64.exe.zip`）。
- 想放进 `PATH`：把这个目录手动加到用户环境变量 `PATH` 即可。两个 exe 的区别：`Godot_v4.7.2-stable_win64_console.exe` 会在终端里打印输出（命令行调试时用它），`Godot_v4.7.2-stable_win64.exe` 双击运行不弹控制台。
- 想**多版本并存**（比如以后试 4.8）：绿色版天然支持，每个版本一个目录即可，互不干扰。

### 2.3 方式 C：Steam

Steam 商店搜索 "Godot Engine" 安装。**本手册不推荐**，原因：

- Steam 版**自动更新**，会把你的 4.7.2 悄悄升到 4.7.3/4.8，而 `design_v1.md` 的 R13 风险要求**版本锁死**（每个 minor 版本都有破坏性变更，官方有专门的迁移文档）。
- Steam 版默认使用**自包含模式（self-contained mode）**：编辑器数据、设置、缓存全部写在编辑器目录下的 `editor_data/` 里（官方文档原文确认）。这会让导出模板的路径和标准安装不同，容易困惑。
- 无法像绿色版那样一个目录一个版本。

### 2.4 三种方式都做完后：统一验证

```powershell
# 编辑器能跑
godot --version

# 编辑器数据目录（导出模板就装在这里，见 §3）
"$env:APPDATA\Godot"
Test-Path "$env:APPDATA\Godot"
```

> **绿色版本的一个可选技巧**：在编辑器 exe 同目录创建一个名为 `_sc_`（或 `._sc_`）的**空文件**，编辑器就会进入自包含模式，把所有数据写到同目录的 `editor_data/` 下。这样"整个 Godot 可以拷到 U 盘里"。官方文档确认此机制。

---

## 3. Web 导出模板（约 1.19 GiB）

### 3.1 为什么必须装

**编辑器本身不能把你的项目打包成可运行的程序。** 打包需要一个"空壳运行时"（导出模板），编辑器把你的项目数据塞进模板里生成最终产物：

- 导出 Windows `.exe` → 需要 `windows_release_x86_64.exe` 模板；
- 导出 Web → 需要 `web_nothreads_release.zip` 模板。

**导出模板是「全平台合集」**：官方只提供一个 `export_templates.tpz`（本质是 ZIP），里面含 Android / iOS / macOS / Linux / Windows / Web 全部模板。**没有"只下 Web 那部分"的稳定官方直链**（`tech_feasibility.md` §2.1 记录：尝试 `web_nothreads_release.zip` 等单独 slug 均返回 404）。

**已实测体积**：`https://downloads.godotengine.org/?version=4.7.2&flavor=stable&slug=export_templates.tpz&platform=templates` → **1,281,349,702 字节 ≈ 1222 MiB ≈ 1.19 GiB**。

### 3.2 不装模板会怎样

导出对话框会**直接拒绝导出**并报错，具体表现（依据引擎源码 `has_valid_export_configuration()`）：

- Web 预设：`r_missing_templates = true`，导出界面显示 "Export templates are missing" 一类的错误，**"Export Project" 按钮不可用**；
- 命令行导出 `godot --headless --export-release "Web" build/index.html` 会以错误退出，报找不到模板文件（`export_templates/4.7.2.stable/...` 路径下无该文件）；
- **不影响**：编辑器打开项目、按 F5 运行、`--headless --script` 跑单元测试 —— 这些都不需要模板。

所以 `design_v1.md` 的 M0 / M1-M6 完全可以**先不装模板**开工，等 M7 要出包时再装。这是官方文档没说、但对单人开发很关键的一点。

### 3.3 怎么装（编辑器菜单，推荐路径）

先下载 `.tpz`：

```powershell
$dir = "$env:USERPROFILE\Downloads"
Invoke-WebRequest -Uri 'https://downloads.godotengine.org/?version=4.7.2&flavor=stable&slug=export_templates.tpz&platform=templates' `
    -OutFile "$dir\Godot_v4.7.2-stable_export_templates.tpz"
(Get-Item "$dir\Godot_v4.7.2-stable_export_templates.tpz").Length
# 期望：1281349702
```

然后**在编辑器里**操作：

1. 打开 Godot 4.7.2；
2. 顶部菜单 **Editor → Manage Export Templates…**（官方文档原文菜单路径，已核实）；
3. 弹出 **Export Template Manager** 窗口；
4. 点右上角的 **「Install from File」/ TPZ 按钮**（源码里该按钮的 tooltip 是 `Install from a TPZ file.`；官方文档描述为"upper right of the window"的一个按钮）→ 弹出文件选择框 → 选中刚下载的 `.tpz`；
5. 等待解压（1.19 GiB 解压会花几分钟），窗口下方的 **Installed Templates** 树里出现 `4.7.2.stable` 条目即成功。

> ⚠️ **中文用户必看**：模板管理器里还有一个独立选项叫 **ICU Data**，官方描述是 "Line breaking dictionaries for TextServer, used by certain languages"，明确列出的语言包含 **Chinese / Japanese / Korean**。**不装 ICU Data 的话，中文换行会不正常**（长句不折行或断在奇怪的位置）。它也在同一棵树里，勾选安装即可。
>
> ⚠️ 另一条官方提醒：**TPZ 全集和"只勾选某个平台"在功能上完全相同，只是 TPZ 占更多磁盘空间**。你无法只下 Web 部分（没有官方单平台直链），所以就用 TPZ。

**装到哪了（已核实）**：

- Windows 导出模板根目录 = `%APPDATA%\Godot\export_templates\`
- 本次会解压到 `%APPDATA%\Godot\export_templates\4.7.2.stable\`
- 目录名来自 TPZ 内部 `version.txt` 的内容（源码 `_tpz_file_selected()` 逻辑），**不是**你随便起的名字

```powershell
# 安装后验证（PowerShell）
Get-ChildItem "$env:APPDATA\Godot\export_templates" -Directory
# 期望看到：4.7.2.stable ...

Get-ChildItem "$env:APPDATA\Godot\export_templates\4.7.2.stable" -Filter "web_*"
# 期望看到：web_debug.zip, web_release.zip, web_nothreads_debug.zip,
#           web_nothreads_release.zip, web_dlink_*.zip ...
# （文件名清单来自引擎源码 export_template_manager.cpp，已核实）
```

### 3.4 命令行 / CI 能不能用环境变量或自定义路径？

**能，但只有一条正规途径：自包含模式（self-contained mode）。**

官方文档（`File paths in Godot projects`）明确：

- 编辑器数据（含导出模板）默认在 `%APPDATA%\Godot\`；
- 在编辑器 exe 同目录放一个名为 `_sc_` 或 `._sc_` 的文件，Godot 就启用**自包含模式**，把所有编辑器数据/设置/缓存写到 `editor_data/` 子目录；
- 也就是说：**把 `4.7.2.stable` 整个模板文件夹放到 `<编辑器目录>\editor_data\export_templates\4.7.2.stable\`，Godot 就认。**

```powershell
# 例：让导出模板跟着绿色版 Godot 一起走（便于拷机器 / CI 缓存）
$godot = "$env:USERPROFILE\Godot"
New-Item -ItemType File -Force -Path "$godot\_sc_" | Out-Null     # 启用自包含模式
New-Item -ItemType Directory -Force -Path "$godot\editor_data\export_templates" | Out-Null
# 之后在编辑器里用 Manage Export Templates 装一次 TPZ，就会落到这个目录
```

**不成立的途径（别踩）**：

- **没有** `GODOT_EXPORT_TEMPLATES` 这类环境变量。官方文档里唯一列出的环境变量覆盖是 Linux/*BSD 上的 `XDG_DATA_HOME` / `XDG_CONFIG_HOME` / `XDG_CACHE_HOME`（遵守 XDG 规范），以及把编辑器二进制放进 `PATH`。**Windows 下没有官方支持的环境变量改模板路径——标注「未证实」我没有找到任何 Windows 下的官方环境变量覆盖机制。**
- `export_presets.cfg` 里有 `custom_template/debug` / `custom_template/release` 两个字段（源码里是 `PROPERTY_HINT_GLOBAL_FILE, "*.zip"`，属于**高级选项**）。理论上你可以指向任意路径的模板 zip，但那是"自定义模板"功能，**不等于官方模板的标准安装路径**，且高级选项默认折叠。**这条路可行但未实测，标注「未证实」。**

**CI 上更实际的做法**：在 CI 机器上先跑一次编辑器装好模板（或用自包含模式把带模板的 `editor_data/` 作为缓存目录），然后再跑 `godot --headless --export-release`。

---

## 4. 编辑器界面速览与各面板职责

打开一个项目后，默认布局大致是：左侧 **Scene + FileSystem**，右侧 **Inspector**，中间是**视口**（2D/3D/AssetLib 等主屏），底部是 **Output / Debugger / Animation / Audio / Shader** 等标签页，写脚本时中间切到 **Script** 编辑器。

### 4.1 各面板在本项目里的职责

| 面板 | 干什么 | 本项目里你实际会用它做什么（对应 `design_v1.md` §4） |
|---|---|---|
| **Scene**（左上） | 当前场景的**节点树**；`+` 加节点，右键加子节点/实例化场景 | 搭 `battle_scene.tscn`：`Node3D > BattleView/Units/Terrain/FX/CameraRig`；把 `unit_visual.tscn` 实例化 8 份 |
| **FileSystem**（左下） | 项目文件浏览器（`res://`） | 建 `src/core`、`src/view`、`tests`、`addons` 目录；双击 `.tscn` 打开；双击 `.gd` 编辑；`右键 → New Resource` 建 `.tres` |
| **Inspector**（右） | 当前选中对象的**全部属性**，以及脚本用 `@export` 暴露的字段 | 填 `UnitData.tres` 的数值（力量/护甲/物抗）；调 `Camera3D` 的 `projection = Orthogonal`、`size`、旋转；给 `MeshInstance3D` 选 `CapsuleMesh` 和材质 |
| **2D 视口**（主屏） | 2D 场景编辑（本项目几乎不用） | **基本不用**。v1 是 3D 场景 + 正交相机。UI（`Control` 节点）以后会在这里摆 |
| **3D 视口**（主屏） | 3D 场景编辑，鼠标中键/右键可轨道旋转视图 | **主力面板**：摆棋盘、放单位、调相机角度、看 `DirectionalLight3D` 阴影。左上角有透视/正交、网格吸附等工具按钮 |
| **Script 编辑器**（主屏） | 写 `.gd`；有补全、跳转定义、错误下划线 | 写全部 `src/**/*.gd` 与 `tests/*.gd`。AI 写好文件后你在这里看改动、按 F5 试 |
| **Output**（底部） | `print()` 的输出、引擎错误、警告 | 看 `print("damage=", d)` 的调试输出；**遇到"莫名不生效"先看这里有没有红字** |
| **Debugger**（底部） | 断点、逐行、调用栈、性能监视器（帧率/内存/draw call） | M4 验收帧率时用它看 FPS 与 draw call；排查空引用崩溃的调用栈 |
| **AssetLib**（主屏之一） | 官方素材库，一键装插件 | 装 **GUT** 或 **gdUnit4**（测试框架，见 §12）；本项目**不需要任何美术素材**，所以这里只用来装插件 |
| **Inspector 下的 Signals 标签** | 给当前节点的信号连线 | 把按钮的 `pressed` 连到 `hud.gd` 的方法；把 `battle_scene` 的自定义信号 `battle_finished` 连给外层 |
| **Project Settings**（`Project → Project Settings…`） | 项目级配置，写进 `project.godot` | 渲染器选 Compatibility、设置主场景、`display/window/size`、输入映射（`Input Map`）、`application/config/name`（**决定 `user://` 路径和 Web 存档 origin**） |

### 4.2 三个主屏的快捷键

| 快捷键 | 作用 |
|---|---|
| `F1` | 在浏览器打开**选中节点/类**的官方文档 |
| `F2` | 重命名选中的节点 |
| `F5` | **运行项目**（F5 = 运行主场景） |
| `F6` | 运行**当前场景**（没设主场景时用它） |
| `F8` | 停止运行 |
| `F9` | 暂停运行 |
| `Ctrl + S` | 保存当前场景/脚本 |
| `Ctrl + Shift + S` | 场景"另存为" |
| `Ctrl + Z / Ctrl + Y` | 撤销 / 重做（**编辑器里拖错立刻 Ctrl+Z，别手改 .tscn**） |
| `Ctrl + 1 / 2 / 3 / 4` | 切换主屏：2D / 3D / Script / AssetLib（**标注「未证实」**：主屏切换的默认键位可能随版本变化，请在 `Editor Settings → Shortcuts` 里搜索 "Screen" 确认） |
| 3D 视口内 `W/E/R` | 切换平移/旋转/缩放 Gizmo 模式（**标注「未证实」**，同上可在 Editor Settings 确认） |

> 快捷键都可以在 `Editor → Editor Settings → Shortcuts` 里查和改。**不确定就用鼠标点菜单**，比记错键位强。

### 4.3 一个项目该有的一次性配置（`Project → Project Settings…`）

```ini
# 这些是 project.godot 里的键（可在编辑器 UI 里改，也可手改文本）
[application]
config/name = "Battle Chess"        # 影响 user:// 路径，起名后别乱改（会换存档目录）
run/main_scene = "res://src/view/main_menu.tscn"   # 主场景（F5 跑它）

[rendering]
renderer/rendering_method = "gl_compatibility"      # ★ 必须：Web 只能用 Compatibility
```

- **`renderer/rendering_method`**：Web 平台上 Forward+ 与 Mobile **都不可用**（Web 只有 WebGL 2.0，Godot 不支持 WebGPU），所以这一项必须选 **Compatibility**。桌面开发也用同一个渲染器，避免"桌面好看、Web 翻车"。
- **输入映射**：`Input Map` 标签里集中定义 `ui_*` 之外的键（移动、转向、确认、取消、旋转相机）。`design_v1.md` M5 验收要求"键盘可完成同一流程"，所以键位要在这里统一登记，不要散落在 `_input` 里硬编码 `KEY_Q`。
- **`application/config/name`**：决定了 `user://` 的目录名，而 Web 下 `user://` 是 IndexedDB 虚拟文件系统、按 origin 隔离。**改了名字等于换了存档目录**，发布后别改。

---

## 5. GDScript 最小必要知识（含本项目禁令）

GDScript 的设计目标就是"Python 程序员 30 分钟能读懂"。下面只列**与本项目直接相关**的部分。

### 5.1 与 Python 的异同（速查）

| 项 | Python | GDScript 4 |
|---|---|---|
| 缩进定块 | ✅ 4 空格 | ✅ 缩进，**但一个文件内必须统一用 Tab 或空格**（项目里统一用 Tab，Godot 默认） |
| 函数 | `def` | **`func`** |
| 变量/常量 | `x = 1` / `X = 1` | **`var x = 1`** / **`const X = 1`**（`var` 是强制的，不像 Python 直接赋值） |
| 类型标注 | `x: int = 1` | 同（可选，但**本项目的 core 层强制写**） |
| 类声明 | `class Foo:` | **`class_name Foo extends Resource`**（或分两行；`class_name` 会注册为**全局类名**，其它文件直接用它，不用 `import`） |
| 继承 | `class Foo(Bar)` | `extends Bar` |
| 导入 | `import x` / `from x import y` | **没有 import**。靠 `class_name` 全局可见，或 `preload("res://x.gd")` |
| 空值 | `None` | **`null`** |
| 布尔 | `True/False` | **`true/false`**（小写） |
| 逻辑运算 | `and or not` | **`and or not`**（也支持 `&&` / `‖` / `!`，但官方风格指南要求用 `and` / `or` / `not`） |
| 字符串格式化 | f-string | **`"%d 点" % n`**、`"a" + str(n)`，或 `"%s" % [a, b]`。**没有 f-string**（4.7 有 `String.format`，但 `%` 最稳） |
| 函数默认参数 | ✅ | ✅ |
| 关键字参数 | ✅ | ❌ 不支持 `f(x=1)`，**必须按位置传参** |
| 匿名函数 | `lambda` | **`Callable`**（`func(): ...` 匿名函数字面量） |
| 异常 | `try/except` | **没有异常**。用返回值 `Error` 枚举，或 `assert()` |
| 三元 | `a if c else b` | **`a if c else b`**（同 Python；也支持 `c ? a : b`，但风格指南推荐前者） |

### 5.2 最短的"能读懂"示例集（每段 ≤15 行）

**(1) 纯逻辑类（本项目 `src/core/` 的标准写法）**

```gdscript
# res://src/core/damage.gd
class_name Damage
extends RefCounted          # ★ 不 extends Node —— 规则层的铁律

enum ResMode { DIVIDE, MULTIPLY, FLAT }

static func power_damage_milli(p_milli: int, a_milli: int, r_milli: int, k: int, h_milli: int) -> int:
    # 全部整数域运算（千分比），禁止浮点比较（ADR-5）
    var p_eff: int = int(round((p_milli + 2000 * k) * h_milli / 1000.0))
    if r_milli >= 1000:
        push_error("R >= 1000 是非法数据（除零）")
        return 0
    return (p_eff - a_milli) * 1000 / (1000 - r_milli)
```

要点：`static func` 让调用方无需实例化；`-> int` 是返回类型标注；`push_error()` 是"报错但不中断"；`enum` + `match`（类似 `switch`）用来做 `res_mode` 三模式分派。

**(2) `Resource` 数据类（`src/data/units/*.tres` 的原型）**

```gdscript
# res://src/core/unit_data.gd
class_name UnitData
extends Resource

@export var id: StringName = &""
@export var display_name: String = "民兵"
@export_group("基础属性（千分比）")
@export var base_stats: Dictionary = {}
@export var growth_points_per_level: int = 3
@export_group("升级曲线")
@export var kill_thresholds_cumulative: Array[int] = [1, 3, 7, 15]
@export var max_level: int = 5
```

`@export` = "把这个字段暴露到 Inspector 里让我填"。`@export_group("...")` 只是折叠分组，纯 UI 用途。`&"..."` 是 `StringName` 字面量（性能更好的字符串）。

**(3) 节点脚本：生命周期与 `@onready`**

```gdscript
# res://src/view/camera_rig.gd
extends Node3D

@onready var cam: Camera3D = $Camera3D     # 子节点在 _ready 时才存在，必须 @onready

func _ready() -> void:
    cam.projection = Camera3D.PROJECTION_ORTHOGONAL
    cam.rotation_degrees = Vector3(-55.0, 45.0, 0.0)   # ADR-2：俯角 55°

func _input(event: InputEvent) -> void:
    if event is InputEventKey and event.pressed and event.keycode == KEY_Q:
        cam.rotation_degrees.y -= 90.0                 # 四向旋转
```

生命周期顺序（记住这条就够）：
`_init()`（构造） → 进入场景树 → `_enter_tree()` → **`_ready()`（子节点已就绪，最常用）** → 每帧 `_process(delta)` → 退出时 `_exit_tree()` → `_notification(NOTIFICATION_PREDELETE)`。
`_physics_process(delta)` 是固定步长（默认 60 Hz），物理/确定性逻辑用它。

**(4) 信号：定义、连接、触发、等待**

```gdscript
# res://src/view/battle_scene.gd
extends Node3D

signal battle_finished(result: String)      # 自定义信号，可带参数

func _ready() -> void:
    var btn: Button = $HUD/EndTurnButton
    btn.pressed.connect(_on_end_turn_pressed)     # Godot 4 写法：Callable

func _on_end_turn_pressed() -> void:
    battle_finished.emit("victory")               # 触发

# 外层 RPG 可以这样等（design_v1.md R13 的接入方式）：
# var scene := preload("res://src/view/battle_scene.tscn").instantiate()
# add_child(scene)
# var result: String = await scene.battle_finished
```

三种连接方式，按可读性排序：**（a）编辑器 Signals 面板点连线**（最快，但连接信息进 `.tscn`）；**（b）代码 `signal.connect(callable)`**（推荐，改动可 diff）；**（c）`await signal`**（当协程用）。

**信号 vs 直接调用**：本项目所有 `core → view` 的通信用**事件数组**（`design_v1.md` ADR-4），`view` 内部的 UI 通信用信号。**禁止 `core` 里出现 `emit_signal`** —— 那会让它依赖 `Object` 的信号机制，破坏"纯逻辑可 headless 测试"。

**(5) `preload` vs `load`**

```gdscript
# preload：编译期解析，路径必须写死，返回资源；加载失败编辑器就报错（推荐）
const UNIT_MELEE := preload("res://src/data/units/melee_grunt.tres")
const BATTLE_SCENE := preload("res://src/view/battle_scene.tscn")

# load：运行时解析，可以拼接路径，失败返回 null（用于动态加载）
func load_level(level_id: String) -> LevelData:
    var path := "res://src/data/levels/%s.tres" % level_id
    var res: Resource = load(path)
    if res == null:
        push_error("关卡不存在：" + path)
    return res as LevelData
```

**(6) `RefCounted` vs `Node`（本项目最重要的类型选择）**

| | `RefCounted`（含 `Resource`） | `Node` |
|---|---|---|
| 生命周期 | **引用计数**：没人引用就自动释放 | **场景树管理**：`add_child()` 出生，`queue_free()` 死亡 |
| 能被 `--headless --script` 直接用吗 | ✅ **完全没问题** | ⚠️ 可以 `new()`，但没进树时 `_ready` 不会调、`get_node` 拿不到子节点 |
| 进场景树吗 | ❌ 不能 | ✅ 必须 |
| 能被 `@export` 到 Inspector 吗 | ✅（`Resource` 可以，`RefCounted` 需序列化才行，所以用 `Resource`） | ❌ |
| 本项目用在哪 | `src/core/**`、`src/ai/**`、`src/save/**` | `src/view/**` |

**判据一句话**：**这个类需要"存在于世界里"吗？需要就是 `Node`，不需要就是 `RefCounted`/`Resource`。** 伤害公式不需要存在于世界里 → `RefCounted`。血量条需要显示在屏幕上 → `Node`。

### 5.3 本项目的硬性禁令（写代码前先背下来）

| 禁令 | 原因 | 怎么检查 |
|---|---|---|
| ❌ **`src/core/**` 与 `src/ai/**` 不许 `extends Node`** | 规则层必须能在 headless 下不进场景树直接跑（ADR-4） | `Select-String -Path src\core\*.gd -Pattern 'extends Node'` 应为空 |
| ❌ **`src/core/**` 不许 `get_node` / `$` / `emit_signal` / 任何渲染 API** | 同上 | 同上，grep 这些关键词 |
| ❌ **禁止浮点比较参与任何分支判定** | 整数千分比 + 定点数，避免"同一局面两次结果不同"（ADR-5） | 禁止 `if d < 1.0:` 这种；一律 `if d_milli < 1000:` |
| ❌ **禁止 `rng.randf() * 100 < pct`** | 浮点抽样不可复现、无法与 Python 原型逐条对账 | 只用 `rng_service` 的整数掷骰：`rng_int(1, 100) <= pct` |
| ❌ **禁止 `RandomNumberGenerator`（64 位）用于战斗** | 状态存不进 `uint32` 存档，跨语言对不上 | 用 ADR-5 规定的 32 位 LCG |
| ❌ **禁止依赖 `Array.sort()` 决定行动顺序** | 排序不稳定会导致同局面不同结果 | 行动顺序必须由明确的 `turn_manager` 决定 |
| ⚠️ **`src/core/**` 里 `print()` 只用于调试，正式输出走事件流** | 事件数组才是 `view` 的数据源 | — |

**依赖方向铁律**（`design_v1.md` §4）：**`view → ai → core`，`core` 绝不反向依赖。** Code Review 只看这一条也能保住架构。

**取整三件套（必须与 `spec_rules.md` 一致，混用就错）**：
- 伤害取整 = **`floor`**（向下取整）
- 比例乘法（高低差、精力并入）= **`round-half-up`**
- 命中率 = **`ceil(D_milli / 10)`**，不是 `round`（两者在 1..999 中有 **401/999 = 40.1%** 的取值不同）

---

## 6. 一次完整的最小开发循环（手把手）

目标：**从零到"看到画面 + 跑通 headless 测试 + 看到输出"**，全程约 30-40 分钟。

### 步骤 1：新建项目

1. 启动 Godot 4.7.2 → 弹出 **Project Manager**；
2. 点 **Create**（或 `New Project`）；
3. **Project Name**：`battle_chess`；
4. **Project Path**：点 `Browse` 选一个空目录，例如 `E:\dev\battle_chess`（**不要**选到当前的需求文档目录里）；
5. **Renderer**：**必须选 `Compatibility`**（Web 导出要求；桌面开发也用它，保持一致）；
6. **Version Control Metadata**：选 **Git** —— 它会自动生成 `.gitignore` 和 `.gitattributes`（官方文档确认），省掉 §9 一半的工作；
7. 点 **Create & Edit**。

> 项目根目录会立刻出现 `project.godot` 和 `.godot/`（`.godot/` 是缓存，**不要提交**，见 §9）。

### 步骤 2：建立目录结构

在左下角 **FileSystem** 面板里：右键项目根 → **New Folder…**，逐个建出 `design_v1.md` §4 的骨架：

```
res://
├─ src/core/          ← 纯逻辑：fixed_math.gd / rng_service.gd / grid.gd / unit_state.gd
│                        unit_data.gd / damage.gd / ballistics.gd / turn_manager.gd
│                        action_resolver.gd / level_system.gd / battle_core.gd / battle_setup.gd
├─ src/ai/            ← dumb_ai.gd
├─ src/data/units/    ← *.tres 兵种原型
├─ src/data/levels/   ← *.tres 关卡
├─ src/save/          ← save_service.gd / migrations.gd
├─ src/view/          ← *.tscn + *.gd（表现层）
├─ tests/             ← test_*.gd + golden_vectors.json + run_tests.gd
└─ tools/             ← 非引擎脚本（Python 原型、balance_probe）
```

> **快捷做法**：也可以直接在 Windows 资源管理器里建目录，Godot 会自动扫到（切回窗口时它扫描 FileSystem）。**目录名用小写 + 下划线**，避免大小写坑（见 §11 坑 #5）。

### 步骤 3：新建 3D 场景

1. 顶部主屏切到 **3D**；
2. 点 **Scene 面板**左上角的 **`+`（Add Child Node）**，弹出节点搜索框；
3. 搜索并添加 **`Node3D`** —— 这会成为根节点；
4. 右键这个 `Node3D` → **Add Child Node** → 加 **`Camera3D`**；
5. 再加一个 **`MeshInstance3D`**；
6. 选中根节点，`F2` 重命名为 `BattleScene`；相机的父节点关系保持在根节点下；
7. `Ctrl + S` 保存，路径填 `res://src/view/battle_scene.tscn`。

### 步骤 4：把节点摆成"能看见东西"的样子

1. 选中 **`Camera3D`**，在右侧 **Inspector** 里设：`Projection` → **Orthogonal**（ADR-2）；`Size` → `16`；`Transform → Position` → `(0, 12, 8)`；`Transform → Rotation Degrees` → `(-55, 45, 0)`。
   > 推荐直接在 Inspector 里填数值。**「未证实」**：3D 视口里"相机对齐到当前视图"的快捷键在不同版本有差异，别猜。
2. 选中 **`MeshInstance3D`** → Inspector → `Mesh` → **New CapsuleMesh**；
3. `Material Override` → **New StandardMaterial3D** → `Albedo → Color` 选蓝色；`Transform → Position` 设为 `(0, 1, 0)`；
4. Scene 面板 `+` → 加一个 **`DirectionalLight3D`**，旋转 `(-45, -30, 0)`，让胶囊有明暗层次；
5. `Ctrl + S` 保存。

> **看不到东西？** 依次查：`MeshInstance3D` 是否在相机前方、相机 `Far` 是否够远、场景里有没有 `DirectionalLight3D`。最省事：用 3D 视口左上角的小图标切到相机预览。

### 步骤 5：写脚本并打印输出

1. 右键 Scene 面板里的根节点 `BattleScene` → **Attach Script…**；
2. 路径填 `res://src/view/battle_scene.gd`，模板选 **Default**（`extends Node3D`），点 **Create**；
3. 中间主屏自动切到 **Script 编辑器**，粘贴：

```gdscript
extends Node3D

@onready var pivot: MeshInstance3D = $MeshInstance3D
var t: float = 0.0

func _ready() -> void:
    print("battle_scene ready, node count = ", get_child_count())

func _process(delta: float) -> void:
    t += delta
    pivot.position.y = 1.0 + sin(t * 2.0) * 0.15   # 待机浮沉（ADR-3 的动画三件套之一）
```

4. `Ctrl + S` 保存。切回 **Output** 面板，点 **Clear**。

### 步骤 6：设主场景并按 F5 运行

1. 顶部菜单 **Project → Project Settings… → General → Application → Run**；
2. **Main Scene** 右边点文件夹图标 → 选 `res://src/view/battle_scene.tscn` → **Close**；
3. 按 **`F5`**（运行项目）或 **`F6`**（只运行当前场景）；
4. 弹出的游戏窗口里应看到蓝色胶囊在上下浮动；编辑器底部 **Output** 面板应打印 `battle_scene ready, node count = 4`；
5. 按 **`F8`** 停止。

> **F5 与 F6 的区别**：F5 跑 Project Settings 里的主场景；F6 跑当前打开的场景。项目早期主场景还没定的时候用 F6。

### 步骤 7：写第一个 headless 测试脚本

现在验证"规则层不需要引擎"这件事。新建 `res://tests/run_tests.gd`（FileSystem 面板右键 `tests` → **New Script…**，或直接在 Script 编辑器里 `File → New Script`）：

```gdscript
# res://tests/run_tests.gd
extends SceneTree        # ★ --script 运行的脚本必须 extends SceneTree 或 MainLoop

var _failures: int = 0

func _initialize() -> void:
    _check_damage_basic()
    _check_damage_prob_miss()
    if _failures == 0:
        print("ALL GREEN")
    else:
        print("%d FAILURES" % _failures)
    quit()

func _check_damage_basic() -> void:
    # P=10, A=8, R=0.5 → D=(10-8)/0.5=4 → 造成 4（design_v1.md §7 用例）
    var d_milli := 4000
    _assert_eq(d_milli / 1000, 4, "P10 A8 R0.5 -> 4")

func _check_damage_prob_miss() -> void:
    # D_milli=11 → 命中率 ceil(11/10)=2%
    _assert_eq(int(ceil(11.0 / 10.0)), 2, "D_milli=11 -> 2%")

func _assert_eq(got: int, want: int, label: String) -> void:
    if got != want:
        _failures += 1
        print("FAIL %s: got %d want %d" % [label, got, want])
```

### 步骤 8：用 `godot --headless --script` 跑它

```powershell
# 关键：--path 指向含 project.godot 的目录；--headless 无窗口无 GPU
godot --headless --path E:\dev\battle_chess --script res://tests/run_tests.gd
```

期望输出：

```
ALL GREEN
```

故意改坏一个期望值再跑，应看到 `FAIL ...` 与 `1 FAILURES`。

**注意事项**：
- 脚本**必须 `extends SceneTree`（或 `MainLoop`）**，否则报错。官方文档原话："The script must inherit from `SceneTree` or `MainLoop`."
- `--path` 换成绝对路径时用正斜杠或双反斜杠；`res://` 开头的脚本路径**相对于项目根**。
- 退出码：脚本里没 `quit()` 会一直挂着；有 `quit()` 就正常退出。CI 里用 `$LASTEXITCODE` 判断。

### 步骤 9：在 Output 里确认一切

- 运行项目时：Output 面板显示 `print()` 内容；
- headless 脚本：`print()` 直接打到 **PowerShell 终端**（不是 Godot 的 Output 面板——因为没有编辑器）；
- 如果没看到输出：确认你用的是带 console 的 exe（绿色版的 `..._console.exe`），winget 版直接 `godot` 即可。

**这一圈闭环走完，你就具备了本项目的全部日常操作**：编辑器里摆场景、按 F5 看效果、命令行跑测试看输出。剩下的都是内容量问题。

---

## 7. `--headless` 与命令行能力

官方定义（已核实，`command_line_tutorial.rst`）：`--headless` = `--display-driver headless --audio-driver Dummy`，官方描述是 "Useful for servers and with `--script`."

### 7.1 本项目实际会用到的命令（对照 `design_v1.md` §8 各里程碑 AC）

```powershell
# 0) 版本自检（M0 起点）→ 期望 4.7.2.stable.official.<hash>
godot --version

# 1) ★ M0 验收：headless 测试跑通空断言 → 期望输出 "0 failures"（本手册示例输出 "ALL GREEN"）
godot --headless --path E:\dev\battle_chess --script res://tests/run_tests.gd

# 2) ★ M1-M2：单个测试文件
godot --headless --path E:\dev\battle_chess --script res://tests/test_damage.gd
godot --headless --path E:\dev\battle_chess --script res://tests/test_turn.gd

# 3) 语法检查（只解析不运行，比运行快得多）：官方定义 "Only parse for errors and quit (use with --script)"
godot --headless --path E:\dev\battle_chess --check-only --script res://src/core/damage.gd

# 4) 全工程导入（首次克隆仓库 / 换机器后跑一次，生成 .godot 缓存；会自动启动编辑器再退出）
godot --headless --path E:\dev\battle_chess --import

# 5) ★ M7：命令行导出（等价于编辑器里点导出，CI 友好）
godot --headless --path E:\dev\battle_chess --export-release "Web" build\web\index.html
godot --headless --path E:\dev\battle_chess --export-release "Windows Desktop" build\win\BattleChess.exe

# 6) 导出调试版（方便看报错） / 只导出数据包
godot --headless --path E:\dev\battle_chess --export-debug "Web" build\web_debug\index.html
godot --headless --path E:\dev\battle_chess --export-pack "Web" build\web.pck
```

**这几条命令的坑（官方文档原文）**：

1. **导出必须用编辑器二进制**，不能用导出模板二进制（"`godot` must be a Godot editor binary, not an export template."）。
2. **`--headless` 在 CI 上是必须的**（"**required** on platforms that do not have GPU access"）。
3. **输出路径相对于 `project.godot` 所在目录**，不是你敲命令时所在的目录（"**not** relative to the current working directory"）；且**目标目录必须已存在**（"The target directory must exist."）→ 先 `New-Item -ItemType Directory -Force`。
4. **预设名必须与 `export_presets.cfg` 完全一致**（含空格加引号）；**未知参数不报错**（"unknown command line arguments have no effect whatsoever. The engine will **not** warn you."）→ 打错一个字母你会以为生效了。**每次导出后都要检查产物是否更新。**

### 7.2 headless 下能做与不能做

| 能做 | 不能做 |
|---|---|
| ✅ 所有纯逻辑：伤害公式、RNG、升级、存档序列化、`RefCounted`/`Resource` 类 | ❌ 任何真实渲染结果：截图、`Viewport.get_texture()` 取像素、粒子、shader 编译产物 |
| ✅ 构造 `Node`、`add_child`、跑 `_process`（场景树存在） | ❌ 依赖 GPU/显示器的 API（窗口尺寸、鼠标位置、`DisplayServer` 相关） |
| ✅ 读 `user://`/`res://` 文件、写 JSON 存档 | ❌ 音频输出（`--audio-driver Dummy`）、手柄输入 |
| ✅ 加载 `.tscn`（能实例化） | ❌ 依赖真实帧率的性能测试（headless 下帧率无意义） |
| ✅ 用 SceneTree 做"脚本化整场战斗"（M2 验收就要求这个） | ⚠️ `await` 计时器/`Tween` 能跑，但没有真实 delta 的一致性保证 |

**实践建议**：把 M2 的"脚本化整场战斗"写成**纯 `RefCounted` 驱动**（`BattleCore` 自己 `step(action)` 循环），不要依赖 `SceneTree` 的帧循环。这样 `--headless` 下快且确定，输出的事件日志还能作为回归基准。

### 7.3 退出码与 CI 判断（PowerShell）

```powershell
godot --headless --path E:\dev\battle_chess --script res://tests/run_tests.gd
if ($LASTEXITCODE -ne 0) { throw "测试失败，exit=$LASTEXITCODE" }
```

**注意**：`print()` 出的 "FAIL" 不会自动换算成非零退出码。**你的 `run_tests.gd` 必须在失败时显式 `quit(1)`**（`SceneTree.quit(exit_code)`），否则 CI 永远绿。

---

## 8. 导出 Web 的完整流程

### 8.1 前置：Project Settings 要点

| 设置 | 值 | 为什么 |
|---|---|---|
| `rendering/renderer/rendering_method` | **`gl_compatibility`** | Web 只有 WebGL 2.0，**Forward+ / Mobile 在 Web 平台上不可用**（官方渲染器对比表在 Web 列标 ❌） |
| `display/window/size/viewport_width/height` | 例如 `1280 × 720` | 影响初始画布比例 |
| `application/config/name` | 定稿后别改 | 决定 Web 存档的 origin 与 `user://` 名 |
| `rendering/anti_aliasing/quality/msaa_3d` | 2x 或 4x | Compatibility **没有 FXAA/TAA**，MSAA 是唯一 AA 手段 |
| Glow / SSAO | 按需关闭 | 俯视固定相机下收益低、Web 上白花性能 |

### 8.2 新建 Web 导出预设（编辑器）

1. 顶部菜单 **Project → Export…**（打开 **Export** 窗口）；
2. 左上 **Add…** → 选 **Web**；
3. 在 **Runnable** 那一行会看到一排选项，**这些就是引擎源码里的导出选项**（已核实源码 `export_platform.cpp` 的选项名与默认值）：

| 界面选项 | 源码字段 | 默认 | 本项目 |
|---|---|---|---|
| **Use Threads** | `variant/thread_support` | **false** | **保持关闭** ✅ |
| **Extensions Support** | `variant/extensions_support` | false | 保持关闭（开了会要求跨源隔离） |
| **VRAM Texture Compression → For Desktop** | `vram_texture_compression/for_desktop` | true | 保持（S3TC/BPTC） |
| **VRAM Texture Compression → For Mobile** | `vram_texture_compression/for_mobile` | false | 保持关闭（开了会强制 `Import ETC2 ASTC` 并增大包体） |
| **Progressive Web App → Enable** | `progressive_web_app/enabled` | false | 按需；开了才有 service worker + manifest |
| **Ensure Cross Origin Isolation Headers** | `progressive_web_app/ensure_cross_origin_isolation_headers` | true | 仅 PWA 开启时有意义；单线程路线用不上 |
| **Export Icon** | `html/export_icon` | true | 保持（favicon 立即显示） |
| **Canvas Resize Policy** | `html/canvas_resize_policy` | Project | 保持 |
| **Focus Canvas On Start** | `html/focus_canvas_on_start` | true | 保持 |
| **Head Include** | `html/head_include` | 空 | 可放自定义 CSS/统计代码 |

> ⚠️ **`Use Threads` 的 UI 名称**：源码字段是 `variant/thread_support`，官方文档正文用 *Use Threads* 指代这个选项。**标注「未证实」**：4.7.2 中文界面下的确切中文译名我没有核实（可能是「使用线程」），请以**复选框位置**为准——它在 Web 预设的靠前位置，默认**未勾选**。

4. 设置 **Export Path**，例如 `build/web/index.html`（**以 `.html` 结尾**——引擎源码里 Web 平台 `get_binary_extensions()` 只返回 `html`）；
5. 想同时出 Windows 包：再 **Add… → Windows Desktop**，路径 `build/win/BattleChess.exe`；
6. **Export Presets** 面板关掉后会自动保存到项目根的 **`export_presets.cfg`**。

**为什么 `Use Threads` 必须关**（`tech_feasibility.md` §2.2 已核实官方原文）：

- 开了 = 用 `SharedArrayBuffer` = 服务器必须返回这两个响应头，且**整个页面必须跨源隔离**：
  ```
  Cross-Origin-Opener-Policy: same-origin
  Cross-Origin-Embedder-Policy: require-corp
  ```
- 跨源隔离意味着**页面上不能有广告、不能有第三方集成**，且 **GitHub Pages 无法配置自定义响应头**（社区长期需求），itch.io 内嵌也要额外处理；
- 官方结论原文：单线程是 "the preferred and now default way to export your games on the Web"。
- 你的是回合制战棋，**每帧逻辑量极小，单线程完全够**。

### 8.3 导出产物长什么样

点 **Export Project** 之后，`build/web/` 里会出现（文件名来自引擎源码 `_extract_template()` / `export_project()`，`<name>` = 你导出路径的文件名，例如 `index`）：

文件名来自引擎源码，`<name>` = 你导出路径的文件名（例如 `index`）：

- **必须有**：`<name>.html`（唯一需要打开的）、`<name>.js`（Emscripten 加载器）、`<name>.wasm`（**引擎本体**，最大，gzip 收益最高，官方称可压到约 **1/4**）、`<name>.pck`（**你的项目数据**）、`<name>.audio.worklet.js`、`<name>.audio.position.worklet.js`（3D 定位音频）、`<name>.png`（启动 splash）。
- **`html/export_icon` 开启时**：`<name>.icon.png`（favicon）、`<name>.apple-touch-icon.png`。
- **仅在 PWA 开启时**：`<name>.offline.html`、`<name>.service.worker.js`、`<name>.manifest.json`。

> 全部文件都必须在**同一个目录**里、且通过 **HTTP** 访问。直接双击 `index.html`（`file://`）**不行**——浏览器会因安全策略拒绝加载 `.wasm`。

### 8.4 本地起服务验证

```powershell
cd E:\dev\battle_chess\build\web
python -m http.server 8060
# 然后在 Chrome 打开 http://localhost:8060/index.html
```

**为什么 `http.server` 就够**（单线程路线）：单线程导出**不需要** `SharedArrayBuffer`，因此**不需要 COOP/COEP 响应头**，任意静态服务都能跑。这正是选单线程的核心价值。

> 官方还提供了一个专门脚本 `platform/web/serve.py`（用法 `python serve.py --root .`），它会**额外发送正确的 MIME 类型**（尤其 `.wasm` 必须是 `application/wasm`，否则会丢掉启动优化）。**「未证实」**：`serve.py` 在 4.7.2 仓库中的确切路径为 `platform/web/serve.py`（`tech_feasibility.md` §2.4 记录过该 URL），我只核实了文档级的引用，没实测下载。

**注意 `localhost` 的豁免**：浏览器把 `localhost` 视为安全上下文，所以剪贴板、PWA 等 API 在本地可测。局域网用 `http://192.168.x.x:8060` 打开时**不是**安全上下文，部分 API 会失效——测真机请用 HTTPS 或 `localhost` 转发。

### 8.5 gzip 与 itch.io

| 环境 | 你要做什么 |
|---|---|
| **自己 / VPS / Cloudflare Pages / Netlify** | 打开服务端 gzip/brotli 即可，**尤其要压 `.wasm` 与 `.pck`** |
| **GitHub Pages** | 官方文档把它列在"**提供即时压缩**的托管方（gzip）"里 → **单线程路线可直接部署** |
| **itch.io** | 官方文档把它列在"**不**提供即时压缩"的托管方里 → **你必须自己预先压缩** |

itch.io 预压缩的实操：

```powershell
# 在导出目录里，对每个 >1KB 的文件生成同名 .gz（itch.io 会自动识别 x.gz 并直接下发）
Get-ChildItem -File | Where-Object { $_.Length -gt 1KB } | ForEach-Object {
    $in  = $_.FullName
    $out = "$in.gz"
    if (Test-Path $out) { Remove-Item $out }
    $src = [System.IO.File]::OpenRead($in)
    $dst = [System.IO.File]::Create($out)
    $gz  = New-Object System.IO.Compression.GZipStream($dst, [System.IO.Compression.CompressionMode]::Compress)
    $src.CopyTo($gz); $gz.Dispose(); $dst.Dispose(); $src.Dispose()
}
# 然后把整个目录（含 .gz）打包成 zip 上传到 itch.io，勾选 "This file will be played in the browser"
```

> **「未证实」**：itch.io 对 `.gz` 的识别细节（是否需要保留原始文件、是否需要特定命名）请以其官方 [HTML5 上传文档](https://itch.io/docs/creators/html5) 为准；上面的做法是社区通行做法，我在本机无法实测。

**其他 Web 坑（`tech_feasibility.md` §3 已核实）**：
- **音频**：默认 Sample 模式**不支持 AudioEffects / 混响 / 多普勒 / 程序化音频**，3D 定位音频"可能不总是正常工作"。切 Stream 模式能恢复特性但延迟变高（单线程下更明显）。v1 只用简单采样音。
- **后台暂停**：标签页失焦时浏览器暂停项目，`_process`/`_physics_process` 停止；**独立窗口不受影响**。你的 `await` 计时动画要考虑这个。
- **全屏 / 鼠标捕获**：必须在输入回调（`_input`/`_unhandled_input`）内触发，不能靠 `Input` 轮询。**弹道拖拽瞄准必须走输入回调。**
- **存档**：`user://` 落到 **IndexedDB**；清站点数据 / 无痕模式 / iframe 嵌入且禁第三方 cookie → **丢档**。所以 `design_v1.md` §6 把"存档导出/导入字符串"列为**硬需求**。
- **Service Worker 旧缓存**：测试时"看到旧版本"，去 DevTools → Application → Unregister service worker + 勾 "Update on reload"。

### 8.6 iOS 内存坑（必须知道）

- 官方 issue [#70621](https://github.com/godotengine/godot/issues/70621)：Godot 默认 `WASM_MEM_MAX=2048MB`，**iOS 16.2 Safari 直接 OOM**；把 `WASM_MEM_MAX` 改到 256MB 后消失。该 issue 至今 open。
- `design_v1.md` Q12 的默认决定是 **iOS Safari 不列入 v1 验收目标**，理由：修它需要**编译自定义 Web 模板**。
- 所以：**v1 明确"iOS 请用 Chrome/Firefox"**，移动端列为"尽力支持"。别在 v1 上耗时间。

---

## 9. 版本管理与协作

### 9.1 `.gitignore`（Godot 4.1+ 的官方清单）

官方文档 *Version control systems* 明确，Godot 4.1 及以后应忽略：

```gitignore
# Godot 4 生成物（官方明确要求忽略）
/.godot/
*.translation

# 导出产物（不是源码，别提交）
/build/
/export/
*.pck
*.exe
*.wasm
*.zip
!*.import            # 例外：见下

# 编辑器 / 系统
.DS_Store
Thumbs.db
desktop.ini

# 本机环境
/tools/rules_proto/__pycache__/
*.pyc
```

**逐条说明**：

| 文件/目录 | 提交？ | 理由 |
|---|---|---|
| **`.godot/`** | ❌ **绝对不提交** | 官方明确列出。里面是本机缓存：导入结果、缩略图、`.godot/editor/` 的编辑器状态、`.godot/export_credentials.cfg`（含密码/加密密钥，**官方说"generally should not be committed"**） |
| **`export_presets.cfg`** | ✅ **要提交** | 官方明文："This file contains the vast majority of the export configuration and **can be safely committed to version control**. There is nothing in here that you would normally have to keep secret."（**注意**：Godot 3.x 与 4.0 **会**在这里存凭据，4.1+ 不会——所以别照抄老教程的"忽略它"） |
| **`.godot/export_credentials.cfg`** | ❌ 不提交 | 官方：机密信息。代价是克隆到新机器后部分导出选项缺失，手动拷一次即可 |
| **`*.import`** | ✅ **要提交** | 官方忽略清单里**没有**它。它是"导入器参数 + 依赖哈希"，是工程的一部分；只忽略 `*.translation`（导入产物） |
| **`*.translation`** | ❌ 不提交 | 官方明确列出（从 CSV 生成的二进制导入产物） |
| **二进制资源**（`.png/.wav/.glb/.blend`） | ✅ 提交，但建议 **Git LFS** | 官方提供 LFS 示例 `.gitattributes`；本项目 v1 **零外部素材**，所以基本用不上 |
| **导出产物**（`build/**`） | ❌ 不提交 | 可再生，且体积大（Web 包几十 MB） |
| **`tests/golden_vectors.json`** | ✅ **必须提交** | 跨语言对账基准（`design_v1.md` §4），是重要资产 |
| **`src/data/**/*.tres`** | ✅ 提交 | 是文本、可 diff，是"数据"不是"产物" |

> **最省事的做法**：创建项目时 **Version Control Metadata 选 Git**，Godot 会自动写好 `.gitignore` 与 `.gitattributes`（官方文档确认此功能）。已有项目则在编辑器里 `Project → Version Control → Generate Version Control Metadata`。

### 9.2 Windows 上的换行符

官方提醒：Git for Windows 默认 `core.autocrlf=true` 会把 LF 转成 CRLF，导致 `.tscn`/`.gd` 频繁显示"已修改"。两个解法（二选一）：

```powershell
git config --global core.autocrlf input
# 或者：让 Godot 生成的 .gitattributes 强制 LF（推荐，团队一致）
# .gitattributes 里应有：* text=auto eol=lf
```

### 9.3 `.tscn` / `.tres` 能不能手改 / AI 代写？

**能，但要守规矩**：

1. 它们是**文本格式**，AI 可以生成和修改（这是本手册"AI 能代劳"清单的基础）。
2. 里面的 `ExtResource("1_abc")` / `SubResource("...")` 是**资源 ID 引用**，删错会直接让场景打不开。手改后**必须在编辑器里打开验证**。
3. **`uid://` 引用**：Godot 4 给每个资源一个 UID 存在 `.godot/uid_cache.bin` 里。手改路径时如果 UID 对不上，编辑器会重新生成并可能提示"资源已重新导入"。
4. **协作铁律**：两个人（或你和 AI）**同时改同一个 `.tscn`** 极易冲突。建议：`.tscn` 的"结构"由一人在编辑器里改，`.gd` 由另一人纯文本改，**写范围分离**。

### 9.4 `.gitignore` 导致"改动不生效"的两个典型

- 你改了 `.gd`，但 Git 状态没变化 → 检查它是不是被某个过宽的规则（如 `*.json`、`build/`）吃掉了。
- 你把 `.godot/` 提交了，别人拉下来后**用你机器上的导入缓存**，导致"资源路径找不到" → 立刻 `git rm -r --cached .godot` 并加进 `.gitignore`。

---

## 10. 你需要手动做的事清单

**这张表的目的是让你准确知道"AI 能替你做多少"，不是让你觉得轻松。** 判据只有一条：**这件事需要"看"或"拖"吗？**

| # | 事项 | AI 能代劳 | 只有你能做 | 说明 |
|---|---|---|---|---|
| 1 | 写 `src/core/**/*.gd` 纯逻辑（伤害、RNG、升级、回合） | ✅ | | 纯文本，可 headless 验证 |
| 2 | 写 `tests/**/*.gd` 与 `golden_vectors.json` 对账 | ✅ | | 同上 |
| 3 | 写 `project.godot` / `export_presets.cfg` / `.gitignore` 文本 | ✅ | | 但**渲染器与主场景的正确性要你验** |
| 4 | 写 `src/view/**/*.gd`（相机逻辑、动画播放、UI 回调） | ✅ | | 可以写，但**"看起来对不对"必须你按 F5** |
| 5 | 写 `.tres` 数据资源（兵种原型、关卡、balance） | ✅ | | 但如果 AI 生成的 `ExtResource` ID 有问题，需你在编辑器里打开修复 |
| 6 | 手写 `.tscn` 场景文本 | ⚠️ **能但风险高** | | 建议：AI 只写**扁平、无交叉引用**的简单场景；复杂场景你在编辑器里搭 |
| 7 | **在编辑器里拖拽摆场景**（相机角度、光照、单位位置、UI 布局） | ❌ | ✅ **必须** | AI 没有眼睛，看不到 55° 俯角"好不好看" |
| 8 | **安装导出模板**（下载 1.19 GiB + 菜单安装） | ❌ | ✅ **必须** | 需要 GUI 文件选择框与人工点按 |
| 9 | **点导出 / 在 Chrome 里真机试玩** | ❌ | ✅ **必须** | 需要浏览器与判断"手感" |
| 10 | **弹道瞄准手感调参**（力度/角度映射、是否开辅助） | ❌ | ✅ **必须** | `design_v1.md` Q2 的开放问题，只能真人试 |
| 11 | **程序化美术的"可读性"判断**（形状/颜色语义够不够区分兵种） | ❌ | ✅ **必须** | R-3 被标为"最致命的产品风险"，必须找人试玩 |
| 12 | **帧率实测**（中端集显 + Chrome ≥55 FPS） | ❌ | ✅ **必须** | `design_v1.md` §7 明确"此数字为工程目标，非官方基准，必须真机实测" |
| 13 | **装 GUT / gdUnit4 插件** | ❌ | ✅ | 编辑器里 AssetLib 一键装；装完 AI 可以写测试 |
| 14 | 写测试断言、跑 `godot --headless --script` 命令行测试 | ✅ | | 只要你把 Godot 装好、`--path` 给对 |
| 15 | 用 `--export-release` 跑命令行导出 | ⚠️ | ✅ | 命令 AI 能给、能跑，但**前提是模板已装、预设已在编辑器里建好** |
| 16 | 读 Output / Debugger 里的报错并修（若是代码问题） | ✅ | | 把报错原文贴给 AI 即可 |
| 17 | **iOS / Safari 真机验证** | ❌ | ✅ | 且 v1 已决定不做（见 §8.6） |
| 18 | **回答 §11 的 13 个开放问题**（Q0/Q3 最关键） | ❌ | ✅ | 这是价值判断，不是技术判断 |
| 19 | 存档导出字符串的**真机验证**（清站点数据后能恢复） | ❌ | ✅ | M7 的硬需求 AC |
| 20 | 写文档、README、CHANGELOG | ✅ | | 纯文本 |

**总结成三句话**：

1. **所有 `.gd` / `.json` / `.md` / 大部分 `.tres` 的文本内容，AI 可以整包写。**
2. **所有"看着调"的事（场景摆放、相机、手感、可读性、帧率）必须你本人。**
3. **所有"装环境 / 点 GUI / 真机试"的事必须你本人**——但它们大多是**一次性**的（装 Godot、装模板、建导出预设），做完之后 AI 的产出率才真正上来。

---

## 11. 新手最常见的 10 个坑

### 坑 #1：没设主场景，F5 直接报错

- **现象**：按 F5 弹出提示 "No main scene has ever been defined"，或者让你选一个场景。
- **原因**：`Project Settings → Application → Run → Main Scene` 为空。F5 只能跑主场景，F6 才能跑"当前场景"。
- **解决**：设主场景（`Project → Project Settings… → General → Application → Run → Main Scene`）；或临时用 **F6**。

### 坑 #2：脚本写了但没"挂"到节点上

- **现象**：`_ready()` 里的 `print()` 从来不输出，游戏没有任何变化，Output 里也没有报错。
- **原因**：`.gd` 文件存在 ≠ 脚本生效。**脚本必须 attach 到某个节点**（`.tscn` 里该节点有 `script = ExtResource(...)`）。
- **排查**：Scene 面板里选中节点，看 Inspector 顶部**有没有一个脚本图标**；没有就右键节点 → **Attach Script…**。
- **更隐蔽的版本**：你 attach 的是 A 场景的节点，但你 F5 跑的是 B 场景。

### 坑 #3：信号连接报 "Nonexistent function" 或参数数量不匹配

- **现象**：运行时报 `Invalid call. Nonexistent function 'xxx' in base 'Node'`，或者信号触发了但回调没进。
- **原因**：三种常见错法 ——（a）`connect` 的方法名拼错；（b）**Godot 3 写法** `connect("sig", self, "method")` 在 Godot 4 里已经废弃，必须用 Callable：`sig.connect(method)`；（c）信号带参数但回调签名不匹配（例如 `timeout(delta)` 只收 delta，你写了两个参数）。
- **解决**：用编辑器 Signals 面板连线（会自动生成正确的 `_on_...` 方法），或在代码里写 `sig.connect(_on_sig)` 并让编辑器补全；报错时把**完整报错原文**贴给 AI。

### 坑 #4：`@onready` 变量是 null

- **现象**：`Invalid access to property or key 'x' on a base object of type 'Nil'`，或者 `Attempt to call function on a null instance`。
- **原因**：（a）忘了 `@onready`，在 `_ready` 之前访问子节点 → null；（b）`$Path/To/Node` 路径写错（大小写、层级不对）；（c）节点是**运行时才 add_child** 的，`_ready` 时还不存在。
- **解决**：
  - 确认路径：在 Scene 面板里**右键节点 → Copy Node Path**，粘到你代码里，别手打；
  - 运行时才创建的节点用 `await get_tree().process_frame` 或放在创建之后再取；
  - 加防御：`assert(cam != null, "Camera3D 没找到")`，让错误发生在**你预期的地方**而不是 10 行之后。

### 坑 #5：资源路径大小写不一致

- **现象**：编辑器里能跑，导出的 Web 包/`.exe` 里报 "Cannot open file res://Src/Core/Damage.gd" 或资源变空。
- **原因**：Windows 文件系统**不区分大小写**，Linux/macOS 与 Web 打包**区分大小写**。你在 Windows 上写 `res://Src/Core/damage.gd`，实际文件是 `src/core/damage.gd`，本地能跑，导出后崩。
- **解决**：**所有路径一律小写 + 下划线**；删掉重命名时注意 Git 在 Windows 上对大小写重命名的迟钝（用 `git mv` 分两步改）。官方文档专门有一节提醒 case sensitivity。

### 坑 #6：改了东西但不生效（`.godot` 缓存 / Service Worker）

- **现象**：代码明明改了，运行结果还是旧的。
- **原因**（三选一）：
  - **（a）编辑器缓存**：`.godot/` 里的导入缓存/UID 缓存过期（多见于手改 `.tscn`/移动资源之后）；
  - **（b）Web 版 Service Worker 旧缓存**：官方 troubleshooting 明确列出，"一键部署多个项目时会命中旧缓存"；
  - **（c）**你在跑的其实不是当前打开的场景（见坑 #1）。
- **解决**：
  - （a）`Project → Reload Current Project`；仍不行就关掉 Godot，删掉项目根 `.godot/` 目录，重开（会重新导入，可能几分钟）；
  - （b）DevTools → Application → Service Workers → **Unregister** + 勾 **Update on reload**；
  - （c）确认主场景。

### 坑 #7：headless 下跑带渲染的代码

- **现象**：`godot --headless --script ...` 报 GPU / RenderingDevice / viewport 相关错误，或拿到的数据全是默认值。
- **原因**：`--headless` = `--display-driver headless --audio-driver Dummy`。**没有真实视口、没有 GPU 输出**。任何"读像素、截图、看渲染结果、依赖真实窗口尺寸"的代码都得不到有意义的结果。
- **解决**：
  - 把规则测试写成**纯 `RefCounted`**，根本不碰渲染（这正是 ADR-4 的用意）；
  - 需要验证渲染的部分（M4 的 2.5D 表现）**必须开编辑器按 F5 人肉看**，或用 `--write-movie` 写视频帧（**「未证实」**：`--write-movie` 在 headless 下的可用性我没实测，官方定义为"Run the engine in a way that a movie is written"）；
  - 不要试图用 headless 做帧率测试。

### 坑 #8：`load()` 返回 null / 资源路径写错

- **现象**：`preload("res://...")` 报 "Cannot open file"，或 `load(path)` 返回 `null` 然后后续全崩。
- **原因**：
  - `res://` 是**项目根**，不是文件系统绝对路径；写成 `res://E:/...` 一定错；
  - 手机/Web 上路径大小写敏感（见坑 #5）；
  - 动态拼接的路径没有对应文件（关卡 id 拼错）。
- **解决**：`preload` 只用于**写死的常量路径**（编辑器会在编译期报错，帮你早发现）；动态用 `load` 并**必须判空**：`if res == null: push_error(...); return`。路径分隔符用 `/`，不要用 `\`（官方推荐在所有平台都用 `/`）。

### 坑 #9：改了 `project.godot` 的 `config/name`，存档"消失了"

- **现象**：改名后读不到原来的存档。
- **原因**：桌面端 `user://` 默认落在 `%APPDATA%\Godot\app_userdata\[project_name]\`；Web 端是**按 origin 隔离**的 IndexedDB。名字一改，存档目录/键就变了。另外 Web 端**换域名**也等于丢档。
- **解决**：发布后不要再改 `config/name`；需要固定路径就打开 `application/config/use_custom_user_dir` 并设 `custom_user_dir_name`（官方文档确认）。**任何时候都保留"存档导出/导入字符串"作为兜底**（`design_v1.md` §6 的硬需求）。

### 坑 #10：导出报"模板缺失 / 版本不匹配"

- **现象**：
  - `Export templates are missing` / 导出按钮不可用；
  - 或报找不到 `.../export_templates/4.7.2.stable/windows_release_x86_64.exe`；
  - 或你装了 4.7.1 的模板却用 4.7.2 编辑器。
- **原因**：没用 **Editor → Manage Export Templates…** 安装；或者编辑器版本与模板版本不一致（模板必须与编辑器**完全相同**的版本号，包括 `.stable` 后缀）。
- **解决**：
  1. `godot --version` 确认编辑器是 `4.7.2.stable`；
  2. 去 `%APPDATA%\Godot\export_templates\` 看有没有目录叫 `4.7.2.stable`（**这个名字来自 TPZ 内部的 `version.txt`，别手改**）；
  3. 没有就重新下载对应版本的 `.tpz` 并安装（见 §3.3）；
  4. 装完**重启编辑器**再看 Export 窗口。
- **关联坑**：`--export-release` 跑成功但产物没更新 → 检查**输出目录是否存在**（官方要求目标目录必须已存在）、**预设名是否与 `export_presets.cfg` 完全一致**（未知参数不报错，见 §7.1 第 6 条）。

---

## 12. 学习资源与阅读顺序

### 12.1 官方文档（**注意用 stable，不要 latest**）

- [关键概念总览（Scene/Node/信号）](https://docs.godotengine.org/en/stable/getting_started/introduction/key_concepts_overview.html) —— 对应本手册 §1
- [编辑器界面第一眼](https://docs.godotengine.org/en/stable/getting_started/introduction/first_look_at_the_editor.html) —— 对应 §4
- [命令行教程（`--headless`/`--script`/`--export-*` 权威定义）](https://docs.godotengine.org/en/stable/tutorials/editor/command_line_tutorial.html) —— 对应 §7
- [GDScript 基础（语法/注解/类型）](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_basics.html) —— 对应 §5
- [**GDScript 官方风格指南**](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html) —— 建议直接照抄
- [导出项目（导出预设与模板）](https://docs.godotengine.org/en/stable/tutorials/export/exporting_projects.html) —— 对应 §3、§8
- [Web 导出与限制](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html) —— 对应 §8
- [渲染器对比（为什么 Web 只能 Compatibility）](https://docs.godotengine.org/en/stable/tutorials/rendering/renderers.html)
- [文件路径（`res://` / `user://` / 编辑器数据目录 / 自包含模式）](https://docs.godotengine.org/en/stable/tutorials/io/data_paths.html) —— 对应 §3、§9、坑 #9
- [版本管理（`.gitignore` 官方清单 / Git LFS）](https://docs.godotengine.org/en/stable/tutorials/best_practices/version_control_systems.html) —— 对应 §9
- [4.6 → 4.7 迁移（破坏性变更）](https://docs.godotengine.org/en/stable/tutorials/migrating/upgrading_to_godot_4.7.html) —— 记住版本锁死，别乱升
- [程序化几何（`SurfaceTool`/`ArrayMesh`，本项目地形靠它）](https://docs.godotengine.org/en/stable/tutorials/3d/procedural_geometry/index.html) —— M4 用
- [`Tween` 类参考（ADR-3 全部动画）](https://docs.godotengine.org/en/stable/classes/class_tween.html) —— M4 用
- [类参考索引](https://docs.godotengine.org/en/stable/classes/index.html) —— 查任何 API

> **技巧**：编辑器里**选中任意节点/类，按 `F1` 直接打开它的官方文档**。比开浏览器快。

### 12.2 测试框架

| 测试框架 | 仓库 | 说明 |
|---|---|---|
| **GUT**（Godot Unit Test） | https://github.com/bitwes/Gut | 老牌、文档多；实测 2742 stars，最近推送 2026-08-18 |
| **gdUnit4** | https://github.com/MikeSchulze/gdUnit4 | 更现代，支持 GDScript 与 C#；实测 1244 stars，最近推送 2026-08-30 |

两者都能跑 headless，本项目倾向 **GUT**。装法：主屏 **AssetLib** → 搜 `Gut` → Download 到 `res://addons/` → `Project Settings → Plugins` 里 Enable。

**重要提醒**：`design_v1.md` §4 的 `tests/run_tests.gd` 是**自己的 headless 入口**，零依赖也能跑（§6 步骤 7 就是零依赖版）。**先用零依赖版把 M0/M1 跑起来，再按需引入 GUT** —— 少一个依赖，少一类版本不兼容的坑。

### 12.3 按本项目里程碑的阅读顺序（省时间版）

| 阶段 | 先读什么 | 对应本手册 |
|---|---|---|
| **M0** | 命令行教程 → 版本管理 → 导出项目 | §2 → §3 → §7 → §9 |
| **M0.5**（不需要 Godot） | **不用读** —— 用 Python 在 `tools/rules_proto/` 写原型（`tech_feasibility.md` §9.2） | — |
| **M1-M2** | GDScript 基础 → **GDScript 风格指南** → 关键概念总览 → `Resource`/`RefCounted` 类参考 | §5 |
| **M3** | `Vector3` / `Math` / `Curve3D` 类参考 | §5.3 |
| **M4** | 第一眼界面 → 3D 视口操作 → 程序化几何 → `Tween` → `Camera3D` | §1.4 → §4 → §6 |
| **M5** | `Control` 节点 → `Input Map` → 信号 | §4.3 → §5.2(4) |
| **M6-M7** | 文件路径（`user://`）→ Web 导出 → 导出项目 | §8 → §9 |
| **M8** | 渲染器能力表（`tech_feasibility.md` §3）→ Web 导出限制 | §8.5 |

**建议先只读三篇**：`command_line_tutorial`、`gdscript_styleguide`、`key_concepts_overview`。三篇加起来约 1 小时，够你走完 M0-M2。其余按需查，**不要通读**。

---

## 附：核实状态说明

**已核实**（官方文档原文 / 引擎源码 / 本机实测）：Godot 4.7.2 stable 于 2026-08-18 发布、4.8 仅到 dev7（`versions.json` 实拉）；winget 包 `GodotEngine.GodotEngine` 当前 = 4.7.2（本机 `winget show` 实跑）；编辑器 zip = 86,013,866 字节、模板 tpz = 1,281,349,702 字节（HTTP HEAD 实测，重定向到官方对象存储）；菜单路径 `Editor → Manage Export Templates…`；TPZ 内含 `web_nothreads_release.zip` 等、模板装到 `%APPDATA%\Godot\export_templates\<version>`；Web 导出选项字段名与默认值（`variant/thread_support` 默认 false 等）；Web 导出产物文件清单；`--headless`/`--script`/`--check-only`/`--export-release`/`--path`/`--import` 语义与坑；`--script` 的脚本必须 `extends SceneTree` 或 `MainLoop`；`.godot/` 与 `*.translation` 应忽略而 `export_presets.cfg` **可以**提交；Web 下 `user://` = IndexedDB 虚拟文件系统；自包含模式（`_sc_` → `editor_data/`）。以上依据：官方 *Command line tutorial* / *Exporting projects* / *Exporting for the Web* / *Version control systems* / *File paths in Godot projects* / *EditorPaths* 类参考，以及 `godotengine/godot` 的 `editor/export/export_template_manager.cpp`、`platform/web/export/export_plugin.cpp`。

**标注为「未证实」的条目**（共 6 条，涉及它们时请以本机实测为准）：

1. **Use Threads 的中文界面译名** —— 源码字段是 `variant/thread_support`，界面文字随语言包变。
2. **主屏切换 `Ctrl+1..4`、3D 视口 `W/E/R` 等快捷键** —— 键位可能随版本变，请在 `Editor Settings → Shortcuts` 确认。
3. **Windows 下用环境变量或自定义路径指定导出模板** —— 官方只提供自包含模式；`custom_template/*` 高级选项可行但未实测。
4. **`serve.py` 细节与 Web MIME/请求头** —— 未实测；`python -m http.server` 对单线程包已验证足够。
5. **itch.io 对预压缩 `.gz` 的识别规则** —— 以 itch.io 官方 HTML5 文档为准。
6. **`--write-movie` 在 headless 下的可用性** —— 未实测。

**标注为推测的工程目标**（非官方基准，必须真机实测）：中端集显浏览器 60 FPS 可达（`tech_feasibility.md` §4.2）；空项目 Web 包 20-45 MB（4.2 时代官方社区数据，4.7.2 未实测）。
