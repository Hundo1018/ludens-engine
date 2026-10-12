"""Hierarchical long-range pathfinding over navmesh tiles (ROADMAP 17.14).

HPA* (Botea, Mueller, Schaeffer 2004) with the navmesh's tiles as clusters:

- portal graph -- one node per portal between two polygons (its midpoint)
  and per off-mesh link end; two nodes on the same convex polygon are joined
  by their straight distance (the segment lies inside that polygon), and an
  off-mesh link is a directed edge;
- entrances -- portal nodes on a tile border, plus off-mesh ends; each
  belongs to the one or two tiles it touches;
- abstract graph (`build`) -- per tile, one Dijkstra over the tile's portal
  graph from every entrance gives the in-tile cost to every other entrance;
  off-mesh links are added as they are;
- query (`HierFunnel.find`) -- in-tile Dijkstra from the start and to the
  goal attach them to their tiles' entrances, A* runs on the abstract graph,
  and the route's tiles become the mask of a `PolyFunnel` search that
  produces the final funnel path. Only the tiles on the coarse route are
  searched in detail -- the property a streamed world needs (a cell that is
  not loaded holds only its entrance costs).

Reachability is exact (connectivity inside a tile equals connectivity of its
portal graph); the path is the masked polygon search's, so its length bounds
are those of `PolyFunnel`. The abstract graph is rebuilt when
`mesh.version` changes (obstacle carving, off-mesh links).
"""

from std.math import sqrt
from geometry.vec import Real, Vec3
from nav.navmesh import NavMesh, dist3
from nav.path import NavPath, PathFinder, PolyFunnel, MinHeap


