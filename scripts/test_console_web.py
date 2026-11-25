#!/usr/bin/env python3
"""The console and photo mode in the wasm64 module (issue #146, docs/console.md), under node through the `window.game` hook
(scripts/game_run.mjs, no WebGPU).

    pixi run -e wasm test-console-web        # builds build/app.wasm first

  - typed: ` opens the console, g o d Enter runs `god`, ` closes it; the log holds `god` at its frame and the run is marked;
  - lines submitted through the hook at ticks 30 .. 160 (teleport, god, spawn, noclip twice) give a log; that log loaded into
    a fresh run with the same keys (`replay`) gives the same hash at every one of the 240 ticks; without the lines the
    final hash differs;
  - photo mode from tick 100 to 150 holds the hash still (the game is not stepped) while the keys stay held;
  - a release module (LUDENS_CONFIG=release scripts/build_wasm.sh build/app_release.wasm) has none of the console's strings
    that build/app.wasm has."""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import divergence  # noqa: E402

passed = 0
failed = 0


def check(cond: bool, label: str) -> None:
    global passed, failed
    if cond:
        passed += 1
    else:
        failed += 1
    print(f"  [{'PASS' if cond else 'FAIL'}] {label}")


KEYS = [{"tick": 0, "hold": "w"}, {"tick": 0, "hold": "KeyD"}] + [{"tick": t, "press": "Space"} for t in range(10, 240, 45)]
LINES = [(30, "teleport 0 3 -4"), (40, "god"), (50, "spawn crate"), (120, "noclip"), (160, "noclip")]


def run(script: list, **job) -> list:
    return divergence.run_trace({"ticks": 240, "state": False, "script": KEYS + script, "console_log": True, **job})


def main() -> int:
    typed = run([{"tick": 30, "press": "Backquote"}, {"tick": 31, "press": "g"}, {"tick": 32, "press": "o"}, {"tick": 33, "press": "d"},
                 {"tick": 34, "press": "Enter"}, {"tick": 35, "press": "Backquote"}])
    end = typed[-1]
    check(end["console_log"] == "34 god\n" and end["cheated"], f"typed ` g o d Enter: log {end['console_log']!r}, cheated {end['cheated']}")

    lined = run([{"tick": t, "console": line} for t, line in LINES])
    log = lined[-1]["console_log"]
    check(log == "".join(f"{t} {line}\n" for t, line in LINES), f"the hook's lines are logged with their frames:\n{log}")
    replayed = run([], replay=log)
    same = all(a["hash"] == b["hash"] for a, b in zip(lined[:-1], replayed[:-1], strict=True))
    check(same and len(lined) == len(replayed), f"the log played back gives the same hash at all 240 ticks (final {lined[-2]['hash']})")
    check(replayed[-1]["console_log"] == log and replayed[-1]["cheated"], "the replay logs the same lines and is marked")
    plain = run([])
    check(plain[-2]["hash"] != lined[-2]["hash"] and not plain[-1]["cheated"], f"without the lines the run ends at {plain[-2]['hash']}, unmarked")

    photo = run([{"tick": 100, "photo": True}, {"tick": 150, "photo": False}])
    held = {photo[t]["hash"] for t in range(100, 151)}
    check(len(held) == 1, f"photo mode from tick 100 to 150: {len(held)} distinct hash over ticks 100..150")
    check(photo[151]["hash"] != photo[150]["hash"], "after leaving photo mode the game steps again")

    rel = ROOT / "build/app_release.wasm"
    subprocess.run(["bash", "scripts/build_wasm.sh", str(rel)], cwd=ROOT, check=True, stdout=subprocess.DEVNULL,
                   env={**os.environ, "LUDENS_CONFIG": "release"})
    d = (ROOT / "build/app.wasm").read_bytes()
    r = rel.read_bytes()
    for m in (b"unknown command `", b"is registered twice", b"console replay line"):
        check(m in d and m not in r, f"`{m.decode()}`: in build/app.wasm {m in d}, in the release module {m in r}")
    print(f"  module sizes: debug {len(d)} bytes, release {len(r)} bytes")
    print(f"test-console-web: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
