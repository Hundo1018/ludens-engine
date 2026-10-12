"""Navigation mesh: convex polygons + portals over a compact field (ROADMAP 17.14).

Second half of the bake. Recast builds regions (watershed), traces and
simplifies contours, then triangulates. This module replaces those three steps
with a per-tile **greedy rectangle merge** over the eroded walkable spans:

- a rectangle grows in +x, then row by row in +z, while every cell has an
  unassigned walkable span connected to its row / column neighbour, and the
  floor stays within `max_climb` of the seed's floor;
- rectangles never cross a tile boundary, so a tile can be rebuilt alone.

Every polygon is an axis-aligned rectangle in XZ (convex), with per-corner
heights from the corner spans (exact on planar ramps). The price relative to
Recast is polygon count -- a diagonal wall becomes a staircase of rectangles
(`bench_nav` reports polygons per bake). Portals between polygons are maximal
runs of connected cells along a shared edge, so a corridor of rectangles is a
valid funnel input.

Dynamic obstacles (`add_obstacle` / `remove_obstacle` + `update`) mark spans
`blocked`, re-erode, and rebuild only the tiles within `agent_radius` of the
change ("tile rebake"; `test_nav` checks it equals a from-scratch rebuild).

Off-mesh links (ladders, jumps, teleports) connect two points on the mesh with
a cost multiplier; pathfinders traverse them as graph edges and mark the jump
in the returned path.
"""

from std.math import sqrt, floor, ceil
from geometry.vec import Real, Vec3, dot
from nav.heightfield import (
    NavBakeConfig,
    Heightfield,
    CompactField,
    rasterize,
    filter_low_hanging,
    filter_low_height,
    erode,
    erode_window,
    dir_dx,
    dir_dz,
)


def dist3(a: Vec3, b: Vec3) -> Real:
    var d = b - a
    return sqrt(dot(d, d))


