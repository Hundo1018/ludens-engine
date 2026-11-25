"""Captions and subtitles (ludens-engine #118): a line of text for a sound the player may not hear, and for each line of
dialogue, with a speaker name, a size and a background the player sets (`Access.captions`, `caption_size`, `caption_background`,
`caption_speaker`).

A caption track is text, one `caption` row per audio event, `#` starts a comment:

    ludens-captions 1
    caption cue1 duration=1200 speaker=cap.speaker.ball text=cap.jump
    caption cue2 duration=900 text=cap.impact
    text en cap.speaker.ball Ball
    text en cap.jump jumps
    text zh-TW cap.jump 跳起來

`event` is the audio event's name (the host triggers it when the mixer plays that event). `text` and `speaker` are keys of the
`text <locale> <key> <string>` rows (the rest of the line is the string), so a caption follows the player's language: `set_locale`
picks the locale by tag, `set_locale_index` by order of first appearance in the file (the UI locale index of `UiEnv`). A key with no
string in the locale falls back to the first locale of the file, then shows the key itself. `speaker` is optional. `duration` is
milliseconds, 100 .. 20000.

`Captions.trigger(event)` shows the row's caption; while the same event's caption is still up its timer is restarted, so a sound
that repeats (footsteps) does not stack. At most `MAX_LINES` captions are up: a new one past that removes the oldest. Dialogue has
no event: `Captions.say(speaker, text, ms)` shows a line the game has already looked up.

`Captions.draw` appends the captions to a draw list: from the bottom edge of the safe area upward, centred, each in a box that
holds its wrapped text, `Access.caption_background` as the box's opacity (no box at 0), the font size 18 reference pixels times the
window factor, the caption size and the UI text scale. Text at 200 % of both is wrapped to the safe width, never past it.

Standard library and ui/."""
from game.access import Access
from ui.draw import Color, DrawList
from ui.geom import Rect
from ui.scale import UiScale
from ui.sdf_font import FontMetrics

comptime MAX_LINES = 3
comptime CAPTION_BASE_PX = Float32(18.0)  # reference pixels at 100 % size and 100 % text scale
comptime MIN_DURATION_MS = 100
comptime MAX_DURATION_MS = 20000


struct CaptionRow(Copyable, Movable):
    var event: String
    var text_key: String
    var speaker_key: String
    var duration_ms: Int

    def __init__(out self, event: String, text_key: String, speaker_key: String, duration_ms: Int):
        self.event = event
        self.text_key = text_key
        self.speaker_key = speaker_key
        self.duration_ms = duration_ms


struct CaptionLine(Copyable, Movable):
    var event: String  # "" for dialogue
    var speaker: String
    var text: String
    var left_ms: Float32

    def __init__(out self, event: String, speaker: String, text: String, left_ms: Float32):
        self.event = event
        self.speaker = speaker
        self.text = text
        self.left_ms = left_ms

    def shown(self, with_speaker: Bool) -> String:
        """What is drawn: `Name: text`, or the text alone."""
        if with_speaker and self.speaker.byte_length() > 0:
            return self.speaker + ": " + self.text
        return self.text


def _int(text: String, what: String) raises -> Int:
    var v = 0
    if text.byte_length() == 0 or text.byte_length() > 6:
        raise Error(what + ": expected a whole number, got `" + text + "`")
    for i in range(text.byte_length()):
        var c = Int(text.as_bytes()[i])
        if c < 48 or c > 57:
            raise Error(what + ": expected a whole number, got `" + text + "`")
        v = v * 10 + (c - 48)
    return v


