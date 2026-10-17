# tier: integration
"""SDF -> isosurface -> collision mesh (ROADMAP 17.69, `geometry.isosurface`
`sample_sdf` / `TriMesh.flat` into `ContactScene6.add_trimesh`).

  1. A box SDF (half 1 x 0.5 x 1, top at y 0.5) sampled on a grid aligned
     with its faces gives a closed mesh (0 open edges) of volume 4 (1 %;
     the cut edges and corners lose 0.6 %).
  2. That mesh as a static collider: a 0.2 m box dropped from y 1.5 comes
     to rest on the top face (bottom at y 0.5, 1 cm) and stays inside the
     footprint.
  3. A sphere SDF (r 0.8): closed mesh, volume within 3 % of 4/3 pi r^3
     (marching tetrahedra cuts corners).
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.sdf3 import Sdf3
from geometry.isosurface import sample_sdf, marching_tetrahedra
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig


def main() raises:
    var s = Suite("iso_collision")
    var bx = Sdf3.box(Vec3(0, 0, 0, 0), Vec3(1, 0.5, 1, 0))
    # faces between nodes (a face on a node would give zero-length crossings)
    var g = sample_sdf(bx, Vec3(-1.3125, -0.8125, -1.3125, 0), 0.125, 22, 14, 22)
    var mesh = marching_tetrahedra(g, 0)
    print("box SDF: triangles", mesh.triangles(), " open edges", mesh.open_edges(), " volume", mesh.volume())
    s.check(mesh.open_edges() == 0 and abs(mesh.volume() - 4) < 0.04, "box: closed mesh, volume 2 x 1 x 2 = 4 (1 %)")

    var sc = ContactScene6[QuatBody6]()
    var flat = mesh.flat()
    _ = sc.add_trimesh(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), flat[0], flat[1])
    var b = sc.add(QuatBody6.at_rest(Vec3(0.1, 1.5, -0.2, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), False)
    var cfg = SolverConfig()
    for _ in range(180):
        sc.step(1.0 / 60.0, Vec3(0, -9.8, 0, 0), cfg)
    var p = sc.pose(b).pos
    print("box dropped on the mesh: rests at", p[0], p[1], p[2], " (bottom", p[1] - 0.1, ")")
    s.check(abs(p[1] - 0.1 - 0.5) < 0.01 and abs(p[0]) < 1 and abs(p[2]) < 1, "rests on the generated top face")

    var sp = Sdf3.sphere(Vec3(0, 0, 0, 0), 0.8)
    var gs = sample_sdf(sp, Vec3(-1, -1, -1, 0), 0.0625, 33, 33, 33)
    var ms = marching_tetrahedra(gs, 0)
    var want = Real(4.0 / 3.0 * 3.14159265 * 0.512)
    print("sphere SDF: open edges", ms.open_edges(), " volume", ms.volume(), " (", want, ")")
    s.check(ms.open_edges() == 0 and abs(ms.volume() / want - 1) < 0.03, "sphere: closed mesh, volume within 3 %")
    s.finish()
