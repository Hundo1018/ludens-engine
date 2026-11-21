#!/usr/bin/env python3
"""Can a Python behaviour script run in the browser beside the engine's wasm64 module? (docs/scene-format.md)

    pixi run -e wasm python3 scripts/python_web_probe.py              # build if needed, run native + node + Chrome
    pixi run -e wasm python3 scripts/python_web_probe.py --no-browser # native and node only
    pixi run -e wasm python3 scripts/python_web_probe.py --rebuild    # rebuild the module and the native library

The engine ships as one wasm64 module; CPython for the web (Pyodide) is a wasm32 module, so the two cannot be linked
together. This probe loads them side by side and lets Python call the engine's C-ABI exports through a JS object
(scripts/python_web_probe.mjs). The same behaviour source runs natively under this interpreter with ctypes against
the same C-ABI built as a shared library from the same pinned ludens-core.

Measured: what Pyodide makes a page download, time to the first world hash, the cost of a call in each direction,
whether the world hash after 600 ticks equals the native one (with and without math.sin in the script), and how many
results of math.* differ in their bits between the two interpreters.

Everything is built into build/py_probe/. Pyodide comes from npm (`pyodide`, the version pinned below)."""
import argparse
import base64
import ctypes
import gzip
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build/py_probe"
CORE = ROOT / "build/deps/ludens-core"
PYODIDE = "314.0.8"
PORT = 8147
TICKS = 600
CALLS = 200000
TABLE = 20000
RUNTIME_FILES = ["pyodide.mjs", "pyodide.asm.mjs", "pyodide.asm.wasm", "python_stdlib.zip", "pyodide-lock.json"]

# The behaviour: plain Python against an object with new_world / add_box / add_sphere / impulse / step / tick / hash.
# It is the only script either side runs; neither host is named in it.
BEHAVIOUR = '''
import math, struct, time

def build(eng):
    eng.new_world()
    eng.add_box(0.0, -0.5, 0.0, 20.0, 0.5, 20.0, 0.0, 1)
    ball = eng.add_sphere(0.0, 5.0, 0.0, 0.5, 1.0, 0)
    for i in range(10):
        eng.add_box(2.0, 0.5 + i * 1.0, 0.0, 0.5, 0.5, 0.5, 1.0, 0)
    return ball

def system_plain(eng, ball, tick):
    eng.impulse(ball, 0.05 * ((tick % 7) - 3), 0.2 if tick % 30 == 0 else 0.0, 0.0)

def system_sin(eng, ball, tick):
    eng.impulse(ball, 0.1 * math.sin(tick * 0.1), 0.0, 0.1 * math.cos(tick * 0.07))

def run(eng, system, ticks):
    ball = build(eng)
    for t in range(ticks):
        system(eng, ball, t)
        eng.step(1)
    return eng.hash()

def noop(i):
    return i

def bench_calls(eng, n):
    tick = eng.tick
    for _ in range(2000):
        tick()
    t0 = time.perf_counter()
    for _ in range(n):
        tick()
    return time.perf_counter() - t0

def math_tables(n):
    xs = [(i * 0.6180339887498949) % 100.0 + 0.001 for i in range(n)]
    fns = {"sin": math.sin, "cos": math.cos, "tan": math.tan, "exp": lambda x: math.exp(x * 0.1), "log": math.log,
           "pow": lambda x: x ** 1.3, "atan2": lambda x: math.atan2(x, 3.0), "sqrt": math.sqrt}
    return {name: struct.pack("<%dd" % n, *[f(x) for x in xs]) for name, f in fns.items()}
'''


def run_cmd(cmd, **kw):
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, **kw)
    if proc.returncode:
        sys.exit(f"python_web_probe: {' '.join(map(str, cmd))}\n{proc.stdout[-3000:]}{proc.stderr[-3000:]}")
    return proc.stdout


