# Data tables, schemas and live tuning (#119)

Gameplay values live in table files, not in code. A table is a set of entries (weapons, enemies, recipes); each entry
has typed fields. A schema file declares the fields. `ludens check` fails the build on invalid data, naming the file,
the line and the column. This is the data shape ludens-core's rules framework (ROADMAP 17.70: attributes, tags, effects,
abilities, damage) reads.

Code: `game/table.mojo` (parse, validate), `game/tuning.mojo` (live edits, export), `game/tuning_panel.mojo` (the
panel), `scripts/gen_table.py` (typed accessors). Tests: `pixi run -e wasm test-tables`, `pixi run -e wasm tuning-web`.

## The table file

The scene row grammar (`docs/scene-format.md` §4): one `path = value` row per line, `#` comments, blank lines ignored.

```
ludens-table 1 schema 2
weapons.bow.ammo = arrows
weapons.bow.damage = 8
weapons.sword.damage = 12
weapons.sword.levels.1 = 5
weapons.sword.levels.2 = 10
weapons.sword.tint = 0.5 0.5 0.75
```

- The first row is the header: grammar version `1` and the schema version the file was written for. A different
  schema version is an error that says so (`upgrade the table`); there are no automatic upgrades yet (§9 of the scene
  format).
- The key is `<table>.<entry id>.<field>`. An entry id is letters, digits, `_` and `-`; `schema` is reserved.
  `<table>.<entry> = +` declares an entry whose fields are all at their defaults.
- A list field has one row per element: `<table>.<entry>.<field>.<index>`. The index is a number >= 0 and elements are
  ordered by its numeric value (`2` before `10`; `2.5` between `2` and `3`), so an element can be inserted without
  renumbering. Two indexes with the same value are an error.
- The file name is the table name: `weapons.table` holds table `weapons` and sits beside `weapons.schema`.
- Because each value is one row with its whole key, a diff or a merge works on rows exactly as for a scene. The
  key-wise merge driver (`ludens merge`, scene format §5) is #125 and is not in this repository yet; until then git's
  line merge applies, which conflicts when two people insert rows at the same place.

Values use the lexical forms of the scene format (§3a): `true` / `false`, numbers, `"strings"` with `\"`, `\\` and `\n`
as the only escapes, words, `@<16 hex digits>[:name]` for an asset, `none`, and `?` (a value still to be filled, always an
error in a table).

## The schema file

```
ludens-schema 1
weapons.schema.version = 2
weapons.schema.damage.kind = integer
weapons.schema.damage.required = true
weapons.schema.damage.min = 0
weapons.schema.damage.max = 100
weapons.schema.reach.kind = real
weapons.schema.reach.default = 1.5
```

Rows are `<table>.schema.<field>.<attribute> = value`, plus `<table>.schema.version`. Field order is the order in which
a field first appears; accessors and the panel use it.

| kind | value in the table | attributes |
|---|---|---|
| `boolean` | `true`, `false` | |
| `integer` | `-3`, `12` (a real like `1.5` is an error) | `min`, `max` |
| `real` | `2.25` (finite) | `min`, `max` |
| `vector` | `0.5 0.5 0.75` | `size` (2 to 16, required), `min` / `max` for each component |
| `enumeration` | one of the words in `values` | `values` (required) |
| `ref` | an entry id of another table | `ref = <table>` (required) |
| `asset` | `@9c1d22aa5e0b7f31:icon/sword` | |
| `string` | `"Short blade"` | |
| `list` | rows `<field>.<index>` | `of` = boolean, integer, real, enumeration, ref, asset or string; `min` / `max` / `values` / `ref` apply to the elements; `min_count`, `max_count` |

Every non-list field needs exactly one of `required = true` (no row is an error), `default = <value>`, or
`optional = true` (no row means `none`, and `none` is a legal value). A list is empty unless it is `required`. A
non-optional field written as `none` is an error. `doc = "text"` is kept for tools and ignored by the parser. The
schema is checked too: a default outside its own range, a list without `of`, a `min` above a `max`, an unknown
attribute and a field with no kind are errors that name `weapons.schema` and the line.

Changing a default or the meaning of a field means raising `version`; tables written for the old version then fail
with the two version numbers until they are upgraded.

## Validation

`ludens check` validates the scene, then every `*.table` under the project's table directory (`tables = "data"` in
`ludens.toml`, default `data/`). Every problem is reported, not only the first; the exit code is 1 if there is any.

```
data/weapons.table:6: weapons.sword.damage: `many` is not a whole number
data/weapons.table:16: weapons.axe.damage: 250 is above the maximum 100
data/weapons.table:17: weapons.club.damage: required field has no row
data/weapons.table:19: weapons.crossbow.ammo: `quivers` is not an entry of table `ammo` (data/ammo.table)
```

