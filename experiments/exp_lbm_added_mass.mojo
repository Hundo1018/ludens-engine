"""Probe for ROADMAP 17.59 (added mass): the lattice force on a moving
sphere as a response to its velocity history. The sphere (R = 3 cells,
24^3 periodic, nu 0.16) is driven along x with a prescribed random velocity
(uniform in [-amp, amp] lattice units per step); position either fixed or
integrated (`move` arg). Prints CSV `n,v,f` (lattice units) for
`scripts/added_mass_fit.py`:

    pixi run mojo run -I build experiments/exp_lbm_added_mass.mojo move > am.csv
    pixi run python scripts/added_mass_fit.py am.csv 20

Measured (17.59): c_0 = -75 (0.66 rho V; `Lbm.wall_drag` gives 0.684),
explicit coupling unstable below density ratio ~0.6 (spectral radius 1.22
at 0.5), the implicit wall drag stable down to 0.05 (0.994)."""

from std.sys import argv
from std.random import seed, random_float64
from geometry.vec import Real, Vec3
from fluid.lbm import Lbm


def main() raises:
    var args = argv()
    var move = len(args) > 1 and args[1] == "move"
    var amp = Real(0.01)
    var steps = 3000
    seed(7)
    var l = Lbm(24, 24, 24, 0.16)
    l.init_uniform(1, 0, 0, 0)
    var c = Vec3(12.5, 11.5, 11.5, 0)
    var k = l.add_moving_sphere(c, 3, Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0))
    print("n,v,f")
    for n in range(steps):
        var v = Real(random_float64(-1, 1)) * amp
        if move:
            c = c + Vec3(v, 0, 0, 0)
        l.move_sphere(k, c, Vec3(v, 0, 0, 0), Vec3(0, 0, 0, 0))
        l.step()
        print(n, ",", v, ",", l.obj_f[k][0], sep="")
