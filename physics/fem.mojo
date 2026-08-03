"""Co-rotational linear tetrahedral FEM — a continuum next to the mass-spring lattice.

`softbody.mojo` models a deformable as particles joined by distance
constraints. That is cheap and stable but it is not a material: its stiffness
depends on how the lattice happens to be connected, it has no Poisson effect,
and "volume" is only preserved to the extent the spring topology happens to
resist it. FEM instead discretises the CONTINUUM: each tetrahedron carries a
deformation gradient, and stress comes from a constitutive law with real
material parameters (Lame mu and lambda), so stiffness and volume response are
properties of the material rather than of the mesh wiring.

The "co-rotational" part is the whole reason this is usable. Linear elasticity
computes stress from the small-strain tensor, which is only valid for small
DISPLACEMENTS — rotate an undeformed body and linear FEM reports enormous
spurious strain and tears it apart. Co-rotational FEM extracts the rotation R
from the deformation gradient F by polar decomposition and measures strain in
the unrotated frame, so a rigid rotation produces exactly zero force. That
property is asserted directly in `test_fem`, because it is the one that
separates a working implementation from one that merely looks elastic at rest.

Stress (co-rotational linear):  P(F) = 2*mu*(F - R) + lambda * tr(R^T F - I) * R
Nodal forces:                   H = -W * P * Dm^-T,  columns give f0..f2, f3 = -sum
"""

from std.math import sqrt
from geometry.vec import Real, Vec3
from geometry.mat import Mat3


def _det3(m: Mat3) -> Real:
    return (
        m.get(0, 0) * (m.get(1, 1) * m.get(2, 2) - m.get(1, 2) * m.get(2, 1))
        - m.get(0, 1) * (m.get(1, 0) * m.get(2, 2) - m.get(1, 2) * m.get(2, 0))
        + m.get(0, 2) * (m.get(1, 0) * m.get(2, 1) - m.get(1, 1) * m.get(2, 0))
    )


def _inv3(m: Mat3) -> Mat3:
    var d = _det3(m)
    var inv = 1.0 / d if abs(d) > 1e-20 else Real(0)
    var r = Mat3()
    r.set(0, 0, (m.get(1, 1) * m.get(2, 2) - m.get(1, 2) * m.get(2, 1)) * inv)
    r.set(0, 1, (m.get(0, 2) * m.get(2, 1) - m.get(0, 1) * m.get(2, 2)) * inv)
    r.set(0, 2, (m.get(0, 1) * m.get(1, 2) - m.get(0, 2) * m.get(1, 1)) * inv)
    r.set(1, 0, (m.get(1, 2) * m.get(2, 0) - m.get(1, 0) * m.get(2, 2)) * inv)
    r.set(1, 1, (m.get(0, 0) * m.get(2, 2) - m.get(0, 2) * m.get(2, 0)) * inv)
    r.set(1, 2, (m.get(0, 2) * m.get(1, 0) - m.get(0, 0) * m.get(1, 2)) * inv)
    r.set(2, 0, (m.get(1, 0) * m.get(2, 1) - m.get(1, 1) * m.get(2, 0)) * inv)
    r.set(2, 1, (m.get(0, 1) * m.get(2, 0) - m.get(0, 0) * m.get(2, 1)) * inv)
    r.set(2, 2, (m.get(0, 0) * m.get(1, 1) - m.get(0, 1) * m.get(1, 0)) * inv)
    return r^


def polar_rotation(f: Mat3) -> Mat3:
    """Rotation factor of `F = R S` by Newton iteration `R <- (R + R^-T)/2`.

    Cheap, quadratically convergent, and the standard choice for co-rotational
    FEM. It is what makes a rigid rotation cost zero force: without it the
    strain measure sees the rotation as stretch."""
    var r = f.copy()
    for _ in range(12):
        var rit = _inv3(r).transpose()
        var nr = Mat3()
        for i in range(3):
            for j in range(3):
                nr.set(i, j, 0.5 * (r.get(i, j) + rit.get(i, j)))
        r = nr^
    return r^


@fieldwise_init
struct Tet(Copyable, ImplicitlyCopyable, Movable):
    var a: Int
    var b: Int
    var c: Int
    var d: Int
    var dm_inv: Mat3  # inverse rest shape matrix
    var vol: Real  # rest volume


