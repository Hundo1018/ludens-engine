"""Contact events: began/stay/ended diff over two frames' contact sets
(audit cluster 2).

Pure set logic over `(a, b, feat)` keys -- no `Body6`, no `ColliderSet`, not
even collision geometry: whoever produced this step's contact set (brute
loop, any `BroadPhase` backend, a sensor overlap pass) hands over the keys
that touched, and this module says which of them are new, which persisted,
and which stopped. That is what lets sensors report overlap without ever
touching the impulse solver, and what will let 17.13 queries watch overlaps
without depending on physics at all.
"""

comptime EV_BEGAN = 0
comptime EV_STAY = 1
comptime EV_ENDED = 2


@fieldwise_init
struct ContactEvent(Copyable, ImplicitlyCopyable, Movable):
    """One transition in the contact set. `kind` is `EV_BEGAN` / `EV_STAY` /
    `EV_ENDED`.

    `feat` is the triangle index for mesh contacts and 0 otherwise, the same
    sub-key the warm-start cache uses: a crate sliding along a floor genuinely
    begins and ends contact with each triangle in turn, and collapsing that to
    one event per body pair would report a single unbroken touch."""

    var a: Int
    var b: Int
    var feat: Int
    var kind: Int


def pack_key(a: Int, b: Int, feat: Int) -> Int:
    """(body, body, feature) packed into one Int so the frame-to-frame diff is
    a sorted-list merge. 21 bits each: 2M bodies, 2M triangles per mesh."""
    return (a << 42) | (b << 21) | feat


def _unpack_event(key: Int, kind: Int) -> ContactEvent:
    return ContactEvent(key >> 42, (key >> 21) & 0x1FFFFF, key & 0x1FFFFF, kind)


def diff_events(cur: List[Int], prev: List[Int], mut out: List[ContactEvent]):
    """Both `cur` and `prev` must already be sorted ascending (plain `sort()`
    on Int is a total order, so any correct sort gives the identical merge --
    the caller picks how; see `physics.solver6.ContactScene6._emit_events`).

    A sorted-merge diff: a key present only in `cur` began, a key present
    only in `prev` ended, a key in both stayed. Working from the derived
    current set rather than an incrementally maintained one means nothing
    has to be invalidated when a body is removed -- the solver already knows
    exactly which contacts exist this step, and `prev` is last step's answer
    to the same question."""
    var i = 0
    var j = 0
    while i < len(cur) or j < len(prev):
        if j >= len(prev) or (i < len(cur) and cur[i] < prev[j]):
            out.append(_unpack_event(cur[i], EV_BEGAN))
            i += 1
        elif i >= len(cur) or cur[i] > prev[j]:
            out.append(_unpack_event(prev[j], EV_ENDED))
            j += 1
        else:
            out.append(_unpack_event(cur[i], EV_STAY))
            i += 1
            j += 1
