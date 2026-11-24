#!/usr/bin/env python3
"""Show that each accessibility test fails under one deliberate change to the code it tests (#118).

    pixi run -e wasm python3 scripts/mutation_access.py --list
    pixi run -e wasm python3 scripts/mutation_access.py                  # every mutation, one after the other
    pixi run -e wasm python3 scripts/mutation_access.py shake-ignores-reduce-motion   # one

Each mutation replaces one exact string in one source file, runs the named test and prints the checks that failed. The file is
restored afterwards, also when the run is interrupted. A mutation whose test still passes is reported as SURVIVED and makes the exit
code 1: the test does not look at that behaviour. A change that does not compile is reported as COMPILE ERROR (not a pass).

Test names: `native:<name>` is scripts/test_native.py, `gpu:<name>` the same on lavapipe, `audio:<name>` scripts/test_audio.py,
`node` builds build/app.wasm and runs scripts/test_access.py."""
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# name: (file, old text, new text, test, what the change breaks)
MUTATIONS = {
    "range-upper-bound": ("game/access.mojo", "    if v < lo or v > hi:\n        raise Error(key + \": \" + String(v)", "    if v < lo:\n        raise Error(key + \": \" + String(v)", "native:access", "values above the range are accepted"),
    "shake-ignores-reduce-motion": ("game/access.mojo", "return 0.0 if self.reduce_motion else Float32(self.shake) / 100.0", "return Float32(self.shake) / 100.0", "native:access", "reduce motion no longer zeroes the shake"),
    "rows-drop-text-scale": ("game/access.mojo", "        if self.text_scale != d.text_scale:\n            out +=", "        if False:\n            out +=", "native:access", "text scale is not written to the profile"),
    "flash-step-not-scaled-by-dt": ("game/access.mojo", "Float32(self.flash_step) / 100.0 * dt * 60.0 if self.flash_limit", "Float32(self.flash_step) / 100.0 * 60.0 * 0.0166667 if self.flash_limit", "native:access", "the flash step ignores the frame time"),
    "shake-scale-ignored": ("game/camera_shake.mojo", "Real(self.offset_x(scale))", "Real(self.offset_x(1.0))", "native:access", "the x offset ignores the player's scale"),
    "shake-linear-in-trauma": ("game/camera_shake.mojo", "return self.max_offset * self.trauma * self.trauma * scale", "return self.max_offset * self.trauma * scale", "native:access", "amplitude is linear in trauma, not quadratic"),
    "protan-matrix": ("game/access_filters.mojo", "[Float32(0.152286), 1.052583,", "[Float32(0.16), 1.052583,", "native:access", "a published matrix entry is changed"),
    "correction-without-red-shift": ("game/access_filters.mojo", "            out_g = g + 0.7 * er + eg\n", "            out_g = g + eg\n", "native:access", "daltonization does not move red error into green"),
    "flash-limit-too-loose": ("game/access_filters.mojo", "    var t = step / a\n", "    var t = 2.0 * step / a\n", "native:access", "the limiter lets through twice the step"),
    "caption-speaker-always": ("game/captions.mojo", "if with_speaker and self.speaker.byte_length() > 0:", "if self.speaker.byte_length() > 0:", "native:access", "speaker names cannot be turned off"),
    "caption-stacks-repeats": ("game/captions.mojo", "                if self.active[i].event == event:\n", "                if self.active[i].event == event and False:\n", "native:access", "a repeated sound stacks captions"),
    "caption-line-cap": ("game/captions.mojo", "while len(self.active) > MAX_LINES:", "while len(self.active) > MAX_LINES + 1:", "native:access", "one caption too many stays up"),
    "caption-background-zero": ("game/captions.mojo", "            if bg > 0.0:\n", "            if True:\n", "native:access", "background opacity 0 still draws a box"),
    "caption-never-expires": ("game/captions.mojo", "            if left > 0.0:\n", "            if left > -100000.0:\n", "native:access", "captions never leave"),
    "mixer-ignores-user-volume": ("app/mixer.mojo", "                var g = self.bus_gain[b] * self.user_gain[b]\n", "                var g = self.bus_gain[b]\n", "audio:audio_mixer", "the player's bus volume is not applied"),
    "mixer-master-ignores-user-volume": ("app/mixer.mojo", "var master = self.bus_gain[BUS_MASTER] * self.user_gain[BUS_MASTER]", "var master = self.bus_gain[BUS_MASTER]", "audio:audio_mixer", "the player's master volume is not applied"),
    "mixer-mono-left-only": ("app/mixer.mojo", "                var m = (l + r) * 0.5\n", "                var m = l\n", "audio:audio_mixer", "mono copies the left channel instead of the mean"),
    "host-no-mono": ("app/access_host.mojo", "        mixer.set_mono(self.access.mono)\n", "", "audio:access_app", "the host never sets the mixer's mono flag"),
    "host-no-caption-trigger": ("app/access_host.mojo", "            _ = self.captions.trigger(mixer.events[event].name)\n", "            pass\n", "audio:access_app", "audio events raise no captions"),
    "host-text-scale-ignored": ("app/access_host.mojo", "        if self.access.text_scale != 100:\n", "        if False:\n", "audio:access_app", "the profile's text scale never reaches the HUD"),
    "gpu-deutan-matrix": ("app/access_post.mojo", "vec3<f32>(0.367322, 0.280085, -0.011820)", "vec3<f32>(0.467322, 0.280085, -0.011820)", "gpu:access_native", "a matrix entry in the shader differs from the CPU model"),
    "gpu-correction-shift": ("app/access_post.mojo", "lin.g + 0.7 * e.r + e.g, lin.b + 0.7 * e.r + e.b", "lin.g + 0.5 * e.r + e.g, lin.b + 0.5 * e.r + e.b", "gpu:access_native", "the shader's correction shift differs from the CPU model"),
    "gpu-flash-limiter-off": ("app/access_post.mojo", "  return p + (c - p) * (limit / a);\n", "  return c;\n", "gpu:access_native", "the flash limiter returns its input"),
    "gpu-reduce-motion-shutter": ("app/render3d.mojo", "f.append(Float32(0.0) if self.reduce_motion else self.shutter)", "f.append(self.shutter)", "gpu:access_native", "reduce motion leaves the shutter open"),
    "gpu-reduce-motion-blur-circle": ("app/render3d.mojo", "f.append(Float32(0.0) if self.reduce_motion else coc_scale(", "f.append(coc_scale(", "gpu:access_native", "reduce motion leaves depth of field on"),
    "profile-drops-access-rows-on-save": ("app/profile.mojo", "        var whole = text + self.access_text\n", "        var whole = text\n", "node", "a rebind erases the accessibility rows from the file"),
    "profile-ignores-access-rows-on-load": ("app/profile.mojo", " + len(access.load_rows(text))\n", " + 0\n", "node", "the settings are not restored at start"),
    "app-step-not-called": ("app/main.mojo", "        self.acc.step(self.sim.mixer, min(dt, 0.1))\n", "", "node", "the host never applies the volumes or ages captions"),
    "app-caption-trigger-removed": ("app/main.mojo", "                self.acc.heard(self.sim.mixer, self.cue_events[c.cue])\n", "", "node", "positioned cues raise no captions"),
}


