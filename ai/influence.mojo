"""Influence maps and team visibility / fog of war (ROADMAP 17.15).

`InfluenceMap`: a 2D grid (XZ) of scalar layers, one per team. Sources stamp
influence with linear falloff (`stamp`); `propagate` spreads it the
Champandard way: each cell takes the max of its neighbours' value x
exp(-decay x distance), blended with its own by `momentum`, over 8
neighbours. Sources are re-stamped before each propagation step (every
frame), so the field converges to ~ strength x exp(-decay x path distance). Blocked cells (walls) neither hold nor pass influence.
`tension(a, b)` = a + b and `vulnerability`-style combinations are plain
per-cell arithmetic over layers (`combine`).

`TeamVision`: per team, the cells some unit currently sees (`visible`) and
has ever seen (`explored`) -- fog of war. A unit sees every cell within its
radius whose centre is reachable by a grid line of sight: the supercover
line from the unit's cell to the target cell crosses no blocked cell.
Blocked cells are the scene's walls (set from a `NavMesh` with
`block_from_navmesh`, or directly).
"""

from std.math import sqrt, exp, floor
from geometry.vec import Real, Vec3
from nav.navmesh import NavMesh

comptime _SQRT2: Real = 1.4142135623730951


struct InfluenceMap(Movable):
    var nx: Int
    var nz: Int
    var cell: Real
    var origin: Vec3
    var layers: Int
    var v: List[Real]  # layer-major: layer * nx * nz + x + z * nx
    var blocked: List[Bool]

    def __init__(out self, origin: Vec3, nx: Int, nz: Int, cell: Real, layers: Int) raises:
        if nx <= 0 or nz <= 0 or cell <= 0 or layers <= 0:
            raise Error("InfluenceMap: positive dimensions, cell and layer count required")
        self.nx = nx
        self.nz = nz
        self.cell = cell
        self.origin = origin
        self.layers = layers
        self.v = List[Real](length=nx * nz * layers, fill=0)
        self.blocked = List[Bool](length=nx * nz, fill=False)

    def idx(self, x: Int, z: Int) -> Int:
        return x + z * self.nx

    def cell_of(self, p: Vec3) -> Int:
        var x = Int(floor((p[0] - self.origin[0]) / self.cell))
        var z = Int(floor((p[2] - self.origin[2]) / self.cell))
        if x < 0 or z < 0 or x >= self.nx or z >= self.nz:
            return -1
        return self.idx(x, z)

    def center(self, c: Int) -> Vec3:
        var x = c % self.nx
        var z = c // self.nx
        return self.origin + Vec3((Real(x) + 0.5) * self.cell, 0, (Real(z) + 0.5) * self.cell, 0)

    def get(self, layer: Int, c: Int) -> Real:
        return self.v[layer * self.nx * self.nz + c]

    def at(self, layer: Int, p: Vec3) -> Real:
        var c = self.cell_of(p)
        return self.get(layer, c) if c >= 0 else Real(0)

    def clear(mut self, layer: Int):
        var base = layer * self.nx * self.nz
        for c in range(self.nx * self.nz):
            self.v[base + c] = 0

    def block_from_navmesh(mut self, mesh: NavMesh):
        """A cell is blocked when no walkable navmesh span lies under its centre."""
        for c in range(self.nx * self.nz):
            self.blocked[c] = mesh.find_span(self.center(c)) < 0

    def stamp(mut self, layer: Int, p: Vec3, strength: Real, radius: Real):
        """Add strength x (1 - d / radius) to every unblocked cell within radius."""
        var base = layer * self.nx * self.nz
        var r = Int(radius / self.cell) + 1
        var c0 = self.cell_of(p)
        if c0 < 0:
            return
        var x0 = c0 % self.nx
        var z0 = c0 // self.nx
        for z in range(max(z0 - r, 0), min(z0 + r, self.nz - 1) + 1):
            for x in range(max(x0 - r, 0), min(x0 + r, self.nx - 1) + 1):
                var c = self.idx(x, z)
                if self.blocked[c]:
                    continue
                var d = self.center(c) - p
                var dist = sqrt(d[0] * d[0] + d[2] * d[2])
                if dist < radius:
                    self.v[base + c] += strength * (1 - dist / radius)

    def propagate(mut self, layer: Int, decay: Real, momentum: Real, iterations: Int):
        var base = layer * self.nx * self.nz
        var n = self.nx * self.nz
        for _ in range(iterations):
            var nxt = List[Real](length=n, fill=0)
            for z in range(self.nz):
                for x in range(self.nx):
                    var c = self.idx(x, z)
                    if self.blocked[c]:
                        continue
                    var best = Real(0)
                    for dz in range(-1, 2):
                        for dx in range(-1, 2):
                            if dx == 0 and dz == 0:
                                continue
                            var xx = x + dx
                            var zz = z + dz
                            if xx < 0 or zz < 0 or xx >= self.nx or zz >= self.nz:
                                continue
                            var cc = self.idx(xx, zz)
                            if self.blocked[cc]:
                                continue
                            var dist = self.cell * (_SQRT2 if dx != 0 and dz != 0 else Real(1))
                            var val = self.v[base + cc] * exp(-decay * dist)
                            if abs(val) > abs(best):
                                best = val
                    nxt[c] = self.v[base + c] * (1 - momentum) + best * momentum
            for c in range(n):
                self.v[base + c] = nxt[c]

    def combine(mut self, out_layer: Int, a: Int, wa: Real, b: Int, wb: Real):
        """Out = wa * a + wb * b (e.g. tension = a + b, control = a - b)."""
        var n = self.nx * self.nz
        for c in range(n):
            self.v[out_layer * n + c] = wa * self.v[a * n + c] + wb * self.v[b * n + c]

    def best_cell(self, layer: Int, maximise: Bool = True) -> Int:
        var n = self.nx * self.nz
        var best = -1
        for c in range(n):
            if self.blocked[c]:
                continue
            if best < 0:
                best = c
                continue
            var a = self.v[layer * n + c]
            var b = self.v[layer * n + best]
            if (maximise and a > b) or (not maximise and a < b):
                best = c
        return best