def build(rebuild: bool) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(["bash", "scripts/deps.sh"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    wasm, lib = OUT / "ludens64.wasm", OUT / "libludens.so"
    if rebuild or not wasm.exists():
        run_cmd([sys.executable, "-m", "ludens_wasm_rt.build_wasm", "--lib", str(CORE), str(CORE / "embed/capi.mojo"),
                 "-I", str(CORE), "-o", str(wasm), "--export", "ld_*"])
    if rebuild or not lib.exists():
        sys.path.insert(0, str(ROOT / "scripts"))
        import native_libs
        mojo = Path(os.environ["CONDA_PREFIX"]) / "bin/mojo"
        # --target-cpu x86-64: the reference build, no FMA, the one the wasm module must hash like
        run_cmd([str(mojo), "build", "--emit", "shared-lib", "--target-cpu", "x86-64", "-I", str(CORE), "-o", str(lib),
                 str(CORE / "embed/capi.mojo")], env=native_libs.native_env())
    if not (OUT / "node_modules/pyodide/pyodide.asm.wasm").exists():
        run_cmd(["npm", "install", "--no-audit", "--no-fund", "--silent", "--prefix", str(OUT), f"pyodide@{PYODIDE}"])
    (OUT / "behaviour.py").write_text(BEHAVIOUR)


class NativeEngine:
    """The same seven calls the JS object offers, on the shared library through ctypes."""

    def __init__(self, path: Path):
        L = ctypes.CDLL(str(path))
        f32, i32, i64, p = ctypes.c_float, ctypes.c_int32, ctypes.c_int64, ctypes.c_void_p
        sig = {"ld_world_create": (i32, [ctypes.c_double, f32, f32, f32, ctypes.POINTER(p)]),
               "ld_world_destroy": (i32, [p]), "ld_world_tick": (i64, [p]),
               "ld_body_add_box": (i64, [p, f32, f32, f32, f32, f32, f32, f32, i32]),
               "ld_body_add_sphere": (i64, [p, f32, f32, f32, f32, f32, i32]),
               "ld_body_apply_impulse": (i32, [p, i64, f32, f32, f32]),
               "ld_world_step_ticks": (i32, [p, i32]), "ld_world_hash": (i32, [p, ctypes.POINTER(ctypes.c_uint64)])}
        for name, (res, args) in sig.items():
            fn = getattr(L, name)
            fn.restype, fn.argtypes = res, args
        self.L, self.w = L, p(None)

    def new_world(self):
        if self.w:
            self.L.ld_world_destroy(self.w)
        w = ctypes.c_void_p()
        if self.L.ld_world_create(1 / 60, 0.0, -9.81, 0.0, ctypes.byref(w)) != 0:
            raise RuntimeError("ld_world_create")
        self.w = w

    def add_box(self, px, py, pz, hx, hy, hz, mass, fixed):
        return self.L.ld_body_add_box(self.w, px, py, pz, hx, hy, hz, mass, fixed)

    def add_sphere(self, px, py, pz, r, mass, fixed):
        return self.L.ld_body_add_sphere(self.w, px, py, pz, r, mass, fixed)

    def impulse(self, b, x, y, z):
        return self.L.ld_body_apply_impulse(self.w, b, x, y, z)

    def step(self, n):
        return self.L.ld_world_step_ticks(self.w, n)

    def tick(self):
        return self.L.ld_world_tick(self.w)

    def hash(self):
        out = ctypes.c_uint64()
        if self.L.ld_world_hash(self.w, ctypes.byref(out)) != 0:
            raise RuntimeError("ld_world_hash")
        return f"{out.value:016x}"


def native() -> dict:
    eng = NativeEngine(OUT / "libludens.so")
    g: dict = {}
    exec(BEHAVIOUR, g)
    out = {"runtime": "CPython " + sys.version.split()[0], "pythonVersion": sys.version.split()[0]}
    out["hashPlain"] = g["run"](eng, g["system_plain"], TICKS)
    out["hashSin"] = g["run"](eng, g["system_sin"], TICKS)
    eng.new_world()
    out["pyToEngineNs"] = g["bench_calls"](eng, CALLS) * 1e9 / CALLS
    ball, system = g["build"](eng), g["system_plain"]
    for i in range(2000):
        system(eng, ball, i)
    t0 = time.perf_counter()
    for i in range(CALLS):
        system(eng, ball, i)
    out["callbackNs"] = (time.perf_counter() - t0) * 1e9 / CALLS
    t0 = time.perf_counter()
    eng.step(600)
    out["engineTickUs"] = (time.perf_counter() - t0) * 1e6 / 600
    tables = g["math_tables"](TABLE)
    out["tables"] = {k: hashlib.sha256(v).hexdigest() for k, v in tables.items()}
    out["raw"] = tables
    return out


def host_mjs() -> Path:
    import ludens_wasm_rt
    return Path(ludens_wasm_rt.HOST_MJS)


def node() -> dict:
    text = run_cmd(["node", "scripts/python_web_probe.mjs", str(host_mjs()), str(OUT / "ludens64.wasm"),
                    str(OUT / "node_modules/pyodide"), str(OUT / "behaviour.py"), "raw"])
    data = json.loads(next(l for l in text.splitlines() if l.startswith("{")))
    data["raw"] = {k: base64.b64decode(v) for k, v in data["raw"].items()}
    return data


PAGE = """<!doctype html><meta charset="utf-8"><title>running</title><pre id="log"></pre>
<script type="module">
import { run } from './python_web_probe.mjs';
try {
  const source = await (await fetch('behaviour.py')).text();
  const r = await run({ hostUrl: new URL('host.mjs', location.href).href, wasm: fetch('ludens64.wasm'),
    pyodideUrl: new URL('node_modules/pyodide/', location.href).href, source, ticks: %d, calls: %d, tableSize: %d });
  r.runtime = navigator.userAgent.match(/Chrome\\/[0-9.]+/)?.[0] ?? navigator.userAgent;
  r.resources = performance.getEntriesByType('resource').map((e) => [e.name.split('/').pop(), e.decodedBodySize]);
  document.getElementById('log').textContent = JSON.stringify(r);
  document.title = 'PASS';
} catch (e) { document.getElementById('log').textContent = String(e.stack ?? e); document.title = 'FAIL'; }
</script>
"""


def browser() -> dict | str:
    chrome = shutil.which("google-chrome") or shutil.which("chromium")
    if not chrome:
        return "no Chrome on PATH"
    (OUT / "index.html").write_text(PAGE % (TICKS, CALLS, TABLE))
    shutil.copy(host_mjs(), OUT / "host.mjs")
    shutil.copy(ROOT / "scripts/python_web_probe.mjs", OUT / "python_web_probe.mjs")
    server = subprocess.Popen([sys.executable, "-m", "http.server", str(PORT), "--bind", "127.0.0.1", "--directory", str(OUT)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(1.5)
        r = subprocess.run(["node", "scripts/web_cdp.mjs", chrome, f"http://127.0.0.1:{PORT}/index.html", "240"], cwd=ROOT,
                           capture_output=True, text=True)
    finally:
        server.kill()
    line = next((l for l in r.stdout.splitlines() if l.startswith("{")), "")
    return json.loads(line) if line else "the page did not finish: " + r.stdout[-1500:].strip()


def ulps(a: bytes, b: bytes) -> tuple[int, int, int]:
    """How many doubles differ in their bits, the largest difference in units in the last place, and how many
    still differ once rounded to float32 (what the C-ABI's float arguments receive)."""
    n = len(a) // 8
    ia, ib = struct.unpack(f"<{n}q", a), struct.unpack(f"<{n}q", b)
    diffs = [abs(x - y) for x, y in zip(ia, ib) if x != y]
    fa, fb = struct.unpack(f"<{n}d", a), struct.unpack(f"<{n}d", b)
    single = sum(1 for x, y in zip(fa, fb) if struct.pack("<f", x) != struct.pack("<f", y))
    return len(diffs), max(diffs, default=0), single


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--rebuild", action="store_true")
    ap.add_argument("--no-browser", action="store_true")
    args = ap.parse_args()
    build(args.rebuild)

    nat, web = native(), node()
    page = "skipped (--no-browser)" if args.no_browser else browser()
    sides = [("native: " + nat["runtime"] + " + ctypes", nat), ("node: Pyodide " + web["pythonVersion"] + " on " + web["runtime"], web)]
    if isinstance(page, dict):
        sides.append(("page: Pyodide on " + page["runtime"], page))

    print(f"python_web_probe: ludens-core {(CORE / '.rev').read_text().strip()[:8]}, pyodide {PYODIDE}, "
          f"engine module {(OUT / 'ludens64.wasm').stat().st_size} bytes\n")
    print("### What Pyodide adds to the download\n\n| file | bytes | gzip -6 |\n|---|---:|---:|")
    total = gz = 0
    for name in RUNTIME_FILES:
        data = (OUT / "node_modules/pyodide" / name).read_bytes()
        z = len(gzip.compress(data, 6))
        total, gz = total + len(data), gz + z
        print(f"| {name} | {len(data)} | {z} |")
    print(f"| total | {total} | {gz} |")
    wasm = (OUT / "ludens64.wasm").read_bytes()
    print(f"| for scale: the engine's C-ABI module | {len(wasm)} | {len(gzip.compress(wasm, 6))} |")
    if isinstance(page, dict):
        fetched = sorted((n, s) for n, s in page["resources"] if s)
        print("\nFetched by the page: " + ", ".join(f"{n} {s}" for n, s in fetched)
              + f" (sum {sum(s for _, s in fetched)} bytes).")
    else:
        print(f"\nPage run: {page}")

    print("\n### Time\n\n| where | engine load ms | Pyodide load ms | start to first world hash ms | "
          "Python -> engine call ns | JS -> Python call ns | one behaviour call ns | engine tick µs (12 bodies) |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|")
    f = lambda d, k, digits=0: f"{d[k]:.{digits}f}" if k in d else "n/a"
    for name, d in sides:
        print(f"| {name} | {f(d, 'engineLoadMs')} | {f(d, 'pyodideLoadMs')} | {f(d, 'startToFirstHashMs')} | "
              f"{f(d, 'pyToEngineNs')} | {f(d, 'jsToPyNs')} | {f(d, 'callbackNs')} | {f(d, 'engineTickUs', 1)} |")

    print(f"\n### World hash after {TICKS} ticks, the script applying an impulse every tick\n")
    print("| where | arithmetic only | with math.sin / math.cos |\n|---|---|---|")
    for name, d in sides:
        print(f"| {name} | {d['hashPlain']} | {d['hashSin']} |")
    same_plain = all(d["hashPlain"] == nat["hashPlain"] for _, d in sides)
    same_sin = all(d["hashSin"] == nat["hashSin"] for _, d in sides)

    print(f"\n### math.* on {TABLE} inputs: results whose bits differ from native CPython\n")
    print("| function | node: differing | largest difference (ulp) | still differing as float32 | page table equals node's |\n|---|---:|---:|---:|---|")
    any_diff = 0
    for name in nat["raw"]:
        count, worst, single = ulps(nat["raw"][name], web["raw"][name])
        any_diff += count
        same = (page["tables"][name] == web["tables"][name]) if isinstance(page, dict) else "n/a"
        print(f"| {name} | {count} | {worst} | {single} | {same} |")

    budget = 16.667e6 * 0.01  # 1 % of a 60 Hz frame, in ns
    print("\n### Against the criterion written before the run\n")
    print("Criterion: hashes equal, and 1000 behaviour calls within 1 % of a 16.7 ms tick (166.7 ns each).\n")
    print("| where | hash equal (arithmetic) | hash equal (math.sin) | one behaviour call ns | calls that fit in 1 % of a tick | 1000 calls within budget |")
    print("|---|---|---|---:|---:|---|")
    for name, d in sides:
        print(f"| {name} | {d['hashPlain'] == nat['hashPlain']} | {d['hashSin'] == nat['hashSin']} | {d['callbackNs']:.0f} | "
              f"{int(budget / d['callbackNs'])} | {d['callbackNs'] * 1000 <= budget} |")
    print(f"\nsummary: arithmetic hash equal on every host: {same_plain}; math.sin hash equal: {same_sin}; "
          f"math results differing in node: {any_diff} of {TABLE * len(nat['raw'])}")
    (OUT / "result.json").write_text(json.dumps({k: {x: y for x, y in d.items() if x != "raw"} for k, d in sides}, indent=1) + "\n")
    return 0 if same_plain else 1


if __name__ == "__main__":
    sys.exit(main())