struct NavMesh(Movable):
    var cfg: NavBakeConfig
    var field: CompactField
    var tiles_x: Int
    var tiles_z: Int
    # per tile: flat rects [x0, z0, x1, z1, s00, s10, s11, s01] (corner spans)
    var tile_rects: List[List[Int]]
    var span_rect: List[Int]  # local rect index within the span's tile, -1 = none
    # polygons (rebuilt by `_flatten` from tile_rects)
    var poly_base: List[Int]  # per tile: first polygon id
    var span_poly: List[Int]
    var p_rect: List[Int]  # (tile << 32) | local rect
    var p_verts: List[Vec3]  # 4 per poly: (x0,z0) (x1,z0) (x1,z1) (x0,z1)
    var p_center: List[Vec3]
    # links, CSR by source polygon
    var link_start: List[Int]
    var l_to: List[Int]
    var l_a: List[Vec3]
    var l_b: List[Vec3]
    var l_offmesh: List[Int]  # -1 = portal (a = left, b = right); else off-mesh link id (a = take-off, b = landing)
    var version: Int  # bumped whenever polygons or links change (pathfinder caches key on it)
    # off-mesh links
    var om_a: List[Vec3]
    var om_b: List[Vec3]
    var om_bidir: List[Bool]
    var om_cost_mul: List[Real]
    # dynamic obstacles (world AABBs)
    var ob_min: List[Vec3]
    var ob_max: List[Vec3]
    var ob_alive: List[Bool]
    var dirty: List[Bool]  # per tile, pending `update`
    var pending: Bool
    var win: List[Int]  # pending cell window [x0, z0, x1, z1] whose flags may change

    def __init__(out self, var field: CompactField, cfg: NavBakeConfig):
        self.cfg = cfg
        self.field = field^
        var ts = cfg.tile_size
        self.tiles_x = (self.field.width + ts - 1) // ts
        self.tiles_z = (self.field.depth + ts - 1) // ts
        var nt = self.tiles_x * self.tiles_z
        self.tile_rects = List[List[Int]]()
        for _ in range(nt):
            self.tile_rects.append(List[Int]())
        self.span_rect = List[Int](length=self.field.span_count(), fill=-1)
        self.poly_base = List[Int](length=nt + 1, fill=0)
        self.span_poly = List[Int]()
        self.p_rect = List[Int]()
        self.p_verts = List[Vec3]()
        self.p_center = List[Vec3]()
        self.link_start = List[Int]()
        self.l_to = List[Int]()
        self.l_a = List[Vec3]()
        self.l_b = List[Vec3]()
        self.l_offmesh = List[Int]()
        self.om_a = List[Vec3]()
        self.om_b = List[Vec3]()
        self.om_bidir = List[Bool]()
        self.om_cost_mul = List[Real]()
        self.ob_min = List[Vec3]()
        self.ob_max = List[Vec3]()
        self.ob_alive = List[Bool]()
        self.dirty = List[Bool](length=nt, fill=False)
        self.pending = False
        self.win = List[Int](length=4, fill=0)
        self.version = 0
        erode(self.field, cfg.walkable_radius())
        for t in range(nt):
            self._build_tile(t)
        self._flatten()

    # ---------------------------------------------------------------- tiles

    def tile_of_cell(self, x: Int, z: Int) -> Int:
        return (x // self.cfg.tile_size) + (z // self.cfg.tile_size) * self.tiles_x

    def _span_in_rect(self, x: Int, z: Int, tile: Int, rect: Int) -> Int:
        var col = x + z * self.field.width
        for k in range(self.field.cell_count[col]):
            var s = self.field.cell_start[col] + k
            if self.span_rect[s] == rect and self.tile_of_cell(x, z) == tile:
                return s
        return -1

    def _free(self, s: Int, tile: Int, seed_y: Int) -> Bool:
        if s < 0 or not self.field.walk[s] or self.span_rect[s] >= 0:
            return False
        if self.tile_of_cell(self.field.cx[s], self.field.cz[s]) != tile:
            return False
        return abs(self.field.y[s] - seed_y) <= self.cfg.walkable_climb()

    def _build_tile(mut self, t: Int):
        var ts = self.cfg.tile_size
        var tx0 = (t % self.tiles_x) * ts
        var tz0 = (t // self.tiles_x) * ts
        var tx1 = min(tx0 + ts, self.field.width)
        var tz1 = min(tz0 + ts, self.field.depth)
        for z in range(tz0, tz1):
            for x in range(tx0, tx1):
                var col = x + z * self.field.width
                for k in range(self.field.cell_count[col]):
                    self.span_rect[self.field.cell_start[col] + k] = -1
        self.tile_rects[t] = List[Int]()
        var nrect = 0
        for z in range(tz0, tz1):
            for x in range(tx0, tx1):
                var col = x + z * self.field.width
                for k in range(self.field.cell_count[col]):
                    var seed = self.field.cell_start[col] + k
                    if not self._free(seed, t, self.field.y[seed]):
                        continue
                    var sy = self.field.y[seed]
                    # grow along +x
                    var row = List[Int]()
                    row.append(seed)
                    self.span_rect[seed] = nrect
                    while True:
                        var nx = self.field.neighbour(row[len(row) - 1], 0)
                        if not self._free(nx, t, sy):
                            break
                        self.span_rect[nx] = nrect
                        row.append(nx)
                    var w = len(row)
                    var last_row = row.copy()
                    var z_end = z
                    # grow along +z, whole rows only
                    while True:
                        var cand = List[Int]()
                        var ok = True
                        for i in range(w):
                            var up = self.field.neighbour(last_row[i], 1)
                            if not self._free(up, t, sy):
                                ok = False
                                break
                            if i > 0 and self.field.neighbour(cand[i - 1], 0) != up:
                                ok = False
                                break
                            cand.append(up)
                        if not ok:
                            break
                        for i in range(w):
                            self.span_rect[cand[i]] = nrect
                        last_row = cand^
                        z_end += 1
                    self.tile_rects[t].append(x)
                    self.tile_rects[t].append(z)
                    self.tile_rects[t].append(x + w - 1)
                    self.tile_rects[t].append(z_end)
                    self.tile_rects[t].append(seed)
                    self.tile_rects[t].append(row[w - 1])
                    self.tile_rects[t].append(last_row[w - 1])
                    self.tile_rects[t].append(last_row[0])
                    nrect += 1

    def _corner(self, s: Int, cx: Int, cz: Int) -> Vec3:
        return Vec3(
            self.field.bmin[0] + Real(cx) * self.field.cs,
            self.field.bmin[1] + Real(self.field.y[s]) * self.field.ch,
            self.field.bmin[2] + Real(cz) * self.field.cs,
            0,
        )

    def _flatten(mut self):
        var nt = len(self.tile_rects)
        var total = 0
        for t in range(nt):
            self.poly_base[t] = total
            total += len(self.tile_rects[t]) // 8
        self.poly_base[nt] = total
        self.p_rect = List[Int](capacity=total)
        self.p_verts = List[Vec3](capacity=4 * total)
        self.p_center = List[Vec3](capacity=total)
        for t in range(nt):
            var rs = self.tile_rects[t].copy()
            for r in range(len(rs) // 8):
                var x0 = rs[8 * r]
                var z0 = rs[8 * r + 1]
                var x1 = rs[8 * r + 2]
                var z1 = rs[8 * r + 3]
                var v0 = self._corner(rs[8 * r + 4], x0, z0)
                var v1 = self._corner(rs[8 * r + 5], x1 + 1, z0)
                var v2 = self._corner(rs[8 * r + 6], x1 + 1, z1 + 1)
                var v3 = self._corner(rs[8 * r + 7], x0, z1 + 1)
                self.p_rect.append((t << 32) | r)
                self.p_verts.append(v0)
                self.p_verts.append(v1)
                self.p_verts.append(v2)
                self.p_verts.append(v3)
                self.p_center.append((v0 + v1 + v2 + v3) * 0.25)
        var n = self.field.span_count()
        self.span_poly = List[Int](length=n, fill=-1)
        for s in range(n):
            if self.span_rect[s] >= 0:
                var t = self.tile_of_cell(self.field.cx[s], self.field.cz[s])
                self.span_poly[s] = self.poly_base[t] + self.span_rect[s]
        self._build_links()

    def _edge_point(self, s: Int, n: Int, ex: Int, ez: Int) -> Vec3:
        """Point on a cell corner at the average floor of spans s and n."""
        var y = (Real(self.field.y[s]) + Real(self.field.y[n])) * 0.5
        return Vec3(
            self.field.bmin[0] + Real(ex) * self.field.cs,
            self.field.bmin[1] + y * self.field.ch,
            self.field.bmin[2] + Real(ez) * self.field.cs,
            0,
        )

    def _build_links(mut self):
        self.version += 1
        var np = self.poly_count()
        var src = List[Int]()
        var to = List[Int]()
        var la = List[Vec3]()
        var lb = List[Vec3]()
        var lom = List[Int]()
        for p in range(np):
            var t = self.p_rect[p] >> 32
            var r = self.p_rect[p] & 0xFFFFFFFF
            var x0 = self.tile_rects[t][8 * r]
            var z0 = self.tile_rects[t][8 * r + 1]
            var x1 = self.tile_rects[t][8 * r + 2]
            var z1 = self.tile_rects[t][8 * r + 3]
            for d in range(4):
                # edge cells, in increasing coordinate along the edge
                var cnt = (z1 - z0 + 1) if (d == 0 or d == 2) else (x1 - x0 + 1)
                var run_q = -1
                var run_s0 = -1
                var run_n0 = -1
                var run_i0 = 0
                var prev_s = -1
                var prev_n = -1
                for i in range(cnt + 1):
                    var q = -1
                    var s = -1
                    var nb = -1
                    if i < cnt:
                        var cx = x1 if d == 0 else (x0 if d == 2 else x0 + i)
                        var cz = z1 if d == 1 else (z0 if d == 3 else z0 + i)
                        s = self._span_in_rect(cx, cz, t, r)
                        if s >= 0:
                            nb = self.field.neighbour(s, d)
                            if nb >= 0:
                                q = self.span_poly[nb]
                    if q != run_q:
                        if run_q >= 0:
                            # close run [run_i0, i - 1]
                            var a: Vec3
                            var b: Vec3
                            if d == 0:
                                a = self._edge_point(run_s0, run_n0, x1 + 1, z0 + run_i0)
                                b = self._edge_point(prev_s, prev_n, x1 + 1, z0 + i)
                            elif d == 2:
                                a = self._edge_point(run_s0, run_n0, x0, z0 + run_i0)
                                b = self._edge_point(prev_s, prev_n, x0, z0 + i)
                            elif d == 1:
                                a = self._edge_point(run_s0, run_n0, x0 + run_i0, z1 + 1)
                                b = self._edge_point(prev_s, prev_n, x0 + i, z1 + 1)
                            else:
                                a = self._edge_point(run_s0, run_n0, x0 + run_i0, z0)
                                b = self._edge_point(prev_s, prev_n, x0 + i, z0)
                            # store (left, right) as seen crossing in direction d:
                            # left = positive XZ cross product with the crossing
                            var mid = (a + b) * 0.5
                            var side = Real(dir_dx(d)) * (a[2] - mid[2]) - Real(dir_dz(d)) * (a[0] - mid[0])
                            src.append(p)
                            to.append(run_q)
                            la.append(a if side > 0 else b)
                            lb.append(b if side > 0 else a)
                            lom.append(-1)
                        run_q = q
                        run_s0 = s
                        run_n0 = nb
                        run_i0 = i
                    prev_s = s
                    prev_n = nb
        # off-mesh links
        for o in range(len(self.om_a)):
            var pa = self.find_poly(self.om_a[o])
            var pb = self.find_poly(self.om_b[o])
            if pa < 0 or pb < 0:
                continue
            src.append(pa)
            to.append(pb)
            la.append(self.om_a[o])
            lb.append(self.om_b[o])
            lom.append(o)
            if self.om_bidir[o]:
                src.append(pb)
                to.append(pa)
                la.append(self.om_b[o])
                lb.append(self.om_a[o])
                lom.append(o)
        # CSR by source
        self.link_start = List[Int](length=np + 1, fill=0)
        for i in range(len(src)):
            self.link_start[src[i] + 1] += 1
        for p in range(np):
            self.link_start[p + 1] += self.link_start[p]
        var fill = self.link_start.copy()
        var nl = len(src)
        self.l_to = List[Int](length=nl, fill=-1)
        self.l_a = List[Vec3](length=nl, fill=Vec3(0))
        self.l_b = List[Vec3](length=nl, fill=Vec3(0))
        self.l_offmesh = List[Int](length=nl, fill=-1)
        for i in range(nl):
            var k = fill[src[i]]
            fill[src[i]] += 1
            self.l_to[k] = to[i]
            self.l_a[k] = la[i]
            self.l_b[k] = lb[i]
            self.l_offmesh[k] = lom[i]

    # ---------------------------------------------------------------- queries

    def poly_count(self) -> Int:
        return len(self.p_center)

    def link_count(self) -> Int:
        return len(self.l_to)

    def find_span(self, p: Vec3) -> Int:
        """Walkable span under p (floor within agent_height), or -1."""
        return self.field.span_at(p, self.cfg.agent_height)

    def find_poly(self, p: Vec3) -> Int:
        var s = self.find_span(p)
        if s < 0:
            return -1
        return self.span_poly[s]

    def find_nearest_span(self, p: Vec3, search_cells: Int) -> Int:
        """Nearest walkable span to p within a square of `search_cells`,
        by XZ-then-Y distance to the span's floor centre; -1 if none."""
        var s0 = self.find_span(p)
        if s0 >= 0:
            return s0
        var px = Int(floor((p[0] - self.field.bmin[0]) / self.field.cs))
        var pz = Int(floor((p[2] - self.field.bmin[2]) / self.field.cs))
        var best = -1
        var best_d = Real(1e30)
        for z in range(pz - search_cells, pz + search_cells + 1):
            for x in range(px - search_cells, px + search_cells + 1):
                if x < 0 or z < 0 or x >= self.field.width or z >= self.field.depth:
                    continue
                var col = x + z * self.field.width
                for k in range(self.field.cell_count[col]):
                    var s = self.field.cell_start[col] + k
                    if not self.field.walk[s]:
                        continue
                    var c = self.field.world_floor(s)
                    var d = dist3(c, p)
                    if d < best_d:
                        best_d = d
                        best = s
        return best

    def snap(self, p: Vec3, search_cells: Int = 4) -> Vec3:
        """Point `p` moved onto the mesh: same XZ if over a walkable span (height from
        the polygon), else the nearest walkable span's floor centre."""
        var s = self.find_span(p)
        if s >= 0:
            return Vec3(p[0], self.height_at(self.span_poly[s], p), p[2], 0)
        var t = self.find_nearest_span(p, search_cells)
        if t < 0:
            return p
        return self.field.world_floor(t)

    def height_at(self, poly: Int, p: Vec3) -> Real:
        """Floor height at p's XZ inside `poly`: the voxel floor of the span
        under p, tilted by the central-difference slope to its connected
        neighbours (exact on flat floors, within about one voxel height on
        ramps and at slope kinks). A rectangle may mix floors up to
        `max_climb` apart, so its corner heights alone are not enough."""
        var col = self.field.column_of(p)
        var s = -1
        if col >= 0:
            for k in range(self.field.cell_count[col]):
                var t = self.field.cell_start[col] + k
                if self.span_poly[t] == poly:
                    s = t
                    break
        if s < 0:
            # p outside the polygon's cells: clamp to its rectangle
            var v0 = self.p_verts[4 * poly]
            var v2 = self.p_verts[4 * poly + 2]
            var q = Vec3(
                min(max(p[0], v0[0] + self.field.cs * 0.5), v2[0] - self.field.cs * 0.5),
                p[1],
                min(max(p[2], v0[2] + self.field.cs * 0.5), v2[2] - self.field.cs * 0.5),
                0,
            )
            var c2 = self.field.column_of(q)
            if c2 >= 0:
                for k in range(self.field.cell_count[c2]):
                    var t = self.field.cell_start[c2] + k
                    if self.span_poly[t] == poly:
                        s = t
                        break
            if s < 0:
                return self.p_center[poly][1]
        var ch = self.field.ch
        var y = Real(self.field.y[s])
        var fx = (p[0] - self.field.bmin[0]) / self.field.cs - Real(self.field.cx[s]) - 0.5
        var fz = (p[2] - self.field.bmin[2]) / self.field.cs - Real(self.field.cz[s]) - 0.5
        var gx = self._slope(s, 0, 2)
        var gz = self._slope(s, 1, 3)
        return self.field.bmin[1] + (y + fx * gx + fz * gz) * ch

    def _slope(self, s: Int, dpos: Int, dneg: Int) -> Real:
        """Floor rise per cell along an axis, from the connected neighbours."""
        var a = self.field.con[4 * s + dpos]
        var b = self.field.con[4 * s + dneg]
        var y = Real(self.field.y[s])
        if a >= 0 and b >= 0:
            return (Real(self.field.y[a]) - Real(self.field.y[b])) * 0.5
        if a >= 0:
            return Real(self.field.y[a]) - y
        if b >= 0:
            return y - Real(self.field.y[b])
        return 0

    def walkable_area(self) -> Real:
        var n = 0
        for s in range(self.field.span_count()):
            if self.field.walk[s]:
                n += 1
        return Real(n) * self.field.cs * self.field.cs

    def move_along(self, a: Vec3, b: Vec3) -> Vec3:
        """Move from a toward b over walkable cells, sliding along blocked
        cell edges (Detour `moveAlongSurface` on the voxel grid): the motion
        is walked cell by cell; crossing into a non-walkable cell zeroes that
        axis of the remaining motion. The result lies inside a walkable span
        connected to a's, with y from `height_at`. a off the mesh -> a."""
        var tol = self.cfg.max_climb + 2 * self.field.ch
        var s = self.field.span_at(a, tol)
        if s < 0:
            return a
        var cs = self.field.cs
        var bx = self.field.bmin[0]
        var bz = self.field.bmin[2]
        var px = a[0]
        var pz = a[2]
        var rx = b[0] - a[0]
        var rz = b[2] - a[2]
        var guard = 4 * (self.field.width + self.field.depth) + 16
        while guard > 0 and (abs(rx) > Real(1e-7) or abs(rz) > Real(1e-7)):
            guard -= 1
            var x0 = bx + Real(self.field.cx[s]) * cs
            var z0 = bz + Real(self.field.cz[s]) * cs
            var tx = Real(2)
            var tz = Real(2)
            if rx > 0:
                tx = (x0 + cs - px) / rx
            elif rx < 0:
                tx = (x0 - px) / rx
            if rz > 0:
                tz = (z0 + cs - pz) / rz
            elif rz < 0:
                tz = (z0 - pz) / rz
            var t = min(tx, tz)
            if t >= 1:
                px += rx
                pz += rz
                break
            t = max(t, Real(0))
            px += rx * t
            pz += rz * t
            rx *= 1 - t
            rz *= 1 - t
            var cross_x = tx <= tz
            var cross_z = tz <= tx
            if cross_x:
                var n = self.field.neighbour(s, 0 if rx > 0 else 2)
                if n >= 0:
                    s = n
                else:
                    rx = 0
            if cross_z:
                var n = self.field.neighbour(s, 1 if rz > 0 else 3)
                if n >= 0:
                    s = n
                else:
                    rz = 0
        # keep the point strictly inside span s's cell
        var e = cs * Real(1e-4)
        var cx0 = bx + Real(self.field.cx[s]) * cs
        var cz0 = bz + Real(self.field.cz[s]) * cs
        px = min(max(px, cx0 + e), cx0 + cs - e)
        pz = min(max(pz, cz0 + e), cz0 + cs - e)
        var out = Vec3(px, a[1], pz, 0)
        var poly = self.span_poly[s]
        if poly >= 0:
            out[1] = self.height_at(poly, out)
        else:
            out[1] = self.field.bmin[1] + Real(self.field.y[s]) * self.field.ch
        return out

    def raycast(self, a: Vec3, b: Vec3) -> Bool:
        """True if the XZ segment a -> b crosses only walkable, connected spans.
        A segment lying exactly on a grid line (an eroded edge, where funnel
        corners sit) runs between two cell rows; it passes if either row does."""
        if self._ray(a, b):
            return True
        var cs = self.field.cs
        var e = Vec3(0)
        if abs(a[2] - b[2]) <= cs * Real(1e-6) and _on_grid(a[2] - self.field.bmin[2], cs):
            e[2] = cs * Real(1e-3)
        elif abs(a[0] - b[0]) <= cs * Real(1e-6) and _on_grid(a[0] - self.field.bmin[0], cs):
            e[0] = cs * Real(1e-3)
        else:
            return False
        return self._ray(a + e, b + e) or self._ray(a - e, b - e)

    def _ray(self, a: Vec3, b: Vec3) -> Bool:
        """Exact cell traversal (Amanatides-Woo). Starts from the span under `a`
        and follows connections, so it stays on a's floor level. Endpoints are
        nudged 1e-3 cells toward each other so a funnel corner lying exactly
        on a cell corner starts inside the walkable cell it leaves into.
        Passing exactly through a grid corner needs one of the two
        orthogonal routes."""
        var cs = self.field.cs
        var d = b - a
        var l2 = d[0] * d[0] + d[2] * d[2]
        var tol = self.cfg.max_climb + 2 * self.field.ch
        if l2 <= Real(1e-12):
            return self.field.span_at(a, tol) >= 0
        var nud = d * (cs * Real(1e-3) / sqrt(l2))
        var p0 = a + nud
        var p1 = b - nud
        var s = self.field.span_at(p0, tol)
        if s < 0:
            return False
        var bx = self.field.bmin[0]
        var bz = self.field.bmin[2]
        var fx = (p0[0] - bx) / cs
        var fz = (p0[2] - bz) / cs
        var ex = Int(floor((p1[0] - bx) / cs))
        var ez = Int(floor((p1[2] - bz) / cs))
        var x = Int(floor(fx))
        var z = Int(floor(fz))
        var dx = p1[0] - p0[0]
        var dz = p1[2] - p0[2]
        var stx = 1 if dx > 0 else -1
        var stz = 1 if dz > 0 else -1
        var dirx = 0 if dx > 0 else 2
        var dirz = 1 if dz > 0 else 3
        comptime INF = Real(1e30)
        var tdx = INF if dx == 0 else abs(Real(cs) / dx) * 1
        var tdz = INF if dz == 0 else abs(Real(cs) / dz) * 1
        # parametric t (0..1 over p0->p1) to the next x / z cell boundary
        var tmx = INF
        if dx != 0:
            var nxb = Real(x + 1) if dx > 0 else Real(x)
            tmx = (nxb - fx) * cs / dx
        var tmz = INF
        if dz != 0:
            var nzb = Real(z + 1) if dz > 0 else Real(z)
            tmz = (nzb - fz) * cs / dz
        var guard = 4 * (self.field.width + self.field.depth) + 8
        while (x != ex or z != ez) and guard > 0:
            guard -= 1
            if abs(tmx - tmz) <= Real(1e-6):
                # exactly through a grid corner: the segment touches the two
                # orthogonal cells at one point only, so either route will do
                # (erosion already keeps agent_radius from the blocked one)
                var t = -1
                var via_x = self.field.neighbour(s, dirx)
                if via_x >= 0:
                    t = self.field.neighbour(via_x, dirz)
                if t < 0:
                    var via_z = self.field.neighbour(s, dirz)
                    if via_z >= 0:
                        t = self.field.neighbour(via_z, dirx)
                if t < 0:
                    return False
                s = t
                x += stx
                z += stz
                tmx += tdx
                tmz += tdz
            elif tmx < tmz:
                s = self.field.neighbour(s, dirx)
                if s < 0:
                    return False
                x += stx
                tmx += tdx
            else:
                s = self.field.neighbour(s, dirz)
                if s < 0:
                    return False
                z += stz
                tmz += tdz
        return guard > 0

    # ---------------------------------------------------------------- edits

    def add_offmesh_link(mut self, a: Vec3, b: Vec3, bidir: Bool = True, cost_mul: Real = 1) raises -> Int:
        """Connect two on-mesh points (ladder, jump, teleport). Raises when an
        endpoint is not over a walkable span."""
        if self.find_poly(a) < 0 or self.find_poly(b) < 0:
            raise Error("add_offmesh_link: endpoint is not on the navmesh")
        if cost_mul < 0:
            raise Error("add_offmesh_link: cost_mul must be >= 0")
        self.om_a.append(a)
        self.om_b.append(b)
        self.om_bidir.append(bidir)
        self.om_cost_mul.append(cost_mul)
        self._build_links()
        return len(self.om_a) - 1

    def add_obstacle(mut self, lo: Vec3, hi: Vec3) raises -> Int:
        """Carve a world AABB out of the mesh at the next `update()`."""
        for a in range(3):
            if not (lo[a] <= hi[a]):
                raise Error("add_obstacle: lo must be <= hi on every axis")
        self.ob_min.append(lo)
        self.ob_max.append(hi)
        self.ob_alive.append(True)
        self._mark_dirty(lo, hi)
        return len(self.ob_min) - 1

    def remove_obstacle(mut self, id: Int) raises:
        if id < 0 or id >= len(self.ob_alive) or not self.ob_alive[id]:
            raise Error("remove_obstacle: unknown or already removed id")
        self.ob_alive[id] = False
        self._mark_dirty(self.ob_min[id], self.ob_max[id])

    def _cells(self, lo: Vec3, hi: Vec3, grow: Int) -> List[Int]:
        """Cell rectangle [x0, z0, x1, z1] covered by an XZ box, grown by
        `grow` cells and clipped to the field (x0 > x1 when outside)."""
        var bx = self.field.bmin[0]
        var bz = self.field.bmin[2]
        var r = List[Int](length=4, fill=0)
        r[0] = max(0, Int(floor((lo[0] - bx) / self.field.cs)) - grow)
        r[1] = max(0, Int(floor((lo[2] - bz) / self.field.cs)) - grow)
        r[2] = min(self.field.width - 1, Int(floor((hi[0] - bx) / self.field.cs)) + grow)
        r[3] = min(self.field.depth - 1, Int(floor((hi[2] - bz) / self.field.cs)) + grow)
        return r^

    def _mark_dirty(mut self, lo: Vec3, hi: Vec3):
        # a blocked cell changes erosion up to walkable_radius cells away
        var c = self._cells(lo, hi, self.cfg.walkable_radius() + 1)
        if c[0] > c[2] or c[1] > c[3]:
            return
        if self.pending:
            self.win[0] = min(self.win[0], c[0])
            self.win[1] = min(self.win[1], c[1])
            self.win[2] = max(self.win[2], c[2])
            self.win[3] = max(self.win[3], c[3])
        else:
            for k in range(4):
                self.win[k] = c[k]
        var ts = self.cfg.tile_size
        for tz in range(c[1] // ts, c[3] // ts + 1):
            for tx in range(c[0] // ts, c[2] // ts + 1):
                self.dirty[tx + tz * self.tiles_x] = True
        self.pending = True

    def _apply_obstacles(mut self, w: List[Int]):
        """Recompute `blocked` for the cells in window w from every live obstacle."""
        for z in range(w[1], w[3] + 1):
            for x in range(w[0], w[2] + 1):
                var col = x + z * self.field.width
                for k in range(self.field.cell_count[col]):
                    self.field.blocked[self.field.cell_start[col] + k] = False
        for o in range(len(self.ob_min)):
            if not self.ob_alive[o]:
                continue
            var lo = self.ob_min[o]
            var hi = self.ob_max[o]
            var c = self._cells(lo, hi, 0)
            for z in range(max(c[1], w[1]), min(c[3], w[3]) + 1):
                for x in range(max(c[0], w[0]), min(c[2], w[2]) + 1):
                    var col = x + z * self.field.width
                    for k in range(self.field.cell_count[col]):
                        var s = self.field.cell_start[col] + k
                        var fy = self.field.bmin[1] + Real(self.field.y[s]) * self.field.ch
                        # blocks the span if the box intersects the agent's
                        # standing volume [floor, floor + agent_height]
                        if hi[1] >= fy and lo[1] <= fy + self.cfg.agent_height:
                            self.field.blocked[s] = True

    def update(mut self) -> Int:
        """Apply pending obstacle edits: recompute blocked flags and erosion in
        the changed window only, rebuild the tiles it touches, re-link.
        Returns the number of tiles rebuilt."""
        if not self.pending:
            return 0
        var w = self.win.copy()
        self._apply_obstacles(w)
        erode_window(self.field, self.cfg.walkable_radius(), w[0], w[1], w[2], w[3])
        var rebuilt = 0
        for t in range(len(self.dirty)):
            if self.dirty[t]:
                self._build_tile(t)
                self.dirty[t] = False
                rebuilt += 1
        self._flatten()
        self.pending = False
        return rebuilt

    def rebuild_all(mut self):
        """Reference path for the carve parity test: every tile from scratch."""
        var w = List[Int](length=4, fill=0)
        w[2] = self.field.width - 1
        w[3] = self.field.depth - 1
        self._apply_obstacles(w)
        erode(self.field, self.cfg.walkable_radius())
        for t in range(len(self.tile_rects)):
            self._build_tile(t)
            self.dirty[t] = False
        self._flatten()
        self.pending = False


def _on_grid(v: Real, cs: Real) -> Bool:
    var f = v / cs
    return abs(f - Real(Int(f + 0.5))) <= Real(1e-4)


def bake_navmesh(verts: List[Vec3], tris: List[Int], cfg: NavBakeConfig) raises -> NavMesh:
    """Triangle soup -> navmesh. Walkable triangles need `cross(b-a, c-a)`
    pointing up (+y). Bounds are the input's AABB plus one cell of margin and
    `agent_height` of headroom."""
    cfg.validate()
    if len(verts) == 0 or len(tris) == 0:
        raise Error("bake_navmesh: empty input")
    var lo = verts[0]
    var hi = verts[0]
    for v in verts:
        for a in range(3):
            lo[a] = min(lo[a], v[a])
            hi[a] = max(hi[a], v[a])
    lo = lo - Vec3(cfg.cell_size, cfg.cell_height, cfg.cell_size, 0)
    hi = hi + Vec3(cfg.cell_size, cfg.agent_height + cfg.cell_height, cfg.cell_size, 0)
    var hf = Heightfield(lo, hi, cfg.cell_size, cfg.cell_height)
    rasterize(hf, verts, tris, cfg)
    filter_low_hanging(hf, cfg)
    filter_low_height(hf, cfg)
    var cf = CompactField(hf, cfg)
    return NavMesh(cf^, cfg)
