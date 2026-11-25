"""Projected decals on the CPU (#140): a box projected onto the triangles under it (a mesh's or the terrain's), clipped to
the box, kept as its own small mesh. The GPU side is `app/decal_pass.mojo`.

A decal is a box: centre c, unit axes u (the decal's width), v (its height) and w (the direction it is projected along,
into the surface), half extents hu, hv, hw. Winding is not trusted (meshes and the terrain wind differently), so a
triangle's normal is taken as the side facing the projector; a triangle edge-on to w is skipped. A surface behind the
hit one but inside the box (the far side of a thin wall) is caught too: keep hw below the thickness of what is hit. The triangle, in the box's frame, is clipped against the six planes |x| <= hu,
|y| <= hv, |z| <= hw (Sutherland-Hodgman), and the polygon left is fanned into triangles. Each vertex gets
uv = (x / hu, y / hv) * 0.5 + 0.5, a `fade` = -(n . w) (1 head-on, 0 grazing) for the shader to fade grazing hits, and is
lifted DECAL_LIFT metres along the triangle's normal so the depth test against the surface passes.

Sources: `project_triangle` takes a world-space triangle; `project_mesh` transforms a mesh's positions as the mesh pass
does (rotation from the quaternion, scaled per axis by `half`, then translated: app/mesh_pass.mojo) and culls triangles
whose bounds miss the box before clipping; `project_terrain` takes the level-0 triangles of the cells under the box
(the collider's tessellation, game/terrain.mojo).

`DecalSet` keeps at most `max_decals` (adding past it replaces the oldest, counted in `replaced`) and draws per frame at
most `max_triangles`, newest first: a decal that does not fit is not drawn that frame (`over_budget`). A decal further
than `max_distance` from the camera is not drawn (`far`).

Record per vertex (vec4 x 3): [x y z fade] [u v layer 0] [r g b a].

Determinism: + - * / and sqrt on Float64; the same calls give the same triangles."""
from std.math import sqrt
from game.terrain import TerrainField

comptime DECAL_LIFT = 0.004  # metres along the surface normal
comptime DECAL_VERTEX_FLOATS = 12


def _norm3(x: Float64, y: Float64, z: Float64) -> List[Float64]:
    var l = sqrt(x * x + y * y + z * z)
    if l < 1e-12:
        return [0.0, 0.0, 0.0]
    return [x / l, y / l, z / l]


def _cross(a: List[Float64], b: List[Float64]) -> List[Float64]:
    return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]


struct Decal(Copyable, Movable):
    var c: List[Float64]
    var u: List[Float64]
    var v: List[Float64]
    var w: List[Float64]
    var hu: Float64
    var hv: Float64
    var hw: Float64
    var color: List[Float64]
    var layer: Int

    def __init__(
        out self, cx: Float64, cy: Float64, cz: Float64, dx: Float64, dy: Float64, dz: Float64,
        upx: Float64, upy: Float64, upz: Float64, hu: Float64, hv: Float64, hw: Float64, var color: List[Float64],
        layer: Int = 0,
    ) raises:
        """A decal centred at c, projected along d, its v axis towards `up` (made perpendicular to d)."""
        if hu <= 0.0 or hv <= 0.0 or hw <= 0.0:
            raise Error("Decal: half extents must be > 0")
        if len(color) != 4:
            raise Error("Decal: colour is r g b a")
        self.w = _norm3(dx, dy, dz)
        if self.w[0] == 0.0 and self.w[1] == 0.0 and self.w[2] == 0.0:
            raise Error("Decal: the projection direction is zero")
        var u = _norm3(upy * self.w[2] - upz * self.w[1], upz * self.w[0] - upx * self.w[2], upx * self.w[1] - upy * self.w[0])
        if u[0] == 0.0 and u[1] == 0.0 and u[2] == 0.0:
            raise Error("Decal: `up` is parallel to the projection direction")
        self.u = u^
        self.v = _cross(self.w, self.u)
        self.c = [cx, cy, cz]
        self.hu = hu
        self.hv = hv
        self.hw = hw
        self.color = color^
        self.layer = layer

    def radius(self) -> Float64:
        return sqrt(self.hu * self.hu + self.hv * self.hv + self.hw * self.hw)

    def world_bounds(self) -> List[Float64]:
        """x0 y0 z0 x1 y1 z1 of the box."""
        var out: List[Float64] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        for k in range(3):
            var e = abs(self.u[k]) * self.hu + abs(self.v[k]) * self.hv + abs(self.w[k]) * self.hw
            out[k] = self.c[k] - e
            out[k + 3] = self.c[k] + e
        return out^


