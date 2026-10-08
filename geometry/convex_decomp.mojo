"""Convex decomposition of a (possibly concave) closed triangle mesh
(ROADMAP 17.5, "V-HACD class").

A rigid body in this engine collides as ONE convex hull. A concave solid -- an
L-shaped slab, an arch, a wall with a window -- has to be covered by several,
and that is what this module produces: a list of convex parts whose union
contains the solid.

Both algorithms start from the same VOXELISATION of the mesh (`voxelize`:
column parity along +x, so it needs a closed mesh but tolerates degenerate
triangles, which are skipped), and differ only in how they group voxels:

  * `SplitDecomposer`   hierarchical -- repeatedly cut the part with the most
    hull-versus-voxel excess by the axis plane that minimises the two halves'
    hull volume. This is the V-HACD recursion with the clipping-plane search
    simplified to the three axes.
  * `ClusterDecomposer` flat -- k-means on voxel centres (farthest-point
    initialisation, Lloyd refinement), with k increased until the excess is
    under tolerance.

They sit behind `ConvexDecomposer` (the 17.5 seam), chosen at compile time
(`decompose_with[D]`). What they must agree on, and what `test_convex_decomp`
checks, is the OBSERVABLE contract: every voxel of the solid is inside some part
(coverage 1), the parts add up to no more than a bounded multiple of the solid's
volume, and the parts answer a convex-vs-convex narrowphase query (GJK) the same
way wherever the answer is not a surface-grazing coin flip.

HULL TIGHTNESS: a part's hull is built from the corners of its boundary voxels,
so it is at most one cell larger than the solid in any direction. That is the
resolution knob (`res` in `voxelize`), not an error: it is why the contract above
speaks of a margin.

Excess is `sum(hull volume) - solid volume`, as a fraction of the solid volume.
Overlap between parts counts as excess (it is real waste in the narrowphase), so
a decomposition cannot reach tolerance by covering the same region twice.
"""

from std.math import sqrt, ceil
from .polytope import Polytope, convex_hull


