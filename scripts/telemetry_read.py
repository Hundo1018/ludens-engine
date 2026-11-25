#!/usr/bin/env python3
"""Reference reader of the telemetry batch and crash report formats (docs/telemetry.md, issue #147).

    python3 scripts/telemetry_read.py FILE... [--map app.wasm.map]      one JSON object per file on stdout

It is written from the format tables in docs/telemetry.md, not from the Mojo or JS encoders, so a collector in any language
can be checked against it. A file starting with "LTEL" is a batch, "LCRS" a crash report; anything else, a bad checksum
or a length that does not add up is an error (exit 1). `--map` maps the crash frames that were not mapped when the
report was written (scripts/wasm_sourcemap.py makes the map). Standard library only."""
import argparse
import json
import sys
import uuid
from pathlib import Path

KINDS = {1: "level_start", 2: "level_end", 3: "death", 4: "purchase", 5: "setting_changed"}


def fnv1a64(data: bytes) -> int:
    h = 0xCBF29CE484222325
    for b in data:
        h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


class Reader:
    def __init__(self, data: bytes, end: int):
        self.d, self.at, self.end = data, 0, end

    def u(self, n: int, signed: bool = False) -> int:
        if self.at + n > self.end:
            raise ValueError(f"truncated at byte {self.at}")
        v = int.from_bytes(self.d[self.at:self.at + n], "little", signed=signed)
        self.at += n
        return v

    def raw(self, n: int) -> bytes:
        if self.at + n > self.end:
            raise ValueError(f"truncated at byte {self.at}")
        v = self.d[self.at:self.at + n]
        self.at += n
        return v

    def text(self, len_bytes: int) -> str:
        return self.raw(self.u(len_bytes)).decode("utf-8")


def decode(data: bytes) -> dict:
    if len(data) < 16:
        raise ValueError("truncated")
    end = len(data) - 8
    if fnv1a64(data[:end]) != int.from_bytes(data[end:], "little"):
        raise ValueError("checksum mismatch")
    r = Reader(data, end)
    magic = r.raw(4)
    fmt = r.u(2)
    r.u(2)  # flags
    if magic == b"LTEL":
        if fmt > 1:
            raise ValueError(f"batch format {fmt} is newer than this reader")
        out = {"type": "batch", "format": fmt, "install_id": str(uuid.UUID(bytes=r.raw(16))), "session_id": r.u(8),
               "seq": r.u(4), "dropped": r.u(4)}
        out["build_id"] = r.text(1)
        out["tags"] = {}
        for _ in range(r.u(1)):
            k = r.u(4)
            out["tags"][k] = r.u(4)
        out["events"] = []
        for _ in range(r.u(4)):
            kind, nv = r.u(2), r.u(1)
            r.u(1)
            ev = {"kind": kind, "name": KINDS.get(kind, "game" if kind >= 256 else "reserved"), "tick": r.u(8, True),
                  "time_ms": r.u(4), "key": r.u(8, True)}
            ev["values"] = [r.u(8, True) for _ in range(nv)]
            out["events"].append(ev)
    elif magic == b"LCRS":
        if fmt > 1:
            raise ValueError(f"crash format {fmt} is newer than this reader")
        ctx_len = r.u(4)
        ctx_end = r.at + ctx_len
        out = {"type": "crash", "format": fmt, "install_id": str(uuid.UUID(bytes=r.raw(16))), "build_id": r.text(1),
               "tick": r.u(8, True), "session_ms": r.u(4)}
        out["log"] = [r.text(2) for _ in range(r.u(2))]
        out["blackbox"] = r.raw(r.u(4))
        if r.at != ctx_end:
            raise ValueError("context length does not match its fields")
        out["reason"] = r.text(2)
        out["frames"] = []
        for _ in range(r.u(2)):
            f = {"func_index": r.u(4), "offset": r.u(4), "line": r.u(4), "column": r.u(4)}
            f["file"] = r.text(2)
            f["name"] = r.text(2)
            out["frames"].append(f)
    else:
        raise ValueError(f"unknown magic {magic!r}")
    if r.at != end:
        raise ValueError(f"{end - r.at} bytes after the last field")
    return out


def map_frames(report: dict, map_path: Path) -> int:
    """Fill file / line / column of the frames with line 0 from a wasm source map; how many were mapped."""
    import wasm_sourcemap  # scripts/, beside this file

    table = wasm_sourcemap.load_map(map_path)
    n = 0
    for f in report["frames"]:
        if f["line"] == 0:
            at = wasm_sourcemap.lookup(table, f["offset"])
            if at:
                f["file"], f["line"], f["column"] = at
                n += 1
    return n


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("files", nargs="+")
    ap.add_argument("--map")
    a = ap.parse_args(argv)
    rc = 0
    for p in a.files:
        try:
            out = decode(Path(p).read_bytes())
        except ValueError as e:
            print(f"{p}: {e}", file=sys.stderr)
            rc = 1
            continue
        if out["type"] == "crash":
            if a.map:
                map_frames(out, Path(a.map))
            out["blackbox"] = {"bytes": len(out["blackbox"]), "fnv1a64": f"{fnv1a64(out['blackbox']):016x}"}
        print(json.dumps({"file": p, **out}))
    return rc


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    sys.exit(main(sys.argv[1:]))
