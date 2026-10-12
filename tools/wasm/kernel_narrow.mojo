"""wasm leaf-kernel probe (ROADMAP 17.76): one narrowphase query,
sphere vs axis-aligned box, through collision.manifold. Fixed-size
`Array`s only, no heap."""

from geometry.vec import Real, Vec3
from collision.manifold import sphere_box_manifold, Axes3


@export
def ludens_kernel_sphere_box_depth(sx: Float32, sy: Float32, sz: Float32, r: Float32, hx: Float32, hy: Float32, hz: Float32) abi("C") -> Float32:
    var axes = Axes3(fill=Vec3(0, 0, 0, 0))
    axes[0] = Vec3(1, 0, 0, 0)
    axes[1] = Vec3(0, 1, 0, 0)
    axes[2] = Vec3(0, 0, 1, 0)
    var m = sphere_box_manifold(
        Vec3(Real(sx), Real(sy), Real(sz), 0), Real(r), Vec3(0, 0, 0, 0), axes, Vec3(Real(hx), Real(hy), Real(hz), 0)
    )
    return Float32(m.depths[0]) if m.hit else Float32(-1)


def main():
    pass
