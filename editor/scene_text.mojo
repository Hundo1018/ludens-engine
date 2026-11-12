"""The flat text form of a scene (ludens-engine #9, slice 1): one `path = value` row per line.

`#` starts a comment, blank lines are ignored, and a path appears once. The rows are the engine's
(`scene_to_fields`), so a new scene property is a new row and this module does not change. Prefabs, nested scenes
and asset references are layered on top of these rows by the format work that follows in #9.

A scene can carry its event sheet (#24) as rows `sheet.<n> = <one line of the sheet>`, read in the order of `n`. They
are this format's rows, not the engine's: `scene_rows_from_text` leaves them out, `scene_sheet_from_text` returns them
as sheet text. In a scene's sheet a body is written `@<i>`, the i-th body of the scene (`body.<i>` rows), because a
handle is only known once the scene is loaded; `sheet_with_handles` puts the handles in."""
from embed.scene_io import SceneField

comptime SCENE_HEADER = "# ludens scene: one `path = value` row per line\n"
comptime SHEET_PREFIX = "sheet."


def scene_rows_to_text(rows: List[SceneField]) -> String:
    var out = String(SCENE_HEADER)
    for i in range(len(rows)):
        out += rows[i].path + " = " + rows[i].text + "\n"
    return out^


def scene_rows_from_text(text: String) raises -> List[SceneField]:
    """Parse rows. An error names its line (1-based)."""
    var rows = List[SceneField]()
    var seen = Dict[String, Int]()
    var lines = text.split("\n")
    for i in range(len(lines)):
        var line = String(lines[i].strip())
        if line.byte_length() == 0 or line.startswith("#"):
            continue
        var eq = line.find("=")
        if eq < 0:
            raise Error("line " + String(i + 1) + ": expected `path = value`, got `" + line + "`")
        var key = String(line[byte=:eq].strip())
        var value = String(line[byte = eq + 1 :].strip())
        if key.byte_length() == 0:
            raise Error("line " + String(i + 1) + ": the row has no path")
        if key in seen:
            raise Error("line " + String(i + 1) + ": duplicate row `" + key + "` (first on line " + String(seen[key]) + ")")
        seen[key] = i + 1
        if key.startswith(SHEET_PREFIX):
            continue  # this format's own rows: see scene_sheet_from_text
        rows.append(SceneField(key, value))
    return rows^


def _whole(t: String) -> Int:
    """A whole number >= 0 made of digits only, or -1."""
    if t.byte_length() == 0 or t.byte_length() > 9:
        return -1
    var n = 0
    for b in t.as_bytes():
        if b < 48 or b > 57:
            return -1
        n = n * 10 + Int(b) - 48
    return n


def scene_sheet_rows(text: String) raises -> List[SceneField]:
    """The scene's `sheet.<n>` rows in the order of n, as (row name, sheet line). An error names its line."""
    var nums = List[Int]()
    var out = List[SceneField]()
    var lines = text.split("\n")
    for i in range(len(lines)):
        var line = String(lines[i].strip())
        if line.byte_length() == 0 or line.startswith("#"):
            continue
        var eq = line.find("=")
        if eq < 0:
            continue  # scene_rows_from_text reports it
        var key = String(line[byte=:eq].strip())
        if not key.startswith(SHEET_PREFIX):
            continue
        var n = _whole(String(key[byte = SHEET_PREFIX.byte_length() :]))
        if n < 1:
            raise Error("line " + String(i + 1) + ": `" + key + "` must be sheet.<n> with n a whole number >= 1")
        var value = String(line[byte = eq + 1 :].strip())
        var at = len(nums)
        while at > 0 and nums[at - 1] > n:
            at -= 1
        nums.insert(at, n)
        out.insert(at, SceneField(key, value))
    return out^


def scene_sheet_from_text(text: String) raises -> String:
    """The event sheet a scene carries, one sheet line per `sheet.<n>` row; empty when it has none."""
    var rows = scene_sheet_rows(text)
    var out = String()
    for i in range(len(rows)):
        out += rows[i].text + "\n"
    return out^


def sheet_to_rows(sheet: String) -> List[SceneField]:
    """Sheet text as scene rows, numbered from 1; blank lines and comments are dropped."""
    var out = List[SceneField]()
    var lines = sheet.split("\n")
    for i in range(len(lines)):
        var line = String(lines[i].strip())
        if line.byte_length() == 0 or line.startswith("#"):
            continue
        out.append(SceneField(SHEET_PREFIX + String(len(out) + 1), line))
    return out^


def sheet_with_handles(sheet: String, handles: List[Int64]) raises -> String:
    """Replace every word `@<i>` by the handle of the scene's i-th body. An error names the sheet line (1-based)."""
    var out = String()
    var lines = sheet.split("\n")
    for i in range(len(lines)):
        var parts = lines[i].split()
        for k in range(len(parts)):
            var w = String(parts[k])
            if w.startswith("@"):
                var idx = _whole(String(w[byte=1:]))
                if idx < 0 or idx >= len(handles):
                    raise Error("line " + String(i + 1) + ": `" + w + "` is not a body of this scene (it has " + String(len(handles)) + ", numbered from 0)")
                w = String(handles[idx])
            if k > 0:
                out += " "
            out += w
        out += "\n"
    return out^
