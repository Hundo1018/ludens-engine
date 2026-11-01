"""Shell entry: one Mojo program, the C-ABI below is only the JS face.

ludens, wgpu and miniaudio are called Mojo to Mojo; none of it goes through ludens' C-ABI."""
from embed.world import EmbedWorld
from geometry.vec import Real, Vec3
from render import Renderer
from scene import Scene
from wgpu._backend.wgpu_native.alloc_guard import raw_alloc
from wgpu._ffi.types import WGPUTextureUsage
from wgpu.buffer import MapRequest
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.texture import Texture
from wgpu.rendercanvas.glfw import MojoInputEvent
from wgpu.rendercanvas.input import InputState
from wgpu.surface import Surface, create_surface_canvas
from wgpu.web.boot import GPUBoot

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
    var renderer: Optional[Renderer]
    var handles: List[Int64]
    var halves: List[Float64]
    var capture: Optional[FrameCapture]
    var capture_target: Optional[Texture]
    var capture_req: Optional[MapRequest]
    var capture_ptr: UInt64
    var want_capture: Bool
    var frames: Int
    var contacts: Int
    var tone_gain: Float32

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
        self.renderer = None
        self.handles = List[Int64]()
        self.halves = List[Float64]()
        self.capture = None
        self.capture_target = None
        self.capture_req = None
        self.capture_ptr = 0
        self.want_capture = False
        self.frames = 0
        self.contacts = 0
        self.tone_gain = 0.0
        self._populate()

    def _populate(mut self) raises:
        """A floor and a column of boxes that fall onto it."""
        self._box(Vec3(0.0, -1.0, 0.0), Vec3(20.0, 1.0, 20.0), 0.0, True)
        for i in range(16):
            var x = Real(i % 4) * 1.2 - 1.8
            var y = Real(2 + i) * 1.1
            self._box(Vec3(x, y, 0.0), Vec3(0.5, 0.5, 0.5), 1.0, False)

    def _box(mut self, pos: Vec3, half: Vec3, mass: Real, is_static: Bool) raises:
        self.handles.append(self.world.add_box(pos, half, mass, is_static))
        self.halves.append(Float64(half[0]))
        self.halves.append(Float64(half[1]))
        self.halves.append(Float64(half[2]))

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
        self.renderer = move.renderer^
        self.handles = move.handles^
        self.halves = move.halves^
        self.capture = move.capture^
        self.capture_target = move.capture_target^
        self.capture_req = move.capture_req^
        self.capture_ptr = move.capture_ptr
        self.want_capture = move.want_capture
        self.frames = move.frames
        self.contacts = move.contacts
        self.tone_gain = move.tone_gain

    def frame(mut self, dt: Float64) raises -> Int32:
        """0 while the GPU is still being set up, 1 once a frame was drawn."""
        for _ in range(self.world.ticks_due(dt)):
            self.world.physics_tick()
        var hits = len(self.world.frame_events)
        if hits > 0:
            self.contacts += hits
            self.tone_gain = 0.35
        else:
            self.tone_gain *= 0.85
        self.scene.set_tone(Float32(330.0 + 20.0 * Float64(min(hits, 20))), self.tone_gain)
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
            if not self.renderer:
                self.renderer = Renderer(self.boot.device(), self.surface.format())
            self.renderer.value().begin(Float32(self.width) / Float32(self.height))
            for i in range(len(self.handles)):
                var st = self.world.state(self.handles[i])
                self.renderer.value().push(
                    Float64(st.pos[0]), Float64(st.pos[1]), Float64(st.pos[2]),
                    Float64(st.rot.x), Float64(st.rot.y), Float64(st.rot.z), Float64(st.rot.w),
                    self.halves[3 * i], self.halves[3 * i + 1], self.halves[3 * i + 2],
                )
            self.renderer.value().draw(self.boot.device(), tex.texture)
            if self.want_capture and not self.capture_req:
                # Frames are read back from an app-owned target: headless Chrome cannot read a canvas texture.
                if not self.capture:
                    self.capture = FrameCapture(self.boot.device(), self.width, self.height)
                    self.capture_target = self.boot.device().create_texture(
                        self.width, self.height, 1, self.surface.format(),
                        WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC,
                        label="capture_target",
                    )
                var target = self.capture_target.value().handle().raw
                self.renderer.value().draw(self.boot.device(), target)
                self.capture_req = self.capture.value().capture(self.boot.device(), target)
                self.want_capture = False
            self.surface.present()
            self.frames += 1
        if self.capture_req and self.capture_req.value().ready():
            var req = self.capture_req.take()
            self.capture_ptr = UInt64(Int(req.take()))
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


@export
def app_contacts(app: UInt64) abi("C") -> Int32:
    """Contact events seen since init."""
    return Int32(_app(app)[].contacts)


@export
def app_body_count(app: UInt64) abi("C") -> Int32:
    return Int32(len(_app(app)[].world.bodies()))


@export
def app_request_capture(app: UInt64) abi("C"):
    """Capture the next drawn frame; poll app_capture_ptr for the pixels."""
    _app(app)[].want_capture = True


@export
def app_capture_ptr(app: UInt64) abi("C") -> UInt64:
    """Address of the captured pixels in wasm memory, 0 until ready (rows are app_capture_pitch bytes)."""
    return _app(app)[].capture_ptr


@export
def app_capture_pitch(app: UInt64) abi("C") -> UInt32:
    return padded_row_pitch(_app(app)[].width)


@export
def app_capture_release(app: UInt64) abi("C"):
    """Unmap the captured frame so another capture can follow."""
    var a = _app(app)
    if a[].capture_ptr != 0:
        a[].capture.value().unmap()
        a[].capture_ptr = 0


@export
def app_format(app: UInt64) abi("C") -> UInt32:
    """The surface's texture format (WGPUTextureFormat); the capture has the same layout."""
    return _app(app)[].surface.format()
