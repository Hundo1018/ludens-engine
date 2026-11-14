# tier: integration
# C3 (design 1.8, the triplanar box face), native: a material-2 box (colour 1,1,1) seen from +X by a fixed camera that
# looks down -X. The centre ray hits the +X face at (1, 1/16, 1/16), where uv = (z, y) * 0.25 falls inside the first
# checker cell (texel 4, 4): the cell is red (200, 30, 30), so the bilinear filter returns it exactly. The face's normal
# is +X, so the triplanar blend is the X term alone, and the lit value is 0.4 + 0.6 * (0.4 / 1.2329) = 0.5947.
# Expected centre: (200, 30, 30) * 0.5947 = (118.9, 17.8, 17.8), within 2 counts.
from harness.runner import Suite
from wgpu import Instance
from wgpu._ffi.types import WGPUTextureFormat, WGPUTextureUsage
from wgpu.capture import FrameCapture, padded_row_pitch
from game.camera_view import View
from game.arena import DrawItem
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from app.render3d import ArenaRenderer

comptime W: UInt32 = 960
comptime H: UInt32 = 540


def main() raises:
    var s = Suite("texture_c3_native")
    var instance = Instance()
    var device = instance.request_adapter().request_device()
    var format = WGPUTextureFormat.RGBA8Unorm
    var target = device.create_texture(
        W, H, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="c3_target",
    )
    var rot = look_rotation(Vec3(Real(-1.0), Real(0.0), Real(0.0), Real(0.0)), Vec3(Real(0.0), Real(1.0), Real(0.0), Real(0.0)))
    var cam = CameraPose(Vec3(Real(4.0), Real(0.0625), Real(0.0625), Real(0.0)), rot, Real(0.7), Real(Float32(W) / Float32(H)), Real(0.1), Real(100.0))
    var view = View(cam, Real(Float32(W) / Float32(H)))
    var hud = Hud(device, format)
    var renderer = ArenaRenderer(device, format, view)
    renderer.begin(view)
    # a 1 m cube at the origin: the unit mesh (half-extent 0.5) scaled by half = 1, material 2 on layer 1
    renderer.push(DrawItem(-1, Vec3(Real(0.0), Real(0.0), Real(0.0), Real(0.0)), 0.0, 0.0, 0.0, 1.0,
                           Vec3(Real(1.0), Real(1.0), Real(1.0), Real(0.0)), Vec3(Real(1.0), Real(1.0), Real(1.0), Real(0.0)),
                           renderer.cube, -1, 2))
    renderer.draw(device, target.handle().raw, W, H, hud)
    var cap = FrameCapture(device, W, H)
    var req = cap.capture(device, target.handle().raw)
    req.wait()
    var ptr = req.take()
    var px = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(ptr))
    var pitch = Int(padded_row_pitch(W))
    var off = (Int(H) // 2) * pitch + (Int(W) // 2) * 4
    var r = Int(px[off])
    var g = Int(px[off + 1])
    var b = Int(px[off + 2])
    cap.unmap()
    _ = target.handle().raw  # keep the texture alive until the readback has finished
    print("C3 centre rgb", r, g, b, "expected about 119 18 18")
    s.check(abs(r - 119) <= 2 and abs(g - 18) <= 2 and abs(b - 18) <= 2,
            "C3: the +X face's centre is the first checker cell, lit, within 2 counts")
    s.finish()
