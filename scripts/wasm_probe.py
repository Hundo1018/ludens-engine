"""Which leaf kernels could ship as wasm today? (ROADMAP 17.76)

    pixi run wasm-probe            # every tools/wasm/kernel_*.mojo
    pixi run wasm-probe -- --selftest

Modular's LLVM has no wasm backend; the known route is `mojo build --emit
llvm` and an external llc (PoC 2026-07-24). That route works only for code
that needs nothing from the Mojo runtime. For each `@export` function in a
kernel file this emits the LLVM IR, walks the call graph from that function,
and lists every reachable symbol that is only DECLARED (an import a wasm
module would need), ignoring `llvm.*` intrinsics. Zero imports = a candidate
leaf kernel. (The emitted module's `main` pulls in runtime start-up symbols;
they are not reachable from the kernel and are not counted.)
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFINE = re.compile(r"^define [^@]*@\"?([\w.$]+)\"?\(")
DECLARE = re.compile(r"^declare [^@]*@\"?([\w.$]+)\"?\(")
CALLEE = re.compile(r"@\"?([\w.$]+)\"?\(")


def parse(ir: str) -> tuple[dict[str, set[str]], set[str]]:
    """(function -> symbols referenced in its body, declared symbols)."""
    bodies: dict[str, set[str]] = {}
    declared: set[str] = set()
    cur = None
    for line in ir.splitlines():
        m = DEFINE.match(line)
        if m:
            cur = m.group(1)
            bodies[cur] = set()
            continue
        m = DECLARE.match(line)
        if m:
            declared.add(m.group(1))
            continue
        if cur is not None:
            if line.startswith("}"):
                cur = None
                continue
            for c in CALLEE.findall(line):
                bodies[cur].add(c)
    return bodies, declared


def imports(ir: str, root: str) -> list[str]:
    bodies, declared = parse(ir)
    seen, todo, out = set(), [root], set()
    while todo:
        f = todo.pop()
        if f in seen:
            continue
        seen.add(f)
        for c in bodies.get(f, ()):
            if c in bodies:
                todo.append(c)
            elif c in declared and not c.startswith("llvm."):
                out.add(c)
    return sorted(out)


def exported(src: str) -> list[str]:
    names, nxt = [], False
    for line in src.splitlines():
        if line.strip() == "@export":
            nxt = True
            continue
        if nxt:
            m = re.match(r"\s*def\s+(\w+)", line)
            if m:
                names.append(m.group(1))
            nxt = False
    return names


def run(files: list[Path]) -> int:
    worst = 0
    for f in files:
        with tempfile.TemporaryDirectory(prefix="wasm_") as d:
            ll = Path(d) / "k.ll"
            r = subprocess.run(["mojo", "build", "--emit", "llvm", "-I", "build", "-o", str(ll), str(f)],
                               cwd=ROOT, capture_output=True, text=True, encoding="utf-8")
            if r.returncode != 0:
                print(f"wasm-probe: {f}: emit failed\n{r.stderr[-1500:]}")
                worst = 1
                continue
            ir = ll.read_text(encoding="utf-8")
        for name in exported(f.read_text(encoding="utf-8")):
            imp = imports(ir, name)
            status = "LEAF (0 imports)" if not imp else f"{len(imp)} imports: {', '.join(imp)}"
            print(f"wasm-probe: {f.relative_to(ROOT)}::{name}: {status}")
            if name not in parse(ir)[0]:
                print(f"wasm-probe:   (exported function not found in IR)")
                worst = 1
    return worst


def selftest() -> int:
    ir = """declare void @ext_io(i32)
declare float @llvm.fma.f32(float, float, float)
define float @k(float %a) {
  %1 = call float @helper(float %a)
  ret float %1
}
define float @helper(float %a) {
  %1 = call float @llvm.fma.f32(float %a, float %a, float %a)
  ret float %1
}
define i32 @main() {
  call void @ext_io(i32 1)
  ret i32 0
}
define float @k2(float %a) {
  call void @ext_io(i32 2)
  ret float %a
}
"""
    checks = [
        ("transitive callee, intrinsic ignored -> leaf", imports(ir, "k") == [], imports(ir, "k")),
        ("main's runtime import not charged to the kernel", "ext_io" not in imports(ir, "k"), imports(ir, "k")),
        ("direct external call counted", imports(ir, "k2") == ["ext_io"], imports(ir, "k2")),
        ("@export names found", exported("@export\ndef a(x: Int) abi(\"C\") -> Int:\n    return x\n") == ["a"], None),
    ]
    for name, ok, detail in checks:
        print(f"  [{'PASS' if ok else 'FAIL'}] wasm-probe selftest - {name} {detail if detail is not None else ''}")
    n = sum(1 for _, ok, _ in checks if ok)
    print(f"[{'PASS' if n == len(checks) else 'FAIL'}] wasm-probe selftest - {n} / {len(checks)} checks")
    return 0 if n == len(checks) else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    files = [ROOT / f for f in a.files] or sorted((ROOT / "tools/wasm").glob("kernel_*.mojo"))
    return run(files)


if __name__ == "__main__":
    sys.exit(main())
