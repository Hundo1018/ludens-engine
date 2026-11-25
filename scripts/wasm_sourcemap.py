#!/usr/bin/env python3
"""A wasm source map from a module's DWARF line tables, and the module without its debug sections (issue #147).

    python3 scripts/wasm_sourcemap.py build/app_debug.wasm -o build/app.wasm --map build/app.wasm.map [--root .]

The input is a module built with `build_wasm --debug line-tables` (the code is byte-identical to a build without it).
The output module is that module with every `.debug_*` section removed (llvm-objcopy --strip-debug); the map is Source
Map v3 in the form browsers and emscripten use for wasm: one generated line, and a segment's generated column is a
byte offset in the module, which is what a stack trace prints (`wasm-function[12]:0x3f2`). DWARF addresses in a wasm
module count from the start of the code section's body, so each is moved by that offset; the script checks that the
stripped module's code section starts at the same byte as the input's, so the map fits the module that ships.

File names under `--root` are written relative to it; the rest (the Mojo standard library) as DWARF gives them.
`load_map` and `lookup` are used by scripts/telemetry_read.py to map the frames of a crash report."""
import argparse
import bisect
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


def tool(name: str) -> str:
    path = shutil.which(name)
    if not path:
        sys.exit(f"wasm_sourcemap: {name} not found (run inside `pixi run -e wasm`)")
    return path


def _leb(data: bytes, at: int) -> tuple[int, int]:
    v = shift = 0
    while True:
        b = data[at]
        at += 1
        v |= (b & 0x7F) << shift
        shift += 7
        if not b & 0x80:
            return v, at


def code_body_offset(data: bytes) -> int:
    """Byte offset of the first byte after the code section's id and size (where DWARF address 0 lies)."""
    if data[:4] != b"\0asm":
        raise ValueError("not a wasm module")
    at = 8
    while at < len(data):
        sid = data[at]
        size, body = _leb(data, at + 1)
        if sid == 10:
            return body
        at = body + size
    raise ValueError("no code section")


def line_rows(dwarfdump_out: str) -> list[tuple[int, str, int, int]]:
    """(address, file, line, column) for every row of every line table, from `llvm-dwarfdump --debug-line`."""
    rows = []
    dirs: dict[int, str] = {}
    files: dict[int, tuple[str, int]] = {}
    cur_file = None
    row = re.compile(r"^0x([0-9a-f]+)\s+(\d+)\s+(\d+)\s+(\d+)\s")
    for line in dwarfdump_out.splitlines():
        if line.startswith("debug_line["):
            dirs, files, cur_file = {}, {}, None
            continue
        m = re.match(r'include_directories\[\s*(\d+)\] = "(.*)"', line)
        if m:
            dirs[int(m.group(1))] = m.group(2)
            continue
        m = re.match(r"file_names\[\s*(\d+)\]:", line)
        if m:
            cur_file = int(m.group(1))
            files[cur_file] = ("", 0)
            continue
        if cur_file is not None:
            m = re.match(r'\s+name: "(.*)"', line)
            if m:
                files[cur_file] = (m.group(1), files[cur_file][1])
                continue
            m = re.match(r"\s+dir_index: (\d+)", line)
            if m:
                files[cur_file] = (files[cur_file][0], int(m.group(1)))
                continue
        m = row.match(line)
        if m:
            cur_file = None
            addr, ln, col, fi = int(m.group(1), 16), int(m.group(2)), int(m.group(3)), int(m.group(4))
            if ln == 0 or "end_sequence" in line:
                continue
            name, di = files.get(fi, ("?", 0))
            d = dirs.get(di, "")
            rows.append((addr, f"{d}/{name}" if d else name, ln, col))
    return rows


def _vlq(v: int) -> str:
    v = (-v << 1) | 1 if v < 0 else v << 1
    out = ""
    while True:
        digit = v & 31
        v >>= 5
        out += B64[digit | (32 if v else 0)]
        if not v:
            return out


def _unvlq(s: str) -> list[int]:
    out, v, shift = [], 0, 0
    for ch in s:
        d = B64.index(ch)
        v |= (d & 31) << shift
        if d & 32:
            shift += 5
            continue
        out.append(-(v >> 1) if v & 1 else v >> 1)
        v = shift = 0
    return out


def build_map(rows: list[tuple[int, str, int, int]], code_off: int, root: Path | None, wasm_name: str) -> dict:
    sources: list[str] = []
    index: dict[str, int] = {}
    seen = {}
    for addr, f, ln, col in rows:  # one row per address: the last row for an address wins, as in a DWARF line table
        seen[addr] = (f, ln, col)
    segs = []
    prev = [0, 0, 0, 0]
    for addr in sorted(seen):
        f, ln, col = seen[addr]
        if root is not None:
            try:
                f = str(Path(f).resolve().relative_to(root))
            except ValueError:
                pass
        if f not in index:
            index[f] = len(sources)
            sources.append(f)
        cur = [code_off + addr, index[f], ln - 1, max(col - 1, 0)]
        segs.append("".join(_vlq(c - p) for c, p in zip(cur, prev, strict=True)))
        prev = cur
    return {"version": 3, "file": wasm_name, "sources": sources, "names": [], "mappings": ",".join(segs)}


def load_map(path: Path) -> tuple[list[int], list[tuple[str, int, int]]]:
    """(sorted offsets, (file, line, column) per offset) from a wasm source map; lines and columns 1-based."""
    m = json.loads(Path(path).read_text())
    offs, where = [], []
    cur = [0, 0, 0, 0]
    for seg in m["mappings"].split(","):
        if not seg:
            continue
        d = _unvlq(seg)
        for i, x in enumerate(d[:4]):
            cur[i] += x
        if len(d) >= 4:
            offs.append(cur[0])
            where.append((m["sources"][cur[1]], cur[2] + 1, cur[3] + 1))
    return offs, where


def lookup(table: tuple[list[int], list[tuple[str, int, int]]], offset: int) -> tuple[str, int, int] | None:
    """The row at or before `offset`, the way a debugger maps a return address."""
    offs, where = table
    i = bisect.bisect_right(offs, offset) - 1
    return where[i] if i >= 0 else None


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("wasm")
    ap.add_argument("-o", dest="out", required=True, help="the module without debug sections")
    ap.add_argument("--map", required=True)
    ap.add_argument("--root", default=".")
    a = ap.parse_args(argv)
    src = Path(a.wasm)
    data = src.read_bytes()
    code_off = code_body_offset(data)
    dump = subprocess.run([tool("llvm-dwarfdump"), "--debug-line", str(src)], capture_output=True, text=True, check=True).stdout
    rows = line_rows(dump)
    if not rows:
        sys.exit(f"wasm_sourcemap: {src} has no line table (build it with --debug line-tables)")
    subprocess.run([tool("llvm-objcopy"), "--strip-debug", str(src), a.out], check=True)
    stripped = Path(a.out).read_bytes()
    if code_body_offset(stripped) != code_off:
        sys.exit(f"wasm_sourcemap: the code section moved when stripping ({code_off} -> {code_body_offset(stripped)})")
    m = build_map(rows, code_off, Path(a.root).resolve(), Path(a.out).name)
    Path(a.map).write_text(json.dumps(m))
    print(f"wasm_sourcemap: {len(rows)} line rows, {len(m['sources'])} files, code at byte {code_off}; "
          f"{a.out} {len(stripped):,} bytes (debug build {len(data):,}), {a.map} {Path(a.map).stat().st_size:,} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
