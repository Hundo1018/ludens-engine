# tier: integration
"""The audio mixer (app/mixer.mojo, #120): events, buses, sidechain ducking, music quantized to the bar, positioned voices
and the loudness meter, each against a value worked out from the model, not from the code under test.
Native only here; native == wasm64 is `pixi run -e wasm audio-same`. Run: `pixi run -e wasm test-audio`."""
from std.math import sin

from audio_assets import load_music, lsound_to_mono, parse_music
from audio_event import AudioEvent, BUS_MASTER, BUS_MUSIC, BUS_SFX, BUS_VOICE, parse_events
from audio_math import Rng, db_to_gain
from loudness import LUFS_FLOOR, LoudnessMeter
from mixer import MAX_VOICES, Mixer
from music import MusicTrack

comptime RATE = 48000


struct Check:
    var passed: Int
    var failed: Int

    def __init__(out self):
        self.passed = 0
        self.failed = 0

    def ok(mut self, cond: Bool, label: String):
        if cond:
            self.passed += 1
        else:
            self.failed += 1
            print("  [FAIL]", label)

    def near(mut self, got: Float64, want: Float64, tol: Float64, label: String):
        var d = got - want
        if d < 0.0:
            d = -d
        if d <= tol:
            self.passed += 1
        else:
            self.failed += 1
            print("  [FAIL]", label, "got", got, "want", want, "tol", tol)


def constant_clip(frames: Int, value: Float32) -> List[Float32]:
    return List[Float32](length=2 * frames, fill=value)


def event(name: String, clip: String, bus: Int = BUS_SFX) -> AudioEvent:
    var e = AudioEvent(name)
    e.clip_names.append(clip)
    e.bus = bus
    return e^


def hash_pcm(pcm: List[Float32]) -> UInt64:
    var h = UInt64(0xCBF29CE484222325)
    for s in pcm:
        h = (h ^ UInt64(s.to_bits())) * UInt64(0x100000001B3)
    return h


def render_blocks(mut m: Mixer, frames: Int, block: Int) raises -> List[Float32]:
    var all = List[Float32]()
    var buf = List[Float32]()
    var done = 0
    while done < frames:
        var n = min(block, frames - done)
        m.render(buf, n)
        for s in buf:
            all.append(s)
        done += n
    return all^


def test_math(mut c: Check):
    c.near(Float64(db_to_gain(0.0)), 1.0, 0.0, "0 dB is exactly 1")
    c.near(Float64(db_to_gain(-20.0)), 0.1, 1e-7, "-20 dB is 0.1")
    c.near(Float64(db_to_gain(-6.0206)), 0.5, 1e-5, "-6.0206 dB is 0.5")
    c.near(Float64(db_to_gain(6.0)), 1.9952623, 1e-6, "+6 dB is 1.99526")
    c.ok(db_to_gain(-100.0) == 0.0, "-100 dB is silence")
    var a = Rng(7)
    var b = Rng(7)
    var same = True
    for _ in range(64):
        if a.next_u64() != b.next_u64():
            same = False
    c.ok(same, "the same seed gives the same sequence")
    var d = Rng(8)
    var e = Rng(7)
    c.ok(d.next_u64() != e.next_u64(), "another seed gives another sequence")
    var r = Rng(1)
    var lo = Float32(10.0)
    var hi = Float32(-10.0)
    for _ in range(1000):
        var v = r.range(0.9, 1.1)
        lo = min(lo, v)
        hi = max(hi, v)
    c.ok(lo >= 0.9 and hi < 1.1 and hi - lo > 0.19, "range(0.9, 1.1) stays inside and covers it: " + String(lo) + " .. " + String(hi))


