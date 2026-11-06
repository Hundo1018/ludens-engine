"""The flat text form of a scene (ludens-shell #9, slice 1): one `path = value` row per line.

`#` starts a comment, blank lines are ignored, and a path appears once. The rows are the engine's
(`scene_to_fields`), so a new scene property is a new row and this module does not change. Prefabs, nested scenes
and asset references are layered on top of these rows by the format work that follows in #9."""
from embed.scene_io import SceneField

comptime SCENE_HEADER = "# ludens scene: one `path = value` row per line\n"


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
        rows.append(SceneField(key, value))
    return rows^
