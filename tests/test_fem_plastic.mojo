# tier: integration
"""FEM plasticity and element-removal fracture (ROADMAP 17.58,
`FemBody.set_plasticity` / `plastic_flow` / `remove_overstrained`).

  1. Ordinary: a 1 m cantilever (x = 0 face pinned, E = 1e7, dt 1/2400) sags under
     10x gravity for 2 s, then the load is removed for 3 s. Purely elastic
     it springs back (tip offset < 1 mm); with plasticity (yield strain
     0.005, creep 0.5) it keeps a permanent bend (tip offset > 2 cm,
     printed). With plasticity off the forces are the old ones (the FEM
     tests' golden sections are unchanged).
  2. Integration: a 1 m bar, both end faces held and pulled apart at 1 m/s:
     with `remove_overstrained(0.3)` after each step, elements break in
     the middle, the bar's tet graph splits into two pieces and every
     removed tet is counted; without removal it only stretches.
  3. Extreme: bad plasticity parameters and max_strain <= 0 raise; a body
     with no tets removes nothing.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.fem import FemBody, make_beam

comptime DT: Real = 1.0 / 2400.0


def _cantilever() -> FemBody:
    var b = FemBody(1.0e7, 0.3, 4.0)
    make_beam(b, 10, 2, 2, 0.1, 0.5)
    for i in range(b.node_count()):
        if b.pos(i)[0] < 1e-6:
            b.pin(i)
    return b^


def _tip_nodes(b: FemBody) -> List[Int]:
    """The x = 1 m face, chosen at rest."""
    var out = List[Int]()
    for i in range(b.node_count()):
        if b.pos(i)[0] > 0.99:
            out.append(i)
    return out^


def _tip_y(b: FemBody, tip: List[Int]) -> Real:
    var acc = Real(0)
    for i in tip:
        acc += b.pos(i)[1]
    return acc / Real(len(tip))


def _bend(plastic: Bool) raises -> Tuple[Real, Real]:
    """(loaded sag, tip offset after unloading) of the tip centre."""
    var b = _cantilever()
    if plastic:
        b.set_plasticity(0.005, 0.5, 0.2)
    var tip = _tip_nodes(b)
    var rest = _tip_y(b, tip)
    for _ in range(4800):
        b.step(DT, Vec3(0, -98, 0, 0))
    var sag = rest - _tip_y(b, tip)
    for _ in range(7200):
        b.step(DT, Vec3(0, 0, 0, 0))
    return (sag, rest - _tip_y(b, tip))


def _pieces(b: FemBody) -> Int:
    """Connected components of the tet graph (nodes in no tet ignored)."""
    var n = b.node_count()
    var parent = List[Int](length=n, fill=-1)
    for i in range(n):
        parent[i] = i

    for t in b.tets:
        var ids: List[Int] = [t.a, t.b, t.c, t.d]
        for k in range(1, 4):
            var x = ids[0]
            while parent[x] != x:
                x = parent[x]
            var y = ids[k]
            while parent[y] != y:
                y = parent[y]
            if x != y:
                parent[y] = x
    var used = List[Bool](length=n, fill=False)
    for t in b.tets:
        used[t.a] = True
        used[t.b] = True
        used[t.c] = True
        used[t.d] = True
    var roots = 0
    for i in range(n):
        if used[i] and parent[i] == i:
            roots += 1
    return roots


def _pull(remove: Bool) raises -> Tuple[Int, Int, Real]:
    """(tets removed, pieces, end-to-end length) after pulling 0.6 s."""
    var b = FemBody(1.0e7, 0.3, 4.0)
    make_beam(b, 10, 2, 2, 0.1, 0.5)
    var left = List[Int]()
    var right = List[Int]()
    for i in range(b.node_count()):
        if b.pos(i)[0] < 1e-6:
            left.append(i)
        elif b.pos(i)[0] > 0.999:
            right.append(i)
    for i in left:
        b.pin(i)
    for i in right:
        b.pin(i)
    var gone = 0
    for _ in range(1440):
        for i in left:
            b.x[i] -= 0.5 * DT
        for i in right:
            b.x[i] += 0.5 * DT
        b.step(DT, Vec3(0, 0, 0, 0))
        if remove:
            gone += b.remove_overstrained(0.3)
    return (gone, _pieces(b), b.x[right[0]] - b.x[left[0]])


def main() raises:
    var s = Suite("fem_plastic")
    var el = _bend(False)
    var pl = _bend(True)
    print("  cantilever under 10 g: sag elastic", el[0], " plastic", pl[0], ";  tip offset after unloading 3 s: elastic", el[1], " plastic", pl[1])
    s.check(abs(el[1]) < 1e-3 and pl[1] > 0.02, "elastic springs back; plastic keeps a permanent bend")

    var cut = _pull(True)
    var whole = _pull(False)
    print("  bar pulled apart: with removal", cut[0], "tets removed,", cut[1], "pieces;  without removal", whole[0], "removed,", whole[1], "piece, length", whole[2])
    s.check(cut[0] > 0 and cut[1] >= 2 and whole[1] == 1 and whole[0] == 0, "overstrained elements break and the bar splits; without removal it only stretches")

    var raised = 0
    var b = _cantilever()
    for args in [(Real(0), Real(0.5), Real(0.1)), (Real(0.01), Real(0), Real(0.1)), (Real(0.01), Real(1.5), Real(0.1)), (Real(0.01), Real(0.5), Real(-1))]:
        try:
            b.set_plasticity(args[0], args[1], args[2])
        except:
            raised += 1
    try:
        _ = b.remove_overstrained(0)
    except:
        raised += 1
    s.check(raised == 5, "bad plasticity parameters and max_strain <= 0 raise")
    var empty = FemBody(1e4, 0.3)
    s.check(empty.remove_overstrained(0.1) == 0, "no tets: nothing removed")
    s.finish()
