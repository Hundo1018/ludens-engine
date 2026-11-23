"""Live tuning of a data table (ludens-engine #119). Standard library only; `game/table.mojo` holds the table.

`Tuner.set` checks one edit against the schema (kind, range, enumeration word, optional) and queues it; it never touches
the table. `Tuner.apply` is called at the start of a tick and commits the queued edits in the order they were set, so a
game that reads the table after `apply` sees a change at a tick boundary and never inside a tick. `Tuner.export_text`
returns the table file with only the changed rows rewritten (or inserted in key order); every other byte of the file,
comments included, stays as it was, so the change reads as a few rows in a diff and merges like any scene row.

The file is not read or written here: the caller passes the text in and writes the text out."""
from game.table import (
    K_LIST, Field, Table, Value, join_lines, parse_field_value, table_from_text, value_text,
)


struct Change(Copyable, Movable):
    var entry: Int
    var field: Int
    var value: Value
    var text: String  # canonical text of the value

    def __init__(out self, entry: Int, field: Int, var value: Value, text: String):
        self.entry = entry
        self.field = field
        self.value = value^
        self.text = text


struct Tuner(Movable):
    var table: Table
    var source: String  # the table file as loaded
    var queue: List[Change]
    var committed: List[Change]  # every applied edit, in order

    def __init__(out self, var table: Table, source: String):
        self.table = table^
        self.source = source
        self.queue = List[Change]()
        self.committed = List[Change]()

    def set(mut self, entry: String, field: String, text: String) raises:
        """Check an edit and queue it. The error names `table.entry.field`."""
        var e = self.table.entry(entry)
        if e < 0:
            raise Error(self.table.file + ": table `" + self.table.schema.table + "` has no entry `" + entry + "`")
        var f = self.table.schema.find(field)
        if f < 0:
            raise Error(self.table.file + ": table `" + self.table.schema.table + "` has no field `" + field + "`")
        var at = self.table.schema.table + "." + entry + "." + field
        try:
            var v = parse_field_value(self.table.schema.fields[f], text)
            v.explicit = True
            v.lines.append(0)
            var canon = value_text(self.table.schema.fields[f], v)
            for i in range(len(self.queue)):  # a later edit of the same cell replaces the queued one (a slider drag)
                if self.queue[i].entry == e and self.queue[i].field == f:
                    self.queue[i] = Change(e, f, v^, canon)
                    return
            self.queue.append(Change(e, f, v^, canon))
        except err:
            raise Error(at + ": " + String(err))

    def pending(self) -> Int:
        return len(self.queue)

    def current(self, entry: Int, field: Int) -> Value:
        """The value a panel shows: the queued edit if there is one, else the table's."""
        for i in range(len(self.queue)):
            if self.queue[i].entry == entry and self.queue[i].field == field:
                return self.queue[i].value.copy()
        return self.table.entries[entry].values[field].copy()

    def apply(mut self) -> Int:
        """Commit the queued edits, in order. Returns how many. Call at the start of a tick."""
        var n = len(self.queue)
        for i in range(n):
            var c = self.queue[i].copy()
            var old_line = self.table.entries[c.entry].values[c.field].lines.copy()
            self.table.entries[c.entry].values[c.field] = c.value.copy()
            if len(old_line) > 0:
                self.table.entries[c.entry].values[c.field].lines = old_line^
            self.committed.append(c^)
        self.queue = List[Change]()
        return n

    def changed(self) raises -> List[Change]:
        """The edits whose final value differs from the table as loaded, one per (entry, field), in first-edit order."""
        var out = List[Change]()
        var done = Dict[String, Int]()
        for i in range(len(self.committed)):
            var key = String(self.committed[i].entry) + "/" + String(self.committed[i].field)
            if key in done:
                out[done[key]] = self.committed[i].copy()
            else:
                done[key] = len(out)
                out.append(self.committed[i].copy())
        # drop the edits that went back to the loaded value
        var base = _loaded_table(self)
        var keep = List[Change]()
        for c in out:
            var f = self.table.schema.fields[c.field].copy()
            if value_text(f, base.entries[c.entry].values[c.field]) != c.text:
                keep.append(c.copy())
        return keep^

    def export_text(self) raises -> String:
        """The table file with the changed rows rewritten. Rows that did not change are copied byte for byte."""
        var changes = self.changed()
        var lines = List[String]()
        for l in self.source.split("\n"):
            lines.append(String(l))
        var had_final_newline = len(lines) > 0 and lines[len(lines) - 1].byte_length() == 0
        if had_final_newline:
            _ = lines.pop()
        for c in changes:
            var key = self.table.schema.table + "." + self.table.entries[c.entry].id + "." + self.table.schema.fields[c.field].name
            var row = key + " = " + c.text
            var at = -1
            for i in range(len(lines)):
                var s = String(lines[i].strip())
                if s.byte_length() == 0 or s.startswith("#"):
                    continue
                var eq = s.find("=")
                if eq > 0 and String(s[byte=:eq].strip()) == key:
                    at = i
            if at >= 0:
                lines[at] = row
                continue
            # a new row goes before the first row with a greater key (a canonical file stays canonical), else at the end
            var pos = len(lines)
            var seen_header = False
            for i in range(len(lines)):
                var s = String(lines[i].strip())
                if s.byte_length() == 0 or s.startswith("#"):
                    continue
                if not seen_header:
                    seen_header = True
                    continue
                var eq = s.find("=")
                if eq > 0 and String(s[byte=:eq].strip()) > key:
                    pos = i
                    break
            lines.insert(pos, row)
        var out = String()
        for i in range(len(lines)):
            out += lines[i] + "\n"
        return out^


def _loaded_table(t: Tuner) raises -> Table:
    """The table as it was before any edit: the schema applied to `source` again."""
    var errors = List[String]()
    var tbl = table_from_text(t.table.schema.copy(), t.source, t.table.file, errors)
    if len(errors) > 0:
        raise Error(join_lines(errors))
    return tbl^


def slider_range(f: Field) -> Tuple[Float64, Float64, Bool]:
    """The range of a slider for a number field and whether it is usable (both `min` and `max` are set)."""
    return (f.lo, f.hi, f.has_min and f.has_max)


def is_tunable(f: Field) -> Bool:
    """A panel can edit every field except a list (its elements are rows of their own, edited in the file)."""
    return f.kind != K_LIST
