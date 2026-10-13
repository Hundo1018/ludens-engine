"""Point caches (ROADMAP 17.63): size vs error bound, throughput, and seek
by cache against seek by snapshot + recompute.

A 16 x 16 cloth, 240 frames. Size per point-frame at err = 1 cm, 1 mm,
0.1 mm and lossless; encode and decode cost per point-frame; then "show
frame 200": decode from the cache (at most 15 deltas after a keyframe)
against restoring a snapshot taken every 16 frames and re-simulating the
remaining frames (the 17.39 replay approach, which needs no cache but pays
the solver).

Run with: `mojo run -I build benchmarks/bench_sim_cache.mojo`.
"""

from std.benchmark import keep
from geometry.vec import Real, Vec3
from physics.cloth import MeshCloth, grid_mesh
from physics.serialize import BinWriter, BinReader
from physics.sim_cache import PointCacheWriter, PointCacheReader
from harness.bench import BenchTable, now

comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 1.0 / 60.0


def cloth() raises -> MeshCloth:
    var m = grid_mesh(15, 15, 1, 1, Vec3(-0.5, 1, -0.5, 0))
    var c = MeshCloth(m[0], m[1], 0.2, 0, 1e-3)
    c.pin(0)
    c.pin(15)
    return c^


def main() raises:
    var c = cloth()
    var frames = List[List[Vec3]]()
    var snaps = List[List[UInt8]]()
    for f in range(240):
        if f % 16 == 0:
            var w = BinWriter()
            c.write_state(w)
            snaps.append(w.b.copy())
        c.advance(DT, G)
        frames.append(c.x.copy())
    var pts = len(frames[0])

    var t = BenchTable("Point cache: size and throughput, 256-point cloth x 240 frames (17.63)")
    var errs: List[Real] = [1e-2, 1e-3, 1e-4, 0]
    for e in errs:
        var t0 = now()
        var wr = PointCacheWriter(e, 16)
        for f in frames:
            wr.add_frame(f)
        var b = wr.bytes()
        var t1 = now()
        var rd = PointCacheReader(b.copy())
        var acc = Real(0)
        var t2 = now()
        for f in range(240):
            acc += rd.frame(f)[0][1]
        var t3 = now()
        keep(acc)
        var bpp = Float64(len(b)) / Float64(240 * pts)
        var name = "err " + String(e) + " m: " + String(Float32(bpp)) + " bytes/point-frame (raw 12)"
        t.add(name + ", encode", pts * 240, "point-frame", t1 - t0, 240 * pts)
        t.add(name + ", decode (random access)", pts * 240, "point-frame", t3 - t2, 240 * pts)
    t.print_report()

    var u = BenchTable("Seek to frame 200: cache vs snapshot + recompute (17.63)")
    var wr = PointCacheWriter(1e-3, 16)
    for f in frames:
        wr.add_frame(f)
    var rd = PointCacheReader(wr.bytes())
    var reps = 200
    var t0 = now()
    var acc = Real(0)
    for _ in range(reps):
        acc += rd.frame(200)[5][1]
    var t1 = now()
    u.add("cache decode (keyframe 192 + 8 deltas)", 1, "seek", t1 - t0, reps)
    var r = cloth()
    var t2 = now()
    for _ in range(20):
        var br = BinReader(snaps[200 // 16].copy())
        r.read_state(br)
        for _ in range(200 - (200 // 16) * 16 + 1):
            r.advance(DT, G)
        acc += r.x[5][1]
    var t3 = now()
    keep(acc)
    u.add("snapshot 192 + recompute 9 frames", 1, "seek", t3 - t2, 20)
    u.print_report()
