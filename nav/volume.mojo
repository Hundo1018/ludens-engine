"""3D volume navigation for flying / swimming agents (ROADMAP 17.14).

A navmesh only covers walkable surfaces. `VolumeNav` covers free space:

1. occupancy -- the input triangles go through the same per-column clipping
   rasteriser as the navmesh bake (`nav.heightfield.rasterize`) with cubic
   voxels; every solid span marks its voxels;
2. clearance -- occupancy is dilated by `ceil(agent_radius / voxel)` voxels
   (box dilation, separable; a superset of the ball, so conservative);
3. sparse voxel octree -- the padded power-of-two cube is split while a node
   holds both free and blocked voxels (O(1) per node from a summed-volume
   table); uniform nodes become leaves. Free leaves are the graph nodes;
   two are adjacent when they share part of a face.

Seam `VolumeFinder`, two variants answering (start, goal) -> polyline:
- `SvoAStar`: A* over free octree leaves with the portal cost model (a
  node sits at the centre of the face patch it was entered through), then
  line-of-sight smoothing. Large open regions are single nodes, so the
  search is small.
- `VoxelAStar`: A* over free voxels, 26-connected without corner cutting
  (a diagonal step needs every axis-aligned intermediate voxel free); the
  dense reference. `SmoothedVoxelAStar` adds the same smoothing.

`VolumeNav.line_of_sight` walks the voxels a segment passes through
(Amanatides-Woo; at an exact edge / corner crossing every voxel touched
must be free), so smoothed segments never clip a blocked voxel.
"""

from std.math import sqrt, floor, ceil
from geometry.vec import Real, Vec3, dot
from nav.heightfield import NavBakeConfig, Heightfield, rasterize
from nav.navmesh import dist3
from nav.path import NavPath, MinHeap, PATH_WALK

comptime _SQRT2: Real = 1.4142135623730951
comptime _SQRT3: Real = 1.7320508075688772


@fieldwise_init
struct VolumeConfig(Copyable, ImplicitlyCopyable, Movable):
    var voxel: Real  # cubic voxel side (m)
    var agent_radius: Real  # clearance kept from solid geometry (m)

    def validate(self) raises:
        if self.voxel <= 0 or self.agent_radius < 0:
            raise Error("VolumeConfig: voxel > 0 and agent_radius >= 0 required")


