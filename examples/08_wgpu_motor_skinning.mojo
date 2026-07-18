"""The candy-wrapper fix, on screen (wgpu-mojo motor-skinning demo).

The engine's motor-DLB skinning vs classic LBS (geometry/skinning.mojo),
rendered through the wgpu-mojo thin layer (ROADMAP 3.4): a two-bone chain
twists about its axis; each ribbon shows the SKINNED WIDTH of the chain at
every station (the 3D distance between a vertex pair straddling the axis).

  * green (top):  motor DLB — width holds while twisting
  * red (bottom): LBS       — width collapses mid-chain (candy wrapper)

CPU skins the vertices with the engine math each frame; positions stream to
the GPU through a uniform array (matrix-free on the wire — the LookMaNo-
Matrices direction). Auto-closes after ~4 s so `pixi run examples` can run it;
prints the measured mid-chain widths as the machine-checkable evidence.
Skips gracefully on hosts without a display/GPU.
"""

from std.math import sqrt, sin, clamp
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from geometry.mat import Mat4
from geometry.motor import Motor3
from geometry.skinning import SkinVert, skin_motor, skin_lbs

from wgpu import (
    Instance,
    WGPUBufferUsage, WGPUShaderStage, WGPU_WHOLE_SIZE,
    WGPUBindGroupEntry, WGPUColor, BGL,
)
from wgpu.rendercanvas import RenderCanvas
from wgpu._ffi.nulls import null_opaque

comptime NS = 32  # stations along the chain
comptime NV = NS * 2  # ribbon vertices per method
comptime FRAMES_MAX = 240

comptime SKIN_WGSL = """
struct U { pos: array<vec4<f32>, 128> }
@group(0) @binding(0) var<uniform> u: U;

struct VOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) col: vec3<f32>,
}

@vertex
fn vs_main(@builtin(vertex_index) idx: u32) -> VOut {
    var o: VOut;
    let p = u.pos[idx];
    o.pos = vec4<f32>(p.x, p.y, 0.0, 1.0);
    o.col = select(vec3<f32>(1.0, 0.25, 0.2), vec3<f32>(0.2, 1.0, 0.4), idx < 64u);
    return o;
}

@fragment
fn fs_main(in: VOut) -> @location(0) vec4<f32> {
    return vec4<f32>(in.col, 1.0);
}
"""


def _len3(v: Vec3) -> Real:
    return sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])


