"""Shell entry: one Mojo program, the C-ABI below is only the JS face.

ludens, wgpu and miniaudio are called Mojo to Mojo; none of it goes through ludens' C-ABI."""
from embed.world import EmbedWorld
from geometry.vec import Vec3
from scene import Scene
from wgpu._backend.wgpu_native.alloc_guard import raw_alloc
from wgpu._ffi.structs import WGPUColor
from wgpu.rendercanvas.glfw import MojoInputEvent
from wgpu.rendercanvas.input import InputState
from wgpu.surface import Surface, create_surface_canvas
from wgpu.web.boot import GPUBoot

comptime CLEAR = WGPUColor(0.05, 0.06, 0.09, 1.0)
comptime SAMPLE_RATE: UInt32 = 48000


struct App(Movable):
    var boot: GPUBoot
    var surface: Surface
    var width: UInt32
    var height: UInt32
    var configured: Bool
    var world: EmbedWorld
    var scene: Scene
    var pcm: List[Float32]
    var input: InputState
    var frames: Int

    def __init__(out self, selector: String, width: UInt32, height: UInt32) raises:
        self.boot = GPUBoot("ludens-shell")
        self.surface = create_surface_canvas(
            self.boot.instance.lib(), self.boot.instance.handle(), selector
        )
        self.width = width
        self.height = height
        self.configured = False
        self.world = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0))
        self.scene = Scene(SAMPLE_RATE)
        self.pcm = List[Float32]()
        self.input = InputState()
        self.frames = 0

    def __init__(out self, *, deinit move: Self):
        self.boot = move.boot^
        self.surface = move.surface^
        self.width = move.width
        self.height = move.height
        self.configured = move.configured
        self.world = move.world^
        self.scene = move.scene^
        self.pcm = move.pcm^
        self.input = move.input^
        self.frames = move.frames

    def frame(mut self, dt: Float64) raises -> Int32:
        """0 while the GPU is still being set up, 1 once a frame was drawn."""
        for _ in range(self.world.ticks_due(dt)):
            self.world.physics_tick()
        if not self.boot.step():
            return 0
        if not self.configured:
            self.surface.configure(
                self.boot.adapter().handle(), self.boot.device().handle().raw,
                self.width, self.height,
            )
            self.configured = True
        var tex = self.surface.get_current_texture()
        if tex.is_renderable():
            var enc = self.boot.device().create_command_encoder("frame")
            var rpass = enc.begin_surface_clear_pass(tex.texture, CLEAR, "frame_pass")
            rpass^.end()
            var cmd = enc^.finish()
            self.boot.device().queue_submit(cmd^)
            self.surface.present()
            self.frames += 1
        self.input.begin_frame()
        return 1


def _app(handle: UInt64) -> Pointer[App, MutUntrackedOrigin]:
    return Pointer[App, MutUntrackedOrigin](unsafe_from_address=Int(handle))


@export
def app_init(selector: UInt64, selector_len: UInt64, width: UInt32, height: UInt32) abi("C") -> UInt64:
    """Create the app on the canvas matching `selector` (UTF-8, not NUL-terminated). 0 on failure."""
    try:
        var bytes = Span(
            unsafe_ptr=Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(selector)),
            length=Int(selector_len),
        )
        var p = raw_alloc[App](1)
        p.unsafe_write(App(String(StringSlice(unsafe_from_utf8=bytes)), width, height))
        return UInt64(Int(p))
    except e:
        print("app_init:", e)
        return 0


@export
def app_frame(app: UInt64, dt: Float64) abi("C") -> Int32:
    """Advance one frame. 0 = setting up, 1 = drew a frame, -1 = error."""
    try:
        return _app(app)[].frame(dt)
    except e:
        print("app_frame:", e)
        return -1


@export
def app_input(
    app: UInt64, kind: Int32, key: Int32, action: Int32, mods: Int32, x: Float64, y: Float64
) abi("C"):
    """A DOM event, already translated to the GLFW codes InputState uses."""
    _app(app)[].input.process_event(MojoInputEvent(kind, key, action, mods, x, y))


@export
def app_resize(app: UInt64, width: UInt32, height: UInt32) abi("C"):
    var a = _app(app)
    a[].width = width
    a[].height = height
    a[].configured = False


@export
def app_audio_render(app: UInt64, dst_ptr: UInt64, frames: UInt32) abi("C") -> Int32:
    """Mix `frames` stereo f32 frames into `dst_ptr`. 0 = ok."""
    try:
        var a = _app(app)
        a[].scene.render(a[].pcm, UInt64(frames))
        var dst = Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(dst_ptr))
        for i in range(Int(frames) * 2):
            dst[i] = a[].pcm[i]
        return 0
    except e:
        print("app_audio_render:", e)
        return -1


@export
def app_destroy(app: UInt64) abi("C"):
    var p = _app(app)
    _ = p.unsafe_take_pointee()
    p.unsafe_free()
