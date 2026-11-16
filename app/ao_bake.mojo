"""Ambient occlusion over a floor, for MeshPass.set_ao (ludens-engine#79): the grid set_ao takes, traced on the CPU with
ludens-core's BVH.raycast over the scene's static boxes.

Each cell of an n by n grid over the floor square (x0, z0) to (x0 + size, z0 + size) is a floor point `height` metres up.
From it, `rays` rays go up over the hemisphere: cosine-weighted, the elevation from the sample index and the azimuth from
the golden angle, the same fixed directions for every cell and every run. A ray that hits a box within `reach` metres
occludes; the cell's value is 1 minus `strength` times the occluded fraction (1 open, 1 - strength fully occluded).
Cells are row-major by z.

The CPU path is the one a web page can use: app/rt_gpu.mojo's GPU trace reads its result back with a blocking device
poll, which the web target does not have (wgpuDevicePoll is native-only). The two agree ray for ray (hit flags equal, t
within 1e-3; ludens-playground's tests/rt_native.mojo).
"""
from std.math import cos, sin
from geometry.vec import Real, Vec3
from geometry.aabb import AABB
from geometry.ray import Ray
from spatial.bvh import BVH


def ao_bake(
    boxes: List[AABB[3]], n: Int = 40, x0: Float32 = -20.0, z0: Float32 = -20.0, size: Float32 = 40.0,
    rays: Int = 16, reach: Float64 = 4.0, strength: Float64 = 0.7, height: Float64 = 0.05,
) raises -> List[Float32]:
    """The n by n cells over the floor square, row-major by z."""
    if n < 1 or rays < 1 or not (size > 0) or not (reach > 0):
        raise Error("ao_bake: n and rays must be at least 1, size and reach positive")
    var cells = List[Float32]()
    if len(boxes) == 0:
        for _ in range(n * n):
            cells.append(1.0)
        return cells^
    var proxies = List[Int]()
    for i in range(len(boxes)):
        proxies.append(i)
    var bvh = BVH[3]()
    bvh.build_boxes(boxes, proxies, sah=True)
    var cell = size / Float32(n)
    for iz in range(n):
        for ix in range(n):
            var x = x0 + (Float32(ix) + 0.5) * cell
            var z = z0 + (Float32(iz) + 0.5) * cell
            var occluded = 0
            for k in range(rays):
                var u = (Float32(k) + 0.5) / Float32(rays)
                var r = (1.0 - u) ** Float32(0.5)
                var phi = Float32(k) * Float32(2.399963)
                var d = Vec3(Real(Float64(r * cos(phi))), Real(Float64(u ** Float32(0.5))), Real(Float64(r * sin(phi))), Real(0))
                var o = Vec3(Real(Float64(x)), Real(height), Real(Float64(z)), Real(0))
                if bvh.raycast(Ray[3](o, d, Real(reach))).hit:
                    occluded += 1
            cells.append(1.0 - Float32(strength) * Float32(occluded) / Float32(rays))
    return cells^
