#!/usr/bin/env python3
"""`ludens check` and `ludens tune` on data tables (ludens-engine #119), end to end through real processes.

    pixi run -e wasm test-tables

Each case writes a project in a temporary directory, runs the command line and compares stdout, stderr and the exit
code. A failed check writes nothing; every error line is `<file>:<line>: <table>.<entry>.<field>: <what>`."""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import build_core  # noqa: E402

LUDENS = [sys.executable, str(ROOT / "scripts/ludens.py")]
FIXTURES = ROOT / "tests/data"
passed = 0
failed = 0


def check(cond: bool, label: str, detail: str = "") -> None:
    global passed, failed
    if cond:
        passed += 1
        print(f"  [PASS] {label}")
    else:
        failed += 1
        print(f"  [FAIL] {label}")
        if detail:
            print("        " + detail.replace("\n", "\n        "))


def main() -> int:
    env = {**os.environ, "LUDENS_CORE": str(build_core.core())}

    def ludens(*args, cwd):
        return subprocess.run([*LUDENS, *args], cwd=cwd, capture_output=True, text=True, env=env, check=False)

    with tempfile.TemporaryDirectory() as tmp:
        proj = Path(tmp) / "game"
        r = ludens("new", str(proj), cwd=tmp)
        check(r.returncode == 0, "ludens new")
        data = proj / "data"
        data.mkdir()
        for name in ("ammo.schema", "ammo.table", "weapons.schema", "weapons.table"):
            shutil.copy(FIXTURES / name, data / name)

        r = ludens("check", cwd=proj)
        check(r.returncode == 0 and "tables ok: 2 tables, 4 entries" in r.stdout, "check passes on valid tables", r.stdout + r.stderr)

        # a wrong kind, an out-of-range value, a missing required field and a dangling reference, each named
        weapons = data / "weapons.table"
        good = weapons.read_text(encoding="utf-8")
        weapons.write_text(
            good.replace("weapons.sword.damage = 12", "weapons.sword.damage = many")
            + "weapons.axe.damage = 250\nweapons.club = +\nweapons.crossbow.damage = 5\nweapons.crossbow.ammo = quivers\n",
            encoding="utf-8",
        )
        r = ludens("check", cwd=proj)
        err = r.stderr
        check(r.returncode == 1, "check exits 1 on invalid tables", err)
        for want, label in [
            (f"{weapons}:6: weapons.sword.damage: `many` is not a whole number", "wrong kind"),
            (f"{weapons}:16: weapons.axe.damage: 250 is above the maximum 100", "out of range"),
            (f"{weapons}:17: weapons.club.damage: required field has no row", "missing required field"),
            (f"{weapons}:19: weapons.crossbow.ammo: `quivers` is not an entry of table `ammo`", "dangling reference"),
        ]:
            check(want in err, f"check names file, line and column: {label}", err)
        check(weapons.read_text(encoding="utf-8").startswith("ludens-table 1 schema 2"), "check writes nothing")
        weapons.write_text(good, encoding="utf-8")

        # a table with no schema beside it
        (data / "orphan.table").write_text("ludens-table 1 schema 1\n", encoding="utf-8")
        r = ludens("check", cwd=proj)
        check(r.returncode == 1 and "orphan.table: no schema orphan.schema beside it" in r.stderr, "a table without a schema fails", r.stderr)
        (data / "orphan.table").unlink()

        # tune: one row changes, the rest of the file is byte for byte
        r = ludens("tune", "data/weapons.table", "sword.damage", "14", "bow.reach", "8.5", cwd=proj)
        after = weapons.read_text(encoding="utf-8")
        want = good.replace("weapons.sword.damage = 12", "weapons.sword.damage = 14").replace("weapons.bow.reach = 9", "weapons.bow.reach = 8.5")
        check(r.returncode == 0 and after == want, "tune rewrites the two rows and nothing else", r.stdout + r.stderr)
        before = after
        r = ludens("tune", "data/weapons.table", "sword.damage", "500", cwd=proj)
        check(r.returncode == 1 and "weapons.sword.damage: 500 is above the maximum 100" in r.stderr and weapons.read_text(encoding="utf-8") == before, "tune refuses an out-of-range value and leaves the file as it was", r.stderr)
        r = ludens("tune", "data/weapons.table", "sword.speed", "3", cwd=proj)
        check(r.returncode == 1 and "has no field `speed`" in r.stderr and weapons.read_text(encoding="utf-8") == before, "tune refuses an unknown field", r.stderr)
        r = ludens("check", cwd=proj)
        check(r.returncode == 0, "the tuned tables still pass check", r.stderr)

    print(f"tables cli: {passed} / {passed + failed} checks")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
