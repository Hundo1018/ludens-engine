"""Architecture index + gate for ludens-engine (ROADMAP 17.0a; docs/ARCHITECTURE.md
S4-S5; spec: .campaign/archindex_spec.md).

Builds an index of every declaration (from `mojo doc`'s own JSON dump, so
struct/trait/function/alias/raises facts have zero textual false positives)
and every import statement (parsed from source text: `import X` / `from X
import a, b as c` including multi-line parenthesised forms and relative
imports, skipping triple-quoted docstrings) across the engine packages listed
in scripts/arch_layers.toml plus tests/benchmarks/examples/experiments/tools.

`check` reads ONLY scripts/arch_layers.toml for the layer table: a package
listed there that has no directory on disk yet (`diag`, `gameplay`) is not an
error; a directory that exists on disk but is missing from the table is.

Commands (see `pixi run arch -- <cmd>`):
  build                 regenerate build/archindex.json
  def NAME [--prefix]   every declaration named NAME (or name-prefixed)
  impl TRAIT            every struct whose parentTraits contain TRAIT
  uses TARGET           importers of a module (pkg.mod) or a symbol (Name)
  deps MODULE [--all]   packages a package imports (direct, or --all transitive)
  raises PKG            functions/methods with raises=true in PKG
  summary [PKG]         per-package layer/modules/LOC/structs/traits/fan-in/out
  check                 layers + cycles + reach-through + missing-package gate
  tiers [--check]       tests/test_*.mojo tier headers vs. computed span
  bench                 grep vs. index, measured (see docs/ARCHITECTURE.md S5)
  selftest              fixture-tree self-test of the `check` rules
"""

from std.python import Python, PythonObject
from std.os.path import isdir, isfile, join
from std.os import listdir, mkdir
from std.sys import argv, exit

comptime VALID_TEST_TIERS = ("unit", "component", "integration", "system", "stress")
comptime EXTRA_CONSUMER_DIR = "tools"
comptime INDEX_PATH = "build/archindex.json"
comptime ARCHDOC_DIR = "build/archdoc"
comptime LAYERS_TOML = "scripts/arch_layers.toml"

# --------------------------------------------------------------------------
# Small string helpers (no regex in stdlib; hand-rolled word-boundary match)
# --------------------------------------------------------------------------

def is_ident_char(c: String) -> Bool:
    if c.byte_length() == 0:
        return False
    return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (
        c >= "0" and c <= "9"
    ) or c == "_"


def join_dotted(parts: List[String], start: Int) -> String:
    var out = String("")
    var first = True
    for i in range(start, len(parts)):
        if not first:
            out += "."
        out += parts[i]
        first = False
    return out


def csv_contains(csv: String, item: String) -> Bool:
    if csv.byte_length() == 0:
        return False
    var parts = csv.split(",")
    for p in parts:
        if String(p.strip()) == item:
            return True
    return False


def read_text(path: String) raises -> String:
    var f = open(path, "r")
    var content = f.read()
    f.close()
    return content


def read_lines(path: String) raises -> List[String]:
    var content = read_text(path)
    var raw = content.splitlines()
    var out = List[String]()
    for r in raw:
        out.append(String(r))
    return out^


def list_mojo_files(dirpath: String) raises -> List[String]:
    """Non-recursive: sorted `.mojo` file names directly inside dirpath."""
    var out = List[String]()
    if not isdir(dirpath):
        return out^
    var entries = listdir(dirpath)
    var names = List[String]()
    for e in entries:
        names.append(String(e))
    sort(names)
    for n in names:
        if n.endswith(".mojo"):
            out.append(n)
    return out^


def line_of(lines: List[String], keyword: String, name: String, start: Int) -> Int:
    """1-based line number of the first line at index >= start whose stripped
    text is `keyword name` followed by a non-identifier char (or nothing).
    Returns -1 if not found. This is the exact algorithm the spec's source
    (3) describes: search is confined to one already-known file, so it can
    never produce a cross-file false positive."""
    var prefix = keyword + " " + name
    var prefix_len = prefix.byte_length()
    for i in range(start, len(lines)):
        var s = String(lines[i].strip())
        if s.startswith(prefix):
            if s.byte_length() == prefix_len:
                return i + 1
            var c = String(s[byte=prefix_len : prefix_len + 1])
            if not is_ident_char(c):
                return i + 1
    return -1

# --------------------------------------------------------------------------
# Records
# --------------------------------------------------------------------------


@fieldwise_init
struct Decl(Writable, Copyable, Movable):
    var path: String
    var line: Int
    var kind: String  # struct | trait | function | method | alias
    var name: String
    var signature: String
    var package: String
    var module: String
    var parent: String  # owning struct name, or "" for module-level decls
    var raises: Bool
    var traits_csv: String  # struct kind only: comma-joined parentTraits

    def write_to(self, mut writer: Some[Writer]):
        var suffix = String(" raises") if self.raises else String("")
        writer.write(
            self.path, ":", self.line, "  ", self.kind, "  ", self.signature, suffix
        )


@fieldwise_init
struct ImportRow(Copyable, Movable):
    var path: String  # importer file, repo-relative
    var line: Int  # the PHYSICAL line this name was written on (grep-comparable)
    var stmt_line: Int  # the import STATEMENT's opening line (for module/package-level use)
    var package: String  # importer package (dir name)
    var module: String  # importer module (file name w/o .mojo)
    var target_pkg: String
    var target_mod: String  # "" for a bare package import
    var target_name: String  # "" for a whole-module import (no symbol)
    var is_relative: Bool


@fieldwise_init
struct Loc(Copyable, Movable):
    var path: String
    var line: Int


def sort_locs(mut locs: List[Loc]):
    for i in range(1, len(locs)):
        var j = i
        while j > 0 and (
            locs[j - 1].path > locs[j].path
            or (locs[j - 1].path == locs[j].path and locs[j - 1].line > locs[j].line)
        ):
            var tmp = locs[j - 1].copy()
            locs[j - 1] = locs[j].copy()
            locs[j] = tmp^
            j -= 1


@fieldwise_init
struct LayerTable(Movable):
    var layers: Dict[String, Int]
    var layer_order: List[String]  # TOML declaration order
    var infra_packages: List[String]
    var consumers: List[String]
    var allow_private: List[String]  # "path:target_pkg.target_mod.name" keys


def load_layer_table(path: String) raises -> LayerTable:
    var tomllib = Python.import_module("tomllib")
    var builtins = Python.import_module("builtins")
    var f = builtins.open(path, "rb")
    var data = tomllib.load(f)
    f.close()

    var layers = Dict[String, Int]()
    var order = List[String]()
    var layers_obj = data["layers"]
    for key in layers_obj:
        var k = String(py=key)
        var v = Int(py=layers_obj[key])
        layers[k] = v
        order.append(k)

    var infra = List[String]()
    var consumers = List[String]()
    if "infrastructure" in data:
        var infra_obj = data["infrastructure"]
        if "packages" in infra_obj:
            for p in infra_obj["packages"]:
                infra.append(String(py=p))
        if "consumers" in infra_obj:
            for c in infra_obj["consumers"]:
                consumers.append(String(py=c))

    var allow = List[String]()
    if "allow_private" in data:
        var ap = data["allow_private"]
        for key in ap:
            allow.append(String(py=key))

    return LayerTable(layers^, order^, infra^, consumers^, allow^)


