# tier: integration
# Texture checks (step 5 PR C1), native wgpu. A checker on layer 1 with its nine mip levels, sampled two ways into a
# 256x256 target and read back:
#   mode 0: nearest at texel centres at mip 0 and mip 4. Every texel must equal the texel of that level.
#   mode 1: triplanar on the +X face of a box (normal (1,0,0)), uv = world.zy * 0.25. The texel must equal the texel of
#           the base level at (z, y) * 0.25, wrapped.
# The target is 256x256 rgba8, so its rows are already 256-byte aligned: no copyTextureToBuffer, no pitch padding.
# Run with pixi run -e wasm test-texture (lavapipe in the parity job).
from harness.runner import Suite
from wgpu import Instance, WGPUBindGroupEntry, WGPUBindGroupLayoutEntry, WGPUBufferBindingLayout
from wgpu import WGPUBufferBindingType, WGPUBufferUsage, WGPUShaderStage, WGPUColor
from wgpu import WGPUSamplerBindingLayout, WGPUTextureBindingLayout, WGPUStorageTextureBindingLayout
from wgpu._ffi.nulls import null_opaque
from wgpu._ffi.types import WGPUTextureFormat, WGPUTextureUsage
from wgpu.capture import FrameCapture
from app.textures import TextureArray, box_levels, checker_base, TRI_WGSL, level_size

comptime SIZE = 256
comptime TEST_WGSL = """
struct U { layer : u32, lod : u32, mode : u32, pad : u32 };
@group(0) @binding(0) var<uniform> u : U;
""" + TRI_WGSL + """

@vertex
fn vs(@builtin(vertex_index) i : u32) -> @builtin(position) vec4<f32> {
  let x = f32((i << 1u) & 2u);
  let y = f32(i & 2u);
  return vec4<f32>(x * 2.0 - 1.0, 1.0 - y * 2.0, 0.0, 1.0);
}

@fragment
fn fs(@builtin(position) p : vec4<f32>) -> @location(0) vec4<f32> {
  let uv = p.xy / 256.0;
  if u.mode == 0u {
    return textureSampleLevel(tex, samp, uv, u.layer, f32(u.lod));
  }
  // the +X face of a box: world = (1, y, z), y and z spanning 8 m across the target
  let world = vec3<f32>(1.0, uv.y * 8.0, uv.x * 8.0);
  return triplanar(world, vec3<f32>(1.0, 0.0, 0.0), u.layer, 0.0);
}
"""


def _nearest(levels: List[List[UInt8]], level: Int, px: Int, py: Int, c: Int) -> Int:
    """The texel nearest to the pixel centre (px + 0.5, py + 0.5) of the 256 target, at mip level."""
    var s = level_size(level)
    var tx = ((2 * px + 1) * s) // (2 * SIZE)
    var ty = ((2 * py + 1) * s) // (2 * SIZE)
    return Int(levels[level][(ty * s + tx) * 4 + c])


def _triplanar_texel(levels: List[List[UInt8]], px: Int, py: Int, c: Int) -> Int:
    """The base texel the +X face reads at pixel (px, py): uv = (z, y) * 0.25 with z = (px + 0.5) / 32, y = (py + 0.5) / 32,
    wrapped to [0, 1), nearest at mip 0."""
    var u = Float64(px) + 0.5
    var v = Float64(py) + 0.5
    var uu = (u / 128.0)  # z * 0.25, z = uv.x * 8, uv.x = u / 256
    var vv = (v / 128.0)
    uu = uu - Float64(Int(uu))
    vv = vv - Float64(Int(vv))
    var tx = Int(uu * SIZE)
    var ty = Int(vv * SIZE)
    return Int(levels[0][(ty * SIZE + tx) * 4 + c])


