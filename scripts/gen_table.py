#!/usr/bin/env python3
"""Generate the typed Mojo accessors of a data table from its schema (ludens-engine #119).

    pixi run -e wasm gen-table game/data/demo.schema --table game/data/demo.table -o game/demo_table.mojo
    pixi run -e wasm gen-table game/data/demo.schema --table game/data/demo.table -o game/demo_table.mojo --check

The output has, for a table `demo`: `DemoRow` (one typed field per schema field), `demo_rows(table)` and
`demo_row(table, id)` (they refuse a table whose schema signature differs from the one generated from), the enumeration
words as `comptime DEMO_<FIELD>_<WORD>` indices, and the schema and default table text as constants, so a wasm64 module
needs no file. `--check` exits 1 when the file on disk differs from what would be written (the lint runs it).

The schema grammar is parsed by game/table.mojo; this script reads only what the accessors need (field order, kind,
`of`, `values`, `optional`) and `tests/game_table.mojo` runs the Mojo parser over the same files, so a field this
script reads differently shows up as a signature mismatch there."""
import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KINDS = {"boolean", "integer", "real", "vector", "enumeration", "ref", "asset", "string", "list"}
MOJO_SCALAR = {"boolean": "Bool", "integer": "Int", "real": "Float64", "enumeration": "Int", "ref": "String", "asset": "String", "string": "String"}


