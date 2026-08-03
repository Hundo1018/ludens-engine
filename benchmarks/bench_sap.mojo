"""Sweep and prune against the other broadphases, swept over motion speed.

SAP's whole claim is temporal coherence: it keeps last frame's sorted order and
repairs it with an insertion sort, which is near-linear when bodies barely move
and degenerates toward a full sort when they do not. So the meaningful axis is
not N alone but HOW FAR things move per frame, and that is what this sweeps —
from a jitter well inside the fat margin, out to displacements of several box
widths per frame.

Compared against the persistent DBVH (the engine's other coherence-exploiting
structure), the spatial hash, and a full BVH rebuild. Every structure answers
the same query, and `test_sap` gates that SAP's pair set equals brute force's,
so this table is cost-only.

The scene is deliberately ISOTROPIC (a cube of boxes). SAP's known failure mode
is many intervals overlapping along the sweep axis, so a flat or wall-shaped
scene would make it look far worse; a cube is the neutral case and the axis
heuristic picks the widest spread.
"""

from std.benchmark import keep
from harness.bench import BenchTable, measure
from geometry.vec import Real, Vec3
from geometry.aabb import AABB
from scheduler.rng import Pcg32, Rng
from collision.broadphase import BroadPhase, Pair, BoxProxy, BruteForce
from collision.bp_bvh import BVHBroadPhase
from collision.bp_dbvh import DbvhBroadPhase
from collision.bp_hashgrid import SpatialHashBroadPhase
from collision.bp_sap import SapBroadPhase

comptime N = 4096
comptime FRAMES = 20


def _tri(x: Real) -> Real:
    """Triangle wave in [-1, 1] with period 2 — a bounded oscillation."""
    var t = x - Real(Int(x / 2)) * 2
    if t < 0:
        t += 2
    return (t - 1) * 2 - 1 if t < 1 else (3 - t) * 2 - 1


def _items(
    cx: List[Real], cy: List[Real], cz: List[Real], f: Int, speed: Real
) -> List[BoxProxy[3]]:
    """Frame `f` of a bounded oscillation. Amplitude is FIXED, so the spatial
    distribution — and therefore the number of overlapping pairs — is the same
    at every speed; only the per-frame DISPLACEMENT scales. That separation is
    what makes the speed axis a coherence axis rather than a density axis: a
    sweep that let boxes drift apart at high speed would be comparing different
    amounts of work per row, the same trap the broadphase table warns about."""
    var items = List[BoxProxy[3]]()
    comptime AMP: Real = 3.0
    # `speed` IS the per-frame phase step. It must stay well below the wave's
    # period of 2: a step of exactly 2 would alias the oscillation into a
    # standstill and fake perfect coherence (which an earlier revision of this
    # sweep did, making the incoherent row look like the cheapest one).
    var step = Real(f) * speed
    for i in range(N):
        var ph = Real(i) * 0.618
        var c = Vec3(
            cx[i] + AMP * _tri(ph + step),
            cy[i] + AMP * _tri(ph * 1.7 + step),
            cz[i] + AMP * _tri(ph * 2.3 + step),
        )
        items.append(BoxProxy[3](i, AABB[3].from_center(c, Vec3(0.5, 0.5, 0.5))))
    return items^


# One concrete runner per broadphase. A single generic `_sweep[BP: BroadPhase]`
# would be tidier, but on this nightly `BP.dim` will not unify with a literal 3
# inside the function body (rebind then trips the implicit-copy rule), so the
# four bodies are written out.
def _run_sap(mut table: BenchTable, cx: List[Real], cy: List[Real],
             cz: List[Real], speed: Real, tag: String) raises:
    var bp = SapBroadPhase[3]()
    bp.rebuild(_items(cx, cy, cz, 0, speed))

    @parameter
    def run():
        try:
            for f in range(FRAMES):
                bp.rebuild(_items(cx, cy, cz, f, speed))
                var out = List[Pair]()
                bp.pairs(out)
                keep(len(out))
        except:
            pass

    table.add("sap" + tag, N, "frame", measure[run](2, 6), FRAMES)


