"""Textures for the arena (step 5 PR C): a texture_2d_array, rgba8unorm (not sRGB in step 5), 256x256, 9 mip levels.

Layer 0 is white and generated here. A layer is loaded one mip level at a time with queue.writeTexture, which has no
256-byte row rule (copyBufferToTexture does). The main sampler is linear with repeat; the test sampler is nearest with
no mip filtering.

Materials, read in the fragment shader (see MATERIAL_WGSL):
  0  colour only (the old look)
  1  mesh uv, with a layer
  2  triplanar with a layer: the per-axis uv is world.zy, world.xz, world.xy times 0.25 per metre, blended by |n|^4
     (normalised). Triplanar lives in TRI_WGSL and uses explicit lod 0 (textureSampleLevel: textureSample needs
     uniform control flow, and the blend branches on the material)."""
from wgpu import WGPUBindGroupEntry
from wgpu._ffi.nulls import null_opaque
from wgpu._ffi.types import WGPUTextureFormat, WGPUTextureUsage
from wgpu._backend.wgpu_native.types import WGPUTextureAspect
from wgpu._ffi.structs import WGPUOrigin3D
from wgpu.device import Device
from wgpu.texture import Texture, TextureView
from wgpu.sampler import Sampler

comptime TEX_SIZE: UInt32 = 256
comptime TEX_LEVELS: UInt32 = 9
comptime TEX_LAYER_WHITE: UInt32 = 0

comptime TRI_WGSL = """
@group(0) @binding(1) var tex : texture_2d_array<f32>;
@group(0) @binding(2) var samp : sampler;

fn triplanar(world : vec3<f32>, n : vec3<f32>, layer : u32, lod : f32) -> vec4<f32> {
  let w = pow(abs(n), vec3<f32>(4.0));
  let ws = w / (w.x + w.y + w.z);
  let cx = textureSampleLevel(tex, samp, world.zy * 0.25, layer, lod);
  let cy = textureSampleLevel(tex, samp, world.xz * 0.25, layer, lod);
  let cz = textureSampleLevel(tex, samp, world.xy * 0.25, layer, lod);
  return cx * ws.x + cy * ws.y + cz * ws.z;
}
"""


def checker_base() -> List[UInt8]:
    """8-texel cells, red and blue, alternating: a 256x256 rgba8 pattern whose every texel is known."""
    var out = List[UInt8](length=Int(TEX_SIZE) * Int(TEX_SIZE) * 4, fill=0)
    for y in range(Int(TEX_SIZE)):
        for x in range(Int(TEX_SIZE)):
            var red = ((x // 8) + (y // 8)) % 2 == 0
            var o = (y * Int(TEX_SIZE) + x) * 4
            out[o] = 200 if red else 30
            out[o + 1] = 30
            out[o + 2] = 30 if red else 200
            out[o + 3] = 255
    return out^


def level_size(level: Int) -> Int:
    return Int(TEX_SIZE) >> level


def box_levels(base: List[UInt8]) raises -> List[List[UInt8]]:
    """The mip chain of a 256x256 rgba8 image, each level the 2x2 box average of the one above (rounded). Level 0 is the
    input. The playground's convert_texture.py uses the same box filter, so the two agree."""
    if len(base) != 256 * 256 * 4:
        raise Error("box_levels: the base level is 256x256 rgba8")
    var out = List[List[UInt8]]()
    out.append(base.copy())
    for level in range(1, Int(TEX_LEVELS)):
        var s = level_size(level)
        var prev = out[level - 1].copy()
        var ps = level_size(level - 1)
        var cur = List[UInt8](length=s * s * 4, fill=0)
        for y in range(s):
            for x in range(s):
                for c in range(4):
                    var sum = 0
                    for dy in range(2):
                        for dx in range(2):
                            sum += Int(prev[((2 * y + dy) * ps + (2 * x + dx)) * 4 + c])
                    cur[(y * s + x) * 4 + c] = UInt8((sum + 2) // 4)
        out.append(cur^)
    return out^


struct TextureArray(Movable):
    """The arena's texture_2d_array. Built once per device; load_layer fills a layer's nine levels."""

    var texture: Texture
    var view: TextureView
    var main_sampler: Sampler  # linear, linear mips, repeat
    var test_sampler: Sampler  # nearest, no mip filtering: the test's exact texel reads
    var layers: UInt32

    def __init__(out self, device: Device, layers: UInt32) raises:
        if layers == 0:
            raise Error("TextureArray: at least one layer")
        self.layers = layers
        # COPY_SRC: the playground's C2 check reads the levels back to compare them with the converted files.
        self.texture = device.create_texture(
            TEX_SIZE, TEX_SIZE, layers, WGPUTextureFormat.RGBA8Unorm,
            WGPUTextureUsage.TEXTURE_BINDING | WGPUTextureUsage.COPY_DST | WGPUTextureUsage.COPY_SRC,
            dimension=2, mip_level_count=TEX_LEVELS, label="arena_textures",
        )
        self.view = self.texture.create_view_default()
        self.main_sampler = device.create_sampler(
            address_mode_u=2, address_mode_v=2, address_mode_w=2,
            mag_filter=2, min_filter=2, mipmap_filter=2, lod_max_clamp=32.0, label="arena_main",
        )
        # nearest texels, repeat addressing, and no interpolation between mips (mipmap_filter nearest). The level is still
        # chosen by the lod the shader passes, so the clamp stays at 32.
        self.test_sampler = device.create_sampler(
            address_mode_u=2, address_mode_v=2, address_mode_w=2,
            mag_filter=1, min_filter=1, mipmap_filter=1, lod_max_clamp=32.0, label="arena_test",
        )
        # layer 0 is white, every level
        var white = List[UInt8](length=Int(TEX_SIZE) * Int(TEX_SIZE) * 4, fill=255)
        var levels = box_levels(white)
        self.load_layer(device, TEX_LAYER_WHITE, levels)

    def load_layer(mut self, device: Device, layer: UInt32, levels: List[List[UInt8]]) raises:
        """One writeTexture per level. levels[L] is the level's rgba8 bytes, size 256 >> L."""
        if layer >= self.layers:
            raise Error("TextureArray.load_layer: layer out of range")
        if len(levels) != Int(TEX_LEVELS):
            raise Error("TextureArray.load_layer: nine levels")
        for level in range(Int(TEX_LEVELS)):
            var s = level_size(level)
            if len(levels[level]) != s * s * 4:
                raise Error("TextureArray.load_layer: a level has the wrong size")
            device.queue_write_texture(
                self.texture, UInt32(level), WGPUOrigin3D(UInt32(0), UInt32(0), layer), WGPUTextureAspect.All,
                levels[level].copy(), UInt32(s * 4), UInt32(s), UInt32(s), UInt32(s), UInt32(1),
            )
