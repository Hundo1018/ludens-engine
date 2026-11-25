"""app/mesh_lod.mojo (#141): the simplifier and the level choice, on the CPU.

A sphere of 64 x 48 segments (6144 triangles, a uv seam) and a flat 32 x 32 grid (an open border):
  - each level has close to its target count of triangles, and its measured error grows with the level;
  - the seam does not open: a level of the closed sphere has no boundary edge (welded positions);
  - the kept vertices are original vertices (positions, normals and uv copied, not moved);
  - the grid keeps its outline (its corners and its bounding rectangle) and stays flat;
  - the choice moves to coarser levels with distance, and with the band an instance whose distance wobbles by 5 %
    around a switch distance switches once; with no band it switches on every frame that crosses;
  - two builds are equal, bit for bit;
  - bad arguments raise."""
from std.math import sin, cos, pi
from harness.runner import Suite
from geometry.vec import Real, Vec3
from game.camera_view import View
from procedural.camera_math import CameraPose, look_rotation
from app.mesh_data import MeshData
from app.mesh_pass import MeshRegistry, unit_sphere_arrays
from app.mesh_lod import LodChain, LodState, simplify, surface_error, triangle_count, weld_ids


def grid(n: Int) -> MeshData:
    var m = MeshData(List[Float32](), List[Float32](), List[Float32](), List[UInt32]())
    for j in range(n + 1):
        for i in range(n + 1):
            m.positions.append(Float32(i) / Float32(n) - 0.5)
            m.positions.append(0.0)
            m.positions.append(Float32(j) / Float32(n) - 0.5)
            m.normals.append(0.0)
            m.normals.append(1.0)
            m.normals.append(0.0)
            m.uv.append(Float32(i) / Float32(n))
            m.uv.append(Float32(j) / Float32(n))
    for j in range(n):
        for i in range(n):
            var a = UInt32(j * (n + 1) + i)
            var b = a + UInt32(n + 1)
            m.indices.append(a)
            m.indices.append(b)
            m.indices.append(a + 1)
            m.indices.append(a + 1)
            m.indices.append(b)
            m.indices.append(b + 1)
    return m^


