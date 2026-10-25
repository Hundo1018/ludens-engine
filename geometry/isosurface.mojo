"""Isosurfaces of sampled scalar fields, and particle fields (ROADMAP 17.60:
particles -> surface, an output for the host to render).

`ScalarGrid` holds values at the nodes of an nx x ny x nz lattice (origin,
spacing). `marching_tetrahedra(grid, iso)` extracts the surface
{value = iso} as a triangle mesh: every cube is split into the same 6
tetrahedra along its main diagonal, each tetrahedron cut by at most two
triangles from its sign pattern (16 cases, no lookup tables); crossings
are placed by linear interpolation along the edge. Shared faces are split
the same way from both sides and edge vertices are welded by edge key, so
a closed isosurface comes out as a closed, consistently wound mesh
(inside = value > iso; normals point out of it).

`splat_particles(points, radius, ...)` builds the grid from particles by
summing the poly6 kernel (1 - r^2 / R^2)^3 over each particle's support.
`splat_particles_anisotropic` (Yu & Turk 2013, 17.60) stretches each
particle's kernel along its neighbourhood: weighted mean and covariance of
the neighbours within `neighbor_radius`, eigen-decomposed; the spreads are
clamped to at least max / `k_r`, and the axes are normalised to unit
geometric mean, so every kernel keeps the sphere's volume (an ellipsoid
of semi-axes R s_k, s_1 s_2 s_3 = 1). Centres move toward the
neighbourhood mean by `smooth`. A particle with fewer than
`min_neighbors` neighbours keeps the sphere. Flat sheets and smooth
surfaces come out flat instead of bumpy (`test_aniso_splat`).

`sample_sdf(sdf, ...)` fills the grid with minus the signed distance, so
`marching_tetrahedra(g, 0)` extracts the solid's surface (inside = value
> 0); `TriMesh.flat()` gives the (x, y, z per vertex, index triples)
arrays `ContactScene6.add_trimesh` takes -- an SDF (a cave, a carved
terrain, 17.69) becomes a static collision mesh.
"""

from std.math import sqrt
from .vec import Real, Vec3, cross, dot, length
from .sdf3 import Sdf3
from .mat3 import Mat3x3, sym_eigen3


struct ScalarGrid(Movable):
    var nx: Int
    var ny: Int
    var nz: Int
    var origin: Vec3
    var spacing: Real
    var v: List[Real]  # [(k * ny + j) * nx + i]

    def __init__(out self, nx: Int, ny: Int, nz: Int, origin: Vec3, spacing: Real) raises:
        if nx < 2 or ny < 2 or nz < 2 or not (spacing > 0):
            raise Error("ScalarGrid: need >= 2 nodes per axis and spacing > 0")
        self.nx = nx
        self.ny = ny
        self.nz = nz
        self.origin = origin
        self.spacing = spacing
        self.v = List[Real](length=nx * ny * nz, fill=0)

    def idx(self, i: Int, j: Int, k: Int) -> Int:
        return (k * self.ny + j) * self.nx + i

    def node(self, i: Int, j: Int, k: Int) -> Vec3:
        return self.origin + Vec3(Real(i), Real(j), Real(k), 0) * self.spacing


struct TriMesh(Movable):
    var verts: List[Vec3]
    var tris: List[Int]  # index triples

    def __init__(out self):
        self.verts = List[Vec3]()
        self.tris = List[Int]()

    def triangles(self) -> Int:
        return len(self.tris) // 3

    def flat(self) -> Tuple[List[Real], List[Int]]:
        """(x, y, z per vertex, index triples) for a collision mesh."""
        var v = List[Real](capacity=3 * len(self.verts))
        for p in self.verts:
            v.append(p[0])
            v.append(p[1])
            v.append(p[2])
        return (v^, self.tris.copy())

    def area(self) -> Real:
        var a = Real(0)
        for t in range(self.triangles()):
            var p = self.verts[self.tris[3 * t]]
            var q = self.verts[self.tris[3 * t + 1]]
            var r = self.verts[self.tris[3 * t + 2]]
            a += 0.5 * length(cross(q - p, r - p))
        return a

    def volume(self) -> Real:
        """Signed volume enclosed (divergence theorem; positive for a
        closed mesh with outward normals)."""
        var vol = Real(0)
        for t in range(self.triangles()):
            var p = self.verts[self.tris[3 * t]]
            var q = self.verts[self.tris[3 * t + 1]]
            var r = self.verts[self.tris[3 * t + 2]]
            vol += dot(p, cross(q, r)) / 6
        return vol

    def open_edges(self) -> Int:
        """Edges used by a number of triangles other than 2 (0 for a closed
        manifold mesh)."""
        var count = Dict[Int, Int]()
        var nv = len(self.verts)
        for t in range(self.triangles()):
            for e in range(3):
                var a = self.tris[3 * t + e]
                var b = self.tris[3 * t + (e + 1) % 3]
                var key = min(a, b) * nv + max(a, b)
                count[key] = count.get(key, 0) + 1
        var bad = 0
        for item in count.items():
            if item.value != 2:
                bad += 1
        return bad


