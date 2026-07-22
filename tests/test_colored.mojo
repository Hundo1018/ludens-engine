from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0)


def _pyramid(rows: Int) -> ContactScene6[QuatBody6]:
    """One box pyramid = one big island: the case island-parallelism can't
    touch (6.5 honesty row) and coloring is for."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 30, 1, 30)),
        Vec3(30, 1, 30),
        True,
    )
    var bi = Inertia3.box(2, 0.25, 0.25, 0.25)
    for i in range(rows):
        for j in range(rows - i):
            var x = Real(j) * 0.52 + Real(i) * 0.26 - Real(rows) * 0.26
            _ = sc.add(
                QuatBody6.at_rest(Vec3(x, 0.3 + 0.52 * Real(i), 0), bi),
                Vec3(0.25, 0.25, 0.25),
                False,
            )
    return sc^


def _flat(n: Int) -> ContactScene6[QuatBody6]:
    """n separated boxes on one ground slab: every pair touches only its own
    dynamic body, so coloring must produce ONE color (statics excluded from
    adjacency) and the colored result must equal plain Gauss-Seidel bitwise."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 30, 1, 30)),
        Vec3(30, 1, 30),
        True,
    )
    var bi = Inertia3.box(2, 0.25, 0.25, 0.25)
    for i in range(n):
        _ = sc.add(
            QuatBody6.at_rest(Vec3(Real(i) * 2 - 9, 0.3, 0), bi),
            Vec3(0.25, 0.25, 0.25),
            False,
        )
    return sc^


def _same(a: ContactScene6[QuatBody6], b: ContactScene6[QuatBody6]) -> Bool:
    for i in range(len(a.bodies)):
        var dp = a.bodies[i].pos - b.bodies[i].pos
        if dp[0] != 0 or dp[1] != 0 or dp[2] != 0:
            return False
        if a.bodies[i].q.x != b.bodies[i].q.x or a.bodies[i].q.w != b.bodies[i].q.w:
            return False
        if a.sleeping[i] != b.sleeping[i]:
            return False
    return True


def main() raises:
    var s = Suite("colored")

    # 1. Determinism: two colored-parallel runs are bit-identical.
    var a = _pyramid(6)
    var b = _pyramid(6)
    for _ in range(300):
        a.step_soft(DT, G, parallel=True, colored=True)
        b.step_soft(DT, G, parallel=True, colored=True)
    s.check(_same(a, b), "colored+parallel is deterministic (two runs equal)")

    # 2. Threads change nothing: colored serial == colored parallel
    #    (same schedule, disjoint same-color writes).
    var c = _pyramid(6)
    for _ in range(300):
        c.step_soft(DT, G, parallel=False, colored=True)
    s.check(_same(a, c), "colored parallel == colored serial (bit-identical)")

    # 3. Behaviour parity vs plain Gauss-Seidel: different schedule, same
    #    physics — the pyramid stands in both and positions agree closely.
    var d = _pyramid(6)
    for _ in range(300):
        d.step_soft(DT, G)
    var worst = Float64(0)
    for i in range(len(a.bodies)):
        var dp = a.bodies[i].pos - d.bodies[i].pos
        var m = max(
            abs(Float64(dp[0])), max(abs(Float64(dp[1])), abs(Float64(dp[2])))
        )
        if m > worst:
            worst = m
    print("  colored vs serial GS worst position delta:", worst)
    s.check(worst < 0.05, "colored solver matches serial physics (< 5 cm)")
    var top = Float64(a.bodies[len(a.bodies) - 1].pos[1])
    print("  pyramid top y:", top, "expected settled:", 0.25 + 0.5 * 5)
    s.check(abs(top - (0.25 + 0.5 * 5)) < 0.05, "pyramid stands when colored")

    # 4. Statics excluded from adjacency: separated boxes on one ground get
    #    a single color, and the colored run equals plain GS bitwise.
    var f1 = _flat(10)
    var f2 = _flat(10)
    for _ in range(200):
        f1.step_soft(DT, G, parallel=True, colored=True)
        f2.step_soft(DT, G)
    s.check(
        _same(f1, f2),
        "ground-only contacts: colored == plain GS bit-identically",
    )

    # 5. Convergence-quality gate: the colored schedule loses the serial
    #    wavefront and needs ~2x iterations to settle as well — at iters=8
    #    the pyramid must actually fall ASLEEP (at iters=4 it never does;
    #    residual ~1 cm/s jitter straddles the sleep threshold).
    var z = _pyramid(6)
    for _ in range(240):
        z.step_soft(DT, G, iters=8, parallel=True, colored=True)
    var asleep = 0
    for i in range(len(z.bodies)):
        if z.sleeping[i]:
            asleep += 1
    print("  colored iters=8: sleeping", asleep, "of", len(z.bodies) - 1)
    s.check(
        asleep == len(z.bodies) - 1,
        "colored solver at 2x iters reaches full sleep",
    )

    s.finish()
