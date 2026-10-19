"""Coupler overhead per coupled step (ROADMAP 17.61): two one-dof masses
split across a spring (the parts of tests/test_coupler.mojo), so the time is
the schedule's own cost (interface lists, interpolation, Aitken passes),
next to the same system stepped monolithically."""

from std.benchmark import keep
from geometry.vec import Real
from diag.counters import Counters
from harness.bench import BenchTable, now
from physics.coupler import Coupler, CoupledPart, EXPLICIT, INTERP, ITERATED
from physics.state_io import StateWriter, StateReader


struct MassA(CoupledPart):
    var x: Real
    var v: Real
    var m: Real
    var k: Real
    var kc: Real
    var xb: Real
    var imp: Real
    var sx: Real
    var sv: Real
    var steps: Int
    var fail_at: Int  # advance number that turns the state NaN (-1: never)

    def __init__(out self, x: Real, m: Real, k: Real, kc: Real, fail_at: Int = -1):
        self.steps = 0
        self.fail_at = fail_at
        self.x = x
        self.v = 0
        self.m = m
        self.k = k
        self.kc = kc
        self.xb = 0
        self.imp = 0
        self.sx = 0
        self.sv = 0

    def advance(mut self, dt: Real) raises:
        var fc = self.kc * (self.xb - self.x)
        self.v += (fc - self.k * self.x) / self.m * dt
        self.x += self.v * dt
        self.imp = fc * dt
        self.steps += 1
        if self.steps == self.fail_at:
            var z = self.x - self.x
            self.x = z / z
            self.v = z / z

    def send(self) -> List[Real]:
        return [self.x]

    def recv(mut self, data: List[Real]):
        self.xb = data[0]

    def impulse(self) -> List[Real]:
        return [self.imp]

    def save(mut self):
        self.sx = self.x
        self.sv = self.v

    def restore(mut self):
        self.x = self.sx
        self.v = self.sv

    def write_state[W: StateWriter](self, mut w: W):
        w.wf(self.x)
        w.wf(self.v)
        w.wf(self.xb)
        w.wf(self.imp)
        w.wi(self.steps)

    def read_state[R: StateReader](mut self, mut r: R) raises:
        self.x = r.rf()
        self.v = r.rf()
        self.xb = r.rf()
        self.imp = r.rf()
        self.steps = r.ri()


struct MassB(CoupledPart):
    var x: Real
    var v: Real
    var m: Real
    var kc: Real
    var xa: Real
    var imp: Real
    var sx: Real
    var sv: Real

    def __init__(out self, x: Real, m: Real, kc: Real):
        self.x = x
        self.v = 0
        self.m = m
        self.kc = kc
        self.xa = 0
        self.imp = 0
        self.sx = 0
        self.sv = 0

    def advance(mut self, dt: Real) raises:
        var fc = -self.kc * (self.x - self.xa)
        self.v += fc / self.m * dt
        self.x += self.v * dt
        self.imp = fc * dt

    def send(self) -> List[Real]:
        return [self.x]

    def recv(mut self, data: List[Real]):
        self.xa = data[0]

    def impulse(self) -> List[Real]:
        return [self.imp]

    def save(mut self):
        self.sx = self.x
        self.sv = self.v

    def restore(mut self):
        self.x = self.sx
        self.v = self.sv

    def write_state[W: StateWriter](self, mut w: W):
        w.wf(self.x)
        w.wf(self.v)
        w.wf(self.xa)
        w.wf(self.imp)

    def read_state[R: StateReader](mut self, mut r: R) raises:
        self.x = r.rf()
        self.v = r.rf()
        self.xa = r.rf()
        self.imp = r.rf()


def main() raises:
    var t = BenchTable("Coupler, two masses, 20000 steps of 4 ms (17.61)")
    var counters = Counters()
    var steps = 20000
    for ratio in [1, 4, 16]:
        for sch in [EXPLICIT, INTERP, ITERATED]:
            var c = Coupler[MassA, MassB](MassA(0.1, 1.0, 100.0, 40.0), MassB(0.0, 0.01, 40.0), ratio, sch)
            var t0 = now()
            for _ in range(steps):
                c.step(4e-3, counters)
            var t1 = now()
            keep(c.b.x)
            var name = "explicit" if sch == EXPLICIT else ("interp" if sch == INTERP else "iterated")
            t.add(name + ", ratio " + String(ratio), steps, "step", t1 - t0, steps)
    # monolithic reference, B substepped 4x inline
    var xa = Real(0.1)
    var va = Real(0)
    var xb = Real(0)
    var vb = Real(0)
    var t0 = now()
    for _ in range(steps):
        var fa = 40.0 * (xb - xa)
        va += (fa - 100.0 * xa) * 4e-3
        xa += va * 4e-3
        for _ in range(4):
            var fb = -40.0 * (xb - xa)
            vb += fb / 0.01 * 1e-3
            xb += vb * 1e-3
    var t1 = now()
    keep(xb)
    t.add("monolithic loop, ratio 4", steps, "step", t1 - t0, steps)
    t.print_report()