struct FemBody(Movable):
    """Node state as SoA plus a tetrahedron list."""

    var x: List[Real]
    var y: List[Real]
    var z: List[Real]
    var vx: List[Real]
    var vy: List[Real]
    var vz: List[Real]
    var inv_m: List[Real]  # 0 = pinned
    var tets: List[Tet]
    var mu: Real
    var lam: Real
    var damping: Real
    var corotational: Bool
    """When False, strain is measured with R = I — plain linear elasticity.
    Kept as a switchable variant rather than deleted because it is the control
    that shows what the polar decomposition BUYS: `bench_fem` prices the
    rotation extraction, and `test_fem` shows that without it a rigid rotation
    of an undeformed body generates enormous spurious force."""

    def __init__(out self, young: Real, poisson: Real, damping: Real = 4.0):
        self.x = List[Real]()
        self.y = List[Real]()
        self.z = List[Real]()
        self.vx = List[Real]()
        self.vy = List[Real]()
        self.vz = List[Real]()
        self.inv_m = List[Real]()
        self.tets = List[Tet]()
        # Lame parameters from the engineering constants a user actually knows
        self.mu = young / (2 * (1 + poisson))
        self.lam = young * poisson / ((1 + poisson) * (1 - 2 * poisson))
        self.damping = damping
        self.corotational = True

    def node_count(self) -> Int:
        return len(self.x)

    def add_node(mut self, p: Vec3, mass: Real):
        self.x.append(p[0])
        self.y.append(p[1])
        self.z.append(p[2])
        self.vx.append(0)
        self.vy.append(0)
        self.vz.append(0)
        self.inv_m.append(1.0 / mass if mass > 0 else Real(0))

    def pos(self, i: Int) -> Vec3:
        return Vec3(self.x[i], self.y[i], self.z[i])

    def pin(mut self, i: Int):
        self.inv_m[i] = 0

    def add_tet(mut self, a: Int, b: Int, c: Int, d: Int):
        var pa = self.pos(a)
        var e1 = self.pos(b) - pa
        var e2 = self.pos(c) - pa
        var e3 = self.pos(d) - pa
        var dm = Mat3()
        for k in range(3):
            dm.set(k, 0, e1[k])
            dm.set(k, 1, e2[k])
            dm.set(k, 2, e3[k])
        var det = _det3(dm)
        # Skip degenerate/inverted tets rather than storing an infinite inverse
        if abs(det) < 1e-12:
            return
        self.tets.append(Tet(a, b, c, d, _inv3(dm), abs(det) / 6.0))

    def total_volume(self) -> Real:
        var v = Real(0)
        for ref t in self.tets:
            var pa = self.pos(t.a)
            var e1 = self.pos(t.b) - pa
            var e2 = self.pos(t.c) - pa
            var e3 = self.pos(t.d) - pa
            var ds = Mat3()
            for k in range(3):
                ds.set(k, 0, e1[k])
                ds.set(k, 1, e2[k])
                ds.set(k, 2, e3[k])
            v += abs(_det3(ds)) / 6.0
        return v

    def elastic_forces(self, mut fx: List[Real], mut fy: List[Real], mut fz: List[Real]):
        """Accumulate co-rotational elastic forces into the given arrays."""
        for ref t in self.tets:
            var pa = self.pos(t.a)
            var e1 = self.pos(t.b) - pa
            var e2 = self.pos(t.c) - pa
            var e3 = self.pos(t.d) - pa
            var ds = Mat3()
            for k in range(3):
                ds.set(k, 0, e1[k])
                ds.set(k, 1, e2[k])
                ds.set(k, 2, e3[k])
            var f = ds * t.dm_inv  # deformation gradient
            var r = polar_rotation(f) if self.corotational else Mat3.identity()
            # P = 2 mu (F - R) + lambda tr(R^T F - I) R
            var rtf = r.transpose() * f
            var tr = rtf.get(0, 0) + rtf.get(1, 1) + rtf.get(2, 2) - 3.0
            var p = Mat3()
            for i in range(3):
                for j in range(3):
                    p.set(
                        i, j,
                        2 * self.mu * (f.get(i, j) - r.get(i, j))
                        + self.lam * tr * r.get(i, j),
                    )
            # H = -W P Dm^-T ; its columns are the forces on nodes b, c, d
            var h = p * t.dm_inv.transpose()
            var w = t.vol
            var f1 = Vec3(-w * h.get(0, 0), -w * h.get(1, 0), -w * h.get(2, 0))
            var f2 = Vec3(-w * h.get(0, 1), -w * h.get(1, 1), -w * h.get(2, 1))
            var f3 = Vec3(-w * h.get(0, 2), -w * h.get(1, 2), -w * h.get(2, 2))
            var f0 = (f1 + f2 + f3) * Real(-1)
            fx[t.a] += f0[0]
            fy[t.a] += f0[1]
            fz[t.a] += f0[2]
            fx[t.b] += f1[0]
            fy[t.b] += f1[1]
            fz[t.b] += f1[2]
            fx[t.c] += f2[0]
            fy[t.c] += f2[1]
            fz[t.c] += f2[2]
            fx[t.d] += f3[0]
            fy[t.d] += f3[1]
            fz[t.d] += f3[2]

    def step(mut self, dt: Real, gravity: Vec3, floor_y: Real = -1e30):
        var n = self.node_count()
        var fx = List[Real]()
        var fy = List[Real]()
        var fz = List[Real]()
        for _ in range(n):
            fx.append(0)
            fy.append(0)
            fz.append(0)
        self.elastic_forces(fx, fy, fz)
        for i in range(n):
            if self.inv_m[i] == 0:
                self.vx[i] = 0
                self.vy[i] = 0
                self.vz[i] = 0
                continue
            var im = self.inv_m[i]
            self.vx[i] += (fx[i] * im + gravity[0]) * dt
            self.vy[i] += (fy[i] * im + gravity[1]) * dt
            self.vz[i] += (fz[i] * im + gravity[2]) * dt
            # mass-proportional damping keeps the explicit integrator usable
            var d = 1.0 / (1.0 + self.damping * dt)
            self.vx[i] *= d
            self.vy[i] *= d
            self.vz[i] *= d
            self.x[i] += self.vx[i] * dt
            self.y[i] += self.vy[i] * dt
            self.z[i] += self.vz[i] * dt
            if self.y[i] < floor_y:
                self.y[i] = floor_y
                if self.vy[i] < 0:
                    self.vy[i] = 0


