# tier: integration
"""`physics.coupler.Coupler` on two masses split across a spring (17.61).

A: mass mA on a wall spring kA; B: mass mB tied to A by a spring kc. A
and B are separate solvers (symplectic Euler each) that only see the
other's position through the coupler. Exact energy
E = mA vA^2 / 2 + kA xA^2 / 2 + mB vB^2 / 2 + kc (xB - xA)^2 / 2; the
monolithic reference steps both masses together at dt / ratio.
"""

from std.math import isfinite, sqrt
from harness.runner import Suite
from geometry.vec import Real
from diag.counters import Counters, COUPLING_REJECTED
from physics.coupler import Coupler, CoupledPart, EXPLICIT, INTERP, ITERATED
from physics.state_io import StateWriter, StateReader
from physics.serialize import BinWriter, BinReader


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


def energy(a: MassA, b: MassB) -> Real:
    var d = b.x - a.x
    return 0.5 * a.m * a.v * a.v + 0.5 * a.k * a.x * a.x + 0.5 * b.m * b.v * b.v + 0.5 * a.kc * d * d


def make(kc: Real, ratio: Int, scheme: Int) raises -> Coupler[MassA, MassB]:
    # A: 1 kg on 100 N/m; B: 0.01 kg on kc. Start: A displaced 0.1 m, B at rest at 0.
    return Coupler[MassA, MassB](MassA(0.1, 1.0, 100.0, kc), MassB(0.0, 0.01, kc), ratio, scheme)


def run(mut c: Coupler[MassA, MassB], dt: Real, steps: Int, mut counters: Counters) raises:
    for _ in range(steps):
        c.step(dt, counters)


def monolithic(kc: Real, h: Real, steps: Int) -> Real:
    """Energy after `steps` monolithic symplectic-Euler steps of size h."""
    var xa = Real(0.1)
    var va = Real(0)
    var xb = Real(0)
    var vb = Real(0)
    for _ in range(steps):
        var fc = kc * (xb - xa)
        va += (fc - 100.0 * xa) / 1.0 * h
        vb += -fc / 0.01 * h
        xa += va * h
        xb += vb * h
    var d = xb - xa
    return 0.5 * va * va + 0.5 * 100.0 * xa * xa + 0.5 * 0.01 * vb * vb + 0.5 * kc * d * d


def worst_energy(kc: Real, ratio: Int, scheme: Int, steps: Int, mut counters: Counters) raises -> Real:
    """Largest |E / E0 - 1| over `steps` steps of 4 ms."""
    var c = make(kc, ratio, scheme)
    var e0 = energy(c.a, c.b)
    var worst = Real(0)
    for _ in range(steps):
        c.step(4e-3, counters)
        worst = max(worst, abs(energy(c.a, c.b) / e0 - 1))
    return worst


def nan_case(mut s: Suite, mut counters: Counters) raises:
    """One side NaN: B keeps the last finite data and continues, counter moves."""
    var n = Coupler[MassA, MassB](MassA(0.1, 1.0, 100.0, 400.0, fail_at=101), MassB(0.0, 0.01, 400.0), 4, INTERP)
    run(n, 1e-3, 100, counters)
    var before = counters.get(COUPLING_REJECTED)
    var xa_last = n.a.x
    run(n, 1e-3, 100, counters)
    print("NaN in A: rejected", counters.get(COUPLING_REJECTED) - before, " B holds xA", n.b.xa, "(last finite", xa_last, ")")
    s.check(counters.get(COUPLING_REJECTED) - before >= 100, "non-finite A data rejected every step and counted")
    s.check(isfinite(n.b.x) and isfinite(n.b.v) and n.b.xa == xa_last, "B continues on A's last finite data")


