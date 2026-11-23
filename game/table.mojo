"""Data tables with a schema (ludens-engine #119). Format: `docs/data-tables.md`. Standard library only.

A table is a file of rows in the scene row grammar (`path = value`, `#` comments, one row per line):

    ludens-table 1 schema 1
    weapons.sword.damage = 12
    weapons.sword.reach = 1.5
    weapons.bow.ammo = arrows

The row key is `<table>.<entry id>.<field>`; a list field has one row per element, `<table>.<entry>.<field>.<index>`.
The schema is a second file of rows (`ludens-schema 1`, `<table>.schema.<field>.<attr> = value`). `schema_from_text`
and `table_from_text` parse them; every error names the file, the line and the column (the field), for example

    weapons.table:12: weapons.sword.damage: 250 is above the maximum 100

Field kinds: boolean, integer, real, vector, enumeration, ref (an entry of another table), asset (`@<hex id>[:sub]`),
string, list (of one scalar kind). Defaults, `min` / `max`, `required` and `optional` (`none` is legal) are
attributes of a field. Nothing here reads a file or the clock: callers pass text, so the same code runs natively and
in the wasm64 module."""

comptime K_BOOL = 0
comptime K_INT = 1
comptime K_REAL = 2
comptime K_VEC = 3
comptime K_ENUM = 4
comptime K_REF = 5
comptime K_ASSET = 6
comptime K_STRING = 7
comptime K_LIST = 8

comptime SCHEMA_HEADER = "ludens-schema 1"
comptime TABLE_HEADER = "ludens-table 1"


def kind_name(k: Int) -> String:
    if k == K_BOOL:
        return "boolean"
    if k == K_INT:
        return "integer"
    if k == K_REAL:
        return "real"
    if k == K_VEC:
        return "vector"
    if k == K_ENUM:
        return "enumeration"
    if k == K_REF:
        return "ref"
    if k == K_ASSET:
        return "asset"
    if k == K_STRING:
        return "string"
    if k == K_LIST:
        return "list"
    return "?"


def kind_from_name(s: String) -> Int:
    for k in range(9):
        if kind_name(k) == s:
            return k
    return -1


def _words(s: String) -> List[String]:
    var out = List[String]()
    for w in s.split():
        out.append(String(w))
    return out^


