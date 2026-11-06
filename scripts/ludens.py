#!/usr/bin/env python3
"""ludens: the command line of the editor core (ludens-shell #11).

    ludens new <dir>                    create a project: ludens.toml + a demo scene
    ludens hash | list | check          the world hash, the bodies (index, handle, position), validate the scene
    ludens run <ticks> [-o OUT]         step the scene and print the world hash
    ludens cmd [-o OUT] <name> <args>   run one editor command on the scene, in place
    ludens script <file> [-o OUT]       run a file of commands (one per line, `#` comments, `undo`, `redo`)
    ludens build --target web           build build/web (wasm64 module + JS) and MANIFEST.sha256
    ludens capture <ticks> -o OUT.cap   record every tick;  ludens replay <file.cap>  verify it, naming the first bad frame
    ludens trace <ticks> -o OUT.json    step the scene with profiling spans on and write a Chrome trace (Perfetto) file
    ludens overlay <ticks> -o OUT.json  step the scene with the physics debug-draw on; prints the arrow count, writes the last frame as JSON

Everything runs in `ludens-core`, the native build of the editor's Mojo command layer, so what the GUI does is what
these do. Nothing is written when a command fails. Subcommands for assets, builds and replay follow with their
issues (#12, #15, #13).

The project is the nearest directory upward with a ludens.toml (`scene = "world.scene"` names the scene file);
`--project DIR` names it. `LUDENS_CORE` points at a core binary instead of building one."""
import argparse
import os
import subprocess
import sys
import json
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))


def core_path() -> Path:
    if "LUDENS_CORE" in os.environ:
        return Path(os.environ["LUDENS_CORE"])
    import build_core
    return build_core.core()


def run_core(*args: str) -> int:
    return subprocess.run([str(core_path()), *args]).returncode


def find_project(explicit: str | None) -> Path:
    if explicit:
        d = Path(explicit).resolve()
        if not (d / "ludens.toml").exists():
            sys.exit(f"ludens: no ludens.toml in {d}")
        return d
    d = Path.cwd().resolve()
    for p in [d, *d.parents]:
        if (p / "ludens.toml").exists():
            return p
    sys.exit("ludens: no ludens.toml here or in a parent directory (ludens new <dir> makes a project)")


def scene_of(project: Path) -> str:
    cfg = tomllib.loads((project / "ludens.toml").read_text(encoding="utf-8"))
    return str(project / cfg.get("scene", "world.scene"))


def cmd_new(a) -> int:
    d = Path(a.dir)
    if (d / "ludens.toml").exists():
        sys.exit(f"ludens: {d} already has a ludens.toml")
    d.mkdir(parents=True, exist_ok=True)
    (d / "ludens.toml").write_text(f'name = "{d.resolve().name}"\nscene = "world.scene"\n', encoding="utf-8")
    return run_core("demo", str(d / "world.scene"))


def cmd_run(a) -> int:
    extra = ["-o", a.output] if a.output else []
    return run_core("run", scene_of(find_project(a.project)), str(a.ticks), *extra)


def cmd_trace(a) -> int:
    """Step the scene with the engine's profiling spans on and write a Chrome Trace / Perfetto JSON file."""
    import build_core
    out = Path(a.output)
    rc = subprocess.run([str(build_core.core_trace()), "trace", scene_of(find_project(a.project)), str(a.ticks), str(out)]).returncode
    if rc:
        return rc
    events = json.loads(out.read_text(encoding="utf-8"))
    names = sorted({e["name"] for e in events})
    print(f"trace: {len(events)} events, {len(names)} span names ({', '.join(names)}) -> {out}")
    return 0


def cmd_overlay(a) -> int:
    """Step the scene with the physics debug-draw compiled in: one arrow per contact point per step."""
    import build_core
    return subprocess.run([str(build_core.core_overlay()), "overlay", scene_of(find_project(a.project)), str(a.ticks), a.output]).returncode


