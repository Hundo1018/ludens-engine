"""Find documentation text that names code which does not exist, or calls code "future" that exists now.

    pixi run -e wasm stale-refs                 # check, exit 1 on a finding
    pixi run -e wasm stale-refs -- --report     # every finding, no exit code
    pixi run -e wasm stale-refs -- --selftest

Adapted from ludens-core's scripts/stale_refs.py. Where it looks: comments and docstrings of every `.mojo` file,
`//` and `/* */` comments of the `.ts` / `.mjs` / `.js` files, and the prose docs in DOCS (README.md, docs/*.md).
Skipped: docs/scene-format.md, a design for the next scene format ("it is not implemented"), whose job is to name
code that does not exist yet.

Two rules:

  dead name    A backticked token that reads as a code name -- `_private`, `snake_case_name`, `CamelCase`,
               `Type.member`, `pkg.module` / `pkg.module.Name` for a package of this repo (app, editor, game, ui) --
               must exist. A plain name must appear in code (comments and docstrings removed); `pkg.module` must be
               the file `pkg/module.mojo`, and `pkg.module.Name` must also have `Name` in that file.
  resolved     A sentence that says a named thing is missing ("a future `X`", "until `X` exists", "`X` does
               not exist yet", "no `X` yet", "once `X` lands") while `X` exists.

Names from the libraries this repo builds against (ludens-core, wgpu-mojo, miniaudio-mojo, ludens-wasm-rt) are not
in this checkout (scripts/deps.sh exports them into build/ on demand), so the ones the docs use are listed in ALLOW.

A finding that is correct as written (a dependency's API, an external API, notation, an example name) goes in ALLOW
with a reason: `token  # reason` (anywhere) or `path:token  # reason` (one file).
"""

import argparse
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALLOW = "scripts/stale_refs_allow.txt"
DOC_GLOBS = ["README.md", "docs/*.md"]
DOC_SKIP = {"docs/scene-format.md"}
SKIP_DIRS = {".git", ".pixi", "build", "build64", "node_modules", "__pycache__"}
CODE_EXT = (".mojo", ".py", ".sh", ".toml", ".ts", ".mjs", ".js", ".yml", ".html", ".json")
JS_EXT = (".ts", ".mjs", ".js")
FILE_EXT = {"ts", "mjs", "js", "py", "md", "toml", "mojo", "wasm", "json", "html", "css", "sh", "txt"}

SQ = re.compile(r"(?<![A-Za-z0-9])'(?:\\.|[^'\\\n])*'")
TICK = re.compile(r"`([^`\n]{1,120})`")
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
MEMBER = re.compile(r"^([A-Z][A-Za-z0-9]+)\.([a-z_][a-z0-9_]*)$")
QUAL = re.compile(r"^([a-z_][a-z0-9_]*)\.([a-z_][a-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)$")
MODREF = re.compile(r"^([a-z_][a-z0-9_]*)\.([a-z_][a-z0-9_]*)$")
MISSING = [
    re.compile(r"\bfuture\s+`([^`]+)`", re.I),
    re.compile(r"\buntil\s+`([^`]+)`\s+(?:exists|lands|is added|is written)", re.I),
    re.compile(r"\bonce\s+`([^`]+)`\s+(?:exists|lands|is added)", re.I),
    re.compile(r"`([^`]+)`\s+(?:does not|doesn't)\s+(?:exist|exist yet)\b", re.I),
    re.compile(r"\bno\s+`([^`]+)`\s+yet\b", re.I),
    re.compile(r"`([^`]+)`\s+(?:is|are)\s+not\s+(?:written|implemented|there)\s+yet\b", re.I),
]


def walk(root: Path):
    for p in sorted(root.rglob("*")):
        rel = p.relative_to(root)
        if any(part in SKIP_DIRS for part in rel.parts) or not p.is_file():
            continue
        yield p, rel.as_posix()


