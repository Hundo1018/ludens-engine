# tier: integration
"""Checkpoints as save games (ROADMAP 17.72, `gameplay.checkpoint
.save_checkpoint` / `load_save_checkpoint`).

  1. Ordinary: a floor and 4 falling boxes with a game flow (a coin flag,
     an inventory, the RNG, the tick); at tick 60 a save-game checkpoint
     (flow section + one `BodyRecord` per dynamic body) and the full
     checkpoint (flow + scene snapshot) are taken and their sizes printed.
     60 ticks later the level is rebuilt from its script and the save
     checkpoint loaded: every box's pose and velocity equal tick 60's bit
     for bit, and the flow (tick, flag, inventory, next RNG draw) is the
     checkpoint's.
  2. Integration (selective): `KEEP_INVENTORY` keeps the items picked up
     after the checkpoint; `sections = SECTION_BODIES` puts the boxes back
     and leaves the flow as it is; a blob without a "bodies" section
     (an older build's) loads the flow and leaves the boxes alone.
  3. Extreme: a blob that is not a save file raises.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from gameplay.flow import FLAG_INT
from gameplay.inventory import Inventory
from gameplay.save import SaveWriter, BodyRecord, save_bodies
from gameplay.checkpoint import (
    GameFlow, save_checkpoint, load_save_checkpoint, take_checkpoint,
    KEEP_NONE, KEEP_INVENTORY, SECTION_BODIES,
)

comptime DT: Real = 1.0 / 60.0


def level() -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 10, 0.5, 10)), Vec3(10, 0.5, 10, 0), True)
    for k in range(4):
        _ = sc.add(QuatBody6.at_rest(Vec3(Real(k) * 0.7 - 1, 1 + Real(k) * 0.5, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    return sc^


def run(mut sc: ContactScene6[QuatBody6], mut flow: GameFlow, n: Int, cfg: SolverConfig) raises:
    for _ in range(n):
        sc.step(DT, Vec3(0, -9.8, 0, 0), cfg)
        flow.tick += 1
        if flow.tick % 10 == 0:
            var coins = flow.flags.find("coins")
            flow.flags.set(coins, flow.flags.get(coins) + Int(flow.rng.next_u32() % 5))


def bodies_equal(want: List[BodyRecord], b: ContactScene6[QuatBody6]) -> Bool:
    """Every dynamic body of `b` matches the record taken for its slot."""
    for x in want:
        ref y = b.bset.bodies[x.slot]
        for c in range(3):
            if x.pos[c] != y.pos[c] or x.vel[c] != y.vel[c] or x.omega[c] != y.omega[c]:
                return False
        if x.rot.x != y.q.x or x.rot.y != y.q.y or x.rot.z != y.q.z or x.rot.w != y.q.w:
            return False
    return True


def main() raises:
    var s = Suite("save_checkpoint")
    var cfg = SolverConfig()
    var sc = level()
    var flow = GameFlow(42)
    _ = flow.flags.declare("coins", FLAG_INT)
    var limits: List[Int] = [10, 10]
    flow.inventories.append(Inventory(4, limits))
    _ = flow.inventories[0].add(0, 3)
    run(sc, flow, 60, cfg)
    var blob = save_checkpoint(flow, sc)
    var full = take_checkpoint(flow, sc)
    var at60 = save_bodies(sc)
    var coins60 = flow.flags.get(flow.flags.find("coins"))
    var probe = flow.copy()
    var next60 = probe.rng.next_u32()
    print("  tick 60: save checkpoint", len(blob), "bytes, full checkpoint (scene snapshot)", len(full), "bytes")
    run(sc, flow, 60, cfg)
    _ = flow.inventories[0].add(1, 5)

    var rebuilt = level()
    var f = load_save_checkpoint(blob, flow, rebuilt)
    s.check(bodies_equal(at60, rebuilt), "boxes back at tick 60's poses and velocities, bit for bit")
    var ok = f.tick == 60 and f.flags.get(f.flags.find("coins")) == coins60 and f.inventories[0].count_of(1) == 0
    s.check(ok and f.rng.next_u32() == next60, "flow is the checkpoint's: tick 60, coins, inventory, next RNG draw")
    print("  coins at tick 60", coins60, " at tick 120", flow.flags.get(flow.flags.find("coins")))

    var r2 = level()
    var k = load_save_checkpoint(blob, flow, r2, KEEP_INVENTORY)
    s.check(k.inventories[0].count_of(1) == 5 and k.tick == 60, "KEEP_INVENTORY: items picked up after the checkpoint stay")
    var r3 = level()
    var b_only = load_save_checkpoint(blob, flow, r3, KEEP_NONE, SECTION_BODIES)
    s.check(bodies_equal(at60, r3) and b_only.tick == 120, "SECTION_BODIES: boxes restored, flow untouched (tick 120)")
    var old = SaveWriter()
    old.add_raw("flow", flow.to_bytes())
    var r4 = level()
    var fresh = save_bodies(level())
    var fo = load_save_checkpoint(old.bytes(), GameFlow(1), r4)
    s.check(bodies_equal(fresh, r4) and fo.tick == 120, "no bodies section: flow loads, boxes left alone")
    var raised = False
    try:
        var junk: List[UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
        _ = load_save_checkpoint(junk, flow, r4)
    except:
        raised = True
    s.check(raised, "not a save file: raises")
    s.finish()
