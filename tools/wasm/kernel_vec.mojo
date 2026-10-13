"""wasm leaf-kernel probe (ROADMAP 17.76): pure arithmetic on geometry.vec,
exported with the C ABI, no allocation, no I/O. `scripts/wasm_probe.py` emits
its LLVM IR and counts external declarations a wasm module would have to
import."""

from geometry.vec import Real, Vec3, dot, cross


@export
def ludens_kernel_dot_cross(ax: Float32, ay: Float32, az: Float32, bx: Float32, by: Float32, bz: Float32) abi("C") -> Float32:
    var a = Vec3(Real(ax), Real(ay), Real(az), 0)
    var b = Vec3(Real(bx), Real(by), Real(bz), 0)
    var c = cross(a, b)
    return Float32(dot(c, c) + dot(a, b))


def main():
    pass