def _ident(s: String, allow_dash: Bool) -> Bool:
    """Letters, digits and `_` (and `-` for entry ids); not empty."""
    if s.byte_length() == 0:
        return False
    for b in s.as_bytes():
        var ok = (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95
        if allow_dash and b == 45:
            ok = True
        if not ok:
            return False
    return True


def _parse_int(t: String) raises -> Int:
    var n = t.byte_length()
    if n == 0 or n > 18:
        raise Error("`" + t + "` is not a whole number")
    var i = 0
    var neg = False
    var bytes = t.as_bytes()
    if bytes[0] == 45 or bytes[0] == 43:
        neg = bytes[0] == 45
        i = 1
    if i >= n:
        raise Error("`" + t + "` is not a whole number")
    var v = 0
    while i < n:
        var b = bytes[i]
        if b < 48 or b > 57:
            raise Error("`" + t + "` is not a whole number")
        v = v * 10 + Int(b) - 48
        i += 1
    return -v if neg else v


def _parse_real(t: String) raises -> Float64:
    var v: Float64
    try:
        v = Float64(t)
    except:
        raise Error("`" + t + "` is not a number")
    if v != v or v > 1.0e300 or v < -1.0e300:
        raise Error("`" + t + "` is not finite")
    return v


def real_text(v: Float64) -> String:
    """The shortest decimal that reads back to the same float32 (docs/scene-format.md §3); a whole value has no `.0`."""
    var f = Float32(v)
    if Float64(Int(f)) == Float64(f) and f > -1.0e9 and f < 1.0e9:
        return String(Int(f))
    return String(f)


def quote(s: String) -> String:
    var out = String("\"")
    for b in s.as_bytes():
        if b == 34:
            out += "\\\""
        elif b == 92:
            out += "\\\\"
        elif b == 10:
            out += "\\n"
        else:
            out += chr(Int(b))
    return out + "\""


def _unquote(t: String) raises -> String:
    var n = t.byte_length()
    if n < 2 or t.as_bytes()[0] != 34 or t.as_bytes()[n - 1] != 34:
        raise Error("`" + t + "` is not a string: it needs double quotes")
    var out = List[UInt8]()
    var bytes = t.as_bytes()
    var i = 1
    while i < n - 1:
        var b = bytes[i]
        if b == 92:
            i += 1
            if i >= n - 1:
                raise Error("the string ends in a lone backslash")
            var e = bytes[i]
            if e == 34 or e == 92:
                out.append(e)
            elif e == 110:
                out.append(10)
            else:
                raise Error("the string has the escape `\\" + chr(Int(e)) + "`; only \\\", \\\\ and \\n exist")
        elif b == 34:
            raise Error("the string has an unescaped quote")
        elif b < 32:
            raise Error("the string holds a control character")
        else:
            out.append(b)
        i += 1
    return String(unsafe_from_utf8=out)


struct Field(Copyable, Movable):
    var name: String
    var kind: Int
    var of_kind: Int  # list: the element kind; -1 otherwise
    var required: Bool
    var optional: Bool  # `none` is a legal value, and the default when none is given
    var has_default: Bool
    var default_text: String
    var has_min: Bool
    var has_max: Bool
    var lo: Float64
    var hi: Float64
    var values: List[String]  # enumeration words
    var size: Int  # vector components
    var ref_table: String
    var min_count: Int  # list length bounds; -1 = none
    var max_count: Int
    var line: Int  # in the schema file

    def __init__(out self, name: String):
        self.name = name
        self.kind = -1
        self.of_kind = -1
        self.required = False
        self.optional = False
        self.has_default = False
        self.default_text = String()
        self.has_min = False
        self.has_max = False
        self.lo = 0
        self.hi = 0
        self.values = List[String]()
        self.size = 0
        self.ref_table = String()
        self.min_count = -1
        self.max_count = -1
        self.line = 0

    def elem_kind(self) -> Int:
        return self.of_kind if self.kind == K_LIST else self.kind


struct Schema(Copyable, Movable):
    var table: String
    var version: Int
    var file: String
    var fields: List[Field]

    def __init__(out self):
        self.table = String()
        self.version = 0
        self.file = String()
        self.fields = List[Field]()

    def find(self, name: String) -> Int:
        for i in range(len(self.fields)):
            if self.fields[i].name == name:
                return i
        return -1

    def signature(self) -> String:
        """`name:kind[:of]` per field, space separated: what generated accessors check before they read a table."""
        var out = String()
        for i in range(len(self.fields)):
            if i > 0:
                out += " "
            out += self.fields[i].name + ":" + kind_name(self.fields[i].kind)
            if self.fields[i].kind == K_LIST:
                out += ":" + kind_name(self.fields[i].of_kind)
        return out^


struct Value(Copyable, Movable):
    """One parsed field value. Numbers (boolean as 0 / 1, integer, real, vector components, list elements) are in
    `nums`; words, strings, references and enumeration words are in `strs`. A list holds one element per entry of
    `idx`, in index order."""
    var is_none: Bool
    var nums: List[Float64]
    var strs: List[String]
    var idx: List[String]  # list: the element keys, in the order of their numeric value
    var lines: List[Int]  # list: the line of each element; otherwise one line
    var explicit: Bool  # a row in the file (False: the schema default)

    def __init__(out self):
        self.is_none = False
        self.nums = List[Float64]()
        self.strs = List[String]()
        self.idx = List[String]()
        self.lines = List[Int]()
        self.explicit = False


def _check_range(f: Field, v: Float64, shown: String) raises:
    if f.has_min and v < f.lo:
        raise Error(shown + " is below the minimum " + real_text(f.lo))
    if f.has_max and v > f.hi:
        raise Error(shown + " is above the maximum " + real_text(f.hi))


def _parse_scalar(f: Field, kind: Int, text: String, mut v: Value) raises:
    """Parse one scalar of `kind` under the attributes of `f` and append it to `v`. The error has no location."""
    if kind == K_BOOL:
        if text == "true":
            v.nums.append(1.0)
        elif text == "false":
            v.nums.append(0.0)
        else:
            raise Error("`" + text + "` is not a boolean (true or false)")
    elif kind == K_INT:
        var n = _parse_int(text)
        _check_range(f, Float64(n), text)
        v.nums.append(Float64(n))
    elif kind == K_REAL:
        var r = _parse_real(text)
        _check_range(f, r, text)
        v.nums.append(r)
    elif kind == K_VEC:
        var parts = _words(text)
        if len(parts) != f.size:
            raise Error("`" + text + "` has " + String(len(parts)) + " numbers, the field is a vector of " + String(f.size))
        for p in parts:
            var r = _parse_real(p)
            _check_range(f, r, p)
            v.nums.append(r)
    elif kind == K_ENUM:
        var found = False
        for w in f.values:
            if w == text:
                found = True
        if not found:
            var all = String()
            for w in f.values:
                all += (" " if all.byte_length() > 0 else "") + w
            raise Error("`" + text + "` is not one of: " + all)
        v.strs.append(text)
    elif kind == K_REF:
        if not _ident(text, True):
            raise Error("`" + text + "` is not an entry id (letters, digits, `_` and `-`)")
        v.strs.append(text)
    elif kind == K_ASSET:
        var ok = text.startswith("@") and text.byte_length() >= 17
        if ok:
            var b = text.as_bytes()
            for i in range(1, 17):
                var c = b[i]
                if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102)):
                    ok = False
            if text.byte_length() > 17 and b[17] != 58:
                ok = False
        if not ok:
            raise Error("`" + text + "` is not an asset reference (`@` and 16 lowercase hex digits, optionally `:name`)")
        v.strs.append(text)
    elif kind == K_STRING:
        v.strs.append(_unquote(text))
    else:
        raise Error("internal: no scalar parser for kind " + kind_name(kind))


