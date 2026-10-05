"""
读 bc_stat.md（Markdown 表格）-> 生成 Godot 用的 src/core/unit_data.gd。
数值只有一处来源：改 bc_stat.md 后重跑本脚本即可。

表格规则：
  · 每行一个角色，按【列名】识别属性（列顺序随意，多余的列会被忽略）
  · 表头行下面必须有 |---|---| 分隔行
  · 支持中英文列名（见 COLS）；用不到的格子写 - 或留空
用法: python tools/make_unit_data.py
"""
import re
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "bc_stat.md"
OUT = ROOT / "game" / "src" / "core" / "unit_data.gd"

TIERS = {"none": 0, "low": 200, "mid": 400, "high": 800, "immune": 1000}
TIER_CN = {0: "无", 200: "低", 400: "中", 800: "高", 1000: "免疫"}
ROLES = {"melee": "MELEE", "ranged": "RANGED", "thrower": "THROWER",
         "近战": "MELEE", "远程": "RANGED", "投掷": "THROWER"}
SIDES = {"player": "PLAYER", "enemy": "ENEMY", "我方": "PLAYER", "敌方": "ENEMY"}

# 列名 -> 内部字段（中英文都认，忽略大小写与空格）
COLS = {
    "名字": "name", "name": "name", "角色": "name",
    "阵营": "side", "side": "side", "faction": "side",
    "攻击方式": "role", "role": "role", "类型": "role",
    "力量": "power", "power": "power", "strength": "power",
    "护甲": "armor", "armor": "armor", "armour": "armor",
    "物抗": "pr", "pr": "pr", "physical_res": "pr",
    "魔抗": "mr", "mr": "mr", "magic_res": "mr",
    "破甲伤害": "armor_break", "破甲": "armor_break", "armor_break": "armor_break",
    "精力上限": "energy_max", "energy_max": "energy_max", "精力": "energy_max",
    "移动力": "move", "move": "move", "movement": "move",
    "射程": "range", "range": "range",
    "射击距离": "range", "攻击距离": "range", "距离": "range",
    "休息恢复力量": "rest_power", "rest_power": "rest_power",
    "休息恢复护甲": "rest_armor", "rest_armor": "rest_armor",
    "休息恢复精力": "rest_energy", "rest_energy": "rest_energy",
    # 可放置物（第 3 张表）专用列
    "占地": "size", "size": "size",
    "阻挡移动": "block_move", "block_move": "block_move",
    "阻挡远程": "block_ranged", "block_ranged": "block_ranged",
    "本关数量": "count", "count": "count", "数量": "count",
    "备注": "note", "note": "note", "comment": "note",
    # 敌方表专用：可控 = 阵营仍是敌方，但回合由玩家操作（用户要求）
    "可控": "controllable", "controllable": "controllable", "玩家控制": "controllable",
    # 碰撞体尺寸（第 99 轮新增，给 Reaper 这种"大个子圆柱"用；不写 = 用 Targeting 的缺省值）
    "体半径": "body_r", "body_r": "body_r", "半径": "body_r",
    "体高": "body_h", "body_h": "body_h", "身高": "body_h",
    # 占地（第 104 轮新增，角色用）：1x2 = 车身占两格 -> 两个碰撞圆柱（沿 +y 排）。
    # ⚠ 列名不能叫「占地」——那个名字被可放置物表占了（PLACEABLE_COLS 用它识别第 3 张表）。
    "占格": "foot", "foot": "foot", "占地格": "foot", "footprint": "foot",
}

# 第 3 张表 = 可放置物。它没有"攻击方式"，靠这一列区分。
PLACEABLE_COLS = {"size", "block_move", "block_ranged", "count"}

# 阵营由"第几个表格块"决定（文件里不放阵营列）：第 1 张表 = 我方，第 2 张 = 敌方
BLOCK_SIDES = ["PLAYER", "ENEMY"]

DEFAULTS = {"power": 20, "armor": 10, "armor_break": 5,
            "energy_max": 4, "move": 3}


def _split_row(line: str):
    return [c.strip() for c in line.strip().strip("|").split("|")]


def _is_sep(line: str) -> bool:
    cells = _split_row(line)
    return len(cells) > 0 and all(re.fullmatch(r":?-{2,}:?", c or "") for c in cells)


def _num(cell, default):
    if cell is None:
        return default
    m = re.search(r"-?\d+(?:\.\d+)?", str(cell))
    if not m:
        return default
    v = float(m.group(0))
    return int(v) if v == int(v) else v


