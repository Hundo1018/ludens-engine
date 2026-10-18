"""Fluid and rigid bodies in one position-based solve (ROADMAP 17.59:
PBF two-way, Macklin et al. 2014 "Unified particle physics").

Rigid bodies are clusters of particles at the fluid's spacing. Per step:
predict every particle under gravity; then, per iteration, every fluid
particle's density constraint C_i = rho_i / rho0 - 1 (neighbours fluid
and solid alike, the PBF kernels of `physics.pbf`) gives a lambda_i, and
each particle k near i moves by w_k lambda_i grad_k C_i with w_k its
inverse mass relative to a fluid particle's (a body of density rho_b
has w = rho_fluid / rho_b: light bodies are pushed more, heavy ones
less -- the momentum the fluid gives is what the body takes); then every
cluster is shape-matched back to a rigid pose (centroid plus the polar
rotation of sum (p - c) q_rest^T, `fem.polar_rotation`); then the box
clamps everything. Velocities are the position change over dt.

The earlier attempt recorded under 17.59 pushed the fluid against fixed
body samples and handed the reaction back as an explicit force; a
density-300 box was thrown out of the tank. Here the body moves inside
the same projection, so its displacement is limited the same way the
fluid's is (`test_pbf_unified`: a light box floats at its density
ratio's draft, a heavy one sinks).
"""

from std.math import sqrt
from geometry.vec import Real, Vec3
from geometry.mat import Mat3
from .pbf import H, poly6, spiky_grad
from .fem import polar_rotation

comptime _EPS: Real = 1e-4
comptime _MAX_CORR: Real = 0.2