def _is_scalar_kind(k: Int) -> Bool:
    return k >= 0 and k <= K_STRING


def parse_field_value(f: Field, text: String) raises -> Value:
    """A non-list field's value from its text: `none` (optional fields), a scalar or a vector. Used for rows, defaults
    and live edits. The error has no location."""
    var v = Value()
    if f.kind == K_LIST:
        raise Error("`" + f.name + "` is a list: its elements are rows `" + f.name + ".<index>`")
    if text == "none":
        if not f.optional:
            raise Error("`none` is not allowed: the field is not optional")
        v.is_none = True
        return v^
    if text == "?":
        raise Error("`?` marks a value still to be filled")
    _parse_scalar(f, f.kind, text, v)
    return v^


def value_text(f: Field, v: Value) -> String:
    """The canonical text of a non-list value (the form `export` writes)."""
    if v.is_none:
        return "none"
    var k = f.kind
    if k == K_BOOL:
        return "true" if v.nums[0] != 0.0 else "false"
    if k == K_INT:
        return String(Int(v.nums[0]))
    if k == K_REAL:
        return real_text(v.nums[0])
    if k == K_VEC:
        var out = String()
        for i in range(len(v.nums)):
            out += (" " if i > 0 else "") + real_text(v.nums[i])
        return out^
    if k == K_STRING:
        return quote(v.strs[0])
    return v.strs[0]


def _element_text(f: Field, v: Value, i: Int) -> String:
    var k = f.of_kind
    if k == K_BOOL:
        return "true" if v.nums[i] != 0.0 else "false"
    if k == K_INT:
        return String(Int(v.nums[i]))
    if k == K_REAL:
        return real_text(v.nums[i])
    if k == K_STRING:
        return quote(v.strs[i])
    return v.strs[i]


def _bool_attr(text: String) raises -> Bool:
    if text == "true":
        return True
    if text == "false":
        return False
    raise Error("`" + text + "` is not a boolean (true or false)")


def _loc(file: String, line: Int, what: String) -> String:
    return file + ":" + String(line) + ": " + what


