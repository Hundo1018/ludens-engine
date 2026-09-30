# tier: component
"""`TimerQueue` seam parity (17.35): `TimerHeap` (array binary min-heap) vs
`TimerWheel` (two-level ring) must produce IDENTICAL `(due_tick, seq)`-ordered
fired sequences for the same script of `schedule`/`cancel`/`advance` calls --
the property 17.39 replay and 17.16 rollback need. Ordinary and extreme cases
run per-backend via a `comptime for` over the two implementations (matching
`docs/design/wave-a-services.md` 17.35's "comptime for" instruction); the
parity check itself drives both backends from the same seeded script in
lock-step."""

from harness.runner import Suite
from scheduler.timers import TimerQueue, TimerHeap, TimerWheel, TimerFire, TimerHandle
from scheduler.rng import SplitMix64, Rng, range_i

comptime _QUEUE_COUNT = 2


def _ordinary[Q: TimerQueue](mut s: Suite, tag: String) raises:
    # a handful of due ticks, including a tie -- fired order must be
    # (due_tick, schedule sequence): total and deterministic.
    var q = Q()
    var h_a = q.schedule(3, 100)  # seq 0, due 3
    var h_b = q.schedule(1, 200)  # seq 1, due 1
    var h_c = q.schedule(3, 300)  # seq 2, due 3 -- ties h_a, later seq
    _ = h_a
    _ = h_b
    _ = h_c
    var fired = List[TimerFire]()
    q.advance(5, fired)
    s.eqi(len(fired), 3, tag + " ordinary: 3 fired")
    if len(fired) == 3:
        s.eqi(fired[0].id, 200, tag + " ordinary: due=1 first")
        s.eqi(fired[1].id, 100, tag + " ordinary: due=3 seq0 next")
        s.eqi(fired[2].id, 300, tag + " ordinary: due=3 seq2 last (tie order)")
        s.eqi(fired[0].due_tick, 1, tag + " ordinary: due_tick recorded")

    # repeat_every fires more than once within a single advance() call
    var q2 = Q()
    _ = q2.schedule(1, 7, repeat_every=2)
    var fired2 = List[TimerFire]()
    q2.advance(8, fired2)  # due 1, 3, 5, 7 -> 4 fires
    s.eqi(len(fired2), 4, tag + " repeat: fires 4 times in 8 ticks")

    # current_tick tracks total ticks advanced
    s.eqi(q2.current_tick(), 8, tag + " current_tick after advance")

    # invalid caller input -> raise (error policy: public API boundary)
    var q3 = Q()
    var raised_after = False
    try:
        _ = q3.schedule(-1, 1)
    except:
        raised_after = True
    s.check(raised_after, tag + " negative after_ticks raises")

    var raised_repeat = False
    try:
        _ = q3.schedule(1, 1, repeat_every=-1)
    except:
        raised_repeat = True
    s.check(raised_repeat, tag + " negative repeat_every raises")

    var raised_advance = False
    try:
        var f = List[TimerFire]()
        q3.advance(-1, f)
    except:
        raised_advance = True
    s.check(raised_advance, tag + " negative n_ticks raises")


def _extreme[Q: TimerQueue](mut s: Suite, tag: String) raises:
    # timer scheduled for "tick 0" (after_ticks=0) fires on the very next
    # advance, not never and not immediately without an advance.
    var q0 = Q()
    _ = q0.schedule(0, 42)
    var f0 = List[TimerFire]()
    q0.advance(1, f0)
    s.eqi(len(f0), 1, tag + " after_ticks=0 fires on first advance")

    # cancel inside the same advance window: cancel BEFORE the advance() call
    # in which the timer would have fired -- must not fire.
    var q1 = Q()
    var h = q1.schedule(1, 9)
    q1.cancel(h)
    var f1 = List[TimerFire]()
    q1.advance(3, f1)
    s.eqi(len(f1), 0, tag + " cancel before due advance -> no fire")

    # double cancel and cancel-after-fire are silent no-ops, not crashes.
    var q2 = Q()
    var h2 = q2.schedule(1, 1)
    q2.cancel(h2)
    q2.cancel(h2)  # double cancel
    var f2 = List[TimerFire]()
    q2.advance(2, f2)
    s.eqi(len(f2), 0, tag + " double cancel stays cancelled")

    var q3 = Q()
    var h3 = q3.schedule(1, 1)
    var f3 = List[TimerFire]()
    q3.advance(2, f3)
    s.eqi(len(f3), 1, tag + " fired once before late cancel")
    q3.cancel(h3)  # cancel after it already fired: no-op, no crash
    s.check(True, tag + " cancel-after-fire does not crash")

    # 1e6 timers due on the exact same tick.
    var q4 = Q()
    for i in range(1_000_000):
        _ = q4.schedule(10, i)
    var f4 = List[TimerFire]()
    q4.advance(11, f4)
    s.eqi(len(f4), 1_000_000, tag + " 1e6 timers same tick all fire")
    if len(f4) == 1_000_000:
        s.check(
            f4[0].handle.seq < f4[999_999].handle.seq,
            tag + " 1e6-same-tick fired in seq order",
        )


def _randomized[Q: TimerQueue](seed: UInt64) raises -> List[TimerFire]:
    var q = Q()
    var rng = SplitMix64.seeded(seed)
    var handles = List[TimerHandle]()
    var fired = List[TimerFire]()
    for step in range(500):
        var op = range_i(rng, 0, 3)
        if op == 0:
            var after = range_i(rng, 0, 30)
            var rep = 0
            if range_i(rng, 0, 4) == 0:
                rep = range_i(rng, 1, 6)
            handles.append(q.schedule(after, step, repeat_every=rep))
        elif op == 1 and len(handles) > 0:
            q.cancel(handles[range_i(rng, 0, len(handles))])
        else:
            q.advance(range_i(rng, 1, 5), fired)
    q.advance(200, fired)  # final drain
    return fired^


def _check_parity(mut s: Suite, seed: UInt64) raises:
    var a = _randomized[TimerHeap](seed)
    var b = _randomized[TimerWheel](seed)
    var same = len(a) == len(b)
    if same:
        for i in range(len(a)):
            if (
                a[i].due_tick != b[i].due_tick
                or a[i].handle.seq != b[i].handle.seq
                or a[i].id != b[i].id
            ):
                same = False
                break
    s.check(same, "parity heap==wheel seed " + String(seed))


def main() raises:
    var s = Suite("timers")

    comptime for i in range(_QUEUE_COUNT):
        comptime if i == 0:
            _ordinary[TimerHeap](s, "heap")
            _extreme[TimerHeap](s, "heap")
        else:
            _ordinary[TimerWheel](s, "wheel")
            _extreme[TimerWheel](s, "wheel")

    for seed in range(1, 13):
        _check_parity(s, UInt64(seed))

    s.finish()