struct Captions(Movable):
    var rows: List[CaptionRow]
    var locales: List[String]  # tags in order of first appearance
    var str_locale: List[Int]  # the strings: locale index, key, text
    var str_key: List[String]
    var str_text: List[String]
    var locale: Int
    var active: List[CaptionLine]
    var shown_total: Int  # captions raised since the start, for a test or a log

    def __init__(out self):
        self.rows = List[CaptionRow]()
        self.locales = List[String]()
        self.str_locale = List[Int]()
        self.str_key = List[String]()
        self.str_text = List[String]()
        self.locale = 0
        self.active = List[CaptionLine]()
        self.shown_total = 0

    def load(mut self, text: String) raises:
        """Parse a track; replaces the rows. Raises with the line number for a row it cannot read; the old rows stay."""
        var rows = List[CaptionRow]()
        var locales = List[String]()
        var str_locale = List[Int]()
        var str_key = List[String]()
        var str_text = List[String]()
        var seen_header = False
        var n = 0
        for raw in text.split("\n"):
            n += 1
            var line = String(raw)
            var hash = line.find("#")
            if hash >= 0:
                var head = String(line[byte=:hash])
                line = head^
            var words = List[String]()
            for w in line.split():
                words.append(String(w))
            if len(words) == 0:
                continue
            try:
                if not seen_header:
                    if len(words) != 2 or words[0] != "ludens-captions" or words[1] != "1":
                        raise Error("expected `ludens-captions 1`")
                    seen_header = True
                    continue
                if words[0] == "text":
                    if len(words) < 4:
                        raise Error("expected `text <locale> <key> <string>`")
                    var li = -1
                    for j in range(len(locales)):
                        if locales[j] == words[1]:
                            li = j
                    if li < 0:
                        li = len(locales)
                        locales.append(words[1])
                    for j in range(len(str_key)):
                        if str_locale[j] == li and str_key[j] == words[2]:
                            raise Error("a second string for `" + words[2] + "` in " + words[1])
                    var at = line.find(words[2], line.find(words[1]) + words[1].byte_length()) + words[2].byte_length()
                    str_locale.append(li)
                    str_key.append(words[2])
                    str_text.append(String(String(line[byte=at:]).strip()))
                    continue
                if words[0] != "caption" or len(words) < 3:
                    raise Error("expected `caption <event> duration=<ms> text=<key> [speaker=<key>]`")
                var duration = 0
                var key = String()
                var speaker = String()
                for i in range(2, len(words)):
                    var eq = words[i].find("=")
                    if eq < 0:
                        raise Error("`" + words[i] + "` is not key=value")
                    var k = String(words[i][byte=:eq])
                    var v = String(words[i][byte = eq + 1 :])
                    if k == "duration":
                        duration = _int(v, "duration")
                    elif k == "text":
                        key = v
                    elif k == "speaker":
                        speaker = v
                    else:
                        raise Error("unknown attribute `" + k + "`")
                if duration < MIN_DURATION_MS or duration > MAX_DURATION_MS:
                    raise Error("duration must be " + String(MIN_DURATION_MS) + " to " + String(MAX_DURATION_MS) + " ms")
                if key.byte_length() == 0:
                    raise Error("a caption needs text=<key>")
                for r in rows:
                    if r.event == words[1]:
                        raise Error("a second row for `" + words[1] + "`")
                rows.append(CaptionRow(words[1], key, speaker, duration))
            except e:
                raise Error(String(n) + ": " + String(e))
        if not seen_header:
            raise Error("empty caption track: expected `ludens-captions 1`")
        self.rows = rows^
        self.locales = locales^
        self.str_locale = str_locale^
        self.str_key = str_key^
        self.str_text = str_text^
        if self.locale >= len(self.locales):
            self.locale = 0

    def set_locale(mut self, tag: String) -> Bool:
        for i in range(len(self.locales)):
            if self.locales[i] == tag:
                self.locale = i
                return True
        return False

    def set_locale_index(mut self, index: Int):
        """The locale at this place in the file's order; an index past the end keeps the current one."""
        if index >= 0 and index < len(self.locales):
            self.locale = index

    def text_of(self, key: String) -> String:
        """The string of a key in the current locale, else in the first locale, else the key."""
        for pass_ in range(2):
            var want = self.locale if pass_ == 0 else 0
            for i in range(len(self.str_key)):
                if self.str_locale[i] == want and self.str_key[i] == key:
                    return self.str_text[i]
        return key

    def trigger(mut self, event: String) -> Bool:
        """Show the caption of an audio event. False when the track has no row for it."""
        for i in range(len(self.rows)):
            if self.rows[i].event == event:
                var speaker = String()
                if self.rows[i].speaker_key.byte_length() > 0:
                    speaker = self.text_of(self.rows[i].speaker_key)
                self._show(event, speaker, self.text_of(self.rows[i].text_key), Float32(self.rows[i].duration_ms))
                return True
        return False

    def say(mut self, speaker: String, text: String, duration_ms: Int):
        """Show a line of dialogue."""
        self._show(String(), speaker, text, Float32(duration_ms))

    def _show(mut self, event: String, speaker: String, text: String, ms: Float32):
        self.shown_total += 1
        if event.byte_length() > 0:
            for i in range(len(self.active)):
                if self.active[i].event == event:
                    self.active[i].text = text
                    self.active[i].speaker = speaker
                    self.active[i].left_ms = ms
                    return
        self.active.append(CaptionLine(event, speaker, text, ms))
        while len(self.active) > MAX_LINES:
            _ = self.active.pop(0)

    def update(mut self, dt_ms: Float32):
        """Age the captions; the ones whose time is up go."""
        var keep = List[CaptionLine]()
        for i in range(len(self.active)):
            var left = self.active[i].left_ms - dt_ms
            if left > 0.0:
                keep.append(CaptionLine(self.active[i].event, self.active[i].speaker, self.active[i].text, left))
        self.active = keep^

    def clear(mut self):
        self.active.clear()

    def count(self) -> Int:
        return len(self.active)

    def state(self, with_speaker: Bool) -> String:
        """The captions up now as a JSON array of the strings drawn, oldest first (`window.game.captions()`)."""
        var out = String("[")
        for i in range(len(self.active)):
            var s = self.active[i].shown(with_speaker)
            var esc = String()
            for cp in s.codepoints():
                var c = Int(cp.to_u32())
                if c == 34 or c == 92:
                    esc += "\\"
                    esc += chr(c)
                elif c < 32:
                    esc += " "
                else:
                    esc += chr(c)
            out += String("," if i > 0 else "") + '"' + esc + '"'
        return out + "]"

    def draw(
        self, mut dl: DrawList, width: Float32, height: Float32, ui: UiScale, metrics: Optional[FontMetrics], access: Access,
    ):
        """Append the captions up now, bottom of the safe area upward. Nothing when the player has captions off."""
        if not access.captions or len(self.active) == 0:
            return
        var safe = ui.safe_rect(width, height)
        var margin = ui.px(8, width, height)
        var pad = ui.px(6, width, height)
        var size = ui.px(CAPTION_BASE_PX, width, height) * access.caption_size_f() * ui.text_scale
        var avail = safe.w - 2 * margin - 2 * pad
        var bg = access.caption_background_f()
        var y = safe.bottom() - margin
        var i = len(self.active) - 1
        while i >= 0:  # the newest at the bottom
            var s = self.active[i].shown(access.caption_speaker)
            var tw = _measure(s, size, metrics)
            var w = tw if tw < avail else avail
            var h = _height(s, size, w, metrics)
            var bw = w + 2 * pad
            var bh = h + 2 * pad
            y -= bh
            var bx = safe.x + (safe.w - bw) * 0.5
            if bg > 0.0:
                dl.fill(Rect(bx, y, bw, bh), Color(0.0, 0.0, 0.0, bg))
            dl.text(Rect(bx + pad, y + pad, w * 1.02 + 1, h), s, Color(1.0, 1.0, 1.0, 1.0), size)
            y -= pad * 0.5
            i -= 1


def _measure(text: String, size: Float32, metrics: Optional[FontMetrics]) -> Float32:
    """The width of the text on one line: the font's advances, or 0.55 em a character (1 em for a CJK one) with no font."""
    if metrics:
        return metrics.value().measure(text, size)
    var w = Float32(0)
    for ch in text.codepoints():
        w += Float32(1.0) if ch.to_u32() >= 0x2E80 else Float32(0.55)
    return w * size


def _height(text: String, size: Float32, max_w: Float32, metrics: Optional[FontMetrics]) -> Float32:
    if metrics:
        return metrics.value().text_height(text, size, max_w)
    var lines = Float32(1)
    var w = _measure(text, size, metrics)
    if max_w > 0 and w > max_w:
        lines = Float32(Int(w / max_w) + 1)
    return lines * size * 1.45
