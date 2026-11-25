#!/usr/bin/env python3
"""Show that each frame-budget test fails under one deliberate change to the code it tests (#123).

    pixi run -e wasm mutation-perf --list
    pixi run -e wasm mutation-perf                  # every mutation, one after the other
    pixi run -e wasm mutation-perf gate-ignores-failures   # one

Each mutation replaces one exact string in one source file, runs the covering test and prints its failed checks. The file is
restored afterwards, also when the run is interrupted. A mutation whose test still passes is reported as SURVIVED and makes the
exit code 1: the test does not look at that behaviour. A test that exits non-zero without naming a failed check (a crash, a compile
error, a timeout) is also an escape: only a named failed check counts as caught. A test is either a native Mojo test (scripts/test_native.py NAME) or
tests/test_perf_gate.py with the named sections. The GPU tests need lavapipe (see .github/workflows/parity.yml); the
environment variables are set as there."""
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FS = "frame_stats"
FC = "frame_counters_native"
GT = "gpu_timer_native"
PG = "perf_gate"  # tests/test_perf_gate.py; the sections after a colon

# name: (file, old text, new text, test, what the change breaks)
MUTATIONS = {
    "p95-rank": ("app/frame_stats.mojo", "return max((pct * n + 99) // 100 - 1, 0)", "return max(pct * n // 100, 0)", FS, "the percentile picks the element after the nearest rank"),
    "avg-off-by-one": ("app/frame_stats.mojo", "out[0] = UInt64(sum // Int64(n))", "out[0] = UInt64(sum // Int64(n + 1))", FS, "the average divides by n + 1"),
    "ring-256": ("app/frame_stats.mojo", "comptime FRAME_RING = 300", "comptime FRAME_RING = 256", FS, "the ring keeps 256 frames, not 300"),
    "oldest-first": ("app/frame_stats.mojo", "return k if self.filled < FRAME_RING else (self.head + k) % FRAME_RING", "return k", FS, "the ring export starts at slot 0 after it wrapped"),
    "audio-dropped": ("app/frame_stats.mojo", "            self.cur[SEG_AUDIO] = self.audio_pending\n", "", FS, "mixer time is never attached to a frame"),
    "audio-kept": ("app/frame_stats.mojo", "            self.audio_pending = -1\n        var base", "        var base", FS, "mixer time is counted again in every later frame"),
    "absent-as-zero": ("app/frame_stats.mojo", "        for s in range(SEGMENTS):\n            self.cur[s] = -1\n", "        for s in range(SEGMENTS):\n            self.cur[s] = 0\n", FS, "a segment that did not run records 0 instead of -1"),
    "counter-max": ("app/frame_stats.mojo", "            mx = max(mx, v)\n", "            mx = v\n", FS, "the counter maximum is the last value"),
    "overlay-gpu-row": ("app/perf_overlay.mojo", "    if not gpu_seen:", "    if False:", FS, "the overlay never says the GPU rows are absent"),
    "overlay-ms": ("app/perf_overlay.mojo", "var us = (Int(ns) + 500) // 1000", "var us = Int(ns) // 1000", FS, "milliseconds are cut, not rounded"),
    "mesh-triangles": ("app/mesh_pass.mojo", "out.triangles += n_idx // 3 * self.batches.counts[k]", "out.triangles += n_idx // 2 * self.batches.counts[k]", FC, "a mesh triangle is counted as 2 indices"),
    "mesh-draws-per-item": ("app/mesh_pass.mojo", "            out.draws += 1\n            out.triangles += n_idx // 3 * self.batches.counts[k]", "            out.draws += self.batches.counts[k]\n            out.triangles += n_idx // 3 * self.batches.counts[k]", FC, "draw calls are counted per instance, not per batch"),
    "primitive-instances": ("app/primitive_pass.mojo", "DrawCounts(1, VERTS_PER_INSTANCE // 3 * self.count)", "DrawCounts(1, VERTS_PER_INSTANCE // 3)", FC, "the primitive pass counts one instance"),
    "hud-draw": ("app/hud.mojo", "return (1 if self.verts > 0 else 0) + (1 if self.glyph_verts > 0 and self.glyph_pipeline else 0)", "return 0", FC, "the HUD's draw is not counted"),
    "texture-no-mips": ("app/gpu_bytes.mojo", "    for l in range(levels):", "    for l in range(min(levels, 1)):", FC, "texture bytes ignore the mip chain"),
    "texture-no-layers": ("app/gpu_bytes.mojo", "mip_chain_texels(width, height, levels) * layers * bytes_per_texel(format)", "mip_chain_texels(width, height, levels) * bytes_per_texel(format)", FC, "texture bytes ignore the array layers"),
    "texture-array-one-layer": ("app/textures.mojo", "Int(TEX_SIZE), Int(TEX_SIZE), Int(self.layers), Int(TEX_LEVELS)", "Int(TEX_SIZE), Int(TEX_SIZE), 1, Int(TEX_LEVELS)", FC, "the texture array is counted as one layer"),
    "depth-not-counted": ("app/render3d.mojo", "        n += texture_bytes(sw, sh, 1, 1, DEPTH_FORMAT)  # the scene's depth\n", "", FC, "the frame's depth buffer is not counted"),
    "counts-not-set": ("app/render3d.mojo", "        self.counts = self.passes.counts(self.meshes) + DrawCounts(hud.draws(), hud.triangles())\n", "", FC, "the renderer never records its counts"),
    "timer-no-resolve": ("app/gpu_timer.mojo", "        if self.marks >= 2:\n            enc.resolve_query_set", "        if self.marks >= 99:\n            enc.resolve_query_set", GT, "the timestamps are never resolved"),
    "timer-one-slot": ("app/gpu_timer.mojo", "enc.write_timestamp(self.queries, UInt32(self.marks))", "enc.write_timestamp(self.queries, UInt32(0))", GT, "every mark writes slot 0"),
    "gpu-total-sum": ("app/render3d.mojo", "            out[3] = total", "            out[3] = spans[0]", "gpu_total", "the whole-frame GPU time is the first pass only"),
    "bodies-zero": ("game/demo_mode.mojo", "c.bodies = len(self.world.bodies())", "c.bodies = 0", f"{PG}:native,wasm", "the demo game reports no bodies"),
    "ai-default": ("game/mode.mojo", "        return -1\n\n    def counters", "        return 0\n\n    def counters", "game_mode", "a game with no AI reports 0 ns instead of -1"),
    "gate-equal-fails": ("scripts/perf_gate.py", "elif measured[\"counters\"][name] > limit:", "elif measured[\"counters\"][name] >= limit:", f"{PG}:check", "a counter equal to its budget fails"),
    "gate-p95-fails": ("scripts/perf_gate.py", "warnings.append(f\"p95 of `{name}`:", "failures.append(f\"p95 of `{name}`:", f"{PG}:check", "a p95 over its budget fails instead of warning"),
    "gate-ignores-failures": ("scripts/perf_gate.py", "return 1 if failures else 0", "return 0", f"{PG}:gate", "the gate exits 0 on a breach"),
    "gate-unknown-key": ("scripts/perf_gate.py", "            if k not in KEYS[table]:", "            if False:", f"{PG}:budgets", "a mistyped key is accepted"),
    "gate-ring-short": ("scripts/perf_gate.py", "    if scene[\"frames\"] < L.FRAME_RING:", "    if False:", f"{PG}:budgets", "a scene shorter than the ring is accepted"),
    "post-mid-not-counted": ("app/post.mojo", "return self.mid_bytes + self.first.target_bytes() + self.second.target_bytes()", "return self.first.target_bytes() + self.second.target_bytes()", FC, "the texture between ThenPost's two parts is not counted"),
    "join-targets-not-counted": ("app/post.mojo", "return self.target_size + self.a.target_bytes()", "return self.a.target_bytes()", FC, "the two textures a Join makes are not counted"),
    "post-bytes-not-summed": ("app/render3d.mojo", "        n += self.post.target_bytes()  # the targets between the post stages (ThenPost, Join)\n", "", FC, "the renderer ignores the post effect's targets"),
    "gate-unique": ("scripts/perf_gate.py", "        if x not in out:\n            out.append(x)", "        out.append(x)", f"{PG}:check", "a finding every run makes is reported once per run"),
    "msaa-not-counted": ("app/render3d.mojo", "            n += self.msaa.value().bytes  # the multisampled colour and depth\n", "            n += 0\n", FC, "the multisampled targets are not counted"),
    "msaa-one-sample": ("app/msaa.mojo", ") * Int(MSAA_SAMPLES)\n", ")\n", FC, "the multisampled targets are counted as one sample"),
    "lut-not-counted": ("app/render3d.mojo", "        n += self.lut_bytes\n", "", FC, "the colour-grading LUT is not counted"),
    "bloom-not-counted": ("app/post_fx.mojo", "    def target_bytes(self) raises -> Int:\n        return self.target_size\n", "    def target_bytes(self) raises -> Int:\n        return 0\n", FC, "the bloom chain is not counted"),
    "mark-after-scene-missing": ("app/render3d.mojo", "            self._mark(enc)  # after the scene pass (single-sample or multisampled)\n", "", GT, "no timestamp after the scene pass: the scene and post spans merge"),
    "f3-never-hides": ("app/main.mojo", "            self.perf_shown = not self.perf_shown\n", "            self.perf_shown = True\n", "web", "F3 shows the overlay but a second F3 does not hide it"),
    "bodies-not-set-in-host": ("app/main.mojo", "        self.stats.set_counter(CTR_BODIES, gc.bodies)\n", "", "web", "the host never records the game's body count"),
    "texture-bytes-not-set-in-host": ("app/main.mojo", "        self.stats.set_counter(CTR_TEXTURE_BYTES, self.game_renderer.value().tex_bytes)\n", "", "web", "the host never records the renderer's texture bytes"),
    "trace-nesting": ("scripts/frame_trace.py", "                    inner = cur\n", "                    inner = cur + 1e9\n", f"{PG}:trace", "physics is drawn outside step"),
}


