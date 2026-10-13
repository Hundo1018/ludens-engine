"""Floating-point factor probe (ROADMAP 17.76).

Which compiler / target factors change simulation bits? Compiles
`benchmarks/probes/fp_probe.mojo` (three scenes, 300 steps) under each
variant, runs it, and compares each scene's state hash and largest
coordinate drift against the reference (skylake, default optimisation).

Variants: CPU targets (x86-64 baseline without FMA, x86-64-v3 / haswell,
skylake, skylake-avx512, the host CPU) and optimisation levels -O0 .. -O3.
A target the host cannot run is skipped.

    pixi run fp-probe
    pixi run fp-probe -- --selftest   # parser check on a synthetic output
"""

import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBE = "benchmarks/probes/fp_probe.mojo"

VARIANTS = [
    ("skylake -O (reference)", ["--target-cpu", "skylake"]),
    ("skylake -O0", ["--target-cpu", "skylake", "-O0"]),
    ("skylake -O1", ["--target-cpu", "skylake", "-O1"]),
    ("skylake -O2", ["--target-cpu", "skylake", "-O2"]),
    ("x86-64 (no FMA, SSE2)", ["--target-cpu", "x86-64"]),
    ("haswell (AVX2 + FMA)", ["--target-cpu", "haswell"]),
    ("skylake-avx512", ["--target-cpu", "skylake-avx512"]),
    ("native host CPU", []),
]


def parse(text):
    """{scene: (hash, [floats])}"""
    out = {}
    lines = text.strip().split("\n")
    for i, l in enumerate(lines):
        if l.startswith("HASH "):
            _, name, h = l.split()
            vals = [float(x) for x in lines[i + 1].split()[1:]]
            out[name] = (int(h), vals)
    return out


def run(flags, d):
    exe = os.path.join(d, "fp")
    b = subprocess.run(["mojo", "build"] + flags + ["-I", "build", PROBE, "-o", exe], cwd=ROOT, capture_output=True, text=True)
    if b.returncode != 0:
        return None, b.stderr.strip().split("\n")[-1]
    r = subprocess.run([exe], cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        return None, "run failed: " + r.stderr.strip()[-200:]
    return parse(r.stdout), ""


def main():
    if "--selftest" in sys.argv:
        p = parse("HASH a 42\na 1.0 2.5\nHASH b 7\nb 3.0\n")
        assert p["a"] == (42, [1.0, 2.5]) and p["b"] == (7, [3.0])
        print("fp-probe selftest: 1 / 1")
        return
    with tempfile.TemporaryDirectory() as d:
        ref = None
        print("| variant | pile | roll | tower |")
        print("|---|---|---|---|")
        for name, flags in VARIANTS:
            res, err = run(flags, d)
            if res is None:
                print("| %s | skipped: %s | | |" % (name, err[:60]))
                continue
            if ref is None:
                ref = res
            cells = []
            for scene in ("pile", "roll", "tower"):
                h, vals = res[scene]
                rh, rvals = ref[scene]
                if h == rh:
                    cells.append("identical")
                else:
                    drift = max(abs(a - b) for a, b in zip(vals, rvals))
                    cells.append("differs, max drift %.2e" % drift)
            print("| %s | %s |" % (name, " | ".join(cells)))


if __name__ == "__main__":
    main()
