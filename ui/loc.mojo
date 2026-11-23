"""Localized string tables (ludens-engine #116).

A `StringTable` is one locale (`zh-TW`): entries keyed by dot-keys (`hud.jumps`), each with its text, a context note for
translators and a maximum length in code points. A `Localizer` holds the tables, the current locale and a fallback chain
(`zh-TW` -> `zh` -> `en`, each table names its `fallback`). Lookup rules:

- `get(key)` walks the chain from the current locale and returns the first text found. A key found nowhere is an error:
  `missing_keys` is incremented, `last_missing` keeps the key, and the text returned is `MISSING_TEXT` (`<?>`), never the key.
  A test that runs a game's UI asserts `missing_keys == 0`.
- `plural(key, n)` picks the form for `n` by the plural rule of the table the entry came from (`PLURAL_*`: CLDR's
  categories one / few / many / other for the four rule families below) and replaces `{n}` with the number.
- `format(key, args)` replaces `{0}` .. `{9}` with the arguments.
- `set_locale(tag)` switches at run time (false and no change for an unknown tag); `version` changes on every switch or
  pseudo-localization toggle, for a HUD cache key.
- Pseudo-localization (`set_pseudo`): every text gets accented Latin-1 letters (`a` -> `å`), is wrapped in `[` `]` and padded
  with `~` to about 40 % longer, with `{...}` placeholders left alone. It is for looking at a layout: longer strings
  must not overlap, and every character it produces is in the font.
- `validate()` lists problems in the source locale (the first table added): a key that is not dot-separated lower-case
  words, no context note, no maximum length, a text over its maximum (any table), a locale with a key the source lacks.
  `untranslated(tag)` lists the source keys a locale does not have. `missing_glyphs(font)` lists every code point any
  text, plural form or pseudo-localized text uses that the font atlas does not hold.

Right-to-left shaping, the plural categories zero and two (Arabic), gender and number-agreement are not handled.
Standard library only."""
from std.collections import Dict
from ui.sdf_font import SdfFont
from ui.text import decode_utf8

comptime MISSING_TEXT = "<?>"
comptime PLURAL_OTHER = 0  # zh ja ko vi th: one form
comptime PLURAL_ONE_OTHER = 1  # en de es it nl sv: n == 1 is one
comptime PLURAL_FR = 2  # fr pt: n = 0 or 1 is one
comptime PLURAL_SLAVIC = 3  # ru uk: one / few / many (integers)
comptime CAT_OTHER = 0
comptime CAT_ONE = 1
comptime CAT_FEW = 2
comptime CAT_MANY = 3


def plural_category(rule: Int, n: Int) -> Int:
    """CLDR's plural category of the integer `n` (negative counts as its absolute value) under `rule`."""
    var a = n if n >= 0 else -n
    if rule == PLURAL_ONE_OTHER:
        return CAT_ONE if a == 1 else CAT_OTHER
    if rule == PLURAL_FR:
        return CAT_ONE if a == 0 or a == 1 else CAT_OTHER
    if rule == PLURAL_SLAVIC:
        var m10 = a % 10
        var m100 = a % 100
        if m10 == 1 and m100 != 11:
            return CAT_ONE
        if m10 >= 2 and m10 <= 4 and not (m100 >= 12 and m100 <= 14):
            return CAT_FEW
        return CAT_MANY
    return CAT_OTHER


@fieldwise_init
struct Entry(Copyable, Movable):
    var key: String
    var forms: List[String]  # indexed by CAT_*; "" = not given (falls back to forms[0], the `other` form)
    var context: String
    var max_len: Int  # code points; 0 = not set


struct StringTable(Movable):
    var locale: String
    var plural_rule: Int
    var fallback: String  # the locale to try next; "" = none
    var entries: List[Entry]
    var index: Dict[String, Int]

    def __init__(out self, locale: String, plural_rule: Int, fallback: String = ""):
        self.locale = locale
        self.plural_rule = plural_rule
        self.fallback = fallback
        self.entries = List[Entry]()
        self.index = Dict[String, Int]()

    def add(mut self, key: String, text: String, context: String = "", max_len: Int = 0):
        var forms = List[String]()
        forms.append(text)
        forms.append(String())
        forms.append(String())
        forms.append(String())
        self._put(Entry(key, forms^, context, max_len))

    def add_plural(
        mut self, key: String, other: String, one: String = "", few: String = "", many: String = "", context: String = "",
        max_len: Int = 0,
    ):
        var forms = List[String]()
        forms.append(other)
        forms.append(one)
        forms.append(few)
        forms.append(many)
        self._put(Entry(key, forms^, context, max_len))

    def _put(mut self, var e: Entry):
        var at = self.index.get(e.key)
        if at:
            self.entries[at.value()] = e^
        else:
            self.index[e.key] = len(self.entries)
            self.entries.append(e^)

    def find(self, key: String) -> Int:
        var at = self.index.get(key)
        return at.value() if at else -1