def main() raises:
    var s = Suite("texture_native")
    var instance = Instance()
    var device = instance.request_adapter().request_device()
    var format = WGPUTextureFormat.RGBA8Unorm

    var tex = TextureArray(device, UInt32(2))
    var base = checker_base()
    var levels = box_levels(base)
    tex.load_layer(device, UInt32(1), levels.copy())

    var target = device.create_texture(
        UInt32(SIZE), UInt32(SIZE), 1, format,
        WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="tex_target",
    )

    var shader = device.create_shader_module_wgsl(TEST_WGSL, "tex_test")
    var entries: List[WGPUBindGroupLayoutEntry] = [
        WGPUBindGroupLayoutEntry(
            null_opaque(), UInt32(0), WGPUShaderStage.FRAGMENT.value, UInt32(0),
            WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.Uniform, UInt32(0), UInt64(0)),
            WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
            WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
        ),
        WGPUBindGroupLayoutEntry(
            null_opaque(), UInt32(1), WGPUShaderStage.FRAGMENT.value, UInt32(0),
            WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.Uniform, UInt32(0), UInt64(0)),
            WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
            WGPUTextureBindingLayout(null_opaque(), UInt32(2), UInt32(3), UInt32(0)),
            WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
        ),
        WGPUBindGroupLayoutEntry(
            null_opaque(), UInt32(2), WGPUShaderStage.FRAGMENT.value, UInt32(0),
            WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.Uniform, UInt32(0), UInt64(0)),
            WGPUSamplerBindingLayout(null_opaque(), UInt32(2)),
            WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
            WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
        ),
    ]
    var bgl = device.create_bind_group_layout(entries)
    var layout = device.create_pipeline_layout(bgl, "tex_layout")
    var pipeline = device.create_render_pipeline(shader, "vs", "fs", format, layout, label="tex_pipeline")
    var uni = device.create_buffer(UInt64(16), WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST, label="tex_uniform")
    var cap = FrameCapture(device, UInt32(SIZE), UInt32(SIZE))

    # mode, layer, lod, then the expected texel source for the check
    var passes = List[List[Int]]()
    passes.append([0, 1, 0])
    passes.append([0, 1, 4])
    passes.append([1, 1, 0])
    for p in passes:
        var u = List[UInt32]()
        u.append(UInt32(p[1]))
        u.append(UInt32(p[2]))
        u.append(UInt32(p[0]))
        u.append(UInt32(0))
        device.queue_write_data(uni, UInt64(0), u)
        var bg_entries: List[WGPUBindGroupEntry] = [
            WGPUBindGroupEntry(null_opaque(), UInt32(0), uni.handle().raw, UInt64(0), UInt64(16), null_opaque(), null_opaque()),
            WGPUBindGroupEntry(null_opaque(), UInt32(1), null_opaque(), UInt64(0), UInt64(0), null_opaque(), tex.view.handle().raw),
            WGPUBindGroupEntry(null_opaque(), UInt32(2), null_opaque(), UInt64(0), UInt64(0), tex.test_sampler.handle().raw, null_opaque()),
        ]
        var bg = device.create_bind_group(bgl, bg_entries, "tex_group")
        var pass_view = target.create_view_default()
        var enc = device.create_command_encoder("tex_enc")
        var rpass = enc.begin_render_pass_clear(pass_view^, WGPUColor(0.0, 0.0, 0.0, 1.0), "tex_pass")
        rpass.set_pipeline(pipeline)
        rpass.set_bind_group(UInt32(0), bg)
        rpass.draw(UInt32(3), UInt32(1), UInt32(0), UInt32(0))
        rpass^.end()
        device.queue_submit(enc^.finish("tex_cmd"))

        var req = cap.capture(device, target.handle().raw)
        req.wait()
        var ptr = req.take()
        var px = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(ptr))
        var worst = 0
        for y in range(SIZE):
            for x in range(SIZE):
                for c in range(3):
                    var got = Int(px[(y * SIZE + x) * 4 + c])
                    var want = 0
                    if p[0] == 0:
                        want = _nearest(levels, p[2], x, y, c)
                    else:
                        want = _triplanar_texel(levels, x, y, c)
                    var d = got - want
                    if d < 0:
                        d = -d
                    if d > worst:
                        worst = d
        cap.unmap()
        var name = "mip " + String(p[2]) + " nearest" if p[0] == 0 else "triplanar +X face"
        print(name, "max channel difference", worst)
        if p[0] == 0:
            s.check(worst == 0, "C1: " + name + " reproduces every texel of the level, exactly")
        else:
            s.check(worst <= 2, "C1: " + name + " reproduces the base texel at (z, y) * 0.25 within 2")
    s.finish()
