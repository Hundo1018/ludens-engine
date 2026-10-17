"""Hair strands <-> lattice air, two-way (ROADMAP 17.61: strands' reaction
on the LBM flow).

`StrandAir` owns an `Lbm` like `ClothAir` (same lattice conventions:
`lattice_corners`, `lattice_velocity`, `lattice_momentum`) and couples a
`StrandSet` through its particles:

  * each non-root particle gets drag toward the local air velocity u at
    the strand's own rate `drag` (1/s, the `StrandSet.drag` model, now
    with u from the lattice instead of a uniform wind), integrated
    implicitly: v <- (v + a u) / (1 + a), a = drag dt;
  * a particle stands for `particle_mass` kg (strands carry no mass of
    their own), so its impulse is J = m (v_new - v);
  * two-way: -J goes to the 8 cells around the particle (trilinear), as
    `ClothAir` does; one-way: the air is not touched.

`step(strands, gravity, bones)`: drag with the air at the start of the
step, the strands' own step with their drag switched off for that call
(it was applied here), the lattice step. Roots follow their bones and
take no drag. `air_impulse` / `strand_impulse` sum what each side got.
"""

from geometry.vec import Real, Vec3
from .rigid6 import Pose6
from fluid.lbm import Lbm
from .strand import StrandSet
from .cloth_air import lattice_corners, lattice_velocity, lattice_momentum


struct StrandAir(Movable):
    var lbm: Lbm
    var origin: Vec3
    var dx: Real
    var dt: Real
    var rho: Real
    var particle_mass: Real
    var two_way: Bool
    var strand_impulse: Vec3
    var air_impulse: Vec3

    def __init__(out self, var lbm: Lbm, origin: Vec3, dx: Real, dt: Real, rho: Real, particle_mass: Real, two_way: Bool = True) raises:
        if not (dx > 0) or not (dt > 0) or not (rho > 0) or not (particle_mass > 0):
            raise Error("StrandAir: dx, dt, rho and particle_mass must be > 0")
        self.lbm = lbm^
        self.origin = origin
        self.dx = dx
        self.dt = dt
        self.rho = rho
        self.particle_mass = particle_mass
        self.two_way = two_way
        self.strand_impulse = Vec3(0, 0, 0, 0)
        self.air_impulse = Vec3(0, 0, 0, 0)

    def air_velocity(self, p: Vec3) -> Vec3:
        return lattice_velocity(self.lbm, self.origin, self.dx, self.dt, p)

    def air_momentum(self) -> Vec3:
        return lattice_momentum(self.lbm, self.rho, self.dx, self.dt)

    def step(mut self, mut strands: StrandSet, gravity: Vec3, bones: List[Pose6]):
        self.lbm.clear_cell_force()
        var a = strands.drag * self.dt
        var to_lat = self.dt / (self.rho * self.dx * self.dx * self.dx * self.dx)
        for s in range(len(strands.start)):
            for k in range(1, strands.count[s]):
                var i = strands.start[s] + k
                var u = self.air_velocity(strands.x[i])
                var vn = (strands.v[i] + u * a) * (1 / (1 + a))
                var j = (vn - strands.v[i]) * self.particle_mass
                strands.v[i] = vn
                self.strand_impulse = self.strand_impulse + j
                if self.two_way:
                    self.air_impulse = self.air_impulse - j
                    var cw = lattice_corners(self.lbm, self.origin, self.dx, strands.x[i])
                    var cs = cw[0].copy()
                    var ws = cw[1].copy()
                    for q in range(8):
                        self.lbm.add_cell_force(cs[q], j * (-to_lat * ws[q]))
        var keep = strands.drag
        strands.drag = 0
        strands.step(self.dt, gravity, bones)
        strands.drag = keep
        self.lbm.step()