The format is `<file>:<line>: <table>.<entry>.<field>: <message>`. For a missing required field the line is the
entry's first row. For a list element the key includes the index. `tests/game_table.mojo` asserts the exact text of
each error kind, and `tests/test_tables.py` runs the same through `ludens check`.

Assets: `check_assets(tables, known, errors)` reports an `asset` value whose id is not in the list `known`. The asset
database (#12) does not exist yet, so `ludens check` checks only the lexical form of an asset reference.
Entity references (`#id`) are a scene concept; a table refers to another table's entries with `ref`.

## Typed accessors

`scripts/gen_table.py game/data/demo.schema --table game/data/demo.table -o game/demo_table.mojo` writes, for a table
`demo`: the struct `DemoRow` with one typed field per schema field (`Bool`, `Int`, `Float64`, `String`,
`List[Float64]` for a vector, `List[...]` for a list, an `Int` index for an enumeration with `comptime
DEMO_<FIELD>_<WORD>` constants, and `has_<field>` beside an optional field), `demo_rows(table)`, `demo_row(table, id)`,
and the schema and table text as constants so a wasm64 module needs no file. The accessors refuse a table read under a
different schema than the one they were generated from. `pixi run -e wasm lint` fails when the generated file is not
what the generator writes. `game/demo_mode.mojo` reads `speed`, `jump_speed`, `jump_enabled`, `gravity_y` and
`look_sensitivity` through `DemoRow`. The game reads the table text baked into the generated `game/demo_table.mojo`, not
`game/data/demo.table` at run time (a wasm64 module has no file access). A table exported from the panel or edited with
`ludens tune` therefore has no effect on the game until `pixi run -e wasm gen-table game/data/demo.schema --table
game/data/demo.table -o game/demo_table.mojo` regenerates that file; `pixi run -e wasm lint` and `test-tables` fail
while the two disagree; with the default table the game's hash is unchanged (`test-game`).

## Live tuning

`Tuner` (`game/tuning.mojo`) wraps a loaded table:

- `set(entry, field, text)` checks one edit against the schema (kind, range, enumeration word, `none`) and queues it.
  It does not touch the table. A later edit of the same cell replaces the queued one (a slider drag is many edits).
- `apply()` commits the queue in order. The game calls it before each tick, so a value changes between ticks, never in
  one.
- `export_text()` returns the table file with only the changed rows rewritten, or inserted before the first row with a
  greater key. Every other byte, comments included, is copied. An edit set back to the loaded value writes nothing.

`TuningPanel` (`game/tuning_panel.mojo`) draws the panel with `ui/` widgets from the schema: a slider for an integer or
real with both `min` and `max`, a checkbox for a boolean, a button per word for an enumeration, a slider per vector
component; other fields are shown as text. The Export button makes `frame` return True.

- **Web**: F2 opens the panel over the game (`GameMode.overlay`, `app/main.mojo`). Export downloads `demo.table` through
  `app_take_export` and a link click in `shell/web/app.ts`. The shell now sends the pointer in canvas pixels (the page may
  show the 960 x 540 canvas smaller); before, it sent CSS pixels. Test: `pixi run -e wasm tuning-web`.
- **Command line** (the editor has no panel window yet, #10): `ludens tune data/weapons.table sword.damage 14` runs the
  same `Tuner.set`, `apply`, `export_text` and rewrites the file.

## Measurements

Parse time, native build, `pixi run -e wasm test-tables` (a table of N entries with 2 rows each, schema `ammo`). Two
runs on a shared machine, so the range is the spread between them:

| entries | rows | bytes | parse ms | ns per row |
|---:|---:|---:|---:|---:|
| 1 000 | 2 000 | 49 595 | 1.7 to 2.6 | 840 to 1 300 |
| 10 000 | 20 000 | 525 784 | 17.6 to 21.5 | 880 to 1 070 |
| 100 000 | 200 000 | 5 557 595 | 199 to 239 | 1 000 to 1 200 |

The time per row stays within 30 % across a 100-fold size range inside one run. Not measured: the wasm64 build, and
tables with list or vector fields.

## Not done here

- A merge driver for table files (#125); git's line merge applies.
- Upgrade functions between schema versions; a version mismatch is an error.
- Undo for table edits: `ludens tune` and the panel are not commands in `editor/command` (rule 2 in the README) because
  the editor's command layer edits a world, not a table; this waits for the editor panels (#10).
- Editing list elements in the panel (they are rows in the file).
- Checking asset references against the asset database (#12).
