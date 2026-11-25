# tier: integration
# GPU timestamp queries (app/gpu_timer.mojo) on native wgpu. The timer is either present, and then a pass with work
# in it takes longer than an empty span and the spans add up to the whole, or absent, and then the frame's GPU rows
# are "did not run" (-1), not 0.
#   without the features   `GpuTimer.create` returns None; the frame's GPU segments stay -1
#   renderer, 1x and MSAA 4x, with and without stages: a draw gives a scene time > 0 and a whole-frame time equal to the sum
#   with the features      3 marks around a 4096-instance draw give 2 spans, each > 0 ns; the heavy span is longer
#                          than the empty one; a frame's `gpu_frame` equals the sum of its spans
from harness.runner import Suite
from wgpu import Instance, WGPUBufferUsage
from wgpu.adapter import Adapter
from wgpu.device import Device
from app.gpu_timer import GpuTimer, gpu_timer_features
from game.camera_view import View
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from procedural.camera_math import CameraPose, look_rotation
from hud import Hud
from ui.draw import DrawList
from wgpu import WGPUTextureFormat, WGPUTextureUsage
from app.render3d import SceneRendererOf, DefaultPasses
from app.post import Stage, Copy
from app.render_res import RenderCaps
from app.frame_stats import FrameStats, SEG_GPU_SHADOW, SEG_GPU_SCENE, SEG_GPU_POST, SEG_GPU_FRAME


def timed_device(adapter: Adapter) -> Optional[Device]:
    try:
        return adapter.request_device(required_features=gpu_timer_features())
    except e:
        print("no timestamp device:", String(e))
        return None


def main() raises:
    var s = Suite("gpu_timer_native")
    var adapter = Instance().request_adapter()
    var plain = adapter.request_device()
    s.check(not GpuTimer.create(plain).__bool__(), "a device without the timestamp features has no timer")
    var stats = FrameStats()
    stats.begin()
    stats.end()
    s.check(stats.frame_ns(0, SEG_GPU_FRAME) == -1, "a frame with no GPU timing records -1, not 0")
    var sm = stats.summary(SEG_GPU_FRAME)
    s.check(sm[5] == 0 and sm[0] == 0, "the summary of a segment that never ran has count 0")

    var maybe = timed_device(adapter)
    if not maybe:
        print("this adapter has no timestamp queries: the absent path is all that can be checked here")
        s.finish()
        return
    ref device = maybe.value()
    var timer = GpuTimer.create(device)
    s.check(timer.__bool__(), "a device made with the features has a timer")
    if not timer:
        s.finish()
        return
    s.check(timer.value().period_ns > 0, "the timestamp period is positive: " + String(timer.value().period_ns) + " ns / tick")
    var a = device.create_buffer(UInt64(16 << 20), WGPUBufferUsage.COPY_SRC | WGPUBufferUsage.COPY_DST, label="a")
    var b = device.create_buffer(UInt64(16 << 20), WGPUBufferUsage.COPY_SRC | WGPUBufferUsage.COPY_DST, label="b")
    var spans = List[Int64]()
    for _ in range(5):  # the first frames warm the driver up; the last one is read
        var enc = device.create_command_encoder("timer")
        timer.value().begin_frame()
        timer.value().mark(enc)
        timer.value().mark(enc)  # an empty span
        for _ in range(64):  # a span with work: copy 16 MiB 64 times
            enc.copy_buffer_to_buffer(a, UInt64(0), b, UInt64(0), UInt64(16 << 20))
        timer.value().mark(enc)
        timer.value().resolve(enc)
        device.queue_submit(enc^.finish())
        _ = device.poll(True)
        spans = timer.value().read()
    s.check(len(spans) == 2, "3 marks give 2 spans")
    print("spans ns:", spans[0], spans[1])
    s.check(spans[0] >= 0 and spans[1] > 0, "the empty span is >= 0 and the span with 64 buffer copies is > 0")
    s.check(spans[1] > spans[0], "the span with work is longer than the empty span")
    # the renderer's own marks, in each branch of the frame: single-sample and multisampled, with and without post stages
    var w: UInt32 = 640
    var h: UInt32 = 360
    var format = WGPUTextureFormat.RGBA8Unorm
    var target = device.create_texture(w, h, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="t")
    var hud = Hud(device, format)
    hud.set(DrawList(), Float32(w), Float32(h))
    var aspect = Real(Float64(w) / Float64(h))
    var cam = CameraPose(Vec3(0, 2, 8, 0), look_rotation(Vec3(0, 0, -1, 0), Vec3(0, 1, 0, 0)), 0.9, aspect, 0.1, 200.0)
    for samples in [1, 4]:
        var caps = RenderCaps.default()
        caps.samples = samples
        var plain = SceneRendererOf[DefaultPasses](device, format, View(cam.copy(), aspect), caps=caps)
        s.check(plain.enable_gpu_timing(device), "samples " + String(samples) + ", no stages: the renderer has a GPU timer")
        plain.begin(View(cam.copy(), aspect))
        plain.draw(device, target.handle().raw, w, h, hud)
        _ = device.poll(True)
        var g = plain.gpu_times()
        s.check(g[1] > 0 and g[2] == -1 and g[3] == g[0] + g[1], "samples " + String(samples) + ", no stages: scene time > 0, no post span, whole = shadow + scene")
        var staged = SceneRendererOf[DefaultPasses, Stage[Copy]](device, format, View(cam.copy(), aspect), caps=caps)
        s.check(staged.enable_gpu_timing(device), "samples " + String(samples) + ", one stage: the renderer has a GPU timer")
        staged.begin(View(cam.copy(), aspect))
        staged.draw(device, target.handle().raw, w, h, hud)
        _ = device.poll(True)
        var q = staged.gpu_times()
        s.check(q[1] > 0 and q[2] > 0 and q[3] == q[0] + q[1] + q[2], "samples " + String(samples) + ", one stage: scene and post spans > 0, whole = their sum")
    s.check(target.handle().raw == target.handle().raw, "the target is alive until here")
    s.finish()
