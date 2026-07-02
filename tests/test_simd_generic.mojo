"""Generic SIMD (WS4): `integrate_simd` vectorizes ANY `SimdComponent`, not just
Vec2/float32. Here a float32x4 (Vec4-shaped) component pair is integrated and
checked lane-by-lane against the closed-form scalar result."""

from harness.runner import Suite
from ecs.world import World
from ecs.archetype import ArchetypeBackend
from ecs.component import SimdComponent
from ecs.system import integrate_simd

comptime Vec4 = SIMD[DType.float32, 4]


@fieldwise_init
struct Pos4(SimdComponent):
    comptime ID: Int = 0
    comptime Dtype = DType.float32
    comptime Width = 4
    var p: Vec4


@fieldwise_init
struct Vel4(SimdComponent):
    comptime ID: Int = 1
    comptime Dtype = DType.float32
    comptime Width = 4
    var v: Vec4


def main() raises:
    var s = Suite("simd_generic")
    comptime N = 100
    comptime FRAMES = 4
    var w = World[ArchetypeBackend[Pos4, Vel4]]()
    for i in range(N):
        var fi = Float32(i)
        _ = w.spawn2(Pos4(Vec4(fi, fi, fi, fi)), Vel4(Vec4(1, 2, 3, 4)))
    var dt = Float32(0.5)

    for _ in range(FRAMES):
        integrate_simd[Pos4, Vel4](w.backend, dt)

    # p_lane_j = i + v_j * dt * FRAMES ; sum over i of lane j = N(N-1)/2 + N*v_j*dt*FRAMES
    var es = w.query2[Pos4, Vel4]()
    var base = Float64(N * (N - 1)) / 2.0
    var sum0 = Float64(0)
    var sum3 = Float64(0)
    for k in range(len(es)):
        var p = w.get[Pos4](es[k]).p
        sum0 += Float64(p[0])
        sum3 += Float64(p[3])
    s.almost(sum0, base + Float64(N) * 1.0 * 0.5 * FRAMES, "float32x4 lane0", 1e-2)
    s.almost(sum3, base + Float64(N) * 4.0 * 0.5 * FRAMES, "float32x4 lane3", 1e-2)
    s.finish()