def command(test: str) -> list[list[str]]:
    kind, _, name = test.partition(":")
    py = sys.executable
    if kind == "native" or kind == "gpu":
        return [[py, "scripts/test_native.py", name]]
    if kind == "audio":
        return [[py, "scripts/test_audio.py", name]]
    return [["bash", "scripts/build_wasm.sh"], [py, "scripts/test_access.py"]]


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
    out = ""
    code = 0
    try:
        src.write_text(original.replace(old, new))
        for cmd in command(test):
            p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, env=env, check=False)
            out += p.stdout + p.stderr
            code = p.returncode
            if code:
                break
    finally:
        src.write_text(original)
    failed = re.findall(r"\[FAIL\] (.*)", out)
    compile_error = ("error:" in out or "build_wasm: mojo build" in out) and not failed
    print(f"{name}: {what}; test `{test}` ->", "SURVIVED (test passed)" if code == 0 else ("COMPILE ERROR" if compile_error else "failed"))
    for line in failed[:6]:
        print("    [FAIL]", line)
    if len(failed) > 6:
        print(f"    ... and {len(failed) - 6} more")
    if compile_error:
        print(out[-800:])
    return code != 0 and not compile_error


def main() -> int:
    args = sys.argv[1:]
    if args == ["--list"]:
        for n, m in MUTATIONS.items():
            print(f"{n:36} {m[0]}: {m[4]} (test {m[3]})")
        return 0
    names = args or list(MUTATIONS)
    unknown = [n for n in names if n not in MUTATIONS]
    if unknown:
        sys.exit("unknown mutation(s): " + ", ".join(unknown))
    results = [run_one(n) for n in names]
    print(f"{sum(results)} of {len(results)} mutations were caught")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