struct TeamVision(Movable):
    var map_nx: Int
    var map_nz: Int
    var teams: Int
    var visible: List[Bool]  # team-major
    var explored: List[Bool]
    var los_checks: Int

    def __init__(out self, grid: InfluenceMap, teams: Int):
        self.map_nx = grid.nx
        self.map_nz = grid.nz
        self.teams = teams
        var n = grid.nx * grid.nz * teams
        self.visible = List[Bool](length=n, fill=False)
        self.explored = List[Bool](length=n, fill=False)
        self.los_checks = 0

    def update(mut self, grid: InfluenceMap, team: Int, units: List[Vec3], radius: Real):
        """Recompute team's visible cells from its units; OR them into explored."""
        var n = self.map_nx * self.map_nz
        var base = team * n
        for c in range(n):
            self.visible[base + c] = False
        var r = Int(radius / grid.cell)
        var r2 = radius * radius
        for u in units:
            var c0 = grid.cell_of(u)
            if c0 < 0:
                continue
            var x0 = c0 % grid.nx
            var z0 = c0 // grid.nx
            for z in range(max(z0 - r, 0), min(z0 + r, grid.nz - 1) + 1):
                for x in range(max(x0 - r, 0), min(x0 + r, grid.nx - 1) + 1):
                    var c = grid.idx(x, z)
                    if self.visible[base + c]:
                        continue
                    var d = grid.center(c) - grid.center(c0)
                    if d[0] * d[0] + d[2] * d[2] > r2:
                        continue
                    if self._los(grid, x0, z0, x, z):
                        self.visible[base + c] = True
                        self.explored[base + c] = True

    def _los(mut self, grid: InfluenceMap, x0: Int, z0: Int, x1: Int, z1: Int) -> Bool:
        """Supercover grid line between two cell centres: every cell it
        touches before the target is unblocked (at an exact corner crossing
        both side cells count). The target itself may be a wall: its face is
        seen, the cells behind it are not."""
        self.los_checks += 1
        var dx = x1 - x0
        var dz = z1 - z0
        var nx = abs(dx)
        var nz = abs(dz)
        var sx = 1 if dx > 0 else -1
        var sz = 1 if dz > 0 else -1
        var x = x0
        var z = z0
        var ix = 0
        var iz = 0
        while ix < nx or iz < nz:
            var lhs = (1 + 2 * ix) * nz
            var rhs = (1 + 2 * iz) * nx
            if lhs == rhs:
                if (x + sx != x1 or z != z1) and grid.blocked[grid.idx(x + sx, z)]:
                    return False
                if (x != x1 or z + sz != z1) and grid.blocked[grid.idx(x, z + sz)]:
                    return False
                x += sx
                z += sz
                ix += 1
                iz += 1
            elif lhs < rhs:
                x += sx
                ix += 1
            else:
                z += sz
                iz += 1
            if (x != x1 or z != z1) and grid.blocked[grid.idx(x, z)]:
                return False
        return True

    def is_visible(self, team: Int, c: Int) -> Bool:
        return self.visible[team * self.map_nx * self.map_nz + c]

    def is_explored(self, team: Int, c: Int) -> Bool:
        return self.explored[team * self.map_nx * self.map_nz + c]

    def visible_count(self, team: Int) -> Int:
        var n = 0
        var base = team * self.map_nx * self.map_nz
        for c in range(self.map_nx * self.map_nz):
            if self.visible[base + c]:
                n += 1
        return n
