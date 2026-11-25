"""Shell entry: one Mojo program, the C-ABI below is only the JS face.

`App` is `AppOf[DemoMode, DefaultPasses]`: the shell around one game (a `GameMode`, game/mode.mojo) drawn through one
render pipeline: a pass list (app/render_pass.mojo), a graph of post stages (app/post.mojo) and an aux pass list.
Another game reuses this shell by naming its own types, e.g.
`AppOf[MyMode, Then[ShadowPass, DefaultPasses], History[Stage[MyStyle]], Aux[NormalPasses]]` (docs/PIPELINES.md);
the C-ABI below exports the default instance.

ludens, wgpu and miniaudio are called Mojo to Mojo; none of it goes through ludens' C-ABI."""
from audio_assets import load_music, lsound_to_mono
from access_host import AccessHost
from audio_event import AudioEvent, BUS_MUSIC, parse_events
from audio_math import Rng
from controls import (
    KEY_BACKSPACE, KEY_E, KEY_ENTER, KEY_F2, KEY_F3, KEY_F8, KEY_F9, KEY_GRAVE, KEY_Q, MOUSE_LEFT, read_frame, typed_text,
)
from frame_stats import (
    FrameStats, now_ns, SEG_NET, SEG_STEP, SEG_PHYSICS, SEG_AI, SEG_SCENE, SEG_PUSH, SEG_HUD, SEG_DRAW, SEG_PRESENT, SEG_FRAME,
    CTR_DRAWS, CTR_TRIANGLES, CTR_TEXTURE_BYTES, CTR_PARTICLES, CTR_BODIES, CTR_AI_AGENTS,
)
from perf_overlay import perf_overlay
from game.demo_mode import DemoMode
from game.mode import GameMode
from game.console import CONSOLE_BUILT, CommandSpec, Console, ConsoleLine
from game.intent import Intent
from game.photo_camera import PhotoMode
from std.math import sqrt
from photo import PhotoCapture, PhotoPost, apply_photo
from platform.achievements import CheatGuard, LocalAchievements
from ui.draw import Color, DrawList
from ui.geom import Rect
from geometry.vec import Real
from game.camera_view import View
from game.action_map import parse_source, slot_of
from game.controls import Controls
from game.input_strings import input_localizer, prompt_text
from hud import Hud, refresh_hud
from platform.transport import NET_DROPPED, NET_NONE
from os_router import OsRouter
from profile import ProfileStore
from platform.transport_web import WebSocketTransport
from render3d import SceneRendererOf, DefaultPasses
from app.render_pass import RenderPass, AuxTarget, NoAux
from app.post import PostEffect, NoPost, scene_aspect
from app.mesh_pass import mesh_probe_hash
from app.skin_gpu import GpuSkinning, SkinJob
from app.skin_pass import CpuSkinning, Skinning, synthetic_scene
from geometry.vec import Vec3
from reference import Reference, fill
from particle_frame import ParticleReference
from post_fx_frame import PostFxFrames
from render import Renderer
from sim import Sim, SAMPLE_RATE
from ui.loc import Localizer
from ui.scale import UiEnv
from ui.sdf_font import FontMetrics, SdfFont
from ui.geom import Insets
from wgpu import raw_alloc
from wgpu import WGPUTextureFormat, WGPUTextureHandle, WGPUTextureUsage
from wgpu.buffer import MapRequest
from wgpu.capture import FrameCapture, padded_row_pitch
from wgpu.texture import Texture
from wgpu.rendercanvas.glfw import MojoInputEvent
from wgpu.rendercanvas.input import InputState
from wgpu.surface import Surface, create_surface_canvas
from wgpu.web.boot import GPUBoot

comptime NetTransport = WebSocketTransport  # the Transport backend (platform/transport.mojo), chosen at build time
comptime NET_CAP = 65536
comptime NET_PER_FRAME = 16
comptime MODE_DEMO = 0  # the physics demo the parity gates and selftests compare
comptime MODE_GAME = 1  # the game (App.M)