def contains(items: List[String], item: String) -> Bool:
    for i in items:
        if i == item:
            return True
    return False


# --------------------------------------------------------------------------
# Import-statement parsing (source 2): only `import`/`from ... import`
# STATEMENTS, triple-quoted docstrings and `#` comments are never parsed.
# --------------------------------------------------------------------------


def emit_names(
    text: String,
    lineno: Int,
    stmt_line: Int,
    path: String,
    package: String,
    module_: String,
    target_pkg: String,
    target_mod: String,
    is_rel: Bool,
    mut out: List[ImportRow],
):
    """Splits a (possibly single-line-fragment) comma list of imported names
    and emits one ImportRow per name, each carrying the PHYSICAL line it was
    written on (not the statement's opening line) — this matters for
    multi-line parenthesised imports, where `git grep -n NAME` finds the
    name's own line, not the `from X import (` line above it. `stmt_line`
    (always the statement's first line) is kept alongside for module/package
    -level lookups, where the whole statement — not one name — is the unit."""
    if text.byte_length() == 0:
        return
    for it in text.split(","):
        var item = String(it.strip())
        if item.byte_length() == 0:
            continue
        var nm = item
        var as_idx = item.find(" as ")
        if as_idx >= 0:
            nm = String(item[byte=0:as_idx].strip())
        out.append(
            ImportRow(path, lineno, stmt_line, package, module_, target_pkg, target_mod, nm, is_rel)
        )


def strip_parens(text: String) -> String:
    var t = text
    if t.startswith("("):
        var t1 = String(t[byte=1 : t.byte_length()])
        t = t1
    if t.endswith(")"):
        var t2 = String(t[byte=0 : t.byte_length() - 1])
        t = t2
    return t


def parse_stmt_lines(
    stmt_lines: List[String],
    line_numbers: List[Int],
    path: String,
    package: String,
    module_: String,
    mut out: List[ImportRow],
):
    var first = String(stmt_lines[0].strip())
    if first.startswith("from "):
        var rest = String(first[byte=5 : first.byte_length()])
        var imp_idx = rest.find(" import ")
        if imp_idx < 0:
            return
        var modpart = String(rest[byte=0:imp_idx].strip())
        var is_rel = modpart.startswith(".")
        var target_pkg: String
        var target_mod: String
        if is_rel:
            var mm = modpart
            while mm.startswith("."):
                var mm2 = String(mm[byte=1 : mm.byte_length()])
                mm = mm2
            target_pkg = package
            target_mod = mm
        else:
            var parts = List[String]()
            for p in modpart.split("."):
                parts.append(String(p))
            target_pkg = parts[0]
            target_mod = join_dotted(parts, 1)

        var first_names = strip_parens(String(rest[byte = imp_idx + 8 : rest.byte_length()].strip()))
        var stmt_line = line_numbers[0]
        emit_names(first_names, line_numbers[0], stmt_line, path, package, module_, target_pkg, target_mod, is_rel, out)
        for li in range(1, len(stmt_lines)):
            var lt = strip_parens(String(stmt_lines[li].strip()))
            emit_names(lt, line_numbers[li], stmt_line, path, package, module_, target_pkg, target_mod, is_rel, out)
    elif first.startswith("import "):
        var rest2 = String(first[byte=7 : first.byte_length()])
        for it in rest2.split(","):
            var item = String(it.strip())
            if item.byte_length() == 0:
                continue
            var mod_expr = item
            var as_idx = item.find(" as ")
            if as_idx >= 0:
                mod_expr = String(item[byte=0:as_idx].strip())
            var parts2 = List[String]()
            for p in mod_expr.split("."):
                parts2.append(String(p))
            var tp = parts2[0]
            var tm = join_dotted(parts2, 1)
            out.append(
                ImportRow(path, line_numbers[0], line_numbers[0], package, module_, tp, tm, String(""), False)
            )


def parse_imports_in_file(
    path: String, package: String, module_: String, lines: List[String]
) raises -> List[ImportRow]:
    var out = List[ImportRow]()
    var in_doc = False
    var i = 0
    var n = len(lines)
    while i < n:
        var raw = lines[i]
        var triple_count = raw.count('"""')
        if triple_count > 0 or in_doc:
            if triple_count % 2 == 1:
                in_doc = not in_doc
            i += 1
            continue
        var stripped = String(raw.strip())
        if stripped.byte_length() == 0 or stripped.startswith("#"):
            i += 1
            continue
        if stripped.startswith("from ") or stripped.startswith("import "):
            var stmt_lines = List[String]()
            var line_numbers = List[Int]()
            stmt_lines.append(stripped)
            line_numbers.append(i + 1)
            var depth = stripped.count("(") - stripped.count(")")
            var j = i
            while depth > 0 and j + 1 < n:
                j += 1
                var nxt = String(lines[j].strip())
                stmt_lines.append(nxt)
                line_numbers.append(j + 1)
                depth += nxt.count("(") - nxt.count(")")
            parse_stmt_lines(stmt_lines, line_numbers, path, package, module_, out)
            i = j + 1
        else:
            i += 1
    return out^


# --------------------------------------------------------------------------
# Declaration extraction (source 1): `mojo doc`'s own JSON dump.
# --------------------------------------------------------------------------


def run_mojo_doc(pkg: String) raises -> PythonObject:
    if not isdir(ARCHDOC_DIR):
        mkdir(ARCHDOC_DIR)
    var out_path = ARCHDOC_DIR + "/" + pkg + ".json"
    var subprocess = Python.import_module("subprocess")
    var res = subprocess.run(
        Python.list("mojo", "doc", "-I", "build", pkg, "-o", out_path),
        capture_output=True,
        text=True,
    )
    if Int(py=res.returncode) != 0:
        raise Error("mojo doc failed for " + pkg + ": " + String(py=res.stderr))
    var json = Python.import_module("json")
    var builtins = Python.import_module("builtins")
    var f = builtins.open(out_path, "r")
    var obj = json.load(f)
    f.close()
    return obj