def _rows(text: String, file: String, header: String, mut errors: List[String]) raises -> List[List[String]]:
    """Split a file into rows `[line, key, value]` (as text). Checks the header and duplicate keys; comments and blank
    lines go. The header words after `header` are returned as the row `["0", "", "<rest>"]` first."""
    var out = List[List[String]]()
    var lines = text.split("\n")
    var seen = Dict[String, Int]()
    var have_header = False
    for i in range(len(lines)):
        var line = String(lines[i].strip())
        if line.byte_length() == 0 or line.startswith("#"):
            continue
        if not have_header:
            have_header = True
            if line == header or line.startswith(header + " "):
                var rest = String(line[byte = header.byte_length() :].strip())
                out.append([String("0"), String(), rest])
                continue
            errors.append(_loc(file, i + 1, "the first row must be the header `" + header + "`, got `" + line + "`"))
            out.append([String("0"), String(), String()])
        var eq = line.find("=")
        if eq < 0:
            errors.append(_loc(file, i + 1, "expected `path = value`, got `" + line + "`"))
            continue
        var key = String(line[byte=:eq].strip())
        var value = String(line[byte = eq + 1 :].strip())
        if key.byte_length() == 0:
            errors.append(_loc(file, i + 1, "the row has no path"))
            continue
        if key in seen:
            errors.append(_loc(file, i + 1, key + ": duplicate row (first on line " + String(seen[key]) + ")"))
            continue
        seen[key] = i + 1
        out.append([String(i + 1), key, value])
    if not have_header:
        errors.append(file + ": empty file: the first row must be the header `" + header + "`")
        out.append([String("0"), String(), String()])
    return out^


def _split_key(key: String) -> List[String]:
    var out = List[String]()
    for p in key.split("."):
        out.append(String(p))
    return out^