def test_parse(mut c: Check) raises:
    var text = String("# a comment\nevent jump\n  clips a b c   # three\n  bus ui\n  pitch 0.9 1.1\n  volume -6 -2\n  priority 7\n  limit 2\n  spatial 1\n  min_distance 2\n  max_distance 50\nevent step\n  clips s\n")
    var evs = parse_events(text)
    c.ok(len(evs) == 2 and evs[0].name == "jump" and evs[1].name == "step", "two events are parsed")
    c.ok(len(evs[0].clip_names) == 3 and evs[0].clip_names[2] == "c", "the clip names are kept in order")
    c.ok(evs[0].bus == 4 and evs[0].priority == 7 and evs[0].limit == 2 and evs[0].spatial, "bus, priority, limit and spatial")
    c.near(Float64(evs[0].pitch_lo), 0.9, 1e-6, "pitch low")
    c.near(Float64(evs[0].volume_hi_db), -2.0, 1e-6, "volume high")
    c.near(Float64(evs[0].max_distance), 50.0, 1e-6, "max distance")
    c.ok(evs[1].bus == BUS_SFX and evs[1].limit == 0 and not evs[1].spatial, "defaults: sfx bus, no limit, not spatial")
    var bad = List[String]()
    bad.append("event x\n  clips a\n  loudness 3\n")
    bad.append("event x\n  clips a\n  bus basement\n")
    bad.append("event x\n  bus sfx\n")
    bad.append("event x\n  clips a\n  pitch 1.2 0.8\n")
    bad.append("clips a\n")
    bad.append("event x\n  clips a\n  limit lots\n")
    var msgs = List[String]()
    for t in bad:
        try:
            _ = parse_events(t)
            msgs.append("accepted")
        except err:
            msgs.append(String(err))
    c.ok(msgs[0] == "line 3: unknown key `loudness`", "unknown key names its line: " + msgs[0])
    c.ok(msgs[1].startswith("line 3: `bus` is one of"), "unknown bus: " + msgs[1])
    c.ok(msgs[2] == "event `x` names no clips", "an event without clips: " + msgs[2])
    c.ok(msgs[3] == "line 3: pitch needs 0 < low <= high <= 4", "pitch range order: " + msgs[3])
    c.ok(msgs[4] == "line 1: `clips` before any `event`", "a key before an event: " + msgs[4])
    c.ok(msgs[5] == "line 3: `lots` is not a number", "a non-number: " + msgs[5])


