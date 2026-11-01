"""The native archives the shell's [native] section links (see wasm.toml): musl sinf/cosf and miniaudio's shim."""
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MA = ROOT / "build/deps/miniaudio-mojo"


def native_env() -> dict[str, str]:
    """The environment without the pixi wasm env's toolchain on PATH (its conda cc does not link on this system)."""
    env_dir = str(ROOT / ".pixi/envs/wasm")
    env = dict(os.environ)
    env["PATH"] = os.pathsep.join(p for p in env["PATH"].split(os.pathsep) if env_dir not in p)
    return env


def build_all() -> None:
    from ludens_wasm_rt import native_math
    (ROOT / "build").mkdir(exist_ok=True)
    native_math.build(ROOT / "build/libwasmrt_math.a")
    subprocess.run(["python3", "tools/build_shim_static.py"], cwd=MA, check=True, env=native_env(), capture_output=True)


def wgpu_native_present() -> bool:
    lib = ROOT / ".pixi/envs/wasm/lib"
    return (lib / "libwgpu_native.so").exists() and (lib / "libwgpu_mojo_cb.so").exists()
