"""One stepping contract for continuum solvers (ROADMAP 17.55).

Before this module FEM, MPM, PBF and LBM each had their own step shape
(`step(dt, gravity, floor_y)`, `step(dt, gravity)`, `step(dt, gravity,
iters)`, `step()` in lattice units) and no shared failure policy or state
hooks. `ContinuumSolver` is that shared shape:

  * `advance(dt, gravity)`: advance by `dt` seconds;
  * `health()`: how many items are non-finite, outside the solver's
    domain, or left unconverged;
  * `quarantine()`: isolate the non-finite / escaped items (the solver's own
    policy, below) and return how many;
  * `write_state` / `read_state`: the dynamic state through
    `physics.state_io`, so a restored solver continues bit for bit.

`step_checked(solver, dt, gravity, counters)` is the failure policy every
caller gets: check and quarantine before and after `advance`, adding the
counts to `CONTINUUM_NAN` / `CONTINUUM_ESCAPED`, so nothing is frozen
silently.

Quarantine policies: FEM pins a non-finite node (inverse mass 0, velocity
0) at the position of a finite node of one of its tets (the origin if it
has none); MPM removes non-finite particles and particles whose 3-cell
stencil leaves the grid (they used to be skipped by P2G / G2P forever,
uncounted); PBF removes non-finite particles; LBM resets a cell with a
non-finite population to rest equilibrium (f_i = w_i).

`LbmContinuum` adapts `fluid.lbm.Lbm` (which cannot import `physics`,
`docs/ARCHITECTURE.md` §1) and does the unit conversion at the boundary:
one lattice step is `dt_lattice` seconds, and `advance(dt)` runs as many
lattice steps as fit, carrying the remainder.
"""

from std.math import isfinite
from geometry.vec import Real, Vec3
from diag.counters import Counters, CG_NOT_CONVERGED, CONTINUUM_NAN, CONTINUUM_ESCAPED
from fluid.lbm import Lbm
from fluid.d3q19 import Q
from .state_io import StateWriter, StateReader
from .fem import FemBody
from .mpm import MpmSolver, MpmParticle
from .pbf import PbfFluid


@fieldwise_init
struct ContinuumHealth(Copyable, ImplicitlyCopyable, Movable):
    var nonfinite: Int
    var escaped: Int
    var unconverged: Int


trait ContinuumSolver(Movable, Deinitable):
    def advance(mut self, dt: Real, gravity: Vec3): ...
    def health(self) -> ContinuumHealth: ...
    def quarantine(mut self) -> Int: ...
    def write_state[W: StateWriter](self, mut w: W): ...
    def read_state[R: StateReader](mut self, mut r: R) raises: ...


def _isolate[S: ContinuumSolver](mut s: S, mut counters: Counters) -> ContinuumHealth:
    var h = s.health()
    if h.nonfinite > 0 or h.escaped > 0:
        _ = s.quarantine()
        if h.nonfinite > 0:
            counters.incr(CONTINUUM_NAN, Int64(h.nonfinite))
        if h.escaped > 0:
            counters.incr(CONTINUUM_ESCAPED, Int64(h.escaped))
    return h


def step_checked[S: ContinuumSolver](mut s: S, dt: Real, gravity: Vec3, mut counters: Counters) -> ContinuumHealth:
    """Check and quarantine, advance, check and quarantine again, counting
    every isolated item. The check before the step matters: one non-finite
    particle reaching an MPM grid poisons every particle in that step (64 of
    64 in `test_continuum`), so state corrupted between steps is caught
    before it spreads; NaN produced inside a step can still spread through
    it. Returns the health found by the check before the step plus the one
    after it (before their quarantines)."""
    var pre = _isolate(s, counters)
    s.advance(dt, gravity)
    var post = _isolate(s, counters)
    return ContinuumHealth(pre.nonfinite + post.nonfinite, pre.escaped + post.escaped, post.unconverged)


def _fin3(v: Vec3) -> Bool:
    return isfinite(v[0]) and isfinite(v[1]) and isfinite(v[2])


# ------------------------------------------------------------------ FEM


def _fem_node_ok(b: FemBody, i: Int) -> Bool:
    return isfinite(b.x[i]) and isfinite(b.y[i]) and isfinite(b.z[i]) and isfinite(b.vx[i]) and isfinite(b.vy[i]) and isfinite(b.vz[i])


