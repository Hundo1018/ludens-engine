"""Shell entry: one Mojo program, the C-ABI below is only the JS face.

ludens, wgpu and miniaudio are called Mojo to Mojo; none of it goes through ludens' C-ABI."""
from controls import read_keys
from game.arena_mode import ArenaMode
from game.mode import GameMode
from geometry.vec import Real
from game.camera_view import View
from game.controls import Controls
from game.sfx import cue_clip, CUE_COUNT
from hud import Hud
from net import net_poll, net_send
from render3d import ArenaRenderer
from app.mesh_pass import mesh_probe_hash
from reference import Reference, fill
from render import Renderer
from sim import Sim, SAMPLE_RATE
from wgpu._backend.wgpu_native.alloc_guard import raw_alloc
from wgpu._ffi.types import WGPUTextureFormat, WGPUTextureHandle, WGPUTextureUsage
from wgpu.buffer import MapRequest
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.texture import Texture
from wgpu.rendercanvas.glfw import MojoInputEvent
from wgpu.rendercanvas.input import InputState
from wgpu.surface import Surface, create_surface_canvas
from wgpu.web.boot import GPUBoot

comptime NET_CAP = 65536
comptime NET_PER_FRAME = 16
comptime MODE_DEMO = 0  # the physics demo the parity gates and selftests compare
comptime MODE_GAME = 1  # the arena game


