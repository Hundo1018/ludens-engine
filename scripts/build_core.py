#!/usr/bin/env python3
"""Build native Mojo entries of the editor core (no GPU) with the pixi env's mojo and the system linker.

    pixi run -e wasm build-core            # build/ludens-core, rebuilt only when a source is newer

The pixi env's conda cc does not link on every system, so the build runs with that env's bin dir off PATH
(native_libs.native_env); mojo itself is called by absolute path so it still finds its standard library.
LUDENS_CORE_SRC points at a ludens-core source tree instead of the pinned build/deps/ludens-core (development);
LUDENS_ENGINE is still read, as its old name. (LUDENS_CORE is something else: the editor core binary, scripts/ludens.py.)"""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import native_libs  # noqa: E402


def engine_dir() -> Path:
    override = os.environ.get("LUDENS_CORE_SRC") or os.environ.get("LUDENS_ENGINE")
    return Path(override) if override else ROOT / "build/deps/ludens-core"


def newest(paths) -> float:
    return max((p.stat().st_mtime for p in paths), default=0.0)


def native_sources(entry: str, engine: bool = True) -> list:
    """Every file a native build of `entry` can read: the binary is rebuilt when any of them is newer. With `engine`,
    that is all of this repo's packages (app/ included: tests import app.mesh_pass, app.ao_bake, ...), every package of
    the ludens-core checkout and wgpu-mojo's sources, since the include path is `-I <core> -I wgpu-mojo -I app -I .`."""
    sources = [ROOT / entry]
    for d in ("editor", "ui", "game"):
        sources += ROOT.glob(d + "/**/*.mojo")
    if engine:
        sources += ROOT.glob("app/**/*.mojo")
        sources += engine_dir().glob("*/*.mojo")
        sources += (ROOT / "build/deps/wgpu-mojo/wgpu").glob("**/*.mojo")
    return sources


def build_native(entry: str, out: Path, *, asserts: bool = False, force: bool = False, engine: bool = True, defines: tuple = ()) -> Path:
    """Build `entry` (relative to the repo) to `out`. Raises SystemExit with the compiler output on failure.

    `engine=False` builds with the standard library only (the `ui/` tests: that directory must stand alone)."""
    includes = ["-I", "."]
    if engine:
        if "LUDENS_CORE_SRC" not in os.environ and "LUDENS_ENGINE" not in os.environ:
            subprocess.run(["bash", "scripts/deps.sh"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
        # app/ too, with wgpu-mojo: a test can drive the shell's own device code (InputState -> Keys) natively.
        includes = ["-I", str(engine_dir()), "-I", str(ROOT / "build/deps/wgpu-mojo"), "-I", "app", "-I", "."]
    sources = native_sources(entry, engine)
    if not force and out.exists() and out.stat().st_mtime >= newest(sources):
        return out
    out.parent.mkdir(exist_ok=True)
    mojo = Path(os.environ["CONDA_PREFIX"]) / "bin/mojo"
    cmd = [str(mojo), "build", *(["-D", "ASSERT=all"] if asserts else []), *[x for d in defines for x in ("-D", d)], *includes, entry, "-o", str(out)]
    proc = subprocess.run(cmd, cwd=ROOT, env=native_libs.native_env(), capture_output=True, text=True, check=False)
    if proc.returncode:
        sys.exit(proc.stdout + proc.stderr)
    return out


def core() -> Path:
    return build_native("editor/core_main.mojo", ROOT / "build/ludens-core")


def core_trace() -> Path:
    """The same core built with `-D LUDENS_TRACE=True`: the engine's profiling spans are recorded (`ludens trace`)."""
    return build_native("editor/core_main.mojo", ROOT / "build/ludens-core-trace", defines=("LUDENS_TRACE=True",))


def core_overlay() -> Path:
    """The same core built with `-D LUDENS_DEBUG_DRAW=True`: the solver pushes one arrow per contact point (`ludens overlay`)."""
    return build_native("editor/core_main.mojo", ROOT / "build/ludens-core-overlay", defines=("LUDENS_DEBUG_DRAW=True",))


def selftest() -> int:
    """The freshness list covers what a native test can import (a test binary was once kept after app/mesh_pass.mojo
    changed, because only app/controls.mojo was watched)."""
    with_engine = {str(p) for p in native_sources("tests/mesh_pass.mojo")}
    alone = {str(p) for p in native_sources("tests/ui_layout.mojo", engine=False)}
    checks = {
        "an app/ module a test imports is watched": str(ROOT / "app/mesh_pass.mojo") in with_engine,
        "the entry itself is watched": str(ROOT / "tests/mesh_pass.mojo") in with_engine,
        "ludens-core's packages are watched": any(p.endswith("/embed/world.mojo") for p in with_engine)
        and any(p.endswith("/physics/solver6.mojo") for p in with_engine),
        "wgpu-mojo's sources are watched": any("/wgpu-mojo/wgpu/" in p for p in with_engine),
        "a ui test watches no app/ file": not any("/app/" in p for p in alone),
    }
    for label, ok in checks.items():
        print("  [PASS]" if ok else "  [FAIL]", label)
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    print(core())