def _tier(cell, default=0):
    if not cell:
        return default
    token = str(cell).strip().lower()
    if token in TIERS:
        return TIERS[token]
    for k, v in TIERS.items():          # 容忍 "high(80%)" 或 "高" 这类写法
        if k in token:
            return v
    for k, v in {"无": 0, "低": 200, "中": 400, "高": 800, "免疫": 1000}.items():
        if k in token:
            return v
    return default


def _parse_range(cell):
    """射程：'-'/'近战' -> (0,0)；'8' -> (1,8)；'3-20'/'3~20' -> (3,20)"""
    if not cell or str(cell).strip() in ("-", "—", "–", "近战", "melee", ""):
        return 0, 0
    nums = re.findall(r"\d+", str(cell))
    if not nums:
        return 0, 0
    if len(nums) == 1:
        return 1, int(nums[0])
    return int(nums[0]), int(nums[1])


def parse(text: str):
    """只解析真正的表格块（表头 + 分隔行 + 数据行）。
    阵营由表格块的先后决定：第 1 张 = 我方，第 2 张 = 敌方。
    第 3 张（含"占地"/"阻挡移动"这类列）= 可放置物，另走 _parse_placeable。
    返回 (players, enemies, placeables)。"""
    lines = text.splitlines()
    rows = []                       # (block_index, fields, cells)
    block = 0
    i = 0
    while i < len(lines) - 1:
        if lines[i].strip().startswith("|") and _is_sep(lines[i + 1]):
            headers = _split_row(lines[i])
            fields = [COLS.get(h.strip().lower(), COLS.get(h.strip())) for h in headers]
            j = i + 2
            while j < len(lines) and lines[j].strip().startswith("|") and not _is_sep(lines[j]):
                cells = _split_row(lines[j])
                if len(cells) >= 2:
                    rows.append((block, fields, cells))
                j += 1
            i = j
            block += 1
        else:
            i += 1

    players, enemies, placeables = [], [], []
    for block_idx, fields, cells in rows:
        d = {}
        for k, cell in zip(fields, cells):
            if k:
                d[k] = cell
        if not d.get("name"):
            continue
        name = d["name"].strip()
        # 可放置物表：有"占地"或"阻挡移动"这类列就按可放置物解析
        if PLACEABLE_COLS & set(d.keys()):
            placeables.append(_parse_placeable(name, d))
            continue
        # 阵营：优先用第几块表；万一有人又加回了"阵营"列，则那一列优先
        side = SIDES.get(str(d.get("side", "")).strip().lower(), None)
        if side is None:
            side = BLOCK_SIDES[block_idx] if block_idx < len(BLOCK_SIDES) else "ENEMY"
        role_token = str(d.get("role", "")).strip().lower()
        role = ROLES.get(role_token)
        rmin, rmax = _parse_range(d.get("range", ""))
        if role is None:
            # 没写攻击方式才按射程猜；写了就以表格为准
            # （老国王写的是 ranged + 1-15，不能因为 >12 就被改成投掷手）
            if rmax == 0:
                role = "MELEE"
            elif rmax > 12:
                role = "THROWER"
            else:
                role = "RANGED"

        unit = {
            "name": name, "side": side, "role": role,
            "power": _num(d.get("power"), DEFAULTS["power"]),
            "armor": _num(d.get("armor"), DEFAULTS["armor"]),
            "armor_break": _num(d.get("armor_break"), DEFAULTS["armor_break"]),
            "energy_max": _num(d.get("energy_max"), DEFAULTS["energy_max"]),
            "move": _num(d.get("move"), DEFAULTS["move"]),
            "rest_power": _num(d.get("rest_power"), None),
            "rest_armor": _num(d.get("rest_armor"), None),
            "rest_energy": _num(d.get("rest_energy"), None),
            "pr": _tier(d.get("pr")), "mr": _tier(d.get("mr")),
            "rng_min": rmin, "rng_max": rmax,
            "controllable": _yes(d.get("controllable")),
            # 碰撞体尺寸：不写就交给 Targeting.BODY_R / BODY_H 的缺省值
            "body_r": _fnum(d.get("body_r"), None),
            "body_h": _fnum(d.get("body_h"), None),
            # 第 104 轮：占地 1xN -> foot_y = N（N>1 时 Unit.from_data 会生成 N 个碰撞圆柱）
            "foot_y": _foot_y(d.get("foot")),
            "note": (d.get("note") or "").strip(),
        }
        # 兜底值：休息恢复力量/护甲 = 0，休息恢复精力 = 2（用户指定）
        if unit["rest_power"] is None:
            unit["rest_power"] = 0
            print("  [兜底] %-16s 未写休息恢复力量 -> 0" % name)
        if unit["rest_armor"] is None:
            unit["rest_armor"] = 0
            print("  [兜底] %-16s 未写休息恢复护甲 -> 0" % name)
        if unit["rest_energy"] is None:
            unit["rest_energy"] = 2
            print("  [兜底] %-16s 未写休息恢复精力 -> 2" % name)
        (players if side == "PLAYER" else enemies).append(unit)
    return players, enemies, placeables


