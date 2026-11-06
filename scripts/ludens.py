#!/usr/bin/env python3
"""ludens: the command line of the editor core (ludens-shell #11).

    ludens new <dir>                    create a project: ludens.toml + a demo scene
    ludens hash | list | check          the world hash, the bodies (index, handle, position), validate the scene
    ludens run <ticks> [-o OUT]         step the scene and print the world hash
    ludens cmd [-o OUT] <name> <args>   run one editor command on the scene, in place
    ludens script <file> [-o OUT]       run a file of commands (one per line, `#` comments, `undo`, `redo`)

Everything runs in `ludens-core`, the native build of the editor's Mojo command layer, so what the GUI does is what
these do. Nothing is written when a command fails. Subcommands for assets, builds and replay follow with their
issues (#12, #15, #13).

The project is the nearest directory upward with a ludens.toml (`scene = "world.scene"` names the scene file);
`--project DIR` names it. `LUDENS_CORE` points at a core binary instead of building one."""
import argparse
import os
import subprocess
import sys
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
