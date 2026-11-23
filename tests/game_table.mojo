# tier: integration
"""Data tables with a schema and live tuning (ludens-engine #119). Native only: `pixi run -e wasm test-tables`.

Reads tests/data/{ammo,weapons}.{schema,table}, checks every error names file, line and column, the typed accessors,
tick-boundary edits, export and reload, the tuning panel under a scripted pointer, and that a live edit of the demo game
gives the hash of a run started with the edited table. Prints the parse times of large tables."""
from game.demo_mode import DemoMode
from game.demo_table import DEMO_SCHEMA_TEXT, DEMO_TABLE_TEXT, demo_default_table, demo_row, demo_rows
from game.intent import Intent
from game.table import (
    K_REAL, Table, check_assets, check_refs, join_lines, schema_from_text, table_from_text, table_load, value_text,
)
from game.tuning import Tuner
from game.tuning_panel import TuningPanel
from geometry.vec import Real
from std.time import perf_counter_ns


struct Check:
    var passed: Int
    var failed: Int

    def __init__(out self):
        self.passed = 0
        self.failed = 0

    def ok(mut self, cond: Bool, label: String):
        if cond:
            self.passed += 1
            print("  [PASS]", label)
        else:
            self.failed += 1
            print("  [FAIL]", label)


def read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def load_weapons(table_text: String) raises -> List[String]:
    """The errors of `table_text` read under tests/data/weapons.schema (as `weapons.table`)."""
    var errors = List[String]()
    var sch = schema_from_text(read("tests/data/weapons.schema"), "weapons.schema", errors)
    _ = table_from_text(sch^, table_text, "weapons.table", errors)
    return errors^


def weapons_with(rows: String) raises -> String:
    """A valid table (header, sword with a damage) plus extra rows."""
    return "ludens-table 1 schema 2\nweapons.sword.damage = 12\n" + rows


def has(errors: List[String], want: String) -> Bool:
    for e in errors:
        if e == want:
            return True
    return False


def expect(mut c: Check, rows: String, want: String, label: String) raises:
    var errors = load_weapons(weapons_with(rows))
    var ok = has(errors, want)
    c.ok(ok, label)
    if not ok:
        print("      want:", want)
        print("      got: ", join_lines(errors))


def edited_run(table_text: String, ticks: Int, edit_at: Int, field: String, text: String) raises -> UInt64:
    """Play the demo game with a fixed input for `ticks` frames, queueing `field = text` just before frame `edit_at`
    (-1: never). The game starts from `table_text`."""
    var m = DemoMode.with_table(DEMO_SCHEMA_TEXT, table_text)
    for t in range(ticks):
        if t == edit_at:
            m.set_tuning(field, text)
        m.step(Intent(Real(1), Real(0.3) if t < 90 else Real(0), Real(0), Real(0), t == 20, False, False), 1.0 / 60.0)
    return m.hash()


