"""6-DOF rigid dynamics: representation cost + integrator quality.

Table 1 — ns/step of the two parity representations (`QuatBody6` vs
`ScrewBody6`, same physics; see `test_rigid6`) and the three spin integrators.
Table 2 — Dzhanibekov (intermediate-axis tumble) energy/momentum drift after
1e5 steps: what each integrator's cost buys in conservation quality.
"""

from std.benchmark import keep
from std.math import sqrt
from harness.bench import BenchTable, measure
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from geometry.motor import Motor3
from geometry.galie import Screw3
from physics.rigid6 import Inertia3, QuatBody6, ScrewBody6
from physics.integrator6 import (
    EulerSpin,
    Rk2Spin,
    MidpointSpin,
    LgvciSpin,
    run_spin,
    spin_energy,
    spin_momentum_world,
)

comptime STEPS = 100000
comptime DT: Real = 0.001


def main() raises:
    var t = BenchTable("6-DOF rigid body: representation & integrator cost")
    var ibox = Inertia3.box(1, 0.1, 0.3, 0.6)
    var grav = Vec3(0, -9.8, 0)

    var qb = QuatBody6(
        Vec3(0, 0, 0), Quat.identity(), Vec3(1, 0, 0), Vec3(0.3, 2, 0.4), ibox
    )

    @parameter
    def bench_quat():
        for _ in range(STEPS):
            qb.step(DT, grav, Vec3(0, 0, 0))
        keep(qb.pos[0])

    var ns_q = measure[bench_quat]()
    t.add("QuatBody6 (world Newton-Euler)", 1, "step", ns_q, STEPS)

    var sb = ScrewBody6(Motor3.identity(), Screw3.zero(), ibox)
    sb.apply_impulse(Vec3(1, 0, 0), Vec3(0, 0.5, 0))

    @parameter
    def bench_screw():
        for _ in range(STEPS):
            sb.step(DT, grav, Vec3(0, 0, 0))
        keep(sb.vel.b12)

    var ns_s = measure[bench_screw]()
    t.add("ScrewBody6 (motor Lie-Poisson)", 1, "step", ns_s, STEPS)

    var w0 = Vec3(0.001, 3, 0.001)

    @parameter
    def bench_euler():
        var w = w0
        var r = run_spin[EulerSpin](Motor3.identity(), w, ibox, DT, STEPS)
        keep(r[1][0])

    @parameter
    def bench_rk2():
        var w = w0
        var r = run_spin[Rk2Spin](Motor3.identity(), w, ibox, DT, STEPS)
        keep(r[1][0])

    @parameter
    def bench_mid():
        var w = w0
        var r = run_spin[MidpointSpin](Motor3.identity(), w, ibox, DT, STEPS)
        keep(r[1][0])

    @parameter
    def bench_lgvci():
        var w = w0
        var r = run_spin[LgvciSpin](Motor3.identity(), w, ibox, DT, STEPS)
        keep(r[1][0])

    t.add("EulerSpin", 1, "spin step", measure[bench_euler](), STEPS)
    t.add("Rk2Spin", 1, "spin step", measure[bench_rk2](), STEPS)
    t.add("MidpointSpin (implicit)", 1, "spin step", measure[bench_mid](), STEPS)
    t.add("LgvciSpin (variational)", 1, "spin step", measure[bench_lgvci](), STEPS)
    t.print_report()

    # Conservation quality: Dzhanibekov tumble drift after 1e5 steps.
    var e0 = Float64(spin_energy(w0, ibox))
    var l0v = spin_momentum_world(Motor3.identity(), w0, ibox)
    var l0 = Float64(sqrt(l0v[0] * l0v[0] + l0v[1] * l0v[1] + l0v[2] * l0v[2]))
    print("### Dzhanibekov drift after 1e5 steps (dt=0.001)")
    print("")
    print("| integrator | E/E0 - 1 | L/L0 - 1 |")
    print("|---|---:|---:|")

    var rese = run_spin[EulerSpin](Motor3.identity(), w0, ibox, DT, STEPS)
    var resr = run_spin[Rk2Spin](Motor3.identity(), w0, ibox, DT, STEPS)
    var resm = run_spin[MidpointSpin](Motor3.identity(), w0, ibox, DT, STEPS)
    var resv = run_spin[LgvciSpin](Motor3.identity(), w0, ibox, DT, STEPS)

    var names = [
        "EulerSpin",
        "Rk2Spin",
        "MidpointSpin (implicit)",
        "LgvciSpin (variational)",
    ]
    for i in range(4):
        var pose = rese[0]
        var w = rese[1]
        if i == 1:
            pose = resr[0]
            w = resr[1]
        elif i == 2:
            pose = resm[0]
            w = resm[1]
        elif i == 3:
            pose = resv[0]
            w = resv[1]
        var lv = spin_momentum_world(pose, w, ibox)
        var l = Float64(sqrt(lv[0] * lv[0] + lv[1] * lv[1] + lv[2] * lv[2]))
        print(
            "|",
            names[i],
            "|",
            Float64(spin_energy(w, ibox)) / e0 - 1.0,
            "|",
            l / l0 - 1.0,
            "|",
        )
    print("")