struct VoxelGrid(Movable):
    """Occupancy grid: cell `(i, j, k)` has min corner `o + h * (i, j, k)`;
    `occ` is x-major (`(i * ny + j) * nz + k`), 1 = inside the solid."""

    var nx: Int
    var ny: Int
    var nz: Int
    var ox: Float64
    var oy: Float64
    var oz: Float64
    var h: Float64
    var occ: List[UInt8]

    def __init__(
        out self,
        nx: Int, ny: Int, nz: Int,
        ox: Float64, oy: Float64, oz: Float64, h: Float64,
    ):
        self.nx = nx
        self.ny = ny
        self.nz = nz
        self.ox = ox
        self.oy = oy
        self.oz = oz
        self.h = h
        self.occ = List[UInt8](capacity=nx * ny * nz)
        for _ in range(nx * ny * nz):
            self.occ.append(0)

    def idx(self, i: Int, j: Int, k: Int) -> Int:
        return (i * self.ny + j) * self.nz + k

    def filled(self) -> Int:
        var n = 0
        for c in range(len(self.occ)):
            if self.occ[c] != 0:
                n += 1
        return n

    def solid_volume(self) -> Float64:
        return Float64(self.filled()) * self.h * self.h * self.h

    def is_set(self, i: Int, j: Int, k: Int) -> Bool:
        if i < 0 or j < 0 or k < 0 or i >= self.nx or j >= self.ny or k >= self.nz:
            return False
        return self.occ[self.idx(i, j, k)] != 0

    def center(self, c: Int) -> List[Float64]:
        """World centre of cell id `c`."""
        var k = c % self.nz
        var j = (c // self.nz) % self.ny
        var i = c // (self.nz * self.ny)
        var out = List[Float64](capacity=3)
        out.append(self.ox + (Float64(i) + 0.5) * self.h)
        out.append(self.oy + (Float64(j) + 0.5) * self.h)
        out.append(self.oz + (Float64(k) + 0.5) * self.h)
        return out^


def voxelize(verts: List[Float64], indices: List[Int], res: Int) raises -> VoxelGrid:
    """Voxelise a closed triangle mesh (flat `verts`, three `indices` per
    triangle) with `res` cells along its longest side. Raises on a malformed
    mesh (index out of range, index count not a multiple of 3) or `res < 1`;
    degenerate (zero-area) triangles are skipped. An open mesh yields the
    columns it does enclose (an unmatched trailing crossing is ignored)."""
    if res < 1:
        raise Error("convex_decomp.voxelize: res must be >= 1")
    if len(indices) % 3 != 0 or len(verts) % 3 != 0:
        raise Error("convex_decomp.voxelize: flat arrays must have stride 3")
    var nvert = len(verts) // 3
    for q in range(len(indices)):
        if indices[q] < 0 or indices[q] >= nvert:
            raise Error("convex_decomp.voxelize: triangle index out of range")
    if nvert == 0 or len(indices) == 0:
        return VoxelGrid(0, 0, 0, 0, 0, 0, 1)
    var lo = List[Float64]()
    var hi = List[Float64]()
    for k in range(3):
        lo.append(verts[k])
        hi.append(verts[k])
    for i in range(nvert):
        for k in range(3):
            lo[k] = min(lo[k], verts[3 * i + k])
            hi[k] = max(hi[k], verts[3 * i + k])
    var ext = max(hi[0] - lo[0], max(hi[1] - lo[1], hi[2] - lo[2]))
    if ext <= 0:
        return VoxelGrid(0, 0, 0, 0, 0, 0, 1)
    var h = ext / Float64(res)
    var nx = max(1, Int(ceil((hi[0] - lo[0]) / h - 1e-9)))
    var ny = max(1, Int(ceil((hi[1] - lo[1]) / h - 1e-9)))
    var nz = max(1, Int(ceil((hi[2] - lo[2]) / h - 1e-9)))
    var g = VoxelGrid(nx, ny, nz, lo[0], lo[1], lo[2], h)
    var ntri = len(indices) // 3
    # irrational-ish sub-cell offsets keep a column off every mesh edge that
    # sits on a grid line
    var jy = 0.3183098861837907 * h * 0.5
    var jz = 0.1415926535897932 * h * 0.5
    var xs = List[Float64]()
    for j in range(ny):
        for k in range(nz):
            var py = g.oy + (Float64(j) + 0.5) * h + jy
            var pz = g.oz + (Float64(k) + 0.5) * h + jz
            xs.clear()
            for f in range(ntri):
                var a = 3 * indices[3 * f]
                var b = 3 * indices[3 * f + 1]
                var c = 3 * indices[3 * f + 2]
                var ay = verts[a + 1]
                var az = verts[a + 2]
                var by = verts[b + 1]
                var bz = verts[b + 2]
                var cy = verts[c + 1]
                var cz = verts[c + 2]
                var area2 = (by - ay) * (cz - az) - (bz - az) * (cy - ay)
                if abs(area2) < 1e-300:
                    continue  # degenerate, or parallel to the ray
                var u = ((py - ay) * (cz - az) - (pz - az) * (cy - ay)) / area2
                var v = ((by - ay) * (pz - az) - (bz - az) * (py - ay)) / area2
                if u < 0 or v < 0 or u + v > 1:
                    continue
                xs.append(verts[a] + u * (verts[b] - verts[a]) + v * (verts[c] - verts[a]))
            # sort the crossings
            for q in range(1, len(xs)):
                var xv = xs[q]
                var w = q - 1
                while w >= 0 and xs[w] > xv:
                    xs[w + 1] = xs[w]
                    w -= 1
                xs[w + 1] = xv
            var q = 0
            while q + 1 < len(xs):
                var x0 = xs[q]
                var x1 = xs[q + 1]
                for i in range(nx):
                    var cx = g.ox + (Float64(i) + 0.5) * h
                    if cx >= x0 and cx <= x1:
                        g.occ[g.idx(i, j, k)] = 1
                q += 2
    return g^


def mesh_volume(verts: List[Float64], indices: List[Int]) -> Float64:
    """Signed enclosed volume of a closed mesh (positive for outward CCW)."""
    var vol = Float64(0)
    for f in range(len(indices) // 3):
        var a = 3 * indices[3 * f]
        var b = 3 * indices[3 * f + 1]
        var c = 3 * indices[3 * f + 2]
        vol += (
            verts[a] * (verts[b + 1] * verts[c + 2] - verts[b + 2] * verts[c + 1])
            - verts[a + 1] * (verts[b] * verts[c + 2] - verts[b + 2] * verts[c])
            + verts[a + 2] * (verts[b] * verts[c + 1] - verts[b + 1] * verts[c])
        )
    return vol / 6


@fieldwise_init
struct ConvexParts(Movable):
    """A decomposition: convex `hulls`, and how many voxels each was built
    from (`voxels[i]`)."""

    var hulls: List[Polytope]
    var voxels: List[Int]

    def count(self) -> Int:
        return len(self.hulls)

    def total_volume(self) -> Float64:
        var v = Float64(0)
        for i in range(len(self.hulls)):
            v += self.hulls[i].volume()
        return v

    def excess(self, grid: VoxelGrid) -> Float64:
        """`(sum of part volumes - solid volume) / solid volume`."""
        var sv = grid.solid_volume()
        if sv <= 0:
            return 0
        return (self.total_volume() - sv) / sv

    def covers(self, x: Float64, y: Float64, z: Float64, tol: Float64) -> Bool:
        for i in range(len(self.hulls)):
            if self.hulls[i].contains(x, y, z, tol):
                return True
        return False

    def coverage(self, grid: VoxelGrid) -> Float64:
        """Fraction of the solid's voxels whose centre lies inside some part
        (1.0 by construction for both shipped decomposers; the number is the
        contract's measurable half)."""
        var total = 0
        var hit = 0
        for c in range(len(grid.occ)):
            if grid.occ[c] == 0:
                continue
            total += 1
            var p = grid.center(c)
            if self.covers(p[0], p[1], p[2], 1e-9):
                hit += 1
        if total == 0:
            return 1
        return Float64(hit) / Float64(total)


trait ConvexDecomposer:
    """The 17.5 seam: voxel grid in, convex parts out."""

    def decompose(self, grid: VoxelGrid) -> ConvexParts:
        ...


def decompose_with[D: ConvexDecomposer](d: D, grid: VoxelGrid) -> ConvexParts:
    """Compile-time selection of the algorithm (architecture law v2)."""
    return d.decompose(grid)


# ------------------------------------------------------------------ helpers


def _decode(grid: VoxelGrid, c: Int) -> List[Int]:
    var out = List[Int](capacity=3)
    out.append(c // (grid.nz * grid.ny))
    out.append((c // grid.nz) % grid.ny)
    out.append(c % grid.nz)
    return out^


def _set_hull(grid: VoxelGrid, members: List[Int], mark: List[Int], sid: Int) -> Polytope:
    """Hull of the corners of the boundary voxels of a set (`mark[c] == sid`
    says which cells belong)."""
    var pts = List[Float64](capacity=24 * 64)
    var h = grid.h
    for m in range(len(members)):
        var c = members[m]
        var ijk = _decode(grid, c)
        var i = ijk[0]
        var j = ijk[1]
        var k = ijk[2]
        var inner = True
        for d in range(6):
            var ni = i + (1 if d == 0 else (-1 if d == 1 else 0))
            var nj = j + (1 if d == 2 else (-1 if d == 3 else 0))
            var nk = k + (1 if d == 4 else (-1 if d == 5 else 0))
            if ni < 0 or nj < 0 or nk < 0 or ni >= grid.nx or nj >= grid.ny or nk >= grid.nz:
                inner = False
                break
            if mark[grid.idx(ni, nj, nk)] != sid:
                inner = False
                break
        if inner:
            continue
        for q in range(8):
            pts.append(grid.ox + (Float64(i + ((q >> 2) & 1))) * h)
            pts.append(grid.oy + (Float64(j + ((q >> 1) & 1))) * h)
            pts.append(grid.oz + (Float64(k + (q & 1))) * h)
    return convex_hull(pts).simplified(grid.h * 1e-7)


def _all_cells(grid: VoxelGrid) -> List[Int]:
    var out = List[Int]()
    for c in range(len(grid.occ)):
        if grid.occ[c] != 0:
            out.append(c)
    return out^


# ------------------------------------------------------------------- split


@fieldwise_init
struct SplitDecomposer(ConvexDecomposer, Copyable, Movable):
    """Hierarchical axis-plane splitting, worst part first (see module doc)."""

    var max_parts: Int
    var tol: Float64  # stop when excess <= tol (fraction of solid volume)
    var max_cuts: Int  # candidate cut planes tried per axis

    def decompose(self, grid: VoxelGrid) -> ConvexParts:
        var hulls = List[Polytope]()
        var counts = List[Int]()
        var cells = _all_cells(grid)
        if len(cells) == 0:
            return ConvexParts(hulls^, counts^)
        var solid = Float64(len(cells)) * grid.h * grid.h * grid.h
        var mark = List[Int](capacity=len(grid.occ))
        for _ in range(len(grid.occ)):
            mark.append(-1)
        # working sets: members, hull, hull-excess
        var sets = List[List[Int]]()
        var set_hull = List[Polytope]()
        var excess = List[Float64]()
        var next_id = 0
        for c in range(len(cells)):
            mark[cells[c]] = next_id
        var h0 = _set_hull(grid, cells, mark, next_id)
        var v0 = Float64(len(cells)) * grid.h * grid.h * grid.h
        excess.append(h0.volume() - v0)
        set_hull.append(h0^)
        sets.append(cells^)
        var ids = List[Int]()
        ids.append(next_id)
        next_id += 1
        var guard = 0
        while len(sets) < self.max_parts and guard < 4 * self.max_parts + 8:
            guard += 1
            var w = 0
            for s in range(1, len(sets)):
                if excess[s] > excess[w]:
                    w = s
            if excess[w] <= self.tol * solid or len(sets[w]) < 2:
                break
            # best cut of set w
            var members = sets[w].copy()
            var lo = List[Int]()
            var hi = List[Int]()
            for _ in range(3):
                lo.append(1 << 30)
                hi.append(-1)
            for m in range(len(members)):
                var ijk = _decode(grid, members[m])
                for a in range(3):
                    lo[a] = min(lo[a], ijk[a])
                    hi[a] = max(hi[a], ijk[a])
            var best_cost = Float64(1e300)
            var best_axis = -1
            var best_cut = 0
            for a in range(3):
                var span = hi[a] - lo[a]
                if span < 1:
                    continue
                var ncand = min(span, self.max_cuts)
                for q in range(ncand):
                    var cut = lo[a] + 1 + (q * span) // ncand
                    if q > 0 and cut == lo[a] + 1 + ((q - 1) * span) // ncand:
                        continue
                    var left = List[Int]()
                    var right = List[Int]()
                    for m in range(len(members)):
                        var ijk = _decode(grid, members[m])
                        if ijk[a] < cut:
                            left.append(members[m])
                        else:
                            right.append(members[m])
                    if len(left) == 0 or len(right) == 0:
                        continue
                    for m in range(len(left)):
                        mark[left[m]] = next_id
                    for m in range(len(right)):
                        mark[right[m]] = next_id + 1
                    var hl = _set_hull(grid, left, mark, next_id)
                    var hr = _set_hull(grid, right, mark, next_id + 1)
                    next_id += 2
                    var cost = hl.volume() + hr.volume()
                    if cost < best_cost:
                        best_cost = cost
                        best_axis = a
                        best_cut = cut
            if best_axis < 0:
                excess[w] = -1  # unsplittable: never pick it again
                continue
            var left = List[Int]()
            var right = List[Int]()
            for m in range(len(members)):
                var ijk = _decode(grid, members[m])
                if ijk[best_axis] < best_cut:
                    left.append(members[m])
                else:
                    right.append(members[m])
            for m in range(len(left)):
                mark[left[m]] = next_id
            for m in range(len(right)):
                mark[right[m]] = next_id + 1
            var hl = _set_hull(grid, left, mark, next_id)
            var hr = _set_hull(grid, right, mark, next_id + 1)
            next_id += 2
            var gv = grid.h * grid.h * grid.h
            var el = hl.volume() - Float64(len(left)) * gv
            var er = hr.volume() - Float64(len(right)) * gv
            sets[w] = left^
            set_hull[w] = hl^
            excess[w] = el
            sets.append(right^)
            set_hull.append(hr^)
            excess.append(er)
        for s in range(len(sets)):
            if set_hull[s].is_empty():
                continue
            counts.append(len(sets[s]))
            hulls.append(set_hull[s].copy())
        return ConvexParts(hulls^, counts^)


# ----------------------------------------------------------------- cluster


@fieldwise_init
struct ClusterDecomposer(ConvexDecomposer, Copyable, Movable):
    """K-means on voxel centres, k grown until the excess is within tolerance."""

    var max_parts: Int
    var tol: Float64
    var iters: Int  # Lloyd iterations per k

    def _kmeans(self, grid: VoxelGrid, cells: List[Int], k: Int) -> List[Int]:
        """Cluster id (0..k-1) per entry of `cells`."""
        var n = len(cells)
        var px = List[Float64](capacity=n)
        var py = List[Float64](capacity=n)
        var pz = List[Float64](capacity=n)
        for m in range(n):
            var c = grid.center(cells[m])
            px.append(c[0])
            py.append(c[1])
            pz.append(c[2])
        var cx = List[Float64]()
        var cy = List[Float64]()
        var cz = List[Float64]()
        cx.append(px[0])
        cy.append(py[0])
        cz.append(pz[0])
        var dmin = List[Float64](capacity=n)
        for m in range(n):
            var dx = px[m] - px[0]
            var dy = py[m] - py[0]
            var dz = pz[m] - pz[0]
            dmin.append(dx * dx + dy * dy + dz * dz)
        while len(cx) < k:
            var far = 0
            for m in range(n):
                if dmin[m] > dmin[far]:
                    far = m
            if dmin[far] <= 0:
                break
            cx.append(px[far])
            cy.append(py[far])
            cz.append(pz[far])
            for m in range(n):
                var dx = px[m] - px[far]
                var dy = py[m] - py[far]
                var dz = pz[m] - pz[far]
                dmin[m] = min(dmin[m], dx * dx + dy * dy + dz * dz)
        var kk = len(cx)
        var lab = List[Int](capacity=n)
        for _ in range(n):
            lab.append(0)
        for _ in range(self.iters):
            for m in range(n):
                var bd = Float64(1e300)
                var bi = 0
                for q in range(kk):
                    var dx = px[m] - cx[q]
                    var dy = py[m] - cy[q]
                    var dz = pz[m] - cz[q]
                    var dd = dx * dx + dy * dy + dz * dz
                    if dd < bd:
                        bd = dd
                        bi = q
                lab[m] = bi
            var sx = List[Float64]()
            var sy = List[Float64]()
            var sz = List[Float64]()
            var sn = List[Int]()
            for _ in range(kk):
                sx.append(0)
                sy.append(0)
                sz.append(0)
                sn.append(0)
            for m in range(n):
                sx[lab[m]] += px[m]
                sy[lab[m]] += py[m]
                sz[lab[m]] += pz[m]
                sn[lab[m]] += 1
            for q in range(kk):
                if sn[q] > 0:
                    cx[q] = sx[q] / Float64(sn[q])
                    cy[q] = sy[q] / Float64(sn[q])
                    cz[q] = sz[q] / Float64(sn[q])
        return lab^

    def _build(self, grid: VoxelGrid, cells: List[Int], k: Int) -> ConvexParts:
        var lab = self._kmeans(grid, cells, k)
        var kk = 0
        for m in range(len(lab)):
            kk = max(kk, lab[m] + 1)
        var mark = List[Int](capacity=len(grid.occ))
        for _ in range(len(grid.occ)):
            mark.append(-1)
        var groups = List[List[Int]]()
        for _ in range(kk):
            groups.append(List[Int]())
        for m in range(len(cells)):
            mark[cells[m]] = lab[m]
            groups[lab[m]].append(cells[m])
        var hulls = List[Polytope]()
        var counts = List[Int]()
        for q in range(kk):
            if len(groups[q]) == 0:
                continue
            var hq = _set_hull(grid, groups[q], mark, q)
            if hq.is_empty():
                continue
            counts.append(len(groups[q]))
            hulls.append(hq^)
        return ConvexParts(hulls^, counts^)

    def decompose(self, grid: VoxelGrid) -> ConvexParts:
        var cells = _all_cells(grid)
        if len(cells) == 0:
            return ConvexParts(List[Polytope](), List[Int]())
        var k = 1
        var parts = self._build(grid, cells, k)
        while parts.excess(grid) > self.tol and k < self.max_parts:
            k = k + 1 if k < 4 else (k * 3) // 2 + 1
            if k > self.max_parts:
                k = self.max_parts
            parts = self._build(grid, cells, k)
        return parts^
