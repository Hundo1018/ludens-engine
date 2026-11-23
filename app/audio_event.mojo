"""Audio event assets: a named event that picks one of several clips at random, with pitch and volume ranges, a priority
and a concurrency limit (ludens-engine #120). Standard library only; no file is read here, the caller passes the text.

Text format, one event per `event` line, keys indented, `#` starts a comment:

    event jump
      clips jump_a jump_b jump_c     # clip names; the mixer resolves them to registered clips
      bus sfx                        # master | music | sfx | ambience | ui | voice (default sfx)
      pitch 0.95 1.05                # playback-rate range, 1.0 = unchanged
      volume -3 0                    # dB range added to the bus gain
      priority 5                     # higher wins when voices run out
      limit 2                        # at most this many voices of this event at once (0 = no limit)
      spatial 1                      # 1: positioned through a Spatializer
      min_distance 1                 # full-gain radius in metres
      max_distance 60                # gain stops falling here"""

comptime BUS_MASTER = 0
comptime BUS_MUSIC = 1
comptime BUS_SFX = 2
comptime BUS_AMBIENCE = 3
comptime BUS_UI = 4
comptime BUS_VOICE = 5
comptime BUS_COUNT = 6


def bus_name(bus: Int) -> String:
    if bus == BUS_MASTER:
        return "master"
    if bus == BUS_MUSIC:
        return "music"
    if bus == BUS_SFX:
        return "sfx"
    if bus == BUS_AMBIENCE:
        return "ambience"
    if bus == BUS_UI:
        return "ui"
    if bus == BUS_VOICE:
        return "voice"
    return "?"


def bus_by_name(name: String) -> Int:
    for b in range(BUS_COUNT):
        if bus_name(b) == name:
            return b
    return -1


struct AudioEvent(Copyable, Movable):
    var name: String
    var clip_names: List[String]
    var bus: Int
    var pitch_lo: Float32
    var pitch_hi: Float32
    var volume_lo_db: Float32
    var volume_hi_db: Float32
    var priority: Int
    var limit: Int
    var spatial: Bool
    var min_distance: Float32
    var max_distance: Float32

    def __init__(out self, name: String):
        self.name = name
        self.clip_names = List[String]()
        self.bus = BUS_SFX
        self.pitch_lo = 1.0
        self.pitch_hi = 1.0
        self.volume_lo_db = 0.0
        self.volume_hi_db = 0.0
        self.priority = 0
        self.limit = 0
        self.spatial = False
        self.min_distance = 1.0
        self.max_distance = 100000.0


def _num(tok: String, where: String) raises -> Float32:
    try:
        return Float32(atof(tok))
    except:
        raise Error(where + ": `" + tok + "` is not a number")


def parse_events(text: String) raises -> List[AudioEvent]:
    """Parse event assets. The error names the 1-based line."""
    var out = List[AudioEvent]()
    var lines = text.split("\n")
    for n in range(len(lines)):
        var raw = String(lines[n])
        var hash = raw.find("#")
        var text_line = String(raw[byte = 0 : hash]) if hash >= 0 else raw
        var toks = List[String]()
        for t in text_line.split():
            toks.append(String(t))
        if len(toks) == 0:
            continue
        var where = "line " + String(n + 1)
        var key = toks[0]
        if key == "event":
            if len(toks) != 2:
                raise Error(where + ": `event` takes one name")
            out.append(AudioEvent(toks[1]))
            continue
        if len(out) == 0:
            raise Error(where + ": `" + key + "` before any `event`")
        var e = len(out) - 1
        if key == "clips":
            if len(toks) < 2:
                raise Error(where + ": `clips` needs at least one clip name")
            for i in range(1, len(toks)):
                out[e].clip_names.append(toks[i])
        elif key == "bus":
            if len(toks) != 2 or bus_by_name(toks[1]) < 0:
                raise Error(where + ": `bus` is one of master music sfx ambience ui voice")
            out[e].bus = bus_by_name(toks[1])
        elif key == "pitch":
            if len(toks) != 3:
                raise Error(where + ": `pitch` takes a low and a high value")
            out[e].pitch_lo = _num(toks[1], where)
            out[e].pitch_hi = _num(toks[2], where)
            if out[e].pitch_lo <= 0.0 or out[e].pitch_hi < out[e].pitch_lo or out[e].pitch_hi > 4.0:
                raise Error(where + ": pitch needs 0 < low <= high <= 4")
        elif key == "volume":
            if len(toks) != 3:
                raise Error(where + ": `volume` takes a low and a high value in dB")
            out[e].volume_lo_db = _num(toks[1], where)
            out[e].volume_hi_db = _num(toks[2], where)
            if out[e].volume_hi_db < out[e].volume_lo_db:
                raise Error(where + ": volume needs low <= high")
        elif key == "priority":
            if len(toks) != 2:
                raise Error(where + ": `priority` takes one integer")
            out[e].priority = Int(_num(toks[1], where))
        elif key == "limit":
            if len(toks) != 2 or _num(toks[1], where) < 0.0:
                raise Error(where + ": `limit` takes an integer >= 0")
            out[e].limit = Int(_num(toks[1], where))
        elif key == "spatial":
            if len(toks) != 2:
                raise Error(where + ": `spatial` takes 0 or 1")
            out[e].spatial = _num(toks[1], where) != 0.0
        elif key == "min_distance":
            if len(toks) != 2 or _num(toks[1], where) <= 0.0:
                raise Error(where + ": `min_distance` takes a value > 0")
            out[e].min_distance = _num(toks[1], where)
        elif key == "max_distance":
            if len(toks) != 2 or _num(toks[1], where) <= 0.0:
                raise Error(where + ": `max_distance` takes a value > 0")
            out[e].max_distance = _num(toks[1], where)
        else:
            raise Error(where + ": unknown key `" + key + "`")
    for i in range(len(out)):
        if len(out[i].clip_names) == 0:
            raise Error("event `" + out[i].name + "` names no clips")
    return out^
