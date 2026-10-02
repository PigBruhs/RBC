"""
Balance probe v7 — aligned to the clarified rules (2026-09-30 user clarification).

Rule changes incorporated:
  1. phys_res / mag_res are FIXED, FIVE-TIER attributes (no level-up investment):
       0 = 无(NONE) / 0.2 = 低(LOW) / 0.4 = 中(MID) / 0.8 = 高(HIGH) / 1.0 = 免疫(IMMUNE)
  2. Damage formula is MULTIPLICATIVE:
       D = (P_eff - A_cur) * (1 - R)
     (The user's own example: power - armor = 2, R = 0.8 -> D = 0.4 -> 40% chance of 1 damage.
      This confirms `* (1-R)`, not the previously-read `/ (1-R)`.)
  3. Death: only power pool reaching 0 kills (already adopted).
  4. Magic damage only from skills -> mag_res is a reserved field in v1.

Goal: quantify how often the 0<D<1 probability roll actually fires, since with five discrete
R tiers the damage value is a multiple of (1-R), which puts it in the roll band much more often.
"""
import random
from itertools import product

TIERS = {"NONE": 0, "LOW": 200, "MID": 400, "HIGH": 800, "IMMUNE": 1000}   # per-mille


def damage_milli(P_milli: int, A_milli: int, R: int) -> int:
    """D in thousandths.  D = (P - A) * (1 - R).  IMMUNE -> 0."""
    delta = P_milli - A_milli
    if delta <= 0:
        return 0
    return (delta * (1000 - R)) // 1000


