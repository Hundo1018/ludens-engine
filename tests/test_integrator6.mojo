from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.motor import Motor3
from physics.rigid6 import Inertia3
from physics.integrator6 import (
    EulerSpin,
    Rk2Spin,
    MidpointSpin,
    LgvciSpin,
    run_spin,
    spin_energy,
    spin_momentum_world,
)


def _len(v: Vec3) -> Float64:
    return Float64(sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]))


def main() raises:
    var s = Suite("integrator6")
    var probe = Vec3(0.4, -0.3, 0.2)

    # 1. Spherical inertia: the gyroscopic term vanishes, all three
    #    integrators must agree exactly (same exp advance, same omega).
    var isph = Inertia3.sphere(2, 0.5)
    var w0 = Vec3(1, 2, 3)
    var re = run_spin[EulerSpin](Motor3.identity(), w0, isph, 0.001, 200)
    var rr = run_spin[Rk2Spin](Motor3.identity(), w0, isph, 0.001, 200)
    var rm = run_spin[MidpointSpin](Motor3.identity(), w0, isph, 0.001, 200)
    s.check(
        _len(re[0].apply_point(probe) - rm[0].apply_point(probe)) < 1e-5,
        "sphere: euler == midpoint (action)",
    )
    s.check(
        _len(rr[0].apply_point(probe) - rm[0].apply_point(probe)) < 1e-5,
        "sphere: rk2 == midpoint (action)",
    )
    s.check(_len(re[1] - rm[1]) < 1e-6, "sphere: omega agrees")

    # 2. Asymmetric box, short horizon, small dt: all three converge to the
    #    same trajectory (cross parity of the seam).
    var ibox = Inertia3.box(1, 0.1, 0.3, 0.6)  # ix > iy > iz
    var wt = Vec3(0.3, 2, 0.4)
    var be = run_spin[EulerSpin](Motor3.identity(), wt, ibox, 0.0001, 200)
    var br = run_spin[Rk2Spin](Motor3.identity(), wt, ibox, 0.0001, 200)
    var bm = run_spin[MidpointSpin](Motor3.identity(), wt, ibox, 0.0001, 200)
    s.check(
        _len(be[0].apply_point(probe) - bm[0].apply_point(probe)) < 1e-4,
        "box: euler ~ midpoint (short horizon)",
    )
    s.check(
        _len(br[0].apply_point(probe) - bm[0].apply_point(probe)) < 1e-5,
        "box: rk2 ~ midpoint (short horizon)",
    )

    # 3. Dzhanibekov tumble (intermediate-axis spin), 20k steps: the implicit
    #    midpoint must beat Euler on both energy and momentum drift, hard.
    var wd = Vec3(0.001, 3, 0.001)  # y = intermediate axis of ibox
    var e0 = Float64(spin_energy(wd, ibox))
    var l0 = _len(spin_momentum_world(Motor3.identity(), wd, ibox))
    var de = run_spin[EulerSpin](Motor3.identity(), wd, ibox, 0.001, 20000)
    var dm = run_spin[MidpointSpin](Motor3.identity(), wd, ibox, 0.001, 20000)
    var drift_e_euler = abs(Float64(spin_energy(de[1], ibox)) / e0 - 1.0)
    var drift_e_mid = abs(Float64(spin_energy(dm[1], ibox)) / e0 - 1.0)
    var drift_l_euler = abs(
        _len(spin_momentum_world(de[0], de[1], ibox)) / l0 - 1.0
    )
    var drift_l_mid = abs(
        _len(spin_momentum_world(dm[0], dm[1], ibox)) / l0 - 1.0
    )
    print(
        "  drift: euler E", drift_e_euler, "L", drift_l_euler,
        "| midpoint E", drift_e_mid, "L", drift_l_mid,
    )
    s.check(drift_e_mid < 1e-3, "midpoint energy drift tiny")
    s.check(drift_l_mid < 1e-3, "midpoint momentum drift tiny")
    s.check(drift_e_mid < drift_e_euler / 5, "midpoint beats euler on energy")
    s.check(
        drift_l_mid < drift_l_euler / 5, "midpoint beats euler on momentum"
    )

    # 4. LGVCI (Moser-Veselov DMV, the variational fourth seam member).
    #    Sphere: the gyroscopic term vanishes, so omega must be EXACTLY
    #    transported (F is about omega, so F^T.Pi = Pi) and the pose action
    #    must agree with the others to the scheme's O(h^3) angle retardation.
    var rv = run_spin[LgvciSpin](Motor3.identity(), w0, isph, 0.001, 200)
    s.check(_len(rv[1] - w0) < 1e-5, "lgvci sphere: omega exactly kept")
    s.check(
        _len(rv[0].apply_point(probe) - rm[0].apply_point(probe)) < 1e-4,
        "lgvci sphere: action matches midpoint",
    )

    # 5. Box, short horizon cross parity with the implicit midpoint.
    var bv = run_spin[LgvciSpin](Motor3.identity(), wt, ibox, 0.0001, 200)
    s.check(
        _len(bv[0].apply_point(probe) - bm[0].apply_point(probe)) < 1e-4,
        "lgvci box: ~ midpoint (short horizon)",
    )

    # 6. Dzhanibekov long run: the variational structure transports the body
    #    momentum by an exact rotation each step — world |L| holds to the
    #    float32 roundoff-accumulation class, energy stays bounded, and both
    #    beat Euler by a wide margin.
    var dv = run_spin[LgvciSpin](Motor3.identity(), wd, ibox, 0.001, 20000)
    var drift_e_lgvci = abs(Float64(spin_energy(dv[1], ibox)) / e0 - 1.0)
    var drift_l_lgvci = abs(
        _len(spin_momentum_world(dv[0], dv[1], ibox)) / l0 - 1.0
    )
    print("  drift: lgvci E", drift_e_lgvci, "L", drift_l_lgvci)
    s.check(drift_e_lgvci < 1e-3, "lgvci energy drift tiny")
    s.check(drift_l_lgvci < 3e-4, "lgvci momentum conserved to roundoff class")
    s.check(drift_e_lgvci < drift_e_euler / 5, "lgvci beats euler on energy")
    s.check(drift_l_lgvci < drift_l_euler / 5, "lgvci beats euler on momentum")

    s.finish()
