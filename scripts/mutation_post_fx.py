#!/usr/bin/env python3
"""Show that each test of the picture effects fails under one deliberate change to the code it tests (#139).

    pixi run -e wasm python3 scripts/mutation_post_fx.py --list
    pixi run -e wasm python3 scripts/mutation_post_fx.py                    # every mutation, one after the other
    pixi run -e wasm python3 scripts/mutation_post_fx.py lut-axes-swapped   # one

Each mutation replaces one exact string in one source file, runs the named test and prints the checks that failed. The
file is restored afterwards, also when the run is interrupted. A mutation whose test still passes is reported as SURVIVED
and makes the exit code 1: the test does not look at that behaviour. `native` tests are built and run by
scripts/test_native.py and need lavapipe (the script sets the same environment variables as .github/workflows/parity.yml);
`node` tests run a script with node."""
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FX = "app/post_fx.mojo"
R3 = "app/render3d.mojo"
NATIVE = "post_fx_native"

# name: (file, old text, new text, (kind, test), what the change breaks)
MUTATIONS = {
    "fxaa-does-nothing": (FX, "return mix(c, src_at(out_uv), strength);", "return c;", ("native", NATIVE), "FXAA returns its input"),
    "fxaa-no-contrast-gate": (FX, "if range < max(0.0312, lmax * 0.125) { return c; }", "if range < 0.0 { return c; }", ("native", NATIVE), "FXAA filters detail under its contrast gate too"),
    "bloom-no-threshold": (FX, "let w = max(soft, l - t) / max(l, 1e-4);", "let w = 1.0;", ("native", NATIVE), "everything feeds the glow"),
    "bloom-no-coarse-levels": (FX, "return 0.5 * src_at(uv) + 0.5 * (s / 16.0);", "return src_at(uv);", ("native", NATIVE), "the coarser levels of the mip chain are not added"),
    "bloom-weights-sum-to-two": (FX, "return 0.5 * src_at(uv) + 0.5 * (s / 16.0);", "return src_at(uv) + (s / 16.0);", ("native", NATIVE), "the levels' weights add up to 2, not 1"),
    "bloom-intensity-ignored": (FX, "src_texel(uv) + src2_at(uv) * frame.fx.y", "src_texel(uv) + src2_at(uv)", ("native", NATIVE), "bloom_intensity has no effect"),
    "lut-axes-swapped": (FX, "textureLoad(lutt, vec2<i32>(b * n + r, g), 0)", "textureLoad(lutt, vec2<i32>(r * n + b, g), 0)", ("native", NATIVE), "red and blue swap places in the table"),
    "lut-no-interpolation": (FX, "let f = t - vec3<f32>(lo);", "let f = vec3<f32>(0.0);", ("native", NATIVE), "the nearest lower entry, no interpolation"),
    "lut-amount-ignored": (FX, "return mix(c, graded, frame.fx.z);", "return graded;", ("native", NATIVE), "lut_amount has no effect"),
    "msaa-colour-not-resolved": ("app/msaa.mojo", "color_ms.handle().raw, UInt32(0xFFFFFFFF), resolve.handle().raw, UInt32(2), UInt32(2), clear,", "color_ms.handle().raw, UInt32(0xFFFFFFFF), null_opaque(), UInt32(2), UInt32(2), clear,", ("native", NATIVE), "the 4-sample colour is never resolved into the frame"),
    "msaa-depth-not-resolved": ("app/msaa.mojo", "o.d = textureLoad(zms, vec2<i32>(pos.xy), 0);", "o.d = 1.0;", ("native", NATIVE), "the stages see no depth with MSAA"),
    "msaa-hud-not-drawn": (R3, "                hud.record(hpass)\n                hpass^.end()\n            else:", "                hpass^.end()\n            else:", ("native", NATIVE), "the HUD is not drawn over the resolved MSAA frame"),
    "view-clone-not-counted": ("shell/web/view_refs.mjs", "    extra.set(k, (extra.get(k) ?? 0) + 1);", "    extra.set(k, 0);", ("node", "tests/test_view_refs.mjs"), "a cloned view is dropped by the first release"),
}


def run_one(name: str) -> bool:
    """True if the test failed under the mutation (the wanted result)."""
    path, old, new, (kind, test), what = MUTATIONS[name]
    src = ROOT / path
    original = src.read_text()
    if original.count(old) != 1:
        sys.exit(f"{name}: `{old}` occurs {original.count(old)} times in {path}, expected 1")
    env = dict(os.environ)
    env.setdefault("VK_ICD_FILENAMES", "/usr/share/vulkan/icd.d/lvp_icd.json")
    env.setdefault("LIBGL_ALWAYS_SOFTWARE", "1")
    env.setdefault("WGPU_BACKEND", "vulkan")
    cmd = [sys.executable, "scripts/test_native.py", test] if kind == "native" else ["node", "--no-warnings", test]
    try:
        src.write_text(original.replace(old, new))
        p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, env=env, check=False)
    finally:
        src.write_text(original)
    out = p.stdout + p.stderr
    failed = re.findall(r"\[FAIL\] (.*)", out)
    compile_error = "error:" in out and not failed
    crashed = p.returncode != 0 and not failed and not compile_error
    print(f"{name}: {what}; test `{test}` ->", "SURVIVED (test passed)" if p.returncode == 0 else ("COMPILE ERROR" if compile_error else ("crashed" if crashed else "failed")))
    for line in failed:
        print("    [FAIL]", line)
    if compile_error or crashed:
        print(out[-800:])
    return p.returncode != 0 and not compile_error


def main() -> int:
    args = sys.argv[1:]
    if args == ["--list"]:
        for n, m in MUTATIONS.items():
            print(f"{n:26} {m[0]}: {m[4]} (test {m[3][1]})")
        return 0
    names = args or list(MUTATIONS)
    unknown = [n for n in names if n not in MUTATIONS]
    if unknown:
        sys.exit("unknown mutation(s): " + ", ".join(unknown))
    ok = all([run_one(n) for n in names])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