def extract_decls(pkg: String, doc_obj: PythonObject, mut decls: List[Decl]) raises:
    var modules = doc_obj["decl"]["modules"]
    for m in modules:
        var mod_name = String(py=m["name"])
        if mod_name == "__init__":
            continue
        var relpath = pkg + "/" + mod_name + ".mojo"
        if not isfile(relpath):
            continue
        var lines = read_lines(relpath)

        for s in m["structs"]:
            var sname = String(py=s["name"])
            var sig = String(py=s["signature"])
            var traits_csv = String("")
            var first = True
            for pt in s["parentTraits"]:
                var tn = String(py=pt["name"])
                if not first:
                    traits_csv += ","
                traits_csv += tn
                first = False
            var sline = line_of(lines, "struct", sname, 0)
            decls.append(
                Decl(relpath, sline, "struct", sname, sig, pkg, mod_name, String(""), False, traits_csv)
            )
            var method_start = sline if sline > 0 else 0
            for func in s["functions"]:
                var fname = String(py=func["name"])
                var mline = line_of(lines, "def", fname, method_start)
                for ov in func["overloads"]:
                    var osig = String(py=ov["signature"])
                    var oraises = Bool(py=ov["raises"])
                    decls.append(
                        Decl(relpath, mline, "method", fname, osig, pkg, mod_name, sname, oraises, String(""))
                    )
            for al in s["aliases"]:
                var an = String(py=al["name"])
                var asig = String(py=al["signature"])
                var aline = line_of(lines, "comptime", an, method_start)
                decls.append(
                    Decl(relpath, aline, "alias", an, asig, pkg, mod_name, sname, False, String(""))
                )

        for func in m["functions"]:
            var fname = String(py=func["name"])
            var fline = line_of(lines, "def", fname, 0)
            for ov in func["overloads"]:
                var osig = String(py=ov["signature"])
                var oraises = Bool(py=ov["raises"])
                decls.append(
                    Decl(relpath, fline, "function", fname, osig, pkg, mod_name, String(""), oraises, String(""))
                )

        for tr in m["traits"]:
            var trname = String(py=tr["name"])
            var tline = line_of(lines, "trait", trname, 0)
            var tsig = "trait " + trname
            decls.append(
                Decl(relpath, tline, "trait", trname, tsig, pkg, mod_name, String(""), False, String(""))
            )

        for al in m["aliases"]:
            var an = String(py=al["name"])
            var asig = String(py=al["signature"])
            var aline = line_of(lines, "comptime", an, 0)
            decls.append(
                Decl(relpath, aline, "alias", an, asig, pkg, mod_name, String(""), False, String(""))
            )


# --------------------------------------------------------------------------
# Directory classification
# --------------------------------------------------------------------------


@fieldwise_init
struct Dirs(Movable):
    var layered: List[String]  # engine packages from [layers], on disk, in TOML order
    var infra: List[String]  # [infrastructure].packages, on disk (harness)
    var consumers: List[String]  # [infrastructure].consumers + "tools", on disk


def classify_dirs(lt: LayerTable) raises -> Dirs:
    var layered = List[String]()
    for k in lt.layer_order:
        if isdir(k):
            layered.append(k)
    var infra = List[String]()
    for k in lt.infra_packages:
        if isdir(k):
            infra.append(k)
    var consumers = List[String]()
    for k in lt.consumers:
        if isdir(k):
            consumers.append(k)
    if isdir(EXTRA_CONSUMER_DIR) and not contains(consumers, EXTRA_CONSUMER_DIR):
        consumers.append(EXTRA_CONSUMER_DIR)
    return Dirs(layered^, infra^, consumers^)


# --------------------------------------------------------------------------
# Index build / persist / load
# --------------------------------------------------------------------------


def build_index(
    lt: LayerTable, dirs: Dirs, mut decls: List[Decl], mut imports: List[ImportRow]
) raises:
    var doc_dirs = List[String]()
    for d in dirs.infra:
        doc_dirs.append(d)
    for d in dirs.layered:
        doc_dirs.append(d)
    for pkg in doc_dirs:
        var doc_obj = run_mojo_doc(pkg)
        extract_decls(pkg, doc_obj, decls)

    scan_imports_only(dirs, imports)


def json_escape(s: String) -> String:
    var out = String("")
    for ch in s.codepoint_slices():
        var c = String(ch)
        if c == '"':
            out += '\\"'
        elif c == "\\":
            out += "\\\\"
        elif c == "\n":
            out += "\\n"
        else:
            out += c
    return out


def save_index(path: String, decls: List[Decl], imports: List[ImportRow]) raises:
    var out = String('{\n  "decls": [\n')
    for i in range(len(decls)):
        var d = decls[i].copy()
        out += '    {"path": "' + json_escape(d.path) + '", "line": ' + String(d.line)
        out += ', "kind": "' + json_escape(d.kind) + '", "name": "' + json_escape(d.name) + '"'
        out += ', "signature": "' + json_escape(d.signature) + '", "package": "' + json_escape(d.package) + '"'
        out += ', "module": "' + json_escape(d.module) + '", "parent": "' + json_escape(d.parent) + '"'
        out += ', "raises": ' + (String("true") if d.raises else String("false"))
        out += ', "traits_csv": "' + json_escape(d.traits_csv) + '"}'
        out += "," if i + 1 < len(decls) else ""
        out += "\n"
    out += '  ],\n  "imports": [\n'
    for i in range(len(imports)):
        var r = imports[i].copy()
        out += '    {"path": "' + json_escape(r.path) + '", "line": ' + String(r.line)
        out += ', "stmt_line": ' + String(r.stmt_line)
        out += ', "package": "' + json_escape(r.package) + '", "module": "' + json_escape(r.module) + '"'
        out += ', "target_pkg": "' + json_escape(r.target_pkg) + '", "target_mod": "' + json_escape(r.target_mod) + '"'
        out += ', "target_name": "' + json_escape(r.target_name) + '"'
        out += ', "is_relative": ' + (String("true") if r.is_relative else String("false")) + "}"
        out += "," if i + 1 < len(imports) else ""
        out += "\n"
    out += "  ]\n}\n"
    var f = open(path, "w")
    f.write(out)
    f.close()


def load_index(path: String, mut decls: List[Decl], mut imports: List[ImportRow]) raises:
    var text = read_text(path)
    var json = Python.import_module("json")
    var obj = json.loads(text)
    for d in obj["decls"]:
        decls.append(
            Decl(
                String(py=d["path"]),
                Int(py=d["line"]),
                String(py=d["kind"]),
                String(py=d["name"]),
                String(py=d["signature"]),
                String(py=d["package"]),
                String(py=d["module"]),
                String(py=d["parent"]),
                Bool(py=d["raises"]),
                String(py=d["traits_csv"]),
            )
        )
    for r in obj["imports"]:
        imports.append(
            ImportRow(
                String(py=r["path"]),
                Int(py=r["line"]),
                Int(py=r["stmt_line"]),
                String(py=r["package"]),
                String(py=r["module"]),
                String(py=r["target_pkg"]),
                String(py=r["target_mod"]),
                String(py=r["target_name"]),
                Bool(py=r["is_relative"]),
            )
        )


def newest_mtime(dirs: Dirs, extra_files: List[String]) raises -> Float64:
    var os = Python.import_module("os")
    var newest = Float64(0)
    for f in extra_files:
        if isfile(f):
            var t = Float64(py=os.path.getmtime(f))
            if t > newest:
                newest = t
    var all_dirs = List[String]()
    for d in dirs.layered:
        all_dirs.append(d)
    for d in dirs.infra:
        all_dirs.append(d)
    for d in dirs.consumers:
        all_dirs.append(d)
    for pkg in all_dirs:
        for fname in list_mojo_files(pkg):
            var t2 = Float64(py=os.path.getmtime(pkg + "/" + fname))
            if t2 > newest:
                newest = t2
    return newest


def ensure_index(
    force: Bool, lt: LayerTable, mut decls: List[Decl], mut imports: List[ImportRow]
) raises -> Dirs:
    var dirs = classify_dirs(lt)
    var extra = List[String]()
    extra.append(LAYERS_TOML)
    var stale = force or not isfile(INDEX_PATH)
    if not stale:
        var os = Python.import_module("os")
        var idx_mtime = Float64(py=os.path.getmtime(INDEX_PATH))
        var newest = newest_mtime(dirs, extra)
        stale = newest > idx_mtime
    if stale:
        build_index(lt, dirs, decls, imports)
        save_index(INDEX_PATH, decls, imports)
    else:
        load_index(INDEX_PATH, decls, imports)
    return dirs^