def make_jump_mixer(seed: UInt64) raises -> Mixer:
    var m = Mixer(RATE, seed)
    var evs = parse_events("event jump\n  clips a b c\n  pitch 0.8 1.2\n  volume -6 0\n")
    for i in range(3):
        var clip = List[Float32]()
        for k in range(2 * 2000):
            clip.append(Float32(i + 1) * 0.1 * Float32(1 + (k // 2) % 7) / 7.0)
        _ = m.add_clip(String(chr(97 + i)), clip^)
    _ = m.add_event(evs[0].copy())
    return m^


def test_events(mut c: Check) raises:
    # the same seed and the same calls give the same bytes; another seed does not
    var runs = List[UInt64]()
    for seed in range(3):
        var m = make_jump_mixer(UInt64(1 if seed < 2 else 2))
        var all = List[Float32]()
        for _ in range(20):
            _ = m.play_event(0)
            var part = render_blocks(m, 600, 128)
            for s in part:
                all.append(s)
        runs.append(hash_pcm(all))
    c.ok(runs[0] == runs[1], "seed 1 twice: same PCM hash " + String(runs[0]))
    c.ok(runs[0] != runs[2], "seed 2: another PCM hash " + String(runs[2]))
    # each play draws a clip and a pitch inside the ranges, and every clip is used
    var m = make_jump_mixer(5)
    var seen = List[Int](length=3, fill=0)
    var pitch_lo = 99.0
    var pitch_hi = 0.0
    var in_range = True
    for _ in range(300):
        var id = m.play_event(0)
        for v in m.voices:
            if v.active and v.id == id:
                seen[v.clip] += 1
                var p = Float64(v.step) / 65536.0
                pitch_lo = min(pitch_lo, p)
                pitch_hi = max(pitch_hi, p)
                var g = Float64(v.gain)
                if g < 0.5011 - 1e-4 or g > 1.0 + 1e-6:
                    in_range = False
        _ = render_blocks(m, 2000, 128)
    c.ok(seen[0] > 60 and seen[1] > 60 and seen[2] > 60, "300 plays use all three clips: " + String(seen[0]) + " " + String(seen[1]) + " " + String(seen[2]))
    c.ok(pitch_lo >= 0.8 - 1e-4 and pitch_hi <= 1.2 + 1e-4 and pitch_hi - pitch_lo > 0.35, "pitch stays in 0.8 .. 1.2 and covers it: " + String(pitch_lo) + " .. " + String(pitch_hi))
    c.ok(in_range, "volume stays in -6 .. 0 dB")


def test_limits(mut c: Check) raises:
    var m = Mixer(RATE, 1)
    _ = m.add_clip("long", constant_clip(48000, 0.1))
    var low = event("low", "long")
    low.limit = 2
    low.priority = 1
    var high = event("high", "long")
    high.limit = 2
    high.priority = 9
    var low_id = m.add_event(low^)
    var high_id = m.add_event(high^)
    var a = m.play_event(low_id)
    var b = m.play_event(low_id)
    var third = m.play_event(low_id)  # equal priority: replaces the oldest of its own event
    c.ok(m.active_voices() == 2, "limit 2: two voices of the event play")
    var a_alive = False
    for v in m.voices:
        if v.active and v.id == a:
            a_alive = True
    c.ok(not a_alive and third > b, "the third play replaced the oldest voice of the event")
    var h1 = m.play_event(high_id)
    var h2 = m.play_event(high_id)
    var h3 = m.play_event(high_id)
    c.ok(h1 > 0 and h2 > 0 and h3 > 0, "a higher-priority event is limited per event, not by other events")
    var dropped_before = m.dropped
    var lower = m.play_event(low_id)  # at its limit (2) with a lower... equal-priority voice present -> replaces
    c.ok(lower > 0 and m.dropped == dropped_before, "an equal-priority play at the limit replaces, it is not dropped")
    # a lower-priority play at the limit is dropped
    var weak = event("weak", "long")
    weak.limit = 1
    weak.priority = 0
    var strong = event("strong", "long")
    strong.limit = 1
    strong.priority = 5
    var weak_id = m.add_event(weak^)
    var strong_id = m.add_event(strong^)
    # strong and weak share no limit; give both the same event so the limit applies: use one event, two priorities
    var m2 = Mixer(RATE, 1)
    _ = m2.add_clip("long", constant_clip(48000, 0.1))
    var e = event("e", "long")
    e.limit = 1
    e.priority = 5
    var e_id = m2.add_event(e^)
    var first = m2.play_event(e_id)
    m2.events[e_id].priority = 2
    var second = m2.play_event(e_id)
    c.ok(first > 0 and second == -1 and m2.dropped == 1 and m2.active_voices() == 1, "a lower-priority play at the limit is dropped and counted")
    _ = weak_id
    _ = strong_id
    # all voices busy: the lowest priority, oldest voice is replaced by a higher one, and a lower one is dropped
    var m3 = Mixer(RATE, 1)
    _ = m3.add_clip("long", constant_clip(48000, 0.1))
    var mid = event("mid", "long")
    mid.priority = 3
    var top = event("top", "long")
    top.priority = 8
    var bottom = event("bottom", "long")
    bottom.priority = 1
    var mid_id = m3.add_event(mid^)
    var top_id = m3.add_event(top^)
    var bottom_id = m3.add_event(bottom^)
    for _ in range(MAX_VOICES):
        _ = m3.play_event(mid_id)
    c.ok(m3.active_voices() == MAX_VOICES, "MAX_VOICES voices are busy")
    c.ok(m3.play_event(bottom_id) == -1 and m3.dropped == 1, "priority 1 against a full set of priority 3 is dropped")
    var t = m3.play_event(top_id)
    var top_playing = False
    for v in m3.voices:
        if v.active and v.id == t:
            top_playing = True
    c.ok(top_playing and m3.active_voices() == MAX_VOICES, "priority 8 replaces a priority 3 voice; the count stays at MAX_VOICES")
    _ = a
    _ = b


def test_buses(mut c: Check) raises:
    var m = Mixer(RATE, 1)
    _ = m.add_clip("k", constant_clip(48000, 0.5))
    var ev = m.add_event(event("k", "k"))
    _ = m.play_event(ev)
    var out = List[Float32]()
    m.render(out, 64)
    c.near(Float64(out[100]), 0.5, 1e-7, "a 0.5 clip on sfx at 0 dB: 0.5")
    m.set_bus_db(BUS_SFX, -6.0206)
    m.render(out, 64)
    c.near(Float64(out[100]), 0.25, 1e-5, "sfx at -6.0206 dB: 0.25")
    m.set_bus_db(BUS_MASTER, -20.0)
    m.render(out, 64)
    c.near(Float64(out[100]), 0.025, 1e-6, "master -20 dB on top: 0.025")
    m.set_bus_mute(BUS_SFX, True)
    m.render(out, 64)
    c.ok(out[100] == 0.0 and out[101] == 0.0, "a muted bus is exactly silent")
    m.set_bus_mute(BUS_SFX, False)
    m.render(out, 64)
    c.near(Float64(out[100]), 0.025, 1e-6, "unmuted: the bus volume is kept")


def ducking_mixer() raises -> Mixer:
    var m = Mixer(RATE, 1)
    _ = m.add_clip("music", constant_clip(96000, 0.5))
    _ = m.add_clip("line", constant_clip(24000, 0.5))
    var track = List[Int]()
    track.append(0)
    _ = m.music.add_track(MusicTrack(120.0, 4, track^))
    m.music.start(0)
    _ = m.add_event(event("line", "line", BUS_VOICE))
    m.set_bus_mute(BUS_VOICE, True)  # the sidechain reads the voice bus before its fader: only the music is heard
    return m^


def test_ducking(mut c: Check) raises:
    var m = ducking_mixer()
    var before = render_blocks(m, 4800, 128)
    c.near(Float64(before[2 * 4799]), 0.5, 1e-7, "music alone: 0.5")
    _ = m.play_event(0)
    var during = render_blocks(m, 9600, 128)  # 200 ms into the line
    var want = Float64(db_to_gain(-12.0)) * 0.5
    c.near(Float64(during[2 * 9599]), want, 2e-3, "200 ms into the line the music is at -12 dB: " + String(want))
    var tail = render_blocks(m, 14400 + 96000, 128)  # the line ends at 0.5 s; then 2.0 s of release (8 time constants)
    c.near(Float64(tail[2 * (len(tail) // 2 - 1)]), 0.5, 2e-3, "after the line and the release the music is back at 0.5")
    var mid = Float64(during[2 * 100])
    c.ok(mid < 0.5 and mid > want, "the attack is a ramp, not a step: " + String(mid))
    # the ducked output is the same however the output is cut into blocks
    var a = ducking_mixer()
    var b = ducking_mixer()
    var d = ducking_mixer()
    _ = a.play_event(0)
    _ = b.play_event(0)
    _ = d.play_event(0)
    var pa = render_blocks(a, 40000, 128)
    var pb = render_blocks(b, 40000, 37)
    var pd = render_blocks(d, 40000, 40000)
    c.ok(hash_pcm(pa) == hash_pcm(pb) and hash_pcm(pa) == hash_pcm(pd), "blocks of 128, 37 and 40000 frames give the same bytes")


def sources_mixer() raises -> Mixer:
    var m = Mixer(RATE, 1)
    _ = m.add_clip("c", constant_clip(96000, 0.5))
    var e = event("c", "c")
    e.spatial = True
    _ = m.add_event(e^)
    m.set_listener(0, 0, 0, 0, 0, -1, 0, 1, 0)
    return m^


def heard(x: Float32, y: Float32, z: Float32) raises -> Tuple[Float64, Float64]:
    var m = sources_mixer()
    _ = m.play_event(0, x, y, z)
    var out = List[Float32]()
    for _ in range(3):
        m.render(out, 128)  # the first block after a gain change overshoots; later blocks are exact
    return (Float64(out[2 * 127]) / 0.5, Float64(out[2 * 127 + 1]) / 0.5)


def test_3d(mut c: Check) raises:
    # inverse attenuation, min distance 1, rolloff 1: gain 1 / d. Panning: the nearer ear gets full gain, the far ear 0.2,
    # a source dead ahead or behind gives 0.5 to each (miniaudio has no front / back cue without HRTF: #137).
    var dist = List[Float32]()
    dist.append(1.0)
    dist.append(10.0)
    dist.append(100.0)
    for i in range(3):
        var d = Float64(dist[i])
        var left = heard(-dist[i], 0, 0)
        var right = heard(dist[i], 0, 0)
        var behind = heard(0, 0, dist[i])
        var ahead = heard(0, 0, -dist[i])
        var tag = " at " + String(Int(d)) + " m"
        c.near(left[0], 1.0 / d, 1e-4 / d, "left source, left ear: 1/d" + tag)
        c.near(left[1], 0.2 / d, 1e-4 / d, "left source, right ear: 0.2/d" + tag)
        c.near(right[0], 0.2 / d, 1e-4 / d, "right source, left ear: 0.2/d" + tag)
        c.near(right[1], 1.0 / d, 1e-4 / d, "right source, right ear: 1/d" + tag)
        c.near(behind[0], 0.5 / d, 1e-3 / d, "source behind, left ear: 0.5/d" + tag)
        c.near(behind[1], 0.5 / d, 1e-3 / d, "source behind, right ear: 0.5/d" + tag)
        c.ok(behind[0] == behind[1], "behind is centered" + tag)
        c.near(ahead[0], behind[0], 1e-6, "ahead and behind give the same gains (no HRTF)" + tag)
    # a tenfold distance is a tenfold quieter source: the model, not the table above
    var near = heard(-1, 0, 0)
    var far = heard(-10, 0, 0)
    var farther = heard(-100, 0, 0)
    c.near(near[0] / far[0], 10.0, 1e-2, "1 m to 10 m: gain / 10")
    c.near(far[0] / farther[0], 10.0, 1e-2, "10 m to 100 m: gain / 10")
    # min distance: inside it the gain does not grow (0.25 m is clamped to 1 m)
    var inside = heard(-0.25, 0, 0)
    c.near(inside[0], 1.0, 1e-4, "inside the min distance the gain stays 1")


def test_moving_emitter(mut c: Check) raises:
    # an emitter walks from 8 m left to 8 m right in 1 s, 1.5 m in front; the energy goes from the left ear to the right
    var m = sources_mixer()
    var id = m.play_event(0, -8, 0, -1.5)
    var left = List[Float64]()
    var right = List[Float64]()
    var out = List[Float32]()
    var blocks = 375  # 375 * 128 frames = 1 s
    for k in range(blocks):
        var x = Float32(-8.0) + Float32(16.0) * Float32(k) / Float32(blocks - 1)
        m.move_voice(id, x, 0, -1.5)
        m.render(out, 128)
        var el = Float64(0.0)
        var er = Float64(0.0)
        for i in range(128):
            el += Float64(out[2 * i]) * Float64(out[2 * i])
            er += Float64(out[2 * i + 1]) * Float64(out[2 * i + 1])
        left.append(el)
        right.append(er)
    var first_l = Float64(0.0)
    var first_r = Float64(0.0)
    var last_l = Float64(0.0)
    var last_r = Float64(0.0)
    for k in range(40):
        first_l += left[k]
        first_r += right[k]
        last_l += left[blocks - 1 - k]
        last_r += right[blocks - 1 - k]
    c.ok(first_l > 4.0 * first_r, "first 40 blocks (source on the left): left energy " + String(first_l) + " > 4 x right " + String(first_r))
    c.ok(last_r > 4.0 * last_l, "last 40 blocks (source on the right): right energy " + String(last_r) + " > 4 x left " + String(last_l))
    var crossed = -1
    for k in range(blocks):
        if right[k] > left[k]:
            crossed = k
            break
    c.ok(crossed > blocks // 2 - 8 and crossed < blocks // 2 + 8, "left and right energy cross at the middle of the walk: block " + String(crossed))


def test_listener(mut c: Check) raises:
    # the camera faces +x: a source at -z is on its left, a source at +x is ahead
    var m = sources_mixer()
    m.set_listener(0, 0, 0, 1, 0, 0, 0, 1, 0)
    _ = m.play_event(0, 0, 0, -10)
    var out = List[Float32]()
    for _ in range(3):
        m.render(out, 128)
    c.ok(out[2 * 127] > 4.0 * out[2 * 127 + 1], "listener facing +x: a source at -z is on the left ear")
    # the listener moves: standing at x = -10, a source at x = 0 is 10 m to the right
    var n = sources_mixer()
    n.set_listener(-10, 0, 0, 0, 0, -1, 0, 1, 0)
    _ = n.play_event(0, 0, 0, 0)
    for _ in range(3):
        n.render(out, 128)
    c.near(Float64(out[2 * 127 + 1]) / 0.5, 0.1, 1e-4, "listener at x = -10, source at the origin: right ear, 1/10")


def test_music(mut c: Check) raises:
    # 120 bpm, 4 beats: a bar is 96000 frames; each track is 2 bars (192000 frames). Track 0 is 0.25, track 1 is 0.75.
    var m = Mixer(RATE, 1)
    _ = m.add_clip("a", constant_clip(192000, 0.25))
    _ = m.add_clip("b", constant_clip(192000, 0.75))
    _ = m.add_clip("kick", constant_clip(192000, 0.125))
    var la = List[Int]()
    la.append(0)
    la.append(2)
    var lb = List[Int]()
    lb.append(1)
    _ = m.music.add_track(MusicTrack(120.0, 4, la^))
    _ = m.music.add_track(MusicTrack(120.0, 4, lb^))
    c.ok(m.music.bar_frames(0) == 96000, "120 bpm in 4/4 at 48 kHz: a bar is 96000 frames")
    m.music.start(0)
    var first = render_blocks(m, 100000, 97)
    c.near(Float64(first[2 * 99999]), 0.375, 1e-7, "both layers of track 0 play: 0.25 + 0.125")
    c.ok(m.music.frames_to_boundary() == 92000, "100000 frames in, the next bar is 92000 frames away")
    m.music.request_track(1)
    var rest = render_blocks(m, 100000, 97)  # frames 100000 .. 199999; the boundary is frame 192000, inside a block
    var cut = 192000 - 100000
    c.near(Float64(rest[2 * (cut - 1)]), 0.375, 1e-7, "the frame before the bar line is still track 0")
    c.near(Float64(rest[2 * cut]), 0.75, 1e-7, "the bar line frame is track 1")
    c.near(Float64(rest[2 * (len(rest) // 2 - 1)]), 0.75, 1e-7, "track 1 keeps playing")
    c.ok(m.music.current == 1 and m.music.switches == 1, "one quantized change was applied")
    # a layer switched off at 0.3 bar goes quiet exactly at the next bar line
    var n = Mixer(RATE, 1)
    _ = n.add_clip("a", constant_clip(192000, 0.25))
    _ = n.add_clip("kick", constant_clip(192000, 0.125))
    var l = List[Int]()
    l.append(0)
    l.append(1)
    _ = n.music.add_track(MusicTrack(120.0, 4, l^))
    n.music.start(0)
    _ = render_blocks(n, 30000, 128)
    n.music.request_layer(1, False)
    var after = render_blocks(n, 100000, 128)
    var line = 96000 - 30000
    c.near(Float64(after[2 * (line - 1)]), 0.375, 1e-7, "layer 1 still plays up to the bar line")
    c.near(Float64(after[2 * line]), 0.25, 1e-7, "layer 1 is off from the bar line")
    # a request exactly on a bar line takes effect at once
    var p = Mixer(RATE, 1)
    _ = p.add_clip("a", constant_clip(192000, 0.25))
    _ = p.add_clip("b", constant_clip(192000, 0.75))
    var pa = List[Int]()
    pa.append(0)
    var pb = List[Int]()
    pb.append(1)
    _ = p.music.add_track(MusicTrack(120.0, 4, pa^))
    _ = p.music.add_track(MusicTrack(120.0, 4, pb^))
    p.music.start(0)
    _ = render_blocks(p, 96000, 128)
    p.music.request_track(1)
    var now = render_blocks(p, 10, 10)
    c.near(Float64(now[0]), 0.75, 1e-7, "a request made exactly on a bar line switches on that frame")
    # the music loops
    var q = Mixer(RATE, 1)
    var tag = List[Float32]()
    for i in range(2 * 1000):
        tag.append(Float32(i // 2) / 1000.0)
    _ = q.add_clip("ramp", tag^)
    var ql = List[Int]()
    ql.append(0)
    _ = q.music.add_track(MusicTrack(120.0, 4, ql^))
    q.music.start(0)
    var loop = render_blocks(q, 2500, 128)
    c.near(Float64(loop[2 * 1000]), 0.0, 1e-7, "the loop restarts at its first frame")
    c.near(Float64(loop[2 * 2499]), 0.499, 1e-6, "and runs on from there")


def sine_block(frames: Int, freq: Float64, db: Float64) -> List[Float32]:
    var out = List[Float32](capacity=2 * frames)
    var amp = Float64(db_to_gain(Float32(db)))
    for i in range(frames):
        var s = Float32(amp * sin(6.283185307179586 * freq * Float64(i) / 48000.0))
        out.append(s)
        out.append(s)
    return out^


def test_loudness(mut c: Check):
    # EBU Tech 3341 test case 1: a stereo 997 Hz sine at -23 dBFS reads -23.0 LUFS (tolerance +-0.1 LU)
    var meter = LoudnessMeter()
    var tone = sine_block(5 * 48000, 997.0, -23.0)
    meter.feed(tone, 5 * 48000)
    c.near(meter.momentary(), -23.0, 0.1, "momentary loudness of a -23 dBFS 997 Hz stereo sine")
    c.near(meter.integrated(), -23.0, 0.1, "integrated loudness of the same")
    var loud = LoudnessMeter()
    var tone2 = sine_block(5 * 48000, 997.0, -13.0)
    loud.feed(tone2, 5 * 48000)
    c.near(loud.integrated() - meter.integrated(), 10.0, 0.05, "10 dB more level reads 10 LU more")
    # silence after the tone: the momentary value falls, the integrated one stays (the silence is gated out)
    var silence = List[Float32](length=2 * 3 * 48000, fill=0.0)
    meter.feed(silence, 3 * 48000)
    c.ok(meter.momentary() == LUFS_FLOOR, "after 3 s of silence the momentary loudness is the floor")
    # BS.1770 windows are 400 ms every 100 ms: 47 lie inside the 5 s tone, 3 straddle its end with 75 %, 50 % and 25 % of
    # the power, and the rest are below -70 LUFS and gated out: 10 log10(48.5 / 50) = -0.132 dB under -23.
    c.near(meter.integrated(), -23.132, 0.01, "the integrated loudness ignores the silence except the 3 straddling windows")
    # a quiet passage 20 LU under the loud one is dropped by the relative gate
    var gated = LoudnessMeter()
    gated.feed(tone2, 5 * 48000)
    var quiet = sine_block(5 * 48000, 997.0, -43.0)
    gated.feed(quiet, 5 * 48000)
    c.near(gated.integrated(), -13.132, 0.01, "a passage 30 LU lower is removed by the relative gate (same 3 straddling windows)")
    c.ok(LoudnessMeter().integrated() == LUFS_FLOOR and LoudnessMeter().momentary() == LUFS_FLOOR, "no signal: the floor")


def test_assets(mut c: Check) raises:
    # the committed clips: 2 bars at 120 bpm, 48 kHz = 192000 frames, peak under 1, loop seam without a jump
    var m = Mixer(RATE, 1)
    var names = List[String]()
    names.append("calm_pad")
    names.append("calm_perc")
    names.append("tense_pad")
    for n in names:
        var bytes: List[UInt8]
        with open("assets/audio/" + n + ".lsound", "r") as f:
            bytes = f.read_bytes()
        var mono = lsound_to_mono(bytes)
        var peak = Float32(0.0)
        for s in mono:
            peak = max(peak, abs(s))
        c.ok(len(mono) == 192000, n + ": 192000 frames, got " + String(len(mono)))
        c.ok(peak > 0.2 and peak < 1.0, n + ": peak " + String(peak))
        _ = m.add_clip_mono(n, mono)
    var text: String
    with open("assets/audio/music.music", "r") as f:
        text = f.read()
    c.ok(load_music(m, text) == 2, "music.music defines two tracks")
    c.ok(m.track_id("calm") == 0 and m.track_id("tense") == 1 and m.track_id("nope") == -1, "tracks are found by name")
    c.ok(m.music.bar_frames(0) == 96000 and len(m.music.tracks[0].layers) == 2, "calm: 96000-frame bars, two layers")
    m.music.start(0)
    var first = render_blocks(m, 2000, 128)
    var peak_mix = Float32(0.0)
    for s in first:
        peak_mix = max(peak_mix, abs(s))
    c.ok(peak_mix > 0.1 and peak_mix < 1.0, "the calm track mixes to a peak of " + String(peak_mix))
    # a transition requested at 1 s waits for the bar line at 2 s (frame 96000)
    _ = render_blocks(m, 48000 - 2000, 128)
    m.music.request_track(1)
    _ = render_blocks(m, 96000 - 48000 - 1, 128)
    c.ok(m.music.current == 0 and m.music.frames_to_boundary() == 1, "one frame before the bar line the old track still plays")
    _ = render_blocks(m, 1, 1)
    c.ok(m.music.current == 0, "the change is applied when the next block starts at the line")
    _ = render_blocks(m, 1, 1)
    c.ok(m.music.current == 1 and len(m.music.layer_on) == 1, "on the bar line: tense, one layer")
    # parse errors
    var bad = List[String]()
    bad.append("bpm 120\n")
    bad.append("track a\n  bpm 120\n")
    bad.append("track a\n  layers x\n  tempo 3\n")
    var msgs = List[String]()
    for t in bad:
        try:
            _ = parse_music(t)
            msgs.append("accepted")
        except err:
            msgs.append(String(err))
    c.ok(msgs[0] == "line 1: `bpm` before any `track`", "music: " + msgs[0])
    c.ok(msgs[1] == "track `a` needs layers, bpm > 0 and beats >= 1", "music: " + msgs[1])
    c.ok(msgs[2] == "line 3: unknown or incomplete `tempo`", "music: " + msgs[2])
    var garbage = List[UInt8]()
    for _ in range(40):
        garbage.append(7)
    var refused = False
    try:
        _ = lsound_to_mono(garbage)
    except:
        refused = True
    c.ok(refused, "a file without the LSND magic is refused")


def main() raises:
    var c = Check()
    test_math(c)
    test_parse(c)
    test_events(c)
    test_limits(c)
    test_buses(c)
    test_ducking(c)
    test_3d(c)
    test_moving_emitter(c)
    test_listener(c)
    test_music(c)
    test_loudness(c)
    test_assets(c)
    print("audio_mixer:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("audio_mixer: failed checks")
