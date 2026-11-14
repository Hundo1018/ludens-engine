# tier: unit
# Skinning parity (step 5 PR B). B1: the CPU reference on a synthetic 2-joint chain, and the palette layout. The GPU
# side (B2) is added with the compute path.
from harness.runner import Suite
from app.skin_pass import build_palette, cpu_skin
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

    s.finish()
