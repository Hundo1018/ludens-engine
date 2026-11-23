"""The game's mixer: events, voices, buses with sidechain ducking, music, 3D voices and a loudness meter (ludens-engine #120).

    play_event -> voice (clip, rate, gain; a miniaudio `Spatializer` when positioned) -> bus -> master -> LUFS meter

Everything on the render path uses + - * / and comparisons on Float32 / integers, plus miniaudio's spatializer, which is C
code that runs unchanged in the wasm module, so native and wasm64 give the same bytes (`pixi run -e wasm audio-same`).

Events: an event names several clips; each play draws, in this order, the clip, the pitch and the volume from a seeded
`Rng` (all three even when a range is a single value), so a replay with the same seed and the same calls sounds the same.
When an event is at its concurrency limit the oldest voice of that event is replaced if the new play has an equal or
higher priority, otherwise the new play is dropped. When all `MAX_VOICES` are busy the lowest-priority, oldest voice is
replaced under the same rule.

Buses: Master, Music, Sfx, Ambience, Ui, Voice, each with a volume in dB and a mute. One sidechain: while the source
bus (Voice) is louder than a threshold, the target bus (Music) is pulled down by `duck_db`; attack and release are
one-pole filters per sample (5 ms level detector, attack and release on the gain), so the result does not depend on how the output is cut into blocks.

3D: a positioned voice runs through its own `Spatializer` (inverse attenuation between `min_distance` and
`max_distance`, panning from the source's direction in the listener's frame). The listener is set from the camera each
frame. miniaudio smooths a gain change over the first block after it, so a voice that moves every block is not at its
exact gain until it stops (see tests/audio_mixer.mojo).

Not here: occlusion, reverb and HRTF (#137)."""
from std.memory import ArcPointer

from audio_event import AudioEvent, BUS_COUNT, BUS_MASTER, BUS_MUSIC, BUS_SFX, BUS_VOICE
from audio_math import Rng, db_to_gain
from loudness import LoudnessMeter
from miniaudio import MaLib
from miniaudio.sound import AttenuationModel
from miniaudio.spatializer import Spatializer, SpatializerListener
from music import Music

comptime MAX_VOICES = 24
comptime MIXER_CHANNELS: UInt32 = 2


struct Voice(Copyable, Movable):
    var active: Bool
    var id: Int  # the play count when it started; the handle `play_event` returns
    var clip: Int
    var event: Int
    var bus: Int
    var pos: Int  # read position in 1/65536 frames
    var step: Int  # 65536 * playback rate
    var gain: Float32
    var priority: Int
    var spatial: Bool

    def __init__(out self):
        self.active = False
        self.id = 0
        self.clip = 0
        self.event = -1
        self.bus = BUS_SFX
        self.pos = 0
        self.step = 65536
        self.gain = 1.0
        self.priority = 0
        self.spatial = False


