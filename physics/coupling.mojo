"""Continuum <-> rigid coupling ports and the coupled tick (ROADMAP 17.55).

A `ContinuumSolver` (`physics.continuum`) advances on its own; a
`CouplingPort` says how it meets the rigid scene. A port names its solver
type (`comptime S`) and has two halves per tick:

  * `before`: rigid state into the continuum (e.g. a body's pose and
    velocity as a moving boundary of the lattice);
  * `after`: the continuum's loads back onto the bodies (forces and
    torques, applied with the scene's accumulators).

`couple_step` fixes the order every coupled tick uses -- port.before,
the continuum's checked step (`step_checked`: health check, quarantine,
counters), port.after, then the rigid step with the same dt -- so two
solvers coupled through different ports run in one documented order
instead of each caller choosing one. `OneWay[S]` is the port that
exchanges nothing (a continuum that only reads the scene, or none at all).
"""

from geometry.vec import Real, Vec3
from diag.counters import Counters
from .rigid6 import Body6
from .solver6 import ContactScene6
from .solver_config import SolverConfig
from .continuum import ContinuumSolver, ContinuumHealth, step_checked


trait CouplingPort(Movable):
    comptime S: ContinuumSolver

    def before[B: Body6](mut self, mut scene: ContactScene6[B], mut s: Self.S, dt: Real, gravity: Vec3) raises: ...

    def after[B: Body6](mut self, mut scene: ContactScene6[B], mut s: Self.S, dt: Real, gravity: Vec3) raises: ...


struct OneWay[Solver: ContinuumSolver](CouplingPort):
    """No exchange: the continuum steps beside the scene."""

    comptime S = Self.Solver

    def __init__(out self):
        pass

    def before[B: Body6](mut self, mut scene: ContactScene6[B], mut s: Self.S, dt: Real, gravity: Vec3) raises:
        pass

    def after[B: Body6](mut self, mut scene: ContactScene6[B], mut s: Self.S, dt: Real, gravity: Vec3) raises:
        pass


def couple_step[P: CouplingPort, B: Body6](
    mut scene: ContactScene6[B],
    mut port: P,
    mut s: P.S,
    dt: Real,
    gravity: Vec3,
    cfg: SolverConfig,
    mut counters: Counters,
) raises -> ContinuumHealth:
    """One coupled tick: `port.before`, the continuum's checked step,
    `port.after`, the rigid step. Returns what `step_checked` found (the
    checks before and after the continuum's step, before quarantine)."""
    port.before(scene, s, dt, gravity)
    var h = step_checked(s, dt, gravity, counters)
    port.after(scene, s, dt, gravity)
    scene.step(dt, gravity, cfg)
    return h
