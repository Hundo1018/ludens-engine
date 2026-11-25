#!/usr/bin/env python3
"""Crash reports on the web (ludens-engine #147): build app/crash_probe.mojo to wasm64 with DWARF line tables, strip it and
write its source map (scripts/wasm_sourcemap.py), run tests/test_crash.mjs under node (trap, save, send on the next
launch), then read the report with the reference reader (scripts/telemetry_read.py), with and without the map.

    pixi run -e wasm test-crash"""
import subprocess
import sys
from pathlib import Path

import ludens_wasm_rt

ROOT = Path(__file__).resolve().parent.parent
DEPS = ROOT / "build/deps"
sys.path.insert(0, str(ROOT / "scripts"))
import telemetry_read  # noqa: E402


def run(cmd: list[str]) -> None:
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, check=False)
    if proc.returncode:
        sys.exit(proc.stdout + proc.stderr)
    print(proc.stdout.strip().splitlines()[-1])


def crash_line() -> int:
    for i, line in enumerate((ROOT / "app/crash_probe.mojo").read_text().splitlines(), 1):
        if "# CRASH-LINE" in line:
            return i
    sys.exit("test_crash: no CRASH-LINE marker in app/crash_probe.mojo")


def main() -> int:
    (ROOT / "build").mkdir(exist_ok=True)
    subprocess.run(["bash", "scripts/deps.sh"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    run([sys.executable, "-m", "ludens_wasm_rt.build_wasm", "--lib", ".", "-I", "app", "-I", ".", "app/crash_probe.mojo",
         "--target", "wasm64", "-o", "build/crash_probe_debug.wasm", "--export", "c_*", "--debug", "line-tables"])
    run([sys.executable, "scripts/wasm_sourcemap.py", "build/crash_probe_debug.wasm", "-o", "build/crash_probe.wasm",
         "--map", "build/crash_probe.wasm.map"])
    line = crash_line()
    out = ROOT / "build/crash_web.report"
    rc = subprocess.run(["node", "--no-warnings", str(ROOT / "tests/test_crash.mjs"), str(ROOT / "build/crash_probe.wasm"),
                         str(ROOT / "build/crash_probe.wasm.map"), str(ludens_wasm_rt.HOST_MJS), str(DEPS / "wgpu-mojo"),
                         str(DEPS / "miniaudio-mojo"), str(line), str(out)], check=False).returncode
    if rc:
        return rc
    failed = passed = 0

    def check(ok: bool, label: str) -> None:
        nonlocal failed, passed
        failed += not ok
        passed += bool(ok)
        print(f"  [{'PASS' if ok else 'FAIL'}] {label}")

    print("reference reader on the web report")
    r = telemetry_read.decode(out.read_bytes())
    top = r["frames"][0]
    check(r["type"] == "crash" and r["build_id"] == "crash-probe 1" and r["tick"] == 600 and r["session_ms"] == 10000,
          f"crash report from build {r['build_id']!r}, tick {r['tick']}, {r['session_ms']} ms")
    check(r["log"] == [f"frame {i + 2}" for i in range(8)], f"the newest 8 log lines: {r['log'][0]!r} .. {r['log'][-1]!r}")
    check(len(r["blackbox"]) == 1000 and r["blackbox"][999] == (999 * 7) & 0xFF, "the 1000-byte black box, byte for byte at the end")
    check(r["install_id"] == "11110000-0000-4000-a222-000000000000", f"install id {r['install_id']}")
    check(top["file"] == "app/crash_probe.mojo" and top["line"] == line, f"innermost frame mapped by the host: {top['file']}:{top['line']}")
    print("reference reader, mapping afterwards")
    u = telemetry_read.decode(Path(str(out) + ".unmapped").read_bytes())
    check(u["frames"][0]["line"] == 0, "no map at crash time: the frame is unmapped in the file")
    telemetry_read.map_frames(u, ROOT / "build/crash_probe.wasm.map")
    check(u["frames"][0]["file"] == "app/crash_probe.mojo" and u["frames"][0]["line"] == line,
          f"telemetry_read --map maps it: {u['frames'][0]['file']}:{u['frames'][0]['line']}")
    print("reference reader on the files tests/platform_telemetry.mojo wrote (the Mojo encoders)")
    b = telemetry_read.decode((ROOT / "build/telemetry_sample.batch").read_bytes())
    ev = b["events"]
    check(b["type"] == "batch" and b["seq"] == 0 and b["dropped"] == 31 and b["tags"] == {0xAB01: 2} and b["session_id"] == 0x1122334455667788,
          f"batch: seq {b['seq']}, {b['dropped']} dropped, tags {b['tags']}, build {b['build_id']!r}")
    check(len(ev) == 16 and ev[0]["name"] == "death" and ev[1]["values"] == [2, 1000, 0, -1000] and ev[15]["tick"] == 15,
          f"16 death events; event 1 values {ev[1]['values']}, event 15 tick {ev[15]['tick']}")
    c = telemetry_read.decode((ROOT / "build/telemetry_sample.crash").read_bytes())
    check(c["reason"] == "RuntimeError: unreachable" and [f["line"] for f in c["frames"]] == [88, 0] and len(c["blackbox"]) == 300,
          f"crash: {c['reason']!r}, frame lines {[f['line'] for f in c['frames']]}, black box {len(c['blackbox'])} bytes")
    bad = bytearray((ROOT / "build/telemetry_sample.batch").read_bytes())
    bad[60] ^= 1
    try:
        telemetry_read.decode(bytes(bad))
        check(False, "a flipped byte is refused")
    except ValueError as e:
        check(str(e) == "checksum mismatch", f"a flipped byte is refused: {e}")
    print(f"test_crash (reader): {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
