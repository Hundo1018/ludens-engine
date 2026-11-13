#!/usr/bin/env python3
"""Several wasm modules in Web Workers: does it work on a host without COOP/COEP, and what does it cost?

Builds app/zone_main.mojo natively (serial engine, the reference hashes) and as zone.wasm, serves it with
shell/web/zone_worker.ts and the probe page the way GitHub Pages does (no COOP/COEP), and runs the page in headless
Chrome. Fails unless every worker reproduces the native hash and every zone ticks with 1, 2, 3 and 4 workers.
Prints a table of the measurements and writes build/multi_wasm_probe.json.

Run: pixi run -e wasm multi-wasm-probe [--bodies 1000] [--live 1000]"""
import argparse
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

import ludens_wasm_rt

ROOT = Path(__file__).resolve().parent.parent
D = ROOT / "build/deps"
OUT = ROOT / "build/zone_probe"
PORT = 8143
sys.path.insert(0, str(ROOT / "scripts"))
from bench import serial_engine  # noqa: E402
from build_web import STRIP  # noqa: E402


def build_zone(engine: Path, *extra: str) -> None:
    cmd = [sys.executable, "-m", "ludens_wasm_rt.build_wasm", "--lib", str(engine), "--lib", ".", "-I", str(engine), "-I", ".",
           "app/zone_main.mojo", *extra]
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if proc.returncode:
        sys.exit(proc.stdout + proc.stderr)


def build_site() -> None:
    """build/zone_probe: zone.wasm, the worker, the probe page and the shared host."""
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)
    build_zone(D / "ludens-core", "--target", "wasm64", "-o", str(OUT / "zone.wasm"), "--export", "app_zone_*")
    shutil.copy(ludens_wasm_rt.HOST_MJS, OUT / "host.mjs")
    shutil.copy(ROOT / "shell/web/zone_probe.html", OUT / "zone_probe.html")
    for ts in ("zone_worker.ts", "zone_probe.ts"):
        subprocess.run(["node", "--input-type=module", "-e", STRIP, str(ROOT / "shell/web" / ts), str(OUT / ts.replace(".ts", ".js"))],
                       check=True, stderr=subprocess.DEVNULL)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bodies", type=int, default=1000, help="bodies per zone for the hash comparison (the native build prints 1000)")
    ap.add_argument("--live", type=int, default=1000, help="bodies per zone in the timed part")
    args = ap.parse_args()
    chrome = shutil.which("google-chrome") or shutil.which("chromium")
    if not chrome:
        sys.exit("multi-wasm-probe: no Chrome found")
    subprocess.run(["bash", "scripts/deps.sh"], cwd=ROOT, check=True)
    import native_libs  # the static libraries wasm.toml [native] links (a clean checkout has none)
    native_libs.build_all()
    (ROOT / "build").mkdir(exist_ok=True)
    build_zone(serial_engine(), "--target", "native", "-o", "build/zone_native")
    native = subprocess.run([str(ROOT / "build/zone_native")], capture_output=True, text=True, check=True).stdout
    hashes = re.findall(r"seed (\d+) ticks 120 hash (\d+)", native)
    assert hashes, native
    print("native :", ", ".join(f"seed {s} {h}" for s, h in hashes))
    build_site()
    print(f"zone.wasm: {(OUT / 'zone.wasm').stat().st_size} bytes")
    server = subprocess.Popen([sys.executable, "shell/web/serve.py", str(PORT), str(OUT), "plain"], cwd=ROOT,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(2)
        url = f"http://127.0.0.1:{PORT}/zone_probe.html?n={args.bodies};live={args.live};expect={','.join(h for _, h in hashes)}"
        r = subprocess.run(["node", "scripts/web_cdp.mjs", chrome, url, "150"], cwd=ROOT, capture_output=True, text=True)
    finally:
        server.kill()
    line = next((l for l in r.stdout.splitlines() if l.startswith("{")), "")
    if not line:
        print(r.stdout[-3000:])
        return 1
    data = json.loads(line)
    (ROOT / "build/multi_wasm_probe.json").write_text(json.dumps(data, indent=1) + "\n")
    print(f"page   : cross-origin isolated {data['isolated']}, hardwareConcurrency {data['cores']}")
    for h in data["hashes"]:
        same = "equal" if (str(h["seed"]), h["hash"]) in hashes else "DIFFERENT"
        print(f"worker : seed {h['seed']} {h['hash']} {same}; load {h['loadMs']} ms, tick {h['tickMs']} ms, memory {h['memoryMiB']} MiB")
    print(f"\n{args.live} bodies per zone, 60 Hz asked, 3 s each:")
    print("| workers | ticks/s per worker | tick ms median (max) | transfer ms median (max) | floats/msg | MiB per module | page frame ms median (max) |")
    print("|---:|:--|:--|:--|---:|:--|:--|")
    for v in data["live"]:
        pair = lambda a, b: ", ".join(f"{x} ({y})" for x, y in zip(v[a], v[b]))
        print(f"| {v['workers']} | {', '.join(str(t) for t in v['ticksPerSecond'])} | {pair('tickMsMedian', 'tickMsMax')} | "
              f"{pair('transferMsMedian', 'transferMsMax')} | {v['floatsPerMessage']} | {', '.join(str(m) for m in v['memoryMiB'])} | "
              f"{v['pageFrameMsMedian']} ({v['pageFrameMsMax']}) |")
    t = data["transfer"]
    print(f"\ntransfer alone: {t['received']} buffers of {t['floats']} f32 ({t['floats'] // 8} items): median {t['msMedian']} ms, max {t['msMax']} ms")
    verdict = next((l for l in r.stdout.splitlines() if l.startswith("test-web:")), "test-web: no verdict")
    print("\nmulti-wasm-probe:", verdict.split(":", 1)[1].strip())
    return r.returncode


if __name__ == "__main__":
    sys.exit(main())