def hit_percent(D_milli: int) -> int:
    """spec rule: D>=1000 auto-hit; 0<D<1000 -> ceil(D/10) percent, clamped to [1,99]."""
    if D_milli >= 1000:
        return 100
    if D_milli <= 0:
        return 0
    pct = -(-D_milli // 10)          # ceil division
    return max(1, min(99, pct))


def classify(D_milli: int) -> str:
    if D_milli <= 0:
        return "NO_DAMAGE"
    if D_milli < 1000:
        return "ROLL"
    return "AUTO"


# ---------------------------------------------------------------- 1. roll frequency
def roll_frequency():
    """How many (delta, R) combinations land in the probability band?"""
    print("=" * 78)
    print("1. 概率判定触发频率：给定 (力量-护甲) 差值与物抗档位")
    print("=" * 78)
    print("   D = (P-A) * (1-R)  =>  只有 0 < D < 1 才掷骰")
    print()
    print("   %-8s %-28s %-28s" % ("P-A", "R=0.2(低)", "R=0.4(中)"))
    for delta in range(1, 11):
        row = []
        for R in (200, 400):
            D = damage_milli(delta * 1000, 0, R)
            c = classify(D)
            mark = {"ROLL": "★掷骰", "AUTO": "必中"}[c]
            row.append(f"D={D/1000:5.2f} -> {hit_percent(D):3d}%  {mark}")
        print("   %-8d %-28s %-28s" % (delta, row[0], row[1]))
    print()
    print("   R=0.8(高):")
    for delta in range(1, 11):
        D = damage_milli(delta * 1000, 0, 800)
        c = classify(D)
        if c == "ROLL":
            mark = f"★掷骰 -> {hit_percent(D)}% 造成 1 点"
        elif c == "AUTO":
            mark = f"必中 -> {D // 1000} 点"
        else:
            mark = "无法造伤"
        print(f"     P-A={delta:<3} D={D/1000:5.2f}  {mark}")
    print()
    print("   R=1.0(免疫): 任意差值 D=0 -> 力量线完全无效，必须用破甲线或魔法")
    print()


# ---------------------------------------------------------------- 2. archetype matrix
# v1.1 archetypes from spec_rules.md, now with a resistance TIER per unit.
ARCH = {
    # name: (power, armor, tier, armor_break)
    "民兵 Militia":       (9,  5, "LOW",    2000),   # 用户说 5 无所谓，数值只是占位起点
    "剑士 Swordsman":     (14, 8,  "LOW",    3000),
    "塔盾卫 TowerGuard":  (9,  11, "MID",    2500),
    "弓手 Archer":        (13, 6,  "NONE",   2000),
    "破甲者 Breaker":     (12, 6,  "LOW",    6000),
    "石肤守卫 StoneWarden": (12, 9, "HIGH",  2500),
    "重弩手 HeavyXbow":   (14, 6,  "NONE",   2000),
    "掷弹手 Bombardier":  (10, 6,  "MID",    4000),
}


def damage_matrix():
    print("=" * 78)
    print("2. 力量线伤害矩阵（无精力，平地）—— 行=攻击方，列=目标")
    print("=" * 78)
    names = list(ARCH)
    print("%-22s" % "ATK \\ DEF" + "".join("%-13s" % n.split()[0] for n in names))
    roll_count = 0
    total = 0
    for a in names:
        Pa, Aa, Ta, Ba = ARCH[a]
        cells = []
        for d in names:
            Pd, Ad, Td, Bd = ARCH[d]
            D = damage_milli(Pa * 1000, Ad * 1000, TIERS[Td])
            total += 1
            if classify(D) == "ROLL":
                roll_count += 1
                cells.append("%-13s" % f"{D/1000:.1f}({hit_percent(D)}%)")
            elif D == 0:
                cells.append("%-13s" % "0·破甲")
            else:
                cells.append("%-13s" % f"{D//1000}")
        print("%-22s" % a.split()[0] + "".join(cells))
    print()
    print(f"   落在概率判定区间(0<D<1)的组合：{roll_count} / {total} = {roll_count/total*100:.0f}%")
    print("   （对比：旧公式 /(1-R) 且 R 为连续值时，平地概率区间为 0/64 = 0%）")
    print()


# ---------------------------------------------------------------- 3. TTK
def ttk_table():
    print("=" * 78)
    print("3. TTK（击倒所需命中次数）= 力量 / D = 力量 / ((力量-护甲)*(1-R))")
    print("   => TTK = (1/(1-R)) * 力量/(力量-护甲)   即：物抗档位是独立的倍率")
    print("=" * 78)
    print("%-12s" % "护甲/力量" + "".join("%-12s" % f"R={R/1000:.1f}" for R in (0, 200, 400, 800)))
    for ratio in (0.4, 0.5, 0.6, 0.7, 0.8, 0.9):
        P = 10000
        A = int(P * ratio)
        cells = []
        for R in (0, 200, 400, 800):
            D = damage_milli(P, A, R)
            cells.append("%-12s" % ("∞" if D == 0 else f"{P/D:.2f}"))
        print("%-12s" % ratio + "".join(cells))
    print()
    print("   物抗档位对生存力的直接倍率：无=×1.0 / 低=×1.25 / 中=×1.67 / 高=×5.0 / 免疫=击杀不了")
    print()


# ---------------------------------------------------------------- 4. break line
def break_line():
    print("=" * 78)
    print("4. 破甲线（无视物抗、无视护甲、无视力量）—— 免疫单位的唯一物理解")
    print("=" * 78)
    for a in ("破甲者 Breaker", "掷弹手 Bombardier", "剑士 Swordsman", "民兵 Militia"):
        _, _, _, B = ARCH[a]
        print(f"   {a:<22} BD={B/1000:.0f}  +0精力 -> {B/1000:.0f} 点   +3精力 -> {B/1000+6:.0f} 点")
    print()
    print("   注：破甲线打的是「护甲池」（当前护甲值），不造成击杀（power_only 死亡规则）。")
    print("       所以对 R=免疫 的单位，正确解法是：先用破甲打空护甲 -> 但护甲打空也不死 ->")
    print("       必须靠技能(魔法)或强制其力量归零的其他手段 => v1 里 R=免疫 只能作为「Boss 机制」，")
    print("       且必须给玩家提供魔法技能，否则该单位在本作 v1 内不可击杀。")
    print()


# ---------------------------------------------------------------- 5. energy
def energy_check():
    print("=" * 78)
    print("5. 精力强度（+2 力量/点，最多 3 点）—— 在「护甲/力量」比例下的实际增幅")
    print("=" * 78)
    print("%-10s %-10s %-12s %-12s %-12s %-10s" % ("P", "A", "R=低 D(k=0)", "D(k=3)", "倍率", "=+X%"))
    for P, A in ((9, 5), (12, 6), (14, 8), (18, 10)):
        for R in (200, 400):
            d0 = damage_milli(P * 1000, A * 1000, R)
            d3 = damage_milli((P + 6) * 1000, A * 1000, R)
            if d0 == 0:
                continue
            ratio = d3 / d0
            print("%-10d %-10d %-12.2f %-12.2f %-12.2f %-10s" %
                  (P, A, d0 / 1000, d3 / 1000, ratio, f"+{(ratio-1)*100:.0f}%"))
    print()


# ---------------------------------------------------------------- 6. ladder
def ladder():
    print("=" * 78)
    print("6. 五档物抗的「有效生命倍率」（对纯力量输出者而言）")
    print("=" * 78)
    print("   %-10s %-10s %-14s %-16s" % ("档位", "减伤", "伤害乘数", "等效耐久倍率"))
    for name, R in TIERS.items():
        mult = (1000 - R) / 1000
        ehp = "∞（不可击杀）" if R == 1000 else f"×{1/mult:.2f}"
        print("   %-10s %-10s %-14s %-16s" % (name, f"{R/1000:.1f}", f"×{mult:.1f}", ehp))
    print()
    print("   结论：档位之间的跳跃很大（低→高 是 4 倍），而升级每级只 +3 点属性、")
    print("         所以 物抗档位 应该主要用来做「兵种身份的差异」，而不是成长曲线。")
    print()


if __name__ == "__main__":
    roll_frequency()
    damage_matrix()
    ttk_table()
    break_line()
    energy_check()
    ladder()
