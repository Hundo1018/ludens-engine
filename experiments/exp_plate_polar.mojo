"""Flat-plate polar from the LBM tunnel against the Wing model (ROADMAP 17.74).

Lattice Re = u chord / nu = 40. `plate_polar` sweeps the angle of attack;
`gameplay.aircraft.Wing`'s CL(alpha) (2 pi alpha to stall, flat plate sin 2a
after) is the high-Re reference, so the table shows how far a viscous
lattice polar sits from it.
"""

from std.math import sin
from geometry.vec import Real
from gameplay.vehicle_tunnel import plate_polar


def main() raises:
    print("| alpha deg | CL tunnel | CD tunnel | 2 pi alpha | sin 2a |")
    print("|---:|---:|---:|---:|---:|")
    for deg in [0, 10, 20, 30, 45, 60, 90]:
        var a = Real(deg) * 0.017453292
        var p = plate_polar(a)
        print("|", deg, "|", p.cl, "|", p.cd, "|", 6.2831855 * a, "|", sin(2 * a), "|")
