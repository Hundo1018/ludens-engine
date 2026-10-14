"""Water surfaces and floating bodies on them (ROADMAP 17.60).

`fields.WaterVolume` is a flat AABB of water. A boat on a sea needs the
surface height where each of its hull points is, at the current time. The
`WaterSurface` trait is that query, chosen at compile time:

  * `FlatWater`: a constant level.
  * `GerstnerWater`: a sum of Gerstner (trochoidal) waves with deep-water
    dispersion w^2 = g k. Closed form in t: any time can be queried
    directly, with no stepping (rollback and replay friendly). Gerstner
    points move horizontally (steepness Q), so the height above a fixed
    (x, z) needs the inverse map; `height` does 4 fixed-point iterations.
    With all amplitudes 0 it returns the level bit for bit; with Q = 0 a
    single wave is exactly A cos(k . x - w t + phase).
  * `ShallowWaterGrid`: an interactive ripple field, the linear shallow-water
    (wave) equation eta_tt = g H lap(eta) on a grid, explicit leapfrog with
    damping; `disturb` pushes the surface, `step` advances it. Its `height`
    ignores t (it is the current state).

`float_body` applies buoyancy by sampling the body's box at n^3 points: each
point below the local surface pushes up with rho g dV at that point (so the
torque follows), plus a drag on the velocity relative to the water.
"""

from std.math import sqrt, sin, cos, pi
from geometry.vec import Real, Vec3
from .body_set import BodyId
from .rigid6 import Body6
from .solver6 import ContactScene6


trait WaterSurface:
    def height(self, x: Real, z: Real, t: Real) -> Real: ...

    def velocity(self, x: Real, z: Real, t: Real) -> Vec3: ...


@fieldwise_init
struct FlatWater(WaterSurface, Copyable, Movable):
    var level: Real

    def height(self, x: Real, z: Real, t: Real) -> Real:
        return self.level

    def velocity(self, x: Real, z: Real, t: Real) -> Vec3:
        return Vec3(0, 0, 0, 0)


@fieldwise_init
struct GerstnerWave(Copyable, ImplicitlyCopyable, Movable):
    var dir_x: Real  # unit horizontal direction
    var dir_z: Real
    var amplitude: Real
    var wavelength: Real
    var steepness: Real  # Q in [0, 1]; 0 = plain sine
    var phase: Real


struct GerstnerWater(WaterSurface, Copyable, Movable):
    var level: Real
    var gravity: Real
    var waves: List[GerstnerWave]

    def __init__(out self, level: Real, gravity: Real = 9.8):
        self.level = level
        self.gravity = gravity
        self.waves = List[GerstnerWave]()

    def add(mut self, dir_x: Real, dir_z: Real, amplitude: Real, wavelength: Real, steepness: Real = 0, phase: Real = 0):
        var l = sqrt(dir_x * dir_x + dir_z * dir_z)
        self.waves.append(GerstnerWave(dir_x / l, dir_z / l, amplitude, wavelength, steepness, phase))

    def omega(self, w: Int) -> Real:
        var k = 2 * Real(pi) / self.waves[w].wavelength
        return sqrt(self.gravity * k)

    def _displace(self, x0: Real, z0: Real, t: Real) -> Vec3:
        """Where the surface point with rest position (x0, z0) is at t."""
        var x = x0
        var z = z0
        var y = self.level
        for w in range(len(self.waves)):
            ref wv = self.waves[w]
            var k = 2 * Real(pi) / wv.wavelength
            var th = k * (wv.dir_x * x0 + wv.dir_z * z0) - self.omega(w) * t + wv.phase
            var c = cos(th)
            y += wv.amplitude * c
            # horizontal displacement -Q A d sin(th): points crowd at crests
            x -= wv.steepness * wv.amplitude * wv.dir_x * sin(th)
            z -= wv.steepness * wv.amplitude * wv.dir_z * sin(th)
        return Vec3(x, y, z, 0)

    def height(self, x: Real, z: Real, t: Real) -> Real:
        # invert the horizontal map: find the rest position whose displaced
        # point lands on (x, z)
        var x0 = x
        var z0 = z
        for _ in range(4):
            var p = self._displace(x0, z0, t)
            x0 -= p[0] - x
            z0 -= p[2] - z
        return self._displace(x0, z0, t)[1]

    def velocity(self, x: Real, z: Real, t: Real) -> Vec3:
        """Surface particle velocity (d/dt of the displacement) at (x, z)."""
        var h = Real(1e-3)
        var a = self._displace(x, z, t - h)
        var b = self._displace(x, z, t + h)
        return (b - a) * (1 / (2 * h))


