"""The smallest game that runs through the `GameMode` seam, so the shell has something to play and the checks have
something to measure. A ball on a floor with four pillars and three crates to push. WASD moves it relative to the
camera, Space jumps (with a sound), dragging turns the camera, P pauses, R restarts. Real games live in their own
repositories (ludens-playground has one); nothing in `app/` or `ui/` knows this one except the shell's `App` alias."""
from embed.world import EmbedWorld, EVENT_BEGAN
from game.cue import SoundCue
from game.draw_item import DrawItem
from game.demo_table import DemoRow, demo_default_table, demo_row, DEMO_TABLE_TEXT
from game.table import table_load
from game.intent import Intent
from game.mode import GameMode
from game.tuning import Tuner
from game.tuning_panel import TuningPanel
from geometry.quat import Quat
from geometry.trig import sin, cos
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose
from scheduler.rng import SplitMix64
from std.time import perf_counter_ns
from game.demo_strings import demo_localizer
from ui.draw import Color, DrawList
from ui.geom import Rect
from ui.loc import Localizer
from ui.scale import UiEnv, UiScale
from ui.sdf_font import FontMetrics

comptime CUE_JUMP = 1
comptime CUE_IMPACT = 2
comptime IMPACT_MIN_IMPULSE: Float32 = 0.4  # contact impulses below this make no sound
comptime IMPACT_FULL_IMPULSE: Float32 = 8.0  # at this impulse an impact plays at its full volume
comptime IMPACTS_PER_FRAME = 4
comptime MAX_PLACED_CUES = 32  # cues kept for a host that does not take them; impacts stop being queued at this length
comptime IMPACT_SETTLE_TICKS = 30  # bodies placed overlapping the floor settle in the first ticks; that is not an impact
comptime BALL: Real = 0.4
comptime TAU: Float64 = 6.283185307179586


def _gravity_of(row: DemoRow) -> Vec3:
    return Vec3(0.0, Real(row.gravity_y), 0.0, 0.0)


struct Prop(Copyable, Movable):
    var handle: Int64
    var half: Vec3
    var color: Vec3
    var dynamic: Bool  # moves under physics (the crates): listed in `state()`

    def __init__(out self, handle: Int64, half: Vec3, color: Vec3, dynamic: Bool = False):
        self.handle = handle
        self.half = half
        self.color = color
        self.dynamic = dynamic


def _vec(v: Vec3) -> String:
    return String("[") + String(Float64(v[0])) + String(",") + String(Float64(v[1])) + String(",") + String(Float64(v[2])) + String("]")


