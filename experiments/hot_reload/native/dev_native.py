#!/usr/bin/env python3
"""Hot compile for the native Mojo engine: edit engine.mojo, or a package it
imports -> rebuild -> the running live_host swaps the new build in.

  * polls the engine source and every .mojo file of the packages it imports
    (run_native.PACKAGES under --packages-root) every --interval seconds
  * a changed package is re-precompiled into --include, followed by every
    package that imports it (directly or not), in dependency order (H5);
    then the engine is rebuilt with `mojo build --emit shared-lib` into
    <out>/<n>/libengine.so (a new path per build: dlopen of a loaded path
    returns the old library)
  * on success replaces <out>/latest atomically with "<n> <path>"; a failed
    build leaves `latest` alone, so the host keeps the last good module
  * with --run-host, also starts live_host on <out> and relays its output

    python3 experiments/hot_reload/native/dev_native.py --run-host
    # edit experiments/hot_reload/native/engine.mojo, or ecs/, and save

Output lines (with the host's own lines interleaved):
    build version=N ok=1 build_s=1.23 pkgs=ecs pkg_s=0.80 engine_s=0.43
    build version=N ok=0 build_s=0.41 pkgs=- error=<first compiler error line>
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_native import HERE, OUT, PACKAGES, ROOT, mojo  # noqa: E402


_SAY = threading.Lock()


def say(msg: str) -> None:
    """One line per call: the host relay thread prints too."""
    with _SAY:
        sys.stdout.write(msg + "\n")
        sys.stdout.flush()


def first_error(stderr: str) -> str:
    return next((line for line in stderr.splitlines() if "error:" in line), stderr.strip()[:200])


def build(source: Path, dest: Path, include: Path) -> tuple[bool, float, str]:
    dest.parent.mkdir(parents=True, exist_ok=True)
    t0 = time.perf_counter()
    p = subprocess.run([mojo(), "build", "--emit", "shared-lib", "-I", str(include), "-I", str(HERE), str(source),
                        "-o", str(dest)], cwd=ROOT, capture_output=True, text=True)
    dt = time.perf_counter() - t0
    return p.returncode == 0 and dest.exists(), dt, first_error(p.stderr)


# ---- packages (H5) ------------------------------------------------------------

def package_deps(root: Path) -> dict[str, set[str]]:
    """pkg -> the other PACKAGES its sources import (from its `from X` / `import X` lines)."""
    deps = {}
    for pkg in PACKAGES:
        text = "\n".join(f.read_text() for f in sorted((root / pkg).rglob("*.mojo")))
        deps[pkg] = {q for q in PACKAGES if q != pkg and re.search(rf"^\s*(from|import)\s+{q}\b", text, re.M)}
    return deps


def to_rebuild(changed: set[str], deps: dict[str, set[str]]) -> list[str]:
    """`changed` plus every package that depends on one of them, in PACKAGES order."""
    out = set(changed)
    grew = True
    while grew:
        grew = False
        for pkg in PACKAGES:
            if pkg not in out and deps[pkg] & out:
                out.add(pkg)
                grew = True
    return [p for p in PACKAGES if p in out]


def precompile_pkg(root: Path, pkg: str, include: Path) -> tuple[bool, str]:
    """`mojo precompile` into a staging file, then move it into place, so a
    failed precompile leaves the previous .mojoc."""
    stage = include / ".stage"
    stage.mkdir(parents=True, exist_ok=True)
    p = subprocess.run([mojo(), "precompile", str(root / pkg), "-I", str(include), "-o", str(stage / f"{pkg}.mojoc")],
                       cwd=ROOT, capture_output=True, text=True)
    if p.returncode != 0:
        return False, first_error(p.stderr)
    shutil.move(stage / f"{pkg}.mojoc", include / f"{pkg}.mojoc")
    return True, ""


def snapshot_mtimes(root: Path) -> dict[str, dict[str, int]]:
    return {pkg: {str(f): f.stat().st_mtime_ns for f in (root / pkg).rglob("*.mojo")} for pkg in PACKAGES}


# ---- host -----------------------------------------------------------------------

def publish(out: Path, version: int, so: Path) -> None:
    tmp = out / "latest.tmp"
    tmp.write_text(f"{version} {so}\n")
    os.replace(tmp, out / "latest")


def ensure_host() -> Path:
    host = OUT / "live_host"
    src = [HERE / "live_host.mojo", HERE / "hotswap.mojo", HERE / "guard.mojo"]
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
    ap.add_argument("--packages-root", default=str(ROOT), help="directory holding diag/, geometry/, ecs/")
    ap.add_argument("--include", default=str(ROOT / "build"), help="where the precompiled .mojoc files go")
    ap.add_argument("--interval", type=float, default=0.1)
    ap.add_argument("--run-host", action="store_true", help="start live_host on --out and relay its output")
    ap.add_argument("--seconds", type=int, default=600, help="host run time limit")
    ap.add_argument("--keep", type=int, default=3, help="old build directories to keep")
    a = ap.parse_args()

    source, out = Path(a.source).resolve(), Path(a.out).resolve()
    pkg_root, include = Path(a.packages_root).resolve(), Path(a.include).resolve()
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    include.mkdir(parents=True, exist_ok=True)
    deps = package_deps(pkg_root)
    missing = {p for p in PACKAGES if not (include / f"{p}.mojoc").exists()}
    for pkg in to_rebuild(missing, deps):
        ok, err = precompile_pkg(pkg_root, pkg, include)
        if not ok:
            say(f"precompile {pkg} failed: {err}")
            return 1

    host = None
    if a.run_host:
        host = subprocess.Popen([str(ensure_host()), str(out), str(a.seconds)], cwd=ROOT,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        threading.Thread(target=relay, args=(host,), daemon=True).start()

    version, seen, seen_pkgs = 0, None, snapshot_mtimes(pkg_root)
    pending: set[str] = set()  # packages changed since the last good precompile
    try:
        while host is None or host.poll() is None:
            if (out / "stop").exists():
                break
            mtime = source.stat().st_mtime_ns
            now_pkgs = snapshot_mtimes(pkg_root)
            changed = {p for p in PACKAGES if now_pkgs[p] != seen_pkgs[p]}
            if mtime != seen or changed:
                seen, seen_pkgs = mtime, now_pkgs
                if changed:
                    deps = package_deps(pkg_root)
                pending |= changed
                version += 1
                t0 = time.perf_counter()
                rebuild = to_rebuild(pending, deps)
                err = ""
                for pkg in rebuild:
                    ok, err = precompile_pkg(pkg_root, pkg, include)
                    if not ok:
                        break
                else:
                    pending.clear()
                pkg_s = time.perf_counter() - t0
                tag = ",".join(rebuild) or "-"
                if pending:
                    say(f"build version={version} ok=0 build_s={pkg_s:.2f} pkgs={tag} error={err}")
                else:
                    so = out / str(version) / "libengine.so"
                    ok, dt, err = build(source, so, include)
                    if ok:
                        # the line first: the host swaps within a frame of `publish`
                        say(f"build version={version} ok=1 build_s={pkg_s + dt:.2f} pkgs={tag} "
                            f"pkg_s={pkg_s:.2f} engine_s={dt:.2f}")
                        publish(out, version, so)
                        for old in range(1, version - a.keep):
                            shutil.rmtree(out / str(old), ignore_errors=True)
                    else:
                        say(f"build version={version} ok=0 build_s={pkg_s + dt:.2f} pkgs={tag} error={err}")
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
