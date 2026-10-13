"""Camera math for the simulation side (ROADMAP 17.68).

  * `CameraPose`: position, orientation (looking down local -z, y up), field
    of view, aspect, near / far -- the value a host reads each frame.
  * `perspective` / `ortho`: reference projection matrices (right-handed,
    column vectors, clip z in [-1, 1], the OpenGL convention), so host and
    simulation agree on what "in view" means.
  * `Frustum`: the six inward planes of a camera; sphere and AABB tests for
    simulation queries (AI sight cones, observer sets) -- render culling is
    the host's.
  * `spring_damp`: a critically damped spring with a half-life (Holden's
    form), exact for any dt; `spring_damp_quat` springs an orientation along
    the shortest arc.
  * `Shake`: trauma-based camera shake (Eiserloh, GDC 2016): trauma decays
    linearly, the offset is trauma^2 x max x seeded noise of time, so the same
    seed and time give the same shake.
"""

from std.math import sqrt, tan, exp, acos, sin
from geometry.vec import Real, Vec3, dot, cross, length
from geometry.quat import Quat, slerp
from geometry.mat import Mat4
from .noise import perlin2


@fieldwise_init
struct CameraPose(Copyable, ImplicitlyCopyable, Movable):
    var position: Vec3
    var rotation: Quat
    var fov_y: Real  # radians
    var aspect: Real
    var near: Real
    var far: Real

    def forward(self) -> Vec3:
        return self.rotation.rotate(Vec3(0, 0, -1, 0))

    def up(self) -> Vec3:
        return self.rotation.rotate(Vec3(0, 1, 0, 0))

    def right(self) -> Vec3:
        return self.rotation.rotate(Vec3(1, 0, 0, 0))


def look_rotation(forward: Vec3, up_hint: Vec3) -> Quat:
    """Orientation whose -z axis is `forward`. When `forward` is parallel to
    `up_hint` (looking straight up or down) a fallback up of +z is used, so
    the result never degenerates."""
    var f = forward / max(length(forward), Real(1e-12))
    var r = cross(f, up_hint)
    if length(r) < 1e-6:
        r = cross(f, Vec3(0, 0, 1, 0))
    r = r / length(r)
    var u = cross(r, f)
    # rotation matrix with columns r, u, -f -> quaternion
    var m00 = r[0]
    var m11 = u[1]
    var m22 = -f[2]
    var tr = m00 + m11 + m22
    var q: Quat
    if tr > 0:
        var s = sqrt(tr + 1) * 2
        q = Quat((u[2] - (-f[1])) / s, ((-f[0]) - r[2]) / s, (r[1] - u[0]) / s, 0.25 * s)
    elif m00 > m11 and m00 > m22:
        var s = sqrt(1 + m00 - m11 - m22) * 2
        q = Quat(0.25 * s, (u[0] + r[1]) / s, ((-f[0]) + r[2]) / s, (u[2] - (-f[1])) / s)
    elif m11 > m22:
        var s = sqrt(1 + m11 - m00 - m22) * 2
        q = Quat((u[0] + r[1]) / s, 0.25 * s, ((-f[1]) + u[2]) / s, ((-f[0]) - r[2]) / s)
    else:
        var s = sqrt(1 + m22 - m00 - m11) * 2
        q = Quat(((-f[0]) + r[2]) / s, ((-f[1]) + u[2]) / s, 0.25 * s, (r[1] - u[0]) / s)
    return q.normalized()


def perspective(fov_y: Real, aspect: Real, near: Real, far: Real) -> Mat4:
    var f = 1 / tan(fov_y / 2)
    var m = Mat4()
    m.set(0, 0, f / aspect)
    m.set(1, 1, f)
    m.set(2, 2, (far + near) / (near - far))
    m.set(2, 3, 2 * far * near / (near - far))
    m.set(3, 2, -1)
    return m^


def ortho(half_w: Real, half_h: Real, near: Real, far: Real) -> Mat4:
    var m = Mat4()
    m.set(0, 0, 1 / half_w)
    m.set(1, 1, 1 / half_h)
    m.set(2, 2, -2 / (far - near))
    m.set(2, 3, -(far + near) / (far - near))
    m.set(3, 3, 1)
    return m^


@fieldwise_init
struct Plane(Copyable, ImplicitlyCopyable, Movable):
    var n: Vec3  # unit, pointing into the frustum
    var d: Real  # dot(n, p) + d >= 0 inside