struct DemoMode(GameMode):
    var world: EmbedWorld
    var props: List[Prop]
    var ball: Int64
    var floor: Int64
    var yaw: Real
    var tick: Int
    var jumps: Int
    var paused: Bool
    var seed: UInt64  # 0 = the fixed layout; any other value moves the crates and the ball's start (`_build`)
    var scene_name: String  # "arena" (pillars and crates) or "bare" (floor and ball)
    var cue_queue: List[Int]
    var impacts_this_step: Int  # impacts queued by the current step(), at most IMPACTS_PER_FRAME
    var placed_cues: List[SoundCue]  # jump and impact cues with a position, until the host takes them
    var step_physics_ns: Int64  # time in physics_tick during the last step (not game state: not hashed)
    var tuner: Tuner  # game/data/demo.table under its schema; edits apply at a tick boundary (#119)
    var tune: DemoRow  # the tuned values the ticks read
    var panel: TuningPanel  # F2: the live tuning panel built from the schema
    var export_file: String  # table text to save, "<file name>\n<text>", until the host takes it
    var loc: Localizer  # the HUD's strings; the host picks the locale and pseudo-localization (set_ui_env)
    var env: UiEnv
    var ui: UiScale  # the HUD is laid out for 960 x 540
    var metrics: Optional[FontMetrics]  # glyph advances for sizing panels; none until the host has loaded a font
    var t_jumps: String  # this frame's HUD texts, resolved in `step` and `set_ui_env` (a lookup counts errors, so it needs `mut`)
    var t_hint: String
    var t_paused: String
    var text_key: UInt64

    def __init__(out self) raises:
        self.tuner = Tuner(demo_default_table(), DEMO_TABLE_TEXT)
        self.tune = demo_row(self.tuner.table, "main")
        self.panel = TuningPanel()
        self.export_file = String()
        self.world = EmbedWorld(1.0 / 60.0, _gravity_of(self.tune))
        self.props = List[Prop]()
        self.ball = 0
        self.floor = 0
        self.yaw = 0.0
        self.tick = 0
        self.jumps = 0
        self.paused = False
        self.seed = 0
        self.scene_name = String("arena")
        self.cue_queue = List[Int]()
        self.placed_cues = List[SoundCue]()
        self.impacts_this_step = 0
        self.step_physics_ns = 0
        self.loc = demo_localizer()
        self.env = UiEnv.default()
        self.ui = UiScale.reference(960, 540)
        self.metrics = None
        self.t_jumps = String()
        self.t_hint = String()
        self.t_paused = String()
        self.text_key = 0
        self._build()
        self._refresh_texts()

    @staticmethod
    def create() raises -> Self:
        return Self()

    @staticmethod
    def with_table(schema_text: String, table_text: String) raises -> Self:
        """The game started from a table file (a tuned copy of `game/data/demo.table`), read under the demo schema."""
        var m = Self()
        m.tuner = Tuner(table_load(schema_text, "demo.schema", table_text, "demo.table"), table_text)
        m.tune = demo_row(m.tuner.table, "main")
        m.world.set_gravity(m._gravity())
        return m^

    def _gravity(self) -> Vec3:
        return _gravity_of(self.tune)

    def set_tuning(mut self, field: String, text: String) raises:
        """Queue an edit of `demo.main.<field>`; it applies when the next tick starts."""
        self.tuner.set("main", field, text)

    def __init__(out self, *, deinit move: Self):
        self.world = move.world^
        self.props = move.props^
        self.ball = move.ball
        self.floor = move.floor
        self.yaw = move.yaw
        self.tick = move.tick
        self.jumps = move.jumps
        self.paused = move.paused
        self.seed = move.seed
        self.scene_name = move.scene_name^
        self.cue_queue = move.cue_queue^
        self.placed_cues = move.placed_cues^
        self.impacts_this_step = move.impacts_this_step
        self.step_physics_ns = move.step_physics_ns
        self.tuner = move.tuner^
        self.tune = move.tune^
        self.panel = move.panel^
        self.export_file = move.export_file^
        self.loc = move.loc^
        self.env = move.env
        self.ui = move.ui
        self.metrics = move.metrics^
        self.t_jumps = move.t_jumps^
        self.t_hint = move.t_hint^
        self.t_paused = move.t_paused^
        self.text_key = move.text_key

    def _refresh_texts(mut self):
        var key = (UInt64(self.jumps) << 20) ^ UInt64(self.loc.version) ^ (self.env.key() << 1)
        if key == self.text_key and self.t_hint.byte_length() > 0:
            return
        self.text_key = key
        self.t_jumps = self.loc.plural("hud.jumps", self.jumps)
        self.t_hint = self.loc.get("hud.hint")
        self.t_paused = self.loc.get("hud.paused")

    def set_ui_env(mut self, env: UiEnv):
        self.env = env
        self.ui.insets = env.insets
        self.ui.set_text_scale(env.text_scale)
        var tag = "zh-TW" if env.locale == 1 else "en"
        if self.loc.locale() != tag:
            _ = self.loc.set_locale(tag)
        self.loc.set_pseudo(env.pseudo)
        self._refresh_texts()

    def set_font_metrics(mut self, metrics: FontMetrics):
        self.metrics = metrics.copy()

    def _box(mut self, pos: Vec3, half: Vec3, mass: Real, color: Vec3) raises -> Int64:
        var h = self.world.add_box(pos, half, mass, mass == 0.0)
        self.props.append(Prop(h, half, color, mass != 0.0))
        return h

    def _build(mut self) raises:
        self.floor = self._box(Vec3(0.0, -0.5, 0.0, 0.0), Vec3(30.0, 0.5, 30.0, 0.0), 0.0, Vec3(0.42, 0.56, 0.42, 0.0))
        # A seed moves each crate by up to 0.6 m in x and 0.4 m in z and the ball's start by up to 0.5 m in x, drawn in this
        # order from one SplitMix64 stream. Seed 0 draws nothing: the layout (and hash) of a run with no seed is unchanged.
        var rng = SplitMix64.seeded(self.seed)
        var arena = self.scene_name == "arena"
        if arena:
            for i in range(4):  # pillars, so moving changes the picture
                var x = Real(-9.0) + 6.0 * Real(i)
                var z = Real(-6.0 - 4.0 * Real(i % 2))
                _ = self._box(Vec3(x, 1.5, z, 0.0), Vec3(0.6, 1.5, 0.6, 0.0), 0.0, Vec3(0.62, 0.64, 0.76, 0.0))
            for i in range(3):  # crates to push
                var jx = Real(0)
                var jz = Real(0)
                if self.seed != 0:
                    jx = (Real(rng.next_f32()) - 0.5) * 1.2
                    jz = (Real(rng.next_f32()) - 0.5) * 0.8
                _ = self._box(Vec3(Real(2 * i) - 2.0 + jx, 0.5, -2.5 + jz, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 6.0, Vec3(0.62, 0.45, 0.28, 0.0))
        var bx = Real(0)
        if self.seed != 0:
            bx = Real(rng.next_f32()) - 0.5
        self.ball = self.world.add_sphere(Vec3(bx, BALL, 3.0, 0.0), BALL, 70.0, False)

    def reset(mut self, seed: UInt64, scene: String) raises -> Bool:
        """Scenes: "arena" (the default, also for ""), "bare". The seed is kept by R (restart)."""
        var name = scene if scene.byte_length() > 0 else String("arena")
        if name != "arena" and name != "bare":
            raise Error("unknown scene `" + name + "` (arena, bare)")
        self.seed = seed
        self.scene_name = name
        self._restart()
        return True

    def state(self) -> String:
        """JSON: counters, the yaw, the ball's position and velocity and the crates' positions, then the hash."""
        var out = String('{"tick":') + String(self.tick) + String(',"jumps":') + String(self.jumps)
        out += String(',"paused":') + String("true" if self.paused else "false")
        out += String(',"seed":"') + String(self.seed) + String('","scene":"') + self.scene_name + String('"')
        out += String(',"yaw":') + String(Float64(self.yaw))
        try:
            var b = self.world.state(self.ball)
            out += String(',"ball":{"pos":') + _vec(b.pos) + String(',"vel":') + _vec(b.vel) + String("}")
            out += String(',"crates":[')
            var first = True
            for p in self.props:
                if p.dynamic:
                    out += String("" if first else ",") + _vec(self.world.state(p.handle).pos)
                    first = False
            out += String("]")
        except:
            out += String(',"error":"body state unavailable"')
        return out + String(',"hash":"') + String(self.hash()) + String('"}')

    def _restart(mut self) raises:
        self.world = EmbedWorld(1.0 / 60.0, self._gravity())
        self.placed_cues.clear()
        self.props = List[Prop]()
        self.yaw = 0.0
        self.tick = 0
        self.jumps = 0
        self.paused = False
        self._build()

    def step(mut self, intent: Intent, frame_dt: Float64) raises:
        self._step(intent, frame_dt)
        self._refresh_texts()

    def _step(mut self, intent: Intent, frame_dt: Float64) raises:
        self.step_physics_ns = 0
        self.impacts_this_step = 0
        if intent.restart:
            self._restart()
        if intent.pause:
            self.paused = not self.paused
        if not self.panel.open:  # a drag on the panel's sliders is not a camera turn
            self.yaw -= intent.look_dx * Real(self.tune.look_sensitivity)
        if self.paused:
            return
        var jump = intent.jump
        for _ in range(self.world.ticks_due(frame_dt)):
            if self.tuner.apply() > 0:  # queued edits take effect here, between two ticks
                self.tune = demo_row(self.tuner.table, "main")
                self.world.set_gravity(self._gravity())
            var fwd = Vec3(-sin(self.yaw), 0.0, -cos(self.yaw), 0.0)
            var right = Vec3(cos(self.yaw), 0.0, -sin(self.yaw), 0.0)
            var v = (fwd * intent.forward + right * intent.right) * Real(self.tune.speed)
            var vy = self.world.state(self.ball).vel[1]
            if jump and self.tune.jump_enabled and self.world.touching(self.ball, self.floor):
                vy = Real(self.tune.jump_speed)
                self.jumps += 1
                var at = self.world.state(self.ball).pos
                self.placed_cues.append(SoundCue(CUE_JUMP, Float32(at[0]), Float32(at[1]), Float32(at[2]), 0.0, True, Float32(v[0]), Float32(vy), Float32(v[2])))
            jump = False
            self.world.set_velocity(self.ball, Vec3(v[0], vy, v[2], 0.0), Vec3(0.0, 0.0, 0.0, 0.0))
            var t0 = perf_counter_ns()
            self.world.physics_tick()
            self.step_physics_ns += Int64(perf_counter_ns() - t0)
            self._impacts()
            self.tick += 1

    def overlay(mut self, width: Float32, height: Float32, pointer_x: Float32, pointer_y: Float32, pointer_down: Bool, toggle: Bool) raises -> DrawList:
        if toggle:
            self.panel.open = not self.panel.open
        if not self.panel.open:
            return DrawList()
        if self.panel.frame(self.tuner, 8.0, 40.0, 420.0, pointer_x, pointer_y, pointer_down):
            self.export_file = "demo.table\n" + self.tuner.export_text()
        return self.panel.take_list()

    def take_export(mut self) -> String:
        var out = self.export_file
        self.export_file = String()
        return out^

    def scene(mut self) raises -> List[DrawItem]:
        var out = List[DrawItem]()
        for p in self.props:
            var s = self.world.state(p.handle)
            out.append(DrawItem(0, s.pos, Float64(s.rot.x), Float64(s.rot.y), Float64(s.rot.z), Float64(s.rot.w), p.half, p.color))
        var b = self.world.state(self.ball)
        out.append(DrawItem(1, b.pos, 0.0, 0.0, 0.0, 1.0, Vec3(BALL, 0.0, 0.0, 0.0), Vec3(0.2, 0.55, 0.95, 0.0)))
        return out^

    def camera(self) -> CameraPose:
        var target = Vec3(0.0, 1.0, 3.0, 0.0)
        try:
            target = self.world.state(self.ball).pos
        except:
            pass
        # 7 m behind the ball and 2.2 m above it, looking along the heading (yaw 0 looks down -z)
        var back = Vec3(sin(self.yaw), 0.0, cos(self.yaw), 0.0)
        var pos = target + back * 7.0 + Vec3(0.0, 2.2, 0.0, 0.0)
        return CameraPose(pos, Quat.from_axis_angle(Vec3(0.0, 1.0, 0.0, 0.0), self.yaw), 1.0, 1.78, 0.1, 400.0)

    def cues(mut self) -> List[Int]:
        var out = self.cue_queue.copy()
        self.cue_queue.clear()
        return out^

    def positioned_cues(mut self) -> List[SoundCue]:
        var out = self.placed_cues.copy()
        self.placed_cues.clear()
        return out^

    def _impacts(mut self):
        """An impact sound at each contact point that began this tick with an impulse above IMPACT_MIN_IMPULSE, louder with the
        impulse (-30 dB at the minimum, 0 dB at IMPACT_FULL_IMPULSE); at most IMPACTS_PER_FRAME per host frame."""
        if self.tick < IMPACT_SETTLE_TICKS:
            return
        for e in self.world.tick_events:
            if self.impacts_this_step >= IMPACTS_PER_FRAME or len(self.placed_cues) >= MAX_PLACED_CUES:
                return
            if e.kind != Int64(EVENT_BEGAN) or e.impulse < IMPACT_MIN_IMPULSE:
                continue
            var level = e.impulse / IMPACT_FULL_IMPULSE
            if level > 1.0:
                level = 1.0
            self.placed_cues.append(SoundCue(CUE_IMPACT, Float32(e.point[0]), Float32(e.point[1]), Float32(e.point[2]), -30.0 + 30.0 * level))
            self.impacts_this_step += 1

    def audio_events(self) -> String:
        return String(
            "event cue1\n  clips cue1\n  bus sfx\n  pitch 0.97 1.03\n  volume -2 0\n  priority 6\n  limit 2\n  spatial 1\n  min_distance 8\n  max_distance 80\n"
            "event cue2\n  clips cue2\n  bus sfx\n  pitch 0.8 1.25\n  volume -4 0\n  priority 2\n  limit 4\n  spatial 1\n  min_distance 6\n  max_distance 60\n"
        )

    def sounds(self, rate: Int) -> List[List[Float32]]:
        """One clip: the jump, a rising sine of 0.16 s that fades to silence."""
        var clip = List[Float32]()
        var n = Int(0.16 * Float64(rate))
        var phase = 0.0
        for i in range(n):
            var t = Float64(i) / Float64(rate)
            phase += (300.0 + 300.0 * (t / 0.16)) / Float64(rate)
            var s = sin(phase * TAU) * 0.8 * (1.0 - t / 0.16) * 0.6
            clip.append(Float32(s))
            clip.append(Float32(s))
        var out = List[List[Float32]]()
        out.append(clip^)
        # cue 2, the impact: 0.14 s of a falling 140 -> 70 Hz sine with a noise burst, decaying
        var thud = List[Float32]()
        var m = Int(0.14 * Float64(rate))
        var ph = 0.0
        var noise = UInt32(2463534242)
        for i in range(m):
            var t = Float64(i) / Float64(rate)
            ph += (140.0 - 70.0 * (t / 0.14)) / Float64(rate)
            noise = noise * UInt32(1664525) + UInt32(1013904223)
            var n = Float64(Int(noise >> 16) & 0xFFFF) / 32768.0 - 1.0
            var env = (1.0 - t / 0.14) * (1.0 - t / 0.14)
            var v = (sin(ph * TAU) * 0.7 + n * 0.3 * (1.0 - t / 0.14)) * env * 0.7
            thud.append(Float32(v))
            thud.append(Float32(v))
        out.append(thud^)
        return out^

    def _width(self, text: String, size: Float32) -> Float32:
        """The width of `text` at `size`: the font's advances, or 0.55 em a character (1 em for a CJK one) before a font is loaded."""
        if self.metrics:
            return self.metrics.value().measure(text, size)
        var w = Float32(0)
        for ch in text.codepoints():
            w += Float32(1.0) if ch.to_u32() >= 0x2E80 else Float32(0.55)
        return w * size

    def _height(self, text: String, size: Float32, max_w: Float32) -> Float32:
        if self.metrics:
            return self.metrics.value().text_height(text, size, max_w)
        var lines = Float32(1)
        if max_w > 0 and self._width(text, size) > max_w:
            lines = Float32(Int(self._width(text, size) / max_w) + 1)
        return lines * size * 1.45

    def hud(self, width: Float32, height: Float32, frame_ms: Float32) raises -> DrawList:
        """Three panels: the jump counter at the top-left of the safe area, the controls hint along its bottom edge
        (wrapped to its width), and the pause banner in the middle. Sizes come from the reference layout (960 x 540) times
        the window factor; font sizes also times the player's text scale. Each panel is as large as its text needs."""
        var dl = DrawList()
        var safe = self.ui.safe_rect(width, height)
        var margin = self.ui.px(8, width, height)
        var pad = self.ui.px(6, width, height)
        var size = self.ui.font_px(16, width, height)
        var big = self.ui.font_px(28, width, height)
        var panel = Color(0.05, 0.06, 0.1, 0.9)
        var white = Color(1.0, 1.0, 1.0, 1.0)

        var jw = self._width(self.t_jumps, size)
        var jh = self._height(self.t_jumps, size, 0)
        dl.fill(Rect(safe.x + margin, safe.y + margin, jw + 2 * pad, jh + 2 * pad), panel)
        dl.text(Rect(safe.x + margin + pad, safe.y + margin + pad, jw * 1.02 + 1, jh), self.t_jumps, white, size)

        var avail = safe.w - 2 * margin
        var hw = self._width(self.t_hint, size) + 2 * pad
        var pw = hw if hw < avail else avail
        var hh = self._height(self.t_hint, size, pw - 2 * pad)
        var hx = safe.x + (safe.w - pw) * 0.5
        var hy = safe.bottom() - margin - hh - 2 * pad
        dl.fill(Rect(hx, hy, pw, hh + 2 * pad), panel)
        dl.text(Rect(hx + pad, hy + pad, pw - 2 * pad, hh), self.t_hint, white, size)

        if self.paused:
            var bw = self._width(self.t_paused, big)
            var bh = self._height(self.t_paused, big, 0)
            var bx = safe.x + (safe.w - bw - 2 * pad) * 0.5
            var by = safe.y + (safe.h - bh - 2 * pad) * 0.5
            dl.fill(Rect(bx, by, bw + 2 * pad, bh + 2 * pad), panel)
            dl.text(Rect(bx + pad, by + pad, bw * 1.02 + 1, bh), self.t_paused, white, big)
        return dl^

    def hud_key(self, width: Float32, height: Float32) -> Int64:
        """The HUD shows the jump count, the pause banner and a fixed hint, laid out for the size, the safe area, the text
        scale and the locale: those are the key (frame_ms is not drawn)."""
        var h = UInt64(14695981039346656037)
        h = (h ^ UInt64(self.jumps)) * UInt64(0x100000001B3)
        h = (h ^ UInt64(1 if self.paused else 0)) * UInt64(0x100000001B3)
        h = (h ^ self.ui.key(width, height)) * UInt64(0x100000001B3)
        h = (h ^ UInt64(self.loc.version)) * UInt64(0x100000001B3)
        h = (h ^ UInt64(1 if self.metrics else 0)) * UInt64(0x100000001B3)
        return Int64(h >> 1)

    def physics_ns(self) -> Int64:
        return self.step_physics_ns

    def hash(self) -> UInt64:
        var h = self.world.hash()
        h = (h ^ UInt64(self.tick)) * UInt64(0x100000001B3)
        h = (h ^ UInt64(self.jumps)) * UInt64(0x100000001B3)
        h = (h ^ UInt64(1 if self.paused else 0)) * UInt64(0x100000001B3)
        return h
