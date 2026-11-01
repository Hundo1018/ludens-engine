"""The shell's simulation, with no GPU in it: the ludens world, the audio scene and the contact tone.

Everything the native/web parity gate compares (world hash, PCM) comes from here, and the live app drives
the same struct, so the two cannot drift apart."""
from embed.world import EmbedWorld
from geometry.vec import Real, Vec3
from scene import Scene

comptime SAMPLE_RATE: UInt32 = 48000
comptime AUDIO_BLOCK = 128


struct Sim(Movable):
    var world: EmbedWorld
    var scene: Scene
    var pcm: List[Float32]
    var handles: List[Int64]
    var halves: List[Float64]
    var contacts: Int
    var tone_gain: Float32

    def __init__(out self) raises:
        self.world = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
        self.scene = Scene(SAMPLE_RATE)
        self.pcm = List[Float32]()
        self.handles = List[Int64]()
        self.halves = List[Float64]()
        self.contacts = 0
        self.tone_gain = 0.0
        # A floor and a column of boxes that fall onto it.
        self._box(Vec3(0.0, -1.0, 0.0, 0.0), Vec3(20.0, 1.0, 20.0, 0.0), 0.0, True)
        for i in range(16):
            var x = Real(i % 4) * 1.2 - 1.8
            var y = Real(2 + i) * 1.1
            self._box(Vec3(x, y, 0.0, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False)

    def __init__(out self, *, deinit move: Self):
        self.world = move.world^
        self.scene = move.scene^
        self.pcm = move.pcm^
        self.handles = move.handles^
        self.halves = move.halves^
        self.contacts = move.contacts
        self.tone_gain = move.tone_gain

    def _box(mut self, pos: Vec3, half: Vec3, mass: Real, is_static: Bool) raises:
        self.handles.append(self.world.add_box(pos, half, mass, is_static))
        self.halves.append(Float64(half[0]))
        self.halves.append(Float64(half[1]))
        self.halves.append(Float64(half[2]))

    def step(mut self, dt: Float64) raises:
        """Advance the world by `dt` seconds and retune the contact tone."""
        for _ in range(self.world.ticks_due(dt)):
            self.world.physics_tick()
        var hits = len(self.world.frame_events)
        if hits > 0:
            self.contacts += hits
            self.tone_gain = 0.35
        else:
            self.tone_gain *= 0.85
        self.scene.set_tone(Float32(330.0 + 20.0 * Float64(min(hits, 20))), self.tone_gain)

    def render_audio(mut self, frames: Int) raises:
        """Mix `frames` stereo f32 frames into self.pcm."""
        self.scene.render(self.pcm, UInt64(frames))
