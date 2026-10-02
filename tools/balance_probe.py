"""
Throwaway balance simulator v4 for the v1 plan (docs/design_v1.md).

Findings so far (kept here because they drive the plan's numeric tables):
  v1: high armor -> D<=0 deadlock, 0 kills in 120 rounds. Armor must never exceed a peer's power
      unless the design *intends* "you must break armor first" (tank).
  v2: probe AI refused to move. Also: because 力量 IS the health pool, a unit can be one-shot.
  v3: quantified the core ratio. TTK(hits) = power / E[D] = power * (1-R) / (power - armor).
      => TTK is scale-free; it is governed by the ratio armor/power and by R.
      Target TTK 2.5-3.5 => armor/power ~= 0.65-0.75 at R=0.2 (matches the author's own 12/8/0.35 example).
  v4: applies armor = ~65% of power, resistance as a *mini HP multiplier* (R is a liability under
      the literal formula, so high-R units need proportionally more power), and tests pacing.
"""
import random
from dataclasses import dataclass

W, H = 12, 12
THRESHOLDS = [1, 2, 4, 8]

def damage_thousandths(power, armor, res, mode):
    diff = power - armor
    if diff <= 0: return 0
    if mode == "DIVIDE":   return (diff * 1000) // max(1000 - res, 1)
    if mode == "MULTIPLY": return (diff * (1000 - res)) // 1000
    if mode == "FLAT":     return diff - (res * power) // 1000
    raise ValueError(mode)

def expected_damage(power, armor, res, mode):
    return damage_thousandths(power, armor, res, mode) / 1000.0

def ttk(power_att, armor_def, res_def, power_def, mode):
    e = expected_damage(power_att, armor_def, res_def, mode)
    return None if e == 0 else power_def / 1000.0 / e

def roll_damage(power, armor, res, mode, rng):
    d = damage_thousandths(power, armor, res, mode)
    whole, frac = divmod(d, 1000)
    dmg = whole
    if frac > 0 and rng.randrange(100) < (frac + 5) // 10:
        dmg += 1
    return dmg

@dataclass
class Proto:
    name: str; power: int; armor: int; res: int; brk: int
    emax: int; rest_p: int; rest_a: int; move: int; rng_: int; init: int

# Final calibration rule set (these are the numbers the plan recommends):
#   armor/power  = 0.55 (fodder) .. 0.75 (tank)         -> TTK 2-3 hits
#   res          = 0.10 .. 0.20 for normal units, 0.40 for the "high res" unit, paid for with +power
#                  (res is a LIABILITY under the literal formula, so it must be compensated)
#   brk          = 0.25P (normal) .. 0.9P (breaker)      -> attacking armor is a real option
PROTOS = {
    "grunt":   Proto("民兵",   10000,  5500, 100,  2500, 1000, 2500, 2500, 4,  0, 10),
    "soldier": Proto("剑士",   16000,  9000, 200,  5000, 2000, 4000, 4000, 4,  0, 12),
    "tank":    Proto("盾卫",   13000, 14000, 300,  5000, 2000, 4000, 6000, 3,  0,  8),
    "breaker": Proto("破甲手", 15000,  9000, 150, 12000, 2000, 3000, 3000, 4,  0, 11),
    "wraith":  Proto("虚体",   19000, 12000, 400,  4000, 3000, 3000, 3000, 5,  0, 14),
    "bomber":  Proto("掷弹兵", 15000, 10000, 200,  5000, 2000, 3000, 3000, 4,  0,  9),
    "archer":  Proto("弓手",   16000,  6000, 150,  2500, 2000, 3000, 2500, 4,  6, 13),
    "sniper":  Proto("弩手",   17000, 12000, 100,  2000, 2000, 3000, 2500, 3, 10, 16),
}

@dataclass
class Unit:
    uid: int; side: int; proto: Proto; x: int; y: int
    power: int = 0; armor: int = 0; level: int = 1; kills: int = 0
    energy: int = 0; alive: bool = True; rests: int = 0; breaks: int = 0; moves: int = 0
    def __post_init__(self):
        self.power = self.proto.power; self.armor = self.proto.armor; self.energy = self.proto.emax
    @property
    def res(self): return self.proto.res
    @property
    def brk(self): return self.proto.brk
    def max_power(self): return self.proto.power + 1500*(self.level-1)
    def max_armor(self): return self.proto.armor + 1500*(self.level-1)
    def grow(self):
        for i in range(3):
            if self.proto.rng_ == 0 and i == 2: self.armor += 1500
            else: self.power += 1500
    def need_kills(self):
        return sum(THRESHOLDS[:self.level]) if self.level - 1 < len(THRESHOLDS) else 10**9