struct UnifiedPbf(Movable):
    var x: List[Vec3]  # positions (start of step)
    var p: List[Vec3]  # working positions
    var v: List[Vec3]
    var w: List[Real]  # inverse mass relative to a fluid particle
    var body: List[Int]  # -1 = fluid, else rigid body index
    var rest: List[Vec3]  # per particle: rest offset from its body centroid (solids)
    var body_first: List[Int]
    var body_count: List[Int]
    var lo: Vec3
    var hi: Vec3
    var rho0: Real
    var lam: List[Real]

    def __init__(out self, lo: Vec3, hi: Vec3):
        self.x = List[Vec3]()
        self.p = List[Vec3]()
        self.v = List[Vec3]()
        self.w = List[Real]()
        self.body = List[Int]()
        self.rest = List[Vec3]()
        self.body_first = List[Int]()
        self.body_count = List[Int]()
        self.lo = lo
        self.hi = hi
        self.rho0 = 1
        self.lam = List[Real]()

    def calibrate(mut self, spacing: Real):
        """Rest density of a particle in a full lattice at `spacing`."""
        var reach = Int(H / spacing) + 1
        var rho = Real(0)
        for i in range(-reach, reach + 1):
            for j in range(-reach, reach + 1):
                for k in range(-reach, reach + 1):
                    var dx = Real(i) * spacing
                    var dy = Real(j) * spacing
                    var dz = Real(k) * spacing
                    rho += poly6(dx * dx + dy * dy + dz * dz)
        self.rho0 = rho

    def count(self) -> Int:
        return len(self.x)

    def add_fluid(mut self, pos: Vec3):
        self.x.append(pos)
        self.p.append(pos)
        self.v.append(Vec3(0, 0, 0, 0))
        self.w.append(1)
        self.body.append(-1)
        self.rest.append(Vec3(0, 0, 0, 0))
        self.lam.append(0)

    def add_body(mut self, points: List[Vec3], density_ratio: Real) raises -> Int:
        """A rigid body made of `points` (fluid spacing); `density_ratio`
        = body density / fluid density."""
        if len(points) < 1 or not (density_ratio > 0):
            raise Error("UnifiedPbf.add_body: >= 1 point and a positive density ratio")
        var b = len(self.body_first)
        var c = Vec3(0, 0, 0, 0)
        for q in points:
            c = c + q
        c = c / Real(len(points))
        self.body_first.append(len(self.x))
        self.body_count.append(len(points))
        for q in points:
            self.x.append(q)
            self.p.append(q)
            self.v.append(Vec3(0, 0, 0, 0))
            self.w.append(1 / density_ratio)
            self.body.append(b)
            self.rest.append(q - c)
            self.lam.append(0)
        return b

    def body_centroid(self, b: Int) -> Vec3:
        var c = Vec3(0, 0, 0, 0)
        for k in range(self.body_first[b], self.body_first[b] + self.body_count[b]):
            c = c + self.x[k]
        return c / Real(self.body_count[b])

    def body_velocity(self, b: Int) -> Vec3:
        var c = Vec3(0, 0, 0, 0)
        for k in range(self.body_first[b], self.body_first[b] + self.body_count[b]):
            c = c + self.v[k]
        return c / Real(self.body_count[b])

    def _clamp(mut self, k: Int):
        var q = self.p[k]
        self.p[k] = Vec3(
            min(max(q[0], self.lo[0]), self.hi[0]),
            min(max(q[1], self.lo[1]), self.hi[1]),
            min(max(q[2], self.lo[2]), self.hi[2]),
            0,
        )

    def _shape_match(mut self, b: Int):
        var f = self.body_first[b]
        var m = self.body_count[b]
        var c = Vec3(0, 0, 0, 0)
        for k in range(f, f + m):
            c = c + self.p[k]
        c = c / Real(m)
        if m < 3:
            for k in range(f, f + m):
                self.p[k] = c + self.rest[k]
            return
        var a = Mat3()
        for k in range(f, f + m):
            var d = self.p[k] - c
            var r = self.rest[k]
            for i in range(3):
                for j in range(3):
                    a.set(i, j, a.get(i, j) + d[i] * r[j])
        var rot = polar_rotation(a)
        for k in range(f, f + m):
            var r = self.rest[k]
            self.p[k] = c + Vec3(
                rot.get(0, 0) * r[0] + rot.get(0, 1) * r[1] + rot.get(0, 2) * r[2],
                rot.get(1, 0) * r[0] + rot.get(1, 1) * r[1] + rot.get(1, 2) * r[2],
                rot.get(2, 0) * r[0] + rot.get(2, 1) * r[1] + rot.get(2, 2) * r[2],
                0,
            )

    def _neighbours(self) -> List[List[Int]]:
        """Neighbours within H of every particle (cell hashing on H)."""
        var n = len(self.p)
        var gx = Int((self.hi[0] - self.lo[0]) / H) + 1
        var gy = Int((self.hi[1] - self.lo[1]) / H) + 1
        var gz = Int((self.hi[2] - self.lo[2]) / H) + 1
        var start = List[Int](length=gx * gy * gz + 1, fill=0)
        var cell = List[Int](length=n, fill=0)
        for k in range(n):
            var q = self.p[k] - self.lo
            var a = min(max(Int(q[0] / H), 0), gx - 1)
            var b = min(max(Int(q[1] / H), 0), gy - 1)
            var c = min(max(Int(q[2] / H), 0), gz - 1)
            cell[k] = (c * gy + b) * gx + a
            start[cell[k] + 1] += 1
        for i in range(gx * gy * gz):
            start[i + 1] += start[i]
        var fill = start.copy()
        var items = List[Int](length=n, fill=0)
        for k in range(n):
            items[fill[cell[k]]] = k
            fill[cell[k]] += 1
        var out = List[List[Int]]()
        var h2 = H * H
        for k in range(n):
            var nb = List[Int]()
            var ck = cell[k]
            var a0 = ck % gx
            var b0 = (ck // gx) % gy
            var c0 = ck // (gx * gy)
            for c in range(max(c0 - 1, 0), min(c0 + 2, gz)):
                for b in range(max(b0 - 1, 0), min(b0 + 2, gy)):
                    for a in range(max(a0 - 1, 0), min(a0 + 2, gx)):
                        var cc = (c * gy + b) * gx + a
                        for t in range(start[cc], start[cc + 1]):
                            var j = items[t]
                            if j == k:
                                continue
                            var d = self.p[k] - self.p[j]
                            if d[0] * d[0] + d[1] * d[1] + d[2] * d[2] < h2:
                                nb.append(j)
            out.append(nb^)
        return out^

    def step(mut self, dt: Real, gravity: Vec3, iters: Int):
        var n = len(self.x)
        for k in range(n):
            self.v[k] = self.v[k] + gravity * dt
            self.p[k] = self.x[k] + self.v[k] * dt
            self._clamp(k)
        for b in range(len(self.body_first)):
            self._shape_match(b)
        var nbs = self._neighbours()
        var corr = List[Vec3](length=n, fill=Vec3(0, 0, 0, 0))
        for _ in range(iters):
            # lambda per fluid particle, gradients weighted by inverse mass
            for i in range(n):
                if self.body[i] >= 0:
                    self.lam[i] = 0
                    continue
                var rho = poly6(0)
                var gi = Vec3(0, 0, 0, 0)
                var s2 = Real(0)
                for j in nbs[i]:
                    var d = self.p[i] - self.p[j]
                    var r = sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2])
                    rho += poly6(r * r)
                    if r <= 1e-9:
                        continue
                    var g = d * (spiky_grad(r) / (self.rho0 * r))
                    s2 += self.w[j] * (g[0] * g[0] + g[1] * g[1] + g[2] * g[2])
                    gi = gi - g
                s2 += self.w[i] * (gi[0] * gi[0] + gi[1] * gi[1] + gi[2] * gi[2])
                var c = rho / self.rho0 - 1
                self.lam[i] = -max(c, 0) / (s2 + _EPS)
            for k in range(n):
                corr[k] = Vec3(0, 0, 0, 0)
            for i in range(n):
                if self.body[i] >= 0:
                    continue
                for j in nbs[i]:
                    var d = self.p[i] - self.p[j]
                    var r = sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2])
                    if r <= 1e-9:
                        continue
                    var g = d * (spiky_grad(r) / (self.rho0 * r))
                    if self.body[j] < 0:
                        # fluid pair: PBF's symmetric (lambda_i + lambda_j) form
                        corr[i] = corr[i] + g * ((self.lam[i] + self.lam[j]) * self.w[i])
                    else:
                        # fluid i - solid j: i's constraint moves both
                        corr[i] = corr[i] + g * (self.lam[i] * self.w[i])
                        corr[j] = corr[j] - g * (self.lam[i] * self.w[j])
            for k in range(n):
                var c = corr[k]
                var l = sqrt(c[0] * c[0] + c[1] * c[1] + c[2] * c[2])
                if l > _MAX_CORR * H:
                    c = c * (_MAX_CORR * H / l)
                self.p[k] = self.p[k] + c
                self._clamp(k)
            for b in range(len(self.body_first)):
                self._shape_match(b)
        for k in range(n):
            self.v[k] = (self.p[k] - self.x[k]) / dt
            self.x[k] = self.p[k]
