#!/usr/bin/env python3
"""Directory-rule check for ludens-shell (issue #6, E1).

    python3 scripts/check_layout.py              # check the repo, exit 1 on a violation
    python3 scripts/check_layout.py --selftest   # inject one violation per rule, expect it reported

Rules (README "Rules"):
  R1  shell/ implements imports only: no editor / ui symbols, no path into editor/ or ui/, and the module
      exports it uses (shell/web/exports.d.ts) are the generic `app_*` entry points.
  R2  ui/ imports only the standard library, wgpu-mojo and itself. Never engine packages, app/ or editor/.
  R3  editor/ and ui/ hold Mojo (and Markdown) only: no TS / JS / HTML / CSS.
  R4  editor/ built-ins call the extension API (#18) instead of editor internals. Pending until #18 lands:
      flip EXTENSION_API_ENFORCED once the registration points exist.
"""
import argparse
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

UI_ALLOWED_IMPORTS = {"std", "wgpu", "ui"}
EXTENSION_API_ENFORCED = False  # R4, see issue #18
SHELL_SOURCE_SUFFIXES = {".ts", ".tsx", ".js", ".mjs", ".html", ".css", ".py"}
MOJO_ONLY_FORBIDDEN_SUFFIXES = {".ts", ".tsx", ".js", ".mjs", ".html", ".css", ".jsx"}

EDITOR_SYMBOL = re.compile(r"\b(?:editor|ed|ui)_[A-Za-z0-9_]*")
EDITOR_PATH = re.compile(r"(?:^|[/'\"])(?:editor|ui)/")
IMPORT = re.compile(r"^\s*(?:from\s+([A-Za-z_][\w.]*)\s+import|import\s+([A-Za-z_][\w.]*))", re.MULTILINE)
EXPORT_NAME = re.compile(r"^\s+([A-Za-z_][\w]*)\(", re.MULTILINE)
GENERIC_EXPORT = re.compile(r"^app_[a-z0-9_]+$")


def files(root: Path, sub: str, suffixes: set[str] | None = None) -> list[Path]:
    base = root / sub
    if not base.is_dir():
        return []
    return sorted(p for p in base.rglob("*") if p.is_file() and (suffixes is None or p.suffix in suffixes))


def check(root: Path) -> list[str]:
    problems: list[str] = []

    # R1: shell/ is imports only.
    for p in files(root, "shell", SHELL_SOURCE_SUFFIXES):
        rel = p.relative_to(root)
        for n, line in enumerate(p.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            m = EDITOR_SYMBOL.search(line)
            if m:
                problems.append(f"R1 {rel}:{n}: editor/ui symbol `{m.group(0)}` in a platform shell")
            if EDITOR_PATH.search(line):
                problems.append(f"R1 {rel}:{n}: path into editor/ or ui/ from a platform shell")
    for p in files(root, "shell", {".ts"}):
        if p.name == "exports.d.ts":
            for name in EXPORT_NAME.findall(p.read_text(encoding="utf-8")):
                if not GENERIC_EXPORT.match(name):
                    problems.append(f"R1 {p.relative_to(root)}: export `{name}` is not a generic app_* entry point")

    # R2: ui/ depends on std, wgpu and itself only.
    for p in files(root, "ui", {".mojo"}):
        text = p.read_text(encoding="utf-8")
        for m in IMPORT.finditer(text):
            mod = m.group(1) or m.group(2)
            top = mod.split(".")[0]
            if top not in UI_ALLOWED_IMPORTS:
                line = text.count("\n", 0, m.start()) + 1
                problems.append(f"R2 {p.relative_to(root)}:{line}: ui/ imports `{mod}` (allowed: {', '.join(sorted(UI_ALLOWED_IMPORTS))})")

    # R3: editor/ and ui/ are Mojo.
    for sub in ("editor", "ui"):
        for p in files(root, sub, MOJO_ONLY_FORBIDDEN_SUFFIXES):
            problems.append(f"R3 {p.relative_to(root)}: {sub}/ holds Mojo only, not `{p.suffix}`")

    # R4: pending the extension API.
    if EXTENSION_API_ENFORCED:
        problems.append("R4 enabled but not implemented: add the check together with the registration points (#18)")
    return problems


def selftest() -> int:
    ok = True

    def expect(name: str, tree: dict[str, str], want_rules: list[str]) -> None:
        nonlocal ok
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            for rel, text in tree.items():
                f = root / rel
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_text(text, encoding="utf-8")
            got = sorted(p.split()[0] for p in check(root))
        good = got == sorted(want_rules)
        ok &= good
        print(f"  [{'PASS' if good else 'FAIL'}] layout selftest - {name} {got}")

    clean = {
        "shell/web/app.ts": "const x = app.app_frame(1);\n",
        "shell/web/exports.d.ts": "export interface AppExports {\n  app_frame(app: bigint, dt: number): number;\n}\n",
        "ui/button.mojo": "from std.ffi import external_call\nfrom wgpu.device import Device\nfrom ui.text import Label\n",
        "editor/command.mojo": "from embed.world import EmbedWorld\n",
    }
    expect("clean tree", clean, [])
    expect("editor symbol in a shell", {**clean, "shell/web/panel.ts": "editor_open_panel();\n"}, ["R1"])
    expect("path into editor/ from a shell", {**clean, "shell/web/x.mjs": "import '../../editor/cmd.mojo';\n"}, ["R1"])
    expect("non-generic export", {**clean, "shell/web/exports.d.ts": "export interface AppExports {\n  app_frame(a: bigint): number;\n  inspect_body(a: bigint): number;\n}\n"}, ["R1"])
    expect("ui imports the engine", {**clean, "ui/bad.mojo": "from geometry.vec import Vec3\n"}, ["R2"])
    expect("ui imports editor", {**clean, "ui/bad.mojo": "import editor.command\n"}, ["R2"])
    expect("ui imports app", {**clean, "ui/bad.mojo": "from app.sim import Sim\n"}, ["R2"])
    expect("typescript inside editor", {**clean, "editor/panel.ts": "export {}\n"}, ["R3"])
    expect("html inside ui", {**clean, "ui/index.html": "<html></html>\n"}, ["R3"])
    print(f"layout selftest: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--root", type=Path, default=ROOT)
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    problems = check(args.root)
    for p in problems:
        print(p)
    if not EXTENSION_API_ENFORCED:
        print("note: R4 (editor/ built-ins use only the extension API) is pending #18")
    print(f"layout: {'FAIL' if problems else 'PASS'} ({len(problems)} problems)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
