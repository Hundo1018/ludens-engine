# tier: component
"""3D volume navigation (ROADMAP 17.14): SvoAStar vs SmoothedVoxelAStar.

Scene: a 20 x 10 x 20 m volume over a ground slab with a closed building
(walls 0.5 m thick, roof) that has one 2 x 2 m window. A flying agent of
radius 0.4 m starts outside and must enter through the window.

Ordinary: the route through the window is found by both variants, every
segment passes `line_of_sight`, and the octree has far fewer free leaves
than free voxels. Parity: 60 seeded queries -- same reachability, all
segments clear, smoothed lengths within 15 %. Extreme: a window narrower than
the agent (closed by the clearance dilation), a goal inside a wall, start ==
goal, an empty scene (one leaf), bad config.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from scheduler.rng import SplitMix64, Rng
from nav.volume import VolumeNav, VolumeConfig, SvoAStar, SmoothedVoxelAStar, VoxelAStar
from nav.path import NavPath


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


struct Scene(Movable):
    var verts: List[Vec3]
    var tris: List[Int]

    def __init__(out self):
        self.verts = List[Vec3]()
        self.tris = List[Int]()

    def _tri(mut self, a: Vec3, b: Vec3, c: Vec3):
        var n = len(self.verts)
        self.verts.append(a)
        self.verts.append(b)
        self.verts.append(c)
        self.tris.append(n)
        self.tris.append(n + 1)
        self.tris.append(n + 2)

    def quad(mut self, x0: Real, z0: Real, x1: Real, z1: Real, y: Real):
        self._tri(_v(x0, y, z0), _v(x0, y, z1), _v(x1, y, z0))
        self._tri(_v(x1, y, z0), _v(x0, y, z1), _v(x1, y, z1))

    def box(mut self, lo: Vec3, hi: Vec3):
        var x0 = lo[0]
        var y0 = lo[1]
        var z0 = lo[2]
        var x1 = hi[0]
        var y1 = hi[1]
        var z1 = hi[2]
        self.quad(x0, z0, x1, z1, y1)
        self.quad(x0, z0, x1, z1, y0)
        self._tri(_v(x0, y0, z0), _v(x0, y1, z0), _v(x0, y0, z1))
        self._tri(_v(x0, y0, z1), _v(x0, y1, z0), _v(x0, y1, z1))
        self._tri(_v(x1, y0, z0), _v(x1, y0, z1), _v(x1, y1, z0))
        self._tri(_v(x1, y0, z1), _v(x1, y1, z1), _v(x1, y1, z0))
        self._tri(_v(x0, y0, z0), _v(x1, y0, z0), _v(x0, y1, z0))
        self._tri(_v(x1, y0, z0), _v(x1, y1, z0), _v(x0, y1, z0))
        self._tri(_v(x0, y0, z1), _v(x0, y1, z1), _v(x1, y0, z1))
        self._tri(_v(x1, y0, z1), _v(x0, y1, z1), _v(x1, y1, z1))


def building(window: Real) -> Scene:
    """Ground slab + a 10 x 6 x 10 m building at (5..15, 0..6, 5..15) with a
    `window` x `window` m opening in the -x wall centred at (5, 3, 10)."""
    var sc = Scene()
    sc.box(_v(0, -0.5, 0), _v(20, 0, 20))
    var t = Real(0.5)
    var h = Real(6)
    var w2 = window * 0.5
    # -x wall with the window
    sc.box(_v(5, 0, 5), _v(5 + t, h, 10 - w2))
    sc.box(_v(5, 0, 10 + w2), _v(5 + t, h, 15))
    sc.box(_v(5, 0, 10 - w2), _v(5 + t, 3 - w2, 10 + w2))
    sc.box(_v(5, 3 + w2, 10 - w2), _v(5 + t, h, 10 + w2))
    sc.box(_v(15 - t, 0, 5), _v(15, h, 15))  # +x wall
    sc.box(_v(5, 0, 5), _v(15, h, 5 + t))  # -z wall
    sc.box(_v(5, 0, 15 - t), _v(15, h, 15))  # +z wall
    sc.box(_v(5, h - t, 5), _v(15, h, 15))  # roof
    return sc^


def _valid(vol: VolumeNav, p: NavPath) -> Bool:
    for i in range(1, len(p.points)):
        if not vol.line_of_sight(p.points[i - 1], p.points[i]):
            return False
    return True


def main() raises:
    var s = Suite("nav_volume")
    var cfg = VolumeConfig(0.25, 0.4)
    var sc = building(2.0)
    var vol = VolumeNav(sc.verts, sc.tris, _v(0, -1, 0), _v(20, 10, 20), cfg)
    s.check(vol.leaf_count() * 20 < vol.free_voxels(), "octree: free leaves << free voxels")
    s.check(not vol.point_free(_v(10, 3, 5.25)), "wall voxel is blocked")
    s.check(vol.point_free(_v(5.25, 3, 10)), "window centre is free")
    s.check(not vol.point_free(_v(5.25, 3, 9.2)), "window edge within the radius is blocked")

    var a = _v(1, 3, 10)
    var b = _v(12, 3, 12)
    var svo = SvoAStar()
    var vox = SmoothedVoxelAStar()
    var p1 = svo.find(vol, a, b)
    var p2 = vox.find(vol, a, b)
    s.check(p1.found and p2.found, "outside -> inside through the window")
    s.check(_valid(vol, p1) and _valid(vol, p2), "every segment has line of sight")
    var through = False
    for q in p1.points:
        if q[0] > 4 and q[0] < 6.5 and abs(q[2] - 10) < 1.0 and abs(q[1] - 3) < 1.0:
            through = True
    s.check(through, "svo route has a point at the window")
    s.check(p1.expanded < p2.expanded, "svo expands fewer nodes than voxel A*")
    var ratio = p1.length() / p2.length()
    s.check(ratio > 0.85 and ratio < 1.15, "svo / voxel smoothed length within 15 %")
    print("  nav_volume: leaves", vol.leaf_count(), "free voxels", vol.free_voxels(), "| svo", p1.length(), "expanded", p1.expanded, "| voxel", p2.length(), "expanded", p2.expanded)

    # parity over seeded queries
    var rng = SplitMix64.seeded(1714)
    var agree = 0
    var valid = 0
    var close = 0
    var found = 0
    var n = 60
    for _ in range(n):
        var qa = _v(rng.next_f32() * 20, rng.next_f32() * 9, rng.next_f32() * 20)
        var qb = _v(rng.next_f32() * 20, rng.next_f32() * 9, rng.next_f32() * 20)
        var r1 = svo.find(vol, qa, qb)
        var r2 = vox.find(vol, qa, qb)
        if r1.found == r2.found:
            agree += 1
        if r1.found and r2.found:
            found += 1
            if _valid(vol, r1) and _valid(vol, r2):
                valid += 1
            var r = r1.length() / max(r2.length(), Real(1e-6))
            if (r > 0.85 and r < 1.15) or abs(r1.length() - r2.length()) < 0.5:
                close += 1
    s.eqi(agree, n, "reachability agrees on 60 queries")
    s.check(found > 10, "query mix reaches inside and outside")
    s.eqi(valid, found, "all segments clear")
    s.eqi(close, found, "lengths within 15 % (or 0.5 m)")

    # extremes
    var narrow = building(0.6)  # 0.6 m window < 0.8 m agent diameter
    var vn = VolumeNav(narrow.verts, narrow.tris, _v(0, -1, 0), _v(20, 10, 20), cfg)
    s.check(not svo.find(vn, a, b).found and not vox.find(vn, a, b).found, "too-narrow window: no route")
    s.check(not svo.find(vol, a, _v(10, 3, 5.25)).found, "goal inside a wall: not found")
    var same = svo.find(vol, a, a)
    s.check(same.found and same.length() < 1e-5, "start == goal")
    var empty = VolumeNav(List[Vec3](), List[Int](), _v(0, 0, 0), _v(8, 8, 8), VolumeConfig(0.5, 0.0))
    s.eqi(empty.leaf_count(), 1, "empty 16^3 cube is one free leaf")
    var pe = svo.find(empty, _v(0.5, 0.5, 0.5), _v(7.5, 7.5, 7.5))
    s.check(pe.found and len(pe.points) == 2, "empty volume: straight line")
    var raised = False
    try:
        _ = VolumeNav(sc.verts, sc.tris, _v(0, 0, 0), _v(20, 10, 20), VolumeConfig(0, 0.4))
    except:
        raised = True
    s.check(raised, "voxel 0 raises")
    s.finish()
