#!/usr/bin/env python3
"""Retarget Mojo's host LLVM IR to wasm32 for LLVM 18's llc (W1).

Mojo 1.1.0 has no wasm backend: `mojo build --target-triple wasm32-...`
fails with "No available targets are compatible with triple". But
`mojo build --emit llvm` writes unoptimised, mostly target-neutral IR for
the host. This tool rewrites it so the existing back half (llc -> wasm-ld,
scripts/emit-and-link.sh) accepts it:

  1. `target triple` / `target datalayout` -> wasm32
  2. drop the host `"target-cpu"` / `"target-features"` / `"tune-cpu"`
     function attributes; a group left empty gets `"ludens-retarget"="1"`
     (a string attribute with no meaning to LLVM: llc rejects empty groups)
  3. delete `llvm.lifetime.start/end` calls and declarations: the newer
     LLVM form takes only a pointer, LLVM 18's takes (size, pointer), and
     they are optimisation hints only
  4. parse with llc; while it reports an attribute or flag it does not know
     (the IR comes from a newer LLVM than the system's LLVM 18), remove that
     token everywhere and try again. Seen so far: `nuw` on constant
     expressions, `captures(none)`, `nocreateundeforpoison`. Each only
     removes information (a poison flag or an attribute), which makes the IR
     weaker, never different in behaviour.

Every removal is printed and written to <out>.retarget.json, so what was
dropped is on record. What is NOT changed: Mojo's `Int` stays i64 (the
index type of the host); pointers become 32-bit through the datalayout,
and `ptrtoint ptr to i64` / `inttoptr i64` remain valid IR.

    python3 experiments/wasm_mojo/retarget_ir.py in.host.ll out.wasm32.ll
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

WASM32_TRIPLE = "wasm32-unknown-unknown"
WASM32_LAYOUT = "e-m:e-p:32:32-p10:8:8-p20:8:8-i64:64-n32:64-S128-ni:1:10:20"
HOST_ATTRS = re.compile(r'\s*"(target-cpu|target-features|tune-cpu)"="[^"]*"')
# llc: "<file>:<line>:<col>: error: <message>" then the source line and a caret
LLC_ERR = re.compile(r":(\d+):(\d+): error: ([^\n]+)")


def rewrite_target(text: str) -> str:
    text = re.sub(r'^target triple = "[^"]*"', f'target triple = "{WASM32_TRIPLE}"', text, flags=re.M)
    text = re.sub(r'^target datalayout = "[^"]*"', f'target datalayout = "{WASM32_LAYOUT}"', text, flags=re.M)
    text = HOST_ATTRS.sub("", text)
    text = re.sub(r"^\s*call void @llvm\.lifetime\.(start|end)\.p0\([^)]*\)\n", "", text, flags=re.M)
    text = re.sub(r"^declare void @llvm\.lifetime\.(start|end)\.p0\([^)]*\)[^\n]*\n", "", text, flags=re.M)
    return re.sub(r"^(attributes #\d+ = \{)\s*\}", r'\1 "ludens-retarget"="1" }', text, flags=re.M)


def token_at(line: str, col: int) -> str:
    m = re.match(r"[A-Za-z_][\w.-]*(\([^)]*\))?", line[col - 1:])
    return m.group(0) if m else ""


def parse_errors(ir: Path) -> tuple[int, int, str, str] | None:
    p = subprocess.run(["llc", "-march=wasm32", "-filetype=null", str(ir)], capture_output=True, text=True)
    if p.returncode == 0:
        return None
    m = LLC_ERR.search(p.stderr)
    if not m:
        raise SystemExit("llc failed without a parse location:\n" + p.stderr[:2000])
    line_no, col, msg = int(m.group(1)), int(m.group(2)), m.group(3)
    line = ir.read_text().splitlines()[line_no - 1]
    return line_no, col, msg, token_at(line, col)


def retarget(src: Path, dst: Path, max_rounds: int = 50) -> list[dict]:
    text = rewrite_target(src.read_text())
    removed: list[dict] = []
    for _ in range(max_rounds):
        dst.write_text(text)
        err = parse_errors(dst)
        if err is None:
            return removed
        line_no, col, msg, tok = err
        if not tok or tok in ("define", "declare", "call", "ret", "store", "load", "attributes", "target"):
            raise SystemExit(f"llc parse error not caused by an unknown attribute, line {line_no}: {msg}")
        # remove the token as an attribute word (with any parenthesised argument)
        pattern = re.compile(r"(?<![\w.@%$\"-])" + re.escape(tok) + r"(?![\w.-])")
        n = len(pattern.findall(text))
        text = pattern.sub("", text)
        removed.append({"token": tok, "occurrences": n, "llc_message": msg})
        print(f"retarget: removed {tok!r} x{n}  (llc: {msg})", flush=True)
    raise SystemExit("retarget: too many rounds")


def main() -> int:
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    removed = retarget(src, dst)
    Path(str(dst) + ".retarget.json").write_text(json.dumps(
        {"source": str(src), "triple": WASM32_TRIPLE, "datalayout": WASM32_LAYOUT, "removed": removed}, indent=2))
    print(f"retarget: {dst} parses with llc (-march=wasm32); {len(removed)} token kind(s) removed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
