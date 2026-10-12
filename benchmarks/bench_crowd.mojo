"""Crowd avoidance seam (ROADMAP 17.14): Orca / SampledRvo / SocialForce.

N agents (radius 0.3 m, 1.4 m/s) on a 64 m floor with a checkerboard of
1.5 m pillars; seeded spawns at least 0.8 m apart, each goal within 20 m of
its start; 1/30 s ticks for 40 s of simulated time. Each row: cost per
agent-tick, with the quality numbers in the label -- share of agents
arrived, their mean arrival time, the deepest overlap seen after the first
second (sampled every 10 ticks) and the number of re-plans.

Run: pixi run mojo run -I build benchmarks/bench_crowd.mojo
"""

from std.benchmark import keep
from harness.bench import BenchTable, now
from geometry.vec import Real, Vec3
from scheduler.rng import SplitMix64, Rng
from nav.heightfield import NavBakeConfig
from nav.navmesh import NavMesh, bake_navmesh
from nav.crowd import Crowd, CrowdParams, Avoidance, Orca, SampledRvo, SocialForce

comptime DT: Real = 1.0 / 30.0


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


def _box(mut verts: List[Vec3], mut tris: List[Int], lo: Vec3, hi: Vec3):
    var c = List[Vec3]()
    for k in range(8):
        c.append(_v(hi[0] if k & 1 else lo[0], hi[1] if k & 2 else lo[1], hi[2] if k & 4 else lo[2]))
    # 12 outward triangles of the box (corner bits: x=1, y=2, z=4)
    var f = [0, 1, 4, 1, 5, 4, 2, 6, 3, 3, 6, 7, 0, 4, 2, 2, 4, 6, 1, 3, 5, 3, 7, 5, 0, 2, 1, 1, 2, 3, 4, 5, 6, 5, 7, 6]
    var b = len(verts)
    for k in range(8):
        verts.append(c[k])
    for k in range(len(f)):
        tris.append(b + f[k])


def _scene() raises -> NavMesh:
    var verts = List[Vec3]()
    var tris = List[Int]()
    verts.append(_v(0, 0, 0))
    verts.append(_v(0, 0, 64))
    verts.append(_v(64, 0, 0))
    verts.append(_v(64, 0, 64))
    tris.append(0)
    tris.append(1)
    tris.append(2)
    tris.append(2)
    tris.append(1)
    tris.append(3)
    for i in range(1, 8):
        for j in range(1, 8):
            if (i + j) % 2 == 0:
                var x = Real(8 * i)
                var z = Real(8 * j)
                _box(verts, tris, _v(x - 0.75, 0, z - 0.75), _v(x + 0.75, 2.5, z + 0.75))
    return bake_navmesh(verts, tris, NavBakeConfig(0.25, 0.1, 1.8, 0.3, 0.4, 45.0, 16))


def _run[A: Avoidance](mut t: BenchTable, var avoid: A, name: String, mesh: NavMesh, n: Int) raises:
    var c = Crowd[A](avoid^, CrowdParams.default())
    var rng = SplitMix64.seeded(UInt64(n) * 31 + 7)
    var guard = 0
    while len(c) < n and guard < 1000 * n:
        guard += 1
        var p = _v(1 + rng.next_f32() * 62, 0, 1 + rng.next_f32() * 62)
        if mesh.find_span(p) < 0:
            continue
        var free = True
        for j in range(len(c)):
            var d = c.pos[j] - p
            if d[0] * d[0] + d[2] * d[2] < Real(0.64):
                free = False
                break
        if free:
            _ = c.add_agent(mesh, p, 0.3, 1.4)
    for i in range(len(c)):
        var tries = 0
        while tries < 50:
            tries += 1
            var g = c.pos[i] + _v(rng.next_f32() * 40 - 20, 0, rng.next_f32() * 40 - 20)
            if g[0] < 1 or g[0] > 63 or g[2] < 1 or g[2] > 63:
                continue
            if c.set_target(mesh, i, g):
                break
    var steps = Int(Real(40) / DT)
    var arrive_t = List[Real](length=len(c), fill=Real(-1))
    var worst = Real(0)
    var ns = 0
    for k in range(steps):
        var t0 = now()
        c.step(mesh, DT)
        ns += now() - t0
        for i in range(len(c)):
            if arrive_t[i] < 0 and c.arrived[i]:
                arrive_t[i] = Real(k + 1) * DT
        if k % 10 == 0 and k >= 30:
            worst = min(worst, c.min_separation())
    var arrived = 0
    var tsum = Real(0)
    for i in range(len(c)):
        if arrive_t[i] >= 0:
            arrived += 1
            tsum += arrive_t[i]
    var label = name + " (arrived " + String(Int(Real(100 * arrived) / Real(len(c)))) + " %, mean t "
    label += String(Int(tsum / Real(max(arrived, 1)) * 10) / 10) + " s"
    label += ", deepest overlap " + String(Int(-worst * 1000)) + " mm"
    label += ", replans " + String(c.replans) + ")"
    t.add(label, n, "agent-tick", ns, len(c) * steps)


def main() raises:
    var mesh = _scene()
    var t = BenchTable("Crowd avoidance (17.14): 64 m floor with pillars, random goals")
    for n in [64, 256, 1024]:
        _run(t, Orca(), "Orca", mesh, n)
        _run(t, SampledRvo(), "SampledRvo", mesh, n)
        _run(t, SocialForce(), "SocialForce", mesh, n)
    t.print_report()
