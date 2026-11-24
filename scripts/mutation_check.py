#!/usr/bin/env python3
"""Mutation checks for the input action map (ludens-engine #117): break one behaviour at a time and confirm the test that covers it fails.

    pixi run -e wasm python3 scripts/mutation_check.py              # every mutation
    pixi run -e wasm python3 scripts/mutation_check.py dead-zone    # one, by name
    pixi run -e wasm python3 scripts/mutation_check.py --list

Each mutation replaces one exact string in one file, runs the named test command, expects a non-zero exit and at least one
`[FAIL]` line, and puts the file back (also on Ctrl-C). Exit 1 if a mutation is not caught or its text is not found."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NATIVE = ["python3", "scripts/test_native.py", "action_map"]
DEMO = ["python3", "scripts/test_native.py", "demo_mode"]
SAVE = ["python3", "scripts/test_native.py", "game_save"]
INPUT_PATH = ["python3", "scripts/test_native.py", "input_path"]
BUILD = ["bash", "scripts/build_wasm.sh"]
E2E = ["bash", "-c", "bash scripts/build_wasm.sh > /dev/null && python3 scripts/test_input.py"]

# name: (file, old, new, test command, what the test must report)
MUTATIONS = {
    "dead-zone": ("game/action_map.mojo", "var t = (m - deadzone) / span if span > 0.0 else 1.0", "var t = m", NATIVE, "dead zone is not subtracted"),
    "radial": ("game/action_map.mojo", "var m = sqrt(x * x + y * y)\n    if m <= deadzone", "var m = abs(x) if abs(x) > abs(y) else abs(y)\n    if m <= deadzone", NATIVE, "dead zone per axis, not radial"),
    "curve": ("game/action_map.mojo", "var out = pow(t, curve) if curve != 1.0 else t", "var out = t", NATIVE, "the response curve is ignored"),
    "conflict": ("game/action_map.mojo", "                if sb.b.same_source(b):\n                    var nm", "                if False:\n                    var nm", NATIVE, "conflicts are never reported"),
    "profile-apply": ("game/action_map.mojo", "            self.actions[ai].bindings = kept^\n        return problems^", "        return problems^", NATIVE, "load_profile applies nothing"),
    "profile-write": ("game/action_map.mojo", "                if now != was:", "                if False:", NATIVE, "profile() writes nothing"),
    "pad-button": ("game/action_map.mojo", "return PAD_BUTTON_BASE + PAD_BUTTON_STRIDE * device + button", "return PAD_BUTTON_BASE + button", NATIVE, "device offset of a pad button is lost"),
    "buffer": ("game/action_map.mojo", "self.left_ms = window_ms if window_ms > 0.0 else 0.0", "self.left_ms = 0.0", NATIVE, "the buffer window is ignored"),
    "demo-buffer": ("game/demo_mode.mojo", "self.jump_buffer.press(Float64(intent.jump_buffer_ms))", "self.jump_buffer.press(0.0)", DEMO, "the demo game ignores the window"),
    "save-buffer": ("game/demo_mode.mojo", "        self.jump_buffer.left_ms = left_ms\n", "", SAVE, "a save drops the pending jump press"),
    "migrate-bytes": ("game/demo_mode.mojo", "        for _ in range(9):\n            out.append(0)\n", "        for _ in range(8):\n            out.append(0)\n", SAVE, "the 1 -> 2 migration inserts 8 bytes, not 9"),
    "axis-sign": ("game/data/demo.actions", "bind move.y -pad:a1", "bind move.y pad:a1", NATIVE, "stick up moves backward"),
    "profile-restore": ("app/profile.mojo", "self.problems = len(actions.load_profile(text))", "self.problems = 0", E2E, "the app never applies the saved profile"),
    "profile-save": ("app/main.mojo", "        _ = a[].profile.save(a[].controls.actions.profile())\n        return 0", "        return 0", E2E, "the app never saves the profile"),
    "axis-event": ("app/controls.mojo", "f.axes[d * MAX_AXES + a] = input.get_axis(Int32(d), Int32(a))", "f.axes[d * MAX_AXES + a] = 0.0", INPUT_PATH, "axes never reach the map"),
}


def run(cmd: list[str]) -> tuple[int, str]:
    p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, check=False)
    return p.returncode, p.stdout + p.stderr


def main(argv: list[str]) -> int:
    if "--list" in argv:
        for name, (path, _, _, _, what) in MUTATIONS.items():
            print(f"{name:14} {path}: {what}")
        return 0
    names = argv or list(MUTATIONS)
    bad = 0
    for name in names:
        if name not in MUTATIONS:
            sys.exit(f"mutation_check: no mutation {name!r}; --list shows them")
        path, old, new, cmd, what = MUTATIONS[name]
        f = ROOT / path
        original = f.read_text()
        if original.count(old) != 1:
            print(f"[ERROR] {name}: the text to mutate occurs {original.count(old)} times in {path}")
            bad += 1
            continue
        try:
            f.write_text(original.replace(old, new))
            if path.endswith(".actions"):
                run(["python3", "scripts/gen_actions.py"])  # the tests read the embedded copy
            rc, out = run(cmd)
        finally:
            f.write_text(original)
            if cmd is E2E:
                run(BUILD)  # build/app.wasm must not stay mutated
        fails = [l.strip() for l in out.splitlines() if "[FAIL]" in l]
        if path.endswith(".actions"):
            run(["python3", "scripts/gen_actions.py"])  # keep the embedded copy in step with the restored file
        if rc != 0 and fails:
            print(f"[caught] {name} ({what}): {len(fails)} failing checks, first: {fails[0]}")
        else:
            print(f"[MISSED] {name} ({what}): exit {rc}, {len(fails)} failing checks")
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
