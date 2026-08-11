"""Static level geometry: what the midphase is for, and what it costs.

A level has thousands of triangles and a crate touches three. The midphase is
the step that turns the first number into the second, and the table prices the
three ways of doing it on identical terrain:

  brute        every triangle, every query. The honest baseline, and the only
               one whose candidate count is the whole mesh.
  bvh          `TriMesh`, descending a SAH tree over triangle boxes.
  heightfield  `HeightField`, converting the query box straight into cell
               indices. No tree exists to descend.

The `cand=` totals matter as much as the times: a midphase that is fast because
it hands more triangles to the narrowphase has moved the cost rather than
removed it, so the count is reported next to the time in every row. All three
answer the same query on the same surface, and `test_trimesh` gates the
heightfield and the soup to the same resting height.

The terrain sweep is the point of the table. Query cost against the mesh grows
with the tree's depth; against the field it does not grow at all, because the
size of the terrain never enters the arithmetic.

Run with: `mojo run -I build benchmarks/bench_trimesh.mojo`.
"""

from std.benchmark import keep
from geometry.vec import Real, Vec3, length
from geometry.aabb import AABB
from collision.trimesh import TriMesh, HeightField
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from harness.bench import BenchTable, now

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0)


def heights(n: Int) -> List[Real]:
    """A deterministic rolling surface, amplitude ~2, over an n x n grid."""
    var h = List[Real](capacity=n * n)
    for iz in range(n):
        for ix in range(n):
            var a = Real((ix * 37 + iz * 17) % 23) * 0.05
            var b = Real((ix * 11 + iz * 41) % 13) * 0.08
            h.append(a + b)
    return h^


def query_boxes(n: Int, extent: Real) -> List[Real]:
    """`n` query boxes as flat (cx, cy, cz) centres, spread over the terrain and
    sitting just above it so they actually hit something."""
    var out = List[Real](capacity=3 * n)
    for i in range(n):
        var u = Real((i * 7919) % 1000) / 1000.0
        var v = Real((i * 6271) % 1000) / 1000.0
        out.append(u * extent)
        out.append(1.0)
        out.append(v * extent)
    return out^


def bench_size(mut table: BenchTable, grid: Int, nq: Int):
    var cell = Real(1.0)
    var extent = Real(grid - 1) * cell
    var f = HeightField(heights(grid), grid, grid, cell, 0, 0)
    var mesh = f.to_trimesh()
    var tri_count = mesh.ntri()
    var q = query_boxes(nq, extent)
    var half = Vec3(0.4, 0.4, 0.4)

    # --- brute: every triangle is a candidate ---
    var t0 = now()
    var cb = 0
    for i in range(nq):
        var c = Vec3(q[3 * i], q[3 * i + 1], q[3 * i + 2])
        var box = AABB[3](c - half, c + half)
        for t in range(tri_count):
            var p = mesh.tri(t)
            var lo = p.points[0].v
            var hi = p.points[0].v
            for k in range(1, 3):
                comptime for d in range(3):
                    lo[d] = min(lo[d], p.points[k].v[d])
                    hi[d] = max(hi[d], p.points[k].v[d])
            if AABB[3](lo, hi).overlaps(box):
                cb += 1
    keep(cb)
    var t1 = now()
    table.add("brute cand=" + String(cb), tri_count, "midphase", t1 - t0, nq)

    # --- bvh ---
    var t2 = now()
    var cv = 0
    for i in range(nq):
        var c = Vec3(q[3 * i], q[3 * i + 1], q[3 * i + 2])
        var out = List[Int]()
        mesh.candidates(AABB[3](c - half, c + half), out)
        cv += len(out)
    keep(cv)
    var t3 = now()
    table.add("bvh cand=" + String(cv), tri_count, "midphase", t3 - t2, nq)

    # --- heightfield ---
    var t4 = now()
    var cf = 0
    for i in range(nq):
        var c = Vec3(q[3 * i], q[3 * i + 1], q[3 * i + 2])
        var out = List[Int]()
        f.candidates(AABB[3](c - half, c + half), out)
        cf += len(out)
    keep(cf)
    var t5 = now()
    table.add("heightfield cand=" + String(cf), tri_count, "midphase", t5 - t4, nq)


def bench_step(mut table: BenchTable, grid: Int, nb: Int, steps: Int, as_field: Bool) raises:
    """End to end: crates dropped on the terrain, stepped through the solver.

    The midphase is one line of a full step, so this is where its share becomes
    visible or does not. Same crates, same terrain, same surface — only the way
    candidate triangles are found differs."""
    var cell = Real(1.0)
    var extent = Real(grid - 1) * cell
    var f = HeightField(heights(grid), grid, grid, cell, 0, 0)
    var sc = ContactScene6[QuatBody6]()
    var floor_body = QuatBody6.at_rest(Vec3(0, 0, 0), Inertia3.box(1, 30, 1, 30))
    var label: String
    if as_field:
        _ = sc.add_heightfield(floor_body, heights(grid), grid, grid, cell, 0, 0)
        label = "step heightfield"
    else:
        var m = f.to_trimesh()
        var vv = List[Real](capacity=len(m.v))
        for i in range(len(m.v)):
            vv.append(m.v[i])
        var ii = List[Int](capacity=len(m.idx))
        for i in range(len(m.idx)):
            ii.append(m.idx[i])
        _ = sc.add_trimesh(floor_body, vv^, ii^)
        label = "step trimesh (bvh)"
    for i in range(nb):
        var u = Real((i * 7919) % 1000) / 1000.0
        var v = Real((i * 6271) % 1000) / 1000.0
        _ = sc.add(
            QuatBody6.at_rest(
                Vec3(u * extent, 4.0, v * extent),
                Inertia3.box(2, 0.25, 0.25, 0.25),
            ),
            Vec3(0.25, 0.25, 0.25), False,
        )
    var t0 = now()
    for _ in range(steps):
        sc.step_soft(DT, G, broadphase=True)
    var t1 = now()
    var rest = Real(0)
    for i in range(1, len(sc.bodies)):
        rest += sc.bodies[i].position()[1]
    keep(rest)
    table.add(label, f.ntri(), "step", t1 - t0, steps)


def main() raises:
    var table = BenchTable("Static level geometry: midphase candidates per query")
    bench_size(table, 32, 512)
    bench_size(table, 64, 512)
    bench_size(table, 128, 512)
    table.print_report()

    var st = BenchTable("Static level geometry: full solver step (64 crates)")
    for _ in range(2):  # discard the first pass: thread pool creation
        st = BenchTable("Static level geometry: full solver step (64 crates)")
        bench_step(st, 64, 64, 120, False)
        bench_step(st, 64, 64, 120, True)
    st.print_report()