def schema_from_text(text: String, file: String, mut errors: List[String]) raises -> Schema:
    """Parse a schema file. Problems are appended to `errors` (each names file and line); the schema returned is
    usable only when `errors` did not grow."""
    var s = Schema()
    s.file = file
    var start = len(errors)
    var rows = _rows(text, file, SCHEMA_HEADER, errors)
    var tbl_set = False
    for r in range(1, len(rows)):
        var ln = Int(rows[r][0])
        var parts = _split_key(rows[r][1])
        var value = rows[r][2]
        if len(parts) < 3 or parts[1] != "schema":
            errors.append(_loc(file, ln, rows[r][1] + ": a schema row is `<table>.schema.version` or `<table>.schema.<field>.<attribute>`"))
            continue
        if not tbl_set:
            s.table = parts[0]
            tbl_set = True
            if not _ident(s.table, False):
                errors.append(_loc(file, ln, "table name `" + s.table + "` is not letters, digits and `_`"))
        elif parts[0] != s.table:
            errors.append(_loc(file, ln, rows[r][1] + ": the schema is for table `" + s.table + "`, this row is for `" + parts[0] + "`"))
            continue
        if len(parts) == 3 and parts[2] == "version":
            try:
                s.version = _parse_int(value)
                if s.version < 1:
                    errors.append(_loc(file, ln, rows[r][1] + ": the version must be 1 or more"))
            except e:
                errors.append(_loc(file, ln, rows[r][1] + ": " + String(e)))
            continue
        if len(parts) != 4:
            errors.append(_loc(file, ln, rows[r][1] + ": expected `" + s.table + ".schema.<field>.<attribute>`"))
            continue
        var fname = parts[2]
        var attr = parts[3]
        if not _ident(fname, False):
            errors.append(_loc(file, ln, rows[r][1] + ": field name `" + fname + "` is not letters, digits and `_`"))
            continue
        var fi = s.find(fname)
        if fi < 0:
            var nf = Field(fname)
            nf.line = ln
            s.fields.append(nf^)
            fi = len(s.fields) - 1
        try:
            if attr == "kind":
                var k = kind_from_name(value)
                if k < 0:
                    raise Error("`" + value + "` is not a kind (boolean integer real vector enumeration ref asset string list)")
                s.fields[fi].kind = k
            elif attr == "of":
                var k = kind_from_name(value)
                if not _is_scalar_kind(k) or k == K_VEC:
                    raise Error("a list holds boolean, integer, real, enumeration, ref, asset or string elements, not `" + value + "`")
                s.fields[fi].of_kind = k
            elif attr == "default":
                s.fields[fi].has_default = True
                s.fields[fi].default_text = value
            elif attr == "min":
                s.fields[fi].has_min = True
                s.fields[fi].lo = _parse_real(value)
            elif attr == "max":
                s.fields[fi].has_max = True
                s.fields[fi].hi = _parse_real(value)
            elif attr == "values":
                s.fields[fi].values = _words(value)
            elif attr == "size":
                s.fields[fi].size = _parse_int(value)
            elif attr == "ref":
                s.fields[fi].ref_table = value
            elif attr == "required":
                s.fields[fi].required = _bool_attr(value)
            elif attr == "optional":
                s.fields[fi].optional = _bool_attr(value)
            elif attr == "min_count":
                s.fields[fi].min_count = _parse_int(value)
            elif attr == "max_count":
                s.fields[fi].max_count = _parse_int(value)
            elif attr == "doc":
                pass
            else:
                raise Error("unknown attribute `" + attr + "`")
        except e:
            errors.append(_loc(file, ln, rows[r][1] + ": " + String(e)))
    if not tbl_set and len(errors) == start:
        errors.append(file + ": the schema has no rows")
    if s.version < 1 and len(errors) == start:
        errors.append(file + ": missing `" + s.table + ".schema.version = <n>`")
    # per-field consistency, then the defaults (they are parsed under the field's own attributes)
    for i in range(len(s.fields)):
        ref f = s.fields[i]
        var at = file + ":" + String(f.line) + ": " + s.table + ".schema." + f.name + ": "
        if f.kind < 0:
            errors.append(at + "no `kind`")
            continue
        if f.kind == K_LIST and not _is_scalar_kind(f.of_kind):
            errors.append(at + "a list needs `of` (the element kind)")
            continue
        if f.kind != K_LIST and f.of_kind >= 0:
            errors.append(at + "`of` is only for lists")
        if f.kind == K_VEC and (f.size < 2 or f.size > 16):
            errors.append(at + "a vector needs `size` between 2 and 16")
            continue
        if f.elem_kind() == K_ENUM and len(f.values) == 0:
            errors.append(at + "an enumeration needs `values`")
            continue
        if f.elem_kind() == K_REF and f.ref_table.byte_length() == 0:
            errors.append(at + "a ref needs `ref = <table>`")
            continue
        if f.has_min and f.has_max and f.lo > f.hi:
            errors.append(at + "min " + real_text(f.lo) + " is above max " + real_text(f.hi))
        if f.required and f.has_default:
            errors.append(at + "a field is either `required` or has a `default`, not both")
            continue
        if f.kind == K_LIST:
            if f.has_default:
                errors.append(at + "a list has no `default`; it is empty unless it is `required`")
            continue
        if not f.required and not f.has_default and not f.optional:
            errors.append(at + "needs one of `required = true`, a `default` or `optional = true`")
            continue
        if f.has_default:
            try:
                _ = parse_field_value(f, f.default_text)
            except e:
                errors.append(at + "default: " + String(e))
    return s^


struct Entry(Copyable, Movable):
    var id: String
    var line: Int  # first row of the entry
    var values: List[Value]  # one per schema field, in schema order

    def __init__(out self, id: String, line: Int):
        self.id = id
        self.line = line
        self.values = List[Value]()


struct Row(Copyable, Movable):
    """A row as written: kept so `export` can rewrite single rows and leave every other byte of the file alone."""
    var key: String
    var text: String
    var line: Int

    def __init__(out self, key: String, text: String, line: Int):
        self.key = key
        self.text = text
        self.line = line