def join_sep(parts: List[String], sep: String) -> String:
    var out = String("")
    var first = True
    for p in parts:
        if not first:
            out += sep
        out += p
        first = False
    return out


def sort_decls(mut items: List[Decl]):
    for i in range(1, len(items)):
        var j = i
        while j > 0 and (
            items[j - 1].path > items[j].path
            or (items[j - 1].path == items[j].path and items[j - 1].line > items[j].line)
        ):
            var tmp = items[j - 1].copy()
            items[j - 1] = items[j].copy()
            items[j] = tmp^
            j -= 1




# --------------------------------------------------------------------------
# check: layers (a), infra (b), cycles (c), reach-through (d), missing (e)
# --------------------------------------------------------------------------


@fieldwise_init
struct Violation(Copyable, Movable, Writable):
    var rule: String
    var message: String

    def write_to(self, mut writer: Some[Writer]):
        writer.write("[", self.rule, "] ", self.message)


def collect_precompiled_modules(
    dirs: Dirs, mut node_names: List[String], mut node_id: Dict[String, Int]
) raises:
    var pkgs = List[String]()
    for d in dirs.layered:
        pkgs.append(d)
    for d in dirs.infra:
        pkgs.append(d)
    for pkg in pkgs:
        for fname in list_mojo_files(pkg):
            var mod = String(fname.removesuffix(".mojo"))
            var key = pkg + "/" + mod
            node_id[key] = len(node_names)
            node_names.append(key)


def build_adjacency(
    node_id: Dict[String, Int], n: Int, imports: List[ImportRow]
) raises -> List[List[Int]]:
    var adj = List[List[Int]]()
    for _ in range(n):
        var e = List[Int]()
        adj.append(e^)
    for r in imports:
        var src_key = r.package + "/" + r.module
        if src_key not in node_id:
            continue
        if r.target_mod.byte_length() == 0:
            continue
        var dst_key = r.target_pkg + "/" + r.target_mod
        if dst_key not in node_id:
            continue
        var si = node_id[src_key]
        var di = node_id[dst_key]
        if si == di:
            continue
        adj[si].append(di)
    return adj^


def tarjan_scc(n: Int, adj: List[List[Int]]) -> List[List[Int]]:
    """Iterative Tarjan SCC (no recursion, so no stack-depth limit)."""
    var index = List[Int]()
    var low = List[Int]()
    var onstack = List[Bool]()
    for _ in range(n):
        index.append(-1)
        low.append(0)
        onstack.append(False)
    var stack = List[Int]()
    var sccs = List[List[Int]]()
    var counter = 0

    for start in range(n):
        if index[start] != -1:
            continue
        var call_node = List[Int]()
        var call_iter = List[Int]()
        call_node.append(start)
        call_iter.append(0)
        index[start] = counter
        low[start] = counter
        counter += 1
        stack.append(start)
        onstack[start] = True

        while len(call_node) > 0:
            var v = call_node[len(call_node) - 1]
            var it = call_iter[len(call_iter) - 1]
            if it < len(adj[v]):
                call_iter[len(call_iter) - 1] = it + 1
                var w = adj[v][it]
                if index[w] == -1:
                    index[w] = counter
                    low[w] = counter
                    counter += 1
                    stack.append(w)
                    onstack[w] = True
                    call_node.append(w)
                    call_iter.append(0)
                else:
                    if onstack[w] and index[w] < low[v]:
                        low[v] = index[w]
            else:
                _ = call_node.pop()
                _ = call_iter.pop()
                if len(call_node) > 0:
                    var parent = call_node[len(call_node) - 1]
                    if low[v] < low[parent]:
                        low[parent] = low[v]
                if low[v] == index[v]:
                    var comp = List[Int]()
                    while True:
                        var w2 = stack.pop()
                        onstack[w2] = False
                        comp.append(w2)
                        if w2 == v:
                            break
                    sccs.append(comp^)
    return sccs^


def scan_imports_only(dirs: Dirs, mut imports: List[ImportRow]) raises:
    var scan_dirs = List[String]()
    for d in dirs.layered:
        scan_dirs.append(d)
    for d in dirs.infra:
        scan_dirs.append(d)
    for d in dirs.consumers:
        scan_dirs.append(d)
    for pkg in scan_dirs:
        for fname in list_mojo_files(pkg):
            var relpath = pkg + "/" + fname
            var mod_name = String(fname.removesuffix(".mojo"))
            var lines = read_lines(relpath)
            var rows = parse_imports_in_file(relpath, pkg, mod_name, lines)
            for r in rows:
                imports.append(r.copy())


def run_check(lt: LayerTable, dirs: Dirs, imports: List[ImportRow]) raises -> List[Violation]:
    var violations = List[Violation]()

    var layered_set = List[String]()
    for d in dirs.layered:
        layered_set.append(d)
    var infra_set = List[String]()
    for d in dirs.infra:
        infra_set.append(d)

    # (a) layer order, (b) infra reach — deduped per (statement, target_pkg):
    # a multi-name / multi-line import of the same bad target must be reported
    # once, not once per imported name.
    var seen_ab = List[String]()
    for r in imports:
        if not contains(layered_set, r.package):
            continue
        if r.target_pkg == r.package:
            continue
        var dedup_key = r.path + "|" + String(r.stmt_line) + "|" + r.target_pkg
        if contains(seen_ab, dedup_key):
            continue
        if contains(infra_set, r.target_pkg):
            seen_ab.append(dedup_key)
            violations.append(
                Violation(
                    "infra",
                    r.path + ":" + String(r.stmt_line) + "  engine package `" + r.package
                    + "` imports infrastructure package `" + r.target_pkg + "` (harness is test/bench-only)",
                )
            )
            continue
        if r.target_pkg in lt.layers:
            var il = lt.layers[r.package]
            var tl = lt.layers[r.target_pkg]
            if tl >= il:
                seen_ab.append(dedup_key)
                violations.append(
                    Violation(
                        "layer",
                        r.path + ":" + String(r.stmt_line) + "  `" + r.package + "` (layer "
                        + String(il) + ") imports `" + r.target_pkg + "` (layer " + String(tl)
                        + "), not strictly lower",
                    )
                )

    # (d) reach-through: cross-package import of a `_`-prefixed name from a
    # LAYERED importer (tests/benchmarks/examples/experiments/tools/harness
    # "sit above everything and may import anything", per ARCHITECTURE.md S1).
    for r in imports:
        if not contains(layered_set, r.package):
            continue
        if r.target_name.byte_length() == 0 or not r.target_name.startswith("_"):
            continue
        if r.target_pkg == r.package:
            continue
        var key = r.path + ":" + r.target_pkg + "." + r.target_mod + "." + r.target_name
        if contains(lt.allow_private, key):
            continue
        violations.append(
            Violation(
                "reach-through",
                r.path + ":" + String(r.line) + "  imports private `" + r.target_pkg + "."
                + r.target_mod + "." + r.target_name + "` (add to [allow_private] in "
                + LAYERS_TOML + " with a reason, or make it public)",
            )
        )

    # (c) module-level cycles, over the precompiled set (layered + infra).
    var node_names = List[String]()
    var node_id = Dict[String, Int]()
    collect_precompiled_modules(dirs, node_names, node_id)
    var adj = build_adjacency(node_id, len(node_names), imports)
    var sccs = tarjan_scc(len(node_names), adj)
    for comp in sccs:
        if len(comp) > 1:
            var msg = String("cycle: ")
            var first = True
            for idx in comp:
                if not first:
                    msg += " -> "
                msg += node_names[idx]
                first = False
            violations.append(Violation("cycle", msg))

    # (e) on-disk package dir (with .mojo files) missing from [layers].
    var skip = List[String]()
    for d in dirs.infra:
        skip.append(d)
    for d in dirs.consumers:
        skip.append(d)
    for entry in listdir("."):
        var name = String(entry)
        if name.startswith("."):
            continue
        if name == "build" or name == "docs" or name == "scripts":
            continue
        if contains(skip, name):
            continue
        if not isdir(name):
            continue
        if len(list_mojo_files(name)) == 0:
            continue
        if name in lt.layers:
            continue
        violations.append(
            Violation(
                "missing-package",
                "`" + name + "` has .mojo files on disk but is not listed in " + LAYERS_TOML + " [layers]",
            )
        )

    return violations^