struct FemContinuum(ContinuumSolver):
    """`FemBody` under the contract (explicit `step` in `substeps`, or
    `step_implicit` with `implicit`; a floor at `floor_y`). In a scene,
    `FemContactPort` (`physics/fem_scene.mojo`) collides the nodes with the
    colliders; use the explicit path there: contact is applied outside the
    implicit solve, which hands back only m / (m + dt^2 k) of a light node's
    elastic impulse per step (1/29 for E = 3e5 at 1/60 s), so a box sinks
    into the block until it is compressed ~29x too far (measured 9 cm for
    an expected 3 mm)."""

    var body: FemBody
    var floor_y: Real
    var implicit: Bool
    var substeps: Int  # explicit steps per advance (stability: dt / substeps)

    def __init__(out self, var body: FemBody, floor_y: Real = -1e30, implicit: Bool = False, substeps: Int = 1):
        self.body = body^
        self.floor_y = floor_y
        self.implicit = implicit
        self.substeps = max(substeps, 1)

    def advance(mut self, dt: Real, gravity: Vec3):
        if self.implicit:
            _ = self.body.step_implicit(dt, gravity, self.floor_y, 1e-5, 400)
            return
        if self.substeps == 1:
            self.body.step(dt, gravity, self.floor_y)
            return
        var h = dt / Real(self.substeps)
        for _ in range(self.substeps):
            self.body.step(h, gravity, self.floor_y)

    def health(self) -> ContinuumHealth:
        var bad = 0
        for i in range(len(self.body.x)):
            if not _fem_node_ok(self.body, i):
                bad += 1
        return ContinuumHealth(bad, 0, Int(self.body.counters.get(CG_NOT_CONVERGED)))

    def quarantine(mut self) -> Int:
        var n = 0
        for i in range(len(self.body.x)):
            if _fem_node_ok(self.body, i):
                continue
            var px = Real(0)
            var py = Real(0)
            var pz = Real(0)
            var found = False
            for t in self.body.tets:
                if found:
                    break
                if t.a != i and t.b != i and t.c != i and t.d != i:
                    continue
                var ns: List[Int] = [t.a, t.b, t.c, t.d]
                for j in ns:
                    if j != i and _fem_node_ok(self.body, j):
                        px = self.body.x[j]
                        py = self.body.y[j]
                        pz = self.body.z[j]
                        found = True
                        break
            self.body.x[i] = px
            self.body.y[i] = py
            self.body.z[i] = pz
            self.body.vx[i] = 0
            self.body.vy[i] = 0
            self.body.vz[i] = 0
            self.body.inv_m[i] = 0
            n += 1
        return n

    def write_state[W: StateWriter](self, mut w: W):
        w.wi(len(self.body.x))
        for i in range(len(self.body.x)):
            w.wf(self.body.x[i])
            w.wf(self.body.y[i])
            w.wf(self.body.z[i])
            w.wf(self.body.vx[i])
            w.wf(self.body.vy[i])
            w.wf(self.body.vz[i])
            w.wf(self.body.inv_m[i])

    def read_state[R: StateReader](mut self, mut r: R) raises:
        var n = r.ri()
        if n != len(self.body.x):
            raise Error("FemContinuum.read_state: node count differs from this mesh")
        for i in range(n):
            self.body.x[i] = r.rf()
            self.body.y[i] = r.rf()
            self.body.z[i] = r.rf()
            self.body.vx[i] = r.rf()
            self.body.vy[i] = r.rf()
            self.body.vz[i] = r.rf()
            self.body.inv_m[i] = r.rf()


# ------------------------------------------------------------------ MPM


def _mpm_escaped(s: MpmSolver, q: MpmParticle) -> Bool:
    """The test MPM's P2G / G2P use to skip a particle."""
    var inv_dx = 1.0 / s.dx
    var bx = Int((q.x[0] - s.lo[0]) * inv_dx - 0.5)
    var by = Int((q.x[1] - s.lo[1]) * inv_dx - 0.5)
    var bz = Int((q.x[2] - s.lo[2]) * inv_dx - 0.5)
    return bx < 0 or by < 0 or bz < 0 or bx + 2 >= s.n or by + 2 >= s.n or bz + 2 >= s.n


struct MpmContinuum(ContinuumSolver):
    var mpm: MpmSolver

    def __init__(out self, var mpm: MpmSolver):
        self.mpm = mpm^

    def advance(mut self, dt: Real, gravity: Vec3):
        self.mpm.step(dt, gravity)

    def health(self) -> ContinuumHealth:
        var bad = 0
        var out = 0
        for ref q in self.mpm.p:
            if not (_fin3(q.x) and _fin3(q.v)):
                bad += 1
            elif _mpm_escaped(self.mpm, q):
                out += 1
        return ContinuumHealth(bad, out, 0)

    def quarantine(mut self) -> Int:
        var keep = List[MpmParticle](capacity=len(self.mpm.p))
        var n = 0
        for ref q in self.mpm.p:
            if _fin3(q.x) and _fin3(q.v) and not _mpm_escaped(self.mpm, q):
                keep.append(q)
            else:
                n += 1
        self.mpm.p = keep^
        return n

    def write_state[W: StateWriter](self, mut w: W):
        w.wi(len(self.mpm.p))
        for ref q in self.mpm.p:
            w.wv(q.x)
            w.wv(q.v)
            for k in range(9):
                w.wf(q.f.m[k])
            for k in range(9):
                w.wf(q.c.m[k])
            w.wf(q.vol)
            w.wf(q.mass)

    def read_state[R: StateReader](mut self, mut r: R) raises:
        var n = r.ri()
        if n < 0 or n > len(self.mpm.p):
            raise Error("MpmContinuum.read_state: particle count out of range")
        var ps = List[MpmParticle](capacity=n)
        for k in range(n):
            var q = self.mpm.p[k]
            q.x = r.rv()
            q.v = r.rv()
            for c in range(9):
                q.f.m[c] = r.rf()
            for c in range(9):
                q.c.m[c] = r.rf()
            q.vol = r.rf()
            q.mass = r.rf()
            ps.append(q)
        self.mpm.p = ps^


