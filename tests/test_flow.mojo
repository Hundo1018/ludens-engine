# tier: component
"""Game flow: state stack, flags, objectives, inventory, loot (ROADMAP 17.72).

  1. Ordinary: Playing -> Paused -> Menu pushed and popped in order, each
     state deciding what ticks (paused: events only); flags report only
     real changes, booleans normalise; a quest (collect 3 parts, then talk;
     optional 5 rats) completes in event order and an event before an
     objective is unlocked does not count; inventory stacks fill before new
     slots and return what does not fit; loot rolls repeat per seed.
  2. Integration: linear and indexed objective dispatch complete the same
     objectives in the same order over a seeded 5000-event run with 300
     objectives; a checkpoint (flags bytes + objective log + inventory
     copies) restored after a "death" gives the same state; 100000 loot
     draws follow the weights within 1 % and a weight-0 entry never drops.
  3. Extreme: popping an empty stack raises; a prerequisite on a later
     objective (a cycle) raises; loading a flag whose kind changed raises;
     an empty loot table drops nothing; removing more than held takes what
     there is.
"""

from harness.runner import Suite
from scheduler.rng import Pcg32
from gameplay.flow import FlowStack, Flags, TICK_SIM, TICK_TIMERS, TICK_EVENTS, TICK_ALL, FLAG_INT, FLAG_BOOL
from gameplay.objectives import ObjectiveLog, DISPATCH_LINEAR, DISPATCH_INDEXED
from gameplay.inventory import Inventory, LootTable

comptime PLAYING = 1
comptime PAUSED = 2
comptime MENU = 3
comptime EV_PART = 1
comptime EV_TALK = 2
comptime EV_RAT = 3