struct Table(Copyable, Movable):
    var schema: Schema
    var file: String
    var entries: List[Entry]
    var by_id: Dict[String, Int]

    def __init__(out self, var schema: Schema, file: String):
        self.schema = schema^
        self.file = file
        self.entries = List[Entry]()
        self.by_id = Dict[String, Int]()

    def entry(self, id: String) raises -> Int:
        if id in self.by_id:
            return self.by_id[id]
        return -1

    def _at(self, id: String, field: String, kind: Int) raises -> Tuple[Int, Int]:
        var e = self.entry(id)
        if e < 0:
            raise Error(self.file + ": table `" + self.schema.table + "` has no entry `" + id + "`")
        var f = self.schema.find(field)
        if f < 0:
            raise Error(self.file + ": table `" + self.schema.table + "` has no field `" + field + "`")
        if self.schema.fields[f].kind != kind:
            raise Error(self.schema.table + "." + id + "." + field + " is " + kind_name(self.schema.fields[f].kind) + ", not " + kind_name(kind))
        return (e, f)

    def get_bool(self, id: String, field: String) raises -> Bool:
        var p = self._at(id, field, K_BOOL)
        return self.entries[p[0]].values[p[1]].nums[0] != 0.0

    def get_int(self, id: String, field: String) raises -> Int:
        var p = self._at(id, field, K_INT)
        return Int(self.entries[p[0]].values[p[1]].nums[0])

    def get_real(self, id: String, field: String) raises -> Float64:
        var p = self._at(id, field, K_REAL)
        return self.entries[p[0]].values[p[1]].nums[0]

    def get_str(self, id: String, field: String) raises -> String:
        var e = self.entry(id)
        var f = self.schema.find(field)
        if e < 0 or f < 0:
            raise Error(self.file + ": no `" + id + "." + field + "` in table `" + self.schema.table + "`")
        var k = self.schema.fields[f].kind
        if k != K_STRING and k != K_ENUM and k != K_REF and k != K_ASSET:
            raise Error(self.schema.table + "." + id + "." + field + " is " + kind_name(k) + ", not text")
        return self.entries[e].values[f].strs[0]

    def get_vec(self, id: String, field: String) raises -> List[Float64]:
        var p = self._at(id, field, K_VEC)
        return self.entries[p[0]].values[p[1]].nums.copy()


def _list_order(idx: List[String], nums: List[Float64]) -> List[Int]:
    """Positions of the list elements sorted by the numeric value of their index (insertion sort: lists are short)."""
    var order = List[Int]()
    for i in range(len(idx)):
        var at = len(order)
        while at > 0 and nums[order[at - 1]] > nums[i]:
            at -= 1
        order.insert(at, i)
    return order^