def cmd_build(a) -> int:
    """`ludens build --target web`: the wasm64 module and the shell's JS assembled in build/web, with MANIFEST.sha256
    (one `sha256  size  path` line per file, sorted) so two builds of the same commit can be compared."""
    import hashlib
    if a.target != "web":
        print(f"ludens: build --target {a.target} is not implemented yet (web only); native needs the wgpu native libraries and an app entry (ludens-shell #15)", file=sys.stderr)
        return 2
    rc = subprocess.run(["bash", str(ROOT / "scripts/build_wasm.sh")], cwd=ROOT).returncode
    if rc:
        return rc
    rc = subprocess.run([sys.executable, str(ROOT / "scripts/build_web.py")], cwd=ROOT).returncode
    if rc:
        return rc
    out = ROOT / "build/web"
    lines = []
    total = 0
    for f in sorted(p for p in out.rglob("*") if p.is_file() and p.name != "MANIFEST.sha256"):
        data = f.read_bytes()
        total += len(data)
        lines.append(f"{hashlib.sha256(data).hexdigest()}  {len(data)}  {f.relative_to(out).as_posix()}")
    (out / "MANIFEST.sha256").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"build: {len(lines)} files, {total} bytes in {out} (config {a.config}); manifest {out / 'MANIFEST.sha256'}")
    for l in lines:
        h, n, name = l.split("  ")
        print(f"  {int(n):>10}  {name}")
    return 0


def cmd_capture(a) -> int:
    return run_core("capture", scene_of(find_project(a.project)), str(a.ticks), a.output)


def cmd_replay(a) -> int:
    """Check a capture file against a re-simulation of the project's scene; exit 1 and name the first frame that differs."""
    return run_core("replay", scene_of(find_project(a.project)), a.capture)


def cmd_cmd(a) -> int:
    rest = a.rest[1:] if a.rest[:1] == ["--"] else a.rest
    if not rest:
        sys.exit("ludens: cmd needs a command name")
    extra = ["-o", a.output] if a.output else []
    return run_core("cmd", scene_of(find_project(a.project)), *extra, "--", *rest)


def cmd_script(a) -> int:
    extra = ["-o", a.output] if a.output else []
    return run_core("script", scene_of(find_project(a.project)), a.file, *extra)


def simple(sub: str):
    return lambda a: run_core(sub, scene_of(find_project(a.project)))


def main() -> int:
    ap = argparse.ArgumentParser(prog="ludens", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--project", help="project directory (default: the nearest ludens.toml upward)")
    sp = ap.add_subparsers(dest="sub", required=True)

    p = sp.add_parser("new", help="create a project")
    p.add_argument("dir")
    p.set_defaults(f=cmd_new)
    for name in ("hash", "list", "check"):
        p = sp.add_parser(name, help=f"{name} of the project's scene")
        p.set_defaults(f=simple(name))
    p = sp.add_parser("run", help="step the scene")
    p.add_argument("ticks", type=int)
    p.add_argument("-o", "--output")
    p.set_defaults(f=cmd_run)
    p = sp.add_parser("build", help="build the game: --target web writes build/web (module, JS, manifest)")
    p.add_argument("--target", choices=["web", "native", "android"], default="web")
    p.add_argument("--config", choices=["debug", "release"], default="release")
    p.set_defaults(f=cmd_build)
    p = sp.add_parser("capture", help="step the scene and record every tick to a capture file")
    p.add_argument("ticks", type=int)
    p.add_argument("-o", "--output", required=True)
    p.set_defaults(f=cmd_capture)
    p = sp.add_parser("replay", help="verify a capture file against a re-simulation; names the first frame that differs")
    p.add_argument("capture")
    p.set_defaults(f=cmd_replay)
    p = sp.add_parser("trace", help="step the scene and write a Chrome trace (Perfetto) JSON")
    p.add_argument("ticks", type=int)
    p.add_argument("-o", "--output", required=True)
    p.set_defaults(f=cmd_trace)
    p = sp.add_parser("overlay", help="step the scene with the physics debug-draw on; write the last frame's arrows as JSON")
    p.add_argument("ticks", type=int)
    p.add_argument("-o", "--output", required=True)
    p.set_defaults(f=cmd_overlay)
    p = sp.add_parser("cmd", help="run one editor command (in place)")
    p.add_argument("-o", "--output")
    p.add_argument("rest", nargs=argparse.REMAINDER, metavar="name args")
    p.set_defaults(f=cmd_cmd)
    p = sp.add_parser("script", help="run a file of commands")
    p.add_argument("file")
    p.add_argument("-o", "--output")
    p.set_defaults(f=cmd_script)

    a = ap.parse_args()
    return a.f(a)


if __name__ == "__main__":
    sys.exit(main())
