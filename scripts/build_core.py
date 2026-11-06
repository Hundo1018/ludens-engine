#!/usr/bin/env python3
"""Build native Mojo entries of the editor core (no GPU) with the pixi env's mojo and the system linker.

    pixi run -e wasm build-core            # build/ludens-core, rebuilt only when a source is newer

The pixi env's conda cc does not link on every system, so the build runs with that env's bin dir off PATH
(native_libs.native_env); mojo itself is called by absolute path so it still finds its standard library.
LUDENS_ENGINE points at an engine source tree instead of the pinned build/deps/ludens-engine (development)."""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import native_libs  # noqa: E402


def engine_dir() -> Path:
    return Path(os.environ.get("LUDENS_ENGINE", ROOT / "build/deps/ludens-engine"))


def newest(paths) -> float:
    return max((p.stat().st_mtime for p in paths), default=0.0)


def build_native(entry: str, out: Path, *, asserts: bool = False, force: bool = False, engine: bool = True, defines: tuple = ()) -> Path:
    """Build `entry` (relative to the repo) to `out`. Raises SystemExit with the compiler output on failure.

    `engine=False` builds with the standard library only (the `ui/` tests: that directory must stand alone)."""
    sources = [*ROOT.glob("editor/**/*.mojo"), *ROOT.glob("ui/**/*.mojo"), *ROOT.glob("game/**/*.mojo"), ROOT / entry]
    includes = ["-I", "."]
    if engine:
        if "LUDENS_ENGINE" not in os.environ:
            subprocess.run(["bash", "scripts/deps.sh"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
        sources += list(engine_dir().glob("embed/*.mojo"))
        includes = ["-I", str(engine_dir()), "-I", "."]
    if not force and out.exists() and out.stat().st_mtime >= newest(sources):
        return out
    out.parent.mkdir(exist_ok=True)
    mojo = Path(os.environ["CONDA_PREFIX"]) / "bin/mojo"
    cmd = [str(mojo), "build", *(["-D", "ASSERT=all"] if asserts else []), *[x for d in defines for x in ("-D", d)], *includes, entry, "-o", str(out)]
    proc = subprocess.run(cmd, cwd=ROOT, env=native_libs.native_env(), capture_output=True, text=True)
    if proc.returncode:
        sys.exit(proc.stdout + proc.stderr)
    return out


def core() -> Path:
    return build_native("editor/core_main.mojo", ROOT / "build/ludens-core")


def core_trace() -> Path:
    """The same core built with `-D LUDENS_TRACE=True`: the engine's profiling spans are recorded (`ludens trace`)."""
    return build_native("editor/core_main.mojo", ROOT / "build/ludens-core-trace", defines=("LUDENS_TRACE=True",))


if __name__ == "__main__":
    print(core())
