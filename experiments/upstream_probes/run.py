"""Run every probe behind docs/upstream/PRIORITY.md against one Mojo toolchain.

Each case has an outcome predicted before the first run. The script prints
one row per case (predicted, observed, match) and exits non-zero if any row
does not match, so a new Mojo release that changes an outcome shows up.

Usage:
    python3 experiments/upstream_probes/run.py <path to mojo> [--runs N]
"""
import argparse
import pathlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).parent


def sh(args, cwd=None):
    r = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=900)
    return r.returncode, r.stdout + r.stderr


def build(mojo, args, out):
    code, text = sh([mojo, "build", *args], cwd=out)
    if code != 0:
        raise RuntimeError(text[-1500:])


def single_file_cases(mojo, out):
    """(name, predicted, observed) for probes that are one `mojo run`/`build`."""
    rows = []

    def run(name):
        return sh([mojo, "run", str(HERE / name)])

    code, text = run("probe_global_var.mojo")
    rows.append(("module-level var rejected", "error",
                 "error" if "global variables are not supported" in text else f"exit {code}"))

    code, text = sh([mojo, "build", "--target-triple", "wasm32-unknown-unknown",
                     str(HERE / "probe_wasm_target.mojo"), "-o", f"{out}/p.wasm"])
    rows.append(("wasm32 triple rejected", "error",
                 "error" if "No available targets" in text else f"exit {code}"))

    code, text = run("probe_extcall_two_sigs.mojo")
    rows.append(("external_call, one symbol, two signatures", "error",
                 "error" if "conflicting signature" in text else f"exit {code}"))

    code, text = run("probe_thin_field.mojo")
    rows.append(("`def(Int) thin -> Int` struct field", "42",
                 "42" if "thin_field_call= 42" in text else f"exit {code}"))

    code, text = run("probe_type_eq.mojo")
    ok = "Int,Int= True" in text and "Int,Int64= False" in text and "List[Float32]= False" in text
    rows.append(("type identity via reflect[T].name", "correct", "correct" if ok else f"exit {code}"))

    code, text = run("probe_stdlib_global.mojo")
    rows.append(("std.ffi._Global counter", "3",
                 "3" if "global_counter_after_3= 3" in text else f"exit {code}"))
    return rows


def unload_cases(mojo, out, runs):
    """Hosts that unload a Mojo shared library before exit, and their controls."""
    build(mojo, ["--emit", "shared-lib", str(HERE / "plugin_rand.mojo"),
                 "-o", f"{out}/libplugin_rand.so"], out)
    build(mojo, [str(HERE / "host_rand.mojo"), "-o", f"{out}/host_rand"], out)
    for v in ("v1", "v100"):
        build(mojo, ["--emit", "shared-lib", str(HERE / f"lib_global_{v}.mojo"),
                     "-o", f"{out}/libglobal_{v}.so"], out)
    build(mojo, [str(HERE / "host_swap_global.mojo"), "-o", f"{out}/host_swap_global"], out)

    rows = []
    for host, label in (("host_rand", "plugin used std.random"),
                        ("host_swap_global", "_Global across a swap")):
        for keep, predicted in ((False, "SIGSEGV"), (True, "0")):
            codes, survived = [], True
            for _ in range(runs):
                args = [f"{out}/{host}", out] + (["keep"] if keep else [])
                r = subprocess.run(args, capture_output=True, text=True)
                codes.append(r.returncode)
                if host == "host_swap_global" and "survived= True" not in r.stdout:
                    survived = False
            if all(c == -11 for c in codes):
                observed = "SIGSEGV"
            elif all(c == 0 for c in codes):
                observed = "0"
            else:
                observed = str(codes)
            mode = "kept loaded" if keep else "unloaded"
            rows.append((f"{label}, {mode}: exit ({runs} runs)", predicted, observed))
            if host == "host_swap_global":
                rows.append((f"{label}, {mode}: counter 1, 2, 102", "yes", "yes" if survived else "no"))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mojo")
    ap.add_argument("--runs", type=int, default=5)
    a = ap.parse_args()
    a.mojo = str(pathlib.Path(a.mojo).resolve())

    _, ver = sh([a.mojo, "--version"])
    print(ver.strip().splitlines()[-1])
    with tempfile.TemporaryDirectory() as out:
        rows = single_file_cases(a.mojo, out) + unload_cases(a.mojo, out, a.runs)

    width = max(len(r[0]) for r in rows)
    bad = 0
    for name, predicted, observed in rows:
        match = predicted == observed
        bad += not match
        print(f"{name:<{width}}  predicted={predicted:<8} observed={observed:<8} {'ok' if match else 'MISMATCH'}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
