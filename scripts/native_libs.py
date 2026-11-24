"""The native archives the shell's [native] section links (see wasm.toml): musl sinf/cosf and miniaudio's shim."""
import os
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MA = ROOT / "build/deps/miniaudio-mojo"


def native_env() -> dict[str, str]:
    """The environment without the pixi wasm env's toolchain on PATH (its conda cc does not link on this system)."""
    env_dir = str(ROOT / ".pixi/envs/wasm")
    env = dict(os.environ)
    env["PATH"] = os.pathsep.join(p for p in env["PATH"].split(os.pathsep) if env_dir not in p)
    return env


# Two things in miniaudio's C make a native result depend on the machine, and neither exists in the wasm build:
#  - ma_rsqrtf is the x86 `rsqrtss` instruction, an approximation (about 12 bits) that differs between CPU models, and the
#    spatializer normalizes every direction with it. -DMA_NO_SSE2 makes it 1 / sqrt(x), as in wasm. Without it the native gain at
#    7 m was 0.035723 against 0.035714 from the model and from wasm64.
#  - a C compiler that fuses a * b + c into one fused multiply-add changes the last bit. wasm64 never fuses; a compiler whose default
#    target has FMA does (the CI runner's: audio-same failed there with 11483798732328314178 for the moving-source scene, and the
#    same hash is reproduced here with -mfma -ffp-contract=fast). -ffp-contract=off forbids it on every compiler and CPU.
# scripts/audio_same.py compares the output byte for byte; scripts/mutate_audio.py breaks each flag and expects it to fail.
SHIM_FLAGS = ["-DMA_NO_SSE2", "-ffp-contract=off"]


def build_shim() -> None:
    """build/deps/miniaudio-mojo/build/libma_shim.a: the sources and flags of that repo's tools/build_shim_static.py, plus SHIM_FLAGS."""
    out_dir = MA / "build" / "static_ludens"
    archive = MA / "build" / "libma_shim.a"
    out_dir.mkdir(parents=True, exist_ok=True)
    sources = sorted((MA / "src" / "native").glob("ma_shim*.c")) + [MA / "vendor" / "miniaudio" / "miniaudio.c"]
    headers = sorted((MA / "src" / "native").glob("*.h")) + [MA / "vendor" / "miniaudio" / "miniaudio.h"]
    flags = ["-O2", "-fPIC", f"-I{MA / 'vendor' / 'miniaudio'}", f"-I{MA / 'src' / 'native'}", *SHIM_FLAGS]
    stamp = out_dir / "flags.txt"
    if not stamp.exists() or stamp.read_text() != " ".join(flags):
        for old in out_dir.glob("*.o"):
            old.unlink()
        stamp.write_text(" ".join(flags))

    def compile_one(src: Path) -> Path:
        obj = out_dir / (src.stem + ".o")
        if not obj.exists() or obj.stat().st_mtime < max(p.stat().st_mtime for p in [src, *headers]):
            subprocess.run(["cc", *flags, "-c", str(src), "-o", str(obj)], check=True, env=native_env(), capture_output=True)
        return obj

    with ThreadPoolExecutor() as pool:
        objs = list(pool.map(compile_one, sources))
    if not archive.exists() or archive.stat().st_mtime < max(o.stat().st_mtime for o in objs):
        archive.unlink(missing_ok=True)
        subprocess.run(["ar", "rcs", str(archive), *map(str, objs)], check=True, env=native_env())


def build_all() -> None:
    from ludens_wasm_rt import native_math
    (ROOT / "build").mkdir(exist_ok=True)
    native_math.build(ROOT / "build/libwasmrt_math.a")
    build_shim()


def wgpu_native_present() -> bool:
    lib = ROOT / ".pixi/envs/wasm/lib"
    return (lib / "libwgpu_native.so").exists() and (lib / "libwgpu_mojo_cb.so").exists()
