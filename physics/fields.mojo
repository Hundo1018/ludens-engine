"""Force fields and water volumes (ROADMAP 17.27 / 17.28).

Region effects applied to a `ContactScene6` once per frame, before its step,
as impulses at the body centre (force x dt) -- first order in the frame,
which is what every engine these are compared against does. A sleeping
body inside a field that pushes it is woken.

Force fields (`ForceField`):
  GRAVITY  inside an AABB, gravity becomes `vec` for the next step (a
           per-body override the solver applies every substep: zero-g
           rooms, walls you can walk on)
  RADIAL   push (strength > 0) or pull from `center`, falling off linearly
           to zero at `radius` (explosions, attractors)
  WIND     inside an AABB, drag toward the wind velocity: F = k (w - v);
           w is `vec`, or sampled from a `WindGrid` (e.g. filled from the
           LBM wind tunnel's velocity field) -- a grid holding one constant
           velocity everywhere gives exactly the constant field
  DRAG     inside an AABB, linear damping F = -k m v

Water (`WaterVolume`): an AABB whose top face is the surface. Buoyancy is
fluid density x g x submerged volume, applied at the centre of buoyancy
(the submerged centroid, so a tilted box rights itself), plus linear and
angular damping scaled by the submerged fraction. Submerged volume:
  sphere   exact spherical cap
  box      `samples`^3 midpoint integration over the box (any rotation);
           for an axis-aligned box `box_submerged_exact` is the closed form
           (the seam: they agree to the sampling error)
  others   not submerged (hull / mesh / capsule: not implemented)
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot
from collision.collider_set import SHAPE_BOX, SHAPE_SPHERE
from .rigid6 import Body6
from .solver6 import ContactScene6

comptime FIELD_GRAVITY = 0
comptime FIELD_RADIAL = 1
comptime FIELD_WIND = 2
comptime FIELD_DRAG = 3

comptime _PI: Real = 3.14159265358979


@fieldwise_init
struct ForceField(Copyable, ImplicitlyCopyable, Movable):
    var kind: Int
    var lo: Vec3  # region AABB (GRAVITY / WIND / DRAG)
    var hi: Vec3
    var center: Vec3  # RADIAL
    var radius: Real  # RADIAL
    var vec: Vec3  # GRAVITY: gravity inside; WIND: wind velocity
    var strength: Real  # RADIAL: force at the centre; WIND/DRAG: k
    var grid: Int  # WIND: index into the grids passed to apply (-1 = `vec`)

    @staticmethod
    def gravity_zone(lo: Vec3, hi: Vec3, g: Vec3) -> Self:
        return Self(FIELD_GRAVITY, lo, hi, Vec3(0, 0, 0, 0), 0, g, 0, -1)

    @staticmethod
    def radial(center: Vec3, radius: Real, strength: Real) -> Self:
        var z = Vec3(0, 0, 0, 0)
        return Self(FIELD_RADIAL, z, z, center, radius, z, strength, -1)

    @staticmethod
    def wind(lo: Vec3, hi: Vec3, w: Vec3, k: Real, grid: Int = -1) -> Self:
        return Self(FIELD_WIND, lo, hi, Vec3(0, 0, 0, 0), 0, w, k, grid)

    @staticmethod
    def drag(lo: Vec3, hi: Vec3, k: Real) -> Self:
        var z = Vec3(0, 0, 0, 0)
        return Self(FIELD_DRAG, lo, hi, z, 0, z, k, -1)


struct WindGrid(Copyable, Movable):
    """A uniform grid of velocities, sampled trilinearly (clamped at the
    edges). `nx*ny*nz` cells of size `cell` from `origin`."""

    var nx: Int
    var ny: Int
    var nz: Int
    var origin: Vec3
    var cell: Real
    var vel: List[Vec3]

    def __init__(out self, nx: Int, ny: Int, nz: Int, origin: Vec3, cell: Real, fill: Vec3):
        self.nx = nx
        self.ny = ny
        self.nz = nz
        self.origin = origin
        self.cell = cell
        self.vel = List[Vec3](length=nx * ny * nz, fill=fill)

    def at(self, i: Int, j: Int, k: Int) -> Vec3:
        return self.vel[(k * self.ny + j) * self.nx + i]

    def sample(self, p: Vec3) -> Vec3:
        var f = (p - self.origin) * (1 / self.cell)
        var i0 = min(max(Int(f[0]), 0), self.nx - 1)
        var j0 = min(max(Int(f[1]), 0), self.ny - 1)
        var k0 = min(max(Int(f[2]), 0), self.nz - 1)
        var i1 = min(i0 + 1, self.nx - 1)
        var j1 = min(j0 + 1, self.ny - 1)
        var k1 = min(k0 + 1, self.nz - 1)
        var tx = min(max(f[0] - Real(i0), Real(0)), Real(1))
        var ty = min(max(f[1] - Real(j0), Real(0)), Real(1))
        var tz = min(max(f[2] - Real(k0), Real(0)), Real(1))
        var c00 = self.at(i0, j0, k0) * (1 - tx) + self.at(i1, j0, k0) * tx
        var c10 = self.at(i0, j1, k0) * (1 - tx) + self.at(i1, j1, k0) * tx
        var c01 = self.at(i0, j0, k1) * (1 - tx) + self.at(i1, j0, k1) * tx
        var c11 = self.at(i0, j1, k1) * (1 - tx) + self.at(i1, j1, k1) * tx
        var c0 = c00 * (1 - ty) + c10 * ty
        var c1 = c01 * (1 - ty) + c11 * ty
        return c0 * (1 - tz) + c1 * tz


def _inside(p: Vec3, lo: Vec3, hi: Vec3) -> Bool:
    return (
        p[0] >= lo[0] and p[0] <= hi[0]
        and p[1] >= lo[1] and p[1] <= hi[1]
        and p[2] >= lo[2] and p[2] <= hi[2]
    )


def apply_fields[B: Body6](
    mut sc: ContactScene6[B],
    fields: List[ForceField],
    grids: List[WindGrid],
    gravity: Vec3,
    dt: Real,
) raises:
    """Add each field's impulse (force x dt) to every dynamic body it
    reaches; `gravity` is the global gravity the next step will apply.
    Gravity zones are not impulses: they set the body's gravity override
    (`BodySet.grav`), which the solver applies every substep -- an impulse
    cancelling gravity at the start of the frame would leave a drift of
    g·dt²/2 per frame."""
    var any_zone = False
    for k in range(len(fields)):
        if fields[k].kind == FIELD_GRAVITY:
            any_zone = True
    if any_zone or sc.bset.any_grav:
        sc.bset.any_grav = any_zone
        for i in range(len(sc.bset.bodies)):
            sc.bset.grav_on[i] = False
    for i in range(len(sc.bset.bodies)):
        if not sc.bset.is_dynamic(i):
            continue
        var p = sc.bset.bodies[i].position()
        var m = 1 / sc.bset.bodies[i].inv_mass()
        var f = Vec3(0, 0, 0, 0)
        for k in range(len(fields)):
            ref fd = fields[k]
            if fd.kind == FIELD_RADIAL:
                var d = p - fd.center
                var dist = sqrt(dot(d, d))
                if dist < fd.radius and dist > 1e-9:
                    f = f + d * (fd.strength * (1 - dist / fd.radius) / dist)
                continue
            if not _inside(p, fd.lo, fd.hi):
                continue
            if fd.kind == FIELD_GRAVITY:
                sc.bset.grav_on[i] = True
                sc.bset.grav[i] = fd.vec
            elif fd.kind == FIELD_WIND:
                var w = fd.vec if fd.grid < 0 else grids[fd.grid].sample(p)
                f = f + (w - sc.bset.bodies[i].linear_velocity()) * fd.strength
            elif fd.kind == FIELD_DRAG:
                f = f - sc.bset.bodies[i].linear_velocity() * (fd.strength * m)
        if f[0] == 0 and f[1] == 0 and f[2] == 0:
            continue
        if sc.bset.sleeping[i]:
            sc.wake(sc.bset.id_of(i))
        sc.bset.bodies[i].apply_impulse(f * dt, p)


# -------------------------------------------------------------------- water


@fieldwise_init
struct WaterVolume(Copyable, ImplicitlyCopyable, Movable):
    var lo: Vec3
    var hi: Vec3  # hi[1] is the surface
    var density: Real
    var lin_drag: Real  # 1/s, scaled by the submerged fraction
    var ang_drag: Real


def sphere_submerged(c: Vec3, r: Real, surface: Real) -> Tuple[Real, Vec3]:
    """(volume, centroid) of the part of a sphere below `surface`."""
    var h = min(max(surface - (c[1] - r), Real(0)), 2 * r)
    if h <= 0:
        return (Real(0), c)
    var v = _PI * h * h * (3 * r - h) / 3
    # centroid of a cap of height h, measured from the sphere centre
    # (below the centre is negative): -3(2r - h)^2 / (4(3r - h))
    var z = -3 * (2 * r - h) * (2 * r - h) / (4 * (3 * r - h))
    return (v, Vec3(c[0], c[1] + z, c[2], 0))


def box_submerged_exact(c: Vec3, half: Vec3, surface: Real) -> Tuple[Real, Vec3]:
    """Closed form for an AXIS-ALIGNED box."""
    var bottom = c[1] - half[1]
    var h = min(max(surface - bottom, Real(0)), 2 * half[1])
    var v = 4 * half[0] * half[2] * h
    return (v, Vec3(c[0], bottom + h / 2, c[2], 0))


def box_submerged_sampled[B: Body6](
    body: B, half: Vec3, surface: Real, samples: Int
) -> Tuple[Real, Vec3]:
    """Midpoint integration over `samples`^3 cells of the (rotated) box."""
    var n = samples
    var cell_v = 8 * half[0] * half[1] * half[2] / Real(n * n * n)
    var v = Real(0)
    var acc = Vec3(0, 0, 0, 0)
    for i in range(n):
        for j in range(n):
            for k in range(n):
                var lp = Vec3(
                    (Real(2 * i + 1) / Real(n) - 1) * half[0],
                    (Real(2 * j + 1) / Real(n) - 1) * half[1],
                    (Real(2 * k + 1) / Real(n) - 1) * half[2],
                    0,
                )
                var wp = body.act(lp)
                if wp[1] < surface:
                    v += cell_v
                    acc = acc + wp * cell_v
    if v <= 0:
        return (Real(0), body.position())
    return (v, acc * (1 / v))


def apply_buoyancy[B: Body6](
    mut sc: ContactScene6[B],
    waters: List[WaterVolume],
    gravity: Vec3,
    dt: Real,
    samples: Int = 8,
) raises:
    """Buoyancy + submerged damping for every dynamic box / sphere whose
    centre is inside a water volume's horizontal footprint."""
    for i in range(len(sc.bset.bodies)):
        if not sc.bset.is_dynamic(i):
            continue
        var kind = sc.colliders.shape[i]
        if kind != SHAPE_BOX and kind != SHAPE_SPHERE:
            continue
        var p = sc.bset.bodies[i].position()
        var half = sc.colliders.half[i]
        for w in range(len(waters)):
            ref wv = waters[w]
            if p[0] < wv.lo[0] or p[0] > wv.hi[0] or p[2] < wv.lo[2] or p[2] > wv.hi[2]:
                continue
            var sub: Tuple[Real, Vec3]
            var total: Real
            if kind == SHAPE_SPHERE:
                sub = sphere_submerged(p, half[0], wv.hi[1])
                total = 4 * _PI * half[0] * half[0] * half[0] / 3
            else:
                sub = box_submerged_sampled(sc.bset.bodies[i], half, wv.hi[1], samples)
                total = 8 * half[0] * half[1] * half[2]
            if sub[0] <= 0:
                continue
            if sc.bset.sleeping[i]:
                sc.wake(sc.bset.id_of(i))
            var frac = sub[0] / total
            var fb = gravity * (-wv.density * sub[0])
            sc.bset.bodies[i].apply_impulse(fb * dt, sub[1])
            # implicit damping, v / (1 + c dt): unconditionally stable, so
            # a stiff float (buoyancy is a spring of rho g A) still settles
            var v = sc.bset.bodies[i].linear_velocity()
            var om = sc.bset.bodies[i].omega_world()
            sc.bset.bodies[i].set_velocity(
                v * (1 / (1 + wv.lin_drag * frac * dt)),
                om * (1 / (1 + wv.ang_drag * frac * dt)),
            )