# --------------------------------------------------------------------------
# def / impl / uses / deps / raises / summary
# --------------------------------------------------------------------------


def cmd_def(decls: List[Decl], name: String, prefix: Bool):
    var results = List[Decl]()
    for d in decls:
        if d.name == name or (prefix and d.name.startswith(name)):
            results.append(d.copy())
    sort_decls(results)
    for d in results:
        print(d)
    if len(results) == 0:
        print("(no declarations named " + name + ")")


def cmd_impl(decls: List[Decl], trait_name: String):
    var results = List[Decl]()
    for d in decls:
        if d.kind == "struct" and csv_contains(d.traits_csv, trait_name):
            results.append(d.copy())
    sort_decls(results)
    for d in results:
        print(d)
    if len(results) == 0:
        print("(no structs implement " + trait_name + ")")


def cmd_uses(imports: List[ImportRow], target: String):
    var results = locs_from_uses(imports, target)
    dedupe_locs(results)
    for r in results:
        print(r.path + ":" + String(r.line))
    if len(results) == 0:
        print("(no importers of " + target + ")")


def deps_direct(
    pkg: String, lt: LayerTable, dirs: Dirs, imports: List[ImportRow]
) -> List[String]:
    var seen = List[String]()
    for r in imports:
        if r.package != pkg:
            continue
        if r.target_pkg == pkg:
            continue
        var known = (r.target_pkg in lt.layers) or contains(dirs.infra, r.target_pkg)
        if not known:
            continue
        if not contains(seen, r.target_pkg):
            seen.append(r.target_pkg)
    sort(seen)
    return seen^


def deps_transitive(
    pkg: String, lt: LayerTable, dirs: Dirs, imports: List[ImportRow]
) -> List[String]:
    var visited = List[String]()
    var frontier = List[String]()
    frontier.append(pkg)
    while len(frontier) > 0:
        var cur = frontier.pop()
        var direct = deps_direct(cur, lt, dirs, imports)
        for d in direct:
            if not contains(visited, d) and d != pkg:
                visited.append(d)
                frontier.append(d)
    sort(visited)
    return visited^


def mod_deps_direct(
    target: String, lt: LayerTable, dirs: Dirs, imports: List[ImportRow]
) -> List[String]:
    """Modules (as `pkg.mod`) that module `target` (`pkg.mod`) imports.
    A bare package import (`import geometry`) is reported as the package."""
    var seen = List[String]()
    for r in imports:
        if r.package + "." + r.module != target:
            continue
        var known = (r.target_pkg in lt.layers) or contains(dirs.infra, r.target_pkg)
        if not known:
            continue
        var dep = r.target_pkg
        if r.target_mod.byte_length() > 0:
            dep = r.target_pkg + "." + r.target_mod
        if dep != target and not contains(seen, dep):
            seen.append(dep)
    sort(seen)
    return seen^


def cmd_deps(lt: LayerTable, dirs: Dirs, imports: List[ImportRow], pkg: String, all_: Bool):
    if "." in pkg:
        # Module form: `deps collision.queries` -> the modules it imports.
        var mdirect = mod_deps_direct(pkg, lt, dirs, imports)
        print("deps(" + pkg + ") direct:")
        for d in mdirect:
            print("  " + d)
        if all_:
            var visited = List[String]()
            var frontier = mdirect.copy()
            while len(frontier) > 0:
                var cur = frontier.pop()
                if contains(visited, cur) or cur == pkg:
                    continue
                visited.append(cur)
                for d in mod_deps_direct(cur, lt, dirs, imports):
                    if not contains(visited, d):
                        frontier.append(d)
            sort(visited)
            print("deps(" + pkg + ") transitive:")
            for d in visited:
                print("  " + d)
        return
    var direct = deps_direct(pkg, lt, dirs, imports)
    print("deps(" + pkg + ") direct:")
    for d in direct:
        print("  " + d)
    if all_:
        var trans = deps_transitive(pkg, lt, dirs, imports)
        print("deps(" + pkg + ") transitive:")
        for d in trans:
            print("  " + d)


def cmd_raises(decls: List[Decl], pkg: String):
    var results = List[Decl]()
    for d in decls:
        if d.package == pkg and d.raises and (d.kind == "function" or d.kind == "method"):
            results.append(d.copy())
    sort_decls(results)
    for d in results:
        print(d)
    if len(results) == 0:
        print("(no raising functions/methods in " + pkg + ")")


def cmd_summary(
    lt: LayerTable, dirs: Dirs, decls: List[Decl], imports: List[ImportRow], pkg_filter: String
) raises:
    var pkgs = List[String]()
    if pkg_filter.byte_length() > 0:
        pkgs.append(pkg_filter)
    else:
        for k in lt.layer_order:
            if contains(dirs.layered, k):
                pkgs.append(k)
        for d in dirs.infra:
            pkgs.append(d)

    print("package        layer  modules  loc    structs  traits  fan_in  fan_out")
    for pkg in pkgs:
        var modules = list_mojo_files(pkg)
        var loc = 0
        for fname in modules:
            loc += len(read_lines(pkg + "/" + fname))
        var structs = 0
        var traits = 0
        for d in decls:
            if d.package == pkg:
                if d.kind == "struct":
                    structs += 1
                elif d.kind == "trait":
                    traits += 1
        var fan_out = len(deps_direct(pkg, lt, dirs, imports))
        var fan_in = 0
        var all_pkgs = List[String]()
        for k in dirs.layered:
            all_pkgs.append(k)
        for k in dirs.infra:
            all_pkgs.append(k)
        for other in all_pkgs:
            if other == pkg:
                continue
            if contains(deps_direct(other, lt, dirs, imports), pkg):
                fan_in += 1
        var layer_label = String(lt.layers[pkg]) if pkg in lt.layers else String("infra")
        print(
            pkg + "  layer=" + layer_label + "  modules=" + String(len(modules))
            + "  loc=" + String(loc) + "  structs=" + String(structs) + "  traits="
            + String(traits) + "  fan_in=" + String(fan_in) + "  fan_out=" + String(fan_out)
        )