# ------------------------------------------------------------------ PBF


struct PbfContinuum(ContinuumSolver):
    var pbf: PbfFluid
    var iters: Int

    def __init__(out self, var pbf: PbfFluid, iters: Int = 3):
        self.pbf = pbf^
        self.iters = iters

    def advance(mut self, dt: Real, gravity: Vec3):
        self.pbf.step(dt, gravity, self.iters)

    def _ok(self, i: Int) -> Bool:
        return isfinite(self.pbf.x[i]) and isfinite(self.pbf.y[i]) and isfinite(self.pbf.z[i]) and isfinite(self.pbf.vx[i]) and isfinite(self.pbf.vy[i]) and isfinite(self.pbf.vz[i])

    def health(self) -> ContinuumHealth:
        var bad = 0
        for i in range(len(self.pbf.x)):
            if not self._ok(i):
                bad += 1
        return ContinuumHealth(bad, 0, 0)

    def quarantine(mut self) -> Int:
        var n = 0
        var i = len(self.pbf.x) - 1
        while i >= 0:
            if not self._ok(i):
                _ = self.pbf.x.pop(i)
                _ = self.pbf.y.pop(i)
                _ = self.pbf.z.pop(i)
                _ = self.pbf.vx.pop(i)
                _ = self.pbf.vy.pop(i)
                _ = self.pbf.vz.pop(i)
                _ = self.pbf.px.pop(i)
                _ = self.pbf.py.pop(i)
                _ = self.pbf.pz.pop(i)
                _ = self.pbf.lam.pop(i)
                n += 1
            i -= 1
        return n

    def write_state[W: StateWriter](self, mut w: W):
        w.wi(len(self.pbf.x))
        for i in range(len(self.pbf.x)):
            w.wf(self.pbf.x[i])
            w.wf(self.pbf.y[i])
            w.wf(self.pbf.z[i])
            w.wf(self.pbf.vx[i])
            w.wf(self.pbf.vy[i])
            w.wf(self.pbf.vz[i])

    def read_state[R: StateReader](mut self, mut r: R) raises:
        var n = r.ri()
        if n != len(self.pbf.x):
            raise Error("PbfContinuum.read_state: particle count differs")
        for i in range(n):
            self.pbf.x[i] = r.rf()
            self.pbf.y[i] = r.rf()
            self.pbf.z[i] = r.rf()
            self.pbf.vx[i] = r.rf()
            self.pbf.vy[i] = r.rf()
            self.pbf.vz[i] = r.rf()


# ------------------------------------------------------------------ LBM


struct LbmContinuum(ContinuumSolver):
    """`Lbm` under the contract: one lattice step = `dt_lattice` seconds.
    Gravity is not applied (an LBM body force is set on the lattice itself,
    `Lbm.fx` / `fy` / `fz`, in lattice units)."""

    var lbm: Lbm
    var dt_lattice: Real
    var carry: Real
    var steps_run: Int

    def __init__(out self, var lbm: Lbm, dt_lattice: Real) raises:
        if not (dt_lattice > 0):
            raise Error("LbmContinuum: dt_lattice must be > 0")
        self.lbm = lbm^
        self.dt_lattice = dt_lattice
        self.carry = 0
        self.steps_run = 0

    def advance(mut self, dt: Real, gravity: Vec3):
        self.carry += dt
        while self.carry >= self.dt_lattice:
            self.lbm.step()
            self.carry -= self.dt_lattice
            self.steps_run += 1

    def _cell_ok(self, c: Int) -> Bool:
        for i in range(Q):
            if not isfinite(self.lbm.at(i, c)):
                return False
        return True

    def health(self) -> ContinuumHealth:
        var bad = 0
        for c in range(self.lbm.cells()):
            if not self._cell_ok(c):
                bad += 1
        return ContinuumHealth(bad, 0, 0)

    def quarantine(mut self) -> Int:
        var n = 0
        for c in range(self.lbm.cells()):
            if not self._cell_ok(c):
                for i in range(Q):
                    self.lbm.set_at(i, c, self.lbm.w[i])
                n += 1
        return n

    def write_state[W: StateWriter](self, mut w: W):
        w.wi(len(self.lbm.f))
        for k in range(len(self.lbm.f)):
            w.wf(self.lbm.f[k])
        w.wf(self.carry)
        w.wi(self.steps_run)

    def read_state[R: StateReader](mut self, mut r: R) raises:
        var n = r.ri()
        if n != len(self.lbm.f):
            raise Error("LbmContinuum.read_state: lattice size differs")
        for k in range(n):
            self.lbm.f[k] = r.rf()
        self.carry = r.rf()
        self.steps_run = r.ri()