def table_from_text(var schema: Schema, text: String, file: String, mut errors: List[String]) raises -> Table:
    """Parse a table file under `schema`. Every problem is appended to `errors` as `file:line: table.entry.field:
    message`. Cross-table references are checked by `check_refs` once all tables are loaded."""
    var tbl = Table(schema^, file)
    var sch = tbl.schema.copy()
    var rows = _rows(text, file, TABLE_HEADER, errors)
    # header: `ludens-table 1 schema <n>`
    var hdr = _words(rows[0][2])
    var need = String(sch.version)
    if len(hdr) != 2 or hdr[0] != "schema":
        errors.append(file + ": the header must be `" + TABLE_HEADER + " schema " + need + "`")
    elif hdr[1] != need:
        errors.append(file + ": written for schema version " + hdr[1] + ", " + sch.file + " is version " + need + " (upgrade the table)")
    # entry order is the order of first appearance; list elements are gathered per (entry, field)
    var lists_idx = Dict[String, List[String]]()
    var lists_txt = Dict[String, List[String]]()
    var lists_ln = Dict[String, List[Int]]()
    for r in range(1, len(rows)):
        var ln = Int(rows[r][0])
        var key = rows[r][1]
        var value = rows[r][2]
        if key.byte_length() == 0:
            continue
        var parts = _split_key(key)
        if len(parts) < 2 or parts[0] != sch.table:
            errors.append(_loc(file, ln, key + ": the key must start with the table name `" + sch.table + ".`"))
            continue
        var id = parts[1]
        if id == "schema":
            errors.append(_loc(file, ln, key + ": `schema` is reserved: it is not an entry id"))
            continue
        if not _ident(id, True):
            errors.append(_loc(file, ln, key + ": entry id `" + id + "` is not letters, digits, `_` and `-`"))
            continue
        var ei = tbl.entry(id)
        if ei < 0:
            var ent = Entry(id, ln)
            for _ in range(len(sch.fields)):
                ent.values.append(Value())
            tbl.entries.append(ent^)
            ei = len(tbl.entries) - 1
            tbl.by_id[id] = ei
        if len(parts) == 2:
            if value != "+":
                errors.append(_loc(file, ln, key + ": an entry row is `" + key + " = +`"))
            continue
        # the field is parts[2]; a list element has more segments (the index may hold a `.`)
        var fi = sch.find(parts[2])
        if fi < 0:
            errors.append(_loc(file, ln, key + ": the schema " + sch.file + " has no field `" + parts[2] + "`"))
            continue
        ref f = sch.fields[fi]
        var at = sch.table + "." + id + "." + f.name
        if f.kind != K_LIST:
            if len(parts) != 3:
                errors.append(_loc(file, ln, key + ": `" + f.name + "` is " + kind_name(f.kind) + ", not a list: the key ends at the field"))
                continue
            try:
                var v = parse_field_value(f, value)
                v.explicit = True
                v.lines.append(ln)
                tbl.entries[ei].values[fi] = v^
            except e:
                errors.append(_loc(file, ln, at + ": " + String(e)))
                tbl.entries[ei].values[fi].explicit = True  # the row exists; it is not also a missing field
        else:
            if len(parts) < 4:
                errors.append(_loc(file, ln, key + ": a list element needs an index: `" + at + ".<index>`"))
                continue
            var index = String()
            for p in range(3, len(parts)):
                index += ("." if p > 3 else "") + parts[p]
            var lk = String(ei) + "/" + String(fi)
            if lk not in lists_idx:
                lists_idx[lk] = List[String]()
                lists_txt[lk] = List[String]()
                lists_ln[lk] = List[Int]()
            lists_idx[lk].append(index)
            lists_txt[lk].append(value)
            lists_ln[lk].append(ln)
    # lists: order by index, parse each element
    for ei in range(len(tbl.entries)):
        for fi in range(len(sch.fields)):
            ref f = sch.fields[fi]
            if f.kind != K_LIST:
                continue
            var lk = String(ei) + "/" + String(fi)
            var at = sch.table + "." + tbl.entries[ei].id + "." + f.name
            if lk not in lists_idx:
                continue
            var idx = lists_idx[lk].copy()
            var txt = lists_txt[lk].copy()
            var lns = lists_ln[lk].copy()
            var nums = List[Float64]()
            var ok = True
            for i in range(len(idx)):
                try:
                    nums.append(_parse_real(idx[i]))
                    if nums[i] < 0:
                        raise Error("the index must not be negative")
                except e:
                    errors.append(_loc(file, lns[i], at + "." + idx[i] + ": the index `" + idx[i] + "` is not a number >= 0 (" + String(e) + ")"))
                    ok = False
                    nums.append(0.0)
            if not ok:
                continue
            var order = _list_order(idx, nums)
            var v = Value()
            v.explicit = True
            for k in range(len(order)):
                var i = order[k]
                if k > 0 and nums[order[k - 1]] == nums[i]:
                    errors.append(_loc(file, lns[i], at + "." + idx[i] + ": the same index as `" + idx[order[k - 1]] + "` (line " + String(lns[order[k - 1]]) + ")"))
                    continue
                var item = Value()
                try:
                    if txt[i] == "?":
                        raise Error("`?` marks a value still to be filled")
                    _parse_scalar(f, f.of_kind, txt[i], item)
                    for n in item.nums:
                        v.nums.append(n)
                    for s in item.strs:
                        v.strs.append(s)
                    v.idx.append(idx[i])
                    v.lines.append(lns[i])
                except e:
                    errors.append(_loc(file, lns[i], at + "." + idx[i] + ": " + String(e)))
            tbl.entries[ei].values[fi] = v^
    # defaults, required fields and list lengths
    for ei in range(len(tbl.entries)):
        for fi in range(len(sch.fields)):
            ref f = sch.fields[fi]
            var at = sch.table + "." + tbl.entries[ei].id + "." + f.name
            var first = tbl.entries[ei].line
            if tbl.entries[ei].values[fi].explicit:
                if f.kind == K_LIST:
                    var n = len(tbl.entries[ei].values[fi].idx)
                    if f.min_count >= 0 and n < f.min_count:
                        errors.append(_loc(file, first, at + ": " + String(n) + " elements, the minimum is " + String(f.min_count)))
                    if f.max_count >= 0 and n > f.max_count:
                        errors.append(_loc(file, first, at + ": " + String(n) + " elements, the maximum is " + String(f.max_count)))
                continue
            if f.required:
                errors.append(_loc(file, first, at + ": required field has no row"))
            elif f.kind == K_LIST:
                if f.min_count > 0:
                    errors.append(_loc(file, first, at + ": 0 elements, the minimum is " + String(f.min_count)))
            elif f.has_default:
                try:
                    var v = parse_field_value(f, f.default_text)
                    v.lines.append(0)
                    tbl.entries[ei].values[fi] = v^
                except:
                    pass  # reported when the schema was read
            else:
                var v = Value()
                v.is_none = True
                v.lines.append(0)
                tbl.entries[ei].values[fi] = v^
    return tbl^


