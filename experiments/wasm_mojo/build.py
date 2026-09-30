#!/usr/bin/env python3
"""W1: build a wasm module from a Mojo source.

  mojo build --emit llvm (host IR)  ->  retarget_ir.py (wasm32 IR)
  ->  scripts/emit-and-link.sh (llc -> wasm-ld, with the C runtime shims)

    python3 experiments/wasm_mojo/build.py [core|probe_int] [--out build/wasm_mojo/core.wasm]

Prints the external symbols the retargeted IR declares, so a missing runtime
function shows up here rather than as a wasm import at run time.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = ROOT / "build" / "wasm_mojo"
sys.path.insert(0, str(HERE))
from retarget_ir import retarget  # noqa: E402

EXPORTS = {
    "core": ["ss_create", "ss_add", "ss_contains", "ss_remove", "ss_len", "ss_dense_at", "ss_dense_ptr",
             "ss_key_bytes", "mojo_rt_heap_used"],
    "probe_int": ["add", "sum_to"],
}
SHIMS = [ROOT / "toolchain" / "standin" / "wasm_rt.c", HERE / "mojo_rt.c"]


def mojo() -> str:
    cand = ROOT / ".venv" / "bin" / "mojo"
    return str(cand) if cand.exists() else "mojo"


def build(name: str, out: Path) -> Path:
    (OUT / "ir").mkdir(parents=True, exist_ok=True)
    host_ll = OUT / f"{name}.host.ll"
    subprocess.run([mojo(), "build", "--emit", "llvm", "-I", str(ROOT / "build"), str(HERE / f"{name}.mojo"),
                    "-o", str(host_ll)], cwd=ROOT, check=True)
    ir = OUT / "ir" / f"{name}.ll"
    retarget(host_ll, ir)
    externs = sorted({m for m in re.findall(r"^declare [^@]*@([\w.]+)\(", ir.read_text(), re.M)
                      if not m.startswith("llvm.")})
    print(f"external symbols: {', '.join(externs) or '-'}")
    cmd = ["bash", "scripts/emit-and-link.sh", "--out", str(out)]
    for e in EXPORTS[name]:
        cmd += ["--export", e]
    cmd += [str(ir)] + ([str(s) for s in SHIMS] if name == "core" else [])
    subprocess.run(cmd, cwd=ROOT, check=True)
    imports = subprocess.run(["node", "-e", f"""
const m = new WebAssembly.Module(require('fs').readFileSync('{out}'));
console.log(WebAssembly.Module.imports(m).map(i => i.module + '.' + i.name).join(', ') || '-');"""],
                             capture_output=True, text=True, check=True).stdout.strip()
    print(f"wasm imports: {imports}")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("name", nargs="?", default="core", choices=list(EXPORTS))
    ap.add_argument("--out")
    a = ap.parse_args()
    build(a.name, Path(a.out) if a.out else OUT / f"{a.name}.wasm")
    return 0


if __name__ == "__main__":
    sys.exit(main())
