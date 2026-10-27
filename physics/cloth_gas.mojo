"""Cloth <-> 2-D grid gas, two-way (ROADMAP 17.61: cloth's reaction on the
`MacFluid2` flow).

The 2-D counterpart of `ClothAir`. The gas is z-invariant with density 1
kg/m^3, so its total momentum is `depth` times sum(u) dx^2. A vertex feels
the gas velocity u = (u_x, u_y, 0) and gives it back its in-plane impulse.
Only the normal part of the drag moves the cloth, so a sheet is pushed by
the gas only when its normal has an x or y component (a sheet standing in
the gas plane, as in the test).

Per vertex, with A its share of the triangle areas and n its area-weighted
normal:

  * the normal drag F = k A n (n . (u - v)) is integrated implicitly along n,
    as in `ClothAir`: v_n <- (v_n + a u_n) / (1 + a), a = k A dt / m;
  * the cloth takes J = m (v_n_new - v_n) n (the full 3-D impulse). A pinned
    vertex (inverse mass 0) does not move and takes J = k A dt (n . (u - v)) n;
  * the gas gets minus the in-plane part of J per unit depth, through
    `MacFluid2.add_impulse`, so depth * sum(u) dx^2 changes by minus the
    in-plane part of the cloth's impulse. The z part of J has no gas
    counterpart and is kept in `z_impulse`.

`step(fluid, cloth, gravity, dt)`: drag with the gas at the start of the
step, the cloth's own step (`advance`), the gas step. `cloth_impulse` and
`gas_impulse` sum what each side received (N s, in-plane); `z_impulse` sums
the out-of-plane part of the cloth's impulse (N s). One-way (`two_way =
False`) only the cloth is pushed.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot, cross
from physics.cloth import MeshCloth
from physics.mac_fluid import MacFluid2


struct ClothGas2(Movable):
    var k: Real  # drag coefficient, kg / (m^2 s)
    var depth: Real  # extent of the gas in z, m
    var two_way: Bool
    var cloth_impulse: Tuple[Real, Real]
    var z_impulse: Real
    var gas_impulse: Tuple[Real, Real]

    def __init__(out self, k: Real, depth: Real, two_way: Bool = True) raises:
        if not (k >= 0) or not (depth > 0):
            raise Error("ClothGas2: k >= 0 and depth > 0")
        self.k = k
        self.depth = depth
        self.two_way = two_way
        self.cloth_impulse = (Real(0), Real(0))
        self.z_impulse = Real(0)
        self.gas_impulse = (Real(0), Real(0))

    def couple(mut self, mut fluid: MacFluid2, mut cloth: MeshCloth, dt: Real):
        """The drag exchange alone: the cloth takes the normal drag impulse, the
        gas takes its in-plane reaction when two-way. Neither side moves here."""
        var n = len(cloth.x)
        var area = List[Real](length=n, fill=0)
        var normal = List[Vec3](length=n, fill=Vec3(0, 0, 0, 0))
        for t in range(len(cloth.tris) // 3):
            var a = cloth.tris[3 * t]
            var b = cloth.tris[3 * t + 1]
            var c = cloth.tris[3 * t + 2]
            var nn = cross(cloth.x[b] - cloth.x[a], cloth.x[c] - cloth.x[a])
            var ar = 0.5 * sqrt(dot(nn, nn)) / 3
            for v in [a, b, c]:
                area[v] += ar
                normal[v] = normal[v] + nn
        var cx = self.cloth_impulse[0]
        var cy = self.cloth_impulse[1]
        var gx = self.gas_impulse[0]
        var gy = self.gas_impulse[1]
        var zi = self.z_impulse
        for i in range(n):
            var nl = sqrt(dot(normal[i], normal[i]))
            if nl <= 0 or area[i] <= 0:
                continue
            var nrm = normal[i] / nl
            var g = fluid.velocity(cloth.x[i][0], cloth.x[i][1])
            var u = Vec3(g[0], g[1], 0, 0)
            var j: Vec3
            if cloth.w[i] > 0:
                var m = 1 / cloth.w[i]
                var a = self.k * area[i] * dt / m
                var vn = dot(cloth.v[i], nrm)
                var vn_new = (vn + a * dot(u, nrm)) / (1 + a)
                j = nrm * (m * (vn_new - vn))
                cloth.v[i] = cloth.v[i] + nrm * (vn_new - vn)
            else:
                j = nrm * (self.k * area[i] * dt * dot(u - cloth.v[i], nrm))
            cx += j[0]
            cy += j[1]
            zi += j[2]
            if self.two_way:
                fluid.add_impulse(cloth.x[i][0], cloth.x[i][1], -j[0] / self.depth, -j[1] / self.depth)
                gx -= j[0]
                gy -= j[1]
        self.cloth_impulse = (cx, cy)
        self.z_impulse = zi
        self.gas_impulse = (gx, gy)

    def step(mut self, mut fluid: MacFluid2, mut cloth: MeshCloth, gravity: Vec3, dt: Real) raises:
        self.couple(fluid, cloth, dt)
        cloth.advance(dt, gravity)
        fluid.step(dt)
