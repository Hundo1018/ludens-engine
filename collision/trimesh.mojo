"""Static level geometry: triangle meshes and heightfields.

Everything the solver could stand on until now was a closed convex body. A
level is not convex, so there was no way to express one — the gap that makes
this table stakes rather than a refinement.

The contact itself is not new work. A triangle IS a convex hull, just a
degenerate one with three vertices and a single face, so `collision/hull.mojo`
already knows how to clip a box or a hull against it. What static geometry adds
is the MIDPHASE: a level has thousands of triangles and a falling crate touches
three of them, so the question is which triangles to hand to the narrowphase.

Two answers are implemented, because they scale differently and the engine's
rule is that comparable methods get compared:

  `TriMesh`     — arbitrary soup, indexed by a BVH over triangle boxes. Handles
                  overhangs, walls, and anything an artist exports. Query cost
                  is O(log T) plus the overlap set.
  `HeightField` — a regular grid sampled as a height per cell corner, with the
                  triangulation left implicit. Cannot express an overhang, but
                  the candidate lookup is arithmetic: clamp the query box to
                  cell indices and read them off, no tree, no memory to touch
                  outside the footprint. O(1) in the terrain's size.

They expose the same two operations (`candidates`, `tri`), so the solver has
one code path and the benchmark can put them side by side on identical terrain.

Vertex storage is flat `List[Real]`, stride 3. On this nightly a `List[Vec3]`
silently loses its tail elements the moment it crosses a function boundary —
`collision/hull.mojo` carries the reduced probe.
"""

from std.math import sqrt, floor
from geometry.vec import Real, Vec3, dot, length, normalize
from geometry.aabb import AABB
from geometry.bvh import BVH
from geometry.gjk import ConvexPoly


def _tri_normal(a: Vec3, b: Vec3, c: Vec3) -> Vec3:
    """Outward normal from the winding, or zero for a degenerate triangle.

    Degenerate triangles are returned as zero rather than skipped so that
    triangle indices stay stable: a mesh's triangle 7 must be triangle 7 after
    any change here, because contact warm-starting keys on that index."""
    var e1 = b - a
    var e2 = c - a
    var n = Vec3(
        e1[1] * e2[2] - e1[2] * e2[1],
        e1[2] * e2[0] - e1[0] * e2[2],
        e1[0] * e2[1] - e1[1] * e2[0],
    )
    var l = length(n)
    if l < 1e-12:
        return Vec3(0, 0, 0)
    return n / l