def _yes(cell) -> bool:
    """'yes'/'no'/'true'/'false'/'是'/'否'/1/0 都认。"""
    t = str(cell or "").strip().lower()
    return t in ("yes", "y", "true", "1", "是", "可")


def _foot_y(cell):
    """占格 '1x2'/'1×2' -> 2（车身沿 +y 占几格）；'1x1'/空 -> 1。
    只认 x 为 1 的写法：本项目没有"横向占两格"的角色，遇到 x>1 直接报错，避免悄悄算错。"""
    if cell is None or str(cell).strip() == "":
        return 1
    t = str(cell).strip().lower().replace("×", "x").replace("*", "x")
    if "x" not in t:
        return int(_num(t, 1))
    a, b = t.split("x", 1)
    nx, ny = int(_num(a, 1)), int(_num(b, 1))
    if nx != 1:
        raise SystemExit("占格只支持 1xN（横向固定 1 格）：%r" % cell)
    return max(1, ny)


def _fnum(cell, default):
    """浮点列（体半径 / 体高）：空 = default。"""
    if cell is None or str(cell).strip() == "":
        return default
    m = re.search(r"-?\d+(?:\.\d+)?", str(cell))
    return float(m.group(0)) if m else default


def _ftxt(v) -> str:
    """GDScript 浮点字面量：整数就写成 3.0，避免 "3" 被当成 int。"""
    f = float(v)
    return ("%d.0" % int(f)) if f == int(f) else ("%g" % f)


def _parse_placeable(name: str, d: dict) -> dict:
    """可放置物：没有回合、没有精力、没有移动力，只有阻挡/血量/抗性/本关数量。"""
    size_raw = str(d.get("size", "1x1")).strip().lower()
    m = re.match(r"(\d+)\s*[x×*]\s*(\d+)", size_raw)
    sw, sh = (int(m.group(1)), int(m.group(2))) if m else (1, 1)
    return {
        "name": name,
        "w": sw, "h": sh,
        "power": _num(d.get("power"), 10),
        "armor": _num(d.get("armor"), 0),
        "pr": _tier(d.get("pr")), "mr": _tier(d.get("mr")),
        "block_move": _yes(d.get("block_move")),
        "block_ranged": _yes(d.get("block_ranged")),
        "count": _num(d.get("count"), 0),
    }


