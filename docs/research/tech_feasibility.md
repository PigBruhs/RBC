# 战棋模块技术可行性验证报告

**候选架构**：Godot 4.7.x + Compatibility 渲染器 + 3D 固定相机（2.5D）+ 程序化图元 + Web 导出 + JSON 存档
**验证日期**：2026-09-30
**验证方式**：官方文档 / 官方仓库 / 官方下载站 HTTP 实测；**本机未安装 Godot，未做真机浏览器实测**
**定位**：本文件是**参考输入**，最终架构由 lead 决定。本文只提供证据、取舍与风险，不做最终裁决。
**写入范围**：本文件为唯一交付物（`docs/research/tech_feasibility.md`）。

---

## 0. 结论摘要（TL;DR）

| 待答问题 | 结论 | 置信度 |
|---|---|---|
| Godot 当前稳定版本 | **4.7.2**，2026-08-18 发布；4.8 尚在 dev7（2026-09-29），不建议 v1 使用 | 已证实 |
| Web 导出是否强制 COOP/COEP | **不强制**。只有勾选 *Use Threads* 才需要；4.3 起单线程导出是**默认且官方推荐**路线 | 已证实 |
| 单线程模板能否免头 | **能**。单线程导出不需要 `SharedArrayBuffer`，因此不需要 COOP/COEP | 已证实 |
| Web 能否用 Forward+ / Mobile 渲染器 | **不能**。Web 平台**只有 Compatibility（OpenGL/WebGL2）**，Forward+/Mobile 不可用 | 已证实 |
| 空项目 Web 包体积量级 | 官方模板为全平台 1.22 GB；**单项目 Web 传输量推测 20–45 MB 原始 / gzip 后约 7–15 MB** | 部分证实 + 推测 |
| 存档落点 | `user://` 在 Web 下是 **IndexedDB 上的虚拟文件系统**；清站点数据 = 丢档 | 已证实 |
| 无美术资源下的表现力 | 程序化图元 + `grow` 反转外壳描边 + Tween，**足以支撑 v1** | 已证实（API 层面） |
| 最大技术风险 | **iOS Safari 内存 / WebAssembly 默认 2 GB 上限**、首屏体积、清站点数据丢档 | 已证实（有官方 issue） |

**一句话**：这条路线在技术上**可行**，且是"无美术资源 + 需要 2.5D + 需要存档"约束下引擎自带能力最完整的一条；但它把风险从"能不能做出来"转移到了"**浏览器侧的内存与存档持久性**"，这两点必须在 v1 前用降级策略锁死。

---

## 1. 需求约束（来自 `BATTLE_CHESS.md`）

用户的 13 行口述规则，抽象成工程约束如下：

| 规则原文要点 | 派生的工程约束 |
|---|---|
| 力量/护甲/物抗/魔抗四属性；伤害 =（力量−护甲）/(1−物抗) | **纯函数**：伤害计算必须与表现层解耦，可用整数/浮点确定性复现 |
| 计算值 ≥1 取整、100% 命中；0<值<1 时伤害取 1 并按概率命中（精度 1%）；<0 无法造伤 | 需要**可注入种子的 RNG**，且概率精度到 1%（即 100 档） |
| 攻击护甲伤害固定、不吃物抗与力量，数值为角色固有属性 | 双伤害通道（力量通道 / 破甲通道），升级树要能加"破甲伤害" |
| 人头 1/2/4/8 升级，最高 5 级；每级 +3 点属性，可选池含射程、落地命中判定范围 | 升级选择池是**数据驱动**的配置，不是硬编码分支 |
| 精力：每回合最多 3 点，1 点 = +2 伤害；角色入场时获得上限点精力 | 回合内资源记账；精力可加进"己方力量"再走同一公式 |
| 每回合可选：普攻（近战/弹道/远程）、技能（后续）、休息 | 行动类型枚举 + 后续可扩展的技能表 |
| 近战：仅相邻 4 格，对角线不可 | 曼哈顿距离 = 1 的邻接判定（无需寻路） |
| 弹道：玩家输入方向与力度，抛物线，**无辅助瞄准 UI**，落地才判定范围内是否有敌人 | 需要自绘瞄准输入（角度+力度），需要轨迹模拟与落地判定；命中与伤害**独立** |
| 远程：必命中，动画只是动画；伤害同近战 | 远程不需要命中判定，只需射程检查 |
| **没有任何美术资源** | 全部视觉必须程序化（图元网格、材质、动画、特效） |
| 战棋只是 RPG 的一个子模块 | 架构必须允许"战棋场景"被 RPG 主循环调用/返回，不能把引擎绑定死在战棋上 |
| v1 要完整实现以上全部 + **存档** | 存档是硬需求，且必须是**可版本迁移**的结构 |

**关键判断**：这套规则的核心是**回合制离散逻辑**，对渲染几乎零要求。真正的技术难点只有三个：①弹道的方向/力度输入与落地判定；②无美术资源下的可读性（玩家要能分清单位/阵营/朝向）；③Web 存档的持久性。

---

## 2. Godot 版本与 Web 导出硬性要求

### 2.1 当前稳定版本与下载体积（已实测）