struct App(Movable):
    var boot: GPUBoot
    var surface: Surface
    var width: UInt32
    var height: UInt32
    var configured: Bool
    var sim: Sim
    var input: InputState
    var renderer: Optional[Renderer]
    var capture: Optional[FrameCapture]
    var capture_target: Optional[Texture]
    var capture_req: Optional[MapRequest]
    var capture_ptr: UInt64
    var want_capture: Bool
    var frames: Int
    var reference: Optional[Reference]
    var reference_frames: Int
    var reference_ptr: UInt64
    var offscreen: Bool
    var probe_cube: Bool
    var net_rx: List[UInt8]
    var net_len: Int
    var net_packets: Int
    var mode: Int
    var arena: Optional[ArenaMode]  # the arena game, behind the GameMode seam (game/mode.mojo)
    var frame_ms: Float32  # CPU time of the previous frame, as the page measured it
    var controls: Controls
    var cue_clips: List[Int]  # the scene's clip id of each game cue, by cue number
    var arena_renderer: Optional[ArenaRenderer]
    var hud: Optional[Hud]
    var game_format: UInt32

    def __init__(out self, selector: String, width: UInt32, height: UInt32) raises:
        self.boot = GPUBoot("ludens-engine")
        self.surface = create_surface_canvas(
            self.boot.instance.lib(), self.boot.instance.handle(), selector
        )
        self.width = width
        self.height = height
        self.configured = False
        self.sim = Sim()
        self.input = InputState()
        self.renderer = None
        self.capture = None
        self.capture_target = None
        self.capture_req = None
        self.capture_ptr = 0
        self.want_capture = False
        self.frames = 0
        self.reference = None
        self.reference_frames = -1
        self.reference_ptr = 0
        self.offscreen = False
        self.probe_cube = False
        self.net_rx = List[UInt8](length=NET_CAP, fill=0)
        self.net_len = 0
        self.net_packets = 0
        self.mode = MODE_DEMO
        self.arena = None
        self.frame_ms = 0
        self.controls = Controls()
        self.cue_clips = List[Int]()
        self.arena_renderer = None
        self.hud = None
        self.game_format = 0

    def __init__(out self, *, deinit move: Self):
        self.boot = move.boot^
        self.surface = move.surface^
        self.width = move.width
        self.height = move.height
        self.configured = move.configured
        self.sim = move.sim^
        self.input = move.input^
        self.renderer = move.renderer^
        self.capture = move.capture^
        self.capture_target = move.capture_target^
        self.capture_req = move.capture_req^
        self.capture_ptr = move.capture_ptr
        self.want_capture = move.want_capture
        self.frames = move.frames
        self.reference = move.reference^
        self.reference_frames = move.reference_frames
        self.reference_ptr = move.reference_ptr
        self.offscreen = move.offscreen
        self.probe_cube = move.probe_cube
        self.net_rx = move.net_rx^
        self.net_len = move.net_len
        self.net_packets = move.net_packets
        self.mode = move.mode
        self.arena = move.arena^
        self.frame_ms = move.frame_ms
        self.controls = move.controls^
        self.cue_clips = move.cue_clips^
        self.arena_renderer = move.arena_renderer^
        self.hud = move.hud^
        self.game_format = move.game_format

    def _net(mut self):
        """Take every packet the host has queued; the newest stays readable through app_net_last_*."""
        for _ in range(NET_PER_FRAME):
            var n = net_poll(UInt64(Int(self.net_rx.unsafe_ptr())), UInt64(NET_CAP))
            if n <= 0:
                break
            self.net_len = Int(n)
            self.net_packets += 1

    def _reference(mut self) raises:
        if self.reference_frames >= 0 and not self.reference:
            self.reference = Reference(self.boot.device(), self.width, self.height)
            self.reference.value().start(self.boot.device(), self.reference_frames)
        if self.reference and self.reference_ptr == 0:
            self.reference_ptr = self.reference.value().poll()

    def start_game(mut self) raises:
        if not self.arena:
            self.arena = ArenaMode()
            # The game's sounds go through the audio scene: each cue is synthesised once and registered as a clip.
            self.cue_clips.append(-1)  # cue numbers start at 1
            for cue in range(1, CUE_COUNT + 1):
                self.cue_clips.append(self.sim.scene.add_clip_pcm(cue_clip(cue, Int(SAMPLE_RATE))))
        self.sim.scene.set_tone(330.0, 0.0)  # the demo's contact tone is silent while the game plays
        self.mode = MODE_GAME

    def _step_mode[M: GameMode](mut self, mut m: M, dt: Float64) raises:
        """One frame of a game: read the keys, step it (at most 0.1 s, so a hidden tab does not fast-forward), play its cues."""
        var intent = self.controls.poll(read_keys(self.input))
        m.step(intent, min(dt, 0.1))
        for cue in m.cues():
            if cue > 0 and cue < len(self.cue_clips):
                self.sim.scene.play(self.cue_clips[cue])

    def _draw_mode[M: GameMode](mut self, mut m: M, target: WGPUTextureHandle, format: UInt32, aspect: Float32) raises:
        var view = View(m.camera(), Real(aspect))
        if self.game_format != format:  # the pipelines are built for one target format
            self.hud = None
            self.arena_renderer = None
            self.game_format = format
        if not self.hud:
            self.hud = Hud(self.boot.device(), format)
        if not self.arena_renderer:
            self.arena_renderer = ArenaRenderer(self.boot.device(), format, view)
        self.arena_renderer.value().begin(view)
        self.arena_renderer.value().probe = self.probe_cube
        for it in m.scene():
            self.arena_renderer.value().push(it)
        self.hud.value().set(m.hud(Float32(self.width), Float32(self.height), self.frame_ms), Float32(self.width), Float32(self.height))
        self.arena_renderer.value().draw(self.boot.device(), target, self.width, self.height, self.hud.value())

    def _draw_scene(mut self, target: WGPUTextureHandle, format: UInt32) raises:
        var aspect = Float32(self.width) / Float32(self.height)
        if self.mode == MODE_GAME:
            var m = self.arena.take()
            self._draw_mode(m, target, format, aspect)
            self.arena = m^
            return
        if not self.renderer:
            self.renderer = Renderer(self.boot.device(), format)
        fill(self.renderer.value(), self.sim, aspect)
        self.renderer.value().draw(self.boot.device(), target)

    def _capture(mut self, format: UInt32) raises:
        if self.want_capture and not self.capture_req:
            # Frames are read back from an app-owned target: headless Chrome cannot read a canvas texture.
            if not self.capture:
                self.capture = FrameCapture(self.boot.device(), self.width, self.height)
                self.capture_target = self.boot.device().create_texture(
                    self.width, self.height, 1, format,
                    WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC,
                    label="capture_target",
                )
            var target = self.capture_target.value().handle().raw
            self._draw_scene(target, format)
            self.capture_req = self.capture.value().capture(self.boot.device(), target)
            self.want_capture = False

    def _finish_capture(mut self) raises:
        if self.capture_req and self.capture_req.value().ready():
            var req = self.capture_req.take()
            self.capture_ptr = UInt64(Int(req.take()))

    def frame(mut self, dt: Float64) raises -> Int32:
        """0 while the GPU is still being set up, 1 once a frame was drawn."""
        var rc = self._frame(dt)
        # Every frame ends here, drawn or not: a key edge or a pointer movement lasts exactly one frame.
        self.input.begin_frame()
        return rc

    def _frame(mut self, dt: Float64) raises -> Int32:
        self._net()
        if self.mode == MODE_GAME:
            var m = self.arena.take()
            self._step_mode(m, dt)
            self.arena = m^
        else:
            self.sim.step(dt)
        if not self.boot.step():
            return 0
        if self.offscreen:
            # Never touch the canvas: headless Chrome loses the device after a canvas draw.
            if self.mode != MODE_DEMO:
                self._capture(WGPUTextureFormat.RGBA8Unorm)  # the game still can be looked at, with no canvas draw
            self._reference()
            self._finish_capture()
            return 1
        if not self.configured:
            self.surface.configure(
                self.boot.adapter().handle(), self.boot.device().handle().raw,
                self.width, self.height,
            )
            self.configured = True
        var tex = self.surface.get_current_texture()
        if tex.is_renderable():
            self._draw_scene(tex.texture, self.surface.format())
            self._capture(self.surface.format())
            self.surface.present()
            self.frames += 1
        self._reference()
        self._finish_capture()
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
        var dst = Pointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(dst_ptr))
        a[].sim.render_audio(Int(frames))
        for i in range(Int(frames) * 2):
            dst[i] = a[].sim.pcm[i]
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
    return Int32(_app(app)[].sim.contacts)