def _lat_idx(i: Int, j: Int, k: Int, ny: Int, nz: Int) -> Int:
    """Lattice node index. Module level: a nested def cannot infer the capture
    convention of an outer `var` on this nightly."""
    return (i * (ny + 1) + j) * (nz + 1) + k


def make_beam(
    mut b: FemBody, nx: Int, ny: Int, nz: Int, h: Real, mass_per_node: Real
):
    """A box lattice split into 5 tetrahedra per cell, the standard
    decomposition that tiles without leaving gaps."""
    for i in range(nx + 1):
        for j in range(ny + 1):
            for k in range(nz + 1):
                b.add_node(
                    Vec3(Real(i) * h, Real(j) * h, Real(k) * h), mass_per_node
                )
    for i in range(nx):
        for j in range(ny):
            for k in range(nz):
                var v000 = _lat_idx(i, j, k, ny, nz)
                var v100 = _lat_idx(i + 1, j, k, ny, nz)
                var v010 = _lat_idx(i, j + 1, k, ny, nz)
                var v001 = _lat_idx(i, j, k + 1, ny, nz)
                var v110 = _lat_idx(i + 1, j + 1, k, ny, nz)
                var v101 = _lat_idx(i + 1, j, k + 1, ny, nz)
                var v011 = _lat_idx(i, j + 1, k + 1, ny, nz)
                var v111 = _lat_idx(i + 1, j + 1, k + 1, ny, nz)
                # alternate the split so neighbouring cells share faces
                if (i + j + k) % 2 == 0:
                    b.add_tet(v000, v100, v010, v001)
                    b.add_tet(v100, v110, v010, v111)
                    b.add_tet(v100, v010, v001, v111)
                    b.add_tet(v010, v011, v001, v111)
                    b.add_tet(v100, v001, v101, v111)
                else:
                    b.add_tet(v100, v000, v110, v101)
                    b.add_tet(v000, v010, v110, v011)
                    b.add_tet(v000, v001, v101, v011)
                    b.add_tet(v110, v101, v011, v111)
                    b.add_tet(v000, v110, v101, v011)
