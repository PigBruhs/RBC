# 关卡与胜负条件（场景元数据）

> 用户口径（第 97 轮）：**胜负条件写进场景元数据，不同场景的胜负条件相互独立。**
> 本文是这套机制的契约与扩展指南。加**场景**、加**胜负玩法**都只改数据 + 一处纯函数，
> 不需要在场景代码里写 `if`。

---

## 1. 关卡元数据在哪

全部在 `game/src/core/level.gd` 的 `Level.DEFS` 字典里，一个场景一条。现有两个场景：

| id | 名字 | 可行动区域 | 物理边界 | 相机 yaw |
|---|---|---|---|---|
| `field` | 测试场 48×48 | 48×48（= 整张图） | 48×48 | 225° |
| `arena` | 皇室竞技场 21×41 | 21×41 @ (0,0) | **100×100**（四周是"空场"） | 225° |

一条场景声明的字段（`game/src/core/level.gd`）：

| 键 | 含义 |
|---|---|
| `name` | 显示名 |
| `gw` / `gh` | **物理边界**（炮弹能飞到哪） |
| `play` | **可行动区域** `[x0, y0, w, h]`：有格子、能走、能放、画地形；外面是空场 |
| `cam_yaw` | 相机偏航（`Level.cam_center()` 取可行动区域中心，所以扩空场相机不动） |
| `player` / `enemy` | 每边的 `{king, forward, lateral}` —— 公主格、英雄出生格都从它推 |
| `dummies` | 假人靶子格（测试场有、竞技场没有） |
| `spawn` | 英雄**重生点**（与 `roster` 里的出场格是两件事） |
| `roster` | **本场景有哪些角色、在哪**：`[角色名, 阵营, x, y]` |
| `respawn_turns` | 场景特有的重生回合数（缺省 10） |
| `river_rows` / `bridge_cols` | 河与桥 |
| `victory` | **胜负条件**（本文重点） |
| `heli` | 直升机的场景参数覆盖（缺省值在 `Level.HELI_DEFAULTS`） |

---

## 2. 胜负条件契约

### 2.1 判定入口（纯函数，可无头测试）

```gdscript
# game/src/core/turn_flow.gd
TurnFlow.check(units: Array[Unit], cfg: Dictionary, turn_count: int) -> int
#   返回 TurnFlow.NONE(-1) = 还没结束
#        TurnFlow.PLAYER(0) / TurnFlow.ENEMY(1) = 该方获胜
```

`battle_scene._check_over()` 调它，`turn_count` 用 `GameMaster.turn_count`（全局唯一的回合边界时钟）。

### 2.2 四种条件类型

| `type` | 判定 | 额外字段 |
|---|---|---|
| `king` | 一方**老国王**阵亡（`u.is_king`）。**缺省值**，也是第 96 轮以前唯一的规则 | — |
| `annihilate` | 一方**可行动单位**全灭（假人不算、`no_turn` 的公主与国王不算） | — |
| `survive` | 撑满 `rounds` 个回合边界还没输 | `rounds: int`、`side: int`（缺省 = 敌方守） |
| `reach` | 某一方有人站进 `cells` 里任意一格 | `cells: Array[Vector2i]`、`side: int`（缺省 = 谁先到谁赢） |

### 2.3 叠加

`king` 这类主条件之外，还可以挂 `also` 数组，**任意一条满足就分胜负**：

```gdscript
"victory": {"type": "king", "also": [{"type": "survive", "rounds": 20, "side": 1}]}
```

### 2.4 现状与示例

两个场景当前都用 `{"type": "king"}`，但**都在元数据里显式写了出来**（不靠隐式缺省）——
这样换玩法就是改一行数据。

```gdscript
# 一方全灭即分胜负（适合没有国王的关卡）
"victory": {"type": "annihilate"},

# 我方守住 20 个回合也算赢
"victory": {"type": "king", "also": [{"type": "survive", "rounds": 20, "side": 1}]},

# 我方有人站到 (10, 20) 即胜
"victory": {"type": "reach", "side": 0, "cells": [Vector2i(10, 20)]},
```

### 2.5 边界行为（已被自检锁住）

- **双方同时全灭** → `annihilate` 返回"没结束"，交给上层兜底（`_begin_next_round` 的 200 边界保护）。
- **场景没配 `victory`** → 取缺省 `{"type": "king"}`，与旧行为一致。
- **`king` 模式下场上没有老国王**（关卡没配）→ 视同敌方失败，你是赢家（既有行为，有断言）。

---

## 3. 怎么加东西

### 加一个新场景
1. 在 `Level.DEFS` 里加一条：`gw/gh`、`play`、`cam_yaw`、`player`/`enemy`、`roster`、`victory`（**必填**）、
   以及需要时的 `spawn` / `respawn_turns` / `river_rows` / `bridge_cols` / `heli`。
2. `roster` 里的角色名必须在 `bc_stat.md` 的表里（→ `UnitData.UNITS` / `ENEMIES`）。
3. 调试页可以直接切场景（`ui_set_level`）。
4. **不用改任何场景侧代码**：出生、重生、河/桥、相机、胜负都由元数据驱动。

### 加一种胜负玩法
1. 在 `turn_flow.gd` 的 `TurnFlow.check_one()` 的 `match` 里加一个分支（约 5~8 行）。
2. 在文件顶部 `TYPE_*` 常量区加一行，并在 `reason_text()` 里加一句人话。
3. 在 `game/tests/run.gd` 的「场景胜负条件（第 97 轮）」段落加断言。
4. 在本文 §2.2 的表里补一行。

---

## 4. 相关文件

| 文件 | 职责 |
|---|---|
| `game/src/core/level.gd` | 场景元数据 + 地形/出生点/相机的查询函数（`Level.victory()` 也在它里面） |
| `game/src/core/turn_flow.gd` | 胜负判定的纯函数（`TurnFlow.check` / `check_one` / `reason_text`） |
| `game/src/view/battle_scene.gd` | `_check_over()` 调判定 + 弹胜者界面 |
| `game/tests/run.gd` | 判定逻辑的断言（无头，不加载场景） |
| `docs/规格.md` §六 / §七 | 现用口径（**权威**） |