def main() raises:
    # --- rest pose: vertex pairs straddling the chain axis ------------------
    comptime R: Real = 0.15
    var rest = List[SkinVert]()
    var ia = List[Int]()
    var ib = List[Int]()
    var wa = List[Real]()
    var out_dlb = List[SkinVert]()
    var out_lbs = List[SkinVert]()
    for s in range(NS):
        var x = Real(s) / Real(NS - 1) * 2
        rest.append(SkinVert(Vec3(x, R, 0)))
        rest.append(SkinVert(Vec3(x, -R, 0)))
        for _ in range(2):
            ia.append(0)
            ib.append(1)
            wa.append(clamp(Real(1.5) - x, 0, 1))  # bone0 -> bone1 ramp
            out_dlb.append(SkinVert(Vec3(0, 0, 0)))
            out_lbs.append(SkinVert(Vec3(0, 0, 0)))

    # --- GPU + window (skip cleanly when headless) ---------------------------
    try:
        var instance = Instance()
        var adapter = instance.request_adapter()
        var device = adapter.request_device()
        var canvas = RenderCanvas(
            adapter, device, 960, 540, "ludens: motor DLB vs LBS (candy wrapper)"
        )
        var uniforms = device.create_buffer(
            UInt64(128 * 16),
            WGPUBufferUsage.UNIFORM | WGPUBufferUsage.COPY_DST,
            label="skin_positions",
        )
        var bgl = device.create_bind_group_layout(
            [BGL.buffer_uniform(UInt32(0), WGPUShaderStage.VERTEX.value)],
            "skin_bgl",
        )
        var pl = device.create_pipeline_layout(bgl, "skin_pl")
        var shader = device.create_shader_module_wgsl(SKIN_WGSL, "skin")
        var pipeline = device.create_render_pipeline(
            shader, "vs_main", "fs_main", canvas.surface_format(), pl,
            primitive_topology=UInt32(5),  # TriangleStrip
            label="skin_pipeline",
        )
        _ = shader^
        _ = pl^
        var bind_group = device.create_bind_group(
            bgl,
            [
                WGPUBindGroupEntry(
                    null_opaque(), UInt32(0), uniforms.handle().raw,
                    UInt64(0), WGPU_WHOLE_SIZE, null_opaque(), null_opaque(),
                )
            ],
            "skin_bg",
        )
        _ = bgl^

        print("Rendering DLB (green) vs LBS (red) — closes itself in ~4 s.")
        var frame_idx = 0
        while canvas.is_open() and frame_idx < FRAMES_MAX:
            # frame-indexed time: deterministic and vsync-independent
            var t = Float32(frame_idx) * Float32(1.0 / 60.0)
            canvas.poll()
            var frame = canvas.next_frame()
            if not frame.is_renderable():
                continue

            # --- engine-side skinning: bone1 twists about the chain axis ----
            var theta = Real(sin(t * 1.8)) * 2.8
            var pivot = Vec3(1, 0, 0)
            var bones = List[Motor3]()
            bones.append(Motor3.identity())
            bones.append(
                Motor3.from_translation(pivot)
                * Motor3.from_quat(Quat.from_axis_angle(Vec3(1, 0, 0), theta))
                * Motor3.from_translation(-pivot)
            )
            var mats = List[Mat4]()
            mats.append(bones[0].to_mat4())
            mats.append(bones[1].to_mat4())
            skin_motor(bones, rest, ia, ib, wa, out_dlb)
            skin_lbs(mats, rest, ia, ib, wa, out_lbs)

            # --- ribbons: per-station SKINNED WIDTH, streamed as vec4s ------
            var u = List[Float32](capacity=128 * 4)
            for m in range(2):
                for s in range(NS):
                    var top = out_dlb[s * 2].v if m == 0 else out_lbs[s * 2].v
                    var bot = out_dlb[s * 2 + 1].v if m == 0 else out_lbs[
                        s * 2 + 1
                    ].v
                    var width = _len3(top - bot)
                    var cx = Float32(rest[s * 2].v[0] - 1.0) * 0.8
                    var cy = Float32(0.45) if m == 0 else Float32(-0.45)
                    var h = Float32(width) * 1.2
                    u.append(cx)
                    u.append(cy + h * 0.5)
                    u.append(0)
                    u.append(0)
                    u.append(cx)
                    u.append(cy - h * 0.5)
                    u.append(0)
                    u.append(0)
            device.queue_write_data(uniforms, UInt64(0), u)

            if frame_idx % 60 == 30:
                var wd = _len3(out_dlb[NS].v - out_dlb[NS + 1].v)
                var wl = _len3(out_lbs[NS].v - out_lbs[NS + 1].v)
                print(
                    "  theta=", theta, " mid width: DLB=", wd, " LBS=", wl
                )

            var enc = device.create_command_encoder("skin_frame")
            var rpass = enc.begin_surface_clear_pass(
                frame.texture,
                WGPUColor(Float64(0.05), Float64(0.05), Float64(0.08), Float64(1)),
                "skin_pass",
            )
            rpass.set_pipeline(pipeline)
            rpass.set_bind_group(UInt32(0), bind_group)
            rpass.draw(UInt32(NV), UInt32(1), UInt32(0), UInt32(0))
            rpass.draw(UInt32(NV), UInt32(1), UInt32(NV), UInt32(0))
            rpass^.end()
            device.queue_submit(enc^.finish())
            canvas.present()
            frame_idx += 1
        print("Done —", frame_idx, "frames rendered.")
    except e:
        print("(wgpu demo skipped: ", e, ")")
