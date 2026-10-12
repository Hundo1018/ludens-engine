"""Pathfinding over a `NavMesh` (ROADMAP 17.14). Seam: `PathFinder`.

Three variants answer the same query (start, goal) -> polyline:

- `PolyFunnel`: A* over navmesh polygons (node position = entry portal
  midpoint, Detour's cost model) then the simple stupid funnel algorithm
  (Mononen) for string pulling. Fewest nodes; corners only where the corridor
  bends.
- `GridAStar`: A* over walkable spans, 8-connected, diagonals only when both
  orthogonal neighbours are walkable (no corner cutting). Octile length; the
  reference for reachability.
- `FlowFieldPath`: one Dijkstra integration field per goal (`FlowField`), then
  steepest descent. Many agents with the same goal read a direction in O(1)
  (`FlowField.direction`) instead of each running a search.

Parity (`test_nav_parity`): identical reachability on the same mesh, every
returned segment stays on walkable spans, and lengths agree within the
octile-vs-Euclidean bound. Off-mesh links are edges in all three.

Path points carry a flag: `PATH_OFFMESH` on a point means the segment that
STARTS there is an off-mesh traversal (jump / ladder), not a walk.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot
from nav.navmesh import NavMesh, dist3

comptime PATH_WALK = 0
comptime PATH_OFFMESH = 1
comptime _SQRT2: Real = 1.4142135623730951


struct NavPath(Copyable, Movable):
    var found: Bool
    var points: List[Vec3]
    var flags: List[Int]
    var expanded: Int  # search nodes popped (cost metric for the bench)

    def __init__(out self):
        self.found = False
        self.points = List[Vec3]()
        self.flags = List[Int]()
        self.expanded = 0

    def add(mut self, p: Vec3, flag: Int):
        self.points.append(p)
        self.flags.append(flag)

    def length(self) -> Real:
        var l = Real(0)
        for i in range(1, len(self.points)):
            l += dist3(self.points[i - 1], self.points[i])
        return l


trait PathFinder(Movable, Deinitable):
    def find(mut self, mesh: NavMesh, start: Vec3, goal: Vec3) -> NavPath:
        ...


struct MinHeap(Movable, Sized):
    """Binary min-heap of (key, id); ties broken by id so pops are
    deterministic. Lazy deletion: callers skip stale entries."""

    var key: List[Real]
    var id: List[Int]

    def __init__(out self):
        self.key = List[Real]()
        self.id = List[Int]()

    def __len__(self) -> Int:
        return len(self.id)

    def clear(mut self):
        self.key.clear()
        self.id.clear()

    def _less(self, i: Int, j: Int) -> Bool:
        if self.key[i] != self.key[j]:
            return self.key[i] < self.key[j]
        return self.id[i] < self.id[j]

    def _swap(mut self, i: Int, j: Int):
        var k = self.key[i]
        self.key[i] = self.key[j]
        self.key[j] = k
        var d = self.id[i]
        self.id[i] = self.id[j]
        self.id[j] = d

    def push(mut self, k: Real, v: Int):
        self.key.append(k)
        self.id.append(v)
        var i = len(self.id) - 1
        while i > 0:
            var p = (i - 1) // 2
            if not self._less(i, p):
                break
            self._swap(i, p)
            i = p

    def pop(mut self) -> Int:
        var top = self.id[0]
        var last = len(self.id) - 1
        self._swap(0, last)
        _ = self.key.pop()
        _ = self.id.pop()
        var i = 0
        var n = len(self.id)
        while True:
            var l = 2 * i + 1
            var r = l + 1
            var m = i
            if l < n and self._less(l, m):
                m = l
            if r < n and self._less(r, m):
                m = r
            if m == i:
                break
            self._swap(i, m)
            i = m
        return top


def _cross2(u: Vec3, v: Vec3) -> Real:
    return u[0] * v[2] - u[2] * v[0]


def _same(a: Vec3, b: Vec3) -> Bool:
    var d = b - a
    return d[0] * d[0] + d[2] * d[2] < Real(1e-12)


def string_pull(lefts: List[Vec3], rights: List[Vec3], mut out: NavPath, flag_last: Int):
    """Simple stupid funnel algorithm over portals[0..n): portal 0 is (start,
    start), the last is (end, end). "Left" is the side with positive XZ cross
    product relative to the travel direction. Appends corners (not the start)
    to `out`; the end point gets `flag_last`."""
    var n = len(lefts)
    var apex = lefts[0]
    var pl = lefts[0]
    var pr = rights[0]
    var left_i = 0
    var right_i = 0
    var i = 1
    while i < n:
        var l = lefts[i]
        var r = rights[i]
        # tighten the right side
        if _cross2(pr - apex, r - apex) >= 0:
            if _same(apex, pr) or _cross2(pl - apex, r - apex) < 0:
                pr = r
                right_i = i
            else:
                # right crossed over left: left corner becomes the new apex
                apex = pl
                var ai = left_i
                out.add(apex, PATH_WALK)
                pl = apex
                pr = apex
                right_i = ai
                i = ai + 1
                continue
        # tighten the left side
        if _cross2(pl - apex, l - apex) <= 0:
            if _same(apex, pl) or _cross2(pr - apex, l - apex) > 0:
                pl = l
                left_i = i
            else:
                apex = pr
                var ai = right_i
                out.add(apex, PATH_WALK)
                pl = apex
                pr = apex
                left_i = ai
                i = ai + 1
                continue
        i += 1
    var end = lefts[n - 1]
    if len(out.points) == 0 or not _same(out.points[len(out.points) - 1], end):
        out.add(end, flag_last)
    else:
        out.flags[len(out.flags) - 1] = flag_last


struct PolyFunnel(PathFinder):
    """A* over polygons + funnel string pulling, then (default) visibility
    smoothing: the funnel is taut only inside the corridor A* picked, and the
    portal-midpoint cost model can pick a corridor a few percent longer than
    the shortest; `smooth_path` drops every corner a straight walkable segment
    can skip."""

    var smooth: Bool
    var tile_mask: List[Bool]  # empty = every tile; else search only tiles marked True
    var g: List[Real]
    var pos: List[Vec3]
    var parent_link: List[Int]
    var stamp: List[Int]
    var closed: List[Int]
    var gen: Int
    var heap: MinHeap

    def __init__(out self, smooth: Bool = True):
        self.smooth = smooth
        self.tile_mask = List[Bool]()
        self.g = List[Real]()
        self.pos = List[Vec3]()
        self.parent_link = List[Int]()
        self.stamp = List[Int]()
        self.closed = List[Int]()
        self.gen = 0
        self.heap = MinHeap()

    def _reset(mut self, n: Int):
        if len(self.g) != n:
            self.g = List[Real](length=n, fill=0)
            self.pos = List[Vec3](length=n, fill=Vec3(0))
            self.parent_link = List[Int](length=n, fill=-1)
            self.stamp = List[Int](length=n, fill=0)
            self.closed = List[Int](length=n, fill=0)
            self.gen = 0
        self.gen += 1
        self.heap.clear()

    def corridor(mut self, mesh: NavMesh, start: Vec3, goal: Vec3, mut expanded: Int) -> List[Int]:
        """Links from the start polygon to the goal polygon (empty if the two
        coincide); a single -1 element means no path."""
        var res = List[Int]()
        var sp = mesh.find_poly(start)
        var gp = mesh.find_poly(goal)
        if sp < 0 or gp < 0:
            res.append(-1)
            return res^
        if sp == gp:
            return res^
        self._reset(mesh.poly_count())
        var gen = self.gen
        self.g[sp] = 0
        self.pos[sp] = start
        self.parent_link[sp] = -1
        self.stamp[sp] = gen
        self.heap.push(dist3(start, goal), sp)
        var reached = False
        while len(self.heap) > 0:
            var p = self.heap.pop()
            if self.closed[p] == gen:
                continue
            self.closed[p] = gen
            expanded += 1
            if p == gp:
                reached = True
                break
            for l in range(mesh.link_start[p], mesh.link_start[p + 1]):
                var q = mesh.l_to[l]
                if self.closed[q] == gen:
                    continue
                if len(self.tile_mask) > 0 and not self.tile_mask[mesh.p_rect[q] >> 32]:
                    continue
                var entry: Vec3
                var cost: Real
                var om = mesh.l_offmesh[l]
                if om >= 0:
                    entry = mesh.l_b[l]
                    cost = dist3(self.pos[p], mesh.l_a[l]) + dist3(mesh.l_a[l], mesh.l_b[l]) * mesh.om_cost_mul[om]
                else:
                    entry = (mesh.l_a[l] + mesh.l_b[l]) * 0.5
                    cost = dist3(self.pos[p], entry)
                var h = dist3(entry, goal)
                if q == gp:
                    cost += h
                    h = 0
                var ng = self.g[p] + cost
                if self.stamp[q] != gen or ng < self.g[q]:
                    self.stamp[q] = gen
                    self.g[q] = ng
                    self.pos[q] = entry
                    self.parent_link[q] = l
                    self.heap.push(ng + h, q)
        if not reached:
            res.append(-1)
            return res^
        var rev = List[Int]()
        var c = gp
        while c != sp:
            var l = self.parent_link[c]
            rev.append(l)
            # source polygon of link l: the one whose CSR range holds it
            c = _link_source(mesh, l)
        for k in range(len(rev)):
            res.append(rev[len(rev) - 1 - k])
        return res^

    def find(mut self, mesh: NavMesh, start: Vec3, goal: Vec3) -> NavPath:
        var out = NavPath()
        var expanded = 0
        var links = self.corridor(mesh, start, goal, expanded)
        out.expanded = expanded
        if len(links) == 1 and links[0] < 0:
            return out^
        var s = mesh.snap(start, 0)
        var e = mesh.snap(goal, 0)
        out.found = True
        out.add(s, PATH_WALK)
        var lefts = List[Vec3]()
        var rights = List[Vec3]()
        lefts.append(s)
        rights.append(s)
        for k in range(len(links)):
            var l = links[k]
            var om = mesh.l_offmesh[l]
            if om >= 0:
                var a = mesh.l_a[l]
                lefts.append(a)
                rights.append(a)
                string_pull(lefts, rights, out, PATH_OFFMESH)
                var b = mesh.l_b[l]
                out.add(b, PATH_WALK)
                lefts = List[Vec3]()
                rights = List[Vec3]()
                lefts.append(b)
                rights.append(b)
            else:
                lefts.append(mesh.l_a[l])
                rights.append(mesh.l_b[l])
        lefts.append(e)
        rights.append(e)
        string_pull(lefts, rights, out, PATH_WALK)
        if self.smooth:
            return smooth_path(mesh, out)
        return out^


def smooth_path(mesh: NavMesh, path: NavPath) -> NavPath:
    """Greedy visibility pass: from each kept point, jump to the farthest later
    point reachable by a straight walkable segment (`NavMesh.raycast`).
    Off-mesh take-off / landing points are always kept."""
    var out = NavPath()
    out.found = path.found
    out.expanded = path.expanded
    var n = len(path.points)
    if n == 0:
        return out^
    out.add(path.points[0], path.flags[0])
    var i = 0
    while i < n - 1:
        if path.flags[i] == PATH_OFFMESH:
            out.add(path.points[i + 1], path.flags[i + 1])
            i += 1
            continue
        # farthest j with no off-mesh traversal in between
        var lim = i + 1
        while lim < n - 1 and path.flags[lim] != PATH_OFFMESH:
            lim += 1
        var j = lim
        while j > i + 1 and not mesh.raycast(path.points[i], path.points[j]):
            j -= 1
        out.add(path.points[j], path.flags[j])
        i = j
    return out^


def _link_source(mesh: NavMesh, l: Int) -> Int:
    """Binary search the CSR offsets for the polygon owning link l."""
    var lo = 0
    var hi = mesh.poly_count() - 1
    while lo < hi:
        var mid = (lo + hi + 1) // 2
        if mesh.link_start[mid] <= l:
            lo = mid
        else:
            hi = mid - 1
    return lo


def _offmesh_edges(mesh: NavMesh) -> Tuple[List[Int], List[Int], List[Real], List[Int]]:
    """Off-mesh links as directed span edges (from, to, cost, link id)."""
    var fr = List[Int]()
    var to = List[Int]()
    var cost = List[Real]()
    var ids = List[Int]()
    for o in range(len(mesh.om_a)):
        var a = mesh.find_span(mesh.om_a[o])
        var b = mesh.find_span(mesh.om_b[o])
        if a < 0 or b < 0:
            continue
        var c = dist3(mesh.om_a[o], mesh.om_b[o]) * mesh.om_cost_mul[o]
        fr.append(a)
        to.append(b)
        cost.append(c)
        ids.append(o)
        if mesh.om_bidir[o]:
            fr.append(b)
            to.append(a)
            cost.append(c)
            ids.append(o)
    return (fr^, to^, cost^, ids^)


def _span_step(mesh: NavMesh, s: Int, k: Int) -> Int:
    """k in [0, 8): 0..3 straight (direction k), 4..7 diagonal (between k-4
    and k-3)."""
    if k < 4:
        return mesh.field.neighbour(s, k)
    return mesh.field.diagonal(s, k - 4)


struct GridAStar(PathFinder):
    """A* over walkable spans, 8-connected without corner cutting."""

    var g: List[Real]
    var parent: List[Int]
    var parent_om: List[Int]
    var stamp: List[Int]
    var closed: List[Int]
    var gen: Int
    var heap: MinHeap

    def __init__(out self):
        self.g = List[Real]()
        self.parent = List[Int]()
        self.parent_om = List[Int]()
        self.stamp = List[Int]()
        self.closed = List[Int]()
        self.gen = 0
        self.heap = MinHeap()

    def find(mut self, mesh: NavMesh, start: Vec3, goal: Vec3) -> NavPath:
        var out = NavPath()
        var ss = mesh.find_span(start)
        var gs = mesh.find_span(goal)
        if ss < 0 or gs < 0:
            return out^
        var n = mesh.field.span_count()
        if len(self.g) != n:
            self.g = List[Real](length=n, fill=0)
            self.parent = List[Int](length=n, fill=-1)
            self.parent_om = List[Int](length=n, fill=-1)
            self.stamp = List[Int](length=n, fill=0)
            self.closed = List[Int](length=n, fill=0)
            self.gen = 0
        self.gen += 1
        var gen = self.gen
        self.heap.clear()
        var om = _offmesh_edges(mesh)
        var cs = mesh.field.cs
        var goal_c = mesh.field.world_floor(gs)
        self.g[ss] = 0
        self.parent[ss] = -1
        self.stamp[ss] = gen
        self.heap.push(dist3(mesh.field.world_floor(ss), goal_c), ss)
        var reached = False
        while len(self.heap) > 0:
            var u = self.heap.pop()
            if self.closed[u] == gen:
                continue
            self.closed[u] = gen
            out.expanded += 1
            if u == gs:
                reached = True
                break
            for k in range(8):
                var v = _span_step(mesh, u, k)
                if v < 0 or self.closed[v] == gen:
                    continue
                var step = cs if k < 4 else cs * _SQRT2
                var ng = self.g[u] + step
                if self.stamp[v] != gen or ng < self.g[v]:
                    self.stamp[v] = gen
                    self.g[v] = ng
                    self.parent[v] = u
                    self.parent_om[v] = -1
                    self.heap.push(ng + dist3(mesh.field.world_floor(v), goal_c), v)
            for e in range(len(om[0])):
                if om[0][e] != u:
                    continue
                var v = om[1][e]
                if self.closed[v] == gen:
                    continue
                var ng = self.g[u] + om[2][e]
                if self.stamp[v] != gen or ng < self.g[v]:
                    self.stamp[v] = gen
                    self.g[v] = ng
                    self.parent[v] = u
                    self.parent_om[v] = om[3][e]
                    self.heap.push(ng + dist3(mesh.field.world_floor(v), goal_c), v)
        if not reached:
            return out^
        var rev = List[Int]()
        var c = gs
        while c >= 0:
            rev.append(c)
            c = self.parent[c] if c != ss else -1
        out.found = True
        out.add(mesh.snap(start, 0), PATH_WALK)
        for k in range(len(rev)):
            var s = rev[len(rev) - 1 - k]
            if k > 0 and self.parent_om[s] >= 0:
                out.flags[len(out.flags) - 1] = PATH_OFFMESH
            out.add(mesh.field.world_floor(s), PATH_WALK)
        out.add(mesh.snap(goal, 0), PATH_WALK)
        return out^


struct FlowField(Movable):
    """Integration field toward one goal span: cost-to-goal per span (Dijkstra,
    8-connected without corner cutting, plus off-mesh links) and the next span
    on a shortest route. -1 next = goal or unreachable."""

    var goal: Int
    var cost: List[Real]
    var next: List[Int]
    var next_om: List[Int]
    var heap: MinHeap

    def __init__(out self):
        self.goal = -1
        self.cost = List[Real]()
        self.next = List[Int]()
        self.next_om = List[Int]()
        self.heap = MinHeap()

    def build(mut self, mesh: NavMesh, goal: Vec3) -> Bool:
        """Returns False when the goal is not on the mesh."""
        var n = mesh.field.span_count()
        self.cost = List[Real](length=n, fill=Real(-1))
        self.next = List[Int](length=n, fill=-1)
        self.next_om = List[Int](length=n, fill=-1)
        self.goal = mesh.find_span(goal)
        if self.goal < 0:
            return False
        var om = _offmesh_edges(mesh)
        var cs = mesh.field.cs
        var done = List[Bool](length=n, fill=False)
        self.heap.clear()
        self.cost[self.goal] = 0
        self.heap.push(0, self.goal)
        while len(self.heap) > 0:
            var u = self.heap.pop()
            if done[u]:
                continue
            done[u] = True
            # neighbour relation is symmetric, so predecessors = neighbours
            for k in range(8):
                var v = _span_step(mesh, u, k)
                if v < 0 or done[v]:
                    continue
                var nc = self.cost[u] + (cs if k < 4 else cs * _SQRT2)
                if self.cost[v] < 0 or nc < self.cost[v]:
                    self.cost[v] = nc
                    self.next[v] = u
                    self.next_om[v] = -1
                    self.heap.push(nc, v)
            # off-mesh edge v -> u: v's next hop is u through the link
            for e in range(len(om[0])):
                if om[1][e] != u:
                    continue
                var v = om[0][e]
                if done[v]:
                    continue
                var nc = self.cost[u] + om[2][e]
                if self.cost[v] < 0 or nc < self.cost[v]:
                    self.cost[v] = nc
                    self.next[v] = u
                    self.next_om[v] = om[3][e]
                    self.heap.push(nc, v)
        return True

    def cost_at(self, mesh: NavMesh, p: Vec3) -> Real:
        var s = mesh.find_span(p)
        if s < 0:
            return -1
        return self.cost[s]

    def direction(self, mesh: NavMesh, p: Vec3) -> Vec3:
        """Unit XZ direction toward the next span on a shortest route (zero at
        the goal, off the mesh, or where the goal is unreachable)."""
        var s = mesh.find_span(p)
        if s < 0 or self.next[s] < 0:
            return Vec3(0)
        var d = mesh.field.world_floor(self.next[s]) - p
        d[1] = 0
        var l = sqrt(dot(d, d))
        if l <= 0:
            return Vec3(0)
        return d / l


struct FlowFieldPath(PathFinder):
    """Path = steepest descent through a cached `FlowField` (rebuilt only when
    the goal span changes)."""

    var field: FlowField
    var built_for: Int
    var built_version: Int

    def __init__(out self):
        self.field = FlowField()
        self.built_for = -2
        self.built_version = -1

    def find(mut self, mesh: NavMesh, start: Vec3, goal: Vec3) -> NavPath:
        var out = NavPath()
        var gs = mesh.find_span(goal)
        if gs < 0:
            return out^
        if gs != self.built_for or self.built_version != mesh.version:
            _ = self.field.build(mesh, goal)
            self.built_for = gs
            self.built_version = mesh.version
            out.expanded = mesh.field.span_count()
        var s = mesh.find_span(start)
        if s < 0 or self.field.cost[s] < 0:
            return out^
        out.found = True
        out.add(mesh.snap(start, 0), PATH_WALK)
        out.add(mesh.field.world_floor(s), PATH_WALK)
        while s != gs:
            var nx = self.field.next[s]
            if self.field.next_om[s] >= 0:
                out.flags[len(out.flags) - 1] = PATH_OFFMESH
            out.add(mesh.field.world_floor(nx), PATH_WALK)
            s = nx
        out.add(mesh.snap(goal, 0), PATH_WALK)
        return out^
