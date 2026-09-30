"""Physics LOD and a simulation budget (ROADMAP 17.31).

Two knobs, both on machinery the solver already has:

  `DistanceLOD`  freezes bodies farther than `radius` from an observer and
                 unfreezes them when it comes back within `radius -
                 hysteresis` (`ContactScene6.freeze`: temporarily static,
                 velocity kept, so a body resumes exactly where it stopped
                 -- no pop, no penetration jump)
  `SimBudget`    moves the solver's iterations and substeps between a floor
                 and a ceiling from the measured cost of the last step:
                 above the target it degrades (iterations first, then
                 substeps), comfortably below it restores (substeps first);
                 between the two thresholds it holds, so a steady load does
                 not oscillate

At full quality -- nothing frozen, the budget at its ceiling -- stepping is
the plain `ContactScene6.step` with the caller's config (the seam parity).
"""

from geometry.vec import Real, Vec3, dot
from .rigid6 import Body6
from .solver6 import ContactScene6
from .solver_config import SolverConfig


struct DistanceLOD(Copyable, Movable):
    var radius: Real
    var hysteresis: Real

    def __init__(out self, radius: Real, hysteresis: Real = 1):
        self.radius = radius
        self.hysteresis = hysteresis

    def update[B: Body6](self, mut sc: ContactScene6[B], observer: Vec3) raises -> Int:
        """Freeze / unfreeze by distance; returns how many bodies are frozen."""
        var frozen = 0
        for i in range(len(sc.bset.bodies)):
            if sc.bset.is_removed(i):
                continue
            var is_f = sc.bset.frozen_motion[i] >= 0
            if not is_f and not sc.bset.moves(i):
                continue
            var d = sc.bset.bodies[i].position() - observer
            var dist2 = dot(d, d)
            var id = sc.bset.id_of(i)
            if not is_f and dist2 > (self.radius + self.hysteresis) * (self.radius + self.hysteresis):
                sc.freeze(id)
                is_f = True
            elif is_f and dist2 < self.radius * self.radius:
                sc.unfreeze(id)
                is_f = False
            if is_f:
                frozen += 1
        return frozen


struct SimBudget(Copyable, Movable):
    var target_ns: Int
    var min_iters: Int
    var max_iters: Int
    var min_substeps: Int
    var max_substeps: Int
    var iters: Int
    var substeps: Int

    def __init__(
        out self, target_ns: Int, min_iters: Int = 1, max_iters: Int = 4,
        min_substeps: Int = 1, max_substeps: Int = 4,
    ):
        self.target_ns = target_ns
        self.min_iters = min_iters
        self.max_iters = max_iters
        self.min_substeps = min_substeps
        self.max_substeps = max_substeps
        self.iters = max_iters
        self.substeps = max_substeps

    def update(mut self, measured_ns: Int):
        """Degrade above 110% of the target, restore below 70%, else hold."""
        if measured_ns * 10 > self.target_ns * 11:
            if self.iters > self.min_iters:
                self.iters -= 1
            elif self.substeps > self.min_substeps:
                self.substeps -= 1
        elif measured_ns * 10 < self.target_ns * 7:
            if self.substeps < self.max_substeps:
                self.substeps += 1
            elif self.iters < self.max_iters:
                self.iters += 1

    def apply(self, mut cfg: SolverConfig):
        cfg.iters = self.iters
        cfg.substeps = self.substeps