LITERAL_BEFORE = re.compile(r"(?:[=+(,\[]|\breturn)\s*$")


def strip_mojo(text: str) -> tuple[str, list[tuple[int, str]]]:
    """(code without comments/docstrings, [(line, prose)] of the comments and docstrings). The code has one line per
    source line (blank where a line is all docstring), so a line number in it is the line number in the file.

    A triple-quoted string after `=`, `+`, `(`, `,`, `[` or `return` is a string literal (this repo keeps its WGSL
    in `comptime X = \"\"\"...\"\"\"`), so it stays code; any other one is a docstring."""
    code, prose = [], []
    in_doc = in_lit = False
    for i, line in enumerate(text.splitlines(), 1):
        kept = []
        if in_doc or in_lit:
            if '"""' not in line:
                if in_lit:
                    code.append(line)
                else:
                    prose.append((i, line))
                    code.append("")
                continue
            before, _, line = line.partition('"""')
            if in_lit:
                kept.append(before)
            else:
                prose.append((i, before))
            in_doc = in_lit = False
        # a single-quoted literal can hold `"""` (`'"""'`); hide it so it does not open a docstring
        line = SQ.sub(lambda m: "'" + " " * (len(m.group(0)) - 2) + "'", line)
        while '"""' in line:
            before, _, rest = line.partition('"""')
            kept.append(before)
            literal = bool(LITERAL_BEFORE.search(" ".join(kept)))
            if '"""' in rest:
                doc, _, line = rest.partition('"""')
                if literal:
                    kept.append(doc)
                else:
                    prose.append((i, doc))
            else:
                if literal:
                    kept.append(rest)
                    in_lit = True
                else:
                    prose.append((i, rest))
                    in_doc = True
                line = ""
                break
        # a `#` outside a string literal starts a comment
        no_str = re.sub(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', lambda m: " " * len(m.group(0)), line)
        k = no_str.find("#")
        if k >= 0:
            prose.append((i, line[k + 1:]))
            line = line[:k]
        kept.append(line)
        code.append(" ".join(kept))
    return "\n".join(code), prose


def strip_js(text: str) -> tuple[str, list[tuple[int, str]]]:
    """The same split for TS / JS: `//` to the end of the line and `/* ... */`, outside string literals. Template
    literals and regex literals are taken as code; a `//` inside one is cut short, which only loses prose."""
    code, prose = [], []
    in_block = False
    for i, line in enumerate(text.splitlines(), 1):
        if in_block:
            end = line.find("*/")
            if end < 0:
                prose.append((i, line))
                code.append("")
                continue
            prose.append((i, line[:end]))
            line = line[end + 2:]
            in_block = False
        no_str = re.sub(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|`(?:\\.|[^`\\])*`',
                        lambda m: " " * len(m.group(0)), line)
        out = []
        pos = 0
        while True:
            a, b = no_str.find("//", pos), no_str.find("/*", pos)
            if a < 0 and b < 0:
                out.append(line[pos:])
                break
            if b < 0 or 0 <= a < b:
                out.append(line[pos:a])
                prose.append((i, line[a + 2:]))
                break
            out.append(line[pos:b])
            end = no_str.find("*/", b + 2)
            if end < 0:
                prose.append((i, line[b + 2:]))
                in_block = True
                break
            prose.append((i, line[b + 2:end]))
            pos = end + 2
        code.append(" ".join(out))
    return "\n".join(code), prose


def strip_py(text: str) -> str:
    text = re.sub(r'"""[\s\S]*?"""', "", text)
    return re.sub(r"#.*", "", text)


def index(root: Path):
    """Names that appear in code, the names of each local .mojo module, and the prose to check."""
    words, per_module, prose = set(), {}, {}
    for p, rel in walk(root):
        if p.suffix not in CODE_EXT:
            continue
        text = p.read_text(encoding="utf-8", errors="ignore")
        if p.suffix == ".mojo":
            code, pr = strip_mojo(text)
            prose[rel] = pr
            per_module[rel] = set(WORD.findall(code))
        elif p.suffix in JS_EXT:
            code, pr = strip_js(text)
            prose[rel] = pr
        elif p.suffix == ".py":
            code = strip_py(text)
        else:
            code = text
        words.update(WORD.findall(code))
    return words, per_module, prose


def is_code_name(tok: str) -> bool:
    if tok.startswith("_") and len(tok) > 2:
        return True
    if "_" in tok.strip("_") and tok.lower() == tok and len(tok) >= 6:
        return True
    return bool(re.fullmatch(r"[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]*)+", tok))


def exists(tok: str, words, per_module) -> bool | None:
    """True / False when `tok` is a checkable code name, None when it is not one."""
    tok = tok.strip().rstrip("()").removesuffix("[]")
    local = lambda pkg: any(k.startswith(pkg + "/") for k in per_module)  # noqa: E731
    m = QUAL.match(tok)
    if m:  # `pkg.mod.Name` for a package of this repo; `max.gpu.host` or `self.a.b` are not checked
        if not local(m.group(1)):
            return None
        mod = f"{m.group(1)}/{m.group(2)}.mojo"
        return mod in per_module and m.group(3) in per_module[mod]
    m = MODREF.match(tok)
    if m and local(m.group(1)) and m.group(2) not in FILE_EXT:  # `app.ts` is a file name, not a module  # `game.draw_item`: the module file
        mod = f"{m.group(1)}/{m.group(2)}"
        return mod + ".mojo" in per_module or any(k.startswith(mod + "/") for k in per_module)
    m = MEMBER.match(tok)
    if m:  # `Type.member`: both names must appear in code
        return m.group(1) in words and m.group(2) in words
    if "." in tok:
        return None
    if not WORD.fullmatch(tok):
        return None
    if not is_code_name(tok):
        return None
    return tok in words


def load_allow(root: Path) -> dict[str, str]:
    f = root / ALLOW
    out = {}
    if not f.exists():
        return out
    for line in f.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, _, reason = line.partition("#")
        out[key.strip()] = reason.strip()
    return out


def docs(root: Path) -> list[str]:
    out = []
    for g in DOC_GLOBS:
        out += sorted(p.relative_to(root).as_posix() for p in root.glob(g) if p.is_file())
    return [d for d in out if d not in DOC_SKIP]


def findings(root: Path) -> list[tuple[str, int, str, str]]:
    """(path, line, token, rule) for every finding, before the allow list."""
    words, per_module, prose = index(root)
    texts = dict(prose)
    for d in docs(root):
        texts[d] = list(enumerate((root / d).read_text(encoding="utf-8").splitlines(), 1))
    out = []
    for rel, lines in sorted(texts.items()):
        prev = ""
        for i, line in lines:
            for m in TICK.finditer(line):
                inner = m.group(1).strip()
                if exists(inner, words, per_module) is False:
                    out.append((rel, i, inner, "dead name"))
            joined = prev + " " + line  # a sentence wrapped across two lines
            start = len(prev) + 1
            prev = line
            for pat in MISSING:
                for m in pat.finditer(joined):
                    tok = m.group(1)
                    if m.end() <= start:
                        continue  # wholly on the previous line: reported there
                    if exists(tok, words, per_module) or (root / tok).exists():
                        out.append((rel, i, tok, "resolved"))
    return out


def check(root: Path) -> list[str]:
    allow = load_allow(root)
    used, problems = set(), []
    for rel, i, tok, rule in findings(root):
        for key in (f"{rel}:{tok}", tok):
            if key in allow:
                used.add(key)
                break
        else:
            what = "names code that does not exist" if rule == "dead name" else "calls existing code missing or future"
            problems.append(f"{rel}:{i}: `{tok}` {what}")
    for key, reason in allow.items():
        if not reason:
            problems.append(f"{ALLOW}: `{key}` has no reason")
        elif key not in used:
            problems.append(f"{ALLOW}: `{key}` is not needed any more (nothing matches it)")
    return problems


def selftest() -> int:
    cases = 0
    with tempfile.TemporaryDirectory() as t:
        r = Path(t)
        (r / "pkg").mkdir()
        (r / "docs").mkdir()
        (r / "pkg/mod.mojo").write_text(
            '"""Uses `live_name` and `pkg.mod.Thing`, from `pkg.mod`."""\n'
            "def live_name():\n    pass\n\nstruct Thing:\n    pass\n"
            "# `_gone_helper` was renamed\n"
            "# a\n# future `live_name` will do it\n"
            "# a future `Thing.live_name`; `Thing.gone_method` too\n"
            "# `pkg.mod.Missing` and `pkg.gone_mod`\n"
            '# `x + y` and `max` are not code names, nor `max.gpu.host`, `wgpu._ffi` or `self.a.b`\n'
            'var s = "# `_in_string` is not a comment"\n'
            "var q = '\"\"\"'  # `_after_quote` is a comment, not a docstring\n"
            "def after_quote():\n    pass\n"
            'comptime WGSL = """\nfn wgsl_only_fn() {}\n"""\n'
            "# `wgsl_only_fn` is in a string literal, which is code; `pkg.ts` is a file name\n"
        )
        (r / "pkg/web.ts").write_text(
            "// `live_name` is fine, `_ts_gone` is not\n"
            'const u = "http://x/`_in_ts_string`";\n'
            "/* `BlockGone`\n   `_block_two` */ const k = 1; // `_after_block`\n"
        )
        (r / "README.md").write_text("`_readme_gone` and `live_name`\n")
        (r / "docs/plan.md").write_text("`_doc_gone`\n")
        (r / "docs/scene-format.md").write_text("`_design_name` is skipped\n")
        got = {(rel, tok, rule) for rel, _, tok, rule in findings(r)}
        want = {
            ("pkg/mod.mojo", "_gone_helper", "dead name"),
            ("pkg/mod.mojo", "live_name", "resolved"),
            ("pkg/mod.mojo", "Thing.live_name", "resolved"),
            ("pkg/mod.mojo", "Thing.gone_method", "dead name"),
            ("pkg/mod.mojo", "pkg.mod.Missing", "dead name"),
            ("pkg/mod.mojo", "pkg.gone_mod", "dead name"),
            ("pkg/mod.mojo", "_after_quote", "dead name"),
            ("pkg/web.ts", "_ts_gone", "dead name"),
            ("pkg/web.ts", "BlockGone", "dead name"),
            ("pkg/web.ts", "_block_two", "dead name"),
            ("pkg/web.ts", "_after_block", "dead name"),
            ("README.md", "_readme_gone", "dead name"),
            ("docs/plan.md", "_doc_gone", "dead name"),
        }
        cases += 1
        if got != want:
            print(f"selftest FAIL findings: got {sorted(got)} want {sorted(want)}")
            return 1
        (r / "scripts").mkdir()
        (r / ALLOW).write_text("_gone_helper  # kept as history\npkg/mod.mojo:pkg.gone_mod\nunused_entry  # stale\n")
        p = check(r)
        cases += 1
        expect = {"no reason", "not needed any more"}
        if len(p) != 13 or not all(any(e in x for x in p) for e in expect):
            print("selftest FAIL allow list:", p)
            return 1
    print(f"stale_refs selftest: {cases} cases ok")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    problems = check(ROOT)
    if a.report:
        for p in problems:
            print(p)
        print(f"{len(problems)} findings")
        return 0
    if problems:
        print("stale references (fix the text, or allow it with a reason in " + ALLOW + "):")
        for p in problems:
            print("  " + p)
        return 1
    print("stale_refs: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