struct DecalMesh(Movable):
    """The clipped triangles of one decal: DECAL_VERTEX_FLOATS per vertex, 3 vertices per triangle."""

    var decal: Decal
    var verts: List[Float32]

    def __init__(out self, var decal: Decal):
        self.decal = decal^
        self.verts = List[Float32]()

    def triangles(self) -> Int:
        return len(self.verts) // (3 * DECAL_VERTEX_FLOATS)

    def project_triangle(
        mut self, ax: Float64, ay: Float64, az: Float64, bx: Float64, by: Float64, bz: Float64,
        cx: Float64, cy: Float64, cz: Float64,
    ):
        ref d = self.decal
        var n = _norm3(
            (by - ay) * (cz - az) - (bz - az) * (cy - ay),
            (bz - az) * (cx - ax) - (bx - ax) * (cz - az),
            (bx - ax) * (cy - ay) - (by - ay) * (cx - ax),
        )
        var facing = -(n[0] * d.w[0] + n[1] * d.w[1] + n[2] * d.w[2])
        if facing < 0.0:  # wound the other way: the side facing the projector is the front
            n = [-n[0], -n[1], -n[2]]
            facing = -facing
        if facing <= 0.0:
            return
        var poly = List[Float64]()  # local x y z per vertex
        for p in [[ax, ay, az], [bx, by, bz], [cx, cy, cz]]:
            var rx = p[0] - d.c[0]
            var ry = p[1] - d.c[1]
            var rz = p[2] - d.c[2]
            poly.append(rx * d.u[0] + ry * d.u[1] + rz * d.u[2])
            poly.append(rx * d.v[0] + ry * d.v[1] + rz * d.v[2])
            poly.append(rx * d.w[0] + ry * d.w[1] + rz * d.w[2])
        for axis in range(3):
            var h = d.hu if axis == 0 else (d.hv if axis == 1 else d.hw)
            poly = _clip(poly, axis, h, 1.0)
            poly = _clip(poly, axis, h, -1.0)
            if len(poly) < 9:
                return
        var m = len(poly) // 3
        for k in range(1, m - 1):
            for idx in [0, k, k + 1]:
                var x = poly[3 * idx]
                var y = poly[3 * idx + 1]
                var z = poly[3 * idx + 2]
                for j in range(3):
                    self.verts.append(Float32(d.c[j] + x * d.u[j] + y * d.v[j] + z * d.w[j] + n[j] * DECAL_LIFT))
                self.verts.append(Float32(facing))
                self.verts.append(Float32(x / d.hu * 0.5 + 0.5))
                self.verts.append(Float32(y / d.hv * 0.5 + 0.5))
                self.verts.append(Float32(d.layer))
                self.verts.append(0.0)
                for j in range(4):
                    self.verts.append(Float32(d.color[j]))

    def project_mesh(
        mut self, positions: List[Float32], indices: List[UInt32], px: Float64, py: Float64, pz: Float64,
        qx: Float64, qy: Float64, qz: Float64, qw: Float64, sx: Float64, sy: Float64, sz: Float64,
    ) -> Int:
        """Project onto a mesh placed like a DrawItem (pos, rotation q, per-axis scale `half`). Returns the triangles
        that reached the clipper (their bounds met the box)."""
        var b = self.decal.world_bounds()
        var nv = len(positions) // 3
        var world = List[Float64](capacity=nv * 3)
        for i in range(nv):
            var lx = Float64(positions[3 * i]) * sx
            var ly = Float64(positions[3 * i + 1]) * sy
            var lz = Float64(positions[3 * i + 2]) * sz
            # v + 2 w (q x v) + 2 q x (q x v), the rotation of a unit quaternion
            var tx = 2.0 * (qy * lz - qz * ly)
            var ty = 2.0 * (qz * lx - qx * lz)
            var tz = 2.0 * (qx * ly - qy * lx)
            world.append(px + lx + qw * tx + (qy * tz - qz * ty))
            world.append(py + ly + qw * ty + (qz * tx - qx * tz))
            world.append(pz + lz + qw * tz + (qx * ty - qy * tx))
        var tested = 0
        for t in range(len(indices) // 3):
            var i0 = Int(indices[3 * t]) * 3
            var i1 = Int(indices[3 * t + 1]) * 3
            var i2 = Int(indices[3 * t + 2]) * 3
            var miss = False
            for k in range(3):
                var lo = min(world[i0 + k], world[i1 + k], world[i2 + k])
                var hi = max(world[i0 + k], world[i1 + k], world[i2 + k])
                if hi < b[k] or lo > b[k + 3]:
                    miss = True
            if miss:
                continue
            tested += 1
            self.project_triangle(
                world[i0], world[i0 + 1], world[i0 + 2], world[i1], world[i1 + 1], world[i1 + 2],
                world[i2], world[i2 + 1], world[i2 + 2],
            )
        return tested

    def project_terrain(mut self, f: TerrainField) -> Int:
        """Project onto the level-0 triangles of the terrain cells under the box. Returns the cells visited."""
        var b = self.decal.world_bounds()
        var ix0 = max(Int((b[0] - Float64(f.ox)) / Float64(f.cell)) - 1, 0)
        var ix1 = min(Int((b[3] - Float64(f.ox)) / Float64(f.cell)) + 1, f.nx - 2)
        var iz0 = max(Int((b[2] - Float64(f.oz)) / Float64(f.cell)) - 1, 0)
        var iz1 = min(Int((b[5] - Float64(f.oz)) / Float64(f.cell)) + 1, f.nz - 2)
        var cells = 0
        for iz in range(iz0, iz1 + 1):
            for ix in range(ix0, ix1 + 1):
                cells += 1
                var x0 = Float64(f.ox) + Float64(ix) * Float64(f.cell)
                var z0 = Float64(f.oz) + Float64(iz) * Float64(f.cell)
                var x1 = x0 + Float64(f.cell)
                var z1 = z0 + Float64(f.cell)
                var h00 = Float64(f.height(ix, iz))
                var h10 = Float64(f.height(ix + 1, iz))
                var h01 = Float64(f.height(ix, iz + 1))
                var h11 = Float64(f.height(ix + 1, iz + 1))
                if ((ix + iz) & 1) == 0:  # the diagonal of HeightField.tri
                    self.project_triangle(x0, h00, z0, x0, h01, z1, x1, h11, z1)
                    self.project_triangle(x0, h00, z0, x1, h11, z1, x1, h10, z0)
                else:
                    self.project_triangle(x0, h00, z0, x0, h01, z1, x1, h10, z0)
                    self.project_triangle(x1, h10, z0, x0, h01, z1, x1, h11, z1)
        return cells


def _clip(poly: List[Float64], axis: Int, h: Float64, sign: Float64) -> List[Float64]:
    """Keep the part of the polygon (local x y z per vertex) with sign * p[axis] <= h."""
    var out = List[Float64]()
    var m = len(poly) // 3
    if m == 0:
        return out^
    for i in range(m):
        var j = (i + 1) % m
        var da = sign * poly[3 * i + axis] - h
        var db = sign * poly[3 * j + axis] - h
        if da <= 0.0:
            for k in range(3):
                out.append(poly[3 * i + k])
        if (da <= 0.0) != (db <= 0.0):
            var t = da / (da - db)
            for k in range(3):
                out.append(poly[3 * i + k] + (poly[3 * j + k] - poly[3 * i + k]) * t)
    return out^


struct DecalSet(Movable):
    var meshes: List[DecalMesh]  # oldest first
    var max_decals: Int
    var max_triangles: Int  # per frame
    var max_distance: Float64
    var replaced: Int  # decals removed to make room
    var over_budget: Int  # last pack: decals not drawn for the triangle budget
    var far: Int  # last pack: decals not drawn for distance

    def __init__(out self, max_decals: Int = 256, max_triangles: Int = 16384, max_distance: Float64 = 60.0):
        self.meshes = List[DecalMesh]()
        self.max_decals = max_decals
        self.max_triangles = max_triangles
        self.max_distance = max_distance
        self.replaced = 0
        self.over_budget = 0
        self.far = 0

    def add(mut self, var mesh: DecalMesh) -> Int:
        """Keep a projected decal; past max_decals the oldest is removed. A decal that caught no triangle is not kept
        (returns -1)."""
        if mesh.triangles() == 0:
            return -1
        if len(self.meshes) >= self.max_decals:
            for i in range(1, len(self.meshes)):
                self.meshes.swap_elements(i - 1, i)
            _ = self.meshes.pop()
            self.replaced += 1
        self.meshes.append(mesh^)
        return len(self.meshes) - 1

    def pack(mut self, cam_x: Float64, cam_y: Float64, cam_z: Float64, mut out: List[Float32]) -> Int:
        """Append the vertices of the decals to draw, newest first, within the budget. Returns the triangles written.
        Decals overlap in the order they were added: the GPU pass draws the written list back to front."""
        self.over_budget = 0
        self.far = 0
        var chosen = List[Int]()
        var tris = 0
        var i = len(self.meshes) - 1
        while i >= 0:
            ref m = self.meshes[i]
            var dx = m.decal.c[0] - cam_x
            var dy = m.decal.c[1] - cam_y
            var dz = m.decal.c[2] - cam_z
            var reach = self.max_distance + m.decal.radius()
            if dx * dx + dy * dy + dz * dz > reach * reach:
                self.far += 1
            elif tris + m.triangles() > self.max_triangles:
                self.over_budget += 1
            else:
                chosen.append(i)
                tris += m.triangles()
            i -= 1
        # oldest of the chosen first, so a newer decal is drawn over an older one
        var k = len(chosen) - 1
        while k >= 0:
            ref v = self.meshes[chosen[k]].verts
            for j in range(len(v)):
                out.append(v[j])
            k -= 1
        return tris
