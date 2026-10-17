# tier: component
"""Sparse volumes and their byte format (ROADMAP 17.63,
`geometry.sparse_volume`).

  1. Ordinary: a 64^3 field with 0 %, 1 %, 10 % and 100 % of its voxels
     non-background round-trips exactly through `from_dense` -> `encode`
     -> `decode_volume` -> `to_dense`; the encoded size against the dense
     f64 array (2 MiB) is printed per occupancy -- sparse is smaller at
     1 % and 10 %, dense is smaller at 100 % (masks and leaf headers), as
     the ROADMAP asks both sides to be measured. Negative coordinates work.
  2. Integration: an LBM lattice's density field (24^3, a sphere moved
     through it) exported as a volume and read back is the same field,
     bit for bit.
  3. Extreme: an empty volume encodes and decodes; a flipped byte, a
     truncated buffer and a foreign magic raise instead of reading past
     the end.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.sparse_volume import SparseVolume, decode_volume, from_dense, to_dense
from fluid.lbm import Lbm, BC_PERIODIC
from scheduler.rng import SplitMix64

comptime N = 64


def main() raises:
    var s = Suite("sparse_volume")
    var rng = SplitMix64.seeded(3)
    var exact = True
    var line = String("  64^3, encoded bytes / dense 2 MiB:")
    var ratios = List[Real]()
    for occ in [Real(0), Real(0.01), Real(0.1), Real(1.0)]:
        var vals = List[Real](length=N * N * N, fill=0)
        for q in range(N * N * N):
            if Real(rng.next_f32()) < occ:
                vals[q] = Real(rng.next_f32()) + 0.5
        var vol = from_dense(vals, N, N, N, 0)
        var bytes = vol.encode()
        var back = decode_volume(bytes)
        var dense = to_dense(back, N, N, N)
        for q in range(N * N * N):
            exact = exact and dense[q] == vals[q]
        var ratio = Real(len(bytes)) / Real(N * N * N * 8)
        ratios.append(ratio)
        line += " " + String(Int(occ * 100)) + " %: " + String(ratio)
    print(line)
    s.check(exact, "every occupancy round-trips exactly")
    s.check(ratios[1] < 0.5 and ratios[2] < 1 and ratios[3] > 1, "sparse wins at 1 % and 10 %; dense wins at 100 %")

    var neg = SparseVolume(-1)
    neg.set(-5, -17, 3, 2.5)
    neg.set(40, -1, -9, 7)
    var nb = decode_volume(neg.encode())
    s.check(nb.get(-5, -17, 3) == 2.5 and nb.get(40, -1, -9) == 7 and nb.get(0, 0, 0) == -1, "negative coordinates and background")

    var l = Lbm(24, 24, 24, 0.1, BC_PERIODIC)
    l.init_uniform(1, 0.02, 0, 0)
    var k = l.add_moving_sphere(Vec3(8, 12, 12, 0), 3, Vec3(0.02, 0, 0, 0), Vec3(0, 0, 0, 0))
    for step in range(40):
        l.move_sphere(k, Vec3(8 + 0.02 * Real(step + 1), 12, 12, 0), Vec3(0.02, 0, 0, 0), Vec3(0, 0, 0, 0))
        l.step()
    var rho = List[Real](length=l.cells(), fill=0)
    for c in range(l.cells()):
        rho[c] = l.density(c) if l.flag[c] == 0 else Real(0)
    var lv = from_dense(rho, 24, 24, 24, 0)
    var lb = decode_volume(lv.encode())
    var ld = to_dense(lb, 24, 24, 24)
    var same = True
    for c in range(l.cells()):
        same = same and ld[c] == rho[c]
    print("  LBM density field 24^3:", lv.active_voxels(), "active voxels in", lv.leaf_count(), "leaves, bytes", len(lv.encode()))
    s.check(same, "an LBM field round-trips bit for bit")

    var empty = SparseVolume(0.5)
    var eb = decode_volume(empty.encode())
    var raised = 0
    var bad = lv.encode()
    bad[100] = bad[100] ^ 0x10
    try:
        _ = decode_volume(bad)
    except:
        raised += 1
    var cut = lv.encode()
    var short = List[UInt8]()
    for q in range(len(cut) // 2):
        short.append(cut[q])
    try:
        _ = decode_volume(short)
    except:
        raised += 1
    var foreign = lv.encode()
    foreign[0] = 0x58
    try:
        _ = decode_volume(foreign)
    except:
        raised += 1
    s.check(eb.leaf_count() == 0 and eb.get(1, 2, 3) == 0.5 and raised == 3, "empty volume round-trips; corrupt, truncated and foreign data raise")
    s.finish()
