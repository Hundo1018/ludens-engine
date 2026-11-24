"""Bytes a GPU texture occupies, for the frame counters (app/frame_stats.mojo `CTR_TEXTURE_BYTES`).

Computed from the size, layers, mip levels and format the texture was created with, not read back from the texture and not
from the driver: wgpu-mojo's web host does not implement `wgpuTextureGetWidth` and its siblings (it traps), so a counter that
asked the texture would work natively and fail in the browser. Every level of a chain is `max(1, w >> level) * max(1, h >> level)`
texels. A driver may pad rows or tile, so this is the size the data has, not the allocation. A format this file does not know
raises instead of guessing."""
from wgpu import WGPUTextureFormat


def bytes_per_texel(format: UInt32) raises -> Int:
    if format == WGPUTextureFormat.R8Unorm:
        return 1
    if (
        format == WGPUTextureFormat.RGBA8Unorm or format == WGPUTextureFormat.RGBA8UnormSrgb
        or format == WGPUTextureFormat.BGRA8Unorm or format == WGPUTextureFormat.BGRA8UnormSrgb
        or format == WGPUTextureFormat.R32Float or format == WGPUTextureFormat.Depth32Float
        or format == WGPUTextureFormat.RG11B10Ufloat
    ):
        return 4
    if format == WGPUTextureFormat.RGBA16Float:
        return 8
    if format == WGPUTextureFormat.RGBA32Float:
        return 16
    raise Error("gpu_bytes: no texel size for texture format " + String(format))


def mip_chain_texels(width: Int, height: Int, levels: Int) -> Int:
    var n = 0
    for l in range(levels):
        n += max(1, width >> l) * max(1, height >> l)
    return n


def texture_bytes(width: Int, height: Int, layers: Int, levels: Int, format: UInt32) raises -> Int:
    return mip_chain_texels(width, height, levels) * layers * bytes_per_texel(format)