| 项目 | 实测值 | 来源 |
|---|---|---|
| 最新稳定版 | **4.7.2**（2026-08-18） | [versions.json](https://godotengine.org/versions.json)、[Windows 下载页](https://godotengine.org/download/windows/) |
| 下一个稳定分支 | 4.7（2026-06-18）；4.8 仅到 dev7（2026-09-29） | [versions.json](https://godotengine.org/versions.json) |
| Windows x86_64 编辑器 zip | **86,013,866 字节 ≈ 82.0 MiB** | 官方 CDN `HEAD` 实测 |
| 导出模板 `export_templates.tpz` | **1,281,349,702 字节 ≈ 1222 MiB ≈ 1.19 GiB** | 官方 CDN `HEAD` 实测 |
| 官方 Web 编辑器（免安装试玩） | 4.7.2 在线版可用 | [editor.godotengine.org](https://editor.godotengine.org/releases/4.7.2.stable/godot.editor.html) |

> **对 lead 估算的修正**：主方案里写的"100–150 MB 编辑器 + 1–1.5 GB 模板"，**编辑器实际偏小（约 82 MB）**，模板量级正确（约 1.19 GiB）。注意模板 `.tpz` 是**全平台合集**（含 Android/iOS/macOS/Linux/Web/Windows），Web 只是其中一小部分，但官方**不提供**按平台单独下载的稳定 URL（实测 `web_nothreads_release.zip`、`web_release.zip` 等 slug 均返回 404）。
> 下载直链：[Godot 4.7.2 Windows x86_64](https://downloads.godotengine.org/?version=4.7.2&flavor=stable&slug=win64.exe.zip&platform=windows.64)、[Export templates 4.7.2](https://downloads.godotengine.org/?version=4.7.2&flavor=stable&slug=export_templates.tpz&platform=templates)

### 2.2 COOP/COEP：是不是硬性要求？

**不是无条件的硬性要求，取决于是否开启线程。** 官方文档原文要点（[Exporting for the Web](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html)）：

- 由于 `SharedArrayBuffer` 的安全问题，Web 平台的多线程导出有诸多缺点，**包括需要特定服务端响应头和完整的跨源隔离**（意味着托管网站上不能有广告、不能有第三方集成）。
- **自 Godot 4.3 起支持单线程导出**，解决了这个问题；代价是不能使用线程、性能不如多线程导出，但"**不需要那么多安装开销，并且对 itch.io、Poki、CrazyGames 这类商店/发行商整体更兼容**"，在 macOS 和 iOS 上表现"非常好"。
- 官方结论：**"For these reasons, it is the preferred and now default way to export your games on the Web."**（单线程是首选且现在的默认 Web 导出方式）
- 当且仅当 **Use Threads** 打开时，Web 导出使用 `SharedArrayBuffer`，要求安全上下文 + 以下响应头：

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

- 如果不能控制 Web 服务器或无法添加响应头，可勾选 **Progressive Web App > Enable**，用 service worker 模拟这些响应头（**仍需要安全上下文 HTTPS**）。若既没有头、也没开 service worker 兜底，**"the project will not run"**。

### 2.3 两条路线的取舍

| 维度 | 路线 A：单线程（**推荐 / 默认**） | 路线 B：多线程（Use Threads） |
|---|---|---|
| COOP/COEP | **不需要** | **必须**（或开 PWA service worker 兜底） |
| SharedArrayBuffer | 不需要 | 需要 |
| 第三方集成（广告/统计/外部 iframe） | 可用 | **被跨源隔离阻断** |
| GitHub Pages 部署 | **可行**（无法自定义响应头也不影响） | 不可行（GitHub Pages 不能设置自定义响应头，见 §2.4） |
| itch.io 内嵌 | 官方明确"更兼容" | 需要 itch.io 侧可控头或 PWA 兜底 |
| `Thread` 类 / 多线程渲染 | 不可用 | 可用 |
| 音频延迟（Stream 模式） | 较差 | 较好 |
| iOS / macOS | 官方称"表现非常好" | 一直有兼容问题 |
| **对本地回合制战棋的实际影响** | 逻辑是回合制、每帧工作极少，**单线程足够** | 收益低、代价高 |

**结论**：本项目（回合制战棋，逻辑量极小）应**直接锁定单线程**，彻底绕开 COOP/COEP 问题。这是把"部署复杂度"归零的关键决策。

### 2.4 实际可部署性

| 托管方式 | 关键事实 | 对本项目的含义 |
|---|---|---|
| **GitHub Pages** | 官方文档列出"提供即时压缩的托管方：**GitHub Pages (gzip)**"。但 GitHub Pages **不提供**自定义响应头的配置能力（社区长期需求，见 [community discussion #13309](https://github.com/orgs/community/discussions/13309)） | **单线程路线可部署**；多线程路线不可部署 |
| **itch.io** | 官方文档列出"**不**提供即时压缩的托管方：itch.io、GitLab Pages（支持手动 gzip 预压缩）"；[itch.io HTML5 上传文档](https://itch.io/docs/creators/html5) | 单线程路线可行；**必须自己预先 gzip/brotli 压缩** |
| **本地自测** | 官方提供 `serve.py`（[脚本原文](https://raw.githubusercontent.com/godotengine/godot/master/platform/web/serve.py)），用法：`python serve.py --root .` | 本机 Python 3.13 可用，可直接起本地服务 |

> **压缩提示（官方原文）**：`.wasm` 用 gzip 可压到**原始体积的四分之一左右**；服务端压缩对 `.pck` 与 `.wasm` 尤其重要。`.wasm` 必须以 `application/wasm` MIME 返回，否则会损失启动优化。

**标注**：GitHub Pages"无法设置自定义响应头"这一条为**部分证实**——依据是官方社区讨论标题与 GitHub Pages 文档中不存在该功能；我没有找到一句官方明文"不支持"。因此工程上应按"**不敢依赖**"处理，这正好与单线程路线一致。

---

## 3. Web 导出已知限制（官方文档）

来源：[Exporting for the Web](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html)、[Overview of renderers](https://docs.godotengine.org/en/stable/tutorials/rendering/renderers.html)、[System requirements](https://docs.godotengine.org/en/stable/about/system_requirements.html)

| 类别 | 限制 | 对本项目的影响 |
|---|---|---|
| **图形 API** | 只能 WebGL 2.0；**Godot 目前不支持 WebGPU** | 这是 Forward+/Mobile 无法上 Web 的根本原因 |
| **渲染器** | **Web 上 Compatibility 是唯一选择**；Forward+/Mobile 在 Web 列为 ❌ | **v1 的光照/阴影方案必须按 Compatibility 的能力集设计** |
| **Safari** | 官方原文："Safari has several issues with WebGL 2.0 support that other browsers don't have, so we recommend using a Chromium-based browser or Firefox if possible." | Safari 是**二等公民**，需列入风险清单 |
| **内存（最低要求）** | 官方系统要求：导出的 Web 项目**桌面/笔记本最低 4 GB RAM**，移动设备最低 2 GB | 官方把 Web 的内存门槛写成了原生导出的 2 倍 |
| **音频** | 自 4.3 起用 Web Audio API；默认 **Sample** 播放模式：**不支持 AudioEffects、不支持混响/多普勒、不支持程序化音频生成**，3D 定位音频"可能不总是正常工作"；切到 **Stream** 可恢复完整特性但延迟增加（单线程下尤其明显） | v1 若要音效，只能放简单采样音；混响等后期效果**必须放弃** |
| **后台处理** | 标签页失去焦点时浏览器会暂停项目，`_process()` / `_physics_process()` 停止；但**非聚焦的独立浏览器窗口不受影响** | 回合制战棋影响很小；`await` 计时的动画需注意 |
| **全屏 / 鼠标捕获** | 必须在输入事件回调（`_input` / `_unhandled_input`）内触发，且需自定义 HTML | 弹道"拖拽瞄准"必须走输入回调，不能靠 `Input` 轮询 |
| **网络** | 底层网络未实现；仅 HTTP/WebSocket(客户端)/WebRTC，且有同源策略、不支持阻塞模式等限制 | v1 单机，无影响 |
| **剪贴板 / 手柄** | 需要安全上下文；剪贴板 API 异步，从 GDScript 访问"可能不可靠"；手柄需按键后才被检测 | 影响"存档导出为字符串"功能（见 §5） |
| **持久化** | 用户必须允许 cookie（**具体是 IndexedDB**）；`iframe` 中还需**第三方 cookie**；无痕模式不持久 | **存档硬需求的核心风险点**，详见 §5 |
| **安全上下文** | 越来越多功能只在 HTTPS 下可用（localhost 通常豁免） | 本地开发用 localhost 即可 |
| **Service worker 缓存** | 一键部署多个项目时会命中旧缓存，官方给出 DevTools 手动 unregister 的绕行办法 | 测试时若"看到旧版本"，先 unregister |

### Compatibility 渲染器的能力边界（决定画质上限）

| 能力 | Compatibility | 说明 |
|---|---|---|
| 光照方式 | Forward 单 pass；带阴影的光源走 multi-pass，混合精度较差 | 卡通/平涂风格反而合适 |
| 每 mesh 最大 OmniLight / SpotLight | **8**（可调高） | 战棋场景光源需求极低 |
| 最大 DirectionalLight | 8 | 够用 |
| MSAA 3D / SSAA | ✅ 支持 | 抗锯齿**必须靠 MSAA/SSAA** |
| FXAA / SMAA / TAA / FSR2 | ❌ / ❌ / ❌ / ❌ | 无后处理型 AA |
| MSAA 2D | ❌ 不支持 | UI 边缘可能偏硬 |
| Glow / 色调映射 / 颜色调整 / 雾 / SSAO | ✅ 支持 | 卡通描边+发光可用 |
| 体积雾 / SSR / SSIL / SDFGI / VoxelGI | ❌ 全部不支持 | 无高级 GI，靠环境光+烘焙 |
| 贴花 / 粒子拖尾 / 粒子 SDF 碰撞 / 景深模糊 | ❌ 不支持 | 粒子表现要选基础形态 |
| 计算着色器 | ❌ 不支持 | 不要设计基于 compute 的特效 |
| Normal/Roughness buffer | ❌ 不支持 | 某些后处理算法不可用 |
| 自定义后处理（fullscreen quad） | ✅ 支持 | **描边后处理可行** |
| 自定义后处理（CompositorEffects） | ❌ 不支持 | |
| Screen texture / Depth texture（shader 内） | ✅ 支持 | 深度描边可行 |
| LightmapGI | 渲染支持，**烘焙需要 RenderingDevice** | 无美术资源也用不上烘焙 |
| Light projector texture / PCSS / 次表面散射 | ❌ 不支持 | |

---

## 4. 3D 场景在浏览器中的性能预期

### 4.1 可引用的官方依据

1. **Compatibility 渲染器的定位**（[renderers 文档](https://docs.godotengine.org/en/stable/tutorials/rendering/renderers.html)）：面向"低端桌面与移动"，"渲染成本：**基线成本低，但扩展成本高**"。目标平台明确写着 "Mobile, low-end desktop, **web**"。
2. **最低硬件门槛**：Compatibility 只需要 **OpenGL 3.3（桌面）/ OpenGL ES 3.0（移动）**；推荐是 OpenGL 4.6。示例最低 GPU 是 *Intel HD Graphics 2500 (Ivy Bridge)*——即**十年前的集显**都在最低门槛内。
3. **内存门槛**：Web 导出最低 **4 GB RAM**（桌面）。
4. **光源上限**：每 mesh 最多 8 个 Omni/Spot 光（Compatibility）。
5. **官方免责声明**：系统要求一节明确说这些是"**simple 2D or 3D project**"的基线，"CPU/GPU/RAM 需求会随项目规模、渲染器、视口分辨率和图形设置**大幅变化**"，并"**强烈建议在低端硬件上自行测试**"。

### 4.2 目标场景的预算估算

假设场景：**16×16 = 256 格地形 + 20–40 个程序化图元角色 + 少量粒子 + 固定相机**。

| 元素 | 网格复杂度 | 数量 | 估算开销 | 置信度 |
|---|---|---|---|---|
| 地形 | 单块 `ArrayMesh` 或 `PlaneMesh` + 细分，或 256 个独立 `BoxMesh` | 1 或 256 | **强烈建议合并为 1–2 个 mesh**；256 个独立 MeshInstance3D 是最差做法 | 推测（工程常识） |
| 角色 | 每个用 Capsule/Box/Sphere 组合，约 4–6 个子网格，合计 300–800 三角面 | 20–40 | 100–300 个 draw call；Compatibility "基线成本低"，此量级无压力 | 推测 |
| 单位高亮/可移动格 | 半透明 plane/decal（**注意：Compatibility 不支持贴花**） | ≤ 50 | 用独立 quad 或用 terrain 顶点色 | 已证实（贴花不支持） |
| 粒子 | 单次命中特效 `GPUParticles3D` 或 `CPUParticles3D` | 1–3 个瞬时发射器 | 低 | 推测 |
| 阴影 | 1 个 DirectionalLight + 简单阴影 | 1 | Compatibility 阴影走 multi-pass，**建议只给 DirectionalLight 开阴影** | 推测 |
| 合计 | — | — | **推测：集显笔记本浏览器 60 FPS 可达；移动端 30 FPS 需降级** | **未证实** |

> **明确标注**：第 4.2 节的帧率结论为**推测**，依据是 Compatibility 渲染器的官方定位（低端/Web 目标）与最低 GPU 要求（Intel HD 2500 级），**但没有官方基准测试数据，我也未做真机实测**。必须在 v1 的第一个可玩版本上实测才能转为已证实。

### 4.3 降级手段（按性价比排序）

1. **锁 60 FPS 上限 + 降低渲染分辨率**（`viewport` 缩放），这是 Web 上最有效的单项手段。
2. **地形合并成 1 个 ArrayMesh**，格线用顶点色或 shader 画，避免 256 个 draw call。
3. **单位用 `MultiMesh` 做同材质批量绘制**（官方：MultiMeshInstance3D"以极低成本绘制数千次"，代价是每个 surface 只能一个材质）。
4. **取消实时阴影**，改用一个假阴影 quad（贴地椭圆平面），这是无美术资源下的标准技巧。
5. **MSAA 2x 而非 4x**（Compatibility 无 FXAA/TAA，MSAA 是唯一 AA 手段，开销随采样数上升）。
6. **关掉 Glow / SSAO**（战棋俯视固定相机下收益很低）。
7. **粒子改用 `CPUParticles3D` 或直接手写简单特效**，减少 GPU 侧不确定性。
8. **低端降级检测**：用 `OS.get_video_adapter_name()` / 帧率自适应，或用 `ResourceLoader` 的 feature tags 按平台给不同设置。

---

## 5. 存档：Web 导出下的落点与风险（硬需求）

### 5.1 `user://` 到底落在哪？（已证实）

官方 [File paths in Godot projects](https://docs.godotengine.org/en/stable/tutorials/io/data_paths.rst.txt) 原文：

> "On HTML5 exports, `user://` will refer to **a virtual filesystem stored on the device via IndexedDB**. (Interaction with the main filesystem can still be performed through the JavaScriptBridge singleton.)"

也就是说：

- `FileAccess.open("user://save_01.json", WRITE)` 这类代码**在 Web 下无需任何改动**即可工作；Godot 内部把 `user://` 映射到 IndexedDB 上的 Emscripten 虚拟文件系统。
- 数据不是"某个文件"，而是 **IndexedDB 里的一条记录**，归属于**页面所在 origin**。
- 想导出到真实磁盘，只能走 `JavaScriptBridge` 触发浏览器下载（见 §5.4）。

### 5.2 会不会丢？（官方明确列出的风险）

| 风险场景 | 是否丢档 | 官方依据 |
|---|---|---|
| 用户禁止 cookie / IndexedDB | **丢** | "Users must **allow cookies** (specifically IndexedDB) if persistence of the `user://` file system is desired." |
| 页面被 `iframe` 嵌入且第三方 cookie 被禁 | **丢** | "When playing a game presented in an `iframe`, **third-party** cookies must also be enabled." |
| 无痕 / 隐私浏览模式 | **丢** | "Incognito/private browsing mode also prevents persistence." |
| 用户清理浏览器站点数据 | **丢** | 数据属于 best-effort 存储，用户/浏览器可清除（见 §5.3） |
| 浏览器磁盘紧张 / 长期未访问导致驱逐 | **有风险** | 官方在 PWA 一节提到浏览器可能驱逐缓存数据 |
| 换设备 / 换浏览器 / 换域名 | **丢** | 数据按 origin 隔离，无云端同步 |
| `OS.is_userfs_persistent()` 判断 | **可能误报** | 官方原文："can give **false positives** in some cases" |

### 5.3 配额够不够？（对本项目而言：绰绰有余）

宇宙级结论：**战棋存档是几 KB 到几百 KB 的 JSON，任何浏览器配额都远远够用**。配额问题在本项目里**不是风险**，真正的风险是"**用户清数据**"。

| 浏览器 | best-effort 模式下单 origin 配额 | 来源 |
|---|---|---|
| Chromium 系（Chrome/Edge） | 最多 **磁盘总量的 60%**（1 TiB 磁盘 → 600 GiB） | [MDN: Storage quotas and eviction criteria](https://developer.mozilla.org/en-US/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria) |
| Firefox | 取"**磁盘 10%**"与"**10 GiB** 组限额"中的**较小者** | 同上 |
| Safari / WebKit | 按 origin 约为父级配额的 1/10；整体上限为**磁盘的 80%**（浏览器 App）/ 20%（非浏览器 App） | 同上 |
| 升级为 persistent | Chromium 系与 Safari **不会弹窗**，按用户互动历史自动批准或拒绝；Firefox 会弹窗请求 | 同上 |

- **建议**：v1 主动调用 `navigator.storage.persist()`（可通过 `JavaScriptBridge` 调用），能提升"不清除"的概率，但**不能保证**，且**不能作为唯一防线**。
- **必须的兜底**：**手动导出/导入存档字符串**（见 §5.4）。

### 5.4 `window.open` 与 `iframe` 嵌入的差异

| 项 | 独立窗口 / 新标签页打开 | `iframe` 嵌入（itch.io 等） |
|---|---|---|
| IndexedDB 归属 | 一级 origin，正常 | 仍是父页面的 iframe origin；若跨站则为**第三方存储** |
| 持久化前提 | 允许 cookie/IndexedDB | **额外需要允许第三方 cookie**（官方明文） |
| 数据存活率 | 较高 | **较低**（第三方存储被浏览器清理得更激进） |
| 后台暂停 | 标签页失焦即暂停；**独立窗口不受影响** | 同左 |
| 全屏/鼠标捕获 | 需在输入回调内触发 | 同左，且外层可能拦截 |
| 对存档的建议 | 主路径 | 必须提示用户"建议在新窗口打开以获得更可靠的存档" |

**导出/导入字符串方案的可行性与坑**：

| 环节 | 可行性 | 坑 |
|---|---|---|
| 生成字符串 | ✅ 用 `JSON.stringify` + `Marshalls.utf8_to_base64()`（或 `var_to_bytes` + base64） | 存档体积会膨胀约 33%（base64） |
| 复制到剪贴板 | ⚠️ 需要[安全上下文](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html)，官方明说"由于 API 异步，从 GDScript 访问**可能不可靠**" | **不要依赖剪贴板作为主通道** |
| 更稳的做法 | 用 `JavaScriptBridge` 调 `navigator.clipboard.writeText()`，或退化为"把 base64 显示在一个可全选的 `TextEdit` 里，让用户手动 Ctrl+C" | 后者 100% 可用，零依赖 |
| 下载为文件 | ✅ `JavaScriptBridge` 生成 Blob + `<a download>` | 需要写一小段 JS |
| 导入 | ✅ `TextEdit` 粘贴 + base64 解码 + JSON 解析 + 校验 | 必须做**校验与版本号检查**，防手改/截断 |
| 校验和 | 建议加 CRC32 或简单 SHA-256 前缀 | 防止"复制少了几行"导致静默损坏 |

### 5.5 存档结构建议（JSON + 版本迁移）

```
user://saves/slot_01.json      # 单槽存档（JSON，人类可读）
user://saves/meta.json         # 槽位索引/缩略信息（避免加载全档）
user://settings.cfg            # ConfigFile 存设置（与存档分离）
```

```json
{
  "save_version": 3,
  "engine_version": "4.7.2",
  "created_at": "2026-09-30T18:43:08+08:00",
  "rng_seed": 123456789,
  "rng_state": "...",
  "campaign": { "...": "RPG 侧数据" },
  "battle": {
    "grid": { "w": 16, "h": 16, "tiles": [0,0,1] },
    "turn": 4,
    "phase": "player",
    "units": [
      { "id": "u1", "side": 0, "pos": [3,4],
        "str": 12, "armor": 5, "phys_res": 0.25, "mag_res": 0.1,
        "energy": 2, "energy_max": 3, "break_damage": 4,
        "rest_str": 2, "rest_armor": 1,
        "kills": 3, "level": 2, "pending_points": 0,
        "attack_kind": "melee", "range": 1 }
    ],
    "log": [ "..." ]
  }
}
```

**必做的四件事**：
1. **`save_version` 整数**，读取时按版本走 `_migrate_v1_to_v2()` 之类的升级函数链。
2. **写入用"临时文件 + 重命名"**（`user://save.tmp` → `user://save.json`），防写入中途关页面导致半个文件。
3. **读档失败必须可恢复**：解析失败 → 保留坏档副本 + 提示 + 回退到上一槽。
4. **不要用 `ResourceSaver` 存 `.tres`/`.res` 作为存档**——二进制/资源格式跨版本兼容性差，且 Web 下不便人工排查；**用 JSON**。

---

## 6. 无美术资源下的程序化表现手段清单

### 6.1 内置图元网格（全部已证实存在）

官方 class reference 页面均返回 200：[BoxMesh](https://docs.godotengine.org/en/stable/classes/class_boxmesh.html)、[SphereMesh](https://docs.godotengine.org/en/stable/classes/class_spheremesh.html)、[CapsuleMesh](https://docs.godotengine.org/en/stable/classes/class_capsulemesh.html)、[CylinderMesh](https://docs.godotengine.org/en/stable/classes/class_cylindermesh.html)、[PrismMesh](https://docs.godotengine.org/en/stable/classes/class_prismmesh.html)、[PlaneMesh](https://docs.godotengine.org/en/stable/classes/class_planemesh.html)、[TorusMesh](https://docs.godotengine.org/en/stable/classes/class_torusmesh.html)。

**角色设计（零美术）**：`CapsuleMesh` 身体 + `SphereMesh` 头 + `PrismMesh` 朝向楔形 + 阵营色 `StandardMaterial3D`。朝向楔形是关键——没有它玩家分不清单位面朝哪边。

### 6.2 程序化几何生成

来源：[Procedural geometry](https://docs.godotengine.org/en/stable/tutorials/3d/procedural_geometry/index.html)

- **`ArrayMesh`**：直接构造 surface 数组，适合一次性生成地形/网格，性能最好。
- **`SurfaceTool`**：类立即模式 API，有 `generate_normals()` / `index()` 等便利方法，比 ArrayMesh 稍慢但更好写。**推荐用于地形生成**。
- **`ImmediateMesh`**：每帧可变几何，适合可视化调试（如射线），每帧重建所以慢。
- **`MeshDataTool`**：能访问边/面，慢，只在需要拓扑算法时用。
- **官方明确限制**："所有程序化几何生成方法都在 **CPU** 上运行。Godot 尚不支持在 GPU 上生成几何。"
- **`MultiMesh` / `MultiMeshInstance3D`**：硬件实例化，能"以极低成本绘制数千次"，但**每个 surface 只能用同一个材质**。

### 6.3 动画

| 手段 | 适用 | 官方文档 | 工作量 |
|---|---|---|---|
| `Tween` | **运行时生成的一次性动画**（移动、跳跃、抖动、伤害数字飘字） | [class_tween](https://docs.godotengine.org/en/stable/classes/class_tween.html) | 1（最低） |
| `AnimationPlayer` | 需要编辑器里编排的固定动作片段 | [class_animationplayer](https://docs.godotengine.org/en/stable/classes/class_animationplayer.html) | 2 |
| `AnimationTree` | 状态机混合（本项目 v1 不需要） | — | 4 |
| 代码手写 `_process` 插值 | 弹道轨迹等需要精确控制的场合 | — | 2 |

**结论**：v1 **只用 `Tween` + 少量手写插值**就够。`Tween` 对"运行时才产生的动画"是最省事的方案（不需要预先做动画资源）。

### 6.4 卡通描边（关键技巧，已证实）

官方 [BaseMaterial3D](https://docs.godotengine.org/en/stable/classes/class_basematerial3d.html) 有：

- `bool grow = false` — 官方原文：*"If true, enables the vertex grow setting. This can be used to **create mesh-based outlines using a second material pass**..."*
- `float grow_amount = 0.0` — 沿法线外扩的像素量。

**做法（反转外壳 / inverted hull）**：
1. 主材质：正常平涂颜色（`shading_mode = unshaded` 可获得纯净卡通色）。
2. `next_pass` 放第二个材质：`cull_mode = front`（只渲染背面）+ `grow = true`、`grow_amount` 取 2–4 + 纯黑 `albedo`。
3. 结果：一圈黑色描边，**零美术资源、零后处理开销**。

**备选**：后处理描边。Compatibility 渲染器**支持** `screen texture` 与 `depth texture`（官方能力表），也支持"fullscreen quad 自定义后处理"，但**不支持 CompositorEffects**。所以后处理描边必须自己搭 fullscreen quad，成本高于反转外壳。

**标注**：`grow` 属性本身**已证实**（官方 class ref 原文）；但"在 Web/Compatibility 下 `grow` 的视觉效果与原生一致"这一点我**未实测**，标为**推测**。

### 6.5 粒子

| 节点 | 官方定位 | Web/Compatibility 取舍 |
|---|---|---|
| `GPUParticles3D` | GPU 驱动，粒子量大时性能好 | 受"无计算着色器"限制；简单场景仍可用 |
| `CPUParticles3D` | CPU 驱动，兼容性最好 | **Web 上更保险**；战棋特效粒子量小，CPU 完全够 |

官方 [particles 索引](https://docs.godotengine.org/en/stable/tutorials/3d/particles/index.html) 可查。**注意**：Compatibility **不支持粒子拖尾**与粒子 SDF 碰撞。

### 6.6 伤害数字与相机抖动

| 表现 | 实现 | 开销 | 工作量 |
|---|---|---|---|
| 伤害数字 | `Label3D`（World 空间）或用 `Sprite3D` + 代码生成的 `ImageTexture`；配合 `Tween` 上飘 + 淡出 | 极低 | 1 |
| 命中闪白 | `StandardMaterial3D.albedo_color` 用 `Tween` 打一下 | 极低 | 1 |
| 相机抖动 | `Tween` 或手写 `Camera3D.h_offset/v_offset` 衰减 | 极低 | 1 |
| 攻击位移 | `Tween` 移动 + 回位（近战"顶一下"） | 极低 | 1 |
| 弹道轨迹 | 采样点 + `ImmediateMesh` 画线，或按帧摆放小 `SphereMesh`；**抛物线本身是纯数学，与渲染无关** | 低 | 2 |
| 落地判定圈 | 一个半透明 `PlaneMesh` 圆环，随力度缩放 | 低 | 2 |
| 瞄准输入（力度条 + 角度） | 自绘：鼠标拖拽 → 方向 + 力度；**官方明确要求全屏/捕获类操作必须在输入回调内** | 中 | 3 |

### 6.7 我判断**最划算的 3 项**（按性价比）

1. **`grow` + `next_pass` 反转外壳描边** —— 一份材质配置换来全场景黑色描边，把"无贴图的纯色块"从"原型感"拉升到"风格化卡通"，且**零后处理、零美术资源、零额外 draw call 预算压力**（就多一个 pass）。
2. **`Tween` 驱动的程序化动作三件套（位移顶一下 + 闪白 + 伤害数字上飘）** —— 三者合计约 1–2 天工作量，却能提供回合制战棋**最主要的打击感**。回合制的"爽感"几乎全部来自这三件事，而不是模型精度。
3. **`SurfaceTool` 生成单块地形 ArrayMesh + 顶点色格线** —— 一次性解决"地面 + 网格线 + 可移动范围高亮"三件事，把 256 个 draw call 压到 1 个，同时避免使用 Compatibility **不支持**的贴花（Decal）来做格子高亮。

> 第 4 名（备选）：**固定相机的正交/微透视 + 假阴影椭圆**。俯视固定相机是战棋的天然优势，可以大幅削减阴影与 LOD 的复杂度。

---

## 7. 备选架构六维对比

**打分口径**：1 = 最差，5 = 最好；均为**针对本项目约束**（无美术资源 / 战棋子模块 / 需存档 / 中文用户）的相对评分，不是绝对能力评分。

| 维度 | Godot 4.7（原生 + Web） | 纯 Web（Three.js / Babylon.js + TS） | Godot 4.7（仅桌面原生） |
|---|---|---|---|
| **无美术资源适配度** | **5** — 内置图元、`grow` 描边、粒子、UI 全内置，零外部资源即可出风格化画面 | **3** — 图元要靠 `BoxGeometry` 等自建，描边/粒子/UI 都要自己拼或引库；但 DOM UI 反而最好写 | **5** — 同左，且不受 Web 限制 |
| **确定性战斗逻辑可测试性** | **4** — 逻辑可用纯 GDScript 类写；`--headless --script` 可跑；GUT / gdUnit4 可用。但 GDScript 的单测生态弱于 JS/TS | **5** — 逻辑层是纯 TS，`Vitest` 直跑，CI 零成本，这是最强项 | **4** — 同 Godot |
| **导出与分发** | **4** — 一次开发同时出 Windows 原生 + Web；但 Web 包 20–45 MB、需 HTTPS、存档受浏览器制约 | **5** — 就是一个静态站点，GitHub Pages/Vercel 秒发，无 1 GB 工具链 | **3** — 只能出原生，用户要下载安装包；无"发个链接就能玩" |
| **2.5D 表现力** | **5** — 真 3D、真相机、真光照、内置描边与粒子，2.5D 是降维使用 | **4** — 能力不差（Three.js 有 `Raycaster`、后处理、描边），但一切要自建 | **5** — 同左 |
| **开发速度（v1 从零到可玩）** | **4** — 场景/UI/输入/存档/音频全内置，省掉最多基础工程 | **2** — 需要自建渲染层、拾取、动画、UI、存档、构建链；见 §8 代价清单 | **4** — 同左，且省掉 Web 内存/存档适配 |
| **长期 RPG 扩展** | **5** — 引擎自带场景系统、资源管线、UI、音频、动画、后续可加 2D 地图/对话系统 | **3** — 每加一个 RPG 子系统都要自研或找库，长期维护面扩大 | **5** — 同左 |
| **合计** | **27 / 30** | **22 / 30** | **26 / 30** |
| **一票否决项** | **iOS Safari 内存（默认 2 GB 上限）+ 首屏体积**。若目标用户大量用 iPhone 浏览器直接玩，可能被否 | **需要自建整套引擎层**。若团队只有 1 人且要 v1 快速完整交付，这是实质性否决 | **无法"发链接就能玩"**。若分发形态必须是网页，直接否 |

**补充事实（已实测）**：
- Three.js 当前版本 **r186 / npm 0.186.1**（2026-09-24 发布），核心包 min **719 KB / gzip 180.6 KB**，零依赖 → [three.js releases](https://github.com/mrdoob/three.js/releases)、[three.js docs](https://threejs.org/docs/)。
- Babylon.js 当前版本 **9.28.0**（2026-09-24 发布），`@babylonjs/core` 整包 min **7847 KB / gzip 1738.7 KB**（未 tree-shake，实际按需引入会小很多）→ [babylonjs.com docs](https://doc.babylonjs.com/)。
- 构建链可用：**Vite 8.3.1**、**Vitest 5.0.2**（npm registry 实测）。

> 值得注意：**Three.js 的 gzip 体积（180 KB）比 Godot Web 包（推测 7–15 MB）小两个数量级**。这是纯 Web 路线唯一的"碾压级"优势，也是"用户不想下载 1 GB 工具链"这一顾虑的真实价值所在。

---

## 8. 若 Godot 路线被否：纯 Web 路线代价清单

> 本节为 lead 明确要求的补充。结论：**纯 Web 可行，但要把 Godot 免费提供的东西全部自建**。

### 8.1 必须自建的能力清单

| 能力 | Godot 自带 | 纯 Web 需要做什么 | 额外工作量 |
|---|---|---|---|
| 渲染循环 / 相机 | `Camera3D` + 自动渲染 | `WebGLRenderer` + 相机 + resize + 帧循环 | 小（1–2 天） |
| 网格与地形 | `BoxMesh`/`PlaneMesh` 等 + `SurfaceTool` | `BufferGeometry` / `PlaneGeometry` 手工拼顶点；网格线用 `LineSegments` 或自定义 shader | 小–中（2–4 天） |
| 角色组装 | 场景树 + `Node3D` 层级 | `Group`/`Object3D` 层级，自己写"单位工厂" | 小（1–2 天） |
| 拾取（点格子/点单位） | `Area3D` / 物理射线 | `Raycaster` + 地面平面求交 + 网格坐标换算（**必须自己处理坐标系**） | 中（2–4 天） |
| 动画 | `Tween` / `AnimationPlayer` | 引 `@tweenjs/tween.js` 或手写 `lerp` 调度器 | 小–中（2–3 天） |
| 卡通描边 | `BaseMaterial3D.grow` + `next_pass` 一行配置 | 反转外壳 shader 手写，或引 `OutlineEffect`/`OutlinePass`（后处理，开销更大） | 中（2–4 天） |
| 粒子 | `GPUParticles3D` / `CPUParticles3D` | `Points` 或实例化 quad + 自写生命周期 | 中（2–5 天） |
| 伤害数字 / 世界空间文字 | `Label3D` | `CSS2DRenderer` 或 canvas 贴图 `Sprite` | 小（1–2 天） |
| UI（角色面板、升级三选一、瞄准条） | 完整 `Control` 体系 + 主题 | **DOM/React 反而更强**：直接用 HTML+CSS，无需引擎 UI | **更省** |
| 输入（含拖拽瞄准） | `Input` + 信号 | 原生 pointer 事件（**也更省**） | **更省** |
| 存档 | `FileAccess` + `user://` 自动映射 IndexedDB | 直接写 `localStorage`/`IndexedDB`（**也更省，且更透明**） | **更省** |
| 音频 | 音频总线 + 播放器 | `WebAudio` 或 `<audio>` | 小（1–2 天） |
| 场景管理 / 状态机 | `SceneTree` + `change_scene` | 自己写状态机/路由 | 小–中（1–3 天） |
| 构建与发布 | 编辑器一键导出 | Vite 构建（**很简单**） | **更省** |
| **确定性战斗逻辑** | GDScript 纯类 | **纯 TS 模块（两边做法几乎一样）** | **持平** |
| **单元测试** | GUT / gdUnit4（生态较弱） | **Vitest，零成本，最强** | **更省** |

### 8.2 净代价估算

| 项 | 估算 |
|---|---|
| 需要额外自建的"引擎层" | **约 15–25 人天**（渲染/拾取/动画/描边/粒子/状态机） |
| 相对更省的部分 | 约 **5–8 人天**（UI、输入、存档、构建、测试） |
| **净额外成本** | **约 8–18 人天**（**估算，非实测**） |
| 换来什么 | 首屏从"推测 7–15 MB gzip"降到 **180 KB + 业务代码**；无 1.2 GB 工具链；无 COOP/COEP 与 wasm 内存问题；测试与 CI 最顺 |
| 代价 | v1 交付时间被拉长；长期每加一个 RPG 子系统都要自研；**没有编辑器**意味着所有美术摆放都靠代码 |

### 8.3 一条折中路线（供 lead 参考）

**逻辑层语言中立，表现层后置决策**：
1. 先把**战斗规则层**写成**纯函数 + 纯数据**（无论最终选哪条路，这部分都完全复用）。
2. 规则层用 **TypeScript + Vitest** 先写先测（本机 Node 22.13 已就绪，**零安装成本**），把伤害公式、命中概率、精力、升级、行动合法性全部锁死。
3. 表现层在规则层稳定后再二选一：Godot（图元+Tween+描边，快）或 Three.js（体积小、无工具链）。
4. 这样"要不要下载 1.2 GB 工具链"这个决策**可以被推迟到规则层完成之后**，且不会返工。

> 这条折中路线是本节最实际的产出：它把架构决策的风险从"选错了要重写"降到"选错了只重写表现层"。

---

## 9. 环境准备步骤（Windows）

### 9.1 获取 Godot 4.7.2 + Web 导出模板（可执行步骤）

本机现状（**实测**）：`node v22.13.0`（D:\NODEJS）、`python 3.13.1`（C:\Python313）、`git 2.45.1.windows.1`（D:\Git）；**`godot` 不在 PATH，未安装**。

```powershell
# 1) 下载编辑器（约 82 MB）——官方直链
#    https://downloads.godotengine.org/?version=4.7.2&flavor=stable&slug=win64.exe.zip&platform=windows.64
# 2) 下载导出模板（约 1.19 GiB）——官方直链
#    https://downloads.godotengine.org/?version=4.7.2&flavor=stable&slug=export_templates.tpz&platform=templates
# 3) 解压编辑器 zip 到任意目录（Godot 是绿色免安装软件，解压即用）
# 4) 启动 Godot_v4.7.2-stable_win64.exe → 编辑器菜单 Editor > Manage Export Templates > Install from File
#    选择下载好的 export_templates.tpz 完成安装
# 5) 项目 > 导出 > 添加 "Web" 预设：
#      - Use Threads        = 关闭（默认，避免 COOP/COEP）
#      - Progressive Web App = 按需（开启可离线缓存 + 兜底跨源隔离头）
#      - Extensions Support  = 关闭（不需要 GDExtension；开启会要求跨源隔离）
# 6) 本地验证：把导出产物放到一个目录，用官方脚本起服务
#    python serve.py --root .
```

模板安装目录（官方 [File paths](https://docs.godotengine.org/en/stable/tutorials/io/data_paths.rst.txt)）：编辑器数据在 `%APPDATA%\Godot\`，导出模板即存放在该目录下。

**若只想快速试水**：先用 [官方 Web 编辑器 4.7.2](https://editor.godotengine.org/releases/4.7.2.stable/godot.editor.html) 在浏览器里验证引擎行为，**零下载**，但**不能导出 Web 包**（Web 编辑器不能导出 Web）。

### 9.2 无 Godot 时的替代验证路径（重要）

**核心洞察**：本项目的战斗规则是**纯数学**，与引擎完全解耦。因此可以在**不安装 Godot**的前提下，先把规则层验证到位。

| 阶段 | 做法 | 本机可行性 |
|---|---|---|
| **A. 规则层先行（推荐）** | 用 **TypeScript 或 Python** 实现伤害/命中/精力/升级/行动合法性，写成纯函数 + 表驱动数据，用 **Vitest**（或 Python `unittest`）覆盖边界用例 | ✅ Node 22.13 / Python 3.13 已就绪，**零安装** |
| **B. 弹道数学校验** | 抛物线用纯函数模拟（给定角度 θ、力度 v、重力 g → 落地格与判定圈），单元测试覆盖"命中但伤害为 0""未命中"等分支 | ✅ 同上 |
| **C. 规则层 CLI 试玩** | 用 Node/Python 写一个**命令行版战棋**（ASCII 网格），验证回合流程、升级、存档 JSON 往返 | ✅ 命令行架构的最小验证 |
| **D. 移植到 GDScript** | 规则层逻辑 1:1 翻译（GDScript 与 Python/TS 语法接近），用 **GUT** 或 **gdUnit4** 重跑同一批用例 | 需先装 Godot |
| **E. Godot 侧自动化** | `godot --headless --path <项目> --script <脚本>`；`--headless` 官方定位为"Enable headless mode，**Useful for servers and with `--script`**"；另有 `--check-only`（只做语法检查后退出） | 需先装 Godot |
| **F. Web 包导出（无需 GUI）** | `godot --headless --path <项目> --export-release <预设名> <输出路径>` | 需先装 Godot |

**测试框架现状（实测仓库数据）**：
- [bitwes/Gut](https://github.com/bitwes/Gut) — Godot Unit Test，2742 stars，最近推送 2026-08-18。
- [MikeSchulze/gdUnit4](https://github.com/MikeSchulze/gdUnit4) — Godot 4 单元测试框架，支持 GDScript 与 C#，1244 stars，最近推送 2026-08-30。

**建议**：**先做 A–C**。这三步不需要任何 Godot 下载，就能把需求文档里最容易出错的伤害公式、命中概率（1% 精度）、精力记账、升级树全部钉死；等规则稳定后再决定表现层用 Godot 还是 Three.js（见 §8.3）。

---

## 10. 风险清单

> 「v1 前决策」= 是否必须在第一个版本动工前定下来。

| ID | 风险 | 触发条件 | 影响 | 缓解措施 | v1 前决策 |
|---|---|---|---|---|---|
| **R1** | **iOS Safari 内存 OOM** | WebAssembly `Memory` 初始化时 `maximum` 过大；官方 issue [#70621](https://github.com/godotengine/godot/issues/70621) 报告：Godot 默认 `WASM_MEM_MAX=2048MB`，在 iOS 16.2 Safari 上直接 OOM；把 `WASM_MEM_MAX` 改到 256MB 后消失。该 issue **至今 open**（最后更新 2026-06-01） | iPhone/iPad 用户**完全打不开游戏** | ① v1 明确**不支持 iOS Safari 直接游玩**，或②编译降低 `WASM_MEM_MAX` 的自定义 Web 模板，或③引导用户改用 Chrome/Firefox | **是** |
| **R2** | **wasm 32 位内存天花板** | WebAssembly 页面大小固定 64 KiB（[官方规范](https://webassembly.github.io/spec/core/exec/runtime.html)），32 位寻址的理论上限为 4 GiB；Godot 官方 Web 导出最低要求桌面 **4 GB RAM** | 资源多起来后**单靠堆内存无法扩展**，且移动端远低于此 | 严格限制常驻资源；纹理走压缩；场景资源按需 `load`/`free`；**不要把大表一次性加载进内存** | **是**（定资源预算） |
| **R3** | **首屏体积过大** | 官方 4.2 时代数据："default official Godot build exports a web application **around 40Mb**"（[MinimalWebBuild README](https://github.com/Charles-Zhang-Godot/MinimalWebBuild)）；4.0 beta 期 issue [#68647](https://github.com/godotengine/godot/issues/68647) 报告空场景导出 **>40 MB**。4.7.2 的准确数字**未实测** | 移动网络下加载 10–30 秒，用户流失 | ①服务端 gzip/brotli（.wasm 可压到约 1/4）；②**编译裁剪过的自定义 Web 导出模板**（官方 [Optimizing a build for size](https://docs.godotengine.org/en/stable/engine_details/development/compiling/optimizing_for_size.html)：MinimalWebBuild 把 web 模板从 45 MB 降到 **25.63 MB**）；③itch.io 必须**预压缩**；④加 loading 进度条 | **是** |
| **R4** | **存档丢失（清站点数据）** | 用户清理浏览器数据 / 使用无痕模式 / 浏览器磁盘紧张驱逐 / 换设备 | 用户进度**永久丢失**，中文 RPG 用户对此容忍度极低 | ①`navigator.storage.persist()`；②**必备的存档导出/导入字符串**（base64 + 校验和）；③在 UI 上明确提示"存档在浏览器里，请定期导出"；④写入用 tmp+rename 防半档 | **是（硬需求）** |
| **R5** | **iframe 嵌入导致第三方存储被清** | 游戏被 itch.io 等以 `iframe` 嵌入，且用户浏览器禁用第三方 cookie | 官方明文：iframe 中**必须允许第三方 cookie** 才能持久化 | ①检测不可持久化时**显式告警**；②引导"在新窗口打开"；③导出/导入兜底 | **是** |
| **R6** | **默认 2 GB 内存 + 规范默认单线程** | 单线程路线下无法用 `Thread`，物理/资源加载全在主线程 | 加载卡顿、帧率抖动 | 本项目的逻辑量极小，**单线程够用**；加载分批 + 进度条 | 否（架构已规避） |
| **R7** | **Compatibility 渲染器画质上限** | 试图使用 TAA/FXAA/SSAO 之外的高级特性（体积雾、SSR、SDFGI、贴花、粒子拖尾、景深、计算着色器） | 效果做不出来，返工 | **v1 画质方案按 §3 能力表设计**：MSAA/SSAA 抗锯齿、`grow` 描边、Glow 可选、假阴影、无贴花（用 quad 替代） | **是**（定画质基线） |
| **R8** | **Safari WebGL 2.0 兼容问题** | 官方原文：Safari 有一些其他浏览器没有的 WebGL 2.0 问题，建议用 Chromium 或 Firefox | macOS Safari / iOS Safari 用户画面异常 | ①显式做浏览器检测与提示；②把 Safari 列为首要真机测试目标；③与 R1 合并处理 iOS | **是** |
| **R9** | **GitHub Pages 无法设置自定义响应头** | 若将来开启 *Use Threads* 或 *Extensions Support* | 部署在 GitHub Pages 上**直接跑不起来** | 锁定单线程；如需线程则开 PWA 让 service worker 兜底，或换托管（Cloudflare Pages / Netlify 支持自定义头） | 否（单线程已规避） |
| **R10** | **工具链体积（1.19 GiB 模板）** | 用户/协作者需要下载 82 MB 编辑器 + 1.19 GiB 模板 | 环境搭建摩擦大，协作成本高 | ①**先走 §9.2 的"无 Godot 规则层验证"**；②模板只需装一次；③若体积成为否决因素，转 §8 纯 Web 路线 | **是**（与 §7 一票否决项绑定） |
| **R11** | **弹道"无辅助瞄准 UI"的可玩性** | 需求明确"玩家输入瞄准的方向和力度，没有辅助瞄准等 UI" | 3D 视角下**判断抛物线落点极难**，玩家体验差 | ①给"无辅助"但**有反馈**：力度条 + 预估落点圈（仅显示范围不显示命中）；②固定相机角度降低 3D 判断难度；③v1 先用简化输入（角度滑条 + 力度滑条）而非自由拖拽 | **是** |
| **R12** | **Web 音频能力缺失** | 默认 Sample 模式：**不支持 AudioEffects、混响、多普勒、程序化音频**；Stream 模式延迟高 | 技能音效无法做后期处理 | v1 只用简单采样音；效果音走音量/音高包络；**不做混响** | **是**（定音频方案） |
| **R13** | **Godot 版本升级破坏性变更** | 每个 minor 版本都有 breaking changes（官方有 [4.6→4.7 迁移文档](https://docs.godotengine.org/en/stable/tutorials/migrating/upgrading_to_godot_4.7.html)） | v1 后升级引擎可能引发连锁修复 | ①锁定 **4.7.2** 并把版本写进项目 README；②`save_version` 存档版本号与引擎版本解耦；③升级前先跑规则层回归用例 | 否（锁定即可） |
| **R14** | **一键部署的 service worker 旧缓存** | 官方 troubleshooting：多个项目用一键部署时会看到旧项目；service worker 缓存缺少自动失效机制 | 测试时"改了没生效"，误判为 bug | 测试时用 DevTools 的 Application 面板 Unregister service worker 并勾选 Update on reload | 否 |

**风险 Top 5（按"必须先处理"排序）**：**R1（iOS OOM）> R4（清数据丢档）> R3（首屏体积）> R7（画质基线）> R11（无辅助瞄准可玩性）**。

---

## 11. 建议的最小落地路径（供 lead 决策参考，非结论）

| 步骤 | 产出 | 是否需要 Godot | 验收标准 |
|---|---|---|---|
| S0 | 用 TS/Python 写**规则层纯函数** + 单测（伤害公式、1% 命中、精力、升级、行动合法性） | ❌ 不需要 | 边界用例全绿：计算值 ≥1 / 0<x<1 / <0 / 精力加成后跨档 |
| S1 | **命令行 ASCII 战棋**跑通完整回合流程 + JSON 存档往返 | ❌ 不需要 | 能完整打完一局并读档还原 |
| S2 | 决策：Godot 表现层 vs Three.js 表现层（此时规则层已可复用） | — | — |
| S3 | 表现层最小可玩：单块地形 ArrayMesh + 图元角色 + `grow` 描边 + Tween 三件套 | ✅ | 集显笔记本浏览器 60 FPS（实测确认） |
| S4 | 存档：`user://` JSON + 版本迁移 + 导出/导入字符串 + 持久化检测告警 | ✅ | 清站点数据后能靠字符串恢复 |
| S5 | 弹道：方向+力度输入、抛物线、落地判定圈 | ✅ | 无辅助瞄准下可玩（需真人试玩验证） |
| S6 | Web 导出 + 真机验证（Chrome/Firefox/Safari/移动端各一次） | ✅ | 记录各浏览器实际帧率与内存 |

**S0/S1 是本文最重要的建议**：它们把"是否下载 1.19 GiB 工具链"这个决策**推迟**到规则层已被验证之后，从而把这个选择的风险降到最低。

---

## 12. 证据索引与未证实项清单

### 12.1 主要证据来源

- [Godot 版本清单（官方 versions.json）](https://godotengine.org/versions.json)
- [Godot Windows 官方下载页](https://godotengine.org/download/windows/)
- [Exporting for the Web（官方文档）](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html)
- [Overview of renderers（官方文档）](https://docs.godotengine.org/en/stable/tutorials/rendering/renderers.html)
- [File paths in Godot projects（官方文档，`user://` / IndexedDB）](https://docs.godotengine.org/en/stable/tutorials/io/data_paths.rst.txt)
- [System requirements（官方文档，Web 最低 4 GB RAM）](https://docs.godotengine.org/en/stable/about/system_requirements.rst.txt)
- [Procedural geometry（官方文档）](https://docs.godotengine.org/en/stable/tutorials/3d/procedural_geometry/index.html)
- [Optimizing a build for size（官方文档）](https://docs.godotengine.org/en/stable/engine_details/development/compiling/optimizing_for_size.html)
- [Command line tutorial（官方文档，`--headless` / `--script` / `--export-release`）](https://docs.godotengine.org/en/stable/tutorials/editor/command_line_tutorial.html)
- [BaseMaterial3D 类参考（`grow` / `grow_amount`）](https://docs.godotengine.org/en/stable/classes/class_basematerial3d.html)
- [godotengine/godot issue #70621 — iOS Safari WebAssembly 2 GB OOM](https://github.com/godotengine/godot/issues/70621)
- [godotengine/godot issue #104422 — 默认 Web 构建 400MB 堆](https://github.com/godotengine/godot/issues/104422)
- [godotengine/godot issue #68647 — 空项目 Web 导出 >40MB](https://github.com/godotengine/godot/issues/68647)
- [Charles-Zhang-Godot/MinimalWebBuild — 极简 Web 构建实测体积表](https://github.com/Charles-Zhang-Godot/MinimalWebBuild)
- [MDN — Storage quotas and eviction criteria](https://developer.mozilla.org/en-US/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria)
- [itch.io — Uploading HTML5 games](https://itch.io/docs/creators/html5)
- [GitHub community discussion #13309 — Allow setting COOP and COEP headers in GitHub Pages](https://github.com/orgs/community/discussions/13309)
- [WebAssembly 官方规范 — Runtime structure（页面大小 65536 字节）](https://webassembly.github.io/spec/core/exec/runtime.html)
- [three.js 官方文档](https://threejs.org/docs/) / [releases](https://github.com/mrdoob/three.js/releases)、[Babylon.js 官方文档](https://doc.babylonjs.com/)
- [bitwes/Gut](https://github.com/bitwes/Gut)、[MikeSchulze/gdUnit4](https://github.com/MikeSchulze/gdUnit4)

### 12.2 已实测（本机命令产生，非引用）

| 项 | 结果 |
|---|---|
| Godot 4.7.2 Windows 编辑器 zip | 86,013,866 字节 ≈ 82.0 MiB |
| Godot 4.7.2 `export_templates.tpz` | 1,281,349,702 字节 ≈ 1222 MiB ≈ 1.19 GiB |
| 单平台 Web 模板 slug | `web_release.zip` / `web_nothreads_release.zip` 等均 **404**（官方不提供单平台直链） |
| 图元网格类参考页 | `class_boxmesh` / `spheremesh` / `capsulemesh` / `cylindermesh` / `prismmesh` / `planemesh` / `torusmesh` 全部 **HTTP 200** |
| `BaseMaterial3D.grow` / `grow_amount` | 官方 class ref 中存在，且原文提到可用于"second material pass"做 mesh-based outlines |
| Three.js | r186 / npm `0.186.1`，2026-09-24；min 719 KB / gzip 180.6 KB，零依赖 |
| Babylon.js | `9.28.0`，2026-09-24；`@babylonjs/core` min 7847 KB / gzip 1738.7 KB（整包） |
| Vite / Vitest | 8.3.1 / 5.0.2 |
| 本机环境 | Node **v22.13.0**、Python **3.13.1**、git **2.45.1.windows.1**；**Godot 未安装（不在 PATH）** |

### 12.3 明确标注「未证实 / 推测」的条目

| 条目 | 状态 |
|---|---|
| Godot 4.7.2 空项目 Web 导出的**实际传输体积**（推测 20–45 MB 原始 / 7–15 MB gzip） | **推测**：依据为 4.2 时代"约 40 MB"、4.0 beta">40 MB"，**不是 4.7.2 实测** |
| 集显笔记本浏览器 **60 FPS 可达** | **未证实**：依据是 Compatibility 渲染器的官方定位与最低 GPU 门槛（Intel HD 2500 级），**无官方基准，我未真机实测** |
| `grow` 描边在 **Web/Compatibility** 下的视觉效果与原生一致 | **推测**：属性存在已证实，但跨渲染器表现未实测 |
| GitHub Pages **无法**设置自定义响应头 | **部分证实**：依据社区需求讨论与官方文档空白，**未见官方明文"不支持"** |
| 纯 Web 路线**净额外成本 8–18 人天** | **估算**，非实测 |
| itch.io 官方 HTML5 文档的**具体条款内容** | **部分证实**：官方页面存在且被官方 Godot 文档引用，但**我本次未能直接抓取其正文**（网络受限），只确认了 URL 与"itch.io 不提供即时压缩"这一条（来自 Godot 官方文档） |
| Godot 4.8 是否改善 Web 内存/体积问题 | **未证实**：4.8 仍处于 dev7（2026-09-29），无可引用的正式说明 |

---

## 13. 给 lead 的三句总结

1. **可行性结论**：Godot 4.7.2 + Compatibility + 单线程 Web 导出，在"无美术资源 + 2.5D + 含存档"的约束下**技术可行**，六维打分 **27/30** 领先；核心代价是 **1.19 GiB 工具链**与**20–45 MB 首屏**。
2. **必须在 v1 前拍板的五件事**：iOS Safari 是否支持（R1）、存档导出/导入兜底（R4）、首屏体积预算与自定义模板（R3）、画质基线按 Compatibility 能力表锁定（R7）、弹道"无辅助瞄准"的输入形态（R11）。
3. **最低风险路径**：**先用 Node/Python 把规则层写成纯函数并单测、再写一个命令行版跑通存档**（§9.2 S0–S1，零 Godot 依赖），把架构决策推迟到规则层验证之后——这样无论最终选 Godot 还是 Three.js，都不会返工。
