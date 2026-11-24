"""The player's accessibility settings (ludens-engine #118): one struct a game's options screen reads and writes, one text form
that goes into the player profile file next to the input bindings, and the numbers the host feeds the mixer, the renderer and
the UI from it. Standard library only; no file is read or written here.

| key | values | what reads it |
|---|---|---|
| `text_scale` | 100 .. 200 (percent) | `UiEnv.text_scale` (ui/scale.mojo): HUD and widget font sizes |
| `shake` | 0 .. 100 (percent) | `CameraShake.apply` (game/camera_shake.mojo) |
| `reduce_motion` | on, off | shake forced to 0, `SceneRendererOf.reduce_motion` (depth of field and motion blur off) |
| `flash_limit` | on, off | the flash limiter stage (app/access_post.mojo) |
| `flash_step` | 1 .. 50 (percent) | the largest luminance change per 1/60 s while the limiter is on (scaled by the frame time at other rates) |
| `colorblind` | off, protanopia, deuteranopia, tritanopia | the colour-blind stage (app/access_post.mojo) |
| `colorblind_mode` | correct, simulate | correct: shift what the player cannot tell apart; simulate: show what such a player sees |
| `colorblind_strength` | 0 .. 100 (percent) | how far the filter is applied |
| `volume.<bus>` | 0 .. 100 (percent of amplitude) | `Mixer.set_user_volume`; bus = master music sfx ambience ui voice |
| `mono` | on, off | `Mixer.mono`: left and right become their mean |
| `captions` | on, off | `Captions.draw` (game/captions.mojo) |
| `caption_size` | 50 .. 200 (percent) | caption font size, times the text scale |
| `caption_background` | 0 .. 100 (percent opacity) | the box behind a caption |
| `caption_speaker` | on, off | the speaker's name before a line |

Profile rows are `access <key> <value>`, written only for the settings that differ from the defaults, in the order of the
table above. They sit in the same file as the input bindings (`ludens-profile 1`, `set ...` rows: game/action_map.mojo); the
input loader never sees them (`without_access_rows`) and this one never sees the input rows (`access_rows`)."""

comptime TEXT_SCALE_MIN = 100
comptime TEXT_SCALE_MAX = 200
comptime FLASH_STEP_MIN = 1
comptime FLASH_STEP_MAX = 50
comptime CAPTION_SIZE_MIN = 50
comptime CAPTION_SIZE_MAX = 200

comptime CB_OFF = 0
comptime CB_PROTAN = 1
comptime CB_DEUTAN = 2
comptime CB_TRITAN = 3

comptime CB_CORRECT = 0
comptime CB_SIMULATE = 1

comptime ACCESS_BUSES = 6  # master, music, sfx, ambience, ui, voice: the order of app/audio_event.mojo BUS_*


def _bus_key(bus: Int) -> String:
    if bus == 0:
        return "volume.master"
    if bus == 1:
        return "volume.music"
    if bus == 2:
        return "volume.sfx"
    if bus == 3:
        return "volume.ambience"
    if bus == 4:
        return "volume.ui"
    return "volume.voice"


def _cb_name(kind: Int) -> String:
    if kind == CB_PROTAN:
        return "protanopia"
    if kind == CB_DEUTAN:
        return "deuteranopia"
    if kind == CB_TRITAN:
        return "tritanopia"
    return "off"


def _on_off(v: Bool) -> String:
    return "on" if v else "off"


def _parse_int(text: String, lo: Int, hi: Int, key: String) raises -> Int:
    """A whole number of percent inside lo .. hi, or an error naming the key and the range."""
    if text.byte_length() == 0 or text.byte_length() > 4:
        raise Error(key + ": expected a whole number " + String(lo) + " to " + String(hi) + ", got `" + text + "`")
    var v = 0
    for i in range(text.byte_length()):
        var c = Int(text.as_bytes()[i])
        if c < 48 or c > 57:
            raise Error(key + ": expected a whole number " + String(lo) + " to " + String(hi) + ", got `" + text + "`")
        v = v * 10 + (c - 48)
    if v < lo or v > hi:
        raise Error(key + ": " + String(v) + " is outside " + String(lo) + " to " + String(hi))
    return v


def _parse_bool(text: String, key: String) raises -> Bool:
    if text == "on":
        return True
    if text == "off":
        return False
    raise Error(key + ": expected `on` or `off`, got `" + text + "`")


