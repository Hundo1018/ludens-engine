# tier: unit
"""The console in a release build (`-D LUDENS_RELEASE`, issue #146): built by scripts/test_console.py with the define, it
checks that the console does nothing; the script then looks for the console's strings in this binary and in the debug
build of tests/console.mojo."""
from game.console import CONSOLE_BUILT, CommandSpec, Console


def main() raises:
    var con = Console()
    con.register(CommandSpec("god", "", 0, 0, cheat=True))
    con.toggle()
    var answer = con.submit("god", 0)
    var nothing = con.submit("no_such_command", 0)  # a debug build raises here
    con.load_replay("1 god\n")
    con.due(5)
    var taken = con.take()
    var ok = not CONSOLE_BUILT and not con.open and answer == "" and nothing == "" and len(taken) == 0 and con.log_text() == "" and len(con.specs) == 0
    print("console_release: CONSOLE_BUILT", CONSOLE_BUILT, "open", con.open, "queued", len(taken), "specs", len(con.specs))
    if not ok:
        raise Error("console_release: the console is active in a release build")
    print("console_release: 1 passed, 0 failed")