def _run_dbvh(mut table: BenchTable, cx: List[Real], cy: List[Real],
              cz: List[Real], speed: Real, tag: String) raises:
    var bp = DbvhBroadPhase[3]()
    bp.rebuild(_items(cx, cy, cz, 0, speed))

    @parameter
    def run():
        try:
            for f in range(FRAMES):
                bp.rebuild(_items(cx, cy, cz, f, speed))
                var out = List[Pair]()
                bp.pairs(out)
                keep(len(out))
        except:
            pass

    table.add("dbvh" + tag, N, "frame", measure[run](2, 6), FRAMES)


def _run_grid(mut table: BenchTable, cx: List[Real], cy: List[Real],
              cz: List[Real], speed: Real, tag: String) raises:
    var bp = SpatialHashBroadPhase[3](2.0)
    bp.rebuild(_items(cx, cy, cz, 0, speed))

    @parameter
    def run():
        try:
            for f in range(FRAMES):
                bp.rebuild(_items(cx, cy, cz, f, speed))
                var out = List[Pair]()
                bp.pairs(out)
                keep(len(out))
        except:
            pass

    table.add("hashgrid" + tag, N, "frame", measure[run](2, 6), FRAMES)


def _run_bvh(mut table: BenchTable, cx: List[Real], cy: List[Real],
             cz: List[Real], speed: Real, tag: String) raises:
    var bp = BVHBroadPhase[3]()
    bp.rebuild(_items(cx, cy, cz, 0, speed))

    @parameter
    def run():
        try:
            for f in range(FRAMES):
                bp.rebuild(_items(cx, cy, cz, f, speed))
                var out = List[Pair]()
                bp.pairs(out)
                keep(len(out))
        except:
            pass

    table.add("bvh rebuild" + tag, N, "frame", measure[run](2, 6), FRAMES)


def main() raises:
    var rng = Pcg32.seeded(11)
    var cx = List[Real]()
    var cy = List[Real]()
    var cz = List[Real]()
    for _ in range(N):
        cx.append((Real(rng.next_f32()) * 2 - 1) * 40)
        cy.append((Real(rng.next_f32()) * 2 - 1) * 40)
        cz.append((Real(rng.next_f32()) * 2 - 1) * 40)

    var t = BenchTable(
        "broadphase vs motion speed: SAP / DBVH / hashgrid / BVH rebuild"
    )
    var speeds = List[Real]()
    # displacement per frame = 2 * AMP * step = 6 * step world units, and a
    # box is 1 unit wide, so these are ~0.03 / 0.3 / 1.5 / 5.4 box widths.
    speeds.append(0.005)
    speeds.append(0.05)
    speeds.append(0.25)
    speeds.append(0.9)

    var names = List[String]()
    names.append(" @ 0.03 box widths/frame (jitter)")
    names.append(" @ 0.3 box widths/frame")
    names.append(" @ 1.5 box widths/frame")
    names.append(" @ 5.4 box widths/frame (incoherent)")

    for si in range(len(speeds)):
        var sp = speeds[si]
        var tag = names[si]
        # fairness probe: the pair count must be ~constant across speeds,
        # otherwise the rows are not comparable
        var probe = SapBroadPhase[3]()
        probe.rebuild(_items(cx, cy, cz, 7, sp))
        var pp = List[Pair]()
        probe.pairs(pp)
        print("  [pairs at speed", sp, "] =", len(pp))
        _run_sap(t, cx, cy, cz, sp, tag)
        _run_dbvh(t, cx, cy, cz, sp, tag)
        _run_grid(t, cx, cy, cz, sp, tag)
        _run_bvh(t, cx, cy, cz, sp, tag)
    t.print_report()
