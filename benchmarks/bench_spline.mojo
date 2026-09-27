"""Spline benchmark: eval cost per curve family, arc-length table build vs
query, and closest-point cost. Timings use the hardened harness (`measure`:
warmup + min-of-reps, pin with taskset).

Run (single-lane, per docs/design/wave-a-services.md's shared-lane rule):
    flock /tmp/claude-1000/bench.lock taskset -c 3 pixi run mojo run -I build benchmarks/bench_spline.mojo
"""

from std.benchmark import keep
from harness.bench import BenchTable, measure
from scheduler.rng import SplitMix64, Rng
from geometry.vec import Real, Vec3
from geometry.spline import (
    CubicBezier, BezierPath, CatmullRom, ArcLengthTable,
    build_arc_length_table, closest_point,
)


def _rand_pt(mut rng: SplitMix64) -> Vec3:
    return Vec3(
        Real(rng.next_f32()) * 10 - 5,
        Real(rng.next_f32()) * 10 - 5,
        Real(rng.next_f32()) * 10 - 5,
        0,
    )


def main() raises:
    var rng = SplitMix64.seeded(11)
    comptime N_CTRL = 64
    comptime N_SAMPLE = 4096

    var pts = List[Vec3]()
    for _ in range(N_CTRL):
        pts.append(_rand_pt(rng))

    var bez = CubicBezier[3](pts[0], pts[1], pts[2], pts[3])
    var cr_u = CatmullRom[3, 0.0](pts.copy())
    var cr_c = CatmullRom[3, 0.5](pts.copy())
    var cr_ch = CatmullRom[3, 1.0](pts.copy())
    var path = cr_c.to_bezier_path()

    # ---------------------------------------------------------------- eval
    var eval_table = BenchTable("spline eval: ns/sample per family (N_ctrl=" + String(N_CTRL) + ")")

    def eval_bezier() {imm bez}:
        var acc = Real(0)
        for i in range(N_SAMPLE):
            var u = Real(i % 1000) / 1000.0
            acc += bez.eval(u)[0]
        keep(acc)

    def eval_cr_uniform() {imm cr_u}:
        var acc = Real(0)
        var dmax = cr_u.domain_max()
        for i in range(N_SAMPLE):
            var t = dmax * Real(i % 1000) / 1000.0
            acc += cr_u.eval(t)[0]
        keep(acc)

    def eval_cr_centripetal() {imm cr_c}:
        var acc = Real(0)
        var dmax = cr_c.domain_max()
        for i in range(N_SAMPLE):
            var t = dmax * Real(i % 1000) / 1000.0
            acc += cr_c.eval(t)[0]
        keep(acc)

    def eval_cr_chordal() {imm cr_ch}:
        var acc = Real(0)
        var dmax = cr_ch.domain_max()
        for i in range(N_SAMPLE):
            var t = dmax * Real(i % 1000) / 1000.0
            acc += cr_ch.eval(t)[0]
        keep(acc)

    def eval_bezierpath() {imm path}:
        var acc = Real(0)
        var dmax = path.domain_max()
        for i in range(N_SAMPLE):
            var t = dmax * Real(i % 1000) / 1000.0
            acc += path.eval(t)[0]
        keep(acc)

    eval_table.add("CubicBezier (1 segment)", N_SAMPLE, "eval", measure(eval_bezier, 3, 20), N_SAMPLE)
    eval_table.add("CatmullRom uniform (a=0)", N_SAMPLE, "eval", measure(eval_cr_uniform, 3, 20), N_SAMPLE)
    eval_table.add("CatmullRom centripetal (a=0.5)", N_SAMPLE, "eval", measure(eval_cr_centripetal, 3, 20), N_SAMPLE)
    eval_table.add("CatmullRom chordal (a=1)", N_SAMPLE, "eval", measure(eval_cr_chordal, 3, 20), N_SAMPLE)
    eval_table.add("BezierPath (pre-converted)", N_SAMPLE, "eval", measure(eval_bezierpath, 3, 20), N_SAMPLE)
    eval_table.print_report()

    # ---------------------------------------------------------- arc length
    var al_table = BenchTable("arc-length table: build vs query (path = " + String(N_CTRL - 1) + " segments)")

    def build_32() {imm path}:
        var t = build_arc_length_table[3](path, 32)
        keep(t.total_length())

    def build_256() {imm path}:
        var t = build_arc_length_table[3](path, 256)
        keep(t.total_length())

    def build_2048() {imm path}:
        var t = build_arc_length_table[3](path, 2048)
        keep(t.total_length())

    al_table.add("build_arc_length_table", 32, "build", measure(build_32, 3, 20), 1)
    al_table.add("build_arc_length_table", 256, "build", measure(build_256, 3, 20), 1)
    al_table.add("build_arc_length_table", 2048, "build", measure(build_2048, 3, 20), 1)

    var query_table = build_arc_length_table[3](path, 256)
    var total_len = query_table.total_length()

    def query_dist() {imm query_table, imm total_len}:
        var acc = Real(0)
        for i in range(N_SAMPLE):
            var s = total_len * Real(i % 1000) / 1000.0
            acc += query_table.sample_at_distance(s)
        keep(acc)

    al_table.add("sample_at_distance (table N=256)", N_SAMPLE, "query", measure(query_dist, 3, 20), N_SAMPLE)
    al_table.print_report()

    # -------------------------------------------------------- closest point
    var cp_table = BenchTable("closest_point: ns/query (path = " + String(N_CTRL - 1) + " segments)")

    var queries = List[Vec3]()
    for _ in range(1024):
        queries.append(_rand_pt(rng))

    def cp_query() {imm path, imm queries}:
        var acc = Real(0)
        for i in range(len(queries)):
            acc += closest_point[3](path, queries[i])
        keep(acc)

    cp_table.add("closest_point (16 coarse + 8 Newton)", len(queries), "query", measure(cp_query, 3, 20), len(queries))
    cp_table.print_report()