def _accent(cp: Int) -> Int:
    """The Latin-1 accented form pseudo-localization uses, or `cp` itself."""
    if cp == 97:
        return 0xE5  # a
    if cp == 99:
        return 0xE7  # c
    if cp == 100:
        return 0xF0  # d
    if cp == 101:
        return 0xE9  # e
    if cp == 105:
        return 0xEE  # i
    if cp == 110:
        return 0xF1  # n
    if cp == 111:
        return 0xF6  # o
    if cp == 117:
        return 0xFC  # u
    if cp == 121:
        return 0xFD  # y
    if cp == 65:
        return 0xC5
    if cp == 67:
        return 0xC7
    if cp == 68:
        return 0xD0
    if cp == 69:
        return 0xC9
    if cp == 73:
        return 0xCE
    if cp == 78:
        return 0xD1
    if cp == 79:
        return 0xD6
    if cp == 85:
        return 0xDC
    if cp == 89:
        return 0xDD
    return cp


def pseudo_text(text: String) -> String:
    """`text` with accented letters, in brackets, padded with `~` to 40 % more code points (rounded up); `{...}` untouched."""
    var cps = decode_utf8(text)
    var out = String("[")
    var in_brace = False
    for i in range(len(cps)):
        var cp = cps[i].value
        if cp == 123:
            in_brace = True
        var o = cp if in_brace else _accent(cp)
        if cp == 125:
            in_brace = False
        out += chr(o)
    for _ in range((len(cps) * 4 + 9) // 10):
        out += "~"
    out += "]"
    return out^


def fmt(text: String, args: List[String]) -> String:
    """`text` with `{0}` .. `{9}` replaced by `args[i]`; a placeholder with no argument is left as it is."""
    var cps = decode_utf8(text)
    var out = String()
    var i = 0
    while i < len(cps):
        var cp = cps[i].value
        if cp == 123 and i + 2 < len(cps) and cps[i + 2].value == 125 and cps[i + 1].value >= 48 and cps[i + 1].value <= 57:
            var k = cps[i + 1].value - 48
            if k < len(args):
                out += args[k]
                i += 3
                continue
        out += chr(cp)
        i += 1
    return out^


def _valid_key(key: String) -> Bool:
    var cps = decode_utf8(key)
    var dots = 0
    var seg = 0
    for i in range(len(cps)):
        var cp = cps[i].value
        if cp == 46:
            if seg == 0:
                return False
            dots += 1
            seg = 0
        elif (cp >= 97 and cp <= 122) or (cp >= 48 and cp <= 57) or cp == 95:
            seg += 1
        else:
            return False
    return dots >= 1 and seg > 0


struct Localizer(Movable):
    var tables: List[StringTable]  # tables[0] is the source locale
    var current: Int
    var pseudo: Bool
    var missing_keys: Int
    var last_missing: String
    var version: Int

    def __init__(out self):
        self.tables = List[StringTable]()
        self.current = 0
        self.pseudo = False
        self.missing_keys = 0
        self.last_missing = String()
        self.version = 0

    def add_table(mut self, var t: StringTable):
        self.tables.append(t^)

    def table_of(self, tag: String) -> Int:
        for i in range(len(self.tables)):
            if self.tables[i].locale == tag:
                return i
        return -1

    def locale(self) -> String:
        return self.tables[self.current].locale if len(self.tables) > 0 else String()

    def set_locale(mut self, tag: String) -> Bool:
        var i = self.table_of(tag)
        if i < 0:
            return False
        self.current = i
        self.version += 1
        return True

    def set_pseudo(mut self, on: Bool):
        if on != self.pseudo:
            self.pseudo = on
            self.version += 1

    def reset_errors(mut self):
        self.missing_keys = 0
        self.last_missing = String()

    def _find(self, key: String, mut table: Int, mut entry: Int) -> Bool:
        """The first table of the chain from the current locale that has `key`."""
        var t = self.current
        var steps = 0
        while t >= 0 and steps <= len(self.tables):
            var e = self.tables[t].find(key)
            if e >= 0:
                table = t
                entry = e
                return True
            t = self.table_of(self.tables[t].fallback) if self.tables[t].fallback.byte_length() > 0 else -1
            steps += 1
        return False

    def _out(self, text: String) -> String:
        return pseudo_text(text) if self.pseudo else text

    def _missing(mut self, key: String) -> String:
        self.missing_keys += 1
        self.last_missing = key
        return String(MISSING_TEXT)

    def get(mut self, key: String) -> String:
        var t = 0
        var e = 0
        if not self._find(key, t, e):
            return self._missing(key)
        return self._out(self.tables[t].entries[e].forms[CAT_OTHER])

    def plural(mut self, key: String, n: Int) -> String:
        var t = 0
        var e = 0
        if not self._find(key, t, e):
            return self._missing(key)
        var cat = plural_category(self.tables[t].plural_rule, n)
        var text = self.tables[t].entries[e].forms[cat]
        if text.byte_length() == 0:
            text = self.tables[t].entries[e].forms[CAT_OTHER]
        var out = String()
        var cps = decode_utf8(text)
        var i = 0
        while i < len(cps):
            if cps[i].value == 123 and i + 2 < len(cps) and cps[i + 1].value == 110 and cps[i + 2].value == 125:
                out += String(n)
                i += 3
                continue
            out += chr(cps[i].value)
            i += 1
        return self._out(out)

    def format(mut self, key: String, args: List[String]) -> String:
        var t = 0
        var e = 0
        if not self._find(key, t, e):
            return self._missing(key)
        return self._out(fmt(self.tables[t].entries[e].forms[CAT_OTHER], args))

    def untranslated(self, tag: String) -> List[String]:
        """The source locale's keys that `tag` does not define itself (the fallback chain would supply them)."""
        var out = List[String]()
        var t = self.table_of(tag)
        if t <= 0:
            return out^
        for i in range(len(self.tables[0].entries)):
            var k = self.tables[0].entries[i].key
            if self.tables[t].find(k) < 0:
                out.append(k)
        return out^

    def validate(self) -> List[String]:
        var out = List[String]()
        if len(self.tables) == 0:
            return out^
        for i in range(len(self.tables[0].entries)):
            ref e = self.tables[0].entries[i]
            if not _valid_key(e.key):
                out.append("key '" + e.key + "' is not dot-separated lower-case words")
            if e.context.byte_length() == 0:
                out.append("key '" + e.key + "' has no context note")
            if e.max_len <= 0:
                out.append("key '" + e.key + "' has no maximum length")
        for t in range(len(self.tables)):
            for i in range(len(self.tables[t].entries)):
                ref e = self.tables[t].entries[i]
                var src = self.tables[0].find(e.key)
                if t > 0 and src < 0:
                    out.append(self.tables[t].locale + ": key '" + e.key + "' is not in the source locale")
                    continue
                var limit = e.max_len if e.max_len > 0 else (self.tables[0].entries[src].max_len if src >= 0 else 0)
                if limit <= 0:
                    continue
                for f in range(len(e.forms)):
                    var n = len(decode_utf8(e.forms[f]))
                    if n > limit:
                        out.append(self.tables[t].locale + ": '" + e.key + "' has " + String(n) + " characters, the limit is " + String(limit))
        return out^

    def missing_glyphs(self, font: SdfFont) -> List[Int]:
        """Every code point (distinct, in first-use order) used by any text of any locale, or by its pseudo-localized form,
        that the font atlas does not hold."""
        var out = List[Int]()
        for t in range(len(self.tables)):
            for i in range(len(self.tables[t].entries)):
                for f in range(len(self.tables[t].entries[i].forms)):
                    var text = self.tables[t].entries[i].forms[f]
                    if text.byte_length() == 0:
                        continue
                    var bad = font.missing_in(text)
                    var bad_p = font.missing_in(pseudo_text(text))
                    for k in range(len(bad_p)):
                        bad.append(bad_p[k])
                    for k in range(len(bad)):
                        var seen = False
                        for j in range(len(out)):
                            if out[j] == bad[k]:
                                seen = True
                                break
                        if not seen:
                            out.append(bad[k])
        return out^
