# tier: integration
# The arena's centre probe on native wgpu: the rigid cube (mode 1) and the skinned cube with the identity joint (2)
# and with its joint turned 20 deg (3), drawn into an RGBA8 target, read back, centre pixel checked against the
# derived colours. This is the native half of design 1.10 A.2 and the lavapipe half of U3 (a vertex-stage storage
# buffer). Needs a GPU adapter: lavapipe in the parity job.
from harness.runner import Suite
from wgpu import Instance
from wgpu._ffi.types import WGPUTextureFormat, WGPUTextureUsage
from wgpu.capture import FrameCapture, padded_row_pitch
from game.arena_mode import ArenaMode
from game.camera_view import View
from geometry.vec import Real
from hud import Hud
from app.render3d import ArenaRenderer

comptime W: UInt32 = 960
comptime H: UInt32 = 540


def main() raises:
    var s = Suite("arena_probe_native")
    var instance = Instance()
    var device = instance.request_adapter().request_device()
    var format = WGPUTextureFormat.RGBA8Unorm
    var target = device.create_texture(
        W, H, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="probe_target",
    )
    var m = ArenaMode()
    var view = View(m.camera(), Real(Float32(W) / Float32(H)))
    var hud = Hud(device, format)
    hud.set(m.hud(Float32(W), Float32(H), 0.0), Float32(W), Float32(H))
    var renderer = ArenaRenderer(device, format, view)
    var cap = FrameCapture(device, W, H)
    var items = m.scene()
    var pitch = Int(padded_row_pitch(W))
    var expect = List[List[Float64]]()
    expect.append([141.2, 35.3, 35.3])   # mode 1, rigid cube
    expect.append([141.2, 35.3, 35.3])   # mode 2, skinned, identity joint
    expect.append([151.2, 37.8, 37.8])   # mode 3, skinned, joint turned 20 deg
    for mode in range(1, 4):
        renderer.probe = mode
        renderer.begin(view)
        for it in items:
            renderer.push(it)
        renderer.draw(device, target.handle().raw, W, H, hud)
        var req = cap.capture(device, target.handle().raw)
        req.wait()
        var ptr = req.take()
        var px = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(ptr))
        var off = (Int(H) // 2) * pitch + (Int(W) // 2) * 4
        var r = Float64(px[off])
        var g = Float64(px[off + 1])
        var b = Float64(px[off + 2])
        cap.unmap()
        var want = expect[mode - 1].copy()
        var worst = max(abs(r - want[0]), max(abs(g - want[1]), abs(b - want[2])))
        print("mode", mode, "centre rgb", Int(r), Int(g), Int(b), "expected about", Int(want[0]), Int(want[1]), Int(want[2]))
        s.check(worst <= 3.0, "centre pixel of probe mode " + String(mode) + " matches its derived colour within 3")
    s.finish()
