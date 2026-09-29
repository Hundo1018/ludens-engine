"""Heightfield deformation (ROADMAP 17.30): one crater edit plus the bounds
refresh, re-deriving the field's vertical extent from the 16x16 block
summary (incremental) vs rescanning every height (full), over terrain size.
The two give the same AABB (`test_terrain_deform`); the rows show where the
rescan starts to cost more than the edit itself.
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from collision.collider_set import ColliderSet

comptime EDITS = 200


def main() raises:
    var t = BenchTable("Crater edit + bounds refresh: block summary vs full rescan")
    for n in [64, 256, 1024]:
        for inc in [True, False]:
            var cs = ColliderSet()
            var h = List[Real](length=n * n, fill=0)
            var i = cs.add_heightfield(h, n, n, 0.5, 0, 0)
            var t0 = Int(perf_counter_ns())
            for e in range(EDITS):
                var x = Real((e * 37) % n) * 0.5
                var z = Real((e * 91) % n) * 0.5
                _ = cs.deform_heightfield(i, x, z, 2, Real(-0.1) if e % 2 == 0 else Real(0.1), inc)
            var d = Int(perf_counter_ns()) - t0
            keep(cs.world_aabb[i].max[1])
            t.add("crater + " + ("block-summary bounds" if inc else "full-rescan bounds"), n * n, "edit", d, EDITS)
    t.print_report()