def command(test: str) -> list[str]:
    if test == "web":  # headless Chrome: the F3 overlay and the counters through app_frame_stats
        return [sys.executable, "scripts/perf_overlay_web.py"]
    if test == "gpu_total":  # the whole-frame GPU time is read through the native run of the gate test
        return [sys.executable, "tests/test_perf_gate.py", "native"]
    if test.startswith(PG + ":"):
        return [sys.executable, "tests/test_perf_gate.py", *test.split(":")[1].split(",")]
    return [sys.executable, "scripts/test_native.py", test]


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
        p = subprocess.run(command(test), cwd=ROOT, capture_output=True, text=True, env=env, check=False)
    finally:
        src.write_text(original)
    out = p.stdout + p.stderr
    failed = re.findall(r"\[FAIL\] (.*)", out)
    problems = "problems:" in out  # scripts/perf_overlay_shot.mjs names what failed under this heading
    compile_error = "error:" in out and not failed and not problems and p.returncode != 0
    # A mutation is caught only when the test says which check failed. A non-zero exit with no failed check (a crash, a
    # timeout, a signal) is not evidence that the test looks at the behaviour, so it counts as an escape.
    caught = p.returncode != 0 and bool(failed or problems)
    verdict = "SURVIVED (test passed)" if p.returncode == 0 else ("COMPILE ERROR (escape)" if compile_error else ("failed" if caught else "CRASH, no failed check (escape)"))
    print(f"{name}: {what}; test `{test}` ->", verdict)
    for line in failed:
        print("    [FAIL]", line)
    if compile_error or (p.returncode != 0 and not caught):
        print(out[-800:])
    return caught


def main() -> int:
    args = sys.argv[1:]
    if args == ["--list"]:
        for n, m in MUTATIONS.items():
            print(f"{n:24} {m[0]}: {m[4]} (test {m[3]})")
        return 0
    names = args or list(MUTATIONS)
    for n in names:
        if n not in MUTATIONS:
            sys.exit(f"unknown mutation `{n}` (--list shows them)")
    results = {n: run_one(n) for n in names}
    survived = [n for n, ok in results.items() if not ok]
    print(f"\n{len(results) - len(survived)} of {len(results)} mutations were caught" + (f"; SURVIVED: {', '.join(survived)}" if survived else ""))
    return 1 if survived else 0


if __name__ == "__main__":
    sys.exit(main())