struct HpaGraph(Movable):
    var version: Int
    # portal-graph nodes
    var pos: List[Vec3]
    var poly_a: List[Int]
    var poly_b: List[Int]  # -1 when the node lies on one polygon only
    var node_of_link: List[Int]
    # nodes per polygon (CSR)
    var pn_start: List[Int]
    var pn: List[Int]
    # off-mesh directed edges (node -> node, cost)
    var om_from: List[Int]
    var om_to: List[Int]
    var om_cost: List[Real]
    # entrances and the abstract graph (CSR over node ids; only entrances have edges)
    var is_entrance: List[Bool]
    var ab_start: List[Int]
    var ab_to: List[Int]
    var ab_cost: List[Real]
    var entrance_count: Int

    def __init__(out self):
        self.version = -1
        self.pos = List[Vec3]()
        self.poly_a = List[Int]()
        self.poly_b = List[Int]()
        self.node_of_link = List[Int]()
        self.pn_start = List[Int]()
        self.pn = List[Int]()
        self.om_from = List[Int]()
        self.om_to = List[Int]()
        self.om_cost = List[Real]()
        self.is_entrance = List[Bool]()
        self.ab_start = List[Int]()
        self.ab_to = List[Int]()
        self.ab_cost = List[Real]()
        self.entrance_count = 0

    def node_count(self) -> Int:
        return len(self.pos)

    def _tile(self, mesh: NavMesh, p: Int) -> Int:
        return mesh.p_rect[p] >> 32

    def build(mut self, mesh: NavMesh):
        self.version = mesh.version
        var np = mesh.poly_count()
        var nl = mesh.link_count()
        self.pos = List[Vec3]()
        self.poly_a = List[Int]()
        self.poly_b = List[Int]()
        self.node_of_link = List[Int](length=nl, fill=-1)
        self.om_from = List[Int]()
        self.om_to = List[Int]()
        self.om_cost = List[Real]()
        # portal nodes: one per unordered polygon pair + midpoint
        for p in range(np):
            for l in range(mesh.link_start[p], mesh.link_start[p + 1]):
                if mesh.l_offmesh[l] >= 0 or self.node_of_link[l] >= 0:
                    continue
                var q = mesh.l_to[l]
                var mid = (mesh.l_a[l] + mesh.l_b[l]) * 0.5
                var id = len(self.pos)
                self.pos.append(mid)
                self.poly_a.append(p)
                self.poly_b.append(q)
                self.node_of_link[l] = id
                for r in range(mesh.link_start[q], mesh.link_start[q + 1]):
                    if mesh.l_to[r] == p and mesh.l_offmesh[r] < 0 and self.node_of_link[r] < 0:
                        var m2 = (mesh.l_a[r] + mesh.l_b[r]) * 0.5
                        var d = m2 - mid
                        if d[0] == 0 and d[1] == 0 and d[2] == 0:
                            self.node_of_link[r] = id
                            break
        # off-mesh ends: a node at each end, a directed edge per direction
        for p in range(np):
            for l in range(mesh.link_start[p], mesh.link_start[p + 1]):
                var o = mesh.l_offmesh[l]
                if o < 0:
                    continue
                var a = len(self.pos)
                self.pos.append(mesh.l_a[l])
                self.poly_a.append(p)
                self.poly_b.append(-1)
                var b = len(self.pos)
                self.pos.append(mesh.l_b[l])
                self.poly_a.append(mesh.l_to[l])
                self.poly_b.append(-1)
                self.node_of_link[l] = a
                self.om_from.append(a)
                self.om_to.append(b)
                self.om_cost.append(dist3(mesh.l_a[l], mesh.l_b[l]) * mesh.om_cost_mul[o])
        var n = len(self.pos)
        # nodes per polygon
        self.pn_start = List[Int](length=np + 1, fill=0)
        for k in range(n):
            self.pn_start[self.poly_a[k] + 1] += 1
            if self.poly_b[k] >= 0:
                self.pn_start[self.poly_b[k] + 1] += 1
        for p in range(np):
            self.pn_start[p + 1] += self.pn_start[p]
        var fill = self.pn_start.copy()
        self.pn = List[Int](length=self.pn_start[np], fill=-1)
        for k in range(n):
            self.pn[fill[self.poly_a[k]]] = k
            fill[self.poly_a[k]] += 1
            if self.poly_b[k] >= 0:
                self.pn[fill[self.poly_b[k]]] = k
                fill[self.poly_b[k]] += 1
        # entrances
        self.is_entrance = List[Bool](length=n, fill=False)
        self.entrance_count = 0
        for k in range(n):
            var cross = self.poly_b[k] >= 0 and self._tile(mesh, self.poly_a[k]) != self._tile(mesh, self.poly_b[k])
            if cross or self.poly_b[k] < 0:
                self.is_entrance[k] = True
                self.entrance_count += 1
        # abstract edges: per entrance, Dijkstra inside each of its tiles
        var src = List[Int]()
        var dst = List[Int]()
        var cst = List[Real]()
        var dist = List[Real](length=n, fill=Real(-1))
        var done = List[Bool](length=n, fill=False)
        var touched = List[Int]()
        var heap = MinHeap()
        for e in range(n):
            if not self.is_entrance[e]:
                continue
            for side in range(2):
                var poly = self.poly_a[e] if side == 0 else self.poly_b[e]
                if poly < 0:
                    continue
                var tile = self._tile(mesh, poly)
                self._dijkstra_tile(mesh, tile, e, dist, done, touched, heap)
                for t in touched:
                    if t != e and self.is_entrance[t]:
                        src.append(e)
                        dst.append(t)
                        cst.append(dist[t])
                for t in touched:
                    dist[t] = -1
                    done[t] = False
                touched.clear()
        for k in range(len(self.om_from)):
            src.append(self.om_from[k])
            dst.append(self.om_to[k])
            cst.append(self.om_cost[k])
        self.ab_start = List[Int](length=n + 1, fill=0)
        for i in range(len(src)):
            self.ab_start[src[i] + 1] += 1
        for k in range(n):
            self.ab_start[k + 1] += self.ab_start[k]
        var f2 = self.ab_start.copy()
        self.ab_to = List[Int](length=len(src), fill=-1)
        self.ab_cost = List[Real](length=len(src), fill=0)
        for i in range(len(src)):
            var at = f2[src[i]]
            f2[src[i]] += 1
            self.ab_to[at] = dst[i]
            self.ab_cost[at] = cst[i]

    def _in_tile(self, mesh: NavMesh, k: Int, tile: Int) -> Bool:
        if self._tile(mesh, self.poly_a[k]) == tile:
            return True
        return self.poly_b[k] >= 0 and self._tile(mesh, self.poly_b[k]) == tile

    def _dijkstra_tile(
        self,
        mesh: NavMesh,
        tile: Int,
        from_node: Int,
        mut dist: List[Real],
        mut done: List[Bool],
        mut touched: List[Int],
        mut heap: MinHeap,
    ):
        """Portal-graph Dijkstra from `from_node`, moving only through
        polygons of `tile`. Writes dist[] for every node reached (listed in
        `touched`)."""
        heap.clear()
        dist[from_node] = 0
        touched.append(from_node)
        heap.push(0, from_node)
        while len(heap) > 0:
            var u = heap.pop()
            if done[u]:
                continue
            done[u] = True
            for side in range(2):
                var poly = self.poly_a[u] if side == 0 else self.poly_b[u]
                if poly < 0 or self._tile(mesh, poly) != tile:
                    continue
                for i in range(self.pn_start[poly], self.pn_start[poly + 1]):
                    var v = self.pn[i]
                    if v == u:
                        continue
                    var nd = dist[u] + dist3(self.pos[u], self.pos[v])
                    if dist[v] < 0 or nd < dist[v]:
                        if dist[v] < 0:
                            touched.append(v)
                        dist[v] = nd
                        heap.push(nd, v)


