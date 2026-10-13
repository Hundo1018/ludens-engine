# tier: integration
"""Active edges against ghost collisions on triangle meshes (ROADMAP 17.45).

Measured before the fix (frictionless box, 0.5 m cube, sliding 1.5 s): over a
2-triangle floor it keeps 2.0 m/s, over the same floor cut into 80 or 400
quads it ends at -0.26 or 0.03 m/s with up to 0.77 m/s of vertical velocity
and tumbling -- the hull narrowphase meets each triangle alone and hands the
box the flat seams' edge normals. With `geometry.mesh_bake.active_edges`
installed (`add_trimesh(..., active)`), seams between coplanar triangles are
inactive and `contact_gen` keeps the face normal there.

  1. Ordinary: 80- and 400-quad floors with active edges keep the speed
     (2 and 8 m/s) within 1e-3 and vertical velocity under 1e-2.
  2. Integration: a real crease still works -- a floor that rises into a
     vertical wall (90 degrees, active) stops the box at the wall.
  Heightfields compute their flags from the grid (`set_active_angle`).
  3. Extreme / parity: a 2-triangle floor (one internal diagonal) gives the
     same trajectory with or without flags, and a mesh with every edge active
     is bit-identical to no flags at all.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.mesh_bake import active_edges
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 60.0


def _floor(n: Int, wall: Bool) -> Tuple[List[Real], List[Int]]:
    """A 40 x 4 m strip at y = 0 cut into n x 2 quads; with `wall`, the strip
    ends at x = 10 in a 2 m vertical wall facing -x."""
    var v = List[Real]()
    var ix = List[Int]()
    var x1 = Real(10) if wall else Real(35)
    for j in range(3):
        for i in range(n + 1):
            v.append(-5 + (x1 + 5) * Real(i) / Real(n))
            v.append(0)
            v.append(-2 + 2 * Real(j))
    for j in range(2):
        for i in range(n):
            var a = j * (n + 1) + i
            var b = a + 1
            var c = a + n + 1
            var d = c + 1
            ix.append(a); ix.append(c); ix.append(b)
            ix.append(b); ix.append(c); ix.append(d)
    if wall:
        # wall quad strip x = x1, y in [0, 2], sharing the floor's last column
        var base = len(v) // 3
        for j in range(3):
            v.append(x1); v.append(2); v.append(-2 + 2 * Real(j))
        for j in range(2):
            var a = j * (n + 1) + n  # floor vertex at (x1, 0, z_j)
            var c = (j + 1) * (n + 1) + n
            var b = base + j
            var d = base + j + 1
            # facing -x: (a, b, c), (b, d, c)
            ix.append(a); ix.append(b); ix.append(c)
            ix.append(b); ix.append(d); ix.append(c)
    return (v^, ix^)


def _run(n: Int, speed: Real, flags: Int, wall: Bool = False, steps: Int = 90) raises -> Tuple[Real, Real, Real]:
    """flags: 0 = none, 1 = baked active edges, 2 = every edge active.
    Returns (final vx, max |vy|, final x)."""
    var sc = ContactScene6[QuatBody6]()
    var f = _floor(n, wall)
    var act = List[UInt8]()
    if flags == 1:
        act = active_edges(f[0], f[1], 0.0872664626)
    elif flags == 2:
        for _ in range(len(f[1]) // 3):
            act.append(7)
    _ = sc.add_trimesh(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), f[0], f[1], act)
    var b = QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25))
    b.vel = Vec3(speed, 0, 0, 0)
    var id = sc.add(b^, Vec3(0.25, 0.25, 0.25, 0), False)
    sc.set_can_sleep(id, False)
    var maxvy = Real(0)
    for _ in range(steps):
        sc.step_soft(DT, Vec3(0, -9.8, 0, 0), mu=0.0)
        maxvy = max(maxvy, abs(sc.bset.bodies[1].vel[1]))
    return (sc.bset.bodies[1].vel[0], maxvy, sc.bset.bodies[1].pos[0])


def _run_field(speed: Real, angle: Real, slope: Bool = False) raises -> Tuple[Real, Real, Real]:
    """A box sliding over a 41 x 41 heightfield (0.5 m cells; flat, or a
    gentle 0.1 slope in z only); `angle` < 0 = no active-edge flags."""
    var sc = ContactScene6[QuatBody6]()
    var h = List[Real]()
    for iz in range(41):
        for ix in range(41):
            h.append(Real(iz) * 0.05 if slope else Real(0))
    _ = sc.add_heightfield(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), h, 41, 41, 0.5, -10, -10)
    if angle >= 0:
        sc.colliders.fields[0].set_active_angle(angle)
    var y0 = Real(0.25) + (Real(20.6 * 0.05) if slope else Real(0))  # z = 0.3 is grid row 20.6
    var b = QuatBody6.at_rest(Vec3(-8, y0, 0.3, 0), Inertia3.box(1, 0.25, 0.25, 0.25))
    b.vel = Vec3(speed, 0, 0, 0)
    var id = sc.add(b^, Vec3(0.25, 0.25, 0.25, 0), False)
    sc.set_can_sleep(id, False)
    var maxvy = Real(0)
    for _ in range(90):
        sc.step_soft(DT, Vec3(0, -9.8, 0, 0), mu=0.0)
        maxvy = max(maxvy, abs(sc.bset.bodies[1].vel[1]))
    return (sc.bset.bodies[1].vel[0], maxvy, sc.bset.bodies[1].pos[0])


def main() raises:
    var s = Suite("active_edges")

    for sp in [2, 8]:
        for n in [80, 400]:
            var before = _run(n, Real(sp), 0)
            var after = _run(n, Real(sp), 1)
            print("  speed", sp, " n", n, " vx without flags", before[0], " with", after[0], " max|vy| with", after[1])
            s.check(abs(after[0] - Real(sp)) < 1e-3, "speed " + String(sp) + ", " + String(n) + " quads: speed kept within 1e-3")
            s.check(after[1] < 1e-2, "speed " + String(sp) + ", " + String(n) + " quads: no seam kick (|vy| < 1e-2)")
    var ghost = _run(400, 2, 0)
    s.check(abs(ghost[0] - 2) > 1, "control: without flags the 400-quad floor stops the box (the defect is real)")

    var w = _run(40, 4, 1, True, 180)  # 3 s: without the wall the box would pass x = 12
    print("  wall at x = 10: final x", w[2], " vx", w[0])
    s.check(w[2] < 10 and w[2] > 9 and w[0] < 0.5, "a real 90-degree crease still stops the box at the wall (x in (9, 10))")

    var c0 = _run(1, 2, 0)
    var c1 = _run(1, 2, 1)
    s.check(c0[0] == c1[0] and c0[2] == c1[2], "2-triangle floor: identical with or without flags")
    var a0 = _run(80, 2, 0)
    var a2 = _run(80, 2, 2)
    s.check(a0[0] == a2[0] and a0[1] == a2[1] and a0[2] == a2[2], "all edges active == no flags, bit for bit")

    # ---- heightfields (computed from the grid, set_active_angle) ----
    var hf0 = _run_field(8, -1)
    var hf1 = _run_field(8, 0.0872664626)
    print("  heightfield 0.5 m cells, 8 m/s: vx without flags", hf0[0], " max|vy|", hf0[1], "  with", hf1[0], " max|vy|", hf1[1])
    s.check(abs(hf1[0] - 8) < 1e-3 and hf1[1] < 1e-2, "heightfield with active edges: speed kept within 1e-3, |vy| < 1e-2")
    var hd = _run_field(8, -1)
    var hz = _run_field(8, -1)
    s.check(hd[0] == hz[0] and hd[1] == hz[1], "heightfield without flags: deterministic (default unchanged)")
    var crease = _run_field(4, 0.0872664626, True)
    print("  heightfield with a 0.1 slope along z (crossing x at 4 m/s): final x", crease[2], " vx", crease[0])
    s.check(abs(crease[0] - 4) < 1e-2, "sloped heightfield: coplanar seams on the slope stay inactive")
    s.finish()
