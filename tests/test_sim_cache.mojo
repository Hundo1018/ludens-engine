# tier: integration
"""Point caches and the cache player (ROADMAP 17.63).

  1. Ordinary: 240 frames of a 16 x 16 cloth falling onto itself are cached
     at err = 1 mm; every frame reads back within 1 mm (+ f32 rounding) and
     the cache is under half the size of raw f32 positions; err = 0 stores
     the frames losslessly (bit for bit).
  2. Integration: `CachePlayer` driven by the 17.55 `step_checked` loop
     matches the live cloth at every recorded frame within err; random
     access `frame(i)` equals sequential playback; the player's state
     round-trips through `write_state` / `read_state` and continues equally.
  3. Extreme: zero frames (reads, `frame(0)` raises); one point; a frame
     whose point count changes (a keyframe is forced; both sides decode); a
     NaN point (stored raw, NaN read back, neighbouring frames still within
     err); a truncated cache, a flipped byte (checksum), an unknown version
     and a bad magic all raise.
"""

from std.math import isfinite, isnan
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from diag.counters import Counters
from physics.cloth import MeshCloth, grid_mesh
from physics.continuum import step_checked
from physics.serialize import BinWriter, BinReader
from physics.sim_cache import PointCacheWriter, PointCacheReader, CachePlayer

comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 1.0 / 60.0


def _cloth() raises -> MeshCloth:
    var m = grid_mesh(15, 15, 1, 1, Vec3(-0.5, 1, -0.5, 0))
    var c = MeshCloth(m[0], m[1], 0.2, 0, 1e-3)
    c.pin(0)
    c.pin(15)
    return c^


def _maxerr(a: List[Vec3], b: List[Vec3]) -> Real:
    var w = Real(0)
    for i in range(len(a)):
        for k in range(3):
            w = max(w, abs(a[i][k] - b[i][k]))
    return w


def main() raises:
    var s = Suite("sim_cache")

    # ---- record a cloth ------------------------------------------------------------------------------
    var live = _cloth()
    var frames = List[List[Vec3]]()
    var wr = PointCacheWriter(1e-3, 16)
    var lossless = PointCacheWriter(0)
    for _ in range(240):
        live.advance(DT, G)
        frames.append(live.x.copy())
        wr.add_frame(live.x)
        lossless.add_frame(live.x)
    var bytes = wr.bytes()
    var rd = PointCacheReader(bytes.copy())
    var worst = Real(0)
    for f in range(240):
        worst = max(worst, _maxerr(rd.frame(f), frames[f]))
    var raw = 240 * len(live.x) * 12
    print("  cloth 256 points x 240 frames: cache", len(bytes), "bytes vs raw", raw, "(", Float64(len(bytes)) / Float64(raw) * 100, "% )  max error", worst)
    s.check(worst <= 1e-3 + 1e-6, "every frame within err = 1 mm")
    s.check(len(bytes) * 2 < raw, "under half the raw f32 size")
    var lr = PointCacheReader(lossless.bytes())
    var exact = True
    for f in range(0, 240, 7):
        var g = lr.frame(f)
        for i in range(len(g)):
            if g[i] != frames[f][i]:
                exact = False
    s.check(exact, "err = 0: lossless, bit for bit")

    # ---- player under the continuum contract ------------------------------------------------------------
    var player = CachePlayer(PointCacheReader(bytes.copy()), DT)
    var c = Counters()
    var pw = Real(0)
    for f in range(1, 240):
        _ = step_checked(player, DT, G, c)
        pw = max(pw, _maxerr(player.points, frames[f]))
    print("  CachePlayer through step_checked: max error vs live", pw, " frame", player.index)
    s.check(pw <= 1e-3 + 1e-6 and player.index == 239, "player matches the live cloth at every frame within err")
    var seq = True
    var p2 = CachePlayer(PointCacheReader(bytes.copy()), DT)
    for f in range(1, 100):
        p2.advance(DT, G)
        if _maxerr(p2.points, rd.frame(f)) != 0:
            seq = False
    s.check(seq, "random access frame(i) == sequential playback")
    var w = BinWriter()
    p2.write_state(w)
    var p3 = CachePlayer(PointCacheReader(bytes.copy()), DT)
    var r = BinReader(w.b.copy())
    p3.read_state(r)
    var cont = True
    for _ in range(50):
        p2.advance(DT, G)
        p3.advance(DT, G)
        if _maxerr(p2.points, p3.points) != 0:
            cont = False
    s.check(cont, "player state round-trips and continues equally")

    # ---- extremes ---------------------------------------------------------------------------------
    var empty = PointCacheReader(PointCacheWriter(1e-3).bytes())
    var raised = False
    try:
        _ = empty.frame(0)
    except:
        raised = True
    s.check(empty.frames() == 0 and raised, "zero frames: reads, frame(0) raises")
    var odd = PointCacheWriter(1e-3, 8)
    var one: List[Vec3] = [Vec3(1, 2, 3, 0)]
    var two: List[Vec3] = [Vec3(1, 2, 3, 0), Vec3(4, 5, 6, 0)]
    var nanf: List[Vec3] = [Vec3(1, 2, 3, 0), Vec3(Real(0) / Real(0), 5, 6, 0)]
    odd.add_frame(one)
    odd.add_frame(one)
    odd.add_frame(two)
    odd.add_frame(two)
    odd.add_frame(nanf)
    odd.add_frame(two)
    var od = PointCacheReader(odd.bytes())
    var f1 = od.frame(1)
    var f3 = od.frame(3)
    var f4 = od.frame(4)
    var f5 = od.frame(5)
    s.check(len(f1) == 1 and len(f3) == 2 and _maxerr(f1, one) <= 1e-3 and _maxerr(f3, two) <= 1e-3, "point count changes: both sides decode")
    s.check(isnan(f4[1][0]) and f4[0] == nanf[0] and _maxerr(f5, two) <= 1e-3, "a NaN point is stored raw and read back; the next frame decodes")
    var good = odd.bytes()
    var errs = 0
    var cut = List[UInt8]()
    for i in range(len(good) - 20):
        cut.append(good[i])
    try:
        _ = PointCacheReader(cut^)
    except:
        errs += 1
    var flip = good.copy()
    flip[40] = flip[40] ^ 0x10
    try:
        _ = PointCacheReader(flip^)
    except:
        errs += 1
    var ver = good.copy()
    ver[4] = 9
    try:
        _ = PointCacheReader(ver^)
    except:
        errs += 1
    var mag = good.copy()
    mag[0] = 0
    try:
        _ = PointCacheReader(mag^)
    except:
        errs += 1
    s.check(errs == 4, "truncated, flipped byte, unknown version, bad magic: all raise")
    s.finish()
