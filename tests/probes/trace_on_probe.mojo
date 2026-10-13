"""Run by tests/test_trace_runtime.mojo with `-D LUDENS_TRACE` (ROADMAP
17.80): the run-time switch, ring mode, counter tracks and the
TRACE_DROPPED counter on a real solver step. Exits non-zero on failure."""

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
    s.finish()