def main() raises:
    var c = Check()

    # ---- a valid table: typed values, defaults, list order
    var ammo_errors = List[String]()
    var ammo_sch = schema_from_text(read("tests/data/ammo.schema"), "ammo.schema", ammo_errors)
    var ammo = table_from_text(ammo_sch^, read("tests/data/ammo.table"), "ammo.table", ammo_errors)
    var wp_errors = List[String]()
    var wp_sch = schema_from_text(read("tests/data/weapons.schema"), "weapons.schema", wp_errors)
    var wp = table_from_text(wp_sch^, read("tests/data/weapons.table"), "weapons.table", wp_errors)
    c.ok(len(ammo_errors) == 0 and len(wp_errors) == 0, "the fixtures load without errors")
    if len(wp_errors) > 0:
        print(join_lines(wp_errors))
    c.ok(len(wp.entries) == 2 and wp.entries[0].id == "bow", "two entries, in file order")
    c.ok(wp.get_int("sword", "damage") == 12 and wp.get_real("bow", "reach") == 9.0, "integer and real values")
    c.ok(wp.get_real("sword", "reach") == 1.5, "a field with no row has its schema default (reach 1.5)")
    c.ok(not wp.get_bool("sword", "two_handed"), "boolean default false")
    c.ok(wp.get_str("bow", "style") == "ranged" and wp.get_str("sword", "style") == "melee", "enumeration value and default")
    c.ok(wp.get_vec("sword", "tint")[2] == 0.75 and wp.get_vec("bow", "tint")[0] == 1.0, "vector value and default")
    c.ok(wp.get_str("bow", "ammo") == "arrows", "a reference is its entry id")
    c.ok(wp.entries[1].values[wp.schema.find("ammo")].is_none, "an optional field with no row is none")
    c.ok(wp.get_str("sword", "label") == "Short \"blade\"", "a string with an escaped quote")
    var lv = wp.entries[1].values[wp.schema.find("levels")].nums.copy()
    c.ok(len(lv) == 4 and lv[0] == 5 and lv[1] == 10 and lv[2] == 15 and lv[3] == 30, "list elements in numeric index order (1, 2, 2.5, 10), not text order")
    var tables = List[Table]()
    tables.append(wp.copy())
    tables.append(ammo.copy())
    var ref_errors = List[String]()
    check_refs(tables, ref_errors)
    c.ok(len(ref_errors) == 0, "every reference resolves")
    var known = List[String]()
    known.append("@9c1d22aa5e0b7f31")
    var asset_errors = List[String]()
    check_assets(tables, known, asset_errors)
    c.ok(len(asset_errors) == 0, "an asset reference with a known id passes")
    asset_errors = List[String]()
    check_assets(tables, List[String](), asset_errors)
    c.ok(has(asset_errors, "weapons.table:7: weapons.sword.icon: asset `@9c1d22aa5e0b7f31:icon/sword` is not in the asset database"), "an unknown asset id names file, line and column")

    # ---- errors name the file, the line and the column
    expect(c, "weapons.axe.damage = 250\n", "weapons.table:3: weapons.axe.damage: 250 is above the maximum 100", "out of range, above the maximum")
    var dup = load_weapons(weapons_with("weapons.sword.damage = 3\n"))
    c.ok(has(dup, "weapons.table:3: weapons.sword.damage: duplicate row (first on line 2)"), "a duplicate row names both lines")
    expect(c, "weapons.axe.damage = -4\n", "weapons.table:3: weapons.axe.damage: -4 is below the minimum 0", "out of range, below the minimum")
    expect(c, "weapons.axe.damage = heavy\n", "weapons.table:3: weapons.axe.damage: `heavy` is not a whole number", "wrong kind: integer")
    expect(c, "weapons.axe.damage = 1.5\n", "weapons.table:3: weapons.axe.damage: `1.5` is not a whole number", "wrong kind: a real in an integer field")
    expect(c, "weapons.sword.reach = fast\n", "weapons.table:3: weapons.sword.reach: `fast` is not a number", "wrong kind: real")
    expect(c, "weapons.axe.damage = 1\nweapons.axe.two_handed = yes\n", "weapons.table:4: weapons.axe.two_handed: `yes` is not a boolean (true or false)", "wrong kind: boolean")
    expect(c, "weapons.axe.damage = 1\nweapons.axe.style = sling\n", "weapons.table:4: weapons.axe.style: `sling` is not one of: melee ranged magic", "an enumeration word that the schema does not list")
    expect(c, "weapons.axe.damage = 1\nweapons.axe.tint = 1 0\n", "weapons.table:4: weapons.axe.tint: `1 0` has 2 numbers, the field is a vector of 3", "a vector with the wrong number of components")
    expect(c, "weapons.axe.damage = 1\nweapons.axe.tint = 1 0 2\n", "weapons.table:4: weapons.axe.tint: 2 is above the maximum 1", "a vector component out of range")
    expect(c, "weapons.axe.damage = 1\nweapons.axe.icon = @12\n", "weapons.table:4: weapons.axe.icon: `@12` is not an asset reference (`@` and 16 lowercase hex digits, optionally `:name`)", "a malformed asset reference")
    expect(c, "weapons.axe.damage = 1\nweapons.axe.label = open\n", "weapons.table:4: weapons.axe.label: `open` is not a string: it needs double quotes", "an unquoted string")
    expect(c, "weapons.axe.damage = ?\n", "weapons.table:3: weapons.axe.damage: `?` marks a value still to be filled", "a placeholder is an error")
    expect(c, "weapons.axe.damage = 1\nweapons.axe.reach = none\n", "weapons.table:4: weapons.axe.reach: `none` is not allowed: the field is not optional", "none in a field that is not optional")
    expect(c, "weapons.axe = +\n", "weapons.table:3: weapons.axe.damage: required field has no row", "a missing required field names the entry's line and the column")
    expect(c, "weapons.axe.damage = 1\nweapons.axe.speed = 3\n", "weapons.table:4: weapons.axe.speed: the schema weapons.schema has no field `speed`", "a field the schema does not have")
    expect(c, "weapons.axe.damage = 1\nweapons.axe.damage.2 = 3\n", "weapons.table:4: weapons.axe.damage.2: `damage` is integer, not a list: the key ends at the field", "an index on a field that is not a list")
    expect(c, "weapons.axe.damage = 1\nweapons.axe.tags = \"a\"\n", "weapons.table:4: weapons.axe.tags: a list element needs an index: `weapons.axe.tags.<index>`", "a list row without an index")
    expect(c, "weapons.axe.damage = 1\nweapons.axe.levels.1 = 5\nweapons.axe.levels.1.0 = 6\n", "weapons.table:5: weapons.axe.levels.1.0: the same index as `1` (line 4)", "two list indexes with the same value")
    expect(c, "weapons.axe.damage = 1\nweapons.axe.levels.1 = 0\n", "weapons.table:4: weapons.axe.levels.1: 0 is below the minimum 1", "a list element out of range")
    expect(c, "weapons.axe.damage = 1\nweapons.axe.levels.1 = 1\nweapons.axe.levels.2 = 1\nweapons.axe.levels.3 = 1\nweapons.axe.levels.4 = 1\nweapons.axe.levels.5 = 1\n", "weapons.table:3: weapons.axe.levels: 5 elements, the maximum is 4", "a list over its maximum length")
    expect(c, "schema.x.damage = 1\n", "weapons.table:3: schema.x.damage: the key must start with the table name `weapons.`", "a key of another table")
    var bad_ref = List[Table]()
    var t2 = load_weapons(weapons_with("weapons.axe.damage = 1\nweapons.axe.ammo = quivers\n"))
    c.ok(len(t2) == 0, "a dangling reference is valid in one table alone (checked across tables)")
    var e3 = List[String]()
    var s3 = schema_from_text(read("tests/data/weapons.schema"), "weapons.schema", e3)
    bad_ref.append(table_from_text(s3^, weapons_with("weapons.axe.damage = 1\nweapons.axe.ammo = quivers\n"), "weapons.table", e3))
    var s4 = schema_from_text(read("tests/data/ammo.schema"), "ammo.schema", e3)
    bad_ref.append(table_from_text(s4^, read("tests/data/ammo.table"), "ammo.table", e3))
    var dangling = List[String]()
    check_refs(bad_ref, dangling)
    c.ok(has(dangling, "weapons.table:4: weapons.axe.ammo: `quivers` is not an entry of table `ammo` (ammo.table)"), "a dangling reference names file, line, column and the table")
    var only_weapons = List[Table]()
    only_weapons.append(bad_ref[0].copy())
    var not_loaded = List[String]()
    check_refs(only_weapons, not_loaded)
    c.ok(has(not_loaded, "weapons.table:4: weapons.axe.ammo: refers to table `ammo`, which is not loaded"), "a reference to a table that is not loaded")
    var old = load_weapons("ludens-table 1 schema 1\nweapons.sword.damage = 12\n")
    c.ok(has(old, "weapons.table: written for schema version 1, weapons.schema is version 2 (upgrade the table)"), "a table written for an older schema version")
    var nohead = load_weapons("weapons.sword.damage = 12\n")
    c.ok(has(nohead, "weapons.table:1: the first row must be the header `ludens-table 1`, got `weapons.sword.damage = 12`"), "a missing header")
    var many = load_weapons(weapons_with("weapons.a.damage = 900\nweapons.b.damage = x\nweapons.c = +\n"))
    c.ok(len(many) == 3 and not has(many, "weapons.table:3: weapons.a.damage: required field has no row"), "every error is reported, not only the first (" + String(len(many)) + ")")

    # ---- schema errors
    var se = List[String]()
    _ = schema_from_text("ludens-schema 1\nt.schema.version = 1\nt.schema.a.kind = integer\nt.schema.a.min = 5\nt.schema.a.max = 1\nt.schema.a.default = 3\nt.schema.b.kind = list\nt.schema.c.kind = real\nt.schema.d.kind = enumeration\nt.schema.d.default = x\nt.schema.e.kind = integer\nt.schema.e.default = 70\nt.schema.e.max = 60\nt.schema.e.sprite = 1\n", "t.schema", se)
    c.ok(has(se, "t.schema:3: t.schema.a: min 5 is above max 1"), "a schema whose min is above its max")
    c.ok(has(se, "t.schema:7: t.schema.b: a list needs `of` (the element kind)"), "a list without an element kind")
    c.ok(has(se, "t.schema:8: t.schema.c: needs one of `required = true`, a `default` or `optional = true`"), "a field with no default, no required and no optional")
    c.ok(has(se, "t.schema:9: t.schema.d: an enumeration needs `values`"), "an enumeration without words")
    c.ok(has(se, "t.schema:11: t.schema.e: default: 70 is above the maximum 60"), "a default outside its own range")
    c.ok(has(se, "t.schema:14: t.schema.e.sprite: unknown attribute `sprite`"), "an unknown schema attribute")

    # ---- export: unchanged rows stay byte for byte, a changed row is rewritten, a new row goes in key order
    var src = read("tests/data/weapons.table")
    var tn = Tuner(wp.copy(), src)
    c.ok(tn.export_text() == src, "export with no edit writes the file unchanged")
    tn.set("sword", "damage", "20")
    tn.set("sword", "reach", "2.25")
    c.ok(tn.pending() == 2 and tn.table.get_int("sword", "damage") == 12, "an edit is queued; the table is unchanged until a tick boundary")
    var refused = False
    try:
        tn.set("sword", "damage", "250")
    except e:
        refused = String(e) == "weapons.sword.damage: 250 is above the maximum 100"
    c.ok(refused and tn.pending() == 2, "an out-of-range edit is refused with the column named, and queues nothing")
    c.ok(tn.apply() == 2 and tn.pending() == 0 and tn.table.get_int("sword", "damage") == 20, "apply commits the queue in order")
    var out = tn.export_text()
    var want = src.replace("weapons.sword.damage = 12", "weapons.sword.damage = 20").replace("weapons.sword.tags.1 = ", "weapons.sword.reach = 2.25\nweapons.sword.tags.1 = ")
    c.ok(out == want, "export rewrites one row and inserts the new one in key order; the other rows are byte for byte")
    var back = table_load(read("tests/data/weapons.schema"), "weapons.schema", out, "weapons.table")
    c.ok(back.get_int("sword", "damage") == 20 and back.get_real("sword", "reach") == 2.25 and back.get_real("bow", "reach") == 9.0, "the exported file loads and holds the edited values")
    tn.set("sword", "damage", "12")
    _ = tn.apply()
    c.ok(tn.export_text().find("weapons.sword.damage = 12") >= 0, "an edit set back to the loaded value writes the loaded row")
    var again = Tuner(back.copy(), out)
    c.ok(again.export_text() == out, "export of a reloaded table is a fixed point")

    # ---- the panel under a scripted pointer
    var dt = demo_default_table()
    var dsrc = String(DEMO_TABLE_TEXT)
    var dtuner = Tuner(dt.copy(), dsrc)
    var panel = TuningPanel()
    _ = panel.frame(dtuner, 10, 10, 300, 0, 0, False)
    var rows0 = panel.rows
    c.ok(rows0 >= 5 and dtuner.pending() == 0, "the panel draws a control per field (" + String(rows0) + ") and edits nothing by itself")
    # the speed slider is the first control row: its rectangle is the right 40 % of the row
    var sy = Float32(10 + 6 + 22 + 6 + 22 + 11)  # header row, entry label, half a row
    var x_at = Float32(10 + 6 + 288 * 0.6 + 288 * 0.4 * 0.5)  # middle of the slider (the left 60 % of a row is its name)
    _ = panel.frame(dtuner, 10, 10, 300, x_at, sy, False)
    _ = panel.frame(dtuner, 10, 10, 300, x_at, sy, True)  # press
    _ = panel.frame(dtuner, 10, 10, 300, x_at, sy, True)  # drag
    _ = panel.frame(dtuner, 10, 10, 300, x_at, sy, False)  # release
    c.ok(dtuner.pending() == 1, "dragging a slider queues one edit (the drag frames replace each other)")
    _ = dtuner.apply()
    var sp = demo_row(dtuner.table, "main").speed
    c.ok(sp > 10.0 and sp < 10.5, "the speed slider at the middle of 0.5..20 sets about 10.25 (" + String(sp) + ")")
    var export_hit = False
    var bx = Float32(10 + 300 - 6 - 288 * 0.15)
    _ = panel.frame(dtuner, 10, 10, 300, bx, 10 + 6 + 11, False)
    _ = panel.frame(dtuner, 10, 10, 300, bx, 10 + 6 + 11, True)
    export_hit = panel.frame(dtuner, 10, 10, 300, bx, 10 + 6 + 11, False)
    c.ok(export_hit, "the Export button reports a click")
    c.ok(dtuner.export_text().find("demo.main.speed = ") >= 0, "the exported file has the edited row")

    # ---- a live edit equals a run started with the edited table
    var ticks = 240
    var base = edited_run(DEMO_TABLE_TEXT, ticks, -1, "", "")
    var live = edited_run(DEMO_TABLE_TEXT, ticks, 0, "speed", "8")
    var started = edited_run(String(DEMO_TABLE_TEXT).replace("demo.main = +", "demo.main.speed = 8"), ticks, -1, "", "")
    c.ok(live != base, "the edit changes the game (" + String(base) + " -> " + String(live) + ")")
    c.ok(live == started, "edit speed live at tick 0 == a run started with the edited table (hash " + String(live) + ")")
    # export the live edit, reload it, start from it
    var g = DemoMode.with_table(DEMO_SCHEMA_TEXT, DEMO_TABLE_TEXT)
    g.set_tuning("speed", "8")
    g.set_tuning("gravity_y", "-6.5")
    for t in range(ticks):
        g.step(Intent(Real(1), Real(0.3) if t < 90 else Real(0), Real(0), Real(0), t == 20, False, False), 1.0 / 60.0)
    var exported = g.tuner.export_text()
    c.ok(exported.find("demo.main.gravity_y = -6.5") >= 0 and exported.find("demo.main.speed = 8") >= 0, "the game's tuner exports its edited rows")
    var reloaded = edited_run(exported, ticks, -1, "", "")
    c.ok(g.hash() == reloaded, "export, reload and replay gives the hash of the live run (" + String(g.hash()) + ")")
    var mid_a = edited_run(DEMO_TABLE_TEXT, ticks, 100, "speed", "9")
    var mid_b = edited_run(DEMO_TABLE_TEXT, ticks, 100, "speed", "9")
    c.ok(mid_a == mid_b and mid_a != base, "an edit in the middle of a run is deterministic")

    # ---- the demo table without edits is the game as it was: the hash tests/demo_mode.mojo and game-same pin
    c.ok(len(demo_rows(dt)) == 1 and demo_row(dt, "main").speed == 5.0 and demo_row(dt, "main").gravity_y == -9.81, "the demo table's defaults are the constants the game had")

    # ---- parse time
    for n in [1000, 10000, 100000]:
        var text = String("ludens-table 1 schema 1\n")
        for i in range(n):
            text += "ammo.e" + String(i) + ".name = \"Arrow " + String(i) + "\"\nammo.e" + String(i) + ".stack = " + String(1 + i % 99) + "\n"
        var errs = List[String]()
        var sch = schema_from_text(read("tests/data/ammo.schema"), "ammo.schema", errs)
        var t0 = perf_counter_ns()
        var big = table_from_text(sch^, text, "big.table", errs)
        var ms = Float64(perf_counter_ns() - t0) / 1.0e6
        print("  parse", n, "entries,", 2 * n, "rows,", text.byte_length(), "bytes:", ms, "ms,", Int(ms * 1000.0 / Float64(2 * n) * 1000.0), "ns per row")
        c.ok(len(errs) == 0 and len(big.entries) == n, "a table of " + String(n) + " entries parses without errors")

    print("tables:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error(String(c.failed) + " checks failed")
