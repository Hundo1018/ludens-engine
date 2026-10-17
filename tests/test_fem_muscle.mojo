# tier: integration
"""Volumetric muscle on FEM tets (ROADMAP 17.57, `FemBody.set_fibers`,
`activation`, `step_ext`).

  1. Ordinary: a free 0.6 x 0.2 x 0.2 m block (E = 1e5, nu = 0.45, zero
     gravity) with fibres along x: at activation 1 it shortens along x
     (> 10 %) and bulges across (its y-z extent grows); its volume drops
     3.7 % (nu 0.45 linear co-rotational at 17 % strain is not
     incompressible), asserted < 5 %. At activation 0 the body moves exactly
     as one without fibres (bit for bit).
  2. Integration: the same muscle pinned at x = 0 pulls its free end toward
     the pin, more at higher activation (0.25 < 0.5 < 1, printed), and the
     shortening grows with sigma_max; plasticity and fibres together run in
     one `step_ext`.
  3. Extreme: one direction per tet is required, a zero direction and
     sigma_max < 0 raise; activation outside [0, 1] is clamped (1.5 acts as
     1, bit for bit).
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.fem import FemBody, make_beam

comptime DT: Real = 1.0 / 4000.0


def _muscle(act: Real, sigma: Real, pin: Bool) raises -> FemBody:
    var b = FemBody(1.0e5, 0.45, 20.0)
    make_beam(b, 6, 2, 2, 0.1, 0.1)
    var dirs = List[Vec3]()
    for _ in range(len(b.tets)):
        dirs.append(Vec3(1, 0, 0, 0))
    b.set_fibers(dirs, sigma)
    b.activation = act
    if pin:
        for i in range(b.node_count()):
            if b.pos(i)[0] < 1e-6:
                b.pin(i)
    return b^


def _extent(b: FemBody, axis: Int) -> Real:
    var lo = Real(1e30)
    var hi = Real(-1e30)
    for i in range(b.node_count()):
        lo = min(lo, b.pos(i)[axis])
        hi = max(hi, b.pos(i)[axis])
    return hi - lo


def _run(mut b: FemBody, steps: Int):
    for _ in range(steps):
        b.step_ext(DT, Vec3(0, 0, 0, 0))


def main() raises:
    var s = Suite("fem_muscle")
    var rest = _muscle(0, 2e4, False)
    var v0 = rest.total_volume()
    var lx0 = _extent(rest, 0)
    var ly0 = _extent(rest, 1)
    var on = _muscle(1, 2e4, False)
    _run(on, 4000)
    var off = _muscle(0, 2e4, False)
    _run(off, 4000)
    var short = 1 - _extent(on, 0) / lx0
    print("  free muscle, 1 s at activation 1: length", _extent(on, 0), "of", lx0, "(", short * 100, "% shorter)  width", _extent(on, 1), "of", ly0, " volume", on.total_volume(), "of", v0)
    s.check(short > 0.1 and _extent(on, 1) > ly0 and abs(on.total_volume() / v0 - 1) < 0.05, "contracts along the fibres, bulges across, volume within 5 %")
    var plain = FemBody(1.0e5, 0.45, 20.0)
    make_beam(plain, 6, 2, 2, 0.1, 0.1)
    for _ in range(4000):
        plain.step(DT, Vec3(0, 0, 0, 0))
    var still = True
    for i in range(off.node_count()):
        still = still and off.pos(i)[0] == plain.pos(i)[0] and off.pos(i)[1] == plain.pos(i)[1]
    s.check(still, "activation 0: exactly a body without fibres")

    var tips = List[Real]()
    for act in [Real(0.25), Real(0.5), Real(1.0)]:
        var m = _muscle(act, 2e4, True)
        _run(m, 4000)
        tips.append(_extent(m, 0))
    var strong = _muscle(1, 4e4, True)
    _run(strong, 4000)
    print("  pinned muscle length at activation 0.25 / 0.5 / 1:", tips[0], tips[1], tips[2], ";  sigma_max doubled:", _extent(strong, 0))
    s.check(tips[0] > tips[1] and tips[1] > tips[2] and _extent(strong, 0) < tips[2], "more activation or peak stress, more shortening")
    var both = _muscle(1, 2e4, True)
    both.set_plasticity(0.05, 0.5, 0.3)
    _run(both, 400)
    s.check(_extent(both, 0) < lx0 and len(both.plastic) == 6 * len(both.tets), "plasticity and fibres together in step_ext")

    var raised = 0
    var b = _muscle(0, 1e4, False)
    var few = List[Vec3]()
    few.append(Vec3(1, 0, 0, 0))
    try:
        b.set_fibers(few, 1e4)
    except:
        raised += 1
    var zeros = List[Vec3]()
    for _ in range(len(b.tets)):
        zeros.append(Vec3(0, 0, 0, 0))
    try:
        b.set_fibers(zeros, 1e4)
    except:
        raised += 1
    var ones = List[Vec3]()
    for _ in range(len(b.tets)):
        ones.append(Vec3(1, 0, 0, 0))
    try:
        b.set_fibers(ones, -1)
    except:
        raised += 1
    s.check(raised == 3, "wrong direction count, a zero direction and sigma_max < 0 raise")
    var over = _muscle(1.5, 2e4, False)
    var one = _muscle(1.0, 2e4, False)
    _run(over, 200)
    _run(one, 200)
    s.check(over.pos(5)[0] == one.pos(5)[0], "activation 1.5 acts as 1")
    s.finish()
