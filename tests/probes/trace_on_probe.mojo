"""Run by tests/test_trace_runtime.mojo with `-D LUDENS_TRACE` (ROADMAP
17.80): the run-time switch, ring mode, counter tracks and the
TRACE_DROPPED counter on a real solver step, and the island fan-out as
worker tracks. Exits non-zero on failure."""

from harness.runner import Suite
from diag.level import TRACE_ON
from diag.trace import TraceBuffer
from diag.counters import TRACE_DROPPED
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig

comptime DT: Real = 1.0 / 60.0


def main() raises:
    var s = Suite("trace_on_probe")
    s.check(TRACE_ON, "built with -D LUDENS_TRACE")
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 5, 0.5, 5)), Vec3(5, 0.5, 5, 0), True)
    for k in range(4):
        _ = sc.add(QuatBody6.at_rest(Vec3(Real(k), 0.3, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    var cfg = SolverConfig()
    for _ in range(5):
        sc.step(DT, Vec3(0, -9.8, 0, 0), cfg)
    var on = len(sc.trace.events)
    sc.trace.enabled = False
    for _ in range(5):
        sc.step(DT, Vec3(0, -9.8, 0, 0), cfg)
    var off = len(sc.trace.events)
    print("  spans after 5 traced steps", on, " after 5 more with enabled = False", off)
    s.check(on > 0 and off == on, "run-time switch: no spans while disabled")
    sc.trace.enabled = True

    # toggling inside a span keeps nesting balanced
    var t = TraceBuffer(16)
    t.begin("outer")
    t.enabled = False
    t.begin("hidden")
    t.enabled = True
    t.end()  # closes "hidden" (opened while disabled): records nothing
    t.end()  # closes "outer"
    s.check(len(t.events) == 1 and t.events[0].name == "outer", "toggle mid-span: outer recorded once, hidden dropped silently")

    # ring mode keeps the newest
    var r = TraceBuffer(4)
    r.ring = True
    for i in range(10):
        r.begin("s" + String(i))
        r.end()
    var ord = r.ordered()
    print("  ring of 4 after 10 spans: oldest", r.events[ord[0]].name, " newest", r.events[ord[3]].name, " dropped", r.dropped)
    s.check(r.events[ord[0]].name == "s6" and r.events[ord[3]].name == "s9" and r.dropped == 6, "ring mode: keeps s6..s9")

    # counter track in the export
    var js = sc.trace.to_chrome_json()
    s.check('"ph":"C"' in js and "contact_manifolds" in js, "chrome json has counter (C) events")

    # small buffer: drops reach the shared counters
    var sm = ContactScene6[QuatBody6]()
    sm.trace = TraceBuffer(8)
    _ = sm.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 5, 0.5, 5)), Vec3(5, 0.5, 5, 0), True)
    for _ in range(10):
        sm.step(DT, Vec3(0, -9.8, 0, 0), cfg)
    print("  8-slot trace, 10 steps: dropped", sm.trace.dropped, " TRACE_DROPPED counter", sm.counters.get(TRACE_DROPPED))
    s.check(sm.trace.dropped > 0 and Int(sm.counters.get(TRACE_DROPPED)) == sm.trace.dropped, "TRACE_DROPPED counts the trace's drops")

    # 17.80 (c): island fan-out as worker tracks. 40 separate two-box
    # stacks, island-parallel; every island becomes one "island" span on a
    # lane (tid 1 + lane) with no two spans of a lane overlapping; a serial
    # dispatch packs them all onto one lane.
    var isl = ContactScene6[QuatBody6]()
    _ = isl.add(QuatBody6.at_rest(Vec3(40, -0.5, 0, 0), Inertia3.box(1, 50, 0.5, 5)), Vec3(50, 0.5, 5, 0), True)
    for k in range(40):
        for j in range(2):
            _ = isl.add(QuatBody6.at_rest(Vec3(Real(k) * 2, 0.25 + 0.51 * Real(j), 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    var pc = SolverConfig()
    pc.parallel = True
    isl.trace.capacity = 4096
    isl.step(1.0 / 60.0, Vec3(0, -9.8, 0, 0), pc)
    var lanes = List[Int]()
    var spans = 0
    var overlap = False
    for i in range(len(isl.trace.events)):
        ref e = isl.trace.events[i]
        if e.name != "island":
            continue
        spans += 1
        if e.tid not in lanes:
            lanes.append(e.tid)
        for j in range(i):
            ref f = isl.trace.events[j]
            if f.name == "island" and f.tid == e.tid and f.t_begin_ns < e.t_end_ns and e.t_begin_ns < f.t_end_ns:
                overlap = True
    print("island spans", spans, " lanes", len(lanes))
    s.check(spans == 40 and len(lanes) >= 1 and not overlap and "island" in isl.trace.to_chrome_json(), "40 islands as spans on non-overlapping worker lanes, exported")
    var b: List[Int] = [0, 10, 20, 5]
    var e2: List[Int] = [10, 20, 30, 15]
    var lt = TraceBuffer(capacity=16)
    var nl = lt.add_lanes("w", b, e2)
    s.check(nl == 2 and lt.events[1].tid == 2 and lt.events[2].tid == 1, "packing: [0,10] [5,15] [10,20] [20,30] need 2 lanes")
    s.finish()
