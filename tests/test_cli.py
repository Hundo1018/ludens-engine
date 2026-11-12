#!/usr/bin/env python3
"""The `ludens` command line (ludens-engine #11), end to end through real processes.

    pixi run -e wasm test-cli

Checks, each across process boundaries and through text scene files:
  - a project is made and its world hash is stable;
  - the GUI entry, the CLI entry and a script give the same hash for the same edit, right away and after 120 ticks;
  - a control that differs by 1e-7 gives a different hash;
  - undo in a script returns the scene to the original bytes;
  - run -o writes the scene back byte for byte when nothing happened (text round trip);
  - errors exit non-zero, name what is wrong and write nothing.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import build_core  # noqa: E402

LUDENS = [sys.executable, str(ROOT / "scripts/ludens.py")]
passed = 0
failed = 0


def check(cond: bool, label: str) -> None:
    global passed, failed
    if cond:
        passed += 1
        print(f"  [PASS] {label}")
    else:
        failed += 1
        print(f"  [FAIL] {label}")


def run(args, cwd=None, env=None):
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True, env=env)


def world_hash(proc) -> str | None:
    m = re.search(r"hash ([0-9a-f]{16})", proc.stdout)
    return m.group(1) if m else None


def main() -> int:
    core = build_core.core()
    env = {**os.environ, "LUDENS_CORE": str(core)}

    def ludens(*args, cwd=None):
        return run([*LUDENS, *args], cwd=cwd, env=env)

    def core_run(*args):
        return run([str(core), *args], env=env)

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)

        # ---- a project, and a stable hash
        proj = root / "demo"
        r = ludens("new", str(proj))
        check(r.returncode == 0 and (proj / "ludens.toml").exists() and (proj / "world.scene").exists(), "new: ludens.toml and world.scene exist")
        scene = proj / "world.scene"
        original = scene.read_bytes()
        h0 = world_hash(ludens("hash", cwd=proj))
        check(h0 is not None and h0 == world_hash(ludens("hash", cwd=proj)), "hash: the same on two invocations")
        check(ludens("new", str(proj)).returncode != 0, "new: refuses a directory that is already a project")
        sub = proj / "a" / "b"
        sub.mkdir(parents=True)
        check(world_hash(ludens("hash", cwd=sub)) == h0, "the project is found from a subdirectory")
        check(world_hash(ludens("--project", str(proj), "hash", cwd=root)) == h0, "--project names it from anywhere")

        # ---- bodies, handles
        listing = ludens("list", cwd=proj).stdout.strip().splitlines()
        check(len(listing) == 7, "list: 7 bodies")
        handle = listing[2].split()[1]

        # ---- text round trip: run 0 writes the scene back unchanged
        copy = root / "copy.scene"
        r = ludens("run", "0", "-o", str(copy), cwd=proj)
        check(r.returncode == 0 and copy.read_bytes() == original, "run 0 -o: the written scene equals the original, byte for byte")

        # ---- the same edit through three entries (three processes)
        a, b, c = root / "a.scene", root / "b.scene", root / "c.scene"
        for f in (a, b, c):
            f.write_bytes(original)
        move = ["move_body", handle, "0.7", "3.0", "-0.3"]
        script = root / "edit.txt"
        script.write_text("# one edit\n" + " ".join(move) + "\n")
        ra = core_run("gui-move", str(a), handle, "0.7", "3.0", "-0.3")
        rb = ludens("cmd", "-o", str(b), *move, cwd=proj)
        rc = ludens("script", str(script), "-o", str(c), cwd=proj)
        ha, hb, hc = world_hash(ra), world_hash(rb), world_hash(rc)
        check(ha is not None and ha == hb == hc, f"GUI entry == CLI entry == script (hash {ha})")
        check(ha != h0, "the edit changed the world")
        # `cmd -o` reads the project scene (unchanged), so b/c hold the edited result; compare the files too
        check(a.read_bytes() == b.read_bytes() == c.read_bytes(), "the three written scenes are byte-identical")
        ticks = [world_hash(core_run("run", str(f), "120")) for f in (a, b, c)]
        check(ticks[0] is not None and ticks[0] == ticks[1] == ticks[2], "after 120 ticks the three still agree")
        check(ticks[0] != world_hash(core_run("run", str(root / "copy.scene"), "120")), "...and differ from the unedited scene")

        # ---- control
        d = root / "d.scene"
        d.write_bytes(original)
        rd = core_run("gui-move", str(d), handle, "0.7000001", "3.0", "-0.3")
        check(world_hash(rd) is not None and world_hash(rd) != ha, "control: an argument 1e-7 away gives a different hash")

        # ---- undo in a script
        e = root / "e.scene"
        e.write_bytes(original)
        undo_script = root / "undo.txt"
        undo_script.write_text(" ".join(move) + "\nundo\n")
        re_ = core_run("script", str(e), str(undo_script))
        check(re_.returncode == 0 and world_hash(re_) == h0 and e.read_bytes() == original, "script: an edit followed by undo restores the original scene bytes")

        # ---- trace: the engine's profiling spans as Chrome trace JSON, without changing the simulation
        tr = root / "trace.json"
        plain = core_run("run", str(root / "copy.scene"), "120")
        traced = subprocess.run([str(build_core.core_trace()), "trace", str(root / "copy.scene"), "120", str(tr)], capture_output=True, text=True)
        check(traced.returncode == 0 and world_hash(traced) is not None and world_hash(traced) == world_hash(plain), "trace: the world hash after 120 ticks equals a run without tracing")
        events = json.loads(tr.read_text(encoding="utf-8"))
        names = {e["name"] for e in events}
        check(isinstance(events, list) and len(events) > 0 and {"broadphase", "narrowphase"} <= names, f"trace: a JSON array of events that includes broadphase and narrowphase ({sorted(names)})")
        check(all(e["ph"] in ("X", "C") and isinstance(e["ts"], int) and e["pid"] == 0 for e in events) and all(e["dur"] >= 0 for e in events if e["ph"] == "X"), "trace: every event has a phase, an integer timestamp, a pid and a non-negative duration")
        zero = root / "zero.json"
        subprocess.run([str(build_core.core_trace()), "trace", str(root / "copy.scene"), "0", str(zero)], check=True, capture_output=True)
        check(json.loads(zero.read_text(encoding="utf-8")) == [], "trace: zero ticks give an empty array")
        r = subprocess.run([str(build_core.core_trace()), "trace", str(root / "copy.scene"), "-3", str(root / "x.json")], capture_output=True, text=True)
        check(r.returncode == 1 and not (root / "x.json").exists(), "trace: negative ticks are refused and write nothing")

        # ---- overlay: the physics debug-draw (one arrow per contact point), without changing the simulation
        ov = root / "overlay.json"
        ovr = subprocess.run([str(build_core.core_overlay()), "overlay", str(root / "copy.scene"), "120", str(ov)], capture_output=True, text=True)
        check(ovr.returncode == 0 and world_hash(ovr) is not None and world_hash(ovr) == world_hash(traced), "overlay: the world hash after 120 ticks equals a run without the overlay")
        total = int(next(l for l in ovr.stdout.splitlines() if l.startswith("overlay commands:")).split(":")[1])
        arrows = json.loads(ov.read_text(encoding="utf-8"))
        check(total > 0 and isinstance(arrows, list) and all(a["kind"] == 3 and len(a["p0"]) == 3 and len(a["color"]) == 4 for a in arrows), f"overlay: arrows were drawn ({total} over 120 ticks, {len(arrows)} in the last frame), each with kind ARROW, a point and an rgba colour")
        plain_ov = subprocess.run([str(build_core.core_overlay().parent / "ludens-core"), "overlay", str(root / "copy.scene"), "120", str(root / "plain.json")], capture_output=True, text=True)
        check(plain_ov.returncode == 0 and "overlay commands: 0" in plain_ov.stdout, "overlay: the plain build draws nothing (control)")

        # ---- sheet: an event sheet file is validated; errors name the line and the event
        good = root / "good.sheet"
        good.write_text("event 1\n  when tick_mod 30\n  do add n 1\nevent 2 parent 1\n  when key fire\n  do spawn_sphere b 0 5 0 0.3 1\n", encoding="utf-8")
        sg = core_run("sheet", str(good))
        check(sg.returncode == 0 and "sheet ok: 2 events" in sg.stdout, "sheet: a valid sheet is accepted and its events counted")
        bad = root / "bad.sheet"
        bad.write_text("event 1\n  when tick_mod 30\nevent 7\n  when sometimes\n", encoding="utf-8")
        sb = core_run("sheet", str(bad))
        check(sb.returncode == 1 and "line 4" in sb.stderr and "event 7" in sb.stderr, f"sheet: an unknown condition exits 1 and names line 4 and event 7 ({sb.stderr.strip()[:80]})")
        sm = core_run("sheet", str(root / "missing.sheet"))
        check(sm.returncode == 1, "sheet: a missing file exits 1")

        # ---- a scene that carries its event sheet (`sheet.<n>` rows), and the `scene` action
        level1, level2 = root / "level1.scene", root / "level2.scene"
        core_run("demo", str(level2))
        sheet_rows = ("sheet.1 = event 1\nsheet.2 = when tick_mod 10\nsheet.3 = do impulse @1 0 3 0\nsheet.4 = do add kicks 1\n"
                      "sheet.5 = do sound 2\nsheet.10 = event 2 once\nsheet.11 = when var kicks >= 3\nsheet.12 = do scene level2\n")
        level1.write_text(level2.read_text() + sheet_rows)
        plain = core_run("check", str(level2)).stdout.strip()
        check(core_run("check", str(level1)).stdout.strip() == plain, "scene sheet: the sheet rows are not world rows (same hash as the scene without them)")
        kept = root / "kept.scene"
        r5 = core_run("run", str(level1), "5", "-o", str(kept))
        rows = [l for l in kept.read_text().splitlines() if l.startswith("sheet.")]
        check(r5.returncode == 0 and len(rows) == 8 and rows[0] == "sheet.1 = event 1" and rows[7] == "sheet.8 = do scene level2",
              f"scene sheet: saving keeps the sheet, renumbered 1..8 ({len(rows)} rows)")
        no_sheet = root / "no_sheet.scene"
        no_sheet.write_text("\n".join(l for l in level1.read_text().splitlines() if not l.startswith("sheet.")) + "\n")
        check(core_run("run", str(level1), "5").stdout.splitlines()[-1] != core_run("run", str(no_sheet), "5").stdout.splitlines()[-1],
              "scene sheet: the sheet runs (its impulse at tick 0 changes the world)")
        r60 = core_run("run", str(level1), "60")
        after = core_run("run", str(level2), "39").stdout.strip()
        check(r60.returncode == 0 and "scene level2 after tick 20" in r60.stdout and "scene-changes 1 sounds 3" in r60.stdout,
              f"scene sheet: the third kick (tick 20) changes the scene ({r60.stdout.strip()[:70]})")
        check(r60.stdout.strip().splitlines()[-1] == after, "scene sheet: after the change the world is level2 run for the 39 ticks left")
        bad_body = root / "bad_body.scene"
        bad_body.write_text(level1.read_text().replace("@1", "@99"))
        bb = core_run("check", str(bad_body))
        check(bb.returncode == 1 and "row `sheet.3`" in bb.stderr and "@99" in bb.stderr, "scene sheet: a body that is not in the scene names the row")
        bad_act = root / "bad_act.scene"
        bad_act.write_text(level1.read_text().replace("do sound 2", "do explode 2"))
        ba = core_run("check", str(bad_act))
        check(ba.returncode == 1 and "row `sheet.5`" in ba.stderr and "unknown action `explode`" in ba.stderr, "scene sheet: a sheet error names the scene row")
        gone = root / "gone.scene"
        gone.write_text(level1.read_text().replace("do scene level2", "do scene nowhere"))
        check(core_run("run", str(gone), "60").returncode == 1, "scene sheet: changing to a scene that does not exist exits 1")
        bad_row = root / "bad_row.scene"
        bad_row.write_text(level2.read_text() + "sheet.x = event 1\n")
        check(core_run("check", str(bad_row)).returncode == 1, "scene sheet: `sheet.x` is refused")

        # ---- capture and replay: a recording can be checked against a re-simulation
        import struct
        cap = root / "run.cap"
        rc_ = core_run("capture", str(root / "copy.scene"), "120", str(cap))
        check(rc_.returncode == 0 and "captured 120 frames" in rc_.stdout and cap.exists(), "capture: 120 frames recorded")
        rp = core_run("replay", str(root / "copy.scene"), str(cap))
        check(rp.returncode == 0 and "verified 120 frames" in rp.stdout, "replay: the recording verifies against a re-simulation")
        raw = bytearray(cap.read_bytes())
        _, _, _, nframes = struct.unpack_from("<4q", raw, 0)
        frame_at, p_ = [], 32
        for _ in range(nframes):
            ln = struct.unpack_from("<q", raw, p_)[0]
            frame_at.append((p_ + 8, ln))
            p_ += 8 + ln
        for k in (45, 100):
            bad = bytearray(raw)
            bad[frame_at[k][0] + 32] ^= 0x01  # one bit inside frame k's payload
            tampered = root / f"tamper{k}.cap"
            tampered.write_bytes(bad)
            r = core_run("replay", str(root / "copy.scene"), str(tampered))
            check(r.returncode == 1 and f"mismatch at frame {k} of 120" in r.stdout, f"replay: one flipped bit in frame {k} is reported as frame {k}")
        cut = root / "cut.cap"
        cut.write_bytes(bytes(raw[: len(raw) // 2]))
        r = core_run("replay", str(root / "copy.scene"), str(cut))
        check(r.returncode == 1 and "mismatch" not in r.stdout and r.stderr.strip() != "", "replay: a truncated file is an error, not a verdict")
        r = core_run("capture", str(root / "copy.scene"), "0", str(root / "z.cap"))
        check(r.returncode == 1 and not (root / "z.cap").exists(), "capture: zero ticks is refused and writes nothing")

        # ---- errors write nothing
        f = root / "f.scene"
        f.write_bytes(original)
        r = core_run("cmd", str(f), "--", "no_such_command", "1")
        check(r.returncode == 1 and "no_such_command" in r.stderr and f.read_bytes() == original, "unknown command: exit 1, named, scene untouched")
        bad = root / "bad.txt"
        bad.write_text("# ok\n" + " ".join(move) + "\nmove_body only_one_argument\n")
        r = core_run("script", str(f), str(bad))
        check(r.returncode == 1 and "bad.txt:3" in r.stderr and f.read_bytes() == original, "script error: the line is named, scene untouched")
        broken = root / "broken.scene"
        text = original.decode().splitlines()
        text[5] = "this line has no equals sign"
        broken.write_text("\n".join(text) + "\n")
        r = core_run("hash", str(broken))
        check(r.returncode == 1 and "line 6" in r.stderr, "malformed scene row: the line number is reported")
        dup = root / "dup.scene"
        dup.write_text(original.decode() + "version = 1\n")
        r = core_run("hash", str(dup))
        check(r.returncode == 1 and "duplicate row `version`" in r.stderr, "duplicate row: reported")
        r = core_run("hash", str(root / "missing.scene"))
        check(r.returncode == 1 and "cannot read" in r.stderr, "missing file: reported")
        r = core_run("cmd", str(f), "--", "move_body", "99999", "0", "0", "0")
        check(r.returncode == 1 and f.read_bytes() == original, "a handle that is not a body: exit 1, scene untouched")
        r = ludens("cmd", cwd=root)
        check(r.returncode != 0, "outside a project the CLI says so")

    print(f"cli: {passed} / {passed + failed} checks")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