def manh(a, b): return abs(a[0]-b[0]) + abs(a[1]-b[1])

def neighbors(x, y):
    for dx, dy in ((1,0),(-1,0),(0,1),(0,-1)):
        nx, ny = x+dx, y+dy
        if 0 <= nx < W and 0 <= ny < H: yield nx, ny

def reachable(u, occupied):
    start = (u.x, u.y); cost = {start: 0}; frontier = [start]
    while frontier:
        nxt = []
        for (x, y) in frontier:
            c = cost[(x, y)]
            for nx, ny in neighbors(x, y):
                if (nx, ny) in occupied and (nx, ny) != start: continue
                zoc = any((nx+dx, ny+dy) in occupied for dx, dy in ((1,0),(-1,0),(0,1),(0,-1)))
                nc = c + (2 if zoc else 1)
                if nc <= u.proto.move and nc < cost.get((nx, ny), 99):
                    cost[(nx, ny)] = nc; nxt.append((nx, ny))
        frontier = nxt
    return set(cost)

def options(actor, pos, enemies, mode):
    out = []
    for t in enemies:
        d = manh(pos, (t.x, t.y))
        if actor.proto.rng_ > 0:
            if d > actor.proto.rng_: continue
        elif d != 1:
            continue
        p_dmg = expected_damage(actor.power, t.armor, t.res, mode)
        # distance falloff: without it, a long-range unit free-fires from safety every round
        far_pen = 1.6 * max(0, d - 1)
        for stat in (("POWER",) if actor.proto.rng_ > 0 else ("POWER", "ARMOR")):
            for k in range(0, min(3, actor.energy // 1000) + 1):
                if stat == "POWER":
                    dmg = expected_damage(actor.power + 2000*k, t.armor, t.res, mode)
                    val = min(dmg, t.power/1000.0) + (60 if dmg >= t.power/1000.0 else 0)
                    if dmg == 0: val = 0.05
                else:
                    dmg = actor.brk/1000.0 + 2*k
                    val = min(dmg, t.armor/1000.0) * 0.5
                    if p_dmg == 0 and t.armor > 0: val = min(dmg, t.armor/1000.0)*2.0 + 6
                out.append((t, stat, k, val - far_pen))
    return out

def simulate(mode, seed, max_rounds=60):
    rng = random.Random(seed)
    # 6v6 mirrored army (same archetypes both sides -> any win-rate skew is AI/first-strike, not stats)
    layout = [("soldier",(2,3)),("tank",(2,6)),("breaker",(1,5)),("archer",(1,8)),("grunt",(3,4)),("bomber",(1,2))]
    elayout = [("soldier",(9,3)),("tank",(9,6)),("breaker",(10,5)),("archer",(10,8)),("grunt",(8,4)),("bomber",(10,2))]
    units = [Unit(i, 0, PROTOS[k], x, y) for i,(k,(x,y)) in enumerate(layout)]
    units += [Unit(100+i, 1, PROTOS[k], x, y) for i,(k,(x,y)) in enumerate(elayout)]
    order = sorted(units, key=lambda u: (-u.proto.init, u.side, u.uid))
    round_no = 0
    while round_no < max_rounds:
        round_no += 1
        for u in order:
            if not u.alive: continue
            enemies = [v for v in units if v.alive and v.side != u.side]
            if not enemies: break
            occupied = {(v.x, v.y) for v in units if v.alive and v is not u}
            cur = options(u, (u.x, u.y), enemies, mode)
            best = max(cur, key=lambda o: o[3]) if cur else None
            if best is None or best[3] < 1.0:
                cand, cbest = (u.x, u.y), (best[3] if best else -1e9)
                for c in reachable(u, occupied):
                    o = options(u, c, enemies, mode)
                    v = max(x[3] for x in o) if o else -0.35 * min(manh(c, (e.x, e.y)) for e in enemies)
                    if v > cbest + 1e-9: cbest, cand = v, c
                if cand != (u.x, u.y):
                    u.x, u.y = cand; u.moves += 1
                cur = options(u, (u.x, u.y), enemies, mode)
                best = max(cur, key=lambda o: o[3]) if cur else None
            if best is None or best[3] < 1.0:
                u.power = min(u.power + u.proto.rest_p, u.max_power())
                u.armor = min(u.armor + u.proto.rest_a, u.max_armor())
                u.energy = min(u.energy + 1000, u.proto.emax); u.rests += 1
                continue
            t, stat, k, val = best
            u.energy -= 1000 * k
            if stat == "POWER":
                t.power = max(0, t.power - roll_damage(u.power + 2000*k, t.armor, t.res, mode, rng)*1000)
            else:
                t.armor = max(0, t.armor - (u.brk//1000 + 2*k)*1000); u.breaks += 1
            if t.power <= 0:
                t.alive = False; u.kills += 1
                while u.level < 5 and u.kills >= u.need_kills():
                    u.level += 1; u.grow()
        if not any(u.alive and u.side == 0 for u in units) or not any(u.alive and u.side == 1 for u in units):
            break
    p_alive = sum(1 for u in units if u.alive and u.side == 0)
    e_alive = sum(1 for u in units if u.alive and u.side == 1)
    winner = 0 if (e_alive == 0 and p_alive > 0) else (1 if (p_alive == 0 and e_alive > 0) else -1)
    return dict(rounds=round_no, winner=winner, p_alive=p_alive, e_alive=e_alive,
                p_kills=sum(u.kills for u in units if u.side == 0),
                e_kills=sum(u.kills for u in units if u.side == 1),
                p_levels=[u.level for u in units if u.side == 0],
                turns=sum(u.kills + u.rests + u.breaks + u.moves for u in units),
                rests=sum(u.rests for u in units))

def report(mode, n=300):
    rs = [simulate(mode, s) for s in range(n)]
    rounds = sorted(r["rounds"] for r in rs)
    wins = sum(1 for r in rs if r["winner"] == 0); draws = sum(1 for r in rs if r["winner"] == -1)
    lv = sorted(max(r["p_levels"]) for r in rs)
    print(f"=== res_mode = {mode} (n={n}) ===")
    print(f"  rounds: avg {sum(rounds)/len(rounds):.2f} median {rounds[len(rounds)//2]} p10 {rounds[len(rounds)//10]} p90 {rounds[len(rounds)*9//10]} max {rounds[-1]}")
    print(f"  player win {wins/n*100:.1f}%  enemy win {(n-wins-draws)/n*100:.1f}%  unresolved {draws/n*100:.1f}%")
    print(f"  survivors: player {sum(r['p_alive'] for r in rs)/n:.2f}/5, enemy {sum(r['e_alive'] for r in rs)/n:.2f}/5")
    print(f"  player max level: median {lv[n//2]} max {lv[-1]} (>=2: {sum(1 for x in lv if x>=2)/n*100:.0f}%, >=3: {sum(1 for x in lv if x>=3)/n*100:.0f}%)")
    print(f"  rest share of unit-turns: {sum(r['rests'] for r in rs)/max(1,sum(r['turns'] for r in rs))*100:.1f}%")
    print()

if __name__ == "__main__":
    print("### ratio table: TTK (hits) = power*(1-R)/(power-armor) ###")
    print("%-10s %-8s %-8s %-8s" % ("armor/P", "R=0.0", "R=0.2", "R=0.4"))
    for ratio in (0.4, 0.5, 0.55, 0.6, 0.65, 0.7, 0.8):
        row = []
        for R in (0, 200, 400):
            P, A = 16000, int(16000*ratio)
            row.append("%-8s" % f"{ttk(P, A, R, P, 'DIVIDE'):.2f}")
        print("%-10s %s" % (ratio, " ".join(row)))
    print()
    print("### E[damage] & TTK for the archetypes (DIVIDE) ###")
    names = list(PROTOS.keys())
    print("%-9s" % "ATK\\DEF" + "".join("%-9s" % n for n in names))
    for a in names:
        cells = []
        for d in names:
            e = expected_damage(PROTOS[a].power, PROTOS[d].armor, PROTOS[d].res, "DIVIDE")
            cells.append("%-9s" % ("0(break!)" if e == 0 else f"{e:.1f}"))
        print("%-9s" % a + "".join(cells))
    print()
    print("%-9s" % "ATK\\DEF" + "".join("%-9s" % n for n in names) + "   <- TTK in hits")
    for a in names:
        cells = []
        for d in names:
            t = ttk(PROTOS[a].power, PROTOS[d].armor, PROTOS[d].res, PROTOS[d].power, "DIVIDE")
            cells.append("%-9s" % ("never" if t is None else f"{t:.1f}"))
        print("%-9s" % a + "".join(cells))
    print()
    for m in ("DIVIDE", "MULTIPLY"):
        report(m)