def boundary_edges(m: MeshData) -> Int:
    """Welded edges used by exactly one triangle."""
    var w = weld_ids(m)
    var keys = List[Int]()
    var nv = len(m.positions) // 3
    for t in range(len(m.indices) // 3):
        var t0 = w[Int(m.indices[3 * t])]
        var t1 = w[Int(m.indices[3 * t + 1])]
        var t2 = w[Int(m.indices[3 * t + 2])]
        if t0 == t1 or t1 == t2 or t0 == t2:
            continue  # a triangle with two corners at one position (the sphere's poles) covers nothing
        for k in range(3):
            var a = w[Int(m.indices[3 * t + k])]
            var b = w[Int(m.indices[3 * t + (k + 1) % 3])]
            keys.append(min(a, b) * nv + max(a, b))
    var n = 0
    for i in range(len(keys)):
        var c = 0
        for j in range(len(keys)):
            if keys[j] == keys[i]:
                c += 1
        if c == 1:
            n += 1
    return n


def view_at(dist: Float64) -> View:
    var eye = Vec3(Real(0.0), Real(0.0), Real(dist), Real(0.0))
    var pose = CameraPose(eye, look_rotation(Vec3(Real(0.0), Real(0.0), Real(-1.0), Real(0.0)), Vec3(Real(0.0), Real(1.0), Real(0.0), Real(0.0))),
                          Real(pi / 3.0), Real(16.0 / 9.0), Real(0.1), Real(500.0))
    return View(pose, Real(16.0 / 9.0))


def main() raises:
    var s = Suite("mesh_lod")
    var c = unit_sphere_arrays(64, 48)
    var reg = MeshRegistry()
    var sphere = reg.add_static(c[0].copy(), c[1].copy(), c[2].copy(), c[3].copy())
    var full = reg.meshes[sphere].copy()
    s.check(triangle_count(full) == 6144, "the sphere has 6144 triangles")
    s.check(boundary_edges(full) == 0, "the welded sphere is closed (its uv seam and poles are welded)")
    var chain = LodChain.build(reg, sphere, [1.0, 0.5, 0.25, 0.125, 0.0625])
    s.check(chain.levels() == 5, "five levels")
    var counts = String("")
    var errs = String("")
    for k in range(chain.levels()):
        counts += String(chain.triangles[k]) + " "
        errs += String(chain.errors[k]) + " "
    print("sphere levels, triangles:", counts, "; error (object units, radius 0.5):", errs)
    for k in range(1, chain.levels()):
        var target = Float64(6144) / Float64(1 << k)
        var n = Float64(chain.triangles[k])
        s.check(n <= target * 1.02 + 2.0 and n >= target * 0.9, "level " + String(k) + " is within 10 % of its target (" + String(n) + " of " + String(target) + ")")
        s.check(chain.errors[k] >= chain.errors[k - 1], "level " + String(k) + "'s error is not below the finer level's")
        var lv = reg.meshes[chain.ids[k]].copy()
        s.check(boundary_edges(lv) == 0, "level " + String(k) + " stays closed")
    s.check(chain.errors[1] < 0.01, "half the triangles: under 1 % of the diameter (" + String(chain.errors[1]) + ")")
    s.check(chain.errors[4] < 0.05, "a sixteenth: under 5 % of the diameter (" + String(chain.errors[4]) + ")")
    # kept vertices are original ones
    var lv2 = reg.meshes[chain.ids[2]].copy()
    var original = True
    for v in range(len(lv2.positions) // 3):
        var found = False
        for u in range(len(full.positions) // 3):
            var same = True
            for k in range(3):
                same = same and lv2.positions[3 * v + k] == full.positions[3 * u + k] and lv2.normals[3 * v + k] == full.normals[3 * u + k]
            same = same and lv2.uv[2 * v] == full.uv[2 * u] and lv2.uv[2 * v + 1] == full.uv[2 * u + 1]
            if same:
                found = True
                break
        original = original and found
    s.check(original, "every vertex of level 2 is a vertex of the full mesh (position, normal and uv)")

    # the open grid keeps its outline and stays flat
    var g = grid(32)
    var gs = simplify(g, 256)
    print("grid: 2048 triangles to", triangle_count(gs), "; error", surface_error(g, gs))
    s.check(triangle_count(gs) <= 262, "the grid reaches its target (" + String(triangle_count(gs)) + ")")
    var lo = Float32(1.0)
    var hi = Float32(-1.0)
    var flat = True
    var corners = 0
    for v in range(len(gs.positions) // 3):
        lo = min(lo, min(gs.positions[3 * v], gs.positions[3 * v + 2]))
        hi = max(hi, max(gs.positions[3 * v], gs.positions[3 * v + 2]))
        flat = flat and gs.positions[3 * v + 1] == 0.0
        if abs(gs.positions[3 * v]) == 0.5 and abs(gs.positions[3 * v + 2]) == 0.5:
            corners += 1
    s.check(lo == -0.5 and hi == 0.5 and corners == 4, "the grid's four corners and its rectangle are kept")
    s.check(flat, "the grid stays flat")
    s.check(surface_error(g, gs) < 1e-6, "a flat grid simplifies with no error (" + String(surface_error(g, gs)) + ")")

    # the choice by distance
    var h = 1080.0
    var last = -1
    var mono = True
    var line = String("")
    for d in [1.5, 3.0, 6.0, 12.0, 24.0, 48.0, 96.0]:
        var st = LodState()
        var k = chain.pick_level(st, Vec3(0, 0, 0, 0), 1.0, view_at(d), h)
        line += String(d) + " m: " + String(k) + "; "
        mono = mono and k >= last
        last = k
    print("level by distance (1080 px, 60 degrees):", line)
    s.check(mono, "the level does not get finer with distance")
    s.check(last == chain.levels() - 1, "far away the coarsest level is drawn")
    var st0 = LodState()
    s.check(chain.pick_level(st0, Vec3(0, 0, 0, 0), 1.0, view_at(0.6), h) == 0, "close up the full mesh is drawn")
    # find the distance where level 0 -> 1 switches: error_1 * sy * h / 2 / (d - r) = 1
    var v1 = view_at(10.0)
    var d_switch = chain.errors[1] * Float64(v1.sy) * h * 0.5 + chain.radius
    var with_band = LodState()
    var no_band_chain = chain.copy()
    no_band_chain.band = 0.0
    var without = LodState()
    for f in range(120):
        var d = d_switch * (1.0 + 0.05 * sin(Float64(f) * 0.7))
        _ = chain.pick_level(with_band, Vec3(0, 0, 0, 0), 1.0, view_at(d), h)
        _ = no_band_chain.pick_level(without, Vec3(0, 0, 0, 0), 1.0, view_at(d), h)
    print("120 frames, distance", d_switch, "m +- 5 %: switches with the band", with_band.switches, ", without", without.switches)
    s.check(with_band.switches <= 1, "with the band: at most one switch (" + String(with_band.switches) + ")")
    s.check(without.switches >= 20, "without it the level flickers (" + String(without.switches) + " switches)")

    # determinism
    var reg2 = MeshRegistry()
    var sphere2 = reg2.add_static(c[0].copy(), c[1].copy(), c[2].copy(), c[3].copy())
    var chain2 = LodChain.build(reg2, sphere2, [1.0, 0.5, 0.25, 0.125, 0.0625])
    var same = chain2.levels() == chain.levels()
    for k in range(min(chain.levels(), chain2.levels())):
        var a = reg.meshes[chain.ids[k]].copy()
        var b = reg2.meshes[chain2.ids[k]].copy()
        same = same and a.indices == b.indices and a.positions == b.positions
    s.check(same, "a second build is bit for bit the same")

    var raised = 0
    try:
        _ = LodChain.build(reg, sphere, [0.5])
    except:
        raised += 1
    try:
        _ = LodChain.build(reg, sphere, [1.0, 0.5, 0.75])
    except:
        raised += 1
    try:
        _ = simplify(full, 0)
    except:
        raised += 1
    s.check(raised == 3, "ratios not starting at 1, not decreasing, and a target of 0 raise")
    s.finish()