struct AppOf[M: GameMode, P: RenderPass, F: PostEffect = NoPost, A: AuxTarget = NoAux](Movable):
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
    var capture_width: UInt32  # the size the capture buffer and target were made for (app_resize can change width)
    var capture_height: UInt32
    var want_capture: Bool
    var frames: Int
    var reference: Optional[Reference]
    var reference_frames: Int
    var reference_ptr: UInt64
    var particle_reference: Optional[ParticleReference]  # #121: the particle frame of the pixel parity
    var particles_requested: Bool
    var particles_ptr: UInt64
    var post_fx_frames: Optional[PostFxFrames]  # #139: the picture-effects frames of the pixel parity
    var post_fx_requested: Bool
    var post_fx_ptr: List[UInt64]
    var offscreen: Bool
    var probe_cube: Int
    var skin_job: Optional[SkinJob]
    var skin_cpu: List[Vec3]
    var skin_max: Float64  # -1 pending, -2 failed, else max |GPU - CPU|
    var net: NetTransport
    var net_rx: List[UInt8]
    var net_len: Int
    var net_packets: Int
    var mode: Int
    var game: Optional[Self.M]  # the game, behind the GameMode seam (game/mode.mojo)
    var frame_ms: Float32  # CPU time of the previous frame, as the page measured it
    var game_frames: Int  # game frames stepped since the game started (`window.game` events carry it)
    var event_log: List[Int]  # (game frame, cue) pairs raised since the last app_events, flattened
    var out_text: String  # what app_state / app_events last wrote; app_text_ptr is its address
    var controls: Controls
    var os_router: OsRouter  # the one reader of os_poll; the profile, and later the saves, take their results from it
    var profile: ProfileStore  # the saved bindings and accessibility settings (app/profile.mojo)
    var acc: AccessHost  # the player's accessibility settings, captions and camera shake (app/access_host.mojo)
    var input_loc: Localizer  # display names of the input sources (game/input_strings.mojo)
    var cue_events: List[Int]  # the mixer's event id of each game cue, by cue number (-1 for cue 0)
    var game_renderer: Optional[SceneRendererOf[Self.P, Self.F, Self.A]]
    var hud: Optional[Hud]
    var font_data: List[UInt8]  # the .lfont the page loaded (app_load_font); the HUD's atlas is made from it
    var font_metrics: Optional[FontMetrics]
    var font_dirty: Bool  # the game has not been given font_metrics yet
    var ui_env: UiEnv  # safe-area insets, text scale and locale from the page (app_set_ui)
    var game_format: UInt32
    var perf_shown: Bool  # F3: the frame-time overlay (app/perf_overlay.mojo) is drawn over the HUD
    var perf_key_was: Bool
    var overlay_key_was: Bool  # the overlay key (F2) was down at the last draw: `toggle` is its rising edge as drawn
    var export_file: String  # a file the game asked the host to save and the host has not taken yet (app_take_export)
    var stats: FrameStats  # per-segment CPU time of the last FRAME_RING frames (app/frame_stats.mojo, app_frame_stats)
    var console: Console  # ` opens it (game/console.mojo); empty and inert in a release build
    var console_ready: Bool  # the game's commands and the host's photo cvars are registered
    var photo: PhotoMode  # F9 (game/photo_camera.mojo): the game stands still, a free camera, F8 captures
    var photo_renderer: Optional[SceneRendererOf[Self.P, PhotoPost, Self.A]]  # made on the first photo frame (app/photo.mojo)
    var photo_hud: Optional[Hud]  # an empty HUD for photo frames (the HUD is hidden) and the capture
    var photo_capture: Optional[PhotoCapture]
    var photo_want: Bool  # F8 or app_photo_capture: capture on the next drawn photo frame
    var photo_png: List[UInt8]  # the latest capture, until the page takes it (app_take_photo)
    var achievements: CheatGuard[LocalAchievements]  # refuses unlocks once the game reports a cheat (platform/achievements.mojo)

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
        self.capture_width = 0
        self.capture_height = 0
        self.want_capture = False
        self.frames = 0
        self.reference = None
        self.reference_frames = -1
        self.reference_ptr = 0
        self.particle_reference = None
        self.particles_requested = False
        self.particles_ptr = 0
        self.post_fx_frames = None
        self.post_fx_requested = False
        self.post_fx_ptr = [UInt64(0), UInt64(0)]
        self.offscreen = False
        self.probe_cube = 0
        self.skin_job = None
        self.skin_cpu = List[Vec3]()
        self.skin_max = -1.0
        self.net = NetTransport()
        self.net_rx = List[UInt8](length=NET_CAP, fill=0)
        self.net_len = 0
        self.net_packets = 0
        self.mode = MODE_DEMO
        self.game = None
        self.frame_ms = 0
        self.game_frames = 0
        self.event_log = List[Int]()
        self.out_text = String()
        self.controls = Controls()
        self.os_router = OsRouter()
        self.profile = ProfileStore(self.os_router)
        self.acc = AccessHost()
        self.input_loc = input_localizer()
        self.cue_events = List[Int]()
        self.game_renderer = None
        self.hud = None
        self.font_data = List[UInt8]()
        self.font_metrics = None
        self.font_dirty = False
        self.ui_env = UiEnv.default()
        self.game_format = 0
        self.stats = FrameStats()
        self.export_file = String()
        self.overlay_key_was = False
        self.perf_shown = False
        self.perf_key_was = False
        self.console = Console()
        self.console_ready = False
        self.photo = PhotoMode()
        self.photo_renderer = None
        self.photo_hud = None
        self.photo_capture = None
        self.photo_want = False
        self.photo_png = List[UInt8]()
        self.achievements = CheatGuard[LocalAchievements](LocalAchievements())

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
        self.capture_width = move.capture_width
        self.capture_height = move.capture_height
        self.want_capture = move.want_capture
        self.frames = move.frames
        self.reference = move.reference^
        self.reference_frames = move.reference_frames
        self.reference_ptr = move.reference_ptr
        self.particle_reference = move.particle_reference^
        self.particles_requested = move.particles_requested
        self.particles_ptr = move.particles_ptr
        self.post_fx_frames = move.post_fx_frames^
        self.post_fx_requested = move.post_fx_requested
        self.post_fx_ptr = move.post_fx_ptr^
        self.offscreen = move.offscreen
        self.probe_cube = move.probe_cube
        self.skin_job = move.skin_job^
        self.skin_cpu = move.skin_cpu^
        self.skin_max = move.skin_max
        self.net = move.net^
        self.net_rx = move.net_rx^
        self.net_len = move.net_len
        self.net_packets = move.net_packets
        self.mode = move.mode
        self.game = move.game^
        self.frame_ms = move.frame_ms
        self.game_frames = move.game_frames
        self.event_log = move.event_log^
        self.out_text = move.out_text^
        self.controls = move.controls^
        self.os_router = move.os_router
        self.profile = move.profile^
        self.acc = move.acc^
        self.input_loc = move.input_loc^
        self.cue_events = move.cue_events^
        self.game_renderer = move.game_renderer^
        self.hud = move.hud^
        self.font_data = move.font_data^
        self.font_metrics = move.font_metrics^
        self.font_dirty = move.font_dirty
        self.ui_env = move.ui_env
        self.game_format = move.game_format
        self.stats = move.stats^
        self.export_file = move.export_file^
        self.overlay_key_was = move.overlay_key_was
        self.perf_shown = move.perf_shown
        self.perf_key_was = move.perf_key_was
        self.console = move.console^
        self.console_ready = move.console_ready
        self.photo = move.photo^
        self.photo_renderer = move.photo_renderer^
        self.photo_hud = move.photo_hud^
        self.photo_capture = move.photo_capture^
        self.photo_want = move.photo_want
        self.photo_png = move.photo_png^
        self.achievements = move.achievements^

    def take_export(mut self, out_ptr: UInt64, cap: UInt64) -> Int32:
        if self.export_file.byte_length() == 0 and self.mode == MODE_GAME and self.game:
            var m = self.game.take()
            self.export_file = m.take_export()
            self.game = m^
        var n = self.export_file.byte_length()
        if n == 0:
            return 0
        if UInt64(n) > cap:
            return Int32(-n)
        var dst = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(out_ptr))
        var bytes = self.export_file.as_bytes()
        for i in range(n):
            dst[i] = bytes[i]
        self.export_file = String()
        return Int32(n)

    def _net(mut self):
        """Take every packet the host has queued; the newest stays readable through app_net_last_*. The saved input profile
        is asked for on the first frame and applied when it arrives."""
        _ = self.profile.request()
        self.profile.poll(self.controls.actions, self.acc.access)
        for _ in range(NET_PER_FRAME):
            var n = self.net.poll(UInt64(Int(self.net_rx.unsafe_ptr())), NET_CAP)
            if n == NET_DROPPED:
                continue  # a packet larger than NET_CAP: the host dropped it (net_host status.dropped); take the next
            if n <= NET_NONE:
                break  # nothing waiting, or (another backend) NET_CLOSED
            self.net_len = Int(n)
            self.net_packets += 1

    def _reference(mut self) raises:
        if self.reference_frames >= 0 and not self.reference:
            self.reference = Reference(self.boot.device(), self.width, self.height)
            self.reference.value().start(self.boot.device(), self.reference_frames)
        if self.reference and self.reference_ptr == 0:
            self.reference_ptr = self.reference.value().poll()
        if self.particles_requested and not self.particle_reference:
            self.particle_reference = ParticleReference(self.boot.device())
            self.particle_reference.value().start(self.boot.device())
        if self.particle_reference and self.particles_ptr == 0:
            self.particles_ptr = self.particle_reference.value().poll()
        if self.post_fx_requested and not self.post_fx_frames:
            self.post_fx_frames = PostFxFrames(self.boot.device())
            self.post_fx_frames.value().start(self.boot.device())
        if self.post_fx_frames:
            for i in range(2):
                if self.post_fx_ptr[i] == 0:
                    self.post_fx_ptr[i] = self.post_fx_frames.value().poll(i)

    def start_game(mut self) raises:
        if not self.game:
            self.game = Self.M.create()
            # The game's sounds go through the mixer: each clip is registered as `cueN`, and cue N plays the event of that name (the
            # game's own `audio_events()`, or a default spatial event).
            var clips = self.game.value().sounds(Int(SAMPLE_RATE))
            for i in range(len(clips)):
                _ = self.sim.mixer.add_clip("cue" + String(i + 1), clips[i].copy())
            for ev in parse_events(self.game.value().audio_events()):
                _ = self.sim.mixer.add_event(ev.copy())
            self.cue_events.append(-1)  # cue numbers start at 1
            for i in range(len(clips)):
                var name = "cue" + String(i + 1)
                if self.sim.mixer.event_id(name) < 0:
                    var ev = AudioEvent(name)
                    ev.clip_names.append(name)
                    ev.spatial = True
                    ev.min_distance = 8.0
                    _ = self.sim.mixer.add_event(ev^)
                self.cue_events.append(self.sim.mixer.event_id(name))
        self.sim.mixer.set_bus_db(BUS_MUSIC, -14.0)  # music sits under the effects by default
        self.sim.scene.set_tone(330.0, 0.0)  # the demo's contact tone is silent while the game plays
        self.mode = MODE_GAME

    def _advance(mut self, dt: Float64) raises:
        """The simulation half of a frame: the game (or the physics demo) takes its step."""
        if self.mode == MODE_GAME:
            var m = self.game.take()
            # the mode goes back into its slot even when the call raises: the next frame takes it again
            var failed = String()
            try:
                self._step_mode(m, dt)
            except e:
                failed = String(e)
            self.game = m^
            if failed.byte_length() > 0:
                raise Error(failed)
        else:
            self.sim.step(dt)

    def step_only(mut self, dt: Float64) raises:
        """A frame with no drawing and no presenting (`window.game.step(n, false)`): the packets are read, the game steps, and the
        key edges of this frame end. The GPU is not touched, so it works before the device is ready and under node."""
        self._net()
        self._advance(dt)
        self.input.begin_frame()

    def configure_game(mut self, seed: UInt64, scene: String) raises -> Int32:
        """Start the game over in `scene` with `seed` (`?seed=`, `?scene=`). 0 = ok, -1 = the game has no seeds or scenes."""
        self.start_game()
        self.game_frames = 0
        self.event_log.clear()
        self.sim.mixer.rng = Rng(seed)  # the clip and pitch drawn for each play follow the seed, so a replay sounds the same
        return 0 if self.game.value().reset(seed, scene) else -1

    def _console_setup(mut self, m: Self.M) raises:
        if self.console_ready:
            return
        self.console_ready = True
        for spec in m.console_commands():
            self.console.register(spec.copy())
        # the photo settings (game/photo_camera.mojo), applied by the host and never passed to the game
        self.console.register(CommandSpec.cvar("photo.focus", False, Float64(self.photo.focus), 0.2, 1000.0))
        self.console.register(CommandSpec.cvar("photo.fstop", False, 0.0, 0.0, 32.0))
        self.console.register(CommandSpec.cvar("photo.exposure", False, 0.0, -4.0, 4.0))
        self.console.register(CommandSpec.cvar("photo.bloom", False, 0.0, 0.0, 4.0))
        self.console.register(CommandSpec.cvar("photo.scale", True, 2.0, 1.0, 8.0))

    def run_console(mut self, mut m: Self.M) raises:
        """The console's lines for this game frame: a loaded replay's first, then the queue, each run before `step`. A
        line the game refuses is printed, not raised; a cheat marks the achievements guard."""
        self._console_setup(m)
        try:
            self.console.due(self.game_frames)
        except e:
            self.console.print_line(String(e))
        for line in self.console.take():
            if line.name.startswith("photo."):
                self._photo_set(line.name, Float32(line.number(0)))
                continue
            try:
                var answer = m.run_command(line)
                if answer.byte_length() > 0:
                    self.console.print_line(answer)
            except e:
                self.console.print_line(String(e))
        if m.cheated():
            self.achievements.mark_cheated()

    def _photo_set(mut self, name: String, v: Float32) -> Float32:
        if name == "photo.focus":
            return self.photo.set_focus(v)
        if name == "photo.fstop":
            return self.photo.set_fstop(v)
        if name == "photo.exposure":
            return self.photo.set_exposure(v)
        if name == "photo.bloom":
            return self.photo.set_bloom(v)
        return Float32(self.photo.set_scale(Int(v)))

    def toggle_photo(mut self, m: Self.M):
        if self.photo.active:
            self.photo.leave()
        else:
            self.photo.enter(self.acc.camera(m.camera()))

    def _step_mode(mut self, mut m: Self.M, dt: Float64) raises:
        """One frame of a game: read the keys, run the console's lines, step it (at most 0.1 s, so a hidden tab does not
        fast-forward), play its cues. With the console open the keys type into it; in photo mode the game is not
        stepped and the keys fly the free camera."""
        if self.input.is_key_just_pressed(KEY_GRAVE):
            self.console.toggle()
        elif self.console.open:
            self.console.type_text(typed_text(self.input))
            if self.input.is_key_just_pressed(KEY_BACKSPACE):
                self.console.backspace()
            if self.input.is_key_just_pressed(KEY_ENTER):
                self.console.enter(self.game_frames)
        if self.input.is_key_just_pressed(KEY_F9):
            self.toggle_photo(m)
        if self.photo.active and self.input.is_key_just_pressed(KEY_F8):
            self.photo_want = True
        self.run_console(m)
        var intent = self.controls.poll(read_frame(self.input))
        if self.console.open:
            intent = Intent.idle()  # the keys are typing
        if self.photo.active:
            var up = Real(0)
            if not self.console.open:
                up = Real(1 if self.input.is_key_pressed(KEY_E) else 0) - Real(1 if self.input.is_key_pressed(KEY_Q) else 0)
            self.photo.move(intent.forward, intent.right, up, intent.look_dx, intent.look_dy, min(dt, 0.1))
            return  # the simulation stands still: no step, no game frame, no cues
        m.step(intent, min(dt, 0.1))
        self.game_frames += 1
        self.stats.add(SEG_PHYSICS, m.physics_ns())  # inside the step segment; -1 (not measured) records nothing
        self.stats.add(SEG_AI, m.ai_ns())
        var gc = m.counters()
        self.stats.set_counter(CTR_PARTICLES, gc.particles)
        self.stats.set_counter(CTR_BODIES, gc.bodies)
        self.stats.set_counter(CTR_AI_AGENTS, gc.ai_agents)
        # The listener is the camera: its position, the direction it looks along and its up axis (the mixer's spatializers
        # place every positioned voice relative to it).
        var cam = m.camera()
        var fwd = cam.forward()
        var up = cam.up()
        self.sim.mixer.set_listener(
            Float32(cam.position[0]), Float32(cam.position[1]), Float32(cam.position[2]),
            Float32(fwd[0]), Float32(fwd[1]), Float32(fwd[2]), Float32(up[0]), Float32(up[1]), Float32(up[2]),
        )
        for cue in m.cues():
            self.event_log.append(self.game_frames)
            self.event_log.append(cue)
            if cue > 0 and cue < len(self.cue_events):
                _ = self.sim.mixer.play_event(self.cue_events[cue], flat=True)  # no position: heard from the center
                self.acc.heard(self.sim.mixer, self.cue_events[cue])
        for c in m.positioned_cues():
            if c.logged:
                self.event_log.append(self.game_frames)
                self.event_log.append(c.cue)
            if c.cue > 0 and c.cue < len(self.cue_events):
                _ = self.sim.mixer.play_event(self.cue_events[c.cue], c.x, c.y, c.z, c.gain_db, False, c.vx, c.vy, c.vz)
                self.acc.heard(self.sim.mixer, self.cue_events[c.cue])
        self.acc.step(self.sim.mixer, min(dt, 0.1))

    def _console_list(self, width: Float32) -> DrawList:
        """The console panel: its last lines and the line being typed, across the top of the frame."""
        var dl = DrawList()
        comptime if CONSOLE_BUILT:
            if self.console.open:
                var size = Float32(15)
                var lh = size * 1.4
                var n = len(self.console.lines)
                dl.fill(Rect(0, 0, width, lh * Float32(n + 1) + 12), Color(0.02, 0.03, 0.05, 0.88))
                for i in range(n):
                    dl.text(Rect(8, 6 + lh * Float32(i), width - 16, lh), self.console.lines[i], Color(0.85, 0.9, 1.0, 1.0), size)
                dl.text(Rect(8, 6 + lh * Float32(n), width - 16, lh), "] " + self.console.edit + "_", Color(1.0, 1.0, 0.6, 1.0), size)
        return dl^

    def _draw_photo(mut self, mut m: Self.M, target: WGPUTextureHandle, format: UInt32, aspect: Float32) raises:
        """A photo frame: the free camera through the photo pipeline (app/photo.mojo), no HUD (only the console, when
        open); a capture asked for is drawn at the capture size into its own texture and read back."""
        var view = View(self.photo.pose(), Real(aspect))
        if not self.photo_renderer:
            self.photo_renderer = SceneRendererOf[Self.P, PhotoPost, Self.A](self.boot.device(), format, view)
            self.photo_hud = Hud(self.boot.device(), format)
            if len(self.font_data) > 0:
                self.photo_hud.value().set_font(self.boot.device(), self.font_data.copy())
        apply_photo(self.photo_renderer.value(), self.photo)
        var items = m.scene()
        if self.photo_want and not self.photo_capture:
            self.photo_want = False
            var size = self.photo.capture_size(Int(self.width), Int(self.height))
            var pc = PhotoCapture(self.boot.device(), UInt32(size[0]), UInt32(size[1]), format)
            self.photo_hud.value().set(DrawList(), Float32(size[0]), Float32(size[1]))
            self.photo_renderer.value().begin(view.copy())
            for it in items:
                self.photo_renderer.value().push(it)
            pc.start(self.boot.device(), self.photo_renderer.value(), self.photo_hud.value())
            self.photo_hud.value().uploaded()
            self.photo_capture = pc^
        self.photo_renderer.value().begin(view.copy())
        for it in items:
            self.photo_renderer.value().push(it)
        self.photo_hud.value().set(self._console_list(Float32(self.width)), Float32(self.width), Float32(self.height))
        self.photo_renderer.value().draw(self.boot.device(), target, self.width, self.height, self.photo_hud.value())
        self.photo_hud.value().uploaded()

    def _finish_photo(mut self) raises:
        if self.photo_capture and self.photo_capture.value().poll():
            self.photo_png = self.photo_capture.value().png.copy()
            self.photo_capture = None

    def take_photo(mut self, out_ptr: UInt64, cap: UInt64) -> Int32:
        var n = len(self.photo_png)
        if n == 0:
            return 0
        if UInt64(n) > cap:
            return Int32(-n)
        var dst = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(out_ptr))
        for i in range(n):
            dst[i] = self.photo_png[i]
        self.photo_png = List[UInt8]()
        return Int32(n)

    def _draw_mode(mut self, mut m: Self.M, target: WGPUTextureHandle, format: UInt32, aspect: Float32) raises:
        if self.photo.active:
            self._draw_photo(m, target, format, aspect)
            return
        # a pipeline that draws the scene for a picture of its own proportions (SceneSize) sets the camera's
        var view = View(self.acc.camera(m.camera()), Real(scene_aspect[Self.F](Float64(aspect))))
        if self.game_format != format:  # the pipelines are built for one target format
            self.hud = None
            self.game_renderer = None
            self.game_format = format
        if not self.hud:
            self.hud = Hud(self.boot.device(), format)
            if len(self.font_data) > 0:
                self.hud.value().set_font(self.boot.device(), self.font_data.copy())
        if self.font_dirty and self.font_metrics:
            m.set_font_metrics(self.font_metrics.value())
            self.font_dirty = False
        var env = self.acc.ui_env(self.ui_env)
        m.set_ui_env(env)
        if not self.game_renderer:
            self.game_renderer = SceneRendererOf[Self.P, Self.F, Self.A](self.boot.device(), format, view)
        self.game_renderer.value().begin(view)
        self.game_renderer.value().probe = self.probe_cube
        self.game_renderer.value().post_user = self.acc.access.post_user(self.acc.frame_dt)
        self.game_renderer.value().reduce_motion = self.acc.access.reduce_motion
        var t = now_ns()
        var items = m.scene()
        t = self.stats.lap(SEG_SCENE, t)
        for it in items:
            self.game_renderer.value().push(it)
        t = self.stats.lap(SEG_PUSH, t)
        var f2 = self.input.is_key_pressed(KEY_F2)  # the edge is taken here, so a draw that skips frames cannot miss a tap
        var over = m.overlay(
            Float32(self.width), Float32(self.height), Float32(self.input.mouse_x), Float32(self.input.mouse_y),
            self.input.is_mouse_button_pressed(MOUSE_LEFT), f2 and not self.overlay_key_was,
        )
        self.overlay_key_was = f2
        var f3 = self.input.is_key_pressed(KEY_F3)
        if f3 and not self.perf_key_was:
            self.perf_shown = not self.perf_shown
            self.hud.value().key = -1  # the cached HUD no longer matches what is drawn
        self.perf_key_was = f3
        self.acc.captions_into(over, Float32(self.width), Float32(self.height), env, self.font_metrics)
        var con = self._console_list(Float32(self.width))
        for i in range(con.count()):
            over.cmds.append(con.cmds[i].copy())
        if over.count() > 0 or self.perf_shown:  # a panel, a caption or the frame-time overlay is up: the HUD and they are rebuilt every frame
            var list = m.hud(Float32(self.width), Float32(self.height), self.frame_ms)
            for i in range(over.count()):
                list.cmds.append(over.cmds[i].copy())
            if self.perf_shown:
                var pl = perf_overlay(self.stats, 8.0, 8.0)
                for i in range(pl.count()):
                    list.cmds.append(pl.cmds[i].copy())
            self.hud.value().set(list, Float32(self.width), Float32(self.height))
        else:
            refresh_hud(self.hud.value(), m, Float32(self.width), Float32(self.height), self.frame_ms)
        t = self.stats.lap(SEG_HUD, t)
        self.game_renderer.value().draw(self.boot.device(), target, self.width, self.height, self.hud.value())
        self.hud.value().uploaded()
        _ = self.stats.lap(SEG_DRAW, t)
        self.stats.set_counter(CTR_DRAWS, self.game_renderer.value().counts.draws)
        self.stats.set_counter(CTR_TRIANGLES, self.game_renderer.value().counts.triangles)
        self.stats.set_counter(CTR_TEXTURE_BYTES, self.game_renderer.value().tex_bytes)

    def _draw_scene(mut self, target: WGPUTextureHandle, format: UInt32) raises:
        var aspect = Float32(self.width) / Float32(self.height)
        if self.mode == MODE_GAME:
            var m = self.game.take()
            # the mode goes back into its slot even when the call raises: the next frame takes it again
            var failed = String()
            try:
                self._draw_mode(m, target, format, aspect)
            except e:
                failed = String(e)
            self.game = m^
            if failed.byte_length() > 0:
                raise Error(failed)
            return
        if not self.renderer:
            self.renderer = Renderer(self.boot.device(), format)
        var t = now_ns()
        fill(self.renderer.value(), self.sim, aspect)
        t = self.stats.lap(SEG_SCENE, t)
        self.renderer.value().draw(self.boot.device(), target)
        _ = self.stats.lap(SEG_DRAW, t)

    def _capture(mut self, format: UInt32) raises:
        if self.want_capture and not self.capture_req:
            # Frames are read back from an app-owned target: headless Chrome cannot read a canvas texture.
            if self.capture and (self.capture_width != self.width or self.capture_height != self.height):
                self.capture = None  # resized since the last capture: the readback buffer and target are the old size
                self.capture_target = None
            if not self.capture:
                self.capture_width = self.width
                self.capture_height = self.height
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
        self.stats.begin()
        var t0 = now_ns()
        var rc = self._frame(dt)
        # Every frame ends here, drawn or not: a key edge or a pointer movement lasts exactly one frame.
        self.input.begin_frame()
        _ = self.stats.lap(SEG_FRAME, t0)
        self.stats.end()
        return rc

    def _frame(mut self, dt: Float64) raises -> Int32:
        var t = now_ns()
        self._net()
        t = self.stats.lap(SEG_NET, t)
        self._advance(dt)
        _ = self.stats.lap(SEG_STEP, t)
        if not self.boot.step():
            return 0
        if self.offscreen:
            # Never touch the canvas: headless Chrome loses the device after a canvas draw.
            if self.mode != MODE_DEMO:
                self._capture(WGPUTextureFormat.RGBA8Unorm)  # the game still can be looked at, with no canvas draw
            self._reference()
            self._finish_capture()
            self._finish_photo()
            return 1
        if not self.configured:
            self.surface.configure(
                self.boot.adapter().handle(), self.boot.device().handle().raw,
                self.width, self.height,
            )
            self.configured = True
        t = now_ns()
        var tex = self.surface.get_current_texture()
        t = self.stats.lap(SEG_PRESENT, t)
        if tex.is_renderable():
            self._draw_scene(tex.texture, self.surface.format())
            self._capture(self.surface.format())
            t = now_ns()
            self.surface.present()
            _ = self.stats.lap(SEG_PRESENT, t)
            self.frames += 1
        self._reference()
        self._finish_capture()
        self._finish_photo()
        return 1


