"""Photo mode (docs/console.md, issue #146): a free camera inside a bound, lens and picture settings, and the size of the
capture. No GPU and no window: the host (app/main.mojo) applies it.

While `active`:
  - the host does not call `GameMode.step`: the simulation stands still (its hash does not change);
  - the camera is `pose()`: it starts where the game's camera was (`enter`) and flies with the intent (forward / right
    along the view, up / down with `move(..., up)`, look with the pointer). Its position is kept inside a sphere of
    `radius` metres around the start and above `floor_y`, so a player cannot fly out of the level or under it;
  - the HUD is not drawn (`hud_hidden`);
  - `focus` (m), `fstop` (0 = pinhole), `exposure` (EV, applied as 2^EV) and the post-effect numbers `bloom`,
    `grade` go to the photo pipeline (app/photo.mojo). Each setter clamps to its range and returns the value it kept;
  - `capture_size(w, h)` is the frame times `scale` (2 by default), each side at most MAX_CAPTURE_SIDE.

Leaving (`leave`) gives the game back its own camera."""
from std.math import atan2, sqrt
from geometry.quat import Quat
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose

comptime PHOTO_RADIUS: Real = 12.0  # metres the camera may move away from where photo mode started
comptime PHOTO_SPEED: Real = 4.0  # metres per second at full intent
comptime PHOTO_LOOK: Real = 0.004  # radians per pixel of pointer movement
comptime MAX_CAPTURE_SIDE: Int = 8192  # WebGPU's default maxTextureDimension2D
comptime PITCH_LIMIT: Real = 1.5  # radians up or down (just under 90 degrees)


struct PhotoMode(Copyable, Movable):
    var active: Bool
    var origin: Vec3  # the camera's position when photo mode started: the centre of the bound
    var pos: Vec3
    var yaw: Real  # about +y; 0 looks down -z
    var pitch: Real
    var fov_y: Real
    var aspect: Real
    var near: Real
    var far: Real
    var radius: Real
    var floor_y: Real  # the camera stays above this height
    var focus: Float32
    var fstop: Float32
    var exposure: Float32  # EV
    var bloom: Float32  # bloom intensity, 0 = off
    var grade: Float32  # colour-grade amount, 0..1
    var scale: Int  # capture size = frame size times this
    var hud_hidden: Bool
    var clamped: Int  # moves the bound cut short (for tests and the overlay)

    def __init__(out self):
        self.active = False
        self.origin = Vec3(0.0, 0.0, 0.0, 0.0)
        self.pos = self.origin
        self.yaw = 0.0
        self.pitch = 0.0
        self.fov_y = 1.0
        self.aspect = 1.78
        self.near = 0.1
        self.far = 400.0
        self.radius = PHOTO_RADIUS
        self.floor_y = 0.05
        self.focus = 8.0
        self.fstop = 0.0
        self.exposure = 0.0
        self.bloom = 0.0
        self.grade = 0.0
        self.scale = 2
        self.hud_hidden = True
        self.clamped = 0

    def enter(mut self, cam: CameraPose):
        """Start at the game's camera: same place, same heading (yaw and pitch from its forward axis)."""
        self.active = True
        self.origin = cam.position
        self.pos = cam.position
        var f = cam.forward()
        self.yaw = _atan2(-f[0], -f[2])
        var h = sqrt(f[0] * f[0] + f[2] * f[2])
        self.pitch = _atan2(f[1], h)
        self.fov_y = cam.fov_y
        self.aspect = cam.aspect
        self.near = cam.near
        self.far = cam.far
        self.floor_y = min(self.floor_y, cam.position[1])
        self.clamped = 0

    def leave(mut self):
        self.active = False

    def rotation(self) -> Quat:
        var q_yaw = Quat.from_axis_angle(Vec3(0.0, 1.0, 0.0, 0.0), self.yaw)
        var q_pitch = Quat.from_axis_angle(Vec3(1.0, 0.0, 0.0, 0.0), self.pitch)
        return q_yaw * q_pitch

    def pose(self) -> CameraPose:
        return CameraPose(self.pos, self.rotation(), self.fov_y, self.aspect, self.near, self.far)

    def move(mut self, forward: Real, right: Real, up: Real, look_dx: Real, look_dy: Real, dt: Float64):
        """One frame of flying: turn by the pointer, then move along the view; the result is kept inside the bound."""
        self.yaw -= look_dx * PHOTO_LOOK
        self.pitch -= look_dy * PHOTO_LOOK
        self.pitch = max(-PITCH_LIMIT, min(PITCH_LIMIT, self.pitch))
        var rot = self.rotation()
        var f = rot.rotate(Vec3(0.0, 0.0, -1.0, 0.0))
        var r = rot.rotate(Vec3(1.0, 0.0, 0.0, 0.0))
        var step = Real(dt) * PHOTO_SPEED
        var want = self.pos + (f * forward + r * right + Vec3(0.0, 1.0, 0.0, 0.0) * up) * step
        self.pos = self.bounded(want)

    def bounded(mut self, p: Vec3) -> Vec3:
        var q = p
        var cut = False
        if q[1] < self.floor_y:
            q = Vec3(q[0], self.floor_y, q[2], 0.0)
            cut = True
        var d = q - self.origin
        var len = sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2])
        if len > self.radius:
            q = self.origin + d * (self.radius / len)
            cut = True
        if cut:
            self.clamped += 1
        return q

    def set_focus(mut self, m: Float32) -> Float32:
        self.focus = max(Float32(0.2), min(Float32(1000.0), m))
        return self.focus

    def set_fstop(mut self, n: Float32) -> Float32:
        """0 is a pinhole (no blur); otherwise 1.0 .. 32."""
        self.fstop = Float32(0.0) if n <= 0 else max(Float32(1.0), min(Float32(32.0), n))
        return self.fstop

    def set_exposure(mut self, ev: Float32) -> Float32:
        self.exposure = max(Float32(-4.0), min(Float32(4.0), ev))
        return self.exposure

    def set_bloom(mut self, v: Float32) -> Float32:
        self.bloom = max(Float32(0.0), min(Float32(4.0), v))
        return self.bloom

    def set_grade(mut self, v: Float32) -> Float32:
        self.grade = max(Float32(0.0), min(Float32(1.0), v))
        return self.grade

    def set_scale(mut self, k: Int) -> Int:
        self.scale = max(1, min(8, k))
        return self.scale

    def capture_size(self, width: Int, height: Int) -> Tuple[Int, Int]:
        """The frame times `scale`, scaled down together (same proportions) if a side would pass MAX_CAPTURE_SIDE."""
        var w = width * self.scale
        var h = height * self.scale
        var big = max(w, h)
        if big > MAX_CAPTURE_SIDE:
            w = w * MAX_CAPTURE_SIDE // big
            h = h * MAX_CAPTURE_SIDE // big
        return (max(w, 1), max(h, 1))


def _atan2(y: Real, x: Real) -> Real:
    """The standard library's atan2 (geometry.trig has sin and cos only). Photo mode moves no body, so its last bits
    do not have to match between targets."""
    return Real(atan2(Float64(y), Float64(x)))