def main() raises:
    var s = Suite("flow")

    # ---- flow stack ------------------------------------------------------------------------------
    var fs = FlowStack()
    fs.push(PLAYING, TICK_ALL)
    var play_sim = fs.ticks(TICK_SIM)
    fs.push(PAUSED, TICK_EVENTS)
    var paused_sim = fs.ticks(TICK_SIM)
    var paused_ev = fs.ticks(TICK_EVENTS)
    fs.push(MENU, TICK_EVENTS)
    _ = fs.pop()
    var back = fs.top()
    _ = fs.pop()
    s.check(play_sim and not paused_sim and paused_ev and back == PAUSED and fs.top() == PLAYING and fs.ticks(TICK_TIMERS), "pause / menu push and pop in order, each deciding what ticks")
    var e = FlowStack()
    var raised = False
    try:
        _ = e.pop()
    except:
        raised = True
    s.check(raised, "popping an empty stack raises")

    # ---- flags --------------------------------------------------------------------------------------
    var fl = Flags()
    var door = fl.declare("door_open", FLAG_BOOL)
    var coins = fl.declare("coins", FLAG_INT, 10)
    fl.set(door, 5)
    fl.set(door, 1)
    fl.set(coins, 10)
    fl.set(coins, 12)
    var ch = fl.drain()
    s.check(len(ch) == 2 and ch[0] == door and ch[1] == coins and fl.get(door) == 1, "only real changes are reported; booleans normalise")
    var fl2 = Flags()
    fl2.load(fl.to_bytes())
    s.check(fl2.to_bytes() == fl.to_bytes(), "flags round-trip by name")
    var fl3 = Flags()
    _ = fl3.declare("coins", FLAG_BOOL)
    raised = False
    try:
        fl3.load(fl.to_bytes())
    except:
        raised = True
    s.check(raised, "loading a flag whose kind changed raises")

    # ---- objectives ---------------------------------------------------------------------------------
    var q = ObjectiveLog()
    var parts = q.add(EV_PART, 3, List[Int]())
    var talk = q.add(EV_TALK, 1, [parts])
    var rats = q.add(EV_RAT, 5, List[Int](), True)
    q.on_event(EV_TALK)  # too early: talk is locked
    q.on_event(EV_PART)
    q.on_event(EV_RAT, 2)
    q.on_event(EV_PART, 2)
    var mid = q.all_required_done()
    q.on_event(EV_TALK)
    print("  quest: completion order", q.completed[0], q.completed[1] if len(q.completed) > 1 else -1, " rats", q.objs[rats].progress, "/ 5")
    s.check(len(q.completed) == 2 and q.completed[0] == parts and q.completed[1] == talk and not mid and q.all_required_done() and not q.objs[rats].done, "quest completes in event order; locked events do not count; optional does not block")
    raised = False
    try:
        _ = q.add(EV_RAT, 1, [7])
    except:
        raised = True
    s.check(raised, "a prerequisite on a later objective (cycle) raises")

    var lin = ObjectiveLog(DISPATCH_LINEAR)
    var idx = ObjectiveLog(DISPATCH_INDEXED)
    var rng = Pcg32.seeded(99)
    for i in range(300):
        var et = Int(rng.next_u32() % 20)
        var tg = 1 + Int(rng.next_u32() % 6)
        var pre = List[Int]()
        if i > 0 and rng.next_u32() % 3 == 0:
            pre.append(Int(rng.next_u32() % UInt32(i)))
        _ = lin.add(et, tg, pre)
        _ = idx.add(et, tg, pre)
    for _ in range(5000):
        var et = Int(rng.next_u32() % 20)
        lin.on_event(et)
        idx.on_event(et)
    var same = len(lin.completed) == len(idx.completed)
    for i in range(min(len(lin.completed), len(idx.completed))):
        if lin.completed[i] != idx.completed[i]:
            same = False
    print("  300 objectives, 5000 events: linear completed", len(lin.completed), " indexed", len(idx.completed), " same order", same)
    s.check(same and len(lin.completed) > 100, "linear and indexed dispatch: same completions, same order")

    # ---- inventory and loot ---------------------------------------------------------------------------
    var inv = Inventory(4, [10, 1, 99])
    var left = inv.add(0, 25)
    var left2 = inv.add(1, 3)
    print("  inventory: 25 of item 0 (stack 10) leaves", left, "; 3 of item 1 (stack 1) leaves", left2)
    s.check(left == 0 and left2 == 2 and inv.count_of(0) == 25 and inv.count_of(1) == 1, "stacks fill then new slots; overflow is returned")
    var took = inv.remove(0, 40)
    s.check(took == 25 and inv.count_of(0) == 0, "removing more than held takes what there is")

    var loot = LootTable()
    loot.add(0, 70)
    loot.add(1, 25, 2, 4)
    loot.add(2, 5)
    loot.add(3, 0)
    var r1 = loot.roll(42, 50)
    var r2 = loot.roll(42, 50)
    var rep = True
    for i in range(50):
        if r1[i][0] != r2[i][0] or r1[i][1] != r2[i][1]:
            rep = False
    s.check(rep, "same seed: same drops")
    var big = loot.roll(7, 100000)
    var cnt = List[Int](length=4, fill=0)
    var cmin = 99
    var cmax = 0
    for d in big:
        cnt[d[0]] += 1
        if d[0] == 1:
            cmin = min(cmin, d[1])
            cmax = max(cmax, d[1])
    print("  100000 draws: shares", Float64(cnt[0]) / 1000.0, Float64(cnt[1]) / 1000.0, Float64(cnt[2]) / 1000.0, "% (70 / 25 / 5), weight 0:", cnt[3], " item 1 counts", cmin, "..", cmax)
    s.check(abs(cnt[0] - 70000) < 1000 and abs(cnt[1] - 25000) < 1000 and abs(cnt[2] - 5000) < 1000 and cnt[3] == 0 and cmin == 2 and cmax == 4, "weights within 1 %, weight 0 never, counts in range")
    var none = LootTable()
    s.check(len(none.roll(1, 10)) == 0, "empty table drops nothing")

    # ---- checkpoint -----------------------------------------------------------------------------------
    var cp_flags = fl.to_bytes()
    var cp_log = q.copy()
    var cp_inv = inv.copy()
    fl.set(coins, 0)
    q.on_event(EV_RAT, 5)
    _ = inv.add(2, 50)
    var rf = Flags()
    rf.load(cp_flags)
    var rq = cp_log.copy()
    var ri = cp_inv.copy()
    s.check(rf.get(rf.find("coins")) == 12 and not rq.objs[rats].done and ri.count_of(2) == 0, "checkpoint restored after a death: flags, objectives, inventory as saved")
    s.finish()