comptime App = AppOf[DemoMode, DefaultPasses]
"""The shell the C-ABI exports: the demo game, the default passes."""


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
def app_take_export(app: UInt64, out_ptr: UInt64, cap: UInt64) abi("C") -> Int32:
    """A file the game wants saved (`GameMode.take_export`: file name, newline, text, UTF-8) is copied to `out_ptr`, at most
    `cap` bytes, and cleared. Returns its length, 0 when there is none, or -(its length) when `cap` is too small (nothing
    is copied and the file stays for the next call)."""
    return _app(app)[].take_export(out_ptr, cap)


@export
def app_frame_stats(app: UInt64, out_ptr: UInt64) abi("C") -> Int32:
    """Frame timings and counters over the last 300 frames (app/frame_stats.mojo). Writes to `out_ptr`, as u64:
    15 segments x [avg, p50, p95, p99, max ns, frames it ran in] in the order net, step, physics (inside step), scene, push,
    hud, draw, present, frame, ai (inside step), audio, gpu_shadow, gpu_scene, gpu_post, gpu_frame; then 6 counters x
    [last, avg, max] in the order draw calls, triangles, texture bytes, particles, bodies, ai agents. 15 * 6 + 6 * 3 = 108
    u64 (864 bytes). A segment that never ran has count 0. Returns the frames in the ring."""
    return _app(app)[].stats.write(out_ptr)


