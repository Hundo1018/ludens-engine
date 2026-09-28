# tier: unit  (override: exercises physics.body_set alone; the physics.rigid6 import is just a concrete Body6 value type to instantiate the generic BodySet[QuatBody6] with, not a second module under test)
"""Body identity (ROADMAP 17.0g-1, audit F5): `BodyId` stable handles and
slot reuse on `BodySet`.

`BodySet.remove` is a programmer-error boundary (docs/ARCHITECTURE.md S2):
holding a `BodyId` past its body's removal and then using it to index into
`BodySet`'s lists is a bug, so that accessor path terminates via
`debug_assert` under `-D ASSERT=all` rather than raising -- verified with a
throwaway standalone probe during development (not committed here: an
assert terminates the process, which would abort this whole suite instead
of failing one check). What IS committed and gated below is the
non-terminating half of the contract: `is_valid(id)` telling a caller a
handle has gone stale BEFORE it touches `remove`/any accessor -- exactly
the check gameplay code holding a ground/platform ref or a kinematic
platform handle across frames (ROADMAP 17.1/17.7/17.24) is expected to run.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.body_set import BodySet, BodyId, MOTION_STATIC, MOTION_DYNAMIC


def _body(y: Real) -> QuatBody6:
    return QuatBody6.at_rest(
        Vec3(0, y, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)
    )


def _test_ordinary(mut s: Suite):
    """Fresh slots are dense, generation 0, and `motion` round-trips."""
    var bset = BodySet[QuatBody6]()
    var a = bset.push(_body(0), MOTION_STATIC)
    var b = bset.push(_body(1), MOTION_DYNAMIC)
    var c = bset.push(_body(2), MOTION_DYNAMIC)
    s.check(a.slot == 0 and b.slot == 1 and c.slot == 2, "slots are dense on first push")
    s.check(a.gen == 0 and b.gen == 0 and c.gen == 0, "fresh slots start at generation 0")
    s.check(len(bset) == 3, "len(bset) == number of pushed bodies")
    s.check(bset.is_static(0) and not bset.is_static(1) and not bset.is_static(2), "motion round-trips through is_static")
    s.check(bset.is_valid(a) and bset.is_valid(b) and bset.is_valid(c), "every freshly-pushed id is valid")
    s.check(a.index() == 0, "BodyId.index() returns the raw slot")


def _test_integration_remove_reuse(mut s: Suite):
    """Removal tombstones the slot and bumps its generation; the next push
    reuses the LOWEST free slot with the new generation, and stale ids for
    that slot read as invalid while ids to OTHER slots are unaffected."""
    var bset = BodySet[QuatBody6]()
    var a = bset.push(_body(0), MOTION_DYNAMIC)
    var b = bset.push(_body(1), MOTION_DYNAMIC)
    var c = bset.push(_body(2), MOTION_DYNAMIC)
    bset.remove(b)
    s.check(not bset.is_valid(b), "a removed id is no longer valid")
    s.check(bset.is_valid(a) and bset.is_valid(c), "removing one id doesn't invalidate others")
    s.check(bset.is_removed(1), "the tombstoned slot reports is_removed")
    s.check(len(bset) == 3, "remove doesn't shrink the dense list (no compaction)")

    var d = bset.push(_body(3), MOTION_STATIC)
    s.check(d.slot == 1, "push reuses the freed slot")
    s.check(d.gen == 1, "the reused slot's generation bumped by exactly one")
    s.check(d != b, "the new id at the reused slot differs from the stale one (BodyId.__ne__)")
    s.check(bset.is_valid(d), "the new id at the reused slot is valid")
    s.check(not bset.is_valid(b), "the OLD id at that slot is still invalid after reuse")
    s.check(bset.is_static(1), "the reused slot's motion reflects the new push, not the old one")

    # lowest-free-slot: free two slots out of order, confirm reuse order.
    bset.remove(c)  # slot 2
    bset.remove(a)  # slot 0
    var e = bset.push(_body(4), MOTION_DYNAMIC)
    s.check(e.slot == 0, "the lowest free slot (0) is reused first")
    var f = bset.push(_body(5), MOTION_DYNAMIC)
    s.check(f.slot == 2, "the next free slot (2) is reused next")
    s.check(len(bset) == 3, "three live slots throughout (no growth from remove+reuse)")


def _test_extreme_generation_never_collides(mut s: Suite):
    """Repeated remove/push cycles on the SAME slot keep bumping its
    generation, so ids issued at different points in that history never
    collide even though they share a slot."""
    var bset = BodySet[QuatBody6]()
    var first = bset.push(_body(0), MOTION_DYNAMIC)
    var seen = List[BodyId]()
    seen.append(first)
    var cur = first
    for _ in range(50):
        bset.remove(cur)
        cur = bset.push(_body(0), MOTION_DYNAMIC)
        s.check(cur.slot == 0, "single-slot churn always reuses slot 0")
        seen.append(cur)
    # every id in `seen` used slot 0 at issue time; only the LAST one
    # (`cur`) should still be valid, and every earlier one distinct from it.
    for i in range(len(seen) - 1):
        s.check(seen[i] != cur, "an id from an earlier generation never equals the current one")
        s.check(not bset.is_valid(seen[i]), "an id from an earlier generation is never valid again")
    s.check(bset.is_valid(cur), "the current generation's id is valid")
    s.check(Int(cur.gen) == 50, "generation is a plain running counter (50 remove/push cycles)")


def main() raises:
    var s = Suite("body_set")
    _test_ordinary(s)
    _test_integration_remove_reuse(s)
    _test_extreme_generation_never_collides(s)
    s.finish()
