"""Skinning for the arena's meshes (step 5 PR B): the palette a skinned draw reads, and the CPU reference it is
checked against. The GPU path (compute and vertex) builds on the same palette.

A palette holds one 4x4 matrix per joint, world * inverse bind, written column-major: the layout WGSL's mat4x4<f32>
reads from a storage buffer. Joints are listed parents first, so one pass computes every world matrix."""
from std.math import cos, sin
from std.math.constants import pi
from wgpu.device import Device
from geometry.mat import Mat4
from geometry.skinning import skin_lbs_k
from geometry.vec import Real, Vec3


def build_palette(locals: List[Mat4], parents: List[Int], inverse_bind: List[Mat4]) raises -> List[Float32]:
    """build_palette_root with no ancestor transform."""
    return build_palette_root(locals, parents, inverse_bind, Mat4.identity())


def build_palette_root(
    locals: List[Mat4], parents: List[Int], inverse_bind: List[Mat4], root: Mat4,
) raises -> List[Float32]:
    """As build_palette, with `root` applied above every root joint: a non-joint ancestor transform, such as the
    Armature and Z_UP rotation CesiumMan's inverse bind matrices exclude (U2). Without it the character lies on its side."""
    """16 floats per joint, column-major. parents[j] is -1 for a root, else an index below j. Raises on a bad parent
    list (the caller's data, at the boundary)."""
    var n = len(locals)
    if len(parents) != n or len(inverse_bind) != n:
        raise Error("build_palette: locals, parents and inverse_bind must have one entry per joint")
    var world = List[Mat4]()
    for j in range(n):
        var p = parents[j]
        if p >= j:
            raise Error("build_palette: a parent must come before its child")
        if p < 0:
            world.append(root.copy() * locals[j].copy())
        else:
            world.append(world[p].copy() * locals[j].copy())
    var out = List[Float32]()
    for j in range(n):
        var m = world[j].copy() * inverse_bind[j].copy()
        for c in range(4):
            for r in range(4):
                out.append(Float32(Float64(m.get(r, c))))
    return out^


def cpu_skin(
    palette: List[Mat4], rest: List[Vec3], joints: List[Int], weights: List[Real], k: Int, mut out: List[Vec3]
) raises:
    """The CPU reference: linear blend skinning, the same arithmetic as the WGSL (geometry.skinning.skin_lbs_k)."""
    skin_lbs_k(palette, rest, joints, weights, k, out)


def palette_to_mats(palette: List[Float32]) raises -> List[Mat4]:
    """The inverse of build_palette: 16 column-major floats per joint back to Mat4 (row-major storage)."""
    if len(palette) % 16 != 0:
        raise Error("palette: 16 floats per joint")
    var mats = List[Mat4]()
    for j in range(len(palette) // 16):
        var m = Mat4()
        for c in range(4):
            for r in range(4):
                m.set(r, c, Real(Float64(palette[16 * j + 4 * c + r])))
        mats.append(m^)
    return mats^


trait Skinning:
    """One skinning path. K = 4 joints per vertex, the layout the WGSL reads: joints and weights are flat, 4 per
    vertex. `device` is used by the GPU path and ignored by the CPU path, so both take the same arguments."""

    def skin(
        mut self, device: Device, palette: List[Float32], rest: List[Vec3], joints: List[Int], weights: List[Real]
    ) raises -> List[Vec3]:
        ...


struct CpuSkinning(Movable, Skinning):
    def __init__(out self):
        pass

    def skin(
        mut self, device: Device, palette: List[Float32], rest: List[Vec3], joints: List[Int], weights: List[Real]
    ) raises -> List[Vec3]:
        var mats = palette_to_mats(palette)
        var out = List[Vec3]()
        for _ in range(len(rest)):
            out.append(Vec3(Real(0), Real(0), Real(0), Real(0)))
        skin_lbs_k(mats, rest, joints, weights, 4, out)
        return out^


def rot_y(deg: Float64) -> Mat4:
    """Rotation about +Y by deg degrees: (1,0,0) maps to (cos, 0, -sin)."""
    var a = deg * pi / 180.0
    var c = Real(cos(a))
    var s = Real(sin(a))
    var m = Mat4.identity()
    m.set(0, 0, c)
    m.set(0, 2, s)
    m.set(2, 0, -s)
    m.set(2, 2, c)
    return m^


@fieldwise_init
struct SkinScene(Movable):
    """One skinning input set: the palette floats, rest positions, 4 joints and 4 weights per vertex."""

    var palette: List[Float32]
    var rest: List[Vec3]
    var joints: List[Int]
    var weights: List[Real]


def synthetic_scene() raises -> SkinScene:
    """The B2 scene: three joints (identity, +90 and -30 degrees about Y), 300 vertices with 4 joints each. Some
    vertices have all-zero weights (they stay at rest). Used by the native test and by the web probe."""
    var locals = List[Mat4]()
    locals.append(Mat4.identity())
    locals.append(rot_y(90.0))
    locals.append(rot_y(-30.0))
    var parents = List[Int]()
    parents.append(-1)
    parents.append(0)
    parents.append(0)
    var ibm = List[Mat4]()
    for _ in range(3):
        ibm.append(Mat4.identity())
    var palette = build_palette(locals, parents, ibm)
    var n = 300
    var rest = List[Vec3]()
    var joints = List[Int]()
    var weights = List[Real]()
    for v in range(n):
        rest.append(Vec3(Real(Float64(v % 17) * 0.13 - 1.0), Real(Float64(v % 11) * 0.09), Real(Float64(v % 13) * 0.21 - 1.4), Real(0)))
        for j in range(4):
            joints.append((v + j) % 3)
        if v % 7 == 0:
            for _ in range(4):
                weights.append(Real(0))
        else:
            weights.append(Real(Float64((v * 3) % 10) / 10.0))
            weights.append(Real(Float64((v * 5) % 10) / 10.0))
            weights.append(Real(0.25))
            weights.append(Real(0))
    return SkinScene(palette^, rest^, joints^, weights^)