@export
def app_frame_ring(app: UInt64, out_ptr: UInt64) abi("C") -> Int32:
    """The frames in the ring, oldest first, 21 i64 each: the 15 segment times in ns (-1 = did not run) then the 6
    counters. Room for 300 frames is 50400 bytes. Returns the number of frames written (scripts/frame_trace.py)."""
    return _app(app)[].stats.write_ring(out_ptr)


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
        var t0 = now_ns()
        a[].sim.render_audio(Int(frames))
        for i in range(Int(frames) * 2):
            dst[i] = a[].sim.pcm[i]
        a[].stats.add_audio(Int64(now_ns() - t0))
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
    """Bytes per row of the captured frame: of the size it was captured at, not the current one."""
    var a = _app(app)
    return padded_row_pitch(a[].capture_width if a[].capture_width > 0 else a[].width)


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
    """Bytes per row of the reference frame; 0 before app_reference_request has started one."""
    var a = _app(app)
    if not a[].reference:
        return 0
    return a[].reference.value().pitch()


@export
def app_particles_request(app: UInt64) abi("C"):
    """Render the particle frame (app/particle_frame.mojo, 480 x 270) for the native/web pixel parity (#121)."""
    _app(app)[].particles_requested = True


@export
def app_particles_ptr(app: UInt64) abi("C") -> UInt64:
    """Address of the particle frame's pixels (RGBA8, rows of app_particles_pitch bytes), 0 until ready."""
    return _app(app)[].particles_ptr


