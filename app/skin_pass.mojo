"""Skinning for the arena's meshes (step 5 PR B): the palette a skinned draw reads, and the CPU reference it is
checked against. The GPU path (compute and vertex) builds on the same palette.

A palette holds one 4x4 matrix per joint, world * inverse bind, written column-major: the layout WGSL's mat4x4<f32>
reads from a storage buffer. Joints are listed parents first, so one pass computes every world matrix."""
from wgpu.device import Device
from geometry.mat import Mat4
from geometry.skinning import skin_lbs_k
from geometry.vec import Real, Vec3


def build_palette(locals: List[Mat4], parents: List[Int], inverse_bind: List[Mat4]) raises -> List[Float32]:
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
            world.append(locals[j].copy())
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