def _tets() -> List[Int]:
    """The cube's 6 tetrahedra around its 0-6 diagonal, as corner indices
    (corner c at offset (cx[c], cy[c], cz[c]) in `marching_tetrahedra`)."""
    return [0, 5, 1, 6,  0, 1, 2, 6,  0, 2, 3, 6,  0, 3, 7, 6,  0, 7, 4, 6,  0, 4, 5, 6]


struct _Welder(Movable):
    var key_to_vert: Dict[Int, Int]

    def __init__(out self):
        self.key_to_vert = Dict[Int, Int]()


def _edge_vertex(g: ScalarGrid, iso: Real, a: Int, b: Int, mut mesh: TriMesh, mut w: _Welder) raises -> Int:
    """The crossing on the grid edge between nodes a and b (flat indices),
    welded by the edge."""
    var lo = min(a, b)
    var hi = max(a, b)
    var key = lo * (len(g.v)) + hi
    if key in w.key_to_vert:
        return w.key_to_vert[key]
    var ka = a // (g.nx * g.ny)
    var ja = (a // g.nx) % g.ny
    var ia = a % g.nx
    var kb = b // (g.nx * g.ny)
    var jb = (b // g.nx) % g.ny
    var ib = b % g.nx
    var va = g.v[a]
    var vb = g.v[b]
    var s = (iso - va) / (vb - va) if vb != va else Real(0.5)
    var p = g.node(ia, ja, ka) + (g.node(ib, jb, kb) - g.node(ia, ja, ka)) * s
    var id = len(mesh.verts)
    mesh.verts.append(p)
    w.key_to_vert[key] = id
    return id


def _emit(mut mesh: TriMesh, p: Int, q: Int, r: Int, toward: Vec3):
    """Add triangle (p, q, r) wound so its normal points along `toward`
    (from inside to outside)."""
    var n = cross(mesh.verts[q] - mesh.verts[p], mesh.verts[r] - mesh.verts[p])
    if dot(n, toward) >= 0:
        mesh.tris.append(p)
        mesh.tris.append(q)
        mesh.tris.append(r)
    else:
        mesh.tris.append(p)
        mesh.tris.append(r)
        mesh.tris.append(q)


def marching_tetrahedra(g: ScalarGrid, iso: Real) raises -> TriMesh:
    """The isosurface {value = iso} (module note)."""
    var mesh = TriMesh()
    var w = _Welder()
    var tets = _tets()
    var cx: List[Int] = [0, 1, 1, 0, 0, 1, 1, 0]
    var cy: List[Int] = [0, 0, 1, 1, 0, 0, 1, 1]
    var cz: List[Int] = [0, 0, 0, 0, 1, 1, 1, 1]
    var corner = List[Int](length=8, fill=0)
    for k in range(g.nz - 1):
        for j in range(g.ny - 1):
            for i in range(g.nx - 1):
                for c in range(8):
                    corner[c] = g.idx(i + cx[c], j + cy[c], k + cz[c])
                for t in range(6):
                    var ids = List[Int](length=4, fill=0)
                    var inside = List[Int]()
                    var outside = List[Int]()
                    for q in range(4):
                        ids[q] = corner[tets[4 * t + q]]
                        if g.v[ids[q]] > iso:
                            inside.append(ids[q])
                        else:
                            outside.append(ids[q])
                    if len(inside) == 0 or len(inside) == 4:
                        continue
                    # direction from the inside nodes' mean to the outside nodes' mean
                    var ci = Vec3(0, 0, 0, 0)
                    for q in inside:
                        var kk = q // (g.nx * g.ny)
                        ci = ci + g.node(q % g.nx, (q // g.nx) % g.ny, kk)
                    var co = Vec3(0, 0, 0, 0)
                    for q in outside:
                        var kk = q // (g.nx * g.ny)
                        co = co + g.node(q % g.nx, (q // g.nx) % g.ny, kk)
                    var toward = co * (1 / Real(len(outside))) - ci * (1 / Real(len(inside)))
                    if len(inside) == 1 or len(inside) == 3:
                        var lone = inside[0] if len(inside) == 1 else outside[0]
                        var others = outside.copy() if len(inside) == 1 else inside.copy()
                        var a = _edge_vertex(g, iso, lone, others[0], mesh, w)
                        var b = _edge_vertex(g, iso, lone, others[1], mesh, w)
                        var c2 = _edge_vertex(g, iso, lone, others[2], mesh, w)
                        _emit(mesh, a, b, c2, toward)
                    else:
                        # two in, two out: a quad on the four crossing edges
                        var a = _edge_vertex(g, iso, inside[0], outside[0], mesh, w)
                        var b = _edge_vertex(g, iso, inside[0], outside[1], mesh, w)
                        var c2 = _edge_vertex(g, iso, inside[1], outside[1], mesh, w)
                        var d = _edge_vertex(g, iso, inside[1], outside[0], mesh, w)
                        _emit(mesh, a, b, c2, toward)
                        _emit(mesh, a, c2, d, toward)
    return mesh^


def splat_particles(points: List[Vec3], radius: Real, origin: Vec3, spacing: Real, nx: Int, ny: Int, nz: Int) raises -> ScalarGrid:
    """A node grid of sum_p (1 - |x - p|^2 / R^2)^3 over particles within R."""
    if not (radius > 0):
        raise Error("splat_particles: radius must be > 0")
    var g = ScalarGrid(nx, ny, nz, origin, spacing)
    var r2 = radius * radius
    var reach = Int(radius / spacing) + 1
    for ref p in points:
        var rel = (p - origin) * (1 / spacing)
        var ci = Int(rel[0])
        var cj = Int(rel[1])
        var ck = Int(rel[2])
        for k in range(max(ck - reach, 0), min(ck + reach + 2, nz)):
            for j in range(max(cj - reach, 0), min(cj + reach + 2, ny)):
                for i in range(max(ci - reach, 0), min(ci + reach + 2, nx)):
                    var d = g.node(i, j, k) - p
                    var q = dot(d, d)
                    if q < r2:
                        var s = 1 - q / r2
                        g.v[g.idx(i, j, k)] += s * s * s
    return g^


def sample_sdf(sdf: Sdf3, origin: Vec3, spacing: Real, nx: Int, ny: Int, nz: Int) raises -> ScalarGrid:
    """A node grid of -distance (positive inside the solid)."""
    var g = ScalarGrid(nx, ny, nz, origin, spacing)
    for k in range(nz):
        for j in range(ny):
            for i in range(nx):
                g.v[g.idx(i, j, k)] = -sdf.distance(g.node(i, j, k))
    return g^


def splat_particles_anisotropic(
    points: List[Vec3], radius: Real, origin: Vec3, spacing: Real, nx: Int, ny: Int, nz: Int,
    neighbor_radius: Real, min_neighbors: Int = 25, k_r: Real = 4, smooth: Real = 0.9,
) raises -> ScalarGrid:
    """`splat_particles` with anisotropic kernels (module note)."""
    if not (radius > 0) or not (neighbor_radius > 0):
        raise Error("splat_particles_anisotropic: radius and neighbor_radius must be > 0")
    var n = len(points)
    # neighbours through a uniform grid of cell neighbor_radius
    var lo = origin
    var cell = neighbor_radius
    var cx = max(Int(Real(nx) * spacing / cell) + 2, 1)
    var cy = max(Int(Real(ny) * spacing / cell) + 2, 1)
    var cz = max(Int(Real(nz) * spacing / cell) + 2, 1)
    var cnt = List[Int](length=cx * cy * cz + 1, fill=0)
    var cid = List[Int](length=n, fill=0)
    for p in range(n):
        var a = min(max(Int((points[p][0] - lo[0]) / cell), 0), cx - 1)
        var b = min(max(Int((points[p][1] - lo[1]) / cell), 0), cy - 1)
        var c = min(max(Int((points[p][2] - lo[2]) / cell), 0), cz - 1)
        cid[p] = (c * cy + b) * cx + a
        cnt[cid[p] + 1] += 1
    for q in range(cx * cy * cz):
        cnt[q + 1] += cnt[q]
    var fill = cnt.copy()
    var order = List[Int](length=n, fill=0)
    for p in range(n):
        order[fill[cid[p]]] = p
        fill[cid[p]] += 1
    var g = ScalarGrid(nx, ny, nz, origin, spacing)
    var r2 = radius * radius
    var nr2 = neighbor_radius * neighbor_radius
    for p in range(n):
        var a0 = cid[p] % cx
        var b0 = (cid[p] // cx) % cy
        var c0 = cid[p] // (cx * cy)
        var wsum = Real(0)
        var mean = Vec3(0, 0, 0, 0)
        var nb = List[Int]()
        for c in range(max(c0 - 1, 0), min(c0 + 2, cz)):
            for b in range(max(b0 - 1, 0), min(b0 + 2, cy)):
                for a in range(max(a0 - 1, 0), min(a0 + 2, cx)):
                    var q0 = (c * cy + b) * cx + a
                    for k in range(cnt[q0], cnt[q0 + 1]):
                        var j = order[k]
                        var d = points[j] - points[p]
                        var dd = dot(d, d)
                        if dd < nr2:
                            var w = 1 - (sqrt(dd) / neighbor_radius) ** 3
                            wsum += w
                            mean = mean + points[j] * w
                            nb.append(j)
        var center = points[p]
        # the sphere unless the neighbourhood is well sampled
        var axes = Mat3x3.identity()
        var stretch = Vec3(1, 1, 1, 0)
        var aniso = False
        if len(nb) >= min_neighbors and wsum > 0:
            mean = mean * (1 / wsum)
            var cov = Mat3x3.zero()
            for j in nb:
                var d = points[j] - mean
                var w = 1 - (length(points[j] - points[p]) / neighbor_radius) ** 3
                for r in range(3):
                    for s in range(3):
                        cov.m[r * 3 + s] += w * d[r] * d[s]
            for k in range(9):
                cov.m[k] /= wsum
            var ev = sym_eigen3(cov)
            var sig = ev[0]
            var smax = max(sig[0], max(sig[1], sig[2]))
            if smax > 0:
                var s0 = sqrt(max(sig[0], smax / k_r))
                var s1 = sqrt(max(sig[1], smax / k_r))
                var s2 = sqrt(max(sig[2], smax / k_r))
                var gm = (s0 * s1 * s2) ** (Real(1) / 3)
                stretch = Vec3(s0 / gm, s1 / gm, s2 / gm, 0)
                axes = ev[1]
                aniso = True
            center = points[p] * (1 - smooth) + mean * smooth
        # node reach: the longest semi-axis
        var smax2 = max(stretch[0], max(stretch[1], stretch[2]))
        var reach = Int(radius * smax2 / spacing) + 1
        var rel = (center - origin) * (1 / spacing)
        var ci = Int(rel[0])
        var cj = Int(rel[1])
        var ck = Int(rel[2])
        for k in range(max(ck - reach, 0), min(ck + reach + 2, nz)):
            for j in range(max(cj - reach, 0), min(cj + reach + 2, ny)):
                for i in range(max(ci - reach, 0), min(ci + reach + 2, nx)):
                    var d = g.node(i, j, k) - center
                    # coordinates along the axes, scaled by 1 / stretch (the
                    # sphere as `splat_particles` computes it, bit for bit)
                    var q = dot(d, d)
                    if aniso:
                        q = 0
                        for a in range(3):
                            var u = (axes.m[0 * 3 + a] * d[0] + axes.m[1 * 3 + a] * d[1] + axes.m[2 * 3 + a] * d[2]) / stretch[a]
                            q += u * u
                    if q < r2:
                        var s = 1 - q / r2
                        g.v[g.idx(i, j, k)] += s * s * s
    return g^