struct Frustum(Copyable, Movable):
    var planes: List[Plane]

    def __init__(out self, cam: CameraPose):
        var f = cam.forward()
        var u = cam.up()
        var r = cam.right()
        var p = cam.position
        var th = tan(cam.fov_y / 2)
        var tw = th * cam.aspect
        self.planes = List[Plane]()
        self.planes.append(Plane(f, -dot(f, p + f * cam.near)))  # near
        self.planes.append(Plane(-f, dot(f, p + f * cam.far)))  # far
        # side planes pass through the eye
        # (camera basis: r x u = -f) each normal points into the frustum
        var nl = cross(f - r * tw, u)  # left edge -> normal toward +r
        var nr = cross(u, f + r * tw)  # right edge -> toward -r
        var nt = cross(f + u * th, r)  # top edge -> toward -u
        var nb = cross(r, f - u * th)  # bottom edge -> toward +u
        for n0 in [nl, nr, nt, nb]:
            var n = n0 / length(n0)
            self.planes.append(Plane(n, -dot(n, p)))

    def sphere_visible(self, c: Vec3, radius: Real) -> Bool:
        for pl in self.planes:
            if dot(pl.n, c) + pl.d < -radius:
                return False
        return True

    def aabb_visible(self, lo: Vec3, hi: Vec3) -> Bool:
        """Conservative: False only when the box is wholly outside one
        plane (the positive-vertex test)."""
        for pl in self.planes:
            var px = hi[0] if pl.n[0] >= 0 else lo[0]
            var py = hi[1] if pl.n[1] >= 0 else lo[1]
            var pz = hi[2] if pl.n[2] >= 0 else lo[2]
            if dot(pl.n, Vec3(px, py, pz, 0)) + pl.d < 0:
                return False
        return True


def spring_damp(x: Vec3, v: Vec3, target: Vec3, half_life: Real, dt: Real) -> Tuple[Vec3, Vec3]:
    """Critically damped spring toward `target` (exact solution, any dt);
    returns (position, velocity). `half_life` is the time to halve the gap."""
    var y = 4 * 0.69314718 / max(half_life, Real(1e-6)) / 2
    var j0 = x - target
    var j1 = v + j0 * y
    var e = exp(-y * dt)
    return (target + (j0 + j1 * dt) * e, (v - j1 * (y * dt)) * e)


def spring_damp_quat(q: Quat, target: Quat, half_life: Real, dt: Real) -> Quat:
    """Move `q` toward `target` along the shortest arc by the fraction a
    critically damped spring (starting at rest) closes in `dt`."""
    var y = 4 * 0.69314718 / max(half_life, Real(1e-6)) / 2
    var closed = 1 - (1 + y * dt) * exp(-y * dt)
    var t = target
    if q.x * t.x + q.y * t.y + q.z * t.z + q.w * t.w < 0:
        t = Quat(-t.x, -t.y, -t.z, -t.w)
    return slerp(q, t, closed).normalized()


struct Shake(Copyable, Movable):
    var trauma: Real
    var decay: Real  # trauma lost per second
    var max_offset: Real  # metres at trauma 1
    var max_angle: Real  # radians at trauma 1
    var freq: Real  # noise samples per second
    var seed: Int

    def __init__(out self, seed: Int, max_offset: Real = 0.3, max_angle: Real = 0.1, decay: Real = 1, freq: Real = 15):
        self.trauma = 0
        self.decay = decay
        self.max_offset = max_offset
        self.max_angle = max_angle
        self.freq = freq
        self.seed = seed

    def add(mut self, amount: Real):
        self.trauma = min(Real(1), max(Real(0), self.trauma + amount))

    def advance(mut self, dt: Real):
        self.trauma = max(Real(0), self.trauma - self.decay * dt)

    def offset(self, t: Real) -> Tuple[Vec3, Vec3]:
        """(translation, small rotation angles about x / y / z) at time t."""
        var s = self.trauma * self.trauma
        var u = t * self.freq
        var p = Vec3(perlin2(u, 0.5, self.seed), perlin2(u, 1.5, self.seed), perlin2(u, 2.5, self.seed), 0) * (s * self.max_offset)
        var a = Vec3(perlin2(u, 3.5, self.seed), perlin2(u, 4.5, self.seed), perlin2(u, 5.5, self.seed), 0) * (s * self.max_angle)
        return (p, a)
