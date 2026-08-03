"""Parity: the zero-allocation `for_each2` produces the same result as the
`query2` + `get`/`set` handle loop, on every backend (WS3)."""

from harness.runner import Suite
from ecs.world import World
from ecs.storage import StorageBackend
from ecs.sparse_backend import SparseSetBackend
from ecs.archetype import ArchetypeBackend
from ecs.bitset_backend import BitsetBackend
from ecs.reactive_backend import ReactiveBackend
from ecs.naive_backend import NaiveBackend
from ecs.chunked_backend import ChunkedBackend
from ecs.component import ComponentType
from geometry.vec import Vec2, Real


@fieldwise_init
struct Pos2(ComponentType):
    comptime ID: Int = 0
    var p: Vec2


@fieldwise_init
struct Vel2(ComponentType):
    comptime ID: Int = 1
    var v: Vec2


def _sum_x[B: StorageBackend](mut w: World[B]) -> Float64:
    var s = Float64(0)
    var es = w.query2[Pos2, Vel2]()
    for k in range(len(es)):
        s += Float64(w.get[Pos2](es[k]).p[0])
    return s


def run_handle[B: StorageBackend](n: Int, frames: Int) -> Float64:
    var w = World[B]()
    for i in range(n):
        _ = w.spawn2(Pos2(Vec2(Real(i), 0)), Vel2(Vec2(1, 1)))
    var dt = Real(1)
    for _ in range(frames):
        var es = w.query2[Pos2, Vel2]()
        for k in range(len(es)):
            var e = es[k]
            w.set(e, Pos2(w.get[Pos2](e).p + w.get[Vel2](e).v * dt))
    return _sum_x(w)


def run_foreach[B: StorageBackend](n: Int, frames: Int) -> Float64:
    var w = World[B]()
    for i in range(n):
        _ = w.spawn2(Pos2(Vec2(Real(i), 0)), Vel2(Vec2(1, 1)))
    var dt = Real(1)

    @parameter
    def integrate(mut p: Pos2, v: Vel2):
        p = Pos2(p.p + v.v * dt)

    for _ in range(frames):
        w.for_each2[Pos2, Vel2, integrate]()
    return _sum_x(w)


def check[B: StorageBackend](mut s: Suite, name: String, n: Int, frames: Int):
    var h = run_handle[B](n, frames)
    var f = run_foreach[B](n, frames)
    # pos.x_i = i + frames  ->  sum = n(n-1)/2 + n*frames
    var expected = Float64(n * (n - 1)) / 2.0 + Float64(n * frames)
    s.almost(h, expected, name + ": handle == expected", 1e-2)
    s.almost(f, h, name + ": for_each2 == handle", 1e-2)


def main() raises:
    var s = Suite("iter_parity")
    comptime N = 200
    comptime F = 5
    check[SparseSetBackend[Pos2, Vel2]](s, "sparse", N, F)
    check[ArchetypeBackend[Pos2, Vel2]](s, "archetype", N, F)
    check[BitsetBackend[Pos2, Vel2]](s, "bitset", N, F)
    check[ReactiveBackend[Pos2, Vel2]](s, "reactive", N, F)
    check[NaiveBackend[Pos2, Vel2]](s, "naive", N, F)
    check[ChunkedBackend[Pos2, Vel2]](s, "chunked", N, F)
    s.finish()
