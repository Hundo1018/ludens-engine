from harness.runner import Suite
from scheduler.fsm import StateMachine


def _eq_list(a: List[Int], b: List[Int]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def main() raises:
    var s = Suite("fsm")

    # events
    comptime GO = 0
    comptime STOP = 1
    comptime SPRINT = 2
    comptime JUMP = 3
    comptime LAND = 4

    # ---- 1. Flat FSM: idle -> walk -> run -> idle ----
    var m = StateMachine()
    var idle = m.add_state()
    var walk = m.add_state()
    var run = m.add_state()
    m.add_transition(idle, GO, walk)
    m.add_transition(walk, SPRINT, run)
    m.add_transition(run, STOP, idle)
    m.add_transition(walk, STOP, idle)
    m.start(idle)
    s.check(m.is_in(idle), "starts in idle")
    s.check(m.fire(GO) and m.is_in(walk), "idle -GO-> walk")
    s.check(m.fire(SPRINT) and m.is_in(run), "walk -SPRINT-> run")
    s.check(not m.fire(GO), "unknown event in run is a no-op")
    s.check(m.is_in(run), "still in run after no-op")
    s.check(m.fire(STOP) and m.is_in(idle), "run -STOP-> idle")

    # ---- 2. HSM: grounded{idle,walk,run} vs airborne{jump,fall} ----
    var h = StateMachine()
    var grounded = h.add_state()
    var g_idle = h.add_state(grounded)
    var g_walk = h.add_state(grounded)
    var airborne = h.add_state()
    var a_jump = h.add_state(airborne)
    var a_fall = h.add_state(airborne)
    h.set_initial(grounded, g_idle)
    h.set_initial(airborne, a_jump)
    # a JUMP from anywhere grounded goes airborne (transition on the parent)
    h.add_transition(grounded, JUMP, airborne)
    h.add_transition(airborne, LAND, grounded)
    h.add_transition(g_idle, GO, g_walk)

    h.start(grounded)
    s.check(h.is_in(grounded) and h.is_in(g_idle), "entering composite -> initial child (idle)")
    s.check(h.fire(GO) and h.is_in(g_walk), "g_idle -GO-> g_walk")
    s.check(h.is_in(grounded), "still 'in' grounded while in g_walk")

    # JUMP is defined on `grounded`; firing it while in the g_walk LEAF must
    # bubble up to the parent transition.
    var fired = h.fire(JUMP)
    s.check(fired and h.is_in(airborne) and h.is_in(a_jump),
            "JUMP bubbles from leaf to parent, enters airborne.initial")
    s.check(not h.is_in(grounded), "no longer in grounded")

    # exit/enter bookkeeping on that JUMP: exited g_walk then grounded,
    # entered airborne then a_jump.
    var want_exit = List[Int]()
    want_exit.append(g_walk)
    want_exit.append(grounded)
    var want_enter = List[Int]()
    want_enter.append(airborne)
    want_enter.append(a_jump)
    s.check(_eq_list(h.exited, want_exit), "exited g_walk then grounded")
    s.check(_eq_list(h.entered, want_enter), "entered airborne then a_jump")

    # ---- 3. Shallow history: grounded resumes its last child ----
    var hh = StateMachine()
    var gr = hh.add_state(-1, -1, True)  # composite WITH history
    var gi = hh.add_state(gr)
    var gw = hh.add_state(gr)
    var air = hh.add_state()
    hh.set_initial(gr, gi)
    hh.add_transition(gi, GO, gw)
    hh.add_transition(gr, JUMP, air)
    hh.add_transition(air, LAND, gr)
    hh.start(gr)
    _ = hh.fire(GO)  # now in gw
    s.check(hh.is_in(gw), "history machine walked to gw")
    _ = hh.fire(JUMP)  # to air (remembers gw)
    s.check(hh.is_in(air), "jumped to air")
    _ = hh.fire(LAND)  # back to grounded -> should RESUME gw, not gi
    s.check(hh.is_in(gw), "history resumes last child (gw, not initial gi)")

    # ---- 4. Determinism: same events from same start -> same path ----
    var seq = List[Int]()
    seq.append(GO)
    seq.append(JUMP)
    seq.append(LAND)
    seq.append(JUMP)

    def _run_path(mut sm: StateMachine, events: List[Int]) -> List[Int]:
        var path = List[Int]()
        for i in range(len(events)):
            _ = sm.fire(events[i])
            path.append(sm.current)
        return path^

    var m1 = StateMachine()
    var m2 = StateMachine()
    # build the same HSM twice
    for build in range(2):
        var sm = StateMachine()
        var G = sm.add_state(-1, -1, True)
        var Gi = sm.add_state(G)
        var Gw = sm.add_state(G)
        var A = sm.add_state()
        sm.set_initial(G, Gi)
        sm.add_transition(Gi, GO, Gw)
        sm.add_transition(G, JUMP, A)
        sm.add_transition(A, LAND, G)
        sm.start(G)
        if build == 0:
            m1 = sm^
        else:
            m2 = sm^
    var p1 = _run_path(m1, seq)
    var p2 = _run_path(m2, seq)
    s.check(_eq_list(p1, p2), "identical event sequences -> identical paths")

    s.finish()
