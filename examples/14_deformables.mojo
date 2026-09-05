"""Example 14 — the deformable-body family: FEM, MPM, and SPH-vs-PBF.

Three short vignettes, each the smallest scene that shows what its solver adds:

  1. Co-rotational FEM. A pinned cantilever beam sags to a steady tip
     deflection under gravity. Then the co-rotational property: rotate an
     undeformed beam bodily by 63 degrees — linear elasticity reads that as
     huge strain and generates a spurious restoring force; co-rotational FEM
     factors the rotation out and the force stays ~0.

  2. MLS-MPM elastic vs plastic. The identical column is dropped twice; the
     plastic run has a determinant-clamp return mapping (`set_plastic`) so it
     forgets strain past yield and keeps its squashed height, while the elastic
     run springs back taller.

  3. SPH vs PBF on the same particle state. SPH turns density error into a
     CFL-limited pressure force; PBF turns it into a constraint projection with
     no timestep limit. Both must settle near rest density `rho0`.

Run:

    pixi run mojo run -I build examples/14_deformables.mojo
"""

from std.math import sqrt, cos, sin
from geometry.vec import Real, Vec3
from physics.fem import FemBody, make_beam
from physics.mpm import MpmSolver
from physics.pbf import PbfFluid
from physics.sph import sph_step

comptime G = Vec3(0, -9.8, 0, 0)


def _max_elastic_force(mut b: FemBody) -> Real:
    var n = b.node_count()
    var fx = List[Real]()
    var fy = List[Real]()
    var fz = List[Real]()
    for _ in range(n):
        fx.append(0)
        fy.append(0)
        fz.append(0)
    b.elastic_forces(fx, fy, fz)
    var m = Real(0)
    for i in range(n):
        var f = sqrt(fx[i] * fx[i] + fy[i] * fy[i] + fz[i] * fz[i])
        if f > m:
            m = f
    return m


def _rotated_beam(corotational: Bool) -> Real:
    var r = FemBody(young=5000.0, poisson=0.3)
    make_beam(r, 4, 2, 2, 0.1, 0.05)
    r.corotational = corotational
    var ca = Real(cos(1.1))
    var sa = Real(sin(1.1))
    for i in range(r.node_count()):
        var px = r.x[i]
        var py = r.y[i]
        r.x[i] = ca * px - sa * py
        r.y[i] = sa * px + ca * py
    return _max_elastic_force(r)


def _mpm_column(mut m: MpmSolver):
    var sp = Real(0.04)
    var vol = sp * sp * sp
    for i in range(6):
        for j in range(10):
            for k in range(4):
                m.add(
                    Vec3(0.55 + Real(i) * sp, 0.95 + Real(j) * sp, 0.70 + Real(k) * sp, 0),
                    vol * 1000.0, vol,
                )


def _mpm_height(m: MpmSolver) -> Real:
    var h = Real(-1e30)
    for ref q in m.p:
        if q.x[1] > h:
            h = q.x[1]
    return h


def _pbf_block(mut f: PbfFluid):
    var sp = Real(0.06)
    for i in range(6):
        for j in range(6):
            for k in range(6):
                f.add(Vec3(0.12 + Real(i) * sp, 0.30 + Real(j) * sp, 0.12 + Real(k) * sp, 0))


def _mean_rho(mut f: PbfFluid) -> Real:
    f._rebuild_grid()
    var nbr = List[Int]()
    var tot = Real(0)
    for i in range(f.count()):
        f._neighbors(i, nbr)
        tot += f.density(i, nbr)
    return tot / Real(f.count())


def main() raises:
    # --- 1. FEM: co-rotational cantilever + the rotated-rest-pose test ---
    print("== FEM co-rotational: pinned cantilever under gravity ==")
    var c = FemBody(young=20000.0, poisson=0.3)
    make_beam(c, 6, 2, 2, 0.1, 0.02)
    for i in range(c.node_count()):
        if c.x[i] < 1e-6:
            c.pin(i)
    for _ in range(600):
        c.step(1.0 / 600.0, G)
    var tip_y = Real(1e30)
    for i in range(c.node_count()):
        if c.x[i] > 0.55 and c.y[i] < tip_y:
            tip_y = c.y[i]
    print("  nodes:", c.node_count(), "  tip y after 600 steps =", Float64(tip_y))

    print("== spurious force from a 63-degree rigid rotation of the rest pose ==")
    var f_lin = _rotated_beam(False)
    var f_cor = _rotated_beam(True)
    print("  linear elasticity   max |force| =", Float64(f_lin))
    print("  co-rotational       max |force| =", Float64(f_cor))
    print("  co-rotational is force-free:", "YES" if f_cor < 1e-2 else "NO")

    # --- 2. MPM: elastic vs plastic on the identical dropped column ---
    print("== MPM: elastic vs plastic column drop (240 particles) ==")
    var me = MpmSolver(Vec3(0, 0, 0, 0), 0.05, 32, 100000.0, 0.2)
    _mpm_column(me)
    for _ in range(2000):
        me.step(1.0 / 2000.0, G)
    var h_elastic = _mpm_height(me)

    var mp = MpmSolver(Vec3(0, 0, 0, 0), 0.05, 32, 100000.0, 0.2)
    _mpm_column(mp)
    mp.set_plastic(0.94, 1.02)
    for _ in range(2000):
        mp.step(1.0 / 2000.0, G)
    var h_plastic = _mpm_height(mp)
    print("  elastic final height =", Float64(h_elastic))
    print("  plastic final height =", Float64(h_plastic))
    print("  plastic keeps its squash:", "YES" if h_plastic < 0.8 * h_elastic else "NO")

    # --- 3. SPH vs PBF settling to rest density on the same state ---
    print("== SPH vs PBF: settled mean density / rho0 (216 particles) ==")
    var fp = PbfFluid(Vec3(0, 0, 0, 0), Vec3(0.6, 1.0, 0.6, 0))
    fp.calibrate(0.06)
    _pbf_block(fp)
    for _ in range(150):
        fp.step(1.0 / 120.0, G, 6)
    var rho_pbf = Float64(_mean_rho(fp) / fp.rho0)

    var fs = PbfFluid(Vec3(0, 0, 0, 0), Vec3(0.6, 1.0, 0.6, 0))
    fs.calibrate(0.06)
    _pbf_block(fs)
    for _ in range(1600):
        sph_step(fs, 1.0 / 2000.0, G)
    var rho_sph = Float64(_mean_rho(fs) / fs.rho0)
    print("  PBF (constraint projection) rho/rho0 =", rho_pbf)
    print("  SPH (CFL-limited pressure)   rho/rho0 =", rho_sph)
    print("  both near rest density:", "YES" if (abs(rho_pbf - 1.0) < 0.2 and abs(rho_sph - 1.0) < 0.2) else "NO")
