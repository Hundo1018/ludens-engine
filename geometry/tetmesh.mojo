"""Tetrahedral meshes from closed surfaces (ROADMAP 17.58).

`tetrahedralize(verts, indices, res)` voxelises a closed triangle mesh
(`convex_decomp.voxelize`, `res` cells along the longest side) and splits
every inside cell into 5 tetrahedra with the alternating split `make_beam`
uses, so neighbouring cells share faces and the mesh is conforming. Lattice
corners are shared between cells (one node per corner). The volume is the
inside cells' volume: a staircase approximation of the surface that
converges as `res` grows (`test_tetmesh` measures it on a sphere).

`embed(mesh, p)` gives the tet and the barycentric weights of a point (a
surface vertex, for drawing the original surface on the deformed tets): the
tet that contains it, or, for a point outside every tet (the staircase lies
inside the surface), the tet whose smallest weight is largest -- the
weights then extrapolate, still summing to 1. `place` evaluates an
embedding on moved tet nodes; it is linear in the nodes, so a rigid motion
of the mesh moves the embedded points rigidly.
"""

from .vec import Real, Vec3, dot, cross
from .convex_decomp import voxelize


struct TetMesh(Copyable, Movable):
    var pts: List[Vec3]
    var tets: List[Int]  # 4 node indices per tet

    def __init__(out self):
        self.pts = List[Vec3]()
        self.tets = List[Int]()

    def tet_count(self) -> Int:
        return len(self.tets) // 4

    def tet_volume(self, t: Int) -> Real:
        """Signed volume (positive for this module's orientation)."""
        var a = self.pts[self.tets[4 * t]]
        var b = self.pts[self.tets[4 * t + 1]]
        var c = self.pts[self.tets[4 * t + 2]]
        var d = self.pts[self.tets[4 * t + 3]]
        return dot(b - a, cross(c - a, d - a)) / 6

    def volume(self) -> Real:
        var v = Real(0)
        for t in range(self.tet_count()):
            v += abs(self.tet_volume(t))
        return v


@fieldwise_init
struct Embedding(Copyable, ImplicitlyCopyable, Movable):
    var tet: Int
    var w0: Real
    var w1: Real
    var w2: Real
    var w3: Real


def _corner(mut m: TetMesh, mut node: List[Int], i: Int, j: Int, k: Int, ny: Int, nz: Int, ox: Float64, oy: Float64, oz: Float64, h: Float64) -> Int:
    """Node index of lattice corner (i, j, k), created on first use."""
    var key = (i * (ny + 1) + j) * (nz + 1) + k
    if node[key] < 0:
        node[key] = len(m.pts)
        m.pts.append(Vec3(Real(ox + h * Float64(i)), Real(oy + h * Float64(j)), Real(oz + h * Float64(k)), 0))
    return node[key]


def tetrahedralize(verts: List[Float64], indices: List[Int], res: Int) raises -> TetMesh:
    """Conforming tets filling the voxelised inside of a closed mesh."""
    var g = voxelize(verts, indices, res)
    var m = TetMesh()
    var nx = g.nx
    var ny = g.ny
    var nz = g.nz
    var node = List[Int](length=(nx + 1) * (ny + 1) * (nz + 1), fill=-1)

    for i in range(nx):
        for j in range(ny):
            for k in range(nz):
                if g.occ[(i * ny + j) * nz + k] == 0:
                    continue
                var v000 = _corner(m, node, i, j, k, ny, nz, g.ox, g.oy, g.oz, g.h)
                var v100 = _corner(m, node, i + 1, j, k, ny, nz, g.ox, g.oy, g.oz, g.h)
                var v010 = _corner(m, node, i, j + 1, k, ny, nz, g.ox, g.oy, g.oz, g.h)
                var v001 = _corner(m, node, i, j, k + 1, ny, nz, g.ox, g.oy, g.oz, g.h)
                var v110 = _corner(m, node, i + 1, j + 1, k, ny, nz, g.ox, g.oy, g.oz, g.h)
                var v101 = _corner(m, node, i + 1, j, k + 1, ny, nz, g.ox, g.oy, g.oz, g.h)
                var v011 = _corner(m, node, i, j + 1, k + 1, ny, nz, g.ox, g.oy, g.oz, g.h)
                var v111 = _corner(m, node, i + 1, j + 1, k + 1, ny, nz, g.ox, g.oy, g.oz, g.h)
                var q: List[Int]
                if (i + j + k) % 2 == 0:
                    q = [v000, v100, v010, v001, v100, v110, v010, v111, v100, v010, v001, v111,
                         v010, v011, v001, v111, v100, v001, v101, v111]
                else:
                    q = [v100, v000, v110, v101, v000, v010, v110, v011, v000, v001, v101, v011,
                         v110, v101, v011, v111, v000, v110, v101, v011]
                for t in range(5):
                    var a = q[4 * t]
                    var b = q[4 * t + 1]
                    var c = q[4 * t + 2]
                    var d = q[4 * t + 3]
                    # orient every tet positively
                    if dot(m.pts[b] - m.pts[a], cross(m.pts[c] - m.pts[a], m.pts[d] - m.pts[a])) < 0:
                        var tmp = c
                        c = d
                        d = tmp
                    m.tets.append(a)
                    m.tets.append(b)
                    m.tets.append(c)
                    m.tets.append(d)
    return m^


def _bary(a: Vec3, b: Vec3, c: Vec3, d: Vec3, p: Vec3) -> Tuple[Real, Real, Real, Real]:
    var v = dot(b - a, cross(c - a, d - a))
    if v == 0:
        return (Real(-1e30), Real(0), Real(0), Real(0))
    var w1 = dot(p - a, cross(c - a, d - a)) / v
    var w2 = dot(b - a, cross(p - a, d - a)) / v
    var w3 = dot(b - a, cross(c - a, p - a)) / v
    return (1 - w1 - w2 - w3, w1, w2, w3)


def embed(m: TetMesh, p: Vec3) -> Embedding:
    """Tet and barycentric weights of `p` (module note)."""
    var best = -1
    var best_min = Real(-1e30)
    var bw = (Real(0), Real(0), Real(0), Real(0))
    for t in range(m.tet_count()):
        var w = _bary(m.pts[m.tets[4 * t]], m.pts[m.tets[4 * t + 1]], m.pts[m.tets[4 * t + 2]], m.pts[m.tets[4 * t + 3]], p)
        var mn = min(min(w[0], w[1]), min(w[2], w[3]))
        if mn > best_min:
            best_min = mn
            best = t
            bw = w
            if mn >= 0:
                break
    return Embedding(best, bw[0], bw[1], bw[2], bw[3])


def place(m: TetMesh, nodes: List[Vec3], e: Embedding) -> Vec3:
    """The embedded point on moved nodes (`nodes` indexed like `m.pts`)."""
    var t = e.tet
    return (nodes[m.tets[4 * t]] * e.w0 + nodes[m.tets[4 * t + 1]] * e.w1
            + nodes[m.tets[4 * t + 2]] * e.w2 + nodes[m.tets[4 * t + 3]] * e.w3)