# --------------------------------------------------------------------------
# tiers: tests/test_*.mojo header vs. computed span
# --------------------------------------------------------------------------


def is_valid_tier(t: String) -> Bool:
    return (
        t == "unit"
        or t == "component"
        or t == "integration"
        or t == "system"
        or t == "stress"
    )


def read_tier_header(path: String) raises -> String:
    var lines = read_lines(path)
    comptime TAG = "# tier:"
    for line in lines:
        var s = String(line.strip())
        if s.startswith(TAG):
            var val = String(s[byte = TAG.byte_length() : s.byte_length()].strip())
            return val
    return String("")


def transitive_closure_from(
    seeds: List[String], lt: LayerTable, dirs: Dirs, imports: List[ImportRow]
) -> List[String]:
    var visited = List[String]()
    var frontier = List[String]()
    for s in seeds:
        if not contains(visited, s):
            visited.append(s)
            frontier.append(s)
    while len(frontier) > 0:
        var cur = frontier.pop()
        var direct = deps_direct(cur, lt, dirs, imports)
        for d in direct:
            if not contains(visited, d):
                visited.append(d)
                frontier.append(d)
    sort(visited)
    return visited^


def cmd_tiers(
    lt: LayerTable, dirs: Dirs, decls: List[Decl], imports: List[ImportRow], check_only: Bool
) raises:
    var files = List[String]()
    for fname in list_mojo_files("tests"):
        if fname.startswith("test_"):
            files.append(fname)

    var bad = 0
    for fname in files:
        var relpath = "tests/" + fname
        var declared = read_tier_header(relpath)
        var declared_label = declared if declared.byte_length() > 0 else String("MISSING")
        var valid = declared.byte_length() > 0 and is_valid_tier(declared)
        if not valid:
            bad += 1

        # direct targets of THIS file only, restricted to layered packages
        var direct_targets = List[String]()
        var has_gameloop = False
        var has_ecs = False
        var has_physics = False
        for r in imports:
            if r.path != relpath:
                continue
            if r.target_pkg == "scheduler" and r.target_mod == "gameloop":
                has_gameloop = True
            if r.target_pkg == "ecs":
                has_ecs = True
            if r.target_pkg == "physics":
                has_physics = True
            if contains(dirs.layered, r.target_pkg) and not contains(direct_targets, r.target_pkg):
                direct_targets.append(r.target_pkg)

        var span = transitive_closure_from(direct_targets, lt, dirs, imports)
        var span_final = List[String]()
        for s in span:
            if s != "diag" and s != "harness":
                span_final.append(s)
        if len(span_final) > 1 and contains(span_final, "geometry"):
            var reduced = List[String]()
            for s in span_final:
                if s != "geometry":
                    reduced.append(s)
            span_final = reduced^

        var suggested: String
        if fname.startswith("test_stress_"):
            suggested = "stress"
        elif has_gameloop and has_ecs and has_physics:
            suggested = "system"
        elif len(span_final) >= 2:
            suggested = "integration"
        elif len(span_final) == 1:
            var only_pkg = span_final[0]
            var mods = List[String]()
            for r in imports:
                if r.path == relpath and r.target_pkg == only_pkg and not contains(mods, r.target_mod):
                    mods.append(r.target_mod)
            if len(mods) > 1:
                suggested = "component"
            else:
                var is_trait_seam = False
                for r in imports:
                    if r.path != relpath or r.target_pkg != only_pkg:
                        continue
                    for d in decls:
                        if d.package == only_pkg and d.kind == "trait" and d.name == r.target_name:
                            var impl_count = 0
                            for d2 in decls:
                                if d2.kind == "struct" and csv_contains(d2.traits_csv, d.name):
                                    impl_count += 1
                            if impl_count >= 2:
                                is_trait_seam = True
                suggested = "component" if is_trait_seam else "unit"
        else:
            suggested = "unit"

        var span_str = "[" + join_sep(span_final, ",") + "]"
        var status = "OK" if (valid and declared == suggested) else ("MISMATCH" if valid else "MISSING/INVALID")
        print(fname + "  declared=" + declared_label + "  span=" + span_str + "  suggested=" + suggested + "  " + status)

    print("tiers: " + String(len(files) - bad) + "/" + String(len(files)) + " have a valid header")
    if check_only and bad > 0:
        exit(1)


# --------------------------------------------------------------------------
# bench: grep vs. index, measured
# --------------------------------------------------------------------------


def dedupe_locs(mut locs: List[Loc]):
    sort_locs(locs)
    var out = List[Loc]()
    for l in locs:
        if len(out) == 0 or not (out[len(out) - 1].path == l.path and out[len(out) - 1].line == l.line):
            out.append(l.copy())
    locs = out^


def locs_contains(items: List[Loc], p: String, ln: Int) -> Bool:
    for i in items:
        if i.path == p and i.line == ln:
            return True
    return False


def format_locs(locs: List[Loc]) -> String:
    var out = String("")
    for l in locs:
        out += l.path + ":" + String(l.line) + "\n"
    return out


def locs_from_decl_name(decls: List[Decl], name: String) -> List[Loc]:
    var out = List[Loc]()
    for d in decls:
        if d.name == name:
            out.append(Loc(d.path, d.line))
    return out^


def locs_from_impl(decls: List[Decl], trait_name: String) -> List[Loc]:
    var out = List[Loc]()
    for d in decls:
        if d.kind == "struct" and csv_contains(d.traits_csv, trait_name):
            out.append(Loc(d.path, d.line))
    return out^


def locs_from_uses(imports: List[ImportRow], target: String) -> List[Loc]:
    """Module form (`pkg.mod`) reports the import STATEMENT's line (that's
    where the literal `pkg.mod` text sits); symbol form (`Name`) reports the
    name's own physical line — both to match what `git grep` would find."""
    var out = List[Loc]()
    if target.find(".") >= 0:
        var parts = List[String]()
        for p in target.split("."):
            parts.append(String(p))
        var tp = parts[0]
        var tm = join_dotted(parts, 1)
        for r in imports:
            if r.target_pkg == tp and r.target_mod == tm:
                out.append(Loc(r.path, r.stmt_line))
    else:
        for r in imports:
            if r.target_name == target:
                out.append(Loc(r.path, r.line))
    return out^


def locs_from_raises(decls: List[Decl], pkg: String) -> List[Loc]:
    var out = List[Loc]()
    for d in decls:
        if d.package == pkg and d.raises and (d.kind == "function" or d.kind == "method"):
            out.append(Loc(d.path, d.line))
    return out^


def locs_from_deps_evidence(
    pkg: String, lt: LayerTable, dirs: Dirs, imports: List[ImportRow]
) -> List[Loc]:
    var out = List[Loc]()
    var seen = List[String]()
    for r in imports:
        if r.package != pkg or r.target_pkg == pkg:
            continue
        var known = (r.target_pkg in lt.layers) or contains(dirs.infra, r.target_pkg)
        if not known or contains(seen, r.target_pkg):
            continue
        seen.append(r.target_pkg)
        out.append(Loc(r.path, r.stmt_line))
    return out^


