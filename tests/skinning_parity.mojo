# tier: unit
# Skinning parity (step 5 PR B). B1: the CPU reference on a synthetic 2-joint chain, and the palette layout. The GPU
# side (B2) is added with the compute path.
from harness.runner import Suite
from app.skin_pass import build_palette, cpu_skin, CpuSkinning, Skinning
from app.skin_gpu import GpuSkinning
from wgpu import Instance
from geometry.mat import Mat4
from geometry.vec import Real, Vec3


def _rot_y(deg: Float64) -> Mat4:
    """Rotation about +Y by deg degrees: (1,0,0) maps to (cos, 0, -sin)."""
    from std.math import cos, sin
    from std.math.constants import pi
    var t = deg * pi / 180.0
    var c = Real(cos(t))
    var s = Real(sin(t))
    var m = Mat4.identity()
    m.set(0, 0, c)
    m.set(0, 2, s)
    m.set(2, 0, -s)
    m.set(2, 2, c)
    return m^


def main() raises:
    var s = Suite("skinning_parity")

    # B1: joint 1 rotated 90 deg about +Y. A vertex at (1,0,0) with weight 1 on joint 1 lands at (0,0,-1).
    var ident = Mat4.identity()
    var locals = List[Mat4]()
    locals.append(ident.copy())
    locals.append(_rot_y(90.0))
    var parents = List[Int]()
    parents.append(-1)
    parents.append(0)
    var ibm = List[Mat4]()
    ibm.append(Mat4.identity())
    ibm.append(Mat4.identity())
    var pal_f = build_palette(locals, parents, ibm)
    s.check(len(pal_f) == 32, "the palette has 16 floats per joint")
    # column-major: joint 1's column 2 (z axis) is at floats 16 + 8 .. 16 + 11, and it holds (sin, 0, cos, 0) = (1, 0, 0, 0)
    s.almost(Float64(pal_f[16 + 8]), 1.0, "the palette is column-major (joint 1, column 2, row 0)", tol=1e-6)

    var palette = List[Mat4]()
    palette.append(Mat4.identity())
    palette.append(_rot_y(90.0))
    var rest = List[Vec3]()
    rest.append(Vec3(Real(1.0), Real(0.0), Real(0.0), Real(0.0)))
    var joints = List[Int]()
    joints.append(1)
    joints.append(0)
    var weights = List[Real]()
    weights.append(Real(1.0))
    weights.append(Real(0.0))
    var out = List[Vec3]()
    out.append(Vec3(Real(0.0), Real(0.0), Real(0.0), Real(0.0)))
    cpu_skin(palette, rest, joints, weights, 2, out)
    s.almost(Float64(out[0][0]), 0.0, "B1: the CPU reference puts (1,0,0) at x = 0", tol=1e-6)
    s.almost(Float64(out[0][1]), 0.0, "B1: the CPU reference puts (1,0,0) at y = 0", tol=1e-6)
    s.almost(Float64(out[0][2]), -1.0, "B1: the CPU reference puts (1,0,0) at z = -1", tol=1e-6)

    # a parent listed after its child is refused at the boundary
    var raised = False
    try:
        var bad = List[Int]()
        bad.append(1)
        bad.append(0)
        _ = build_palette(locals, bad, ibm)
    except:
        raised = True
    s.check(raised, "a child listed before its parent is refused")

    # B2: GPU against CPU on a synthetic mesh: 300 vertices, 4 joints each, some with all-zero weights (rest position).
    var instance = Instance()
    var device = instance.request_adapter().request_device()
    var pal_locals = List[Mat4]()
    pal_locals.append(Mat4.identity())
    pal_locals.append(_rot_y(90.0))
    pal_locals.append(_rot_y(-30.0))
    var pal_parents = List[Int]()
    pal_parents.append(-1)
    pal_parents.append(0)
    pal_parents.append(0)
    var pal_ibm = List[Mat4]()
    for _ in range(3):
        pal_ibm.append(Mat4.identity())
    var pal_floats = build_palette(pal_locals, pal_parents, pal_ibm)
    var n = 300
    var mesh_rest = List[Vec3]()
    var mesh_joints = List[Int]()
    var mesh_weights = List[Real]()
    for v in range(n):
        mesh_rest.append(Vec3(Real(Float64(v % 17) * 0.13 - 1.0), Real(Float64(v % 11) * 0.09), Real(Float64(v % 13) * 0.21 - 1.4), Real(0)))
        for j in range(4):
            mesh_joints.append((v + j) % 3)
        if v % 7 == 0:
            for _ in range(4):
                mesh_weights.append(Real(0))
        else:
            var a = Float64((v * 3) % 10) / 10.0
            var b = Float64((v * 5) % 10) / 10.0
            mesh_weights.append(Real(a))
            mesh_weights.append(Real(b))
            mesh_weights.append(Real(0.25))
            mesh_weights.append(Real(0))
    var cpu = CpuSkinning()
    var gpu = GpuSkinning(device)
    var c_out = cpu.skin(device, pal_floats, mesh_rest, mesh_joints, mesh_weights)
    var g_out = gpu.skin(device, pal_floats, mesh_rest, mesh_joints, mesh_weights)
    var worst = 0.0
    for v in range(n):
        for a in range(3):
            var d = Float64(c_out[v][a] - g_out[v][a])
            if d < 0.0:
                d = -d
            if d > worst:
                worst = d
    s.check(worst < 1e-5, "B2: GPU and CPU skinning agree on 300 vertices within 1e-5")
    print("B2 max |GPU - CPU| over 300 vertices:", worst)

    # B1 again on the GPU: the same chain, (1,0,0) with weight 1 on joint 1 lands at (0,0,-1)
    var chain_joints = List[Int]()
    chain_joints.append(1)
    chain_joints.append(0)
    chain_joints.append(0)
    chain_joints.append(0)
    var chain_w = List[Real]()
    chain_w.append(Real(1.0))
    chain_w.append(Real(0.0))
    chain_w.append(Real(0.0))
    chain_w.append(Real(0.0))
    var chain_rest = List[Vec3]()
    chain_rest.append(Vec3(Real(1.0), Real(0.0), Real(0.0), Real(0.0)))
    var chain_pal = build_palette(locals, parents, ibm)
    var chain_g = gpu.skin(device, chain_pal, chain_rest, chain_joints, chain_w)
    s.almost(Float64(chain_g[0][2]), -1.0, "B1 on the GPU: (1,0,0) lands at z = -1", tol=1e-5)

    s.finish()