@export
def app_body_count(app: UInt64) abi("C") -> Int32:
    return Int32(len(_app(app)[].sim.world.bodies()))


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


@export
def app_reference_request(app: UInt64, frames: Int32) abi("C"):
    """Render the reproducible reference frame (fresh sim, `frames` steps) for the native/web pixel parity."""
    _app(app)[].reference_frames = Int(frames)


@export
def app_reference_ptr(app: UInt64) abi("C") -> UInt64:
    """Address of the reference pixels (RGBA8, rows of app_reference_pitch bytes), 0 until ready."""
    return _app(app)[].reference_ptr


@export
def app_reference_pitch(app: UInt64) abi("C") -> UInt32:
    return _app(app)[].reference.value().pitch()


@export
def app_probe_cube(app: UInt64, on: Int32) abi("C"):
    """On: the arena draws one unit cube at the centre of the view, for the frame check (A.2)."""
    _app(app)[].probe_cube = on != 0


@export
def app_offscreen(app: UInt64, on: Int32) abi("C"):
    """On: frames only render the reference, nothing is drawn to the canvas."""
    _app(app)[].offscreen = on != 0


@export
def app_net_send(app: UInt64, ptr: UInt64, length: UInt64) abi("C") -> Int32:
    """Send `length` bytes at `ptr` as one packet through the host's net_send. 0 = ok."""
    return net_send(ptr, length)


@export
def app_net_packets(app: UInt64) abi("C") -> Int32:
    """Packets received so far through net_poll."""
    return Int32(_app(app)[].net_packets)


@export
def app_net_last_ptr(app: UInt64) abi("C") -> UInt64:
    """Address of the newest received packet (app_net_last_len bytes)."""
    return UInt64(Int(_app(app)[].net_rx.unsafe_ptr()))


@export
def app_net_last_len(app: UInt64) abi("C") -> Int32:
    return Int32(_app(app)[].net_len)


@export
def app_set_mode(app: UInt64, mode: Int32) abi("C") -> Int32:
    """0 = the physics demo (what the selftests and parity gates compare), 1 = the arena game. 0 = ok."""
    try:
        var a = _app(app)
        if mode == MODE_GAME:
            a[].start_game()
        else:
            a[].mode = MODE_DEMO
        return 0
    except e:
        print("app_set_mode:", e)
        return -1


@export
def app_game_status(app: UInt64) abi("C") -> Int32:
    """The game's state: 0 playing, 1 won, 2 lost; -1 when no game is running."""
    var a = _app(app)
    if not a[].arena:
        return -1
    return Int32(a[].arena.value().arena.status())


@export
def app_game_score(app: UInt64) abi("C") -> Int32:
    var a = _app(app)
    return Int32(a[].arena.value().arena.score) if a[].arena else -1


@export
def app_game_collected(app: UInt64) abi("C") -> Int32:
    var a = _app(app)
    return Int32(a[].arena.value().arena.collected()) if a[].arena else -1


@export
def app_mesh_hash() abi("C") -> UInt64:
    """The mesh draw-list hash of the fixed probe scene (app/mesh_pass.mojo mesh_probe_hash). No app handle needed."""
    try:
        return mesh_probe_hash()
    except e:
        print("app_mesh_hash:", e)
        return 0


@export
def app_game_hash(app: UInt64) abi("C") -> UInt64:
    """The game state's hash, for comparing runs."""
    var a = _app(app)
    return a[].arena.value().arena.hash() if a[].arena else 0


@export
def app_release_input(app: UInt64) abi("C"):
    """The page lost focus: let go of every held key and button (their releases happen elsewhere and never arrive)."""
    _app(app)[].input.release_all()
