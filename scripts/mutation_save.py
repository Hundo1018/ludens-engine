#!/usr/bin/env python3
"""Mutation check for the save games (issue #122): apply one source change at a time and require that the named test fails.

    pixi run -e wasm mutation-save            # all mutations
    pixi run -e wasm mutation-save M3 M5      # chosen ones

Each mutation breaks one rule of platform/save_store.mojo or game/demo_mode.mojo. The test that covers the rule must exit
non-zero; a mutation that leaves the test green is reported and the script exits 1. The sources are restored afterwards,
also when the script is interrupted. Not part of CI: it builds the tests once per mutation (about 2 minutes)."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STORE = "platform/save_store.mojo"
DEMO = "game/demo_mode.mojo"

# id, file, text to replace, replacement, test, rule it breaks
MUTATIONS = [
    ("M1", STORE, "    if h != get_uint(data, CHECKED_HEADER, 8):", "    if False:", "platform_save", "the checksum is not compared"),
    ("M2", STORE, "        if files[best].version > current:", "        if False:", "platform_save", "a save from a newer build is not refused"),
    ("M3", STORE, "        self._slots[s].target = 1 - op.write_target", "        self._slots[s].target = op.write_target", "platform_save", "every write goes to the same file (no backup left)"),
    ("M4", STORE, "        data = m.migrate(v, data)\n", "        pass\n", "platform_save", "a migration step is skipped"),
    ("M5", STORE, "            if corrupt >= 0:\n                ev.status = SAVE_CORRUPT", "            if False:\n                ev.status = SAVE_CORRUPT", "platform_save", "two corrupt files are not reported"),
    ("M6", STORE, "        self._slots[s].repair_both = False\n        self._slots[s].generation = files[best].generation", "        self._slots[s].known = False\n        self._slots[s].generation = files[best].generation", "platform_save", "a loaded slot is not marked writable"),
    ("M9", STORE, '        return DecodedFile(FILE_CORRUPT, String("checksum mismatch"))', '        return DecodedFile(FILE_FORMAT_NEWER if Int(get_uint(data, 4, 2)) > SAVE_FORMAT else FILE_CORRUPT, String("checksum mismatch"))', "platform_save", "`format` is trusted before the checksum has passed"),
    ("M10", STORE, "                done.extend(self._fail_pending_loads())", "                pass", "platform_save", "a load over max_payload waits for ever"),
    ("M11", STORE, "        ev.needs_migration = files[best].version < current", "        ev.needs_migration = False", "platform_save", "the migration need is not reported"),
    ("M12", DEMO, "        scratch.load(blob)  # raises on a damaged blob, before the running game is touched\n        _ = self.reset(seed, name)", "        _ = self.reset(seed, name)", "game_save", "a damaged world blob is found only after the game was reset"),
    ("M7", DEMO, "        put_uint(out, UInt64(self.tick), 8)", "        put_uint(out, UInt64(0), 8)", "game_save", "the tick counter is not saved"),
    ("M8", DEMO, "        self.world.load(blob)\n", "", "game_save", "the world blob is not loaded"),
]


def run_test(name: str) -> str:
    """"killed" (a check printed [FAIL]), "survived" (exit 0), or "build error" (the mutation does not compile: invalid)."""
    proc = subprocess.run([sys.executable, "scripts/test_native.py", name], cwd=ROOT, capture_output=True, text=True, check=False)
    out = proc.stdout + proc.stderr
    if proc.returncode == 0:
        return "survived"
    return "killed" if "[FAIL]" in out else "build error"


def main(argv: list[str]) -> int:
    chosen = [m for m in MUTATIONS if not argv or m[0] in argv]
    originals: dict[str, str] = {}
    escaped = 0
    try:
        for mid, rel, old, new, test, rule in chosen:
            path = ROOT / rel
            originals.setdefault(rel, path.read_text())
            text = originals[rel]
            if text.count(old) != 1:
                print(f"{mid}: source text for the mutation not found exactly once in {rel}; update scripts/mutation_save.py")
                return 2
            path.write_text(text.replace(old, new))
            result = run_test(test)
            path.write_text(text)
            escaped += 0 if result == "killed" else 1
            print(f"{mid} [{test}] {rule}: {'a check FAILED as required' if result == 'killed' else result.upper()}", flush=True)
    finally:
        for rel, text in originals.items():
            (ROOT / rel).write_text(text)
    return 1 if escaped else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