def gd_emit(players, enemies, placeables) -> str:
    L = []
    L.append("# ⚠️ 本文件由 tools/make_unit_data.py 从 bc_stat.md 自动生成，请勿手改。")
    L.append("# 改数值请改 bc_stat.md（表格），然后运行: python tools/make_unit_data.py")
    L.append("class_name UnitData")
    L.append("extends RefCounted")
    L.append("")
    L.append("enum Role { MELEE, RANGED, THROWER }")
    L.append("enum Side { PLAYER, ENEMY }")
    L.append("")
    L.append("# 投掷瞄准参数：箭头长度 = 身高的 1~3 倍，映射到射程 THROW_RANGE_MIN~MAX 格")
    L.append("const THROW_RANGE_MIN := 3.0")
    L.append("const THROW_RANGE_MAX := 20.0")
    L.append("const UNIT_HEIGHT := 1.0")
    L.append("const ARROW_LEN_MIN := 1.0")
    L.append("const ARROW_LEN_MAX := 3.0")
    L.append("const THROW_DRAG_MIN := 30.0")
    L.append("const THROW_DRAG_MAX := 400.0")
    L.append("")
    L.append("const DUMMY_SKIP_DELAY := 0.5     # 假人回合的停顿（秒）")
    L.append("const MORTAR_FLIGHT_MAX_SEC := 5.0")
    L.append("const ARROW_FLIGHT_MAX_SEC := 1.0")
    L.append("const DUMMY_REVIVE_SEC := 1.2")
    L.append("")

    def emit(u):
        note = ("  # " + u["note"]) if u.get("note") else ""
        L.append("\t{")
        L.append('\t\t"name": "%s",' % u["name"])
        L.append('\t\t"side": Side.%s,' % u["side"])
        L.append('\t\t"role": Role.%s,' % u["role"])
        L.append('\t\t"power": %s, "armor": %s, "armor_break": %s,' %
                 (u["power"], u["armor"], u["armor_break"]))
        L.append('\t\t"energy_max": %s, "move": %s,' % (u["energy_max"], u["move"]))
        L.append('\t\t"rest_power": %s, "rest_armor": %s, "rest_energy": %s,' %
                 (u["rest_power"], u["rest_armor"], u["rest_energy"]))
        L.append('\t\t"pr": %d, "mr": %d,' % (u["pr"], u["mr"]))
        L.append('\t\t"rng_min": %d, "rng_max": %d,%s' % (u["rng_min"], u["rng_max"], note))
        L.append('\t\t"controllable": %s,' % ("true" if u.get("controllable") else "false"))
        # 只在表里显式写了才输出：这样既保持旧角色的行不膨胀，也不影响任何既有解析
        if u.get("body_r") is not None:
            L.append('\t\t"body_r": %s,' % _ftxt(u["body_r"]))
        if u.get("body_h") is not None:
            L.append('\t\t"body_h": %s,' % _ftxt(u["body_h"]))
        # 第 104 轮：占地 1xN 才输出（既有角色不输出 -> 生成结果逐字不变）
        if int(u.get("foot_y", 1)) > 1:
            L.append('\t\t"foot_y": %d,' % int(u["foot_y"]))
        L.append("\t},")

    L.append("# 我方角色（来自 bc_stat.md 的「我方角色」表）")
    L.append("const UNITS := [")
    for u in players:
        emit(u)
    L.append("]")
    L.append("")
    L.append("# 敌方角色（来自 bc_stat.md 的「敌方角色」表）")
    L.append("const ENEMIES := [")
    for u in enemies:
        emit(u)
    L.append("]")
    L.append("")
    L.append("# 可放置物（来自 bc_stat.md 的「可放置物」表）")
    L.append("# block_move = 阻挡移动；block_ranged = 阻挡远程（投掷手不受阻挡）")
    L.append("const PLACEABLES := [")
    for p in placeables:
        L.append("\t{")
        L.append('\t\t"name": "%s",' % p["name"])
        L.append('\t\t"w": %d, "h": %d,' % (p["w"], p["h"]))
        L.append('\t\t"power": %s, "armor": %s,' % (p["power"], p["armor"]))
        L.append('\t\t"pr": %d, "mr": %d,' % (p["pr"], p["mr"]))
        L.append('\t\t"block_move": %s, "block_ranged": %s,' % (
            "true" if p["block_move"] else "false",
            "true" if p["block_ranged"] else "false"))
        L.append('\t\t"count": %d,' % p["count"])
        L.append("\t},")
    L.append("]")
    L.append("")
    return "\n".join(L)


def main():
    text = SRC.read_text(encoding="utf-8")
    players, enemies, placeables = parse(text)
    if not players:
        print("!! 没解析到我方角色，请检查 bc_stat.md 的表格格式（表头 + |---| + 数据行）")
    OUT.write_text(gd_emit(players, enemies, placeables), encoding="utf-8")
    print("解析结果：我方 %d 人，敌方 %d 人，可放置物 %d 种" % (
        len(players), len(enemies), len(placeables)))
    for p in placeables:
        print("  P %-8s %dx%d 力%-4s 甲%-4s 物抗%-3s 魔抗%-3s 挡移动=%-5s 挡远程=%-5s 数量=%d" % (
            p["name"], p["w"], p["h"], p["power"], p["armor"],
            TIER_CN[p["pr"]], TIER_CN[p["mr"]],
            p["block_move"], p["block_ranged"], p["count"]))
    for u in players + enemies:
        side = "P" if u["side"] == "PLAYER" else "E"
        print("  %s %-16s %-7s 力%-4s 甲%-4s 物抗%-3s 破甲%-3s 精力%-3s 移动%-3s 射程%d-%d 休息%d/%d/%d" % (
            side, u["name"], u["role"], u["power"], u["armor"], TIER_CN[u["pr"]],
            u["armor_break"], u["energy_max"], u["move"],
            u["rng_min"], u["rng_max"], u["rest_power"], u["rest_armor"], u["rest_energy"]))
    print("已写出", OUT)


if __name__ == "__main__":
    main()