struct Access(Copyable, Movable):
    var text_scale: Int  # percent
    var shake: Int  # percent
    var reduce_motion: Bool
    var flash_limit: Bool
    var flash_step: Int  # percent of full luminance per frame
    var colorblind: Int  # CB_*
    var colorblind_mode: Int  # CB_CORRECT or CB_SIMULATE
    var colorblind_strength: Int  # percent
    var volume: List[Int]  # percent of amplitude, by bus
    var mono: Bool
    var captions: Bool
    var caption_size: Int  # percent
    var caption_background: Int  # percent opacity
    var caption_speaker: Bool

    def __init__(out self):
        self.text_scale = 100
        self.shake = 100
        self.reduce_motion = False
        self.flash_limit = False
        self.flash_step = 1
        self.colorblind = CB_OFF
        self.colorblind_mode = CB_CORRECT
        self.colorblind_strength = 100
        self.volume = List[Int]()
        for _ in range(ACCESS_BUSES):
            self.volume.append(100)
        self.mono = False
        self.captions = False
        self.caption_size = 100
        self.caption_background = 75
        self.caption_speaker = True

    def reset(mut self):
        self = Self()

    # ---- what the host reads --------------------------------------------------------------------------------------

    def text_scale_f(self) -> Float32:
        return Float32(self.text_scale) / 100.0

    def shake_factor(self) -> Float32:
        """The camera shake multiplier: 0 .. 1, and 0 whatever the slider says while reduce motion is on."""
        return 0.0 if self.reduce_motion else Float32(self.shake) / 100.0

    def volume_gain(self, bus: Int) -> Float32:
        """The amplitude factor of a bus: percent / 100 (0 is silence, 100 leaves the bus as the game set it)."""
        return Float32(self.volume[bus]) / 100.0

    def caption_size_f(self) -> Float32:
        return Float32(self.caption_size) / 100.0

    def caption_background_f(self) -> Float32:
        return Float32(self.caption_background) / 100.0

    def flash_step_for(self, dt: Float32) -> Float32:
        """The largest luminance change (0 .. 1) one frame of `dt` seconds may make: `flash_step` percent per 1/60 s, so the
        limit per second is the same at 30, 60 and 144 frames per second. 0 while the limiter is off."""
        return Float32(self.flash_step) / 100.0 * dt * 60.0 if self.flash_limit else Float32(0.0)

    def post_user(self, dt: Float32) -> SIMD[DType.float32, 4]:
        """The four numbers the accessibility stages read from `Frame.user` (SceneRendererOf.post_user): x = colour-blind kind
        (0 off, 1 protan, 2 deutan, 3 tritan), y = its strength 0 .. 1, z = 1 to simulate (0 to correct), w = the flash limiter's
        largest luminance step for a frame of `dt` seconds (0 = limiter off)."""
        var kind = Float32(self.colorblind)
        var strength = Float32(self.colorblind_strength) / 100.0
        var simulate = Float32(1.0 if self.colorblind_mode == CB_SIMULATE else 0.0)
        return SIMD[DType.float32, 4](kind, strength, simulate, self.flash_step_for(dt))

    # ---- setters with the ranges -----------------------------------------------------------------------------------

    def set(mut self, key: String, value: String) raises:
        """Apply one setting from its text form; raises (and changes nothing) for an unknown key or a value out of range."""
        if key == "text_scale":
            self.text_scale = _parse_int(value, TEXT_SCALE_MIN, TEXT_SCALE_MAX, key)
        elif key == "shake":
            self.shake = _parse_int(value, 0, 100, key)
        elif key == "reduce_motion":
            self.reduce_motion = _parse_bool(value, key)
        elif key == "flash_limit":
            self.flash_limit = _parse_bool(value, key)
        elif key == "flash_step":
            self.flash_step = _parse_int(value, FLASH_STEP_MIN, FLASH_STEP_MAX, key)
        elif key == "colorblind":
            var kind = -1
            for k in range(4):
                if _cb_name(k) == value:
                    kind = k
            if kind < 0:
                raise Error(key + ": expected off, protanopia, deuteranopia or tritanopia, got `" + value + "`")
            self.colorblind = kind
        elif key == "colorblind_mode":
            if value == "correct":
                self.colorblind_mode = CB_CORRECT
            elif value == "simulate":
                self.colorblind_mode = CB_SIMULATE
            else:
                raise Error(key + ": expected `correct` or `simulate`, got `" + value + "`")
        elif key == "colorblind_strength":
            self.colorblind_strength = _parse_int(value, 0, 100, key)
        elif key == "mono":
            self.mono = _parse_bool(value, key)
        elif key == "captions":
            self.captions = _parse_bool(value, key)
        elif key == "caption_size":
            self.caption_size = _parse_int(value, CAPTION_SIZE_MIN, CAPTION_SIZE_MAX, key)
        elif key == "caption_background":
            self.caption_background = _parse_int(value, 0, 100, key)
        elif key == "caption_speaker":
            self.caption_speaker = _parse_bool(value, key)
        else:
            var done = False
            for b in range(ACCESS_BUSES):
                if key == _bus_key(b):
                    self.volume[b] = _parse_int(value, 0, 100, key)
                    done = True
            if not done:
                raise Error("unknown setting `" + key + "`")

    def set_line(mut self, line: String) raises:
        """`<key> <value>`, the form `app_access_set` takes."""
        var words = List[String]()
        for w in line.split():
            words.append(String(w))
        if len(words) != 2:
            raise Error("expected `<key> <value>`, got `" + line + "`")
        self.set(words[0], words[1])

    # ---- the profile rows -------------------------------------------------------------------------------------------

    def rows(self) -> String:
        """`access <key> <value>` for every setting that is not at its default, one per line."""
        var d = Access()
        var out = String()
        if self.text_scale != d.text_scale:
            out += "access text_scale " + String(self.text_scale) + "\n"
        if self.shake != d.shake:
            out += "access shake " + String(self.shake) + "\n"
        if self.reduce_motion != d.reduce_motion:
            out += "access reduce_motion " + _on_off(self.reduce_motion) + "\n"
        if self.flash_limit != d.flash_limit:
            out += "access flash_limit " + _on_off(self.flash_limit) + "\n"
        if self.flash_step != d.flash_step:
            out += "access flash_step " + String(self.flash_step) + "\n"
        if self.colorblind != d.colorblind:
            out += "access colorblind " + _cb_name(self.colorblind) + "\n"
        if self.colorblind_mode != d.colorblind_mode:
            out += "access colorblind_mode " + String("simulate" if self.colorblind_mode == CB_SIMULATE else "correct") + "\n"
        if self.colorblind_strength != d.colorblind_strength:
            out += "access colorblind_strength " + String(self.colorblind_strength) + "\n"
        for b in range(ACCESS_BUSES):
            if self.volume[b] != d.volume[b]:
                out += "access " + _bus_key(b) + " " + String(self.volume[b]) + "\n"
        if self.mono != d.mono:
            out += "access mono " + _on_off(self.mono) + "\n"
        if self.captions != d.captions:
            out += "access captions " + _on_off(self.captions) + "\n"
        if self.caption_size != d.caption_size:
            out += "access caption_size " + String(self.caption_size) + "\n"
        if self.caption_background != d.caption_background:
            out += "access caption_background " + String(self.caption_background) + "\n"
        if self.caption_speaker != d.caption_speaker:
            out += "access caption_speaker " + _on_off(self.caption_speaker) + "\n"
        return out^

    def load_rows(mut self, text: String) -> List[String]:
        """Apply the `access` rows of a profile text; every other row is ignored. Returns one message per row it could not apply
        (`3: caption_size: 20 is outside 50 to 200`); the rows around a bad one still apply."""
        var problems = List[String]()
        var n = 0
        for raw in text.split("\n"):
            n += 1
            var line = String(raw)
            if not line.startswith("access "):
                continue
            try:
                self.set_line(String(line[byte = 7 :]))
            except e:
                problems.append(String(n) + ": " + String(e))
        return problems^


def access_rows(text: String) -> String:
    """The `access` rows of a profile text, for `Access.load_rows`."""
    var out = String()
    for raw in text.split("\n"):
        var line = String(raw)
        if line.startswith("access "):
            out += line + "\n"
    return out^


def without_access_rows(text: String) -> String:
    """A profile text with the `access` rows taken out, for `ActionMap.load_profile`."""
    var out = String()
    for raw in text.split("\n"):
        var line = String(raw)
        if line.startswith("access ") or line.byte_length() == 0:
            continue
        out += line + "\n"
    return out^


def join_profile(actions_text: String, access: Access) -> String:
    """The one profile file: the input bindings' text (game/action_map.mojo `profile()`) followed by the access rows."""
    return actions_text + access.rows()
