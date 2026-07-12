"""Persistent vs rebuild broadphase on a frame-coherent workload.

N boxes jitter by ±0.02/frame (inside the ±0.1 fat margin most frames): the
persistent tree (`DbvhBroadPhase`) only touches escaped leaves and repairs its
pair cache locally, while the rebuild path (`BVHBroadPhase`) reconstructs the
whole tree and re-queries every box each frame. Same pair sets (`test_dbvh`).
"""

from std.benchmark import keep
from harness.bench import BenchTable, measure
from geometry.vec import Real, Vec3
from geometry.aabb import AABB
from scheduler.rng import Pcg32, Rng
from collision.broadphase import BroadPhase, Pair, BoxProxy
from collision.bp_bvh import BVHBroadPhase
from collision.bp_dbvh import DbvhBroadPhase

comptime N = 4096
comptime FRAMES = 30


def _frame_items(
    cx: List[Real], cy: List[Real], cz: List[Real], f: Int
) -> List[BoxProxy[3]]:
    var items = List[BoxProxy[3]]()
    for i in range(N):
        # deterministic small jitter, no rng state shared with timing
        var ph = Real((i * 7 + f * 13) % 97) * 0.001
        var c = Vec3(cx[i] + ph, cy[i] - ph, cz[i] + ph * 0.5)
        items.append(
            BoxProxy[3](i, AABB[3].from_center(c, Vec3(0.5, 0.5, 0.5)))
        )
    return items^


def main() raises:
    var t = BenchTable("broadphase: persistent (incremental) vs rebuild")
    var rng = Pcg32.seeded(11)
    var cx = List[Real]()
    var cy = List[Real]()
    var cz = List[Real]()
    for _ in range(N):
        cx.append((Real(rng.next_f32()) * 2 - 1) * 40)
        cy.append((Real(rng.next_f32()) * 2 - 1) * 40)
        cz.append((Real(rng.next_f32()) * 2 - 1) * 40)

    var dbvh = DbvhBroadPhase[3]()
    var bvh = BVHBroadPhase[3]()
    # warm both structures once so the persistent tree exists
    var first = _frame_items(cx, cy, cz, 0)
    dbvh.rebuild(first)
    bvh.rebuild(first)

    @parameter
    def run_dbvh():
        try:
            for f in range(FRAMES):
                var items = _frame_items(cx, cy, cz, f)
                dbvh.rebuild(items)
                var out = List[Pair]()
                dbvh.pairs(out)
                keep(len(out))
        except:
            pass

    @parameter
    def run_bvh():
        try:
            for f in range(FRAMES):
                var items = _frame_items(cx, cy, cz, f)
                bvh.rebuild(items)
                var out = List[Pair]()
                bvh.pairs(out)
                keep(len(out))
        except:
            pass

    t.add("DBVH (persistent + pair cache)", N, "frame", measure[run_dbvh](2, 8), FRAMES)
    t.add("BVH (full rebuild)", N, "frame", measure[run_bvh](2, 8), FRAMES)
    t.print_report()
