#!/usr/bin/env python3
"""Show that a test fails under one deliberate change to the code it tests (#121).

    pixi run -e wasm python3 scripts/mutation_check.py --list
    pixi run -e wasm python3 scripts/mutation_check.py                  # every mutation, one after the other
    pixi run -e wasm python3 scripts/mutation_check.py seed-ignored     # one

Each mutation replaces one exact string in one source file, runs the named native test (scripts/test_native.py) and
prints the checks that failed. The file is restored afterwards, also when the run is interrupted. A mutation whose test
still passes is reported as SURVIVED and makes the exit code 1: it means the test does not look at that behaviour.
The GPU tests need lavapipe (see .github/workflows/parity.yml); the script sets the same environment variables."""
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# name: (file, old text, new text, test, what the change breaks)
MUTATIONS = {
    "seed-ignored": ("game/particles.mojo", "self.rng = Rng(seed)", "self.rng = Rng(0)", "particles", "every emitter uses seed 0"),
    "cone-too-wide": ("game/particles.mojo", "var z = 1.0 - (1.0 - self.cos_cone) * self.rng.next_f()", "var z = 1.0 - (1.2 - self.cos_cone) * self.rng.next_f()", "particles", "directions leave the cone"),
    "budget-off-by-one": ("game/particles.mojo", "if self.live() >= self.row.max_particles:", "if self.live() > self.row.max_particles:", "particles", "an emitter holds max_particles + 1"),
    "cap-off-by-one": ("game/particles.mojo", "        if room <= 0:\n            self.dropped_cap += 1", "        if room < 0:\n            self.dropped_cap += 1", "particles", "the system holds cap + 1"),
    "lod-ignored": ("game/particles.mojo", "self.accum += self.row.rate * dt * scale", "self.accum += self.row.rate * dt", "particles", "the rate is not scaled by distance"),
    "drag-wrong": ("game/particles.mojo", "var drag = 1.0 / (1.0 + self.row.drag * dt)", "var drag = 1.0 / (1.0 + self.row.drag)", "particles", "drag ignores dt"),
    "gravity-dropped": ("game/particles.mojo", "self.vy[i] = (self.vy[i] + gy) * drag", "self.vy[i] = self.vy[i] * drag", "particles", "no gravity on y"),
    "live-total-not-freed": ("game/particles.mojo", "                total -= 1\n", "", "particles", "a dead particle keeps its room under the cap"),
    "sort-near-first": ("game/particles.mojo", "if key[ia] > key[ib] or (key[ia] == key[ib] and ia < ib):", "if key[ia] < key[ib] or (key[ia] == key[ib] and ia < ib):", "particles", "alpha particles are packed near to far"),
    "frame-index-fixed": ("game/particles.mojo", "var frame = min(Int(t * Float64(cols * rows)), cols * rows - 1)", "var frame = 0", "particles", "the flipbook never advances"),
    "sort-near-first-gpu": ("game/particles.mojo", "if key[ia] > key[ib] or (key[ia] == key[ib] and ia < ib):", "if key[ia] < key[ib] or (key[ia] == key[ib] and ia < ib):", "particles_native", "alpha particles are drawn near to far"),
    "depth-test-off": ("app/particle_pass.mojo", "device, alpha_shader, layout, color_format, depth_format, 4, BLEND_ALPHA, 0, False, DEPTH_LESS_EQUAL,", "device, alpha_shader, layout, color_format, depth_format, 4, BLEND_ALPHA, 0, False, 8,", "particles_native", "alpha particles ignore the depth buffer"),
    "additive-as-alpha": ("app/particle_pass.mojo", "device, add_shader, layout, color_format, depth_format, 4, BLEND_ADD, 0, False, DEPTH_LESS_EQUAL,", "device, add_shader, layout, color_format, depth_format, 4, BLEND_ALPHA, 0, False, DEPTH_LESS_EQUAL,", "particles_native", "the additive pipeline blends as alpha"),
}


def run_one(name: str) -> bool:
    """True if the test failed under the mutation (the wanted result)."""
    path, old, new, test, what = MUTATIONS[name]
    src = ROOT / path
    original = src.read_text()
    if original.count(old) != 1:
        sys.exit(f"{name}: `{old}` occurs {original.count(old)} times in {path}, expected 1")
    env = dict(os.environ)
    env.setdefault("VK_ICD_FILENAMES", "/usr/share/vulkan/icd.d/lvp_icd.json")
    env.setdefault("LIBGL_ALWAYS_SOFTWARE", "1")
    env.setdefault("WGPU_BACKEND", "vulkan")
    try:
        src.write_text(original.replace(old, new))
        p = subprocess.run([sys.executable, "scripts/test_native.py", test], cwd=ROOT, capture_output=True, text=True, env=env, check=False)
    finally:
        src.write_text(original)
    out = p.stdout + p.stderr
    failed = re.findall(r"\[FAIL\] (.*)", out)
    compile_error = "error:" in out and not failed
    print(f"{name}: {what}; test `{test}` ->", "SURVIVED (test passed)" if p.returncode == 0 else ("COMPILE ERROR" if compile_error else "failed"))
    for line in failed:
        print("    [FAIL]", line)
    if compile_error:
        print(out[-800:])
    return p.returncode != 0 and not compile_error


def main() -> int:
    args = sys.argv[1:]
    if args == ["--list"]:
        for n, m in MUTATIONS.items():
            print(f"{n:24} {m[0]}: {m[4]} (test {m[3]})")
        return 0
    names = args or list(MUTATIONS)
    unknown = [n for n in names if n not in MUTATIONS]
    if unknown:
        sys.exit("unknown mutation(s): " + ", ".join(unknown))
    ok = all([run_one(n) for n in names])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