@export
def app_particles_pitch(app: UInt64) abi("C") -> UInt32:
    """Bytes per row of the particle frame; 0 before app_particles_request has started it."""
    var a = _app(app)
    if not a[].particle_reference:
        return 0
    return a[].particle_reference.value().pitch()


@export
def app_post_fx_request(app: UInt64) abi("C"):
    """Render the picture-effects frames (app/post_fx_frame.mojo, 480 x 270) for the native/web pixel parity (#139)."""
    _app(app)[].post_fx_requested = True


@export
def app_post_fx_ptr(app: UInt64, which: Int32) abi("C") -> UInt64:
    """Address of the pixels of frame `which` (0 FXAA + bloom + grade, 1 MSAA 4x + bloom + grade; RGBA8, rows of
    app_post_fx_pitch bytes), 0 until ready."""
    var a = _app(app)
    return a[].post_fx_ptr[Int(which)] if which == 0 or which == 1 else UInt64(0)


@export
def app_post_fx_pitch(app: UInt64) abi("C") -> UInt32:
    """Bytes per row of the picture-effects frames; 0 before app_post_fx_request has started them."""
    var a = _app(app)
    if not a[].post_fx_frames:
        return 0
    return a[].post_fx_frames.value().pitch()


@export
def app_probe_cube(app: UInt64, mode: Int32) abi("C"):
    """The centre probe, for the frame check: 0 off, 1 a rigid unit cube (A.2), 2 a skinned cube with the
    identity joint, 3 a skinned cube with its joint turned 20 degrees about Y (B3)."""
    _app(app)[].probe_cube = Int(mode)


