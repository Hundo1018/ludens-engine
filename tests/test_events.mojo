# tier: component  (override: the EventChannel seam -- Channel vs PushChannel -- lives entirely inside `scheduler`; the mechanical rule's one-hop span picks up `diag` only because `scheduler/events.mojo` itself imports `diag.counters`, not because this test exercises a second package)
"""`EventChannel` seam parity (17.38): `Channel` (pull, production) vs
`PushChannel` (fan-out, comparison partner) must deliver IDENTICAL
per-reader sequences for the same script of `send`/`register_reader`/`read`/
`update` calls -- the property 17.39 replay and 17.16 rollback need.
Ordinary cases run per-implementation via a `comptime for` over the two
(matching `docs/design/wave-a-services.md` 17.35's precedent for this same
"comptime for over the seam" instruction); the parity and determinism checks
drive both implementations from the same deterministic script directly.

Crossing the trait's associated-type boundary (`EventChannel.Payload`) with a
concrete local event struct inside a generic function needs `rebind_var`
(confirmed by probe against a parse error otherwise -- a bare
`EventChannel[E]` bracket on the TRAIT itself is rejected: "trait
declarations do not support parameters"; the event type has to ride on the
struct's own parameter instead, which is why the trait exposes it as an
associated `comptime Payload`)."""

from harness.runner import Suite
from diag.counters import Counters, EVENT_DROPPED_UNREAD
from scheduler.events import EventChannel, Channel, PushChannel


@fieldwise_init
struct Evt(Copyable, Deinitable, Movable):
    var seq: Int


def _mk[C: EventChannel](seq: Int) -> C.Payload:
    return rebind_var[C.Payload](Evt(seq))


def _send_range[C: EventChannel](mut ch: C, lo: Int, hi: Int):
    for k in range(lo, hi):
        ch.send(_mk[C](k))


def _seqs[C: EventChannel](mut xs: List[C.Payload]) -> List[Int]:
    var out = List[Int]()
    for i in range(len(xs)):
        out.append(rebind_var[Evt](xs[i].copy()).seq)
    return out^


