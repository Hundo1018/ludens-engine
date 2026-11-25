"""Camera shake with a player scale (ludens-engine #118).

The camera rig adds `trauma` (0 .. 1) when something hits; trauma falls at `decay` per second; the camera is moved by
`max_offset * trauma^2 * scale` metres along its own right and up axes, by a value from an integer hash of (seed, frame, axis), so
the same calls give the same offsets (no clock, no global random state). `scale` is `Access.shake_factor()`: the player's 0 .. 100 %
slider, and 0 while "reduce motion" is on. At scale 0 `apply` returns the pose it was given, bit for bit. Only the view moves: the
game's state, its hash and the audio listener do not read the shake.

Standard library and ludens-core's camera pose."""
from geometry.vec import Real
from procedural.camera_math import CameraPose

comptime SHAKE_DECAY = Float32(1.5)  # trauma lost per second
comptime SHAKE_MAX_OFFSET = Float32(0.3)  # metres at trauma 1 and scale 1


def _mix64(x: UInt64) -> UInt64:
    var z = x + 0x9E3779B97F4A7C15
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) * 0x94D049BB133111EB
    return z ^ (z >> 31)


def shake_noise(seed: UInt64, frame: UInt64, axis: Int) -> Float32:
    """A value in [-1, 1] that depends only on the three arguments."""
    var h = _mix64(_mix64(seed ^ (frame * 0xD6E8FEB86659FD93)) + UInt64(axis))
    return Float32(Int(h >> 40)) / Float32(8388608.0) - 1.0  # 24 bits: 0 .. 2 - 2^-23, minus 1


struct CameraShake(Copyable, Movable):
    var trauma: Float32
    var frame: UInt64
    var seed: UInt64
    var decay: Float32
    var max_offset: Float32

    def __init__(out self, seed: UInt64 = 1):
        self.trauma = 0.0
        self.frame = 0
        self.seed = seed
        self.decay = SHAKE_DECAY
        self.max_offset = SHAKE_MAX_OFFSET

    def add(mut self, amount: Float32):
        """Trauma from a hit, capped at 1."""
        var t = self.trauma + amount
        self.trauma = 1.0 if t > 1.0 else (0.0 if t < 0.0 else t)

    def step(mut self, dt: Float32):
        """One frame: trauma decays, the noise moves on."""
        var t = self.trauma - self.decay * dt
        self.trauma = 0.0 if t < 0.0 else t
        self.frame += 1

    def amplitude(self, scale: Float32) -> Float32:
        """Metres of movement along one axis at the largest noise value."""
        return self.max_offset * self.trauma * self.trauma * scale

    def offset_x(self, scale: Float32) -> Float32:
        return self.amplitude(scale) * shake_noise(self.seed, self.frame, 0)

    def offset_y(self, scale: Float32) -> Float32:
        return self.amplitude(scale) * shake_noise(self.seed, self.frame, 1)

    def apply(self, pose: CameraPose, scale: Float32) -> CameraPose:
        """The pose moved by the shake. With scale 0 or no trauma it is `pose` itself."""
        if scale <= 0.0 or self.trauma <= 0.0:
            return pose
        var out = pose
        out.position = pose.position + pose.right() * Real(self.offset_x(scale)) + pose.up() * Real(self.offset_y(scale))
        return out