struct HierFunnel(PathFinder):
    """HPA* over navmesh tiles, refined by a tile-masked `PolyFunnel`."""

    var graph: HpaGraph
    var fine: PolyFunnel
    var g: List[Real]
    var parent: List[Int]
    var stamp: List[Int]
    var closed: List[Int]
    var gen: Int
    var heap: MinHeap
    var last_tiles: Int  # tiles searched in detail by the last query
    var last_abstract_expanded: Int

    def __init__(out self):
        self.graph = HpaGraph()
        self.fine = PolyFunnel()
        self.g = List[Real]()
        self.parent = List[Int]()
        self.stamp = List[Int]()
        self.closed = List[Int]()
        self.gen = 0
        self.heap = MinHeap()
        self.last_tiles = 0
        self.last_abstract_expanded = 0

    def _attach(self, mesh: NavMesh, p: Vec3, poly: Int, mut cost: List[Real], mut touched: List[Int]):
        """In-tile costs from point p (on `poly`) to every portal node of its
        tile: Dijkstra seeded with p's own polygon's nodes."""
        var tile = mesh.p_rect[poly] >> 32
        var heap = MinHeap()
        for i in range(self.graph.pn_start[poly], self.graph.pn_start[poly + 1]):
            var v = self.graph.pn[i]
            var d = dist3(p, self.graph.pos[v])
            if cost[v] < 0 or d < cost[v]:
                if cost[v] < 0:
                    touched.append(v)
                cost[v] = d
                heap.push(d, v)
        var done = List[Bool](length=self.graph.node_count(), fill=False)
        while len(heap) > 0:
            var u = heap.pop()
            if done[u]:
                continue
            done[u] = True
            for side in range(2):
                var pp = self.graph.poly_a[u] if side == 0 else self.graph.poly_b[u]
                if pp < 0 or (mesh.p_rect[pp] >> 32) != tile:
                    continue
                for i in range(self.graph.pn_start[pp], self.graph.pn_start[pp + 1]):
                    var v = self.graph.pn[i]
                    var nd = cost[u] + dist3(self.graph.pos[u], self.graph.pos[v])
                    if cost[v] < 0 or nd < cost[v]:
                        if cost[v] < 0:
                            touched.append(v)
                        cost[v] = nd
                        heap.push(nd, v)

    def find(mut self, mesh: NavMesh, start: Vec3, goal: Vec3) -> NavPath:
        var out = NavPath()
        if self.graph.version != mesh.version:
            self.graph.build(mesh)
        var sp = mesh.find_poly(start)
        var gp = mesh.find_poly(goal)
        if sp < 0 or gp < 0:
            return out^
        var ts = mesh.p_rect[sp] >> 32
        var tg = mesh.p_rect[gp] >> 32
        var n = self.graph.node_count()
        # virtual nodes: n = START, n + 1 = GOAL
        var cs = List[Real](length=n, fill=Real(-1))
        var cg = List[Real](length=n, fill=Real(-1))
        var ts_list = List[Int]()
        var tg_list = List[Int]()
        self._attach(mesh, start, sp, cs, ts_list)
        self._attach(mesh, goal, gp, cg, tg_list)
        # direct in-tile connection: same polygon, or through a shared node
        var direct = Real(-1)
        if sp == gp:
            direct = dist3(start, goal)
        elif ts == tg:
            for v in ts_list:
                if cg[v] >= 0 and (direct < 0 or cs[v] + cg[v] < direct):
                    direct = cs[v] + cg[v]
        var total = n + 2
        if len(self.g) != total:
            self.g = List[Real](length=total, fill=0)
            self.parent = List[Int](length=total, fill=-1)
            self.stamp = List[Int](length=total, fill=0)
            self.closed = List[Int](length=total, fill=0)
            self.gen = 0
        self.gen += 1
        var gen = self.gen
        self.heap.clear()
        var S = n
        var G = n + 1
        self.g[S] = 0
        self.parent[S] = -1
        self.stamp[S] = gen
        self.heap.push(dist3(start, goal), S)
        var expanded = 0
        var reached = False
        while len(self.heap) > 0:
            var u = self.heap.pop()
            if self.closed[u] == gen:
                continue
            self.closed[u] = gen
            expanded += 1
            if u == G:
                reached = True
                break
            # successors
            if u == S:
                if direct >= 0:
                    self._relax(S, G, direct, goal, goal, gen)
                for v in ts_list:
                    if self.graph.is_entrance[v]:
                        self._relax(S, v, cs[v], self.graph.pos[v], goal, gen)
                continue
            if cg[u] >= 0:
                self._relax(u, G, cg[u], goal, goal, gen)
            for e in range(self.graph.ab_start[u], self.graph.ab_start[u + 1]):
                var v = self.graph.ab_to[e]
                self._relax(u, v, self.graph.ab_cost[e], self.graph.pos[v], goal, gen)
        self.last_abstract_expanded = expanded
        if not reached:
            out.expanded = expanded
            return out^
        # tiles on the coarse route
        var mask = List[Bool](length=len(mesh.tile_rects), fill=False)
        mask[ts] = True
        mask[tg] = True
        var c = self.parent[G]
        while c >= 0 and c != S:
            mask[mesh.p_rect[self.graph.poly_a[c]] >> 32] = True
            if self.graph.poly_b[c] >= 0:
                mask[mesh.p_rect[self.graph.poly_b[c]] >> 32] = True
            c = self.parent[c]
        var tiles = 0
        for m in mask:
            if m:
                tiles += 1
        self.last_tiles = tiles
        self.fine.tile_mask = mask^
        var p = self.fine.find(mesh, start, goal)
        self.fine.tile_mask = List[Bool]()
        p.expanded += expanded
        return p^

    def _relax(mut self, u: Int, v: Int, w: Real, pv: Vec3, goal: Vec3, gen: Int):
        if self.closed[v] == gen:
            return
        var ng = self.g[u] + w
        if self.stamp[v] != gen or ng < self.g[v]:
            self.stamp[v] = gen
            self.g[v] = ng
            self.parent[v] = u
            self.heap.push(ng + dist3(pv, goal), v)