@export
def app_skin_start(app: UInt64) abi("C"):
    """B2 on the web: the synthetic scene through the CPU reference and through the GPU compute path. The GPU result
    is collected by app_skin_result, which the page polls."""
    var a = _app(app)
    try:
        var scene = synthetic_scene()
        var cpu = CpuSkinning()
        a[].skin_cpu = cpu.skin(a[].boot.device(), scene.palette, scene.rest, scene.joints, scene.weights)
        var gpu = GpuSkinning(a[].boot.device())
        a[].skin_job = gpu.submit(a[].boot.device(), scene.palette, scene.rest, scene.joints, scene.weights)
        a[].skin_max = -1.0
    except e:
        print("app_skin_start:", e)
        a[].skin_max = -2.0


@export
def app_skin_result(app: UInt64) abi("C") -> Float64:
    """-1 while the GPU job is pending, -2 if it failed, else max |GPU - CPU| over the B2 scene."""
    var a = _app(app)
    if a[].skin_max != -1.0:
        return a[].skin_max
    if not a[].skin_job:
        return -2.0
    if not a[].skin_job.value().ready():
        return -1.0
    try:
        var job = a[].skin_job.take()
        var gpu = job.collect()
        var worst = 0.0
        for v in range(len(gpu)):
            for c in range(3):
                var d = Float64(a[].skin_cpu[v][c] - gpu[v][c])
                if d < 0.0:
                    d = -d
                if d > worst:
                    worst = d
        a[].skin_max = worst
    except e:
        print("app_skin_result:", e)
        a[].skin_max = -2.0
    return a[].skin_max


@export
def app_offscreen(app: UInt64, on: Int32) abi("C"):
    """On: frames only render the reference, nothing is drawn to the canvas."""
    _app(app)[].offscreen = on != 0


@export
def app_net_send(app: UInt64, ptr: UInt64, length: UInt64) abi("C") -> Int32:
    """Send `length` bytes at `ptr` as one packet through the app's Transport (the host's net_send). 0 = ok."""
    return Int32(_app(app)[].net.send(ptr, Int(length)))


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
    """0 = the physics demo (what the selftests and parity gates compare), 1 = the game. 0 = ok."""
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
    return a[].game.value().hash() if a[].game else 0


@export
def app_load_font(app: UInt64, ptr: UInt64, length: UInt64) abi("C") -> Int32:
    """Hand over an `.lfont` file (scripts/assets/convert_font.py, ui/sdf_font.mojo): the HUD draws its text runs from it. The
    bytes are copied, so the page may free its buffer. 0 = ok, -1 = the file does not parse (the HUD keeps drawing no text)."""
    try:
        var a = _app(app)
        var bytes = List[UInt8](length=Int(length), fill=0)
        var src = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(ptr))
        for i in range(Int(length)):
            bytes[i] = src[i]
        var probe = SdfFont(bytes.copy())  # parse once here so a bad file is reported to the page
        a[].font_metrics = probe.m.copy()
        a[].font_data = bytes^
        a[].font_dirty = True
        a[].hud = None  # rebuilt with the atlas on the next frame
        return 0
    except e:
        print("app_load_font:", e)
        return -1


@export
def app_set_ui(
    app: UInt64, text_scale: Float32, left: Float32, top: Float32, right: Float32, bottom: Float32, locale: Int32, pseudo: Int32,
) abi("C"):
    """The player's UI settings and the window's safe area (`UiEnv`): text scale (clamped by the game to 0.5 .. 2), insets in
    window pixels, the locale index in the game's own list and the pseudo-localization flag. Applied from the next frame."""
    _app(app)[].ui_env = UiEnv(text_scale, Insets(left, top, right, bottom), Int(locale), pseudo != 0)


@export
def app_release_input(app: UInt64) abi("C"):
    """The page lost focus: let go of every held key and button (their releases happen elsewhere and never arrive)."""
    _app(app)[].input.release_all()


@export
def app_step(app: UInt64, dt: Float64) abi("C") -> Int32:
    """Advance one frame without drawing (`window.game.step(n, false)`). 1 = ok, -1 = error."""
    try:
        _app(app)[].step_only(dt)
        return 1
    except e:
        print("app_step:", e)
        return -1


@export
def app_configure(app: UInt64, seed: UInt64, scene_ptr: UInt64, scene_len: UInt64) abi("C") -> Int32:
    """Switch to the game and start it over with `seed` and the scene named by the UTF-8 bytes at `scene_ptr` (empty = the
    game's default). 0 = ok, -1 = the game has no seeds or scenes, -2 = error (an unknown scene), printed."""
    try:
        var bytes = Span(
            unsafe_ptr=Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(scene_ptr)),
            length=Int(scene_len),
        )
        return _app(app)[].configure_game(seed, String(StringSlice(unsafe_from_utf8=bytes)))
    except e:
        print("app_configure:", e)
        return -2


@export
def app_state(app: UInt64) abi("C") -> Int32:
    """The game's `state()` JSON, written to the text buffer: returns its byte length (read at app_text_ptr), -1 = no game."""
    var a = _app(app)
    if not a[].game:
        return -1
    a[].out_text = a[].game.value().state()
    return Int32(a[].out_text.byte_length())


@export
def app_load_audio(app: UInt64, name_ptr: UInt64, name_len: UInt64, ptr: UInt64, length: UInt64) abi("C") -> Int32:
    """Hand over an audio file by name: `<clip>.lsound` registers a clip, `<name>.audio` adds the events of an event asset,
    `<name>.music` adds the tracks of a track list (its layers must be loaded already). The bytes are copied. 0 = ok, -1 = the
    file does not parse or names something unknown (the error is printed)."""
    try:
        var a = _app(app)
        var name_src = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(name_ptr))
        var name_bytes = List[UInt8](length=Int(name_len), fill=0)
        for i in range(Int(name_len)):
            name_bytes[i] = name_src[i]
        var name = String(unsafe_from_utf8=Span(name_bytes))
        var bytes = List[UInt8](length=Int(length), fill=0)
        var src = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(ptr))
        for i in range(Int(length)):
            bytes[i] = src[i]
        if name.endswith(".lsound"):
            _ = a[].sim.mixer.add_clip_mono(String(name[byte = 0 : name.byte_length() - 7]), lsound_to_mono(bytes))
        elif name.endswith(".audio"):
            for ev in parse_events(String(unsafe_from_utf8=Span(bytes))):
                _ = a[].sim.mixer.add_event(ev.copy())
        elif name.endswith(".music"):
            _ = load_music(a[].sim.mixer, String(unsafe_from_utf8=Span(bytes)))
        else:
            raise Error("unknown audio file type: " + name)
        return 0
    except e:
        print("app_load_audio:", e)
        return -1


