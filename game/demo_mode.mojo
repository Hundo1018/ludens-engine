"""The smallest game that runs through the `GameMode` seam, so the shell has something to play and the checks have
something to measure. A ball on a floor with four pillars and three crates to push. WASD moves it relative to the
camera, Space jumps (with a sound), dragging turns the camera, P pauses, R restarts. Real games live in their own
repositories (ludens-playground has one); nothing in `app/` or `ui/` knows this one except the shell's `App` alias."""
from embed.world import EmbedWorld
from game.draw_item import DrawItem
from game.intent import Intent
from game.mode import GameMode
from geometry.quat import Quat
from geometry.trig import sin, cos
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose
from std.time import perf_counter_ns
from ui.draw import Color, DrawList
from ui.font import draw_text, text_width
from ui.geom import Rect

comptime CUE_JUMP = 1
comptime SPEED: Real = 5.0
comptime JUMP_SPEED: Real = 5.0
comptime BALL: Real = 0.4
comptime G = Vec3(0.0, -9.81, 0.0, 0.0)
comptime TAU: Float64 = 6.283185307179586


struct Prop(Copyable, Movable):
    var handle: Int64
    var half: Vec3
    var color: Vec3

    def __init__(out self, handle: Int64, half: Vec3, color: Vec3):
        self.handle = handle
        self.half = half
        self.color = color


struct DemoMode(GameMode):
    var world: EmbedWorld
    var props: List[Prop]
    var ball: Int64
    var floor: Int64
    var yaw: Real
    var tick: Int
    var jumps: Int
    var paused: Bool
    var cue_queue: List[Int]
    var step_physics_ns: Int64  # time in physics_tick during the last step (not game state: not hashed)

    def __init__(out self) raises:
        self.world = EmbedWorld(1.0 / 60.0, G)
        self.props = List[Prop]()
        self.ball = 0
        self.floor = 0
        self.yaw = 0.0
        self.tick = 0
        self.jumps = 0
        self.paused = False
        self.cue_queue = List[Int]()
        self.step_physics_ns = 0
        self._build()

    @staticmethod
    def create() raises -> Self:
        return Self()

    def __init__(out self, *, deinit move: Self):
        self.world = move.world^
        self.props = move.props^
        self.ball = move.ball
        self.floor = move.floor
        self.yaw = move.yaw
        self.tick = move.tick
        self.jumps = move.jumps
        self.paused = move.paused
        self.cue_queue = move.cue_queue^
        self.step_physics_ns = move.step_physics_ns

    def _box(mut self, pos: Vec3, half: Vec3, mass: Real, color: Vec3) raises -> Int64:
        var h = self.world.add_box(pos, half, mass, mass == 0.0)
        self.props.append(Prop(h, half, color))
        return h

    def _build(mut self) raises:
        self.floor = self._box(Vec3(0.0, -0.5, 0.0, 0.0), Vec3(30.0, 0.5, 30.0, 0.0), 0.0, Vec3(0.42, 0.56, 0.42, 0.0))
        for i in range(4):  # pillars, so moving changes the picture
            var x = Real(-9.0) + 6.0 * Real(i)
            var z = Real(-6.0 - 4.0 * Real(i % 2))
            _ = self._box(Vec3(x, 1.5, z, 0.0), Vec3(0.6, 1.5, 0.6, 0.0), 0.0, Vec3(0.62, 0.64, 0.76, 0.0))
        for i in range(3):  # crates to push
            _ = self._box(Vec3(Real(2 * i) - 2.0, 0.5, -2.5, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 6.0, Vec3(0.62, 0.45, 0.28, 0.0))
        self.ball = self.world.add_sphere(Vec3(0.0, BALL, 3.0, 0.0), BALL, 70.0, False)

    def _restart(mut self) raises:
        self.world = EmbedWorld(1.0 / 60.0, G)
        self.props = List[Prop]()
        self.yaw = 0.0
        self.tick = 0
        self.jumps = 0
        self.paused = False
        self._build()

    def step(mut self, intent: Intent, frame_dt: Float64) raises:
        self.step_physics_ns = 0
        if intent.restart:
            self._restart()
        if intent.pause:
            self.paused = not self.paused
        self.yaw -= intent.look_dx * 0.006
        if self.paused:
            return
        var jump = intent.jump
        for _ in range(self.world.ticks_due(frame_dt)):
            var fwd = Vec3(-sin(self.yaw), 0.0, -cos(self.yaw), 0.0)
            var right = Vec3(cos(self.yaw), 0.0, -sin(self.yaw), 0.0)
            var v = (fwd * intent.forward + right * intent.right) * SPEED
            var vy = self.world.state(self.ball).vel[1]
            if jump and self.world.touching(self.ball, self.floor):
                vy = JUMP_SPEED
                self.jumps += 1
                self.cue_queue.append(CUE_JUMP)
            jump = False
            self.world.set_velocity(self.ball, Vec3(v[0], vy, v[2], 0.0), Vec3(0.0, 0.0, 0.0, 0.0))
            var t0 = perf_counter_ns()
            self.world.physics_tick()
            self.step_physics_ns += Int64(perf_counter_ns() - t0)
            self.tick += 1

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
        return out^

    def hud(self, width: Float32, height: Float32, frame_ms: Float32) raises -> DrawList:
        var dl = DrawList()
        var s = max(Float32(Int(height / 200.0)), 2.0)
        var panel = Color(0.05, 0.06, 0.1, 0.9)
        var white = Color(1.0, 1.0, 1.0, 1.0)
        var line = "JUMPS " + String(self.jumps)
        dl.fill(Rect(4 * s, 4 * s, text_width(line, s) + 4 * s, 9 * s), panel)
        draw_text(dl, 6 * s, 6 * s, line, s, white)
        var hint = "WASD MOVE   SPACE JUMP   DRAG MOUSE LOOK   P PAUSE   R RESTART"
        var hw = text_width(hint, s) + 4 * s
        dl.fill(Rect(width * 0.5 - hw * 0.5, height - 12 * s, hw, 9 * s), panel)
        draw_text(dl, width * 0.5 - hw * 0.5 + 2 * s, height - 10 * s, hint, s, white)
        if self.paused:
            var bw = 60.0 * s
            dl.fill(Rect(width * 0.5 - bw * 0.5, height * 0.5 - 8 * s, bw, 16 * s), panel)
            draw_text(dl, width * 0.5 - text_width("PAUSED", 2 * s) * 0.5, height * 0.5 - 6 * s, "PAUSED", 2 * s, white)
        return dl^

    def hud_key(self, width: Float32, height: Float32) -> Int64:
        """The HUD shows the jump count, the pause banner and a fixed hint, laid out for the size: those are the key
        (frame_ms is not drawn)."""
        var h = UInt64(14695981039346656037)
        h = (h ^ UInt64(self.jumps)) * UInt64(0x100000001B3)
        h = (h ^ UInt64(1 if self.paused else 0)) * UInt64(0x100000001B3)
        h = (h ^ UInt64(width.to_bits())) * UInt64(0x100000001B3)
        h = (h ^ UInt64(height.to_bits())) * UInt64(0x100000001B3)
        return Int64(h >> 1)

    def physics_ns(self) -> Int64:
        return self.step_physics_ns

    def hash(self) -> UInt64:
        var h = self.world.hash()
        h = (h ^ UInt64(self.tick)) * UInt64(0x100000001B3)
        h = (h ^ UInt64(self.jumps)) * UInt64(0x100000001B3)
        h = (h ^ UInt64(1 if self.paused else 0)) * UInt64(0x100000001B3)
        return h