struct VolumeNav(Movable):
    var cfg: VolumeConfig
    var bmin: Vec3
    var nx: Int
    var ny: Int
    var nz: Int
    var blocked: List[Bool]  # dilated occupancy, x + nx * (y + ny * z)
    var size: Int  # octree cube side in voxels (power of two)
    # octree nodes
    var n_x: List[Int]
    var n_y: List[Int]
    var n_z: List[Int]
    var n_size: List[Int]
    var n_child: List[Int]  # first of 8 children, -1 = leaf
    var n_free: List[Bool]  # leaf is free space
    var n_leaf: List[Int]  # free leaf -> graph node id (-1 otherwise)
    # graph over free leaves
    var g_node: List[Int]  # graph id -> octree node
    var g_start: List[Int]  # CSR
    var g_adj: List[Int]

    def __init__(out self, verts: List[Vec3], tris: List[Int], lo: Vec3, hi: Vec3, cfg: VolumeConfig) raises:
        """Free space inside the box [lo, hi] around the triangles."""
        cfg.validate()
        for a in range(3):
            if not (lo[a] < hi[a]):
                raise Error("VolumeNav: lo must be < hi on every axis")
        self.cfg = cfg
        var vs = cfg.voxel
        self.bmin = lo
        self.nx = Int(ceil((hi[0] - lo[0]) / vs))
        self.ny = Int(ceil((hi[1] - lo[1]) / vs))
        self.nz = Int(ceil((hi[2] - lo[2]) / vs))
        var n = self.nx * self.ny * self.nz
        var occ = List[Bool](length=n, fill=False)
        if len(tris) > 0:
            var hf = Heightfield(lo, hi, vs, vs)
            # slope / climb values are irrelevant here: only solid extents are read
            var rc = NavBakeConfig(vs, vs, vs, 0, 0, 45.0, 1)
            rasterize(hf, verts, tris, rc)
            for z in range(self.nz):
                for x in range(self.nx):
                    if x >= hf.width or z >= hf.depth:
                        continue
                    var s = hf.head[x + z * hf.width]
                    while s >= 0:
                        for y in range(max(hf.smin[s], 0), min(hf.smax[s], self.ny)):
                            occ[x + self.nx * (y + self.ny * z)] = True
                        s = hf.next[s]
        self.blocked = _dilate(occ, self.nx, self.ny, self.nz, Int(ceil(cfg.agent_radius / vs)))
        self.size = 1
        while self.size < max(self.nx, max(self.ny, self.nz)):
            self.size *= 2
        self.n_x = List[Int]()
        self.n_y = List[Int]()
        self.n_z = List[Int]()
        self.n_size = List[Int]()
        self.n_child = List[Int]()
        self.n_free = List[Bool]()
        self.n_leaf = List[Int]()
        self.g_node = List[Int]()
        self.g_start = List[Int]()
        self.g_adj = List[Int]()
        self._build_tree()
        self._build_graph()

    # ------------------------------------------------------------ voxels

    def idx(self, x: Int, y: Int, z: Int) -> Int:
        return x + self.nx * (y + self.ny * z)

    def is_free(self, x: Int, y: Int, z: Int) -> Bool:
        """Outside the grid counts as blocked."""
        if x < 0 or y < 0 or z < 0 or x >= self.nx or y >= self.ny or z >= self.nz:
            return False
        return not self.blocked[self.idx(x, y, z)]

    def voxel_of(self, p: Vec3) -> SIMD[DType.int64, 4]:
        var vs = self.cfg.voxel
        return SIMD[DType.int64, 4](
            Int64(Int(floor((p[0] - self.bmin[0]) / vs))),
            Int64(Int(floor((p[1] - self.bmin[1]) / vs))),
            Int64(Int(floor((p[2] - self.bmin[2]) / vs))),
            0,
        )

    def voxel_center(self, x: Int, y: Int, z: Int) -> Vec3:
        var vs = self.cfg.voxel
        return self.bmin + Vec3((Real(x) + 0.5) * vs, (Real(y) + 0.5) * vs, (Real(z) + 0.5) * vs, 0)

    def point_free(self, p: Vec3) -> Bool:
        var v = self.voxel_of(p)
        return self.is_free(Int(v[0]), Int(v[1]), Int(v[2]))

    def free_voxels(self) -> Int:
        var n = 0
        for b in self.blocked:
            if not b:
                n += 1
        return n

    # ------------------------------------------------------------ octree

    def _build_tree(mut self):
        var sv = _summed(self.blocked, self.nx, self.ny, self.nz)
        self._push_node(0, 0, 0, self.size)
        var i = 0
        while i < len(self.n_size):
            var x = self.n_x[i]
            var y = self.n_y[i]
            var z = self.n_z[i]
            var s = self.n_size[i]
            var total = s * s * s
            var nb = _count_blocked(sv, self.nx, self.ny, self.nz, x, y, z, s)
            if nb == total or s == 1:
                self.n_free[i] = nb == 0
            elif nb == 0:
                self.n_free[i] = True
            else:
                var h = s // 2
                self.n_child[i] = len(self.n_size)
                for c in range(8):
                    self._push_node(x + (c & 1) * h, y + ((c >> 1) & 1) * h, z + ((c >> 2) & 1) * h, h)
            i += 1
        self.n_leaf = List[Int](length=len(self.n_size), fill=-1)
        for k in range(len(self.n_size)):
            if self.n_child[k] < 0 and self.n_free[k]:
                self.n_leaf[k] = len(self.g_node)
                self.g_node.append(k)

    def _push_node(mut self, x: Int, y: Int, z: Int, s: Int):
        self.n_x.append(x)
        self.n_y.append(y)
        self.n_z.append(z)
        self.n_size.append(s)
        self.n_child.append(-1)
        self.n_free.append(False)

    def locate(self, x: Int, y: Int, z: Int) -> Int:
        """Octree leaf holding voxel (x, y, z); -1 outside the cube."""
        if x < 0 or y < 0 or z < 0 or x >= self.size or y >= self.size or z >= self.size:
            return -1
        var k = 0
        while self.n_child[k] >= 0:
            var h = self.n_size[k] // 2
            var c = (1 if x >= self.n_x[k] + h else 0) | (2 if y >= self.n_y[k] + h else 0) | (
                4 if z >= self.n_z[k] + h else 0
            )
            k = self.n_child[k] + c
        return k

    def leaf_graph_node(self, p: Vec3) -> Int:
        var v = self.voxel_of(p)
        if not self.is_free(Int(v[0]), Int(v[1]), Int(v[2])):
            return -1
        var k = self.locate(Int(v[0]), Int(v[1]), Int(v[2]))
        return self.n_leaf[k] if k >= 0 else -1

    def _build_graph(mut self):
        var ng = len(self.g_node)
        self.g_start = List[Int](length=ng + 1, fill=0)
        var adj = List[List[Int]]()
        for _ in range(ng):
            adj.append(List[Int]())
        for g in range(ng):
            var k = self.g_node[g]
            var x0 = self.n_x[k]
            var y0 = self.n_y[k]
            var z0 = self.n_z[k]
            var s = self.n_size[k]
            # +x, +y, +z faces only; the relation is symmetric
            for axis in range(3):
                for u in range(s):
                    for w in range(s):
                        var x: Int
                        var y: Int
                        var z: Int
                        match axis:
                            case 0:
                                x = x0 + s
                                y = y0 + u
                                z = z0 + w
                            case 1:
                                x = x0 + u
                                y = y0 + s
                                z = z0 + w
                            case _:
                                x = x0 + u
                                y = y0 + w
                                z = z0 + s
                        if not self.is_free(x, y, z):
                            continue
                        var m = self.locate(x, y, z)
                        var h = self.n_leaf[m] if m >= 0 else -1
                        if h < 0:
                            continue
                        var dup = False
                        for e in adj[g]:
                            if e == h:
                                dup = True
                                break
                        if not dup:
                            adj[g].append(h)
                            adj[h].append(g)
        for g in range(ng):
            self.g_start[g + 1] = self.g_start[g] + len(adj[g])
        self.g_adj = List[Int](capacity=self.g_start[ng])
        for g in range(ng):
            for e in adj[g]:
                self.g_adj.append(e)

    def leaf_center(self, g: Int) -> Vec3:
        var k = self.g_node[g]
        var vs = self.cfg.voxel
        var h = Real(self.n_size[k]) * 0.5
        var c = self.bmin + Vec3(
            (Real(self.n_x[k]) + h) * vs, (Real(self.n_y[k]) + h) * vs, (Real(self.n_z[k]) + h) * vs, 0
        )
        return c

    def node_count(self) -> Int:
        return len(self.n_size)

    def leaf_count(self) -> Int:
        return len(self.g_node)

    # ------------------------------------------------------------ line of sight

    def line_of_sight(self, a: Vec3, b: Vec3) -> Bool:
        """Every voxel the segment a -> b touches is free."""
        var vs = self.cfg.voxel
        var va = self.voxel_of(a)
        var vb = self.voxel_of(b)
        var x = Int(va[0])
        var y = Int(va[1])
        var z = Int(va[2])
        if not self.is_free(x, y, z):
            return False
        var d = b - a
        var step = SIMD[DType.int64, 4](0)
        var tmax = Vec3(Real(1e30), Real(1e30), Real(1e30), 0)
        var tdel = Vec3(Real(1e30), Real(1e30), Real(1e30), 0)
        var cur = SIMD[DType.int64, 4](Int64(x), Int64(y), Int64(z), 0)
        for ax in range(3):
            if d[ax] > 0:
                step[ax] = 1
                tdel[ax] = vs / d[ax]
                tmax[ax] = (self.bmin[ax] + Real(Int(cur[ax]) + 1) * vs - a[ax]) / d[ax]
            elif d[ax] < 0:
                step[ax] = -1
                tdel[ax] = -vs / d[ax]
                tmax[ax] = (self.bmin[ax] + Real(Int(cur[ax])) * vs - a[ax]) / d[ax]
        var guard = 3 * (self.nx + self.ny + self.nz) + 8
        while (cur[0] != vb[0] or cur[1] != vb[1] or cur[2] != vb[2]) and guard > 0:
            guard -= 1
            var t = min(tmax[0], min(tmax[1], tmax[2]))
            if t > 1:
                break
            # every axis reaching its boundary at t steps; touched voxels:
            # each single-axis step and the combined one
            var axes = List[Int]()
            for ax in range(3):
                if tmax[ax] <= t + Real(1e-6):
                    axes.append(ax)
            if len(axes) > 1:
                for k in range(len(axes)):
                    var p = cur
                    p[axes[k]] += step[axes[k]]
                    if not self.is_free(Int(p[0]), Int(p[1]), Int(p[2])):
                        return False
                if len(axes) == 3:
                    for k in range(3):
                        var p = cur
                        for m in range(3):
                            if m != k:
                                p[m] += step[m]
                        if not self.is_free(Int(p[0]), Int(p[1]), Int(p[2])):
                            return False
            for k in range(len(axes)):
                cur[axes[k]] += step[axes[k]]
                tmax[axes[k]] += tdel[axes[k]]
            if not self.is_free(Int(cur[0]), Int(cur[1]), Int(cur[2])):
                return False
        return True


