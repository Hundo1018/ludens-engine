"""A fixed audio scene for the native / wasm64 byte comparison and the mixing-cost benchmark (ludens-engine #120).

Clips are made from integer arithmetic and an integer `Rng`, no sin / cos, so the input is the same on every platform.
`parity_hashes` runs three scripted renders and hashes every output sample's bit pattern; `bench_blocks` renders blocks
with `voices` voices playing, the number the cost report varies."""
from audio_event import AudioEvent, BUS_MUSIC, BUS_SFX, BUS_UI, BUS_VOICE
from audio_math import Rng
from mixer import Mixer
from music import MusicTrack

comptime SCENE_RATE = 48000
comptime SCENE_BLOCK = 128
comptime PARITY_VALUES = 6


def _saw(frames: Int, period: Int, amp: Float32) -> List[Float32]:
    var out = List[Float32](capacity=2 * frames)
    for i in range(frames):
        var s = (Float32(i % period) / Float32(period) * 2.0 - 1.0) * amp
        out.append(s)
        out.append(s * 0.5)
    return out^


def _noise(frames: Int, seed: UInt64, amp: Float32) -> List[Float32]:
    var r = Rng(seed)
    var out = List[Float32](capacity=2 * frames)
    for _ in range(frames):
        out.append(r.range(-1.0, 1.0) * amp)
        out.append(r.range(-1.0, 1.0) * amp)
    return out^


def _event(name: String, clips: List[String], bus: Int, spatial: Bool) -> AudioEvent:
    var e = AudioEvent(name)
    for c in clips:
        e.clip_names.append(c)
    e.bus = bus
    e.spatial = spatial
    return e^


def build_mixer(seed: UInt64) raises -> Mixer:
    var m = Mixer(SCENE_RATE, seed)
    _ = m.add_clip("saw", _saw(9000, 109, 0.6))
    _ = m.add_clip("saw_low", _saw(12000, 211, 0.5))
    _ = m.add_clip("noise", _noise(6000, 5, 0.5))
    _ = m.add_clip("line", _saw(30000, 157, 0.4))
    _ = m.add_clip("m_bass_a", _saw(192000, 401, 0.3))
    _ = m.add_clip("m_lead_a", _saw(192000, 97, 0.15))
    _ = m.add_clip("m_bass_b", _saw(192000, 503, 0.3))
    var hit_clips = List[String]()
    hit_clips.append("saw")
    hit_clips.append("saw_low")
    hit_clips.append("noise")
    var hit = _event("hit", hit_clips, BUS_SFX, True)
    hit.pitch_lo = 0.85
    hit.pitch_hi = 1.2
    hit.volume_lo_db = -9.0
    hit.volume_hi_db = -1.0
    hit.limit = 6
    hit.priority = 2
    hit.min_distance = 2.0
    hit.max_distance = 80.0
    _ = m.add_event(hit^)
    var ui_clips = List[String]()
    ui_clips.append("saw_low")
    _ = m.add_event(_event("ui", ui_clips, BUS_UI, False))
    var line_clips = List[String]()
    line_clips.append("line")
    _ = m.add_event(_event("line", line_clips, BUS_VOICE, False))
    var a = List[Int]()
    a.append(m.clip_id("m_bass_a"))
    a.append(m.clip_id("m_lead_a"))
    var b = List[Int]()
    b.append(m.clip_id("m_bass_b"))
    b.append(m.clip_id("m_lead_a"))
    _ = m.music.add_track(MusicTrack(120.0, 4, a^))
    _ = m.music.add_track(MusicTrack(120.0, 4, b^))
    m.set_bus_db(BUS_MUSIC, -9.0)
    return m^


def _hash_into(h: UInt64, pcm: List[Float32]) -> UInt64:
    var x = h
    for s in pcm:
        x = (x ^ UInt64(s.to_bits())) * UInt64(0x100000001B3)
    return x


def parity_hashes() raises -> List[UInt64]:
    """[all, 3D only, music + ducking only, voices at the end, plays dropped, momentary LUFS x 100 + 100000]."""
    var out = List[UInt64]()
    # 1. everything: events, positioned voices that move, the sidechain, a bar-quantized track change, a layer change
    var m = build_mixer(11)
    m.music.start(0)
    var h = UInt64(0xCBF29CE484222325)
    var pos = Rng(3)
    var buf = List[Float32]()
    var hit = m.event_id("hit")
    var ui = m.event_id("ui")
    var line = m.event_id("line")
    var last_hit = -1
    for block in range(1500):
        var t = Float32(block) / 1500.0
        m.set_listener(-10.0 + 20.0 * t, 0.0, 5.0, 0.0, 0.0, -1.0, 0.0, 1.0, 0.0)
        if block % 40 == 0:
            last_hit = m.play_event(hit, pos.range(-30.0, 30.0), pos.range(0.0, 3.0), pos.range(-30.0, 30.0), 0.0, False, pos.range(-40.0, 40.0), 0.0, pos.range(-40.0, 40.0))
        if last_hit > 0 and block % 5 == 0:
            m.move_voice(last_hit, -20.0 + 40.0 * t, 1.0, -8.0, 30.0, 0.0, 0.0)
        if block % 211 == 0:
            _ = m.play_event(ui)
        if block == 100:
            _ = m.play_event(line)
        if block == 300:
            m.music.request_track(1)
        if block == 700:
            m.music.request_layer(1, False)
        m.render(buf, SCENE_BLOCK)
        h = _hash_into(h, buf)
    out.append(h)
    var voices_end = m.active_voices()
    var dropped = m.dropped
    var lufs = m.meter.momentary()
    # 2. 3D only: six voices at fixed positions around the listener, constant for 40 blocks
    var s = build_mixer(12)
    s.set_listener(0.0, 0.0, 0.0, 0.0, 0.0, -1.0, 0.0, 1.0, 0.0)
    for i in range(6):
        _ = s.play_event(hit, Float32(i) * 7.0 - 15.0, 0.0, Float32(i % 3) * 6.0 - 6.0)
    var h3 = UInt64(0xCBF29CE484222325)
    for _ in range(40):
        s.render(buf, SCENE_BLOCK)
        h3 = _hash_into(h3, buf)
    out.append(h3)
    # 3. music with a track change and the sidechain, no events but one line, blocks of 100 frames (boundary inside a block)
    var d = build_mixer(13)
    d.music.start(0)
    var hd = UInt64(0xCBF29CE484222325)
    var nblocks = 2200
    for block in range(nblocks):
        if block == 10:
            _ = d.play_event(line)
            d.music.request_track(1)
        d.render(buf, 100)
        hd = _hash_into(hd, buf)
    out.append(hd)
    out.append(UInt64(voices_end))
    out.append(UInt64(dropped))
    out.append(UInt64(Int(lufs * 100.0 + 100000.0)))
    return out^


def bench_blocks(voices: Int, spatial: Bool, blocks: Int) raises -> Mixer:
    """A mixer with `voices` voices of the long music clip playing (spatial or not); rendering is the caller's."""
    var m = Mixer(SCENE_RATE, 1)
    _ = m.add_clip("long", _saw(SCENE_RATE * 20, 211, 0.1))
    var names = List[String]()
    names.append("long")
    _ = m.add_event(_event("v", names, BUS_SFX, spatial))
    m.set_listener(0.0, 0.0, 0.0, 0.0, 0.0, -1.0, 0.0, 1.0, 0.0)
    for i in range(voices):
        _ = m.play_event(0, Float32(i % 7) * 4.0 - 12.0, 0.0, Float32(i % 5) * 3.0 - 6.0)
    return m^
