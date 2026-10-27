"""Hair strands <-> 2-D grid gas, two-way (ROADMAP 17.61: strands' reaction
on the `MacFluid2` flow).

The 2-D counterpart of `StrandAir`, with the same drag model:

  * each non-root particle is dragged toward the gas velocity at its own
    point, at the strand's rate `drag` (1/s), integrated implicitly in x and
    y: v <- (v + a u) / (1 + a), a = drag dt. The gas is z-invariant, so z is
    dragged toward 0 with the same factor;
  * a particle stands for `particle_mass` kg (strands carry no mass of their
    own), so its impulse is J = m (v_new - v);
  * two-way: -J goes to the gas through `MacFluid2.add_impulse`, which books
    it on the staggered faces so that sum(u) dx^2 changes by exactly -J_x.
    One-way: the gas is not touched.

`step(fluid, strands, gravity, bones, dt)`: drag with the gas at the start of
the step, the strands' own step with their drag switched off for that call
(it was applied here), then the gas step. Roots follow their bones and take no
drag. `gas_impulse` and `strand_impulse` sum what each side got (x and y).
"""

from geometry.vec import Real, Vec3
from physics.mac_fluid import MacFluid2
from physics.rigid6 import Pose6
from physics.strand import StrandSet


struct StrandGas2(Movable):
    var particle_mass: Real
    var two_way: Bool
    var strand_impulse: Tuple[Real, Real]
    var gas_impulse: Tuple[Real, Real]

    def __init__(out self, particle_mass: Real, two_way: Bool = True) raises:
        if not (particle_mass > 0):
            raise Error("StrandGas2: particle_mass must be > 0")
        self.particle_mass = particle_mass
        self.two_way = two_way
        self.strand_impulse = (Real(0), Real(0))
        self.gas_impulse = (Real(0), Real(0))

    def couple(mut self, mut fluid: MacFluid2, mut strands: StrandSet, dt: Real):
        """The drag exchange alone: strands take the drag impulse, the gas takes
        -J when two-way. Strands and gas do not move here."""
        var a = strands.drag * dt
        var sx = self.strand_impulse[0]
        var sy = self.strand_impulse[1]
        var gx = self.gas_impulse[0]
        var gy = self.gas_impulse[1]
        for s in range(len(strands.start)):
            for k in range(1, strands.count[s]):
                var i = strands.start[s] + k
                var p = strands.x[i]
                var g = fluid.velocity(p[0], p[1])
                var v = strands.v[i]
                var vn = Vec3((v[0] + a * g[0]) / (1 + a), (v[1] + a * g[1]) / (1 + a), v[2] / (1 + a), 0)
                var jx = (vn[0] - v[0]) * self.particle_mass
                var jy = (vn[1] - v[1]) * self.particle_mass
                strands.v[i] = vn
                sx += jx
                sy += jy
                if self.two_way:
                    fluid.add_impulse(p[0], p[1], -jx, -jy)
                    gx -= jx
                    gy -= jy
        self.strand_impulse = (sx, sy)
        self.gas_impulse = (gx, gy)

    def step(mut self, mut fluid: MacFluid2, mut strands: StrandSet, gravity: Vec3, bones: List[Pose6], dt: Real) raises:
        self.couple(fluid, strands, dt)
        var keep = strands.drag
        strands.drag = 0
        strands.step(dt, gravity, bones)
        strands.drag = keep
        fluid.step(dt)
