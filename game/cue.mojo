"""A sound cue with a place: what a game hands the host for a sound that comes from somewhere (ludens-engine #120).
Standard library only."""


struct SoundCue(Copyable, Movable):
    """Cue `cue` (numbered from 1 like `GameMode.cues()`; clip i of `sounds()` is cue i + 1) at (x, y, z) in world metres.
    `gain_db` is added to the event's volume (an impact's loudness from its impulse); (vx, vy, vz) is the source's velocity. `logged` puts the cue in the
    host's cue log (`window.game.events()`) like a plain cue; a sound that only decorates, such as an impact, is not."""

    var cue: Int
    var x: Float32
    var y: Float32
    var z: Float32
    var gain_db: Float32
    var logged: Bool
    var vx: Float32  # velocity of the source in m/s: the mixer shifts the pitch by its Doppler factor
    var vy: Float32
    var vz: Float32

    def __init__(out self, cue: Int, x: Float32, y: Float32, z: Float32, gain_db: Float32 = 0.0, logged: Bool = False,
        vx: Float32 = 0.0, vy: Float32 = 0.0, vz: Float32 = 0.0,
    ):
        self.cue = cue
        self.x = x
        self.y = y
        self.z = z
        self.gain_db = gain_db
        self.logged = logged
        self.vx = vx
        self.vy = vy
        self.vz = vz
