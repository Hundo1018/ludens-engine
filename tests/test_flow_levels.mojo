# tier: integration
"""Checkpoints, respawn, level transitions, dialogue (ROADMAP 17.72).

  1. Checkpoint: a scene of 6 boxes falling on a floor plus a `GameFlow`
     (stack, flags, a 2-step quest, an inventory, a Pcg32). Checkpoint at
     tick 60, run to tick 120 drawing loot from the flow RNG and picking up
     items; restore and run the same 60 ticks again: body positions and
     velocities, RNG state, flags bytes, objective progress and inventory
     are bit-identical.
  2. Respawn: after picking up 5 items past the checkpoint, `KEEP_NONE`
     gives back the checkpoint's inventory, `KEEP_INVENTORY` keeps the 5
     items while the scene and flags still come from the checkpoint.
  3. Blob errors: one flipped byte (checksum), a truncated blob, a blob of
     another kind raise.
  4. Level transition: unknown level raises; while level 2 loads, events
     are held (the quest does not advance), a checkpoint is refused and a
     second request raises; `loaded(2)` releases the held events in order
     and the inventory crossed the transition untouched; `loaded` for a
     level that was not requested raises. Partition cell loads become
     events through the same door.
  5. Dialogue: a guard asks for a pass; the "bribe" choice needs 10 gold
     (closed at 5, open at 12) and subtracts it; "show pass" sets the
     `gate_open` flag, which completes a "get through the gate" objective
     via `on_flag_changes`. Choosing a closed choice, a choice of another
     node, or after the end raises; a choice leading to a missing node is
     caught by `validate`.
  6. Recorder with flow state: 240 ticks with a pickup (button 2, a roll
     from the flow RNG) every 15 ticks: replay reproduces every checksum,
     `seek` to tick 130 equals a full re-run including the bag, and adding
     one pickup to the recorded input of tick 100 makes `first_divergence`
     report tick 100 (the bodies are untouched: only the flow differs).
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from gameplay.flow import TICK_ALL, FLAG_INT, FLAG_BOOL
from gameplay.objectives import ObjectiveLog, on_flag_changes
from gameplay.inventory import Inventory
from gameplay.checkpoint import GameFlow, take_checkpoint, restore_checkpoint, respawn, KEEP_NONE, KEEP_INVENTORY
from gameplay.level_flow import LevelDirector, checked_checkpoint
from gameplay.large_world import CellEvent, EV_LOAD, EV_UNLOAD
from gameplay.dialogue import DialogueGraph, CMP_GE, CMP_EQ, EFF_SET, EFF_ADD
from gameplay.loc_keys import loc_id
from gameplay.character import CharacterController
from gameplay.replay import InputFrame, SimState, Recorder, seek, replay_from_start, first_divergence, checksum
from scheduler.rng import SplitMix64

comptime EV_PICKUP = 1
comptime EV_TALK = 2
comptime EV_CELL_IN = 3
comptime EV_CELL_OUT = 4
comptime EV_FLAG = 100
comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 1.0 / 60.0


def scene() raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 10, 0.5, 10)), Vec3(10, 0.5, 10, 0), True)
    for k in range(6):
        var b = QuatBody6.at_rest(Vec3(Real(k % 3) * 0.7 - 0.7, 0.5 + Real(k) * 0.65, Real(k // 3) * 0.4, 0), Inertia3.box(1, 0.3, 0.3, 0.3))
        _ = sc.add(b^, Vec3(0.3, 0.3, 0.3, 0), False)
    return sc^


def flow() raises -> GameFlow:
    var f = GameFlow(42)
    f.stack.push(1, TICK_ALL)
    _ = f.flags.declare("gold", FLAG_INT, 5)
    _ = f.flags.declare("gate_open", FLAG_BOOL)
    _ = f.objectives.add(EV_PICKUP, 8, List[Int]())
    _ = f.objectives.add(EV_TALK, 1, [0])
    f.inventories.append(Inventory(4, [5, 99]))
    return f^


def tick(mut f: GameFlow, mut sc: ContactScene6[QuatBody6]) raises:
    """One tick: the world steps; every 6th tick a loot roll from the flow
    RNG puts 0 or 1 item 0 in the bag and counts as a pickup."""
    sc.step_soft(DT, G)
    if f.tick % 6 == 0:
        var n = Int(f.rng.next_u32() % 2)
        if n > 0:
            _ = f.inventories[0].add(0, n)
            f.objectives.on_event(EV_PICKUP, n)
            f.flags.set(0, f.flags.get(0) + 1)
    f.tick += 1


def same_scene(a: ContactScene6[QuatBody6], b: ContactScene6[QuatBody6]) -> Bool:
    if len(a.bset.bodies) != len(b.bset.bodies):
        return False
    for i in range(len(a.bset.bodies)):
        var pa = a.bset.bodies[i].position()
        var pb = b.bset.bodies[i].position()
        var va = a.bset.bodies[i].linear_velocity()
        var vb = b.bset.bodies[i].linear_velocity()
        for k in range(3):
            if pa[k].to_bits() != pb[k].to_bits() or va[k].to_bits() != vb[k].to_bits():
                return False
    return True


def same_flow(a: GameFlow, b: GameFlow) -> Bool:
    var x = a.to_bytes()
    var y = b.to_bytes()
    if len(x) != len(y):
        return False
    for k in range(len(x)):
        if x[k] != y[k]:
            return False
    return True


def raises_restore(b: List[UInt8]) -> Bool:
    try:
        _ = restore_checkpoint(b)
    except:
        return True
    return False


def main() raises:
    var s = Suite("flow_levels")

    # ---- checkpoint round trip ---------------------------------------------------------------------
    var f = flow()
    var sc = scene()
    for _ in range(60):
        tick(f, sc)
    var blob = take_checkpoint(f, sc)
    for _ in range(60):
        tick(f, sc)
    var r = restore_checkpoint(blob)
    var at_ckp = r.flow.tick
    for _ in range(60):
        tick(r.flow, r.scene)
    print("checkpoint: bytes", len(blob), " restored at tick", at_ckp, " items at 120", f.inventories[0].count_of(0), r.flow.inventories[0].count_of(0), " pickups", f.objectives.objs[0].progress, " gold", f.flags.get(0))
    s.check(at_ckp == 60 and same_scene(sc, r.scene), "restored scene re-runs 60 ticks bit for bit")
    s.check(same_flow(f, r.flow) and f.rng.state == r.flow.rng.state, "flow state (flags, objectives, inventory, RNG) bit for bit")

    # ---- respawn policies -----------------------------------------------------------------------------
    var ckp_items = restore_checkpoint(blob).flow.inventories[0].count_of(0)
    _ = f.inventories[0].add(1, 5)
    var plain = respawn(blob, f, KEEP_NONE)
    var kept = respawn(blob, f, KEEP_INVENTORY)
    print("respawn: checkpoint items", ckp_items, " keep-none bag", plain.flow.inventories[0].count_of(0), plain.flow.inventories[0].count_of(1), " keep-inventory bag", kept.flow.inventories[0].count_of(0), kept.flow.inventories[0].count_of(1))
    s.check(plain.flow.inventories[0].count_of(1) == 0 and plain.flow.inventories[0].count_of(0) == ckp_items, "KEEP_NONE: the checkpoint's inventory")
    s.check(kept.flow.inventories[0].count_of(1) == 5 and kept.flow.flags.get(0) == restore_checkpoint(blob).flow.flags.get(0) and kept.flow.tick == 60, "KEEP_INVENTORY: items kept, flags and tick from the checkpoint")

    # ---- blob errors ----------------------------------------------------------------------------------
    var flipped = blob.copy()
    flipped[len(flipped) // 2] ^= 1
    var short = List[UInt8]()
    for k in range(len(blob) - 9):
        short.append(blob[k])
    var other = f.flags.to_bytes()
    s.check(raises_restore(flipped) and raises_restore(short) and raises_restore(other), "flipped byte, truncated blob, foreign blob raise")

    # ---- level transition -----------------------------------------------------------------------------
    var d = LevelDirector([1, 2, 3])
    var lg = ObjectiveLog()
    _ = lg.add(EV_TALK, 2, List[Int]())
    _ = lg.add(EV_CELL_IN, 1, List[Int]())
    var unknown = False
    try:
        d.request(9, Vec3(0, 0, 0, 0), 0)
    except:
        unknown = True
    d.request(2, Vec3(4, 1, 0, 0), 10)
    var cmds = d.take_commands()
    d.post(lg, EV_TALK)
    d.post(lg, EV_TALK)
    var held_progress = lg.objs[0].progress
    var refused = False
    try:
        _ = checked_checkpoint(d, f, sc)
    except:
        refused = True
    var twice = False
    try:
        d.request(3, Vec3(0, 0, 0, 0), 11)
    except:
        twice = True
    var bag_before = f.inventories[0].count_of(0)
    sc = scene()  # the host rebuilt the world for level 2
    d.loaded(2, lg)
    var wrong = False
    try:
        d.loaded(3, lg)
    except:
        wrong = True
    var cells: List[CellEvent] = [CellEvent(12, 7, EV_LOAD, 3), CellEvent(12, 8, EV_UNLOAD, 0)]
    d.post_cells(lg, cells, EV_CELL_IN, EV_CELL_OUT)
    print("level: command", len(cmds), "level", cmds[0].level, " progress while loading", held_progress, " after load", lg.objs[0].progress, " current", d.current)
    s.check(unknown and len(cmds) == 1 and cmds[0].level == 2 and cmds[0].spawn[0] == 4, "unknown id raises; one LoadLevel command with the spawn")
    s.check(held_progress == 0 and lg.objs[0].done and lg.completed[0] == 0, "events held during the load, released on completion")
    s.check(refused and twice and wrong and d.can_save(), "no checkpoint or second request while loading; wrong level report raises")
    s.check(f.inventories[0].count_of(0) == bag_before and d.current == 2 and lg.objs[1].done, "inventory crosses the transition; cell loads arrive as events")

    # ---- dialogue -------------------------------------------------------------------------------------
    var fl = flow().flags.copy()
    var gate_obj = ObjectiveLog()
    _ = gate_obj.add(EV_FLAG + 1, 1, List[Int]())  # flag 1 = gate_open
    var g = DialogueGraph()
    var ask = g.node(loc_id("npc.guard"), loc_id("guard.halt"))
    g.choice(ask, loc_id("guard.show_pass"), 1, eff=EFF_SET, eff_flag=1, eff_value=1)
    g.choice(ask, loc_id("guard.bribe"), 1, cmp=CMP_GE, cmp_flag=0, cmp_value=10, eff=EFF_ADD, eff_flag=0, eff_value=-10)
    g.choice(ask, loc_id("guard.leave"), -1)
    var through = g.node(loc_id("npc.guard"), loc_id("guard.pass"))
    g.choice(through, loc_id("guard.thanks"), -1, cmp=CMP_EQ, cmp_flag=1, cmp_value=1)
    g.validate(fl)
    var st = g.start(ask)
    var poor = len(g.available(st, fl))
    fl.set(0, 12)
    var rich = len(g.available(st, fl))
    _ = fl.drain()
    var closed = False
    try:
        g.choose(st, fl, 3)  # node 1's choice while at node 0
    except:
        closed = True
    g.choose(st, fl, 1)  # bribe
    var gold_after = fl.get(0)
    var thanks_closed = len(g.available(st, fl)) == 0
    var bribe_flags = on_flag_changes(gate_obj, fl, EV_FLAG)
    var shut = not gate_obj.objs[0].done
    var st2 = g.start(ask)
    g.choose(st2, fl, 0)  # show pass: gate_open = 1
    var posted = on_flag_changes(gate_obj, fl, EV_FLAG)
    g.choose(st2, fl, 3)
    var ended = False
    try:
        g.choose(st2, fl, 3)
    except:
        ended = True
    var bad = DialogueGraph()
    _ = bad.node(1, 2)
    bad.choice(0, 3, 5)
    var caught = False
    try:
        bad.validate(fl)
    except:
        caught = True
    print("dialogue: open choices at 5 gold", poor, " at 12 gold", rich, " gold after bribe", gold_after, " flag events", bribe_flags, posted, " gate objective done", gate_obj.objs[0].done)
    s.check(poor == 2 and rich == 3 and gold_after == 2, "bribe needs 10 gold and costs it")
    s.check(thanks_closed and bribe_flags == 1 and shut, "without the pass the gate stays shut")
    s.check(posted == 1 and gate_obj.objs[0].done and st2.done, "show pass -> gate_open -> objective via flag events")
    s.check(closed and ended and caught, "wrong-node choice, choice after the end, missing node raise")

    # ---- recorder with flow state ---------------------------------------------------------------------
    var live = SimState(scene(), CharacterController(Vec3(3, 0.92, 3, 0)), SplitMix64.seeded(7))
    live.flow = flow()
    var rec = Recorder(50)
    for t in range(240):
        var btn = UInt32(2) if t % 15 == 3 else UInt32(0)
        rec.step(live, InputFrame(t, Vec3(0.5, 0, 0, 0), 0, btn), DT, G)
    var div = first_divergence(rec, DT, G)
    var a = seek(rec, 130, DT, G)
    var b = replay_from_start(rec, 130, DT, G)
    var bag_a = a.flow.inventories[0].count_of(0)
    var seek_same = checksum(a) == checksum(b) and bag_a == b.flow.inventories[0].count_of(0) and same_flow(a.flow, b.flow)
    rec.inputs[100].buttons = 2
    var div2 = first_divergence(rec, DT, G)
    print("recorder: bag at 240", live.flow.inventories[0].count_of(0), " at 130", bag_a, " first divergence", div, " after editing tick 100", div2)
    s.check(div == -1 and seek_same and bag_a > 0, "flow state replays; seek == full re-run, bag included")
    s.check(div2 == 100, "an extra pickup in the inputs diverges at its tick")
    s.finish()