@export
def app_music(app: UInt64, name_ptr: UInt64, name_len: UInt64) abi("C") -> Int32:
    """Play the music track `name` from the loaded track list: at once when nothing plays, else from the next bar line. 0 = ok,
    -1 = no such track."""
    var a = _app(app)
    var src = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(name_ptr))
    var bytes = List[UInt8](length=Int(name_len), fill=0)
    for i in range(Int(name_len)):
        bytes[i] = src[i]
    var id = a[].sim.mixer.track_id(String(unsafe_from_utf8=Span(bytes)))
    if id < 0:
        return -1
    a[].sim.mixer.music.request_track(id)
    return 0


@export
def app_set_bus(app: UInt64, bus: Int32, db: Float32, mute: Int32) abi("C") -> Int32:
    """Volume in dB and mute of a bus (0 master, 1 music, 2 sfx, 3 ambience, 4 ui, 5 voice): the per-bus volume settings of
    the accessibility menu. 0 = ok, -1 = no such bus."""
    var a = _app(app)
    if bus < 0 or bus > 5:
        return -1
    a[].sim.mixer.set_bus_db(Int(bus), db)
    a[].sim.mixer.set_bus_mute(Int(bus), mute != 0)
    return 0


@export
def app_loudness(app: UInt64, which: Int32) abi("C") -> Float64:
    """Loudness of the master bus in LUFS: 0 = momentary (last 400 ms), 1 = integrated (gated, since the start). -120 = silent."""
    var a = _app(app)
    return a[].sim.mixer.meter.momentary() if which == 0 else a[].sim.mixer.meter.integrated()


@export
def app_events(app: UInt64) abi("C") -> Int32:
    """The sound cues raised since the last call as a JSON array [{"frame":N,"cue":C}, ...] (N counts game frames since
    the game started), written to the text buffer and cleared here. Returns the byte length."""
    var a = _app(app)
    var out = String("[")
    for i in range(0, len(a[].event_log), 2):
        out += String("," if i > 0 else "") + String('{"frame":') + String(a[].event_log[i]) + String(',"cue":') + String(a[].event_log[i + 1]) + String("}")
    a[].event_log.clear()
    a[].out_text = out + String("]")
    return Int32(a[].out_text.byte_length())


def _text_of(ptr: UInt64, length: UInt64) -> String:
    var bytes = Span(unsafe_ptr=Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(ptr)), length=Int(length))
    return String(StringSlice(unsafe_from_utf8=bytes))


@export
def app_rebind(app: UInt64, ptr: UInt64, length: UInt64) abi("C") -> Int32:
    """Rebind from one line of text, `<action>[.<slot>] <source> [take]` (for example `jump key:KeyJ`, `move.up key:KeyI take`),
    and save the profile. 0 = applied. n > 0 = n slots already use that control and nothing changed (their names, space
    separated, are in the text buffer); `take` moves the control here instead. -1 = the line is wrong (printed)."""
    try:
        var a = _app(app)
        var words = List[String]()
        for w in _text_of(ptr, length).split():
            words.append(String(w))
        if len(words) < 2 or len(words) > 3 or (len(words) == 3 and words[2] != "take"):
            raise Error("expected `<action>[.<slot>] <source> [take]`")
        var dot = words[0].find(".")
        var name = words[0] if dot < 0 else String(words[0][byte=:dot])
        var ai = a[].controls.actions.index(name)
        if ai < 0:
            raise Error("no action `" + name + "`")
        var slot = slot_of(a[].controls.actions.actions[ai].kind, "main" if dot < 0 else String(words[0][byte = dot + 1 :]))
        if slot < 0:
            raise Error("no such slot in `" + words[0] + "`")
        var clash = a[].controls.actions.rebind(name, slot, parse_source(words[1]), len(words) == 3)
        if len(clash) > 0:
            var out = String()
            for i in range(len(clash)):
                out += String(" " if i > 0 else "") + clash[i]
            a[].out_text = out
            return Int32(len(clash))
        _ = a[].profile.save(a[].controls.actions.profile())
        return 0
    except e:
        print("app_rebind:", e)
        return -1


@export
def app_bindings_reset(app: UInt64) abi("C") -> Int32:
    """Every action back to its default bindings; the saved profile is rewritten (empty). 0 = ok."""
    var a = _app(app)
    a[].controls.actions.reset()
    return a[].profile.save(a[].controls.actions.profile())


@export
def app_prompt(app: UInt64, ptr: UInt64, length: UInt64, device: Int32) abi("C") -> Int32:
    """What to show for an action: `<action>[.<slot>]` on `device` (0 keyboard, 1 mouse, 2 gamepad, 3 on-screen pad), in the
    text buffer (`Space`, `A`, `W`), in the UI locale. Returns its byte length, 0 = no binding on that device, -1 = no such action."""
    var a = _app(app)
    var name = _text_of(ptr, length)
    var dot = name.find(".")
    var an = name if dot < 0 else String(name[byte=:dot])
    var ai = a[].controls.actions.index(an)
    if ai < 0:
        return -1
    var slot = slot_of(a[].controls.actions.actions[ai].kind, "main" if dot < 0 else String(name[byte = dot + 1 :]))
    if slot < 0:
        return -1
    _ = a[].input_loc.set_locale("zh-TW" if a[].ui_env.locale == 1 else "en")
    a[].out_text = prompt_text(a[].controls.actions, a[].input_loc, an, slot, Int(device))
    return Int32(a[].out_text.byte_length())


@export
def app_text_len(app: UInt64) abi("C") -> Int32:
    """Byte length of the text app_state / app_events / app_rebind / app_prompt last wrote."""
    return Int32(_app(app)[].out_text.byte_length())


@export
def app_text_ptr(app: UInt64) abi("C") -> UInt64:
    """Address of the text app_state / app_events last wrote (not NUL-terminated; valid until the next call of either)."""
    return UInt64(Int(_app(app)[].out_text.unsafe_ptr()))


@export
def app_access_set(app: UInt64, ptr: UInt64, length: UInt64) abi("C") -> Int32:
    """Change one accessibility setting from `<key> <value>` (game/access.mojo: `text_scale 150`, `volume.music 40`, `colorblind
    deuteranopia`, `mono on`) and save the profile. 0 = applied; -1 = unknown key or value out of range (printed, nothing changed)."""
    try:
        var a = _app(app)
        a[].acc.access.set_line(_text_of(ptr, length))
        a[].profile.set_access(a[].acc.access)
        _ = a[].profile.save(a[].controls.actions.profile())
        return 0
    except e:
        print("app_access_set:", e)
        return -1


