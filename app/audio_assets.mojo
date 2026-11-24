"""Audio files into the mixer (ludens-engine #120): `.lsound` clips (scripts/assets/convert_wav.py) and the track list.

The page hands over raw bytes (`app_load_audio`); decoding and parsing happen here, in the wasm module, so native and web
read a file the same way.

Track list format (`assets/audio/music.music`), `#` starts a comment:

    track calm
      bpm 120
      beats 4                # beats per bar
      layers calm_pad calm_perc"""
from audio_event import AudioEvent
from mixer import Mixer
from music import MusicTrack


def lsound_to_mono(bytes: List[UInt8]) raises -> List[Float32]:
    """Samples of a `.lsound` (magic LSND, u32 version, u32 header length, JSON header, int16 mono frames at 48000 Hz) in -1..1."""
    if len(bytes) < 12 or bytes[0] != 0x4C or bytes[1] != 0x53 or bytes[2] != 0x4E or bytes[3] != 0x44:
        raise Error("not an .lsound file")
    var header_len = Int(bytes[8]) | (Int(bytes[9]) << 8) | (Int(bytes[10]) << 16) | (Int(bytes[11]) << 24)
    var off = 12 + header_len
    if off > len(bytes):
        raise Error(".lsound header is longer than the file")
    var header = String(unsafe_from_utf8=Span(bytes)[12:off])
    if header.find('"rate":48000') < 0 or header.find('"channels":1') < 0:
        raise Error(".lsound must be 48000 Hz mono: " + header)
    var n = (len(bytes) - off) // 2
    var out = List[Float32](capacity=n)
    for i in range(n):
        var raw = Int(bytes[off + 2 * i]) | (Int(bytes[off + 2 * i + 1]) << 8)
        if raw >= 32768:
            raw -= 65536
        out.append(Float32(raw) / 32768.0)
    return out^


struct TrackSpec(Copyable, Movable):
    var name: String
    var bpm: Float32
    var beats: Int
    var layers: List[String]

    def __init__(out self, name: String):
        self.name = name
        self.bpm = 120.0
        self.beats = 4
        self.layers = List[String]()


def parse_music(text: String) raises -> List[TrackSpec]:
    var out = List[TrackSpec]()
    var lines = text.split("\n")
    for n in range(len(lines)):
        var raw = String(lines[n])
        var hash = raw.find("#")
        var body = String(raw[byte = 0 : hash]) if hash >= 0 else raw
        var toks = List[String]()
        for t in body.split():
            toks.append(String(t))
        if len(toks) == 0:
            continue
        var where = "line " + String(n + 1)
        if toks[0] == "track":
            if len(toks) != 2:
                raise Error(where + ": `track` takes one name")
            out.append(TrackSpec(toks[1]))
            continue
        if len(out) == 0:
            raise Error(where + ": `" + toks[0] + "` before any `track`")
        var t = len(out) - 1
        if toks[0] == "bpm" and len(toks) == 2:
            out[t].bpm = Float32(atof(toks[1]))
        elif toks[0] == "beats" and len(toks) == 2:
            out[t].beats = atol(toks[1])
        elif toks[0] == "layers" and len(toks) >= 2:
            for i in range(1, len(toks)):
                out[t].layers.append(toks[i])
        else:
            raise Error(where + ": unknown or incomplete `" + toks[0] + "`")
    for i in range(len(out)):
        if len(out[i].layers) == 0 or out[i].bpm <= 0.0 or out[i].beats < 1:
            raise Error("track `" + out[i].name + "` needs layers, bpm > 0 and beats >= 1")
    return out^


def load_music(mut m: Mixer, text: String) raises -> Int:
    """Add the tracks of a track list; every layer must be a registered clip of the same length as its track's first layer.
    Returns the number of tracks added."""
    var specs = parse_music(text)
    for s in specs:
        var ids = List[Int]()
        for name in s.layers:
            var c = m.clip_id(name)
            if c < 0:
                raise Error("track `" + s.name + "`: unknown clip `" + name + "`")
            if len(ids) > 0 and len(m.clips[c]) != len(m.clips[ids[0]]):
                raise Error("track `" + s.name + "`: layer `" + name + "` is not as long as the first layer")
            ids.append(c)
        _ = m.music.add_track(MusicTrack(s.bpm, s.beats, ids^))
        m.track_names.append(s.name)
    return len(specs)
