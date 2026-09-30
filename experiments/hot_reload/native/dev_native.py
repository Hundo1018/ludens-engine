#!/usr/bin/env python3
"""Hot compile for the native Mojo engine: edit engine.mojo -> rebuild -> the
running live_host swaps the new build in.

  * polls the engine source every --interval seconds
  * rebuilds it with `mojo build --emit shared-lib` into <out>/<n>/libengine.so
    (a new path per build: dlopen of a loaded path returns the old library)
  * on success replaces <out>/latest atomically with "<n> <path>"; a failed
    build leaves `latest` alone, so the host keeps the last good module
  * with --run-host, also starts live_host on <out> and relays its output

    python3 experiments/hot_reload/native/dev_native.py --run-host
    # edit experiments/hot_reload/native/engine.mojo and save

Output lines (with the host's own lines interleaved):
    build version=N ok=1 build_s=1.23
    build version=N ok=0 build_s=0.41 error=<first compiler error line>
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_native import HERE, OUT, ROOT, mojo, precompile  # noqa: E402


def say(msg: str) -> None:
    print(msg, flush=True)


def build(source: Path, dest: Path) -> tuple[bool, float, str]:
    dest.parent.mkdir(parents=True, exist_ok=True)
    t0 = time.perf_counter()
    p = subprocess.run([mojo(), "build", "--emit", "shared-lib", "-I", "build", "-I", str(HERE), str(source),
                        "-o", str(dest)],
                       cwd=ROOT, capture_output=True, text=True)
    dt = time.perf_counter() - t0
    err = next((line for line in p.stderr.splitlines() if "error:" in line), p.stderr.strip()[:200])
    return p.returncode == 0 and dest.exists(), dt, err


def publish(out: Path, version: int, so: Path) -> None:
    tmp = out / "latest.tmp"
    tmp.write_text(f"{version} {so}\n")
    os.replace(tmp, out / "latest")


def ensure_host() -> Path:
    host = OUT / "live_host"
    src = [HERE / "live_host.mojo", HERE / "hotswap.mojo"]
    if not host.exists() or any(s.stat().st_mtime > host.stat().st_mtime for s in src):
        subprocess.run([mojo(), "build", "-I", "build", "-I", str(HERE), str(HERE / "live_host.mojo"),
                        "-o", str(host)], cwd=ROOT, check=True)
    return host


def relay(proc: subprocess.Popen) -> None:
    for line in proc.stdout:
        say(line.rstrip("\n"))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", default=str(HERE / "engine.mojo"))
    ap.add_argument("--out", default=str(OUT / "dev"))
    ap.add_argument("--interval", type=float, default=0.1)
    ap.add_argument("--run-host", action="store_true", help="start live_host on --out and relay its output")
    ap.add_argument("--seconds", type=int, default=600, help="host run time limit")
    ap.add_argument("--keep", type=int, default=3, help="old build directories to keep")
    a = ap.parse_args()

    source, out = Path(a.source).resolve(), Path(a.out).resolve()
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    if not (ROOT / "build" / "ecs.mojoc").exists():
        precompile()

    host = None
    if a.run_host:
        host = subprocess.Popen([str(ensure_host()), str(out), str(a.seconds)], cwd=ROOT,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        threading.Thread(target=relay, args=(host,), daemon=True).start()

    version, seen = 0, None
    try:
        while host is None or host.poll() is None:
            if (out / "stop").exists():
                break
            mtime = source.stat().st_mtime_ns
            if mtime != seen:
                seen = mtime
                version += 1
                so = out / str(version) / "libengine.so"
                ok, dt, err = build(source, so)
                if ok:
                    publish(out, version, so)
                    say(f"build version={version} ok=1 build_s={dt:.2f}")
                    for old in range(1, version - a.keep):
                        shutil.rmtree(out / str(old), ignore_errors=True)
                else:
                    say(f"build version={version} ok=0 build_s={dt:.2f} error={err}")
            time.sleep(a.interval)
    except KeyboardInterrupt:
        pass
    finally:
        (out / "stop").touch()
        if host is not None:
            host.wait(timeout=10)
    return 0


if __name__ == "__main__":
    sys.exit(main())