@export
def app_access_reset(app: UInt64) abi("C") -> Int32:
    """Every accessibility setting back to its default; the profile is rewritten without the access rows. 0 = ok."""
    var a = _app(app)
    a[].acc.access.reset()
    a[].profile.set_access(a[].acc.access)
    return a[].profile.save(a[].controls.actions.profile())


@export
def app_access_text(app: UInt64) abi("C") -> Int32:
    """The settings that differ from their defaults as profile rows (`access <key> <value>`, one per line), in the text buffer.
    Returns its byte length (0 = all defaults)."""
    var a = _app(app)
    a[].out_text = a[].acc.access.rows()
    return Int32(a[].out_text.byte_length())


@export
def app_captions_load(app: UInt64, ptr: UInt64, length: UInt64) abi("C") -> Int32:
    """Load a caption track (game/captions.mojo: `ludens-captions 1`, `caption <event> ...`, `text <locale> <key> <string>`). The
    host raises an event's caption when the mixer starts that event. 0 = ok; -1 = the track is wrong (printed, the old one stays)."""
    try:
        _app(app)[].acc.captions.load(_text_of(ptr, length))
        return 0
    except e:
        print("app_captions_load:", e)
        return -1


@export
def app_caption_say(app: UInt64, ptr: UInt64, length: UInt64, duration_ms: Int32) abi("C") -> Int32:
    """Show a line of dialogue as a caption: the text is `<speaker>`, a tab, `<line>` (no tab: no speaker). 0 = ok."""
    var line = _text_of(ptr, length)
    var tab = line.find("\t")
    var a = _app(app)
    if tab < 0:
        a[].acc.captions.say(String(), line, Int(duration_ms))
    else:
        a[].acc.captions.say(String(line[byte=:tab]), String(line[byte = tab + 1 :]), Int(duration_ms))
    return 0


@export
def app_captions_state(app: UInt64) abi("C") -> Int32:
    """The captions up now as a JSON array of the strings drawn (speaker names as the player's setting says), oldest first, in the
    text buffer. Returns its byte length. Captions off in the settings only hides them from the screen: they are listed here."""
    var a = _app(app)
    a[].out_text = a[].acc.captions.state(a[].acc.access.caption_speaker)
    return Int32(a[].out_text.byte_length())


@export
def app_shake(app: UInt64, trauma: Float32) abi("C") -> Int32:
    """Add camera shake trauma (0 .. 1); the view moves by the player's shake scale (game/camera_shake.mojo). Reads back as
    app_shake_offset. 0 = ok."""
    _app(app)[].acc.shake.add(trauma)
    return 0


@export
def app_shake_offset(app: UInt64, axis: Int32) abi("C") -> Float64:
    """The camera offset now in metres along the camera's right (axis 0) or up (axis 1) at the player's shake scale: 0 at scale 0
    or with reduce motion on."""
    var a = _app(app)
    var scale = a[].acc.access.shake_factor()
    return Float64(a[].acc.shake.offset_x(scale) if axis == 0 else a[].acc.shake.offset_y(scale))


@export
def app_console(app: UInt64, ptr: UInt64, length: UInt64) abi("C") -> Int32:
    """Submit one console line (UTF-8) as if typed (`window.game.console`): it runs before the next game frame and is
    logged. 0 = accepted, -1 = refused (the reason is in the text buffer: app_text_len / app_text_ptr), -2 = no game.
    The answer of a cvar read or `help` is in the text buffer too. In a release build every line is accepted and does
    nothing (game/console.mojo)."""
    var a = _app(app)
    if not a[].game:
        return -2
    try:
        var m = a[].game.take()
        a[]._console_setup(m)
        a[].game = m^
        a[].out_text = a[].console.submit(_text_of(ptr, length), a[].game_frames)
        return 0
    except e:
        a[].out_text = String(e)
        return -1


@export
def app_console_log(app: UInt64) abi("C") -> Int32:
    """The console log (`frame line` per line, game/console.mojo) written to the text buffer; returns its byte length."""
    var a = _app(app)
    a[].out_text = a[].console.log_text()
    return Int32(a[].out_text.byte_length())


@export
def app_console_replay(app: UInt64, ptr: UInt64, length: UInt64) abi("C") -> Int32:
    """Load a console log to play back: each line is submitted at the start of its game frame. 0 = loaded, -1 = it does
    not parse (the reason is in the text buffer)."""
    var a = _app(app)
    try:
        a[].console.load_replay(_text_of(ptr, length))
        return 0
    except e:
        a[].out_text = String(e)
        return -1


@export
def app_cheated(app: UInt64) abi("C") -> Int32:
    """1 once the game reports a cheat (achievements and stats are then refused), else 0."""
    return Int32(1 if _app(app)[].achievements.cheated else 0)


@export
def app_photo(app: UInt64, on: Int32) abi("C") -> Int32:
    """Enter (1) or leave (0) photo mode, as F9 does. Returns 1 if photo mode is on afterwards, -1 = no game."""
    var a = _app(app)
    if not a[].game:
        return -1
    if (on != 0) != a[].photo.active:
        var m = a[].game.take()
        a[].toggle_photo(m)
        a[].game = m^
    return Int32(1 if a[].photo.active else 0)


@export
def app_photo_set(app: UInt64, which: Int32, value: Float32) abi("C") -> Float32:
    """Set a photo setting: 0 focus (m), 1 f-number (0 = pinhole), 2 exposure (EV), 3 bloom, 4 capture scale. Returns the
    value kept after clamping (game/photo_camera.mojo)."""
    var names = ["photo.focus", "photo.fstop", "photo.exposure", "photo.bloom", "photo.scale"]
    if which < 0 or which > 4:
        return -1
    return _app(app)[]._photo_set(names[Int(which)], value)


@export
def app_photo_move(app: UInt64, forward: Float32, right: Float32, up: Float32, seconds: Float32) abi("C") -> Float64:
    """Fly the photo camera as the keys would for `seconds`; returns its distance from where photo mode started."""
    var a = _app(app)
    a[].photo.move(Real(forward), Real(right), Real(up), 0.0, 0.0, Float64(seconds))
    var d = a[].photo.pos - a[].photo.origin
    return sqrt(Float64(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]))


@export
def app_photo_capture(app: UInt64) abi("C") -> Int32:
    """Capture the next photo frame at the capture size, as F8 does. -1 = not in photo mode."""
    var a = _app(app)
    if not a[].photo.active:
        return -1
    a[].photo_want = True
    return 0


@export
def app_take_photo(app: UInt64, out_ptr: UInt64, cap: UInt64) abi("C") -> Int32:
    """The latest capture as a PNG file, copied to `out_ptr` and cleared. Returns its length, 0 when there is none, or
    -(its length) when `cap` is too small (nothing is copied; the file stays)."""
    return _app(app)[].take_photo(out_ptr, cap)
