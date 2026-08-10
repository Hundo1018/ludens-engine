"""3D signed distance fields, and contact between them.

The engine's existing `sdf.mojo` is 2D — `Vec2` throughout — so it cannot be
wired into the 3D solver at all; this is the 3D layer, not a port of a working
one. Worth stating because the roadmap assumed the opposite.

What an SDF buys over the analytic pairs already here is that the number of
contacts stops depending on how a shape is tessellated: a procedurally
sculpted or CSG-composed geometry answers the same query as a primitive, with
no mesh in between. What it costs is that the contact is FOUND rather than
derived — a gradient descent on the maximum of the two fields — so it is
iterative where `sphere_sphere_manifold` is a closed form.

Primitives are exact SDFs (sphere, box, plane, capsule); CSG combines them
with min/max, which makes union and intersection only *bounds* on the true
distance rather than the distance itself. That is the standard caveat and it
matters here: the descent still converges, but its step size is conservative
near a CSG seam, so `sdf_contact` takes more iterations there. The tests
exercise a CSG shape for exactly that reason.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, length, dot, normalize

comptime KIND_SPHERE = 0
comptime KIND_BOX = 1
comptime KIND_PLANE = 2
comptime KIND_CAPSULE = 3

comptime OP_NONE = 0
comptime OP_UNION = 1
comptime OP_INTERSECT = 2
comptime OP_SUBTRACT = 3


@fieldwise_init
struct Sdf3(Copyable, ImplicitlyCopyable, Movable):
    """One primitive, optionally combined with a second by a CSG operator.

    Deliberately two-deep rather than a general tree: a tree needs heap
    indirection per node, and the point of this layer is to be measurable
    against the analytic pairs, not to be a modelling language. Depth two is
    enough to build the cases that distinguish SDF behaviour from primitives
    (a box with a sphere bitten out, a capped intersection)."""

    var kind: Int
    var center: Vec3
    var extent: Vec3  # sphere: (r,-,-) | box: half | plane: normal | capsule: (r, halfy, -)
    var d: Real  # plane offset
    var op: Int
    var kind2: Int
    var center2: Vec3
    var extent2: Vec3
    var d2: Real

    @staticmethod
    def sphere(c: Vec3, r: Real) -> Self:
        return Self(
            KIND_SPHERE, c, Vec3(r, 0, 0), 0,
            OP_NONE, 0, Vec3(0, 0, 0), Vec3(0, 0, 0), 0,
        )

    @staticmethod
    def box(c: Vec3, half: Vec3) -> Self:
        return Self(
            KIND_BOX, c, half, 0,
            OP_NONE, 0, Vec3(0, 0, 0), Vec3(0, 0, 0), 0,
        )

    @staticmethod
    def plane(n: Vec3, d: Real) -> Self:
        return Self(
            KIND_PLANE, Vec3(0, 0, 0), normalize(n), d,
            OP_NONE, 0, Vec3(0, 0, 0), Vec3(0, 0, 0), 0,
        )

    @staticmethod
    def capsule(c: Vec3, r: Real, half_y: Real) -> Self:
        return Self(
            KIND_CAPSULE, c, Vec3(r, half_y, 0), 0,
            OP_NONE, 0, Vec3(0, 0, 0), Vec3(0, 0, 0), 0,
        )

    def combined(self, op: Int, o: Self) -> Self:
        """CSG with a second primitive (the second shape's own `op` is ignored)."""
        return Self(
            self.kind, self.center, self.extent, self.d,
            op, o.kind, o.center, o.extent, o.d,
        )

    @staticmethod
    def _prim(kind: Int, c: Vec3, e: Vec3, d: Real, p: Vec3) -> Real:
        if kind == KIND_SPHERE:
            return length(p - c) - e[0]
        if kind == KIND_PLANE:
            return dot(p, c if False else e) - d  # e holds the unit normal
        if kind == KIND_CAPSULE:
            # segment along local Y through `c`, half-length e[1], radius e[0]
            var q = p - c
            var ty = q[1]
            if ty > e[1]:
                ty = e[1]
            if ty < -e[1]:
                ty = -e[1]
            return length(q - Vec3(0, ty, 0)) - e[0]
        # box
        var q = p - c
        var dx = abs(q[0]) - e[0]
        var dy = abs(q[1]) - e[1]
        var dz = abs(q[2]) - e[2]
        var ox = dx if dx > 0 else Real(0)
        var oy = dy if dy > 0 else Real(0)
        var oz = dz if dz > 0 else Real(0)
        var outside = sqrt(ox * ox + oy * oy + oz * oz)
        var mx = dx if dx > dy else dy
        if dz > mx:
            mx = dz
        var inside = mx if mx < 0 else Real(0)
        return outside + inside

    def distance(self, p: Vec3) -> Real:
        var a = Self._prim(self.kind, self.center, self.extent, self.d, p)
        if self.op == OP_NONE:
            return a
        var b = Self._prim(self.kind2, self.center2, self.extent2, self.d2, p)
        if self.op == OP_UNION:
            return a if a < b else b
        if self.op == OP_INTERSECT:
            return a if a > b else b
        # subtract: a \ b  ==  intersect(a, complement(b))
        var nb = -b
        return a if a > nb else nb

    def gradient(self, p: Vec3) -> Vec3:
        """Central differences. Analytic gradients exist per primitive, but a
        CSG combination switches branch at the seam, so one uniform numerical
        gradient is both simpler and better behaved there than stitching
        analytic pieces together."""
        comptime H: Real = 1e-3
        var gx = self.distance(p + Vec3(H, 0, 0)) - self.distance(p - Vec3(H, 0, 0))
        var gy = self.distance(p + Vec3(0, H, 0)) - self.distance(p - Vec3(0, H, 0))
        var gz = self.distance(p + Vec3(0, 0, H)) - self.distance(p - Vec3(0, 0, H))
        var g = Vec3(gx, gy, gz) * (1.0 / (2 * H))
        var l = length(g)
        return g / l if l > 1e-9 else Vec3(0, 1, 0)


@fieldwise_init
struct SdfContact(Copyable, ImplicitlyCopyable, Movable):
    var hit: Bool
    var point: Vec3
    var normal: Vec3  # from a into b
    var depth: Real


def sdf_contact(
    a: Sdf3, b: Sdf3, seed: Vec3, iters: Int = 32
) -> SdfContact:
    """Contact by driving the two fields to a common value.

    The natural-looking objective, minimising `max(sd_a, sd_b)`, does NOT give
    the penetration: for two spheres its minimum is `(d − ra − rb)/2`, exactly
    HALF the overlap, because the balance point splits the gap between the two
    surfaces. The quantity that is the overlap is the SUM of the two fields
    evaluated where they agree — `−(sd_a + sd_b)` — which reduces to the
    analytic `ra + rb − d` for spheres and to `r − h` for a sphere against a
    plane. That is the measured relation the sphere-pair calibration in
    `test_sdf3` pins down.

    The descent therefore drives `sd_a` toward `sd_b` rather than driving
    either toward zero: step along the gradient of whichever field is larger,
    by half their difference, which for a unit-gradient field closes the gap in
    one step and converges immediately for primitive pairs. CSG fields are only
    a bound on the true distance, so the step is conservative there and the
    iteration count matters — which is why a CSG case is in the tests."""
    var p = seed
    for _ in range(iters):
        var da = a.distance(p)
        var db = b.distance(p)
        var diff = da - db
        if abs(diff) < 1e-6:
            break
        if diff > 0:
            p = p - a.gradient(p) * (diff * 0.5)
        else:
            p = p + b.gradient(p) * (diff * 0.5)
    var da = a.distance(p)
    var db = b.distance(p)
    var sum = da + db
    var ga = a.gradient(p)
    var gb = b.gradient(p)
    var n = gb - ga
    var nl = length(n)
    var normal = n / nl if nl > 1e-6 else gb
    return SdfContact(sum < 0, p, normal, -sum if sum < 0 else Real(0))