struct TriMesh(Movable, ImplicitlyDeletable):
    """A static triangle soup with a BVH midphase.

    Normals are stored per triangle rather than recomputed per query. They are
    the reason mesh contact works at all: the narrowphase picks its separating
    axis by minimum penetration over the two shapes' face normals, and a
    triangle contributes exactly one — its own. Without it a crate landing on a
    ramp would be pushed along whichever of ITS faces happened to overlap
    least, which is the box's axis, not the slope's.

    Single-sided, by the winding. A level's triangles have an inside, and
    accepting contact from behind would let a fast body that has already
    tunnelled be pushed further through instead of back out."""

    var v: List[Real]  # vertices, stride 3
    var idx: List[Int]  # 3 vertex indices per triangle
    var nrm: List[Real]  # one outward normal per triangle, stride 3
    var bvh: BVH[3]

    def __init__(out self, verts: List[Real], indices: List[Int]):
        self.v = List[Real](capacity=len(verts))
        for i in range(len(verts)):
            self.v.append(verts[i])
        self.idx = List[Int](capacity=len(indices))
        for i in range(len(indices)):
            self.idx.append(indices[i])
        var nt = len(self.idx) // 3
        self.nrm = List[Real](capacity=3 * nt)
        self.bvh = BVH[3]()  # before any self method call: all fields must be live
        var boxes = List[AABB[3]](capacity=nt)
        var proxies = List[Int](capacity=nt)
        for t in range(nt):
            var a = self._vert(self.idx[3 * t])
            var b = self._vert(self.idx[3 * t + 1])
            var c = self._vert(self.idx[3 * t + 2])
            var n = _tri_normal(a, b, c)
            self.nrm.append(n[0])
            self.nrm.append(n[1])
            self.nrm.append(n[2])
            var lo = Vec3(0, 0, 0)
            var hi = Vec3(0, 0, 0)
            comptime for k in range(3):
                lo[k] = min(a[k], min(b[k], c[k]))
                hi[k] = max(a[k], max(b[k], c[k]))
            boxes.append(AABB[3](lo, hi))
            proxies.append(t)
        if nt > 0:
            # SAH: a level is built once and queried every step of every frame,
            # so build time is the cheap side of the trade by a wide margin.
            self.bvh.build_boxes(boxes, proxies, sah=True)

    def _vert(self, i: Int) -> Vec3:
        return Vec3(self.v[3 * i], self.v[3 * i + 1], self.v[3 * i + 2])

    def ntri(self) -> Int:
        return len(self.idx) // 3

    def tri(self, t: Int) -> ConvexPoly[3]:
        var p = ConvexPoly[3]()
        p.add(self._vert(self.idx[3 * t]))
        p.add(self._vert(self.idx[3 * t + 1]))
        p.add(self._vert(self.idx[3 * t + 2]))
        return p^

    def tri_faces(self, t: Int) -> List[Real]:
        """The triangle's single face normal, flat — the `faces_b` the hull
        narrowphase expects. EMPTY for a zero-area triangle, which is how the
        solver is told to skip it: such a triangle is still a perfectly valid
        convex object (a segment or a point), so GJK will happily report a hit
        against it and a crate will come to rest balanced on a mathematical
        line. Having no surface, it must contribute no contact."""
        var f = List[Real](capacity=3)
        var n = Vec3(self.nrm[3 * t], self.nrm[3 * t + 1], self.nrm[3 * t + 2])
        if length(n) < 0.5:  # stored normals are unit or exactly zero
            return f^
        f.append(n[0])
        f.append(n[1])
        f.append(n[2])
        return f^

    def candidates(self, box: AABB[3], mut out: List[Int]):
        self.bvh.query_region(box, out)

    def bounds(self) -> AABB[3]:
        var n = len(self.v) // 3
        if n == 0:
            return AABB[3](Vec3(0, 0, 0), Vec3(0, 0, 0))
        var lo = self._vert(0)
        var hi = self._vert(0)
        for i in range(1, n):
            var p = self._vert(i)
            comptime for k in range(3):
                lo[k] = min(lo[k], p[k])
                hi[k] = max(hi[k], p[k])
        return AABB[3](lo, hi)


