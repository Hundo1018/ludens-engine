"""Sparse volume vs dense array by occupancy (ROADMAP 17.63): encoded bytes
and encode / decode time for a 64^3 field. Round trips are exact
(test_sparse_volume); this is the capacity and throughput curve, both
sides measured (dense wins at full occupancy)."""

from std.benchmark import keep
from geometry.vec import Real
from geometry.sparse_volume import from_dense, decode_volume
from harness.bench import BenchTable, now
from scheduler.rng import SplitMix64


def main() raises:
    var t = BenchTable("Sparse volume, 64^3, by occupancy (17.63)")
    var n = 64
    var rng = SplitMix64.seeded(9)
    for occ in [Real(0.01), Real(0.1), Real(0.5), Real(1.0)]:
        var vals = List[Real](length=n * n * n, fill=0)
        for q in range(n * n * n):
            if Real(rng.next_f32()) < occ:
                vals[q] = Real(rng.next_f32()) + 0.5
        var vol = from_dense(vals, n, n, n, 0)
        var t0 = now()
        var b = vol.encode()
        var t1 = now()
        var back = decode_volume(b)
        var t2 = now()
        keep(back.leaf_count())
        var act = vol.active_voxels()
        var label = String(Int(occ * 100)) + " % active, " + String(len(b) // 1024) + " KiB (dense 2048 KiB)"
        t.add("encode " + label, act, "voxel", t1 - t0, max(act, 1))
        t.add("decode " + label, act, "voxel", t2 - t1, max(act, 1))
    t.print_report()