def read_rows(text: str, header: str, path: Path) -> list[tuple[int, str, str]]:
    rows = []
    first = True
    for n, raw in enumerate(text.split("\n"), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if first:
            first = False
            if line != header and not line.startswith(header + " "):
                sys.exit(f"{path}:{n}: the first row must be the header `{header}`")
            continue
        if "=" not in line:
            sys.exit(f"{path}:{n}: expected `path = value`, got `{line}`")
        key, value = (s.strip() for s in line.split("=", 1))
        rows.append((n, key, value))
    return rows


def read_schema(path: Path) -> tuple[str, list[dict]]:
    table = None
    fields: dict[str, dict] = {}
    for n, key, value in read_rows(path.read_text(encoding="utf-8"), "ludens-schema 1", path):
        parts = key.split(".")
        if len(parts) < 3 or parts[1] != "schema":
            sys.exit(f"{path}:{n}: {key}: a schema row is `<table>.schema.version` or `<table>.schema.<field>.<attribute>`")
        table = table or parts[0]
        if len(parts) == 4:
            f = fields.setdefault(parts[2], {"name": parts[2], "optional": False, "values": []})
            if parts[3] == "kind":
                if value not in KINDS:
                    sys.exit(f"{path}:{n}: {key}: `{value}` is not a kind")
                f["kind"] = value
            elif parts[3] == "of":
                f["of"] = value
            elif parts[3] == "values":
                f["values"] = value.split()
            elif parts[3] == "optional":
                f["optional"] = value == "true"
    if table is None:
        sys.exit(f"{path}: the schema has no rows")
    out = list(fields.values())
    for f in out:
        if "kind" not in f:
            sys.exit(f"{path}: {table}.schema.{f['name']}: no kind")
        if f["kind"] == "list" and f.get("of") not in KINDS:
            sys.exit(f"{path}: {table}.schema.{f['name']}: a list needs `of`")
    return table, out


def signature(fields: list[dict]) -> str:
    return " ".join(f"{f['name']}:{f['kind']}" + (f":{f['of']}" if f["kind"] == "list" else "") for f in fields)


def camel(name: str) -> str:
    return "".join(p.capitalize() for p in name.split("_"))


def mojo_str(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def elem_type(f: dict) -> str:
    kind = f["of"] if f["kind"] == "list" else f["kind"]
    return "List[Float64]" if kind == "vector" else MOJO_SCALAR[kind]


def field_type(f: dict) -> str:
    if f["kind"] == "vector":
        return "List[Float64]"
    if f["kind"] == "list":
        return f"List[{MOJO_SCALAR[f['of']]}]"
    return MOJO_SCALAR[f["kind"]]


def read_expr(f: dict, v: str) -> str:
    """Mojo expression reading the field from `v`, a `Value`."""
    k = f["kind"]
    if k == "boolean":
        return f"{v}.nums[0] != 0.0"
    if k == "integer":
        return f"Int({v}.nums[0])"
    if k == "real":
        return f"{v}.nums[0]"
    if k == "vector":
        return f"{v}.nums.copy()"
    if k == "enumeration":
        return f"_word_index(t, {f['name'].upper()!r}, {v}.strs[0])".replace("'", '"')
    if k == "list":
        e = f["of"]
        if e == "boolean":
            return f"_bools({v}.nums)"
        if e == "integer":
            return f"_ints({v}.nums)"
        if e == "real":
            return f"{v}.nums.copy()"
        return f"{v}.strs.copy()"
    return f"{v}.strs[0]"


def generate(schema_path: Path, table_path: Path | None) -> str:
    table, fields = read_schema(schema_path)
    name = camel(table)
    up = table.upper()
    rel_schema = schema_path.relative_to(ROOT).as_posix() if schema_path.is_absolute() else schema_path.as_posix()
    out = [
        f'"""Typed accessors of the `{table}` data table. Generated by scripts/gen_table.py from {rel_schema}; do not edit',
        'by hand (`pixi run -e wasm lint` fails when this file is not what the generator writes)."""',
        "from game.table import Table, table_load",
        "",
        f"comptime {up}_SIGNATURE = {mojo_str(signature(fields))}",
        f"comptime {up}_SCHEMA_TEXT = {mojo_str(schema_path.read_text(encoding='utf-8'))}",
    ]
    if table_path is not None:
        out.append(f"comptime {up}_TABLE_TEXT = {mojo_str(table_path.read_text(encoding='utf-8'))}")
    out.append("")
    for f in fields:
        if f["kind"] == "enumeration" or (f["kind"] == "list" and f.get("of") == "enumeration"):
            for i, w in enumerate(f["values"]):
                out.append(f"comptime {up}_{f['name'].upper()}_{w.upper().replace('-', '_')} = {i}")
    out += ["", "", f"struct {name}Row(Copyable, Movable):", "    var id: String"]
    for f in fields:
        out.append(f"    var {f['name']}: {field_type(f)}")
        if f["optional"]:
            out.append(f"    var has_{f['name']}: Bool  # False when the row is `none`")
    out += ["", "    def __init__(out self, id: String):", "        self.id = id"]
    zero = {"Bool": "False", "Int": "0", "Float64": "0.0", "String": "String()"}
    for f in fields:
        ft = field_type(f)
        out.append(f"        self.{f['name']} = " + (ft + "()" if ft.startswith("List") else zero[ft]))
        if f["optional"]:
            out.append(f"        self.has_{f['name']} = False")
    out += ["", ""]
    enum_fields = [f for f in fields if f["kind"] == "enumeration"]
    if enum_fields or any(f["kind"] == "list" and f.get("of") == "enumeration" for f in fields):
        out += [
            "def _word_index(t: Table, field: String, word: String) raises -> Int:",
            "    var f = t.schema.find(field.lower())",
            "    for i in range(len(t.schema.fields[f].values)):",
            "        if t.schema.fields[f].values[i] == word:",
            "            return i",
            "    raise Error(t.file + \": `\" + word + \"` is not a word of \" + field.lower())",
            "", "",
        ]
    if any(f["kind"] == "list" and f.get("of") == "boolean" for f in fields):
        out += ["def _bools(nums: List[Float64]) -> List[Bool]:", "    var out = List[Bool]()", "    for n in nums:", "        out.append(n != 0.0)", "    return out^", "", ""]
    if any(f["kind"] == "list" and f.get("of") == "integer" for f in fields):
        out += ["def _ints(nums: List[Float64]) -> List[Int]:", "    var out = List[Int]()", "    for n in nums:", "        out.append(Int(n))", "    return out^", "", ""]
    out += [
        f"def {table}_rows(t: Table) raises -> List[{name}Row]:",
        '    """Every entry of `t`, in file order. Raises when `t` was not read under the schema this file was generated from."""',
        f"    if t.schema.signature() != {up}_SIGNATURE:",
        f'        raise Error(t.file + ": the schema is `" + t.schema.signature() + "`, the accessors were generated for `" + {up}_SIGNATURE + "`")',
        f"    var out = List[{name}Row]()",
        "    for e in range(len(t.entries)):",
        f"        var r = {name}Row(t.entries[e].id)",
    ]
    for i, f in enumerate(fields):
        v = f"t.entries[e].values[{i}]"
        if f["optional"]:
            out += [f"        r.has_{f['name']} = not {v}.is_none", f"        if r.has_{f['name']}:", f"            r.{f['name']} = {read_expr(f, v)}"]
        else:
            out.append(f"        r.{f['name']} = {read_expr(f, v)}")
    out += ["        out.append(r^)", "    return out^", "", "",
            f"def {table}_row(t: Table, id: String) raises -> {name}Row:",
            f"    var rows = {table}_rows(t)",
            "    for r in rows:",
            "        if r.id == id:",
            "            return r.copy()",
            f'    raise Error(t.file + ": table `{table}` has no entry `" + id + "`")',
            ""]
    if table_path is not None:
        out += ["", f"def {table}_default_table() raises -> Table:",
                '    """The table text this file was generated with, read under the schema it was generated with."""',
                f'    return table_load({up}_SCHEMA_TEXT, "{rel_schema}", {up}_TABLE_TEXT, "{table_path.as_posix()}")', ""]
    return "\n".join(out) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("schema")
    ap.add_argument("--table", help="a table file to embed as the default table")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--check", action="store_true", help="exit 1 if the output file is not what would be written")
    a = ap.parse_args()
    text = generate(Path(a.schema), Path(a.table) if a.table else None)
    out = Path(a.output)
    if a.check:
        if not out.exists() or out.read_text(encoding="utf-8") != text:
            print(f"gen-table: {out} is out of date; run: pixi run -e wasm gen-table {a.schema} -o {a.output}" + (f" --table {a.table}" if a.table else ""), file=sys.stderr)
            return 1
        return 0
    out.write_text(text, encoding="utf-8")
    print(f"gen-table: wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
