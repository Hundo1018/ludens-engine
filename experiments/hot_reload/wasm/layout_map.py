"""Writable-data layout fingerprint from a wasm-ld link map (--Map=FILE).

The fingerprint covers what a memory transplant actually depends on: the
name, address and size of every symbol in the writable output sections
(.data, .bss) of the LINKED binary, after the optimizer has run. It is
derived from the binary's own link map, not from source declarations.

    python3 experiments/hot_reload/wasm/layout_map.py build/hot/v1/engine_hot.map
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path

WRITABLE = {".data", ".bss", ".tdata", ".tbss"}
LINE = re.compile(r"^\s*([0-9a-f-]+)\s+([0-9a-f-]+)\s+([0-9a-f]+) (\s*)(\S.*)$")


def writable_symbols(map_text: str) -> list[dict]:
    """[{section, name, addr, size}] for symbol lines inside writable sections."""
    out, section = [], None
    for line in map_text.splitlines():
        m = LINE.match(line)
        if not m:
            continue
        vma, _lma, size, indent, what = m.groups()
        level = len(indent) // 8
        if level == 0:
            section = what
        elif level == 2 and section in WRITABLE:
            out.append({"section": section, "name": what, "addr": int(vma, 16), "size": int(size, 16)})
    return out


def fingerprint(map_path: Path) -> dict:
    syms = writable_symbols(map_path.read_text())
    canon = "\n".join(f"{s['section']} {s['name']} {s['addr']:x} {s['size']:x}" for s in syms)
    return {"mapFingerprint": hashlib.sha256(canon.encode()).hexdigest()[:16], "symbols": syms}


if __name__ == "__main__":
    for p in sys.argv[1:]:
        print(json.dumps({"map": p, **fingerprint(Path(p))}, indent=2))