def check_refs(tables: List[Table], mut errors: List[String]) raises:
    """Every `ref` value names an entry of the table the schema points at; a dangling one is reported with the file,
    line and column of the row that holds it."""
    for t in range(len(tables)):
        ref tb = tables[t]
        for fi in range(len(tb.schema.fields)):
            ref f = tb.schema.fields[fi]
            if f.elem_kind() != K_REF:
                continue
            var target = -1
            for u in range(len(tables)):
                if tables[u].schema.table == f.ref_table:
                    target = u
            for ei in range(len(tb.entries)):
                ref v = tb.entries[ei].values[fi]
                if v.is_none:
                    continue
                for k in range(len(v.strs)):
                    var at = tb.schema.table + "." + tb.entries[ei].id + "." + f.name
                    var ln = v.lines[k] if k < len(v.lines) else v.lines[0]
                    if f.kind == K_LIST:
                        at += "." + v.idx[k]
                    if target < 0:
                        errors.append(_loc(tb.file, ln, at + ": refers to table `" + f.ref_table + "`, which is not loaded"))
                    elif tables[target].entry(v.strs[k]) < 0:
                        errors.append(_loc(tb.file, ln, at + ": `" + v.strs[k] + "` is not an entry of table `" + f.ref_table + "` (" + tables[target].file + ")"))


def _asset_id(ref_text: String) -> String:
    """`@<id>:<name>` -> `@<id>`."""
    var c = ref_text.find(":")
    if c > 0:
        return String(ref_text[byte=:c])
    return ref_text


def check_assets(tables: List[Table], known: List[String], mut errors: List[String]) raises:
    """Every `asset` value is one of the `known` asset ids (`@<id>` or `@<id>:<name>`; the part after `:` is not
    compared). The asset database (#12) is the caller's source of `known`."""
    var ids = Dict[String, Int]()
    for k in known:
        ids[_asset_id(String(k))] = 1
    for t in range(len(tables)):
        ref tb = tables[t]
        for fi in range(len(tb.schema.fields)):
            ref f = tb.schema.fields[fi]
            if f.elem_kind() != K_ASSET:
                continue
            for ei in range(len(tb.entries)):
                ref v = tb.entries[ei].values[fi]
                if v.is_none:
                    continue
                for k in range(len(v.strs)):
                    if _asset_id(v.strs[k]) not in ids:
                        var ln = v.lines[k] if k < len(v.lines) else v.lines[0]
                        errors.append(_loc(tb.file, ln, tb.schema.table + "." + tb.entries[ei].id + "." + f.name + ": asset `" + v.strs[k] + "` is not in the asset database"))


def table_load(schema_text: String, schema_file: String, table_text: String, table_file: String) raises -> Table:
    """Schema and table in one call for a single table; raises one error holding every problem, one per line."""
    var errors = List[String]()
    var sch = schema_from_text(schema_text, schema_file, errors)
    if len(errors) > 0:
        raise Error(join_lines(errors))
    var t = table_from_text(sch^, table_text, table_file, errors)
    if len(errors) > 0:
        raise Error(join_lines(errors))
    return t^


def join_lines(lines: List[String]) -> String:
    var out = String()
    for i in range(len(lines)):
        out += (String("\n") if i > 0 else String()) + lines[i]
    return out^
