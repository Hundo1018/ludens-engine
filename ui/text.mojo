"""Line breaking for UI text (ludens-shell #17): UTF-8 decoding and greedy wrapping with CJK rules.

`break_lines` wraps `text` to `max_width` using glyph advances from a `GlyphMetrics` (the font's job, supplied by the
caller, so layout is testable without a font and the same code serves any renderer). Break opportunities:

- after a run of spaces or tabs (the spaces hang past the edge and are not part of the line);
- between two characters when either is a CJK ideograph, kana, Hangul or full-width form, except that a closing mark
  (`、。，）」』】` ...) never starts a line and an opening mark (`（「『【` ...) never ends one (kinsoku);
- inside a word that is wider than a whole line, as a last resort (the same two marks are still respected);
- at every `\n`, which also gives an empty line for `a\n\nb` and after a trailing `\n`.

Text is decoded here (invalid bytes become U+FFFD, one per byte), and lines are reported as byte ranges into `text`.
Complex scripts (Arabic, Indic shaping), bidirectional text and hyphenation are not handled.
"""

comptime REPLACEMENT = 0xFFFD


trait GlyphMetrics:
    def advance(self, cp: Int) -> Float32:
        """The horizontal advance of code point `cp`."""
        ...


@fieldwise_init
struct Cp(Copyable, ImplicitlyCopyable, Movable):
    var value: Int
    var start: Int  # byte offset
    var end: Int  # byte offset, exclusive


@fieldwise_init
struct Line(Copyable, ImplicitlyCopyable, Movable):
    var start: Int  # byte offset
    var end: Int  # byte offset, exclusive; trailing spaces are not included
    var width: Float32  # the width of the line without its trailing spaces


def decode_utf8(text: String) -> List[Cp]:
    var out = List[Cp]()
    var b = text.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        var lead = Int(b[i])
        var need = 0
        var v = 0
        var min_v = 0
        if lead < 0x80:
            out.append(Cp(lead, i, i + 1))
            i += 1
            continue
        elif lead >= 0xC2 and lead <= 0xDF:
            need = 1
            v = lead & 0x1F
            min_v = 0x80
        elif lead >= 0xE0 and lead <= 0xEF:
            need = 2
            v = lead & 0x0F
            min_v = 0x800
        elif lead >= 0xF0 and lead <= 0xF4:
            need = 3
            v = lead & 0x07
            min_v = 0x10000
        else:
            out.append(Cp(REPLACEMENT, i, i + 1))
            i += 1
            continue
        var ok = i + need < n  # the continuation bytes exist
        if ok:
            for k in range(1, need + 1):
                var c = Int(b[i + k])
                if (c & 0xC0) != 0x80:
                    ok = False
                    break
                v = (v << 6) | (c & 0x3F)
        if ok and (v < min_v or v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)):
            ok = False
        if ok:
            out.append(Cp(v, i, i + need + 1))
            i += need + 1
        else:
            out.append(Cp(REPLACEMENT, i, i + 1))
            i += 1
    return out^


def is_space(cp: Int) -> Bool:
    return cp == 0x20 or cp == 0x09


def is_wide(cp: Int) -> Bool:
    """CJK ideographs, kana, Hangul, CJK symbols and full-width forms: text that may break between any two."""
    return (
        (cp >= 0x2E80 and cp <= 0x9FFF)
        or (cp >= 0xAC00 and cp <= 0xD7AF)
        or (cp >= 0xF900 and cp <= 0xFAFF)
        or (cp >= 0xFF00 and cp <= 0xFFEF)
        or (cp >= 0x20000 and cp <= 0x2FFFF)
    )


def never_starts_line(cp: Int) -> Bool:
    """Closing marks and the long-vowel / middle-dot signs."""
    return (
        cp == 0x3001 or cp == 0x3002 or cp == 0xFF0C or cp == 0xFF0E or cp == 0xFF1A or cp == 0xFF1B
        or cp == 0xFF01 or cp == 0xFF1F or cp == 0xFF09 or cp == 0xFF3D or cp == 0xFF5D or cp == 0x3009
        or cp == 0x300B or cp == 0x300D or cp == 0x300F or cp == 0x3011 or cp == 0x3015 or cp == 0x2019
        or cp == 0x201D or cp == 0x30FB or cp == 0x30FC
    )


def never_ends_line(cp: Int) -> Bool:
    """Opening marks."""
    return (
        cp == 0xFF08 or cp == 0xFF3B or cp == 0xFF5B or cp == 0x3008 or cp == 0x300A or cp == 0x300C
        or cp == 0x300E or cp == 0x3010 or cp == 0x3014 or cp == 0x2018 or cp == 0x201C
    )


def _byte_of(cps: List[Cp], idx: Int, text: String) -> Int:
    return cps[idx].start if idx < len(cps) else text.byte_length()


def _width[M: GlyphMetrics](cps: List[Cp], a: Int, b: Int, metrics: M) -> Float32:
    var w = Float32(0)
    for i in range(a, b):
        w += metrics.advance(cps[i].value)
    return w


def measure[M: GlyphMetrics](text: String, metrics: M) -> Float32:
    """The width of `text` on one line (newlines count as zero)."""
    var cps = decode_utf8(text)
    var w = Float32(0)
    for i in range(len(cps)):
        if cps[i].value != 10:
            w += metrics.advance(cps[i].value)
    return w


def break_lines[M: GlyphMetrics](text: String, metrics: M, max_width: Float32) -> List[Line]:
    """Wrap `text` to `max_width`. Always returns at least one line (the empty text is one empty line)."""
    var cps = decode_utf8(text)
    var n = len(cps)
    var lines = List[Line]()
    var start = 0
    while True:
        var j = start
        var w = Float32(0)
        var content_end = start  # exclusive cp index after the last non-space
        var content_w = Float32(0)
        var cand_next = -1  # cp index where the next line would start
        var cand_end = 0  # cp index where this line would end
        var cand_w = Float32(0)
        var run_start = -1
        var w_before_run = Float32(0)
        var broke = False
        while j < n:
            var cp = cps[j].value
            if cp == 10:
                lines.append(Line(_byte_of(cps, start, text), _byte_of(cps, content_end, text), content_w))
                start = j + 1
                broke = True
                break
            var adv = metrics.advance(cp)
            if is_space(cp):
                if run_start < 0:
                    run_start = j
                    w_before_run = content_w
                w += adv
                cand_next = j + 1
                cand_end = run_start
                cand_w = w_before_run
                j += 1
                continue
            run_start = -1
            if j > start:
                var prev = cps[j - 1].value
                if (is_wide(cp) or is_wide(prev)) and not is_space(prev) and not never_starts_line(cp) and not never_ends_line(prev):
                    cand_next = j
                    cand_end = j
                    cand_w = w
            if j > start and w + adv > max_width:
                if cand_next > start:
                    lines.append(Line(_byte_of(cps, start, text), _byte_of(cps, cand_end, text), cand_w))
                    start = cand_next
                else:
                    var at = j
                    if never_starts_line(cp) and at - 1 > start:
                        at -= 1
                    while at - 1 > start and never_ends_line(cps[at - 1].value):
                        at -= 1
                    lines.append(Line(_byte_of(cps, start, text), _byte_of(cps, at, text), _width(cps, start, at, metrics)))
                    start = at
                while start < n and is_space(cps[start].value):
                    start += 1
                broke = True
                break
            w += adv
            content_w = w
            content_end = j + 1
            j += 1
        if broke:
            continue
        lines.append(Line(_byte_of(cps, start, text), _byte_of(cps, content_end, text), content_w))
        break
    return lines^