def _eq_ints(a: List[Int], b: List[Int]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _run_multi_reader_script[C: EventChannel]() raises -> List[List[Int]]:
    """3 readers against ONE script: `r0` registered before anything (sees
    every event), `r1` registered mid-period (after 3 sends -- "reader
    registered mid-frame" extreme case, documented in
    `scheduler/events.mojo`), `r2` registered after an `update()` boundary
    (sees only what comes after it). All three drain once, at the end.
    Deterministic and pure in the sense `test_events_gameloop.mojo`'s
    replay check needs: same calls in, same per-reader lists out."""
    var ch = C()
    var r0 = ch.register_reader()
    _send_range[C](ch, 0, 3)  # seq 0,1,2
    var r1 = ch.register_reader()  # mid-frame: only >=3
    _send_range[C](ch, 3, 6)  # seq 3,4,5
    ch.update()
    _send_range[C](ch, 6, 9)  # seq 6,7,8
    var r2 = ch.register_reader()  # registered after 9 sends: only later
    _send_range[C](ch, 9, 11)  # seq 9,10

    var o0 = List[C.Payload]()
    ch.read(r0, o0)
    var o1 = List[C.Payload]()
    ch.read(r1, o1)
    var o2 = List[C.Payload]()
    ch.read(r2, o2)

    var out = List[List[Int]]()
    out.append(_seqs[C](o0))
    out.append(_seqs[C](o1))
    out.append(_seqs[C](o2))
    return out^


# ---------------------------------------------------------------- ORDINARY
def _ordinary[C: EventChannel](mut s: Suite, tag: String) raises:
    var res = _run_multi_reader_script[C]()
    s.check(
        _eq_ints(res[0], [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]),
        tag + ": reader registered first sees every event, in send order",
    )
    s.check(
        _eq_ints(res[1], [3, 4, 5, 6, 7, 8, 9, 10]),
        tag + ": reader registered mid-frame sees only later events",
    )
    s.check(
        _eq_ints(res[2], [9, 10]),
        tag + ": reader registered after 9 sends sees only its 2 later events",
    )


def _determinism[C: EventChannel](mut s: Suite, tag: String) raises:
    """Two runs of the identical send script -> bit-identical reader streams
    (the property 17.39 replay and 17.16 rollback need)."""
    var a = _run_multi_reader_script[C]()
    var b = _run_multi_reader_script[C]()
    var same = len(a) == len(b)
    if same:
        for i in range(len(a)):
            if not _eq_ints(a[i], b[i]):
                same = False
    s.check(same, tag + ": replaying the same send script twice is bit-identical")


# ------------------------------------------------------------- INTEGRATION
# (component tier here: the seam lives entirely inside `scheduler`. The
# integration cases -- FixedLoop-driven frames, a real ContactScene6 stack --
# are separate files, `tests/test_events_gameloop.mojo` and
# `tests/test_events_contacts.mojo`, so this file's span stays 1 package.)
def _check_parity(mut s: Suite) raises:
    var pull = _run_multi_reader_script[Channel[Evt]]()
    var push = _run_multi_reader_script[PushChannel[Evt]]()
    var same = len(pull) == len(push)
    if same:
        for i in range(len(pull)):
            if not _eq_ints(pull[i], push[i]):
                same = False
    s.check(same, "parity: pull and push agree on all 3 readers for the same script")


# ---------------------------------------------------------------- EXTREME
def _extreme_zero_readers(mut s: Suite) raises:
    var ch = Channel[Evt]()
    ch.send(Evt(1))
    ch.update()
    ch.update()
    ch.update()
    s.eqi(
        Int(ch.dropped_unread), 0,
        "0 readers: nothing counted as dropped (no reader existed to miss it)",
    )

    var chp = PushChannel[Evt]()
    chp.send(Evt(1))  # no subscribers: send() must not crash on an empty fan-out
    s.check(True, "0 readers (push): send with no subscribers does not crash")


def _extreme_invalid_handle(mut s: Suite) raises:
    var ch = Channel[Evt]()
    var out = List[Evt]()
    var raised = False
    try:
        ch.read(99, out)
    except:
        raised = True
    s.check(raised, "pull: reading an unknown reader handle raises")

    var chp = PushChannel[Evt]()
    var outp = List[Evt]()
    var raised_p = False
    try:
        chp.read(99, outp)
    except:
        raised_p = True
    s.check(raised_p, "push: reading an unknown reader handle raises")


def _extreme_dropped_unread(mut s: Suite) raises:
    """A reader that never reads: its events keep aging out of the double
    buffer, and every one of them is counted -- `docs/ARCHITECTURE.md` §2's
    "capacity/budget overflow -> diag counter, never silently lose the
    count" rule, applied to event retention."""
    var ch = Channel[Evt]()
    var r_lazy = ch.register_reader()
    _ = r_lazy  # registered, never read again
    var r_ok = ch.register_reader()
    for period in range(5):
        _send_range[Channel[Evt]](ch, period * 10, period * 10 + 3)
        ch.update()
        var out = List[Evt]()
        ch.read(r_ok, out)  # keeps up every period: never itself dropped

    var counters = Counters()
    ch.sync_counters(counters)
    s.check(
        counters.get(EVENT_DROPPED_UNREAD) > 0,
        "a reader that never reads is counted via diag.counters.EVENT_DROPPED_UNREAD",
    )

    # sync_counters resets the local tally, so a second call right after adds nothing.
    var before = counters.get(EVENT_DROPPED_UNREAD)
    ch.sync_counters(counters)
    s.eqi(
        Int(counters.get(EVENT_DROPPED_UNREAD)), Int(before),
        "sync_counters resets the local tally: no double count on repeated calls",
    )


def _extreme_million_events(mut s: Suite) raises:
    var ch = Channel[Evt]()
    var r = ch.register_reader()
    for k in range(1_000_000):
        ch.send(Evt(k))
    var out = List[Evt]()
    ch.read(r, out)
    s.eqi(len(out), 1_000_000, "1e6 events sent in one frame are all delivered")
    if len(out) == 1_000_000:
        s.eqi(out[0].seq, 0, "1e6 events: first seq preserved")
        s.eqi(out[999_999].seq, 999_999, "1e6 events: last seq preserved, in order")


def main() raises:
    var s = Suite("events")

    comptime for i in range(2):
        comptime if i == 0:
            _ordinary[Channel[Evt]](s, "pull")
            _determinism[Channel[Evt]](s, "pull")
        else:
            _ordinary[PushChannel[Evt]](s, "push")
            _determinism[PushChannel[Evt]](s, "push")

    _check_parity(s)

    _extreme_zero_readers(s)
    _extreme_invalid_handle(s)
    _extreme_dropped_unread(s)
    _extreme_million_events(s)

    s.finish()
