"""Example 17 — four ways to advance a tumbling body: the SpinIntegrator seam.

A box spun about its intermediate axis flips over and over (the Dzhanibekov
effect). The exact motion conserves kinetic energy and world angular momentum;
how well an integrator keeps them over 20 000 steps is what separates them.
The same state is advanced by `EulerSpin`, `Rk2Spin`, `MidpointSpin`
(implicit) and `LgvciSpin` (variational, Moser–Veselov), and each prints its
energy and momentum drift. Explicit Euler drifts visibly; the implicit
midpoint and the variational integrator stay near machine precision on
momentum, which is why the solver's tumbling path can run long without
spinning up.

Run:

    pixi run mojo run -I build examples/17_spin_integrators.mojo
"""

from geometry.vec import Real, Vec3
from geometry.motor import Motor3
from physics.rigid6 import Inertia3
from physics.integrator6 import (
    SpinIntegrator,
    EulerSpin,
    Rk2Spin,
    MidpointSpin,
    LgvciSpin,
    run_spin,
    spin_energy,
    spin_momentum_world,
)


def _len(v: Vec3) -> Float64:
    return (Float64(v[0]) ** 2 + Float64(v[1]) ** 2 + Float64(v[2]) ** 2) ** 0.5


def report[I: SpinIntegrator](name: String, w0: Vec3, inertia: Inertia3) -> Float64:
    var e0 = Float64(spin_energy(w0, inertia))
    var l0 = _len(spin_momentum_world(Motor3.identity(), w0, inertia))
    var r = run_spin[I](Motor3.identity(), w0, inertia, 0.001, 20000)
    var de = abs(Float64(spin_energy(r[1], inertia)) / e0 - 1.0)
    var dl = abs(_len(spin_momentum_world(r[0], r[1], inertia)) / l0 - 1.0)
    print(" ", name, " energy drift", de, "  momentum drift", dl)
    return dl


def main():
    var ibox = Inertia3.box(1, 0.1, 0.3, 0.6)
    var w0 = Vec3(0.001, 3, 0.001, 0)  # about the intermediate axis
    print("Dzhanibekov tumble, 20 000 steps of 1 ms, relative drift:")
    var euler = report[EulerSpin]("EulerSpin   ", w0, ibox)
    _ = report[Rk2Spin]("Rk2Spin     ", w0, ibox)
    var mid = report[MidpointSpin]("MidpointSpin", w0, ibox)
    var lg = report[LgvciSpin]("LgvciSpin   ", w0, ibox)
    print("implicit and variational keep momentum far better than Euler:",
          "YES" if mid < euler and lg < euler else "NO")
