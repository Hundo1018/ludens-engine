"""Contact resolution — the swap seam: three interchangeable solver families.

`ContactSolver` owns a whole substep (apply gravity, resolve the frame's
`Manifold`s, advance positions), so each family can keep its natural structure:

  * `SequentialImpulse` — velocity-level Gauss-Seidel impulses with restitution,
    Coulomb friction and a Baumgarte penetration bias (the Box2D-style classic).
  * `Pbd`  — position-based dynamics: predict, project penetration on positions,
    read velocity back from the position change (inelastic, very stable).
  * `Xpbd` — PBD with the compliant-constraint formulation (accumulated Lagrange
    multiplier). At zero compliance it matches PBD's result but exercises the
    XPBD update — the cost the benchmark measures.

All three are dimension-generic. A parity test asserts they all settle a dropped
stack to the same non-penetrating rest state; restitution/friction behaviour is
checked per solver where it differs.
"""

from std.math import sqrt
from geometry.vec import WorldType, Real, dot, length
from collision.pipeline import Manifold
from .rigidbody import RigidBody
from .forces import apply_gravity, integrate_positions


trait ContactSolver:
    @staticmethod
    def substep[dim: Int](
        mut bodies: List[RigidBody[dim]],
        manifolds: List[Manifold[dim]],
        gravity: SIMD[WorldType, dim],
        dt: Real,
        iterations: Int,
    ): ...


def _support[dim: Int](
    half: SIMD[WorldType, dim], n: SIMD[WorldType, dim]
) -> Real:
    """Box support width along `n`: sum_k |n[k]| * half[k]."""
    var s = Real(0)
    comptime for k in range(dim):
        var nk = n[k]
        if nk < 0:
            nk = -nk
        s += nk * half[k]
    return s


def _penetration[dim: Int](
    a: RigidBody[dim], b: RigidBody[dim], n: SIMD[WorldType, dim]
) -> Real:
    """Current penetration of two boxes along contact normal `n` (a -> b)."""
    var sep = dot(b.pos - a.pos, n)
    return _support(a.half, n) + _support(b.half, n) - sep


struct SequentialImpulse(ContactSolver):
    @staticmethod
    def substep[dim: Int](
        mut bodies: List[RigidBody[dim]],
        manifolds: List[Manifold[dim]],
        gravity: SIMD[WorldType, dim],
        dt: Real,
        iterations: Int,
    ):
        apply_gravity(bodies, dt, gravity)
        comptime BETA = Real(0.2)
        comptime SLOP = Real(0.005)
        for _it in range(iterations):
            for mi in range(len(manifolds)):
                var m = manifolds[mi]
                var a = m.a
                var b = m.b
                var ba = bodies[a]
                var bb = bodies[b]
                var inv_sum = ba.inv_mass + bb.inv_mass
                if inv_sum == 0:
                    continue
                var n = m.contact.normal
                var depth = m.contact.depth

                # normal impulse with restitution + positional bias
                var vn = dot(bb.vel - ba.vel, n)
                var e = min(ba.restitution, bb.restitution)
                var bias = (BETA / dt) * max(depth - SLOP, Real(0))
                var jn = (-(1 + e) * vn + bias) / inv_sum
                if jn < 0:
                    jn = 0
                var pn = n * jn
                ba.vel = ba.vel - pn * ba.inv_mass
                bb.vel = bb.vel + pn * bb.inv_mass

                # Coulomb friction along the sliding tangent
                var rv = bb.vel - ba.vel
                var vt = rv - n * dot(rv, n)
                var tlen = length(vt)
                if tlen > 1e-6:
                    var t = vt / tlen
                    var jt = -dot(rv, t) / inv_sum
                    var mu = sqrt(ba.friction * bb.friction)
                    var maxf = mu * jn
                    if jt > maxf:
                        jt = maxf
                    if jt < -maxf:
                        jt = -maxf
                    var pt = t * jt
                    ba.vel = ba.vel - pt * ba.inv_mass
                    bb.vel = bb.vel + pt * bb.inv_mass

                bodies[a] = ba
                bodies[b] = bb
        integrate_positions(bodies, dt)


struct Pbd(ContactSolver):
    @staticmethod
    def substep[dim: Int](
        mut bodies: List[RigidBody[dim]],
        manifolds: List[Manifold[dim]],
        gravity: SIMD[WorldType, dim],
        dt: Real,
        iterations: Int,
    ):
        apply_gravity(bodies, dt, gravity)
        var prev = List[SIMD[WorldType, dim]]()
        for i in range(len(bodies)):
            prev.append(bodies[i].pos)
        for ref b in bodies:
            if not b.is_static():
                b.pos = b.pos + b.vel * dt

        for _it in range(iterations):
            for mi in range(len(manifolds)):
                var m = manifolds[mi]
                var a = m.a
                var b = m.b
                var ba = bodies[a]
                var bb = bodies[b]
                var w = ba.inv_mass + bb.inv_mass
                if w == 0:
                    continue
                var n = m.contact.normal
                var pen = _penetration(ba, bb, n)
                if pen <= 0:
                    continue
                var corr = pen / w
                ba.pos = ba.pos - n * (corr * ba.inv_mass)
                bb.pos = bb.pos + n * (corr * bb.inv_mass)
                bodies[a] = ba
                bodies[b] = bb

        var inv_dt = Real(1) / dt
        for i in range(len(bodies)):
            if not bodies[i].is_static():
                var bi = bodies[i]
                bi.vel = (bi.pos - prev[i]) * inv_dt
                bodies[i] = bi


struct Xpbd(ContactSolver):
    @staticmethod
    def substep[dim: Int](
        mut bodies: List[RigidBody[dim]],
        manifolds: List[Manifold[dim]],
        gravity: SIMD[WorldType, dim],
        dt: Real,
        iterations: Int,
    ):
        apply_gravity(bodies, dt, gravity)
        var prev = List[SIMD[WorldType, dim]]()
        for i in range(len(bodies)):
            prev.append(bodies[i].pos)
        for ref b in bodies:
            if not b.is_static():
                b.pos = b.pos + b.vel * dt

        var lam = List[Real]()
        for _ in range(len(manifolds)):
            lam.append(0)
        comptime COMPLIANCE = Real(0)  # rigid contact; reduces to PBD at alpha=0
        var alpha = COMPLIANCE / (dt * dt)

        for _it in range(iterations):
            for mi in range(len(manifolds)):
                var m = manifolds[mi]
                var a = m.a
                var b = m.b
                var ba = bodies[a]
                var bb = bodies[b]
                var w = ba.inv_mass + bb.inv_mass
                if w == 0:
                    continue
                var n = m.contact.normal
                var pen = _penetration(ba, bb, n)
                if pen <= 0:
                    continue
                # constraint C = -pen; XPBD multiplier update
                var dlam = (pen - alpha * lam[mi]) / (w + alpha)
                lam[mi] = lam[mi] + dlam
                ba.pos = ba.pos - n * (dlam * ba.inv_mass)
                bb.pos = bb.pos + n * (dlam * bb.inv_mass)
                bodies[a] = ba
                bodies[b] = bb

        var inv_dt = Real(1) / dt
        for i in range(len(bodies)):
            if not bodies[i].is_static():
                var bi = bodies[i]
                bi.vel = (bi.pos - prev[i]) * inv_dt
                bodies[i] = bi
