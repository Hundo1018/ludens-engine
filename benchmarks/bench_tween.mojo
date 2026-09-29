"""Easing dispatch cost (comptime vs runtime) and `Tween[T]` per-frame
update cost across `Real`, `Vec3` and PGA `Motor3` (screw interpolation).

Table 1 is the headline: `ease[kind](t)` (`kind` a COMPTIME bracket
parameter -- monomorphizes to one family's formula, zero dispatch branches)
against `ease_dyn(kind, t)` (`kind` a RUNTIME `Int`, resolved through the
`comptime for`-generated if-chain in `procedural/tween.mojo`) for the SAME
easing, so the delta is dispatch cost alone, not formula cost. Two kinds are
included -- `EASE_QUAD_IN` (id 1, near the front of the chain) and
`EASE_BOUNCE_INOUT` (id 30, the last comparison) -- to check whether the
runtime chain's cost depends on chain position. The measured (runtime -
comptime) DELTA comes out close to the same ~22ns for both ids (see
`scripts/benchmark_report.md.in` for the numbers) despite id 30 needing up
to 30 comparisons against a linear scan and id 1 needing at most two --
which reads as the compiler lowering the dense 0..30 equality chain to a
jump table rather than a linear scan. A comptime-for-generated if-chain is
not free at runtime, but its cost does not grow with the id picked, which is
a better finding than the position-dependence this table set out to show.

Table 2 is `Tween[T].value()` per tween per frame, N = 1e3..1e5, across the
three interpolants the design note names: `lerp_real`, `lerp_vec3`, and
`geodesic3` (screw interpolation -- the whole point of a motor `Tween`
instead of lerp+slerp, see `procedural/tween.mojo`'s module docstring and
`docs/CATEGORY.md` §3). The gap between `lerp_vec3` and `geodesic3` is the
cost of that correctness: `geodesic3` does two `log`/`exp` motor operations
per call (`geometry/galie.mojo`) against `lerp_vec3`'s one FMA.

Run: `flock /tmp/claude-1000/bench.lock pixi run mojo run -I build
benchmarks/bench_tween.mojo` (single-lane machine, see 17.35 design note
preamble).
"""

from std.benchmark import keep
from harness.bench import BenchTable, now
from geometry.vec import Real, Vec3
from geometry.motor import Motor3
from geometry.quat import Quat
from geometry.galie import geodesic3
from procedural.tween import (
    Tween,
    ease,
    ease_dyn,
    lerp_real,
    lerp_vec3,
    EASE_QUAD_IN,
    EASE_QUAD_INOUT,
    EASE_BOUNCE_INOUT,
)

comptime N_EASE = 2_000_000


def _bench_comptime_ease[kind: Int](mut table: BenchTable, tag: String):
    var acc = Real(0)
    var t0 = now()
    for i in range(N_EASE):
        var t = Real(i % 1000) * 0.001
        acc += ease[kind](t)
    var t1 = now()
    keep(acc)
    table.add(tag, N_EASE, "comptime", t1 - t0, N_EASE)


def _bench_runtime_ease(mut table: BenchTable, tag: String, kind_in: Int):
    var kind = kind_in  # runtime variable, not a bracket literal at the call
    var acc = Real(0)
    var t0 = now()
    for i in range(N_EASE):
        var t = Real(i % 1000) * 0.001
        acc += ease_dyn(kind, t)
    var t1 = now()
    keep(acc)
    table.add(tag, N_EASE, "runtime", t1 - t0, N_EASE)


def _sizes() -> List[Int]:
    return [1_000, 10_000, 100_000]


def _bench_tween_real(mut table: BenchTable, n: Int):
    var tws = List[Tween[Real, type_of(lerp_real), EASE_QUAD_INOUT]]()
    for i in range(n):
        var d = 1.0 + Real(i % 7) * 0.1
        tws.append(
            Tween[Real, type_of(lerp_real), EASE_QUAD_INOUT](0.0, 10.0, d, lerp_real)
        )
    for i in range(n):
        _ = tws[i].advance(0.05)
    var acc = Real(0)
    var t0 = now()
    for i in range(n):
        acc += tws[i].value()
    var t1 = now()
    keep(acc)
    table.add("real(lerp)", n, "value()", t1 - t0, n)


def _bench_tween_vec3(mut table: BenchTable, n: Int):
    var tws = List[Tween[Vec3, type_of(lerp_vec3), EASE_QUAD_INOUT]]()
    for i in range(n):
        var d = 1.0 + Real(i % 7) * 0.1
        tws.append(
            Tween[Vec3, type_of(lerp_vec3), EASE_QUAD_INOUT](
                Vec3(0, 0, 0, 0), Vec3(10, 20, 30, 0), d, lerp_vec3
            )
        )
    for i in range(n):
        _ = tws[i].advance(0.05)
    var acc = Vec3(0, 0, 0, 0)
    var t0 = now()
    for i in range(n):
        acc += tws[i].value()
    var t1 = now()
    keep(Int(acc[0]))
    table.add("vec3(lerp)", n, "value()", t1 - t0, n)


def _bench_tween_motor(mut table: BenchTable, n: Int):
    var qb = Quat.from_axis_angle(Vec3(0, 0, 1, 0), Real(1.0))
    var mb = Motor3.from_quat_translation(qb, Vec3(5, 0, 0, 0))
    var ma = Motor3.identity()
    var tws = List[Tween[Motor3, type_of(geodesic3), EASE_QUAD_INOUT]]()
    for i in range(n):
        var d = 1.0 + Real(i % 7) * 0.1
        tws.append(
            Tween[Motor3, type_of(geodesic3), EASE_QUAD_INOUT](ma, mb, d, geodesic3)
        )
    for i in range(n):
        _ = tws[i].advance(0.05)
    var acc = Real(0)
    var t0 = now()
    for i in range(n):
        acc += tws[i].value().s
    var t1 = now()
    keep(acc)
    table.add("motor3(geodesic)", n, "value()", t1 - t0, n)


def main() raises:
    var t1 = BenchTable("Easing dispatch -- comptime vs runtime (N=2e6 calls)")
    _bench_comptime_ease[EASE_QUAD_IN](t1, "quad_in")
    _bench_runtime_ease(t1, "quad_in", EASE_QUAD_IN)
    _bench_comptime_ease[EASE_BOUNCE_INOUT](t1, "bounce_inout")
    _bench_runtime_ease(t1, "bounce_inout", EASE_BOUNCE_INOUT)
    t1.print_report()

    var t2 = BenchTable("Tween[T].value() per tween per frame, N=1e3..1e5")
    var ns = _sizes()
    for i in range(len(ns)):
        _bench_tween_real(t2, ns[i])
        _bench_tween_vec3(t2, ns[i])
        _bench_tween_motor(t2, ns[i])
    t2.print_report()