struct Mixer(Movable):
    var lib: ArcPointer[MaLib]
    var rate: Int
    var clips: List[List[Float32]]  # interleaved stereo at `rate`
    var clip_names: List[String]
    var events: List[AudioEvent]
    var event_clips: List[List[Int]]
    var voices: List[Voice]
    var spats: List[Spatializer]  # one per voice slot; valid while the slot's voice is spatial
    var listener: SpatializerListener
    var rng: Rng
    var plays: Int
    var dropped: Int
    var bus_db: List[Float32]
    var bus_mute: List[Bool]
    var bus_gain: List[Float32]  # linear, from bus_db and bus_mute
    var duck_source: Int
    var duck_target: Int
    var duck_gain_target: Float32
    var duck_threshold: Float32
    var duck_attack: Float32  # per-sample filter coefficients of the target gain
    var duck_release: Float32
    var duck_follow: Float32  # per-sample coefficient of the level detector (5 ms)
    var duck_env: Float32
    var duck_now: Float32  # current ducking gain on the target bus, 1.0 = none
    var music: Music
    var track_names: List[String]  # the name of each music track, by id
    var meter: LoudnessMeter
    var scratch: List[List[Float32]]  # one stereo buffer per bus

    def __init__(out self, rate: Int, seed: UInt64) raises:
        self.lib = ArcPointer(MaLib.default())
        self.rate = rate
        self.clips = List[List[Float32]]()
        self.clip_names = List[String]()
        self.events = List[AudioEvent]()
        self.event_clips = List[List[Int]]()
        self.voices = List[Voice]()
        self.spats = List[Spatializer]()
        for _ in range(MAX_VOICES):
            self.voices.append(Voice())
            self.spats.append(Spatializer.create(self.lib, channels_in=1, channels_out=MIXER_CHANNELS))
        self.listener = SpatializerListener.create(self.lib, channels_out=MIXER_CHANNELS)
        self.rng = Rng(seed)
        self.plays = 0
        self.dropped = 0
        self.bus_db = List[Float32]()
        self.bus_mute = List[Bool]()
        self.bus_gain = List[Float32]()
        self.scratch = List[List[Float32]]()
        for _ in range(BUS_COUNT):
            self.bus_db.append(0.0)
            self.bus_mute.append(False)
            self.bus_gain.append(1.0)
            self.scratch.append(List[Float32]())
        self.duck_source = BUS_VOICE
        self.duck_target = BUS_MUSIC
        self.duck_gain_target = db_to_gain(-12.0)
        self.duck_threshold = 0.01
        self.duck_attack = 0.0
        self.duck_release = 0.0
        self.duck_follow = 0.0
        self.duck_env = 0.0
        self.duck_now = 1.0
        self.music = Music(rate)
        self.track_names = List[String]()
        self.meter = LoudnessMeter()
        self.set_ducking(BUS_VOICE, BUS_MUSIC, -12.0, 0.01, 10.0, 250.0)

    def __init__(out self, *, deinit move: Self):
        self.lib = move.lib^
        self.rate = move.rate
        self.clips = move.clips^
        self.clip_names = move.clip_names^
        self.events = move.events^
        self.event_clips = move.event_clips^
        self.voices = move.voices^
        self.spats = move.spats^
        self.listener = move.listener^
        self.rng = move.rng^
        self.plays = move.plays
        self.dropped = move.dropped
        self.bus_db = move.bus_db^
        self.bus_mute = move.bus_mute^
        self.bus_gain = move.bus_gain^
        self.duck_source = move.duck_source
        self.duck_target = move.duck_target
        self.duck_gain_target = move.duck_gain_target
        self.duck_threshold = move.duck_threshold
        self.duck_attack = move.duck_attack
        self.duck_release = move.duck_release
        self.duck_follow = move.duck_follow
        self.duck_env = move.duck_env
        self.duck_now = move.duck_now
        self.music = move.music^
        self.track_names = move.track_names^
        self.meter = move.meter^
        self.scratch = move.scratch^

    # ---- assets -------------------------------------------------------------------------------------------------

    def add_clip(mut self, name: String, var stereo: List[Float32]) raises -> Int:
        """Register interleaved stereo f32 frames at the mixer's rate; returns the clip id."""
        if len(stereo) == 0 or len(stereo) % 2 != 0:
            raise Error("clip `" + name + "` must be a non-empty whole number of stereo frames")
        self.clips.append(stereo^)
        self.clip_names.append(name)
        return len(self.clips) - 1

    def add_clip_mono(mut self, name: String, mono: List[Float32]) raises -> Int:
        var stereo = List[Float32](capacity=2 * len(mono))
        for s in mono:
            stereo.append(s)
            stereo.append(s)
        return self.add_clip(name, stereo^)

    def clip_id(self, name: String) -> Int:
        for i in range(len(self.clip_names)):
            if self.clip_names[i] == name:
                return i
        return -1

    def add_event(mut self, var event: AudioEvent) raises -> Int:
        """Register an event; every clip name it uses must already be registered."""
        var ids = List[Int]()
        for n in event.clip_names:
            var c = self.clip_id(n)
            if c < 0:
                raise Error("event `" + event.name + "`: unknown clip `" + n + "`")
            ids.append(c)
        self.events.append(event^)
        self.event_clips.append(ids^)
        return len(self.events) - 1

    def track_id(self, name: String) -> Int:
        for i in range(len(self.track_names)):
            if self.track_names[i] == name:
                return i
        return -1

    def event_id(self, name: String) -> Int:
        for i in range(len(self.events)):
            if self.events[i].name == name:
                return i
        return -1

    # ---- buses --------------------------------------------------------------------------------------------------

    def set_bus_db(mut self, bus: Int, db: Float32):
        self.bus_db[bus] = db
        self._bus_changed(bus)

    def set_bus_mute(mut self, bus: Int, mute: Bool):
        self.bus_mute[bus] = mute
        self._bus_changed(bus)

    def _bus_changed(mut self, bus: Int):
        self.bus_gain[bus] = 0.0 if self.bus_mute[bus] else db_to_gain(self.bus_db[bus])

    def set_ducking(mut self, source: Int, target: Int, duck_db: Float32, threshold: Float32, attack_ms: Float32, release_ms: Float32):
        """While `source`'s level (per-sample peak of L and R, smoothed with a 5 ms time constant) is above `threshold`,
        `target` is attenuated by `duck_db` (negative); its gain approaches the new value with `attack_ms` going down and
        `release_ms` coming back (one-pole time constants)."""
        self.duck_source = source
        self.duck_target = target
        self.duck_gain_target = db_to_gain(duck_db)
        self.duck_threshold = threshold
        self.duck_attack = Float32(1.0) / (Float32(1.0) + attack_ms * Float32(self.rate) / 1000.0)
        self.duck_release = Float32(1.0) / (Float32(1.0) + release_ms * Float32(self.rate) / 1000.0)
        self.duck_follow = Float32(1.0) / (Float32(1.0) + 5.0 * Float32(self.rate) / 1000.0)

    # ---- listener -----------------------------------------------------------------------------------------------

    def set_listener(
        mut self, x: Float32, y: Float32, z: Float32, fx: Float32, fy: Float32, fz: Float32, ux: Float32, uy: Float32, uz: Float32
    ) raises:
        """The ear: position, facing direction and world up (the camera's pose, every frame)."""
        self.listener.set_position(x, y, z)
        self.listener.set_direction(fx, fy, fz)
        self.listener.set_world_up(ux, uy, uz)

    # ---- playing ------------------------------------------------------------------------------------------------

    def play_event(
        mut self, event: Int, x: Float32 = 0.0, y: Float32 = 0.0, z: Float32 = 0.0, gain_db: Float32 = 0.0, flat: Bool = False
    ) raises -> Int:
        """Start `event`; returns the voice id, or -1 when the play is dropped (limit or priority). The position is used
        when the event is spatial and `flat` is False (a cue that carries no position plays flat)."""
        if event < 0 or event >= len(self.events):
            raise Error("unknown event id")
        var n_clips = len(self.event_clips[event])
        var pick = self.rng.below(n_clips)
        var pitch = self.rng.range(self.events[event].pitch_lo, self.events[event].pitch_hi)
        var vol_db = self.rng.range(self.events[event].volume_lo_db, self.events[event].volume_hi_db)
        var priority = self.events[event].priority
        var slot = -1
        var limit = self.events[event].limit
        if limit > 0:
            var count = 0
            var oldest = -1
            for i in range(len(self.voices)):
                if self.voices[i].active and self.voices[i].event == event:
                    count += 1
                    if oldest < 0 or self.voices[i].id < self.voices[oldest].id:
                        oldest = i
            if count >= limit:
                if priority < self.voices[oldest].priority:
                    self.dropped += 1
                    return -1
                slot = oldest
        if slot < 0:
            for i in range(len(self.voices)):
                if not self.voices[i].active:
                    slot = i
                    break
        if slot < 0:
            var victim = 0
            for i in range(1, len(self.voices)):
                if self.voices[i].priority < self.voices[victim].priority or (
                    self.voices[i].priority == self.voices[victim].priority and self.voices[i].id < self.voices[victim].id
                ):
                    victim = i
            if priority < self.voices[victim].priority:
                self.dropped += 1
                return -1
            slot = victim
        self.plays += 1
        var v = Voice()
        v.active = True
        v.id = self.plays
        v.clip = self.event_clips[event][pick]
        v.event = event
        v.bus = self.events[event].bus
        v.step = Int(pitch * 65536.0 + 0.5)
        v.gain = db_to_gain(vol_db + gain_db)
        v.priority = priority
        v.spatial = self.events[event].spatial and not flat
        if v.spatial:
            self.spats[slot] = Spatializer.create(self.lib, channels_in=1, channels_out=MIXER_CHANNELS)
            self.spats[slot].set_attenuation_model(AttenuationModel.INVERSE)
            self.spats[slot].set_min_distance(self.events[event].min_distance)
            self.spats[slot].set_max_distance(self.events[event].max_distance)
            self.spats[slot].set_position(x, y, z)
        self.voices[slot] = v^
        return self.plays

    def move_voice(mut self, id: Int, x: Float32, y: Float32, z: Float32, vx: Float32 = 0.0, vy: Float32 = 0.0, vz: Float32 = 0.0) raises:
        """Move a positioned voice (no effect once it has ended or for a non-spatial voice)."""
        for i in range(len(self.voices)):
            if self.voices[i].active and self.voices[i].id == id and self.voices[i].spatial:
                self.spats[i].set_position(x, y, z)
                self.spats[i].set_velocity(vx, vy, vz)

    def active_voices(self) -> Int:
        var n = 0
        for v in self.voices:
            if v.active:
                n += 1
        return n

    # ---- rendering ----------------------------------------------------------------------------------------------

    def _mix_voice(mut self, slot: Int, frames: Int) raises:
        var bus = self.voices[slot].bus
        var n = len(self.clips[self.voices[slot].clip]) // 2
        var pos = self.voices[slot].pos
        var step = self.voices[slot].step
        var gain = self.voices[slot].gain
        var spatial = self.voices[slot].spatial
        var done = False
        var left = List[Float32](length=frames, fill=0.0)
        var right = List[Float32](length=frames, fill=0.0)
        ref clip = self.clips[self.voices[slot].clip]
        for i in range(frames):
            var idx = pos >> 16
            if idx >= n:
                done = True
                break
            var frac = Float32(pos & 0xFFFF) / 65536.0
            var nxt = idx + 1 if idx + 1 < n else idx
            left[i] = clip[2 * idx] + (clip[2 * nxt] - clip[2 * idx]) * frac
            right[i] = clip[2 * idx + 1] + (clip[2 * nxt + 1] - clip[2 * idx + 1]) * frac
            pos += step
        ref buf = self.scratch[bus]
        if spatial:
            var mono = List[Float32](capacity=frames)
            for i in range(frames):
                mono.append((left[i] + right[i]) * 0.5)
            var heard = self.spats[slot].process(self.listener, mono)
            for i in range(frames):
                buf[2 * i] += heard[2 * i] * gain
                buf[2 * i + 1] += heard[2 * i + 1] * gain
        else:
            for i in range(frames):
                buf[2 * i] += left[i] * gain
                buf[2 * i + 1] += right[i] * gain
        self.voices[slot].pos = pos
        if done or (pos >> 16) >= n:
            self.voices[slot].active = False

    def render(mut self, mut out: List[Float32], frames: Int) raises:
        """Mix `frames` stereo frames into `out` (resized to 2 * frames)."""
        for b in range(BUS_COUNT):
            self.scratch[b].resize(2 * frames, 0.0)
            for i in range(2 * frames):
                self.scratch[b][i] = 0.0
        for slot in range(len(self.voices)):
            if self.voices[slot].active:
                self._mix_voice(slot, frames)
        self.music.render(self.clips, self.scratch[BUS_MUSIC], frames)
        out.resize(2 * frames, 0.0)
        var master = self.bus_gain[BUS_MASTER]
        for i in range(frames):
            ref s = self.scratch[self.duck_source]
            var peak = s[2 * i]
            if peak < 0.0:
                peak = -peak
            var pr = s[2 * i + 1]
            if pr < 0.0:
                pr = -pr
            if pr > peak:
                peak = pr
            self.duck_env += (peak - self.duck_env) * self.duck_follow
            var target = self.duck_gain_target if self.duck_env > self.duck_threshold else Float32(1.0)
            var kd = self.duck_attack if target < self.duck_now else self.duck_release
            self.duck_now += (target - self.duck_now) * kd
            var l = Float32(0.0)
            var r = Float32(0.0)
            for b in range(1, BUS_COUNT):
                var g = self.bus_gain[b]
                if b == self.duck_target:
                    g = g * self.duck_now
                l += self.scratch[b][2 * i] * g
                r += self.scratch[b][2 * i + 1] * g
            out[2 * i] = l * master
            out[2 * i + 1] = r * master
        self.meter.feed(out, frames)