struct ShallowWaterGrid(WaterSurface, Movable):
    var nx: Int
    var nz: Int
    var cell: Real
    var origin_x: Real
    var origin_z: Real
    var level: Real
    var depth: Real  # mean depth H
    var gravity: Real
    var damping: Real  # 1/s
    var eta: List[Real]  # surface elevation above `level`
    var prev: List[Real]

    def __init__(out self, nx: Int, nz: Int, cell: Real, origin_x: Real, origin_z: Real, level: Real, depth: Real, gravity: Real = 9.8, damping: Real = 0.0) raises:
        if nx < 3 or nz < 3 or cell <= 0 or depth <= 0:
            raise Error("ShallowWaterGrid: need >= 3 x 3 cells, cell > 0, depth > 0")
        self.nx = nx
        self.nz = nz
        self.cell = cell
        self.origin_x = origin_x
        self.origin_z = origin_z
        self.level = level
        self.depth = depth
        self.gravity = gravity
        self.damping = damping
        self.eta = List[Real](length=nx * nz, fill=0)
        self.prev = List[Real](length=nx * nz, fill=0)

    def wave_speed(self) -> Real:
        return sqrt(self.gravity * self.depth)

    def max_dt(self) -> Real:
        """CFL limit of the 5-point leapfrog: c dt / dx <= 1 / sqrt(2)."""
        return self.cell / (self.wave_speed() * sqrt(Real(2)))

    def disturb(mut self, x: Real, z: Real, radius: Real, amount: Real):
        """Raise (or lower) the surface by `amount` with a cosine bump."""
        for j in range(self.nz):
            for i in range(self.nx):
                var dx = self.origin_x + Real(i) * self.cell - x
                var dz = self.origin_z + Real(j) * self.cell - z
                var d = sqrt(dx * dx + dz * dz)
                if d < radius:
                    var b = amount * 0.5 * (1 + cos(Real(pi) * d / radius))
                    self.eta[j * self.nx + i] += b
                    self.prev[j * self.nx + i] += b

    def step(mut self, dt: Real) raises:
        if dt > self.max_dt():
            raise Error("ShallowWaterGrid.step: dt above the CFL limit " + String(self.max_dt()))
        var c2 = self.gravity * self.depth * dt * dt / (self.cell * self.cell)
        var d = self.damping * dt
        var nxt = List[Real](length=self.nx * self.nz, fill=0)
        for j in range(self.nz):
            for i in range(self.nx):
                var k = j * self.nx + i
                # reflecting walls: mirror the missing neighbour
                var l = self.eta[k - 1] if i > 0 else self.eta[k + 1]
                var r = self.eta[k + 1] if i < self.nx - 1 else self.eta[k - 1]
                var u = self.eta[k - self.nx] if j > 0 else self.eta[k + self.nx]
                var w = self.eta[k + self.nx] if j < self.nz - 1 else self.eta[k - self.nx]
                var lap = l + r + u + w - 4 * self.eta[k]
                nxt[k] = ((2 - d) * self.eta[k] - (1 - d) * self.prev[k] + c2 * lap)
        self.prev = self.eta^
        self.eta = nxt^

    def _sample(self, f: List[Real], x: Real, z: Real) -> Real:
        var fx = (x - self.origin_x) / self.cell
        var fz = (z - self.origin_z) / self.cell
        var i0 = min(max(Int(fx), 0), self.nx - 2)
        var j0 = min(max(Int(fz), 0), self.nz - 2)
        var tx = min(max(fx - Real(i0), Real(0)), Real(1))
        var tz = min(max(fz - Real(j0), Real(0)), Real(1))
        var a = f[j0 * self.nx + i0] * (1 - tx) + f[j0 * self.nx + i0 + 1] * tx
        var b = f[(j0 + 1) * self.nx + i0] * (1 - tx) + f[(j0 + 1) * self.nx + i0 + 1] * tx
        return a * (1 - tz) + b * tz

    def height(self, x: Real, z: Real, t: Real) -> Real:
        return self.level + self._sample(self.eta, x, z)

    def velocity(self, x: Real, z: Real, t: Real) -> Vec3:
        return Vec3(0, 0, 0, 0)  # vertical rate only would need dt; not tracked

    def energy(self) -> Real:
        """Potential energy proxy sum(eta^2) (decays with damping)."""
        var e = Real(0)
        for v in self.eta:
            e += v * v
        return e


def float_body[W: WaterSurface, B: Body6](
    mut sc: ContactScene6[B], id: BodyId, half: Vec3, water: W, t: Real,
    density: Real, gravity: Vec3, drag: Real = 1.0, samples: Int = 4,
) raises -> Real:
    """Buoyancy and drag on a box-shaped body (half extents `half`) from
    `water` at time t, accumulated as forces for the next step. Returns the
    submerged volume."""
    var pose = sc.pose(id)
    var v = sc.velocity(id)
    var om = sc.angular_velocity(id)
    var n = samples
    var dv = 8 * half[0] * half[1] * half[2] / Real(n * n * n)
    var sub = Real(0)
    for i in range(n):
        for j in range(n):
            for k in range(n):
                var lp = Vec3(
                    (Real(2 * i + 1) / Real(n) - 1) * half[0],
                    (Real(2 * j + 1) / Real(n) - 1) * half[1],
                    (Real(2 * k + 1) / Real(n) - 1) * half[2],
                    0,
                )
                var wp = pose.pos + pose.rot.rotate(lp)
                if wp[1] >= water.height(wp[0], wp[2], t):
                    continue
                sub += dv
                var fb = gravity * (-density * dv)
                var pv = v + _cross(om, wp - pose.pos)
                var rel = water.velocity(wp[0], wp[2], t) - pv
                sc.add_force_at(id, fb + rel * (drag * density * dv), wp)
    return sub


def _cross(a: Vec3, b: Vec3) -> Vec3:
    return Vec3(a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0], 0)