def main() raises:
    var s = Suite("coupler")
    var counters = Counters()

    # ratio 1: INTERP is EXPLICIT exactly
    var ce = make(400.0, 1, EXPLICIT)
    var ci = make(400.0, 1, INTERP)
    run(ce, 1e-3, 2000, counters)
    run(ci, 1e-3, 2000, counters)
    s.check(ce.a.x == ci.a.x and ce.b.x == ci.b.x and ce.b.v == ci.b.v, "ratio 1: INTERP == EXPLICIT bit for bit")

    # weak coupling: the three schemes agree (amplitude 0.1 m)
    var w0 = make(1e-3, 4, EXPLICIT)
    var w1 = make(1e-3, 4, INTERP)
    var w2 = make(1e-3, 4, ITERATED)
    run(w0, 1e-3, 2000, counters)
    run(w1, 1e-3, 2000, counters)
    run(w2, 1e-3, 2000, counters)
    var da = max(abs(w0.a.x - w1.a.x), abs(w0.a.x - w2.a.x))
    var db = max(abs(w0.b.x - w1.b.x), abs(w0.b.x - w2.b.x))
    print("weak coupling (kc 1e-3, 2 s): max |dxA|", da, " |dxB|", db)
    s.check(da < 1e-6 and db < 1e-5, "weak coupling: schemes agree (A < 1e-6 m, B < 1e-5 m)")

    # consistency: the gap between schemes shrinks with dt (kc 40, 0.5 s)
    var gaps = List[Real]()
    for dt in [Real(2e-3), Real(1e-3), Real(5e-4)]:
        var steps = Int(0.5 / dt + 0.5)
        var g0 = make(40.0, 4, EXPLICIT)
        var g1 = make(40.0, 4, INTERP)
        var g2 = make(40.0, 4, ITERATED)
        run(g0, dt, steps, counters)
        run(g1, dt, steps, counters)
        run(g2, dt, steps, counters)
        gaps.append(max(abs(g0.b.x - g1.b.x), abs(g0.b.x - g2.b.x), abs(g1.b.x - g2.b.x)))
    print("max |dxB| between schemes, dt 2 / 1 / 0.5 ms:", gaps[0], gaps[1], gaps[2])
    s.check(gaps[1] < 0.6 * gaps[0] and gaps[2] < 0.6 * gaps[1], "schemes converge to each other as dt halves")

    # B substepped: worst energy error over 2 s, held vs interpolated data
    print("dt 4 ms, 2 s, worst |E/E0 - 1|:  kc | ratio | explicit | interp | iterated")
    var worse = 0
    for kc in [Real(400.0), Real(40.0)]:
        for ratio in [2, 4, 8, 16]:
            var d0 = worst_energy(kc, ratio, EXPLICIT, 500, counters)
            var d1 = worst_energy(kc, ratio, INTERP, 500, counters)
            var d2 = worst_energy(kc, ratio, ITERATED, 500, counters)
            print("  ", kc, "|", ratio, "|", d0, "|", d1, "|", d2)
            if not (d1 < d0):
                worse += 1
    s.check(worse == 0, "ratio 2..16: interpolated substeps change the energy less than held data")

    # ITERATED reaches its fixed point
    var it = make(400.0, 4, ITERATED)
    var most = 0
    for _ in range(100):
        it.step(4e-3, counters)
        most = max(most, it.iterations)
    print("ITERATED: most passes per step", most, "of", it.max_iters)
    s.check(most < it.max_iters, "ITERATED converges within its pass budget")

    # conservation diagnostic: imbalance shrinks with dt (first order)
    var i1 = make(400.0, 4, INTERP)
    var i2 = make(400.0, 4, INTERP)
    run(i1, 4e-3, 250, counters)
    run(i2, 2e-3, 500, counters)
    print("interface impulse imbalance, max per step: dt 4 ms", i1.max_imbalance, " dt 2 ms", i2.max_imbalance)
    s.check(i1.max_imbalance > 0 and i2.max_imbalance < 0.6 * i1.max_imbalance, "imbalance > 0 and drops with dt")

    nan_case(s, counters)

    # substep ratio 1000:1 runs and stays bounded
    var big = worst_energy(400.0, 1000, INTERP, 50, counters)
    print("ratio 1000:1, 0.2 s: worst |E/E0 - 1|", big)
    s.check(isfinite(big) and big < 1, "ratio 1000:1: finite, energy within 100 %")

    # bad arguments raise
    var raised = 0
    try:
        _ = make(400.0, 0, EXPLICIT)
    except:
        raised += 1
    try:
        _ = make(400.0, 1, 7)
    except:
        raised += 1
    s.check(raised == 2, "ratio < 1 and unknown scheme raise")

    # snapshot: a coupler restored from bytes continues bit for bit
    for scheme in [EXPLICIT, INTERP, ITERATED]:
        var live = make(400.0, 4, scheme)
        run(live, 2e-3, 60, counters)
        var w = BinWriter()
        live.write_state(w)
        run(live, 2e-3, 60, counters)
        var back = make(400.0, 4, scheme)
        var r = BinReader(w.b.copy())
        back.read_state(r)
        run(back, 2e-3, 60, counters)
        s.check(
            back.a.x == live.a.x and back.b.x == live.b.x and back.b.v == live.b.v
            and back.max_imbalance == live.max_imbalance,
            "snapshot after 60 steps, 60 more: same as uninterrupted (scheme " + String(scheme) + ")",
        )
    var other = make(400.0, 2, EXPLICIT)
    var ws = BinWriter()
    make(400.0, 4, EXPLICIT).write_state(ws)
    var bad_schedule = False
    try:
        var r2 = BinReader(ws.b.copy())
        other.read_state(r2)
    except:
        bad_schedule = True
    s.check(bad_schedule, "a snapshot of another schedule (ratio 4 into ratio 2) raises")
    s.finish()