def _dilate(occ: List[Bool], nx: Int, ny: Int, nz: Int, r: Int) -> List[Bool]:
    """Separable box dilation by r voxels along each axis."""
    if r <= 0:
        return occ.copy()
    var cur = occ.copy()
    for axis in range(3):
        var nxt = List[Bool](length=len(cur), fill=False)
        var n_ax = nx if axis == 0 else (ny if axis == 1 else nz)
        var stride = 1 if axis == 0 else (nx if axis == 1 else nx * ny)
        for i in range(len(cur)):
            if not cur[i]:
                continue
            var c = (i // stride) % n_ax
            for o in range(max(0, c - r), min(n_ax - 1, c + r) + 1):
                nxt[i + (o - c) * stride] = True
        cur = nxt^
    return cur^


def _summed(b: List[Bool], nx: Int, ny: Int, nz: Int) -> List[Int32]:
    """Summed-volume table S[(x, y, z)] = blocked count in [0, x) x [0, y) x [0, z)."""
    var sx = nx + 1
    var sy = ny + 1
    var s = List[Int32](length=sx * sy * (nz + 1), fill=0)
    for z in range(nz):
        for y in range(ny):
            for x in range(nx):
                var v = Int32(1) if b[x + nx * (y + ny * z)] else Int32(0)
                var i = (x + 1) + sx * ((y + 1) + sy * (z + 1))
                s[i] = (
                    v
                    + s[x + sx * ((y + 1) + sy * (z + 1))]
                    + s[(x + 1) + sx * (y + sy * (z + 1))]
                    + s[(x + 1) + sx * ((y + 1) + sy * z)]
                    - s[x + sx * (y + sy * (z + 1))]
                    - s[x + sx * ((y + 1) + sy * z)]
                    - s[(x + 1) + sx * (y + sy * z)]
                    + s[x + sx * (y + sy * z)]
                )
    return s^


def _count_blocked(s: List[Int32], nx: Int, ny: Int, nz: Int, x: Int, y: Int, z: Int, size: Int) -> Int:
    """Blocked voxels in the cube [x, x+size)^3; voxels outside the grid count
    as blocked."""
    var x1 = min(x + size, nx)
    var y1 = min(y + size, ny)
    var z1 = min(z + size, nz)
    var inside = 0
    if x < x1 and y < y1 and z < z1:
        var sx = nx + 1
        var sy = ny + 1
        inside = Int(
            s[x1 + sx * (y1 + sy * z1)]
            - s[x + sx * (y1 + sy * z1)]
            - s[x1 + sx * (y + sy * z1)]
            - s[x1 + sx * (y1 + sy * z)]
            + s[x + sx * (y + sy * z1)]
            + s[x + sx * (y1 + sy * z)]
            + s[x1 + sx * (y + sy * z)]
            - s[x + sx * (y + sy * z)]
        )
    var in_grid = max(0, x1 - x) * max(0, y1 - y) * max(0, z1 - z)
    return inside + (size * size * size - in_grid)


def smooth_volume(vol: VolumeNav, path: NavPath) -> NavPath:
    """Greedy line-of-sight smoothing (same rule as `nav.path.smooth_path`)."""
    var out = NavPath()
    out.found = path.found
    out.expanded = path.expanded
    var n = len(path.points)
    if n == 0:
        return out^
    out.add(path.points[0], PATH_WALK)
    var i = 0
    while i < n - 1:
        var j = n - 1
        while j > i + 1 and not vol.line_of_sight(path.points[i], path.points[j]):
            j -= 1
        out.add(path.points[j], PATH_WALK)
        i = j
    return out^


trait VolumeFinder(Movable, Deinitable):
    def find(mut self, vol: VolumeNav, start: Vec3, goal: Vec3) -> NavPath:
        ...


struct SvoAStar(VolumeFinder):
    """A* over free leaves. A node's position is the shared-face point it was
    entered through (`portal`), not its centre: big leaves would otherwise
    distort distances and send the search around the wrong side of an
    obstacle. Consecutive portals lie on the faces of one convex leaf, so the
    raw route is valid before smoothing."""

    var heap: MinHeap
    var g: List[Real]
    var pos: List[Vec3]
    var parent: List[Int]
    var stamp: List[Int]
    var closed: List[Int]
    var gen: Int

    def __init__(out self):
        self.heap = MinHeap()
        self.g = List[Real]()
        self.pos = List[Vec3]()
        self.parent = List[Int]()
        self.stamp = List[Int]()
        self.closed = List[Int]()
        self.gen = 0

    def find(mut self, vol: VolumeNav, start: Vec3, goal: Vec3) -> NavPath:
        var out = NavPath()
        var s = vol.leaf_graph_node(start)
        var t = vol.leaf_graph_node(goal)
        if s < 0 or t < 0:
            return out^
        var n = vol.leaf_count()
        if len(self.g) != n:
            self.g = List[Real](length=n, fill=0)
            self.pos = List[Vec3](length=n, fill=Vec3(0))
            self.parent = List[Int](length=n, fill=-1)
            self.stamp = List[Int](length=n, fill=0)
            self.closed = List[Int](length=n, fill=0)
            self.gen = 0
        self.gen += 1
        var gen = self.gen
        self.heap.clear()
        self.g[s] = 0
        self.pos[s] = start
        self.parent[s] = -1
        self.stamp[s] = gen
        self.heap.push(dist3(start, goal), s)
        var reached = False
        while len(self.heap) > 0:
            var u = self.heap.pop()
            if self.closed[u] == gen:
                continue
            self.closed[u] = gen
            out.expanded += 1
            if u == t:
                reached = True
                break
            for e in range(vol.g_start[u], vol.g_start[u + 1]):
                var v = vol.g_adj[e]
                if self.closed[v] == gen:
                    continue
                var pv = portal(vol, u, v)
                var cost = dist3(self.pos[u], pv)
                var h = dist3(pv, goal)
                if v == t:
                    cost += h
                    h = 0
                var ng = self.g[u] + cost
                if self.stamp[v] != gen or ng < self.g[v]:
                    self.stamp[v] = gen
                    self.g[v] = ng
                    self.pos[v] = pv
                    self.parent[v] = u
                    self.heap.push(ng + h, v)
        if not reached:
            return out^
        var rev = List[Int]()
        var c = t
        while c >= 0:
            rev.append(c)
            c = self.parent[c] if c != s else -1
        var raw = NavPath()
        raw.found = True
        raw.expanded = out.expanded
        raw.add(start, PATH_WALK)
        for k in range(len(rev) - 2, -1, -1):
            raw.add(self.pos[rev[k]], PATH_WALK)
        raw.add(goal, PATH_WALK)
        return smooth_volume(vol, raw)


def portal(vol: VolumeNav, a: Int, b: Int) -> Vec3:
    """Centre of the face patch shared by adjacent free leaves a and b. The
    segment from either leaf's centre to it stays inside that (convex) leaf,
    so centre -> portal -> centre is a valid route between them."""
    var ka = vol.g_node[a]
    var kb = vol.g_node[b]
    var lo_a = SIMD[DType.int64, 4](Int64(vol.n_x[ka]), Int64(vol.n_y[ka]), Int64(vol.n_z[ka]), 0)
    var lo_b = SIMD[DType.int64, 4](Int64(vol.n_x[kb]), Int64(vol.n_y[kb]), Int64(vol.n_z[kb]), 0)
    var sa = Int64(vol.n_size[ka])
    var sb = Int64(vol.n_size[kb])
    var c = Vec3(0)
    for ax in range(3):
        var lo = max(lo_a[ax], lo_b[ax])
        var hi = min(lo_a[ax] + sa, lo_b[ax] + sb)
        # on the shared axis lo == hi (the face plane)
        c[ax] = vol.bmin[ax] + (Real(Int(lo)) + Real(Int(hi))) * 0.5 * vol.cfg.voxel
    return c

struct VoxelAStar(VolumeFinder):
    """A* over free voxels, 26-connected without corner cutting."""

    var heap: MinHeap
    var g: List[Real]
    var parent: List[Int]
    var stamp: List[Int]
    var closed: List[Int]
    var gen: Int

    def __init__(out self):
        self.heap = MinHeap()
        self.g = List[Real]()
        self.parent = List[Int]()
        self.stamp = List[Int]()
        self.closed = List[Int]()
        self.gen = 0

    def find(mut self, vol: VolumeNav, start: Vec3, goal: Vec3) -> NavPath:
        var out = NavPath()
        var va = vol.voxel_of(start)
        var vb = vol.voxel_of(goal)
        if not vol.is_free(Int(va[0]), Int(va[1]), Int(va[2])) or not vol.is_free(Int(vb[0]), Int(vb[1]), Int(vb[2])):
            return out^
        var n = vol.nx * vol.ny * vol.nz
        if len(self.g) != n:
            self.g = List[Real](length=n, fill=0)
            self.parent = List[Int](length=n, fill=-1)
            self.stamp = List[Int](length=n, fill=0)
            self.closed = List[Int](length=n, fill=0)
            self.gen = 0
        self.gen += 1
        var gen = self.gen
        self.heap.clear()
        var s = vol.idx(Int(va[0]), Int(va[1]), Int(va[2]))
        var t = vol.idx(Int(vb[0]), Int(vb[1]), Int(vb[2]))
        var vs = vol.cfg.voxel
        var gc = vol.voxel_center(Int(vb[0]), Int(vb[1]), Int(vb[2]))
        self.g[s] = 0
        self.parent[s] = -1
        self.stamp[s] = gen
        self.heap.push(0, s)
        var reached = False
        while len(self.heap) > 0:
            var u = self.heap.pop()
            if self.closed[u] == gen:
                continue
            self.closed[u] = gen
            out.expanded += 1
            if u == t:
                reached = True
                break
            var ux = u % vol.nx
            var uy = (u // vol.nx) % vol.ny
            var uz = u // (vol.nx * vol.ny)
            for dz in range(-1, 2):
                for dy in range(-1, 2):
                    for dx in range(-1, 2):
                        var k = abs(dx) + abs(dy) + abs(dz)
                        if k == 0:
                            continue
                        var x = ux + dx
                        var y = uy + dy
                        var z = uz + dz
                        if not vol.is_free(x, y, z):
                            continue
                        # no corner cutting: every axis-aligned sub-step free
                        if k >= 2:
                            if (dx != 0 and not vol.is_free(ux + dx, uy, uz)) or (
                                dy != 0 and not vol.is_free(ux, uy + dy, uz)
                            ) or (dz != 0 and not vol.is_free(ux, uy, uz + dz)):
                                continue
                        if k == 3:
                            if (
                                not vol.is_free(ux + dx, uy + dy, uz)
                                or not vol.is_free(ux + dx, uy, uz + dz)
                                or not vol.is_free(ux, uy + dy, uz + dz)
                            ):
                                continue
                        var v = vol.idx(x, y, z)
                        if self.closed[v] == gen:
                            continue
                        var stp = vs if k == 1 else (vs * _SQRT2 if k == 2 else vs * _SQRT3)
                        var ng = self.g[u] + stp
                        if self.stamp[v] != gen or ng < self.g[v]:
                            self.stamp[v] = gen
                            self.g[v] = ng
                            self.parent[v] = u
                            self.heap.push(ng + dist3(vol.voxel_center(x, y, z), gc), v)
        if not reached:
            return out^
        var rev = List[Int]()
        var c = t
        while c >= 0:
            rev.append(c)
            c = self.parent[c] if c != s else -1
        out.found = True
        out.add(start, PATH_WALK)
        for k in range(1, len(rev) - 1):
            var w = rev[len(rev) - 1 - k]
            out.add(vol.voxel_center(w % vol.nx, (w // vol.nx) % vol.ny, w // (vol.nx * vol.ny)), PATH_WALK)
        out.add(goal, PATH_WALK)
        return out^


struct SmoothedVoxelAStar(VolumeFinder):
    """`VoxelAStar` followed by the same line-of-sight smoothing as `SvoAStar`."""

    var inner: VoxelAStar

    def __init__(out self):
        self.inner = VoxelAStar()

    def find(mut self, vol: VolumeNav, start: Vec3, goal: Vec3) -> NavPath:
        var p = self.inner.find(vol, start, goal)
        if not p.found:
            return p^
        return smooth_volume(vol, p)