struct HeightField(Movable, ImplicitlyDeletable):
    """A regular grid of heights, triangulated implicitly.

    `h[iz * nx + ix]` is the height at grid corner (ix, iz); the cell between
    four corners is two triangles split along its (ix+iz) diagonal, alternating
    per cell so the tessellation has no directional bias — a ball rolled across
    a uniform slope should not drift sideways because every diagonal ran the
    same way.

    The triangles are never stored. `candidates` converts a query box straight
    into a range of cell indices, which is what makes this O(1) in the size of
    the terrain instead of O(log T): a 512x512 field is 522,242 triangles that
    a BVH would have to be built over, sorted, and traversed, and none of that
    memory is touched here."""

    var h: List[Real]
    var nx: Int
    var nz: Int
    var cell: Real
    var ox: Real  # world x of grid corner (0, 0)
    var oz: Real

    def __init__(
        out self, heights: List[Real], nx: Int, nz: Int,
        cell: Real, ox: Real = 0, oz: Real = 0,
    ):
        self.h = List[Real](capacity=len(heights))
        for i in range(len(heights)):
            self.h.append(heights[i])
        self.nx = nx
        self.nz = nz
        self.cell = cell
        self.ox = ox
        self.oz = oz

    def ntri(self) -> Int:
        if self.nx < 2 or self.nz < 2:
            return 0
        return (self.nx - 1) * (self.nz - 1) * 2

    def _corner(self, ix: Int, iz: Int) -> Vec3:
        var cx = min(max(ix, 0), self.nx - 1)
        var cz = min(max(iz, 0), self.nz - 1)
        return Vec3(
            self.ox + Real(cx) * self.cell,
            self.h[cz * self.nx + cx],
            self.oz + Real(cz) * self.cell,
        )

    def tri(self, t: Int) -> ConvexPoly[3]:
        """Triangle `t` of the implicit tessellation. Two per cell, in
        row-major cell order, so the index is stable for warm-starting."""
        var p = ConvexPoly[3]()
        if self.nx < 2 or self.nz < 2:
            return p^
        var per_row = (self.nx - 1) * 2
        var iz = t // per_row
        var rem = t - iz * per_row
        var ix = rem // 2
        var second = (rem & 1) == 1
        var v00 = self._corner(ix, iz)
        var v10 = self._corner(ix + 1, iz)
        var v01 = self._corner(ix, iz + 1)
        var v11 = self._corner(ix + 1, iz + 1)
        # Alternating diagonal, so the tessellation carries no net direction.
        if ((ix + iz) & 1) == 0:
            if not second:
                p.add(v00)
                p.add(v01)
                p.add(v11)
            else:
                p.add(v00)
                p.add(v11)
                p.add(v10)
        else:
            if not second:
                p.add(v00)
                p.add(v01)
                p.add(v10)
            else:
                p.add(v10)
                p.add(v01)
                p.add(v11)
        return p^

    def tri_faces(self, t: Int) -> List[Real]:
        var p = self.tri(t)
        var f = List[Real](capacity=3)
        if len(p.points) < 3:
            return f^
        var n = _tri_normal(p.points[0].v, p.points[1].v, p.points[2].v)
        if length(n) < 0.5:
            return f^  # degenerate cell: no surface, no contact
        if n[1] < 0:
            n = -n  # terrain faces up; winding is an implementation detail here
        f.append(n[0])
        f.append(n[1])
        f.append(n[2])
        return f^

    def candidates(self, box: AABB[3], mut out: List[Int]):
        """Cells overlapping the query box, as triangle indices. No tree: the
        box's x/z range maps directly onto cell indices."""
        if self.nx < 2 or self.nz < 2:
            return
        var per_row = (self.nx - 1) * 2
        var x0 = Int(floor(Float64((box.min[0] - self.ox) / self.cell)))
        var x1 = Int(floor(Float64((box.max[0] - self.ox) / self.cell)))
        var z0 = Int(floor(Float64((box.min[2] - self.oz) / self.cell)))
        var z1 = Int(floor(Float64((box.max[2] - self.oz) / self.cell)))
        x0 = min(max(x0, 0), self.nx - 2)
        x1 = min(max(x1, 0), self.nx - 2)
        z0 = min(max(z0, 0), self.nz - 2)
        z1 = min(max(z1, 0), self.nz - 2)
        if box.max[0] < self.ox or box.min[0] > self.ox + Real(self.nx - 1) * self.cell:
            return
        if box.max[2] < self.oz or box.min[2] > self.oz + Real(self.nz - 1) * self.cell:
            return
        for iz in range(z0, z1 + 1):
            for ix in range(x0, x1 + 1):
                # The y test is what keeps the candidate set honest: a box high
                # above the terrain overlaps the cell in x/z but touches
                # nothing, and reporting it would make this look cheaper than a
                # BVH while doing more narrowphase work.
                var lo = self._corner(ix, iz)[1]
                var hi = lo
                comptime for c in range(4):
                    var y = self._corner(ix + (c & 1), iz + (c >> 1))[1]
                    lo = min(lo, y)
                    hi = max(hi, y)
                if box.max[1] < lo or box.min[1] > hi:
                    continue
                out.append((iz * per_row) + ix * 2)
                out.append((iz * per_row) + ix * 2 + 1)

    def bounds(self) -> AABB[3]:
        if len(self.h) == 0:
            return AABB[3](Vec3(0, 0, 0), Vec3(0, 0, 0))
        var lo = self.h[0]
        var hi = self.h[0]
        for i in range(1, len(self.h)):
            lo = min(lo, self.h[i])
            hi = max(hi, self.h[i])
        return AABB[3](
            Vec3(self.ox, lo, self.oz),
            Vec3(
                self.ox + Real(self.nx - 1) * self.cell,
                hi,
                self.oz + Real(self.nz - 1) * self.cell,
            ),
        )

    def to_trimesh(self) -> TriMesh:
        """The same surface as an explicit soup — the parity reference. If the
        two disagree on a resting height, one of the two candidate paths is
        wrong, and the test says which."""
        var verts = List[Real](capacity=3 * self.nx * self.nz)
        for iz in range(self.nz):
            for ix in range(self.nx):
                var c = self._corner(ix, iz)
                verts.append(c[0])
                verts.append(c[1])
                verts.append(c[2])
        var nt = self.ntri()
        var idx = List[Int](capacity=3 * nt)
        for t in range(nt):
            var p = self.tri(t)
            for k in range(3):
                # Recover the corner index from the position: the grid is
                # regular, so this is exact arithmetic, not a search.
                var q = p.points[k].v
                var ix = Int(
                    floor(Float64((q[0] - self.ox) / self.cell + 0.5))
                )
                var iz = Int(
                    floor(Float64((q[2] - self.oz) / self.cell + 0.5))
                )
                idx.append(iz * self.nx + ix)
        return TriMesh(verts, idx)
