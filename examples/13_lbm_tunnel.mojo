"""Example 13 — lattice-Boltzmann flow past a sphere in a wind tunnel.

`Lbm` is a D3Q19 lattice-Boltzmann fluid: every cell holds 19 populations,
each step is collide + stream + boundary. With `BC_TUNNEL` the inlet holds a
fixed velocity and the outlet a zero gradient, so a uniform stream flows in one
face and out the other.

We voxelise a solid sphere into the stream and run to a quasi-steady state, then
read the centreline x-velocity upstream of the sphere versus in its wake: the
wake must be slower. Half-way bounce-back at the sphere surface is mass-tight,
so `total_mass` is unchanged end to end.

Run:

    pixi run mojo run -I build examples/13_lbm_tunnel.mojo
"""

from geometry.vec import Real, Vec3
from fluid.lbm import Lbm, BC_TUNNEL

comptime U_IN: Real = 0.05
comptime STEPS = 400


def main():
    var t = Lbm(24, 12, 12, Real(0.02), BC_TUNNEL)
    t.init_uniform(1.0, U_IN, 0, 0)
    t.inlet_u = U_IN
    t.set_solid_sphere(8, 5.5, 5.5, 2.5)
    print("== D3Q19 tunnel, 24x12x12, sphere r=2.5 ==")
    print("  solid cells:", t.solid_count(), "  inflow u =", U_IN)

    var m0 = t.total_mass()
    for _ in range(STEPS):
        t.step()

    var upstream = Float64(t.velocity(t.idx(3, 5, 5))[0])
    var wake = Float64(t.velocity(t.idx(14, 5, 5))[0])
    var freestream = Float64(t.velocity(t.idx(14, 1, 1))[0])
    print("== centreline x-velocity after", STEPS, "steps ==")
    print("  upstream   (x=3)  u =", upstream)
    print("  wake       (x=14) u =", wake)
    print("  freestream (corner) u =", freestream)
    print("  wake slower than upstream:", "YES" if wake < upstream else "NO")

    var m1 = t.total_mass()
    print("== mass conservation ==")
    print("  total mass:", m0, "->", m1, " rel. drift =", abs(m1 - m0) / m0)