def run_git_grep(argv_list: List[String]) raises -> String:
    var subprocess = Python.import_module("subprocess")
    var py_args = Python.list()
    for a in argv_list:
        py_args.append(a)
    var res = subprocess.run(py_args, capture_output=True, text=True)
    return String(py=res.stdout)


def grep_locs_from_output(text: String) -> List[Loc]:
    var out = List[Loc]()
    for line in text.splitlines():
        var s = String(line)
        var idx1 = s.find(":")
        if idx1 < 0:
            continue
        var path = String(s[byte=0:idx1])
        var rest = String(s[byte = idx1 + 1 : s.byte_length()])
        var idx2 = rest.find(":")
        if idx2 < 0:
            continue
        var num_str = String(rest[byte=0:idx2])
        try:
            var num = Int(num_str)
            out.append(Loc(path, num))
        except:
            continue
    return out^


def bench_row(
    label: String, cmd_str: String, grep_argv: List[String], mut index_locs: List[Loc], mut acc: List[Int]
) raises:
    dedupe_locs(index_locs)
    var grep_text = run_git_grep(grep_argv)
    var grep_locs = grep_locs_from_output(grep_text)
    var fp = 0
    for g in grep_locs:
        if not locs_contains(index_locs, g.path, g.line):
            fp += 1
    var fneg = 0
    for ix in index_locs:
        if not locs_contains(grep_locs, ix.path, ix.line):
            fneg += 1
    var index_text = format_locs(index_locs)
    print(
        "| " + label + " | `" + cmd_str + "` | " + String(len(grep_locs)) + " | "
        + String(grep_text.byte_length()) + " | " + String(len(index_locs)) + " | "
        + String(index_text.byte_length()) + " | " + String(fp) + " | " + String(fneg) + " |"
    )
    acc[0] += len(grep_locs)
    acc[1] += grep_text.byte_length()
    acc[2] += len(index_locs)
    acc[3] += index_text.byte_length()
    acc[4] += fp
    acc[5] += fneg


def cmd_bench(lt: LayerTable, dirs: Dirs, decls: List[Decl], imports: List[ImportRow]) raises:
    print("| Query | grep command | grep hits | grep bytes | index hits | index bytes | false+ | false- |")
    print("|---|---|---|---|---|---|---|---|")
    var acc = List[Int]()
    for _ in range(6):
        acc.append(0)

    var q1 = locs_from_decl_name(decls, "BVH")
    bench_row("def BVH", "git grep -n -w BVH -- *.mojo", ["git", "grep", "-n", "-w", "BVH", "--", "*.mojo"], q1, acc)

    var q2 = locs_from_decl_name(decls, "ContactScene6")
    bench_row("def ContactScene6", "git grep -n -w ContactScene6 -- *.mojo", ["git", "grep", "-n", "-w", "ContactScene6", "--", "*.mojo"], q2, acc)

    var q3 = locs_from_decl_name(decls, "_Leaf")
    bench_row("def _Leaf (private)", "git grep -n -w _Leaf -- *.mojo", ["git", "grep", "-n", "-w", "_Leaf", "--", "*.mojo"], q3, acc)

    var q4 = locs_from_impl(decls, "BroadPhase")
    bench_row("impl BroadPhase", "git grep -n -w BroadPhase -- *.mojo", ["git", "grep", "-n", "-w", "BroadPhase", "--", "*.mojo"], q4, acc)

    var q5 = locs_from_impl(decls, "StorageBackend")
    bench_row("impl StorageBackend", "git grep -n -w StorageBackend -- *.mojo", ["git", "grep", "-n", "-w", "StorageBackend", "--", "*.mojo"], q5, acc)

    var q6 = locs_from_uses(imports, "collision.queries")
    bench_row("uses collision.queries", "git grep -n -F collision.queries -- *.mojo", ["git", "grep", "-n", "-F", "collision.queries", "--", "*.mojo"], q6, acc)

    var q7 = locs_from_uses(imports, "geometry.bvh")
    bench_row("uses geometry.bvh", "git grep -n -F geometry.bvh -- *.mojo", ["git", "grep", "-n", "-F", "geometry.bvh", "--", "*.mojo"], q7, acc)

    var q8 = locs_from_uses(imports, "SceneQuery")
    bench_row("uses SceneQuery", "git grep -n -w SceneQuery -- *.mojo", ["git", "grep", "-n", "-w", "SceneQuery", "--", "*.mojo"], q8, acc)

    var q9 = locs_from_uses(imports, "BoxProxy")
    bench_row("uses BoxProxy", "git grep -n -w BoxProxy -- *.mojo", ["git", "grep", "-n", "-w", "BoxProxy", "--", "*.mojo"], q9, acc)

    var q10 = locs_from_raises(decls, "physics")
    bench_row("raises physics", "git grep -n -w raises -- physics/*.mojo", ["git", "grep", "-n", "-w", "raises", "--", "physics/*.mojo"], q10, acc)

    var q11 = locs_from_deps_evidence("collision", lt, dirs, imports)
    bench_row("deps collision", "git grep -n -e ^from  -e ^import  -- collision/*.mojo", ["git", "grep", "-n", "-e", "^from ", "-e", "^import ", "--", "collision/*.mojo"], q11, acc)

    var q12 = locs_from_deps_evidence("physics", lt, dirs, imports)
    bench_row("deps physics", "git grep -n -e ^from  -e ^import  -- physics/*.mojo", ["git", "grep", "-n", "-e", "^from ", "-e", "^import ", "--", "physics/*.mojo"], q12, acc)

    print("|---|---|---|---|---|---|---|---|")
    print(
        "| **total** |  | " + String(acc[0]) + " | " + String(acc[1]) + " | " + String(acc[2])
        + " | " + String(acc[3]) + " | " + String(acc[4]) + " | " + String(acc[5]) + " |"
    )


# --------------------------------------------------------------------------
# selftest: a fixture tree exercising every `check` rule exactly once
# --------------------------------------------------------------------------


def write_file(path: String, content: String) raises:
    var f = open(path, "w")
    f.write(content)
    f.close()


def violation_count_containing(violations: List[Violation], needle: String) -> Int:
    var c = 0
    for v in violations:
        if v.message.find(needle) >= 0:
            c += 1
    return c


