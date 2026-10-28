"""Mass properties of a compound body (ROADMAP 17.44).

Each child of a `collision.collider_set.CompoundSpec` contributes its mass,
centre of mass and inertia tensor (closed forms for box / sphere / capsule /
ellipsoid; a hull is integrated over tetrahedra fanned from each face to the
hull's vertex mean). The tensors are turned into the parent frame
(R I R^T), moved to the compound's centre of mass (parallel axis theorem:
I + m (|d|^2 E - d d^T)) and summed; the sum is diagonalised by
`geometry.mat3.sym_eigen3` (Jacobi), which gives the principal moments and
the principal frame. `ContactScene6.add_compound` puts the body origin at
that centre of mass and its axes on that frame, so `Inertia3`'s diagonal
form is exact for the compound -- including products of inertia, which an
L-shaped body has and a diagonal-only sum would drop.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot, cross
from geometry.quat import Quat
from geometry.mat3 import Mat3x3, sym_eigen3
from collision.collider_set import CompoundSpec, SHAPE_BOX, SHAPE_SPHERE, SHAPE_CAPSULE, SHAPE_HULL, SHAPE_ELLIPSOID
from collision.hull import HullShape
from .rigid6 import Inertia3

comptime _PI: Real = 3.14159265358979


@fieldwise_init
struct CompoundMass(Copyable, ImplicitlyCopyable, Movable):
    var mass: Real
    var com: Vec3  # in the spec's frame
    var moments: Vec3  # principal moments
    var frame: Quat  # principal axes in the spec's frame (columns of R)


def _rot_mat(q: Quat) -> Mat3x3:
    return Mat3x3.from_cols(q.rotate(Vec3(1, 0, 0, 0)), q.rotate(Vec3(0, 1, 0, 0)), q.rotate(Vec3(0, 0, 1, 0)))


def quat_from_mat(r: Mat3x3) -> Quat:
    """Unit quaternion of a rotation matrix (Shepperd's branch choice)."""
    var t = r.get(0, 0) + r.get(1, 1) + r.get(2, 2)
    var x: Real
    var y: Real
    var z: Real
    var w: Real
    if t > 0:
        var s = sqrt(t + 1) * 2
        w = s / 4
        x = (r.get(2, 1) - r.get(1, 2)) / s
        y = (r.get(0, 2) - r.get(2, 0)) / s
        z = (r.get(1, 0) - r.get(0, 1)) / s
    elif r.get(0, 0) > r.get(1, 1) and r.get(0, 0) > r.get(2, 2):
        var s = sqrt(1 + r.get(0, 0) - r.get(1, 1) - r.get(2, 2)) * 2
        w = (r.get(2, 1) - r.get(1, 2)) / s
        x = s / 4
        y = (r.get(0, 1) + r.get(1, 0)) / s
        z = (r.get(0, 2) + r.get(2, 0)) / s
    elif r.get(1, 1) > r.get(2, 2):
        var s = sqrt(1 + r.get(1, 1) - r.get(0, 0) - r.get(2, 2)) * 2
        w = (r.get(0, 2) - r.get(2, 0)) / s
        x = (r.get(0, 1) + r.get(1, 0)) / s
        y = s / 4
        z = (r.get(1, 2) + r.get(2, 1)) / s
    else:
        var s = sqrt(1 + r.get(2, 2) - r.get(0, 0) - r.get(1, 1)) * 2
        w = (r.get(1, 0) - r.get(0, 1)) / s
        x = (r.get(0, 2) + r.get(2, 0)) / s
        y = (r.get(1, 2) + r.get(2, 1)) / s
        z = s / 4
    var q = Quat(x, y, z, w)
    return q.normalized()


def _diag(a: Real, b: Real, c: Real) -> Mat3x3:
    var m = Mat3x3()
    m.set(0, 0, a)
    m.set(1, 1, b)
    m.set(2, 2, c)
    return m^


def hull_mass(verts: List[Real], density: Real) -> Tuple[Real, Vec3, Mat3x3]:
    """(mass, centre of mass, inertia tensor about it) of a convex hull of
    local vertices (flat, stride 3): each face's vertices, ordered around the
    face centroid, fan into triangles; each triangle with the vertex mean
    forms a tetrahedron (volume, centroid and second moment in closed form,
    Tonon 2004)."""
    var hs = HullShape(verts.copy())
    var nv = hs.nv()
    var o = Vec3(0, 0, 0, 0)
    for v in range(nv):
        o = o + hs.vert(v)
    o = o / Real(nv)
    var vol = Real(0)
    var mom1 = Vec3(0, 0, 0, 0)
    var cov = Mat3x3()  # second moment about o
    for f in range(hs.nf()):
        var n = hs.face(f)
        var off = dot(n, hs.vert(0))
        for v in range(nv):
            off = max(off, dot(n, hs.vert(v)))
        var ring = List[Int]()
        for v in range(nv):
            if abs(dot(n, hs.vert(v)) - off) < 1e-5:
                ring.append(v)
        if len(ring) < 3:
            continue
        var fc = Vec3(0, 0, 0, 0)
        for k in range(len(ring)):
            fc = fc + hs.vert(ring[k])
        fc = fc / Real(len(ring))
        var u = hs.vert(ring[0]) - fc
        u = u / sqrt(max(dot(u, u), 1e-30))
        var w = cross(n, u)
        var ang = List[Real]()
        for k in range(len(ring)):
            var dv = hs.vert(ring[k]) - fc
            ang.append(_pseudo_angle(dot(dv, w), dot(dv, u)))
        # insertion sort by angle
        for k in range(1, len(ring)):
            var a = ang[k]
            var r = ring[k]
            var m = k - 1
            while m >= 0 and ang[m] > a:
                ang[m + 1] = ang[m]
                ring[m + 1] = ring[m]
                m -= 1
            ang[m + 1] = a
            ring[m + 1] = r
        for k in range(1, len(ring) - 1):
            var a = hs.vert(ring[0]) - o
            var b = hs.vert(ring[k]) - o
            var c = hs.vert(ring[k + 1]) - o
            var tv = dot(a, cross(b, c)) / 6
            vol += tv
            var s = a + b + c
            mom1 = mom1 + s * (tv / 4)
            for p in range(3):
                for q in range(3):
                    var e = a[p] * a[q] + b[p] * b[q] + c[p] * c[q] + s[p] * s[q]
                    cov.set(p, q, cov.get(p, q) + tv / 20 * e)
    # faces are ordered counter-clockwise about their outward normal, so
    # every tetrahedron (vertex mean, a, b, c) has positive volume
    var m = density * vol
    var cl = mom1 / vol if vol > 0 else Vec3(0, 0, 0, 0)
    # second moment about the centroid: C_o - V cl cl^T
    var inertia = Mat3x3()
    var cc = Mat3x3()
    for p in range(3):
        for q in range(3):
            cc.set(p, q, cov.get(p, q) - vol * cl[p] * cl[q])
    var tr = cc.get(0, 0) + cc.get(1, 1) + cc.get(2, 2)
    for p in range(3):
        for q in range(3):
            inertia.set(p, q, density * ((tr if p == q else 0) - cc.get(p, q)))
    return (m, o + cl, inertia^)


def _pseudo_angle(y: Real, x: Real) -> Real:
    """A value in [0, 4) that increases with the angle of (x, y): enough to
    order a face's vertices around its centroid without atan2."""
    var r = y / (abs(x) + abs(y) + 1e-30)
    if x >= 0:
        return r if y >= 0 else 4 + r
    return 2 - r


def child_mass(spec: CompoundSpec, k: Int, density: Real) -> Tuple[Real, Vec3, Mat3x3]:
    """(mass, centre in the child's own frame, inertia about it in that
    frame) of child `k`."""
    var h = spec.half[k]
    var kind = spec.kind[k]
    if kind == SHAPE_HULL:
        return hull_mass(spec.child_verts(k), density)
    var m: Real
    var i: Inertia3
    match kind:
        case == SHAPE_BOX:
            m = density * 8 * h[0] * h[1] * h[2]
            i = Inertia3.box(m, h[0], h[1], h[2])
        case == SHAPE_SPHERE:
            m = density * Real(4.0 / 3.0) * _PI * h[0] * h[0] * h[0]
            i = Inertia3.sphere(m, h[0])
        case == SHAPE_CAPSULE:
            m = density * (_PI * h[0] * h[0] * 2 * h[1] + Real(4.0 / 3.0) * _PI * h[0] * h[0] * h[0])
            i = Inertia3.capsule(m, h[0], h[1])
        case _:
            m = density * Real(4.0 / 3.0) * _PI * h[0] * h[1] * h[2]
            i = Inertia3.ellipsoid(m, h[0], h[1], h[2])
    return (m, Vec3(0, 0, 0, 0), _diag(i.ix, i.iy, i.iz))


def compound_mass(spec: CompoundSpec, density: Real) -> CompoundMass:
    """Total mass, centre of mass, principal moments and principal frame of
    the children of `spec` at uniform `density`."""
    var total = Real(0)
    var mom = Vec3(0, 0, 0, 0)
    var parts = List[Real]()
    var centres = List[Vec3]()
    var tensors = List[Mat3x3]()
    for k in range(len(spec)):
        var cm = child_mass(spec, k, density)
        var r = _rot_mat(spec.rot[k])
        var c = spec.pos[k] + spec.rot[k].rotate(cm[1])
        total += cm[0]
        mom = mom + c * cm[0]
        parts.append(cm[0])
        centres.append(c)
        tensors.append(r * cm[2] * r.transpose())
    var com = mom / total
    var sum = Mat3x3()
    for k in range(len(parts)):
        var d = centres[k] - com
        var dd = dot(d, d)
        for p in range(3):
            for q in range(3):
                var pa = parts[k] * ((dd if p == q else 0) - d[p] * d[q])
                sum.set(p, q, sum.get(p, q) + tensors[k].get(p, q) + pa)
    var eig = sym_eigen3(sum)
    return CompoundMass(total, com, eig[0], quat_from_mat(eig[1]))