def cmd_selftest() raises:
    var tempfile = Python.import_module("tempfile")
    var shutil = Python.import_module("shutil")
    var os = Python.import_module("os")
    var tmpdir = String(py=tempfile.mkdtemp(prefix="archindex_selftest_"))
    var orig_cwd = String(py=os.getcwd())

    os.makedirs(tmpdir + "/scripts")
    os.makedirs(tmpdir + "/low")
    os.makedirs(tmpdir + "/mid")
    os.makedirs(tmpdir + "/midb")
    os.makedirs(tmpdir + "/high")
    os.makedirs(tmpdir + "/cyc")
    os.makedirs(tmpdir + "/orphan")

    var toml_content = (
        '[layers]\nlow = 0\nmid = 1\nmidb = 1\nhigh = 2\ncyc = 1\n\n'
        + '[infrastructure]\npackages = []\nconsumers = []\n\n'
        + '[allow_private]\n"high/h_allowed.mojo:low.priv2._other" = "selftest fixture: deliberately allowed"\n'
    )
    write_file(tmpdir + "/scripts/arch_layers.toml", toml_content)
    write_file(tmpdir + "/low/l1.mojo", "def thing():\n    pass\n")
    write_file(tmpdir + "/low/l2.mojo", "from mid.m1 import Thing\n")
    write_file(tmpdir + "/low/l3.mojo", "from .l1 import thing\n")
    write_file(tmpdir + "/low/priv.mojo", "def _secret():\n    pass\n")
    write_file(tmpdir + "/low/priv2.mojo", "def _other():\n    pass\n")
    write_file(tmpdir + "/low/multi.mojo", "def Thing1():\n    pass\ndef Thing2():\n    pass\n")
    write_file(tmpdir + "/mid/m1.mojo", "from low.l1 import thing\n")
    write_file(tmpdir + "/mid/m3.mojo", "from midb.x import Y\n")
    write_file(tmpdir + "/mid/m4.mojo", "from low.multi import (\n    Thing1,\n    Thing2,\n)\n")
    write_file(
        tmpdir + "/mid/m5.mojo",
        '"""\nfrom high.h0 import _DocGhost\nfrom mid.m1 import nope\n"""\nfrom low.l1 import thing\n',
    )
    write_file(tmpdir + "/midb/x.mojo", "def Y():\n    pass\n")
    write_file(tmpdir + "/high/h_priv.mojo", "from low.priv import _secret\n")
    write_file(tmpdir + "/high/h_allowed.mojo", "from low.priv2 import _other\n")
    write_file(tmpdir + "/cyc/a.mojo", "from .b import thing_b\n")
    write_file(tmpdir + "/cyc/b.mojo", "from .c import thing_c\n")
    write_file(tmpdir + "/cyc/c.mojo", "from .a import thing_a\n")
    write_file(tmpdir + "/orphan/o1.mojo", "from low.l1 import thing\n")

    os.chdir(tmpdir)
    var lt = load_layer_table("scripts/arch_layers.toml")
    var dirs = classify_dirs(lt)
    var imports = List[ImportRow]()
    scan_imports_only(dirs, imports)
    var violations = run_check(lt, dirs, imports)
    os.chdir(orig_cwd)
    shutil.rmtree(tmpdir, ignore_errors=True)

    var total = 10
    var passed = 0
    var results = List[String]()

    var c1 = violation_count_containing(violations, "m1.mojo") == 0
    results.append("1. clean layered pair: " + ("pass" if c1 else "FAIL"))
    if c1:
        passed += 1

    var c2 = violation_count_containing(violations, "l2.mojo") == 1
    results.append("2. upward import flagged once: " + ("pass" if c2 else "FAIL"))
    if c2:
        passed += 1

    var c3 = violation_count_containing(violations, "m3.mojo") == 1
    results.append("3. same-layer import flagged once: " + ("pass" if c3 else "FAIL"))
    if c3:
        passed += 1

    var c4 = violation_count_containing(violations, "cyc/a") == 1 and violation_count_containing(violations, "cyc/b") == 1 and violation_count_containing(violations, "cyc/c") == 1
    results.append("4. 3-module cycle flagged once: " + ("pass" if c4 else "FAIL"))
    if c4:
        passed += 1

    var c5 = violation_count_containing(violations, "h_priv.mojo") == 1
    results.append("5. private cross-package import flagged once: " + ("pass" if c5 else "FAIL"))
    if c5:
        passed += 1

    var c6 = violation_count_containing(violations, "h_allowed.mojo") == 0
    results.append("6. allowed private import not flagged: " + ("pass" if c6 else "FAIL"))
    if c6:
        passed += 1

    var c7 = violation_count_containing(violations, "m4.mojo") == 0
    results.append("7. multi-line parenthesised import clean: " + ("pass" if c7 else "FAIL"))
    if c7:
        passed += 1

    var c8 = violation_count_containing(violations, "DocGhost") == 0 and violation_count_containing(violations, "m5.mojo") == 0
    results.append("8. import inside docstring ignored: " + ("pass" if c8 else "FAIL"))
    if c8:
        passed += 1

    var c9 = violation_count_containing(violations, "l3.mojo") == 0
    results.append("9. relative import resolves clean: " + ("pass" if c9 else "FAIL"))
    if c9:
        passed += 1

    var c10 = violation_count_containing(violations, "orphan") == 1
    results.append("10. package missing from layer table flagged once: " + ("pass" if c10 else "FAIL"))
    if c10:
        passed += 1

    for r in results:
        print(r)
    print("archindex selftest: " + String(passed) + "/" + String(total))
    if passed != total:
        exit(1)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def main() raises:
    var args = List[String]()
    for a in argv():
        args.append(String(a))
    if len(args) < 2:
        print("usage: archindex <build|def|impl|uses|deps|raises|summary|check|tiers|bench|selftest> [args]")
        exit(1)
    var cmd = args[1]

    if cmd == "selftest":
        cmd_selftest()
        return

    var lt = load_layer_table(LAYERS_TOML)
    var decls = List[Decl]()
    var imports = List[ImportRow]()
    var force = cmd == "build"
    var dirs = ensure_index(force, lt, decls, imports)

    if cmd == "build":
        print("archindex: built (" + String(len(decls)) + " decls, " + String(len(imports)) + " imports)")
    elif cmd == "def":
        if len(args) < 3:
            print("usage: archindex def NAME [--prefix]")
            exit(1)
        var prefix = len(args) > 3 and args[3] == "--prefix"
        cmd_def(decls, args[2], prefix)
    elif cmd == "impl":
        if len(args) < 3:
            print("usage: archindex impl TRAIT")
            exit(1)
        cmd_impl(decls, args[2])
    elif cmd == "uses":
        if len(args) < 3:
            print("usage: archindex uses TARGET")
            exit(1)
        cmd_uses(imports, args[2])
    elif cmd == "deps":
        if len(args) < 3:
            print("usage: archindex deps MODULE [--all]")
            exit(1)
        var all_ = len(args) > 3 and args[3] == "--all"
        cmd_deps(lt, dirs, imports, args[2], all_)
    elif cmd == "raises":
        if len(args) < 3:
            print("usage: archindex raises PKG")
            exit(1)
        cmd_raises(decls, args[2])
    elif cmd == "summary":
        var pkg_filter = args[2] if len(args) > 2 else String("")
        cmd_summary(lt, dirs, decls, imports, pkg_filter)
    elif cmd == "check":
        var violations = run_check(lt, dirs, imports)
        if len(violations) == 0:
            var node_names = List[String]()
            var node_id = Dict[String, Int]()
            collect_precompiled_modules(dirs, node_names, node_id)
            var adj = build_adjacency(node_id, len(node_names), imports)
            var edges = 0
            for lst in adj:
                edges += len(lst)
            print("arch check: OK (" + String(len(node_names)) + " modules, " + String(edges) + " edges)")
        else:
            for v in violations:
                print(v)
            exit(1)
    elif cmd == "tiers":
        var check_only = len(args) > 2 and args[2] == "--check"
        cmd_tiers(lt, dirs, decls, imports, check_only)
    elif cmd == "bench":
        cmd_bench(lt, dirs, decls, imports)
    else:
        print("unknown command: " + cmd)
        exit(1)
