"""Cheat commands and the cheated mark (docs/console.md, issue #146).

`cheat_commands()` are the console specs every game can offer (`GameMode.console_commands`): `god`, `noclip`,
`spawn [kind]` and `teleport x y z`, each with `cheat=True`. What they do is the game's (`GameMode.run_command`); the demo
game's meaning is in game/demo_mode.mojo.

`CheatMark` is the state a game keeps: which toggles are on and whether any cheat ran. `marked` never goes back to
False in a run; a game writes `bits()` into its save, so a save made after a cheat says so, and a game loaded from it is
marked again. The host reads `GameMode.cheated()` each frame and marks its achievements guard
(platform/achievements.mojo `CheatGuard`), which then refuses unlocks and stats."""
from game.console import CommandSpec

comptime CHEAT_MARKED: UInt8 = 1
comptime CHEAT_GOD: UInt8 = 2
comptime CHEAT_NOCLIP: UInt8 = 4


def cheat_commands() -> List[CommandSpec]:
    var out = List[CommandSpec]()
    out.append(CommandSpec("god", "", 0, 0, cheat=True))
    out.append(CommandSpec("noclip", "", 0, 0, cheat=True))
    out.append(CommandSpec("spawn", "[crate]", 0, 1, cheat=True))
    out.append(CommandSpec("teleport", "x y z", 3, 3, cheat=True))
    return out^


@fieldwise_init
struct CheatMark(Copyable, ImplicitlyCopyable, Movable):
    var marked: Bool
    var god: Bool
    var noclip: Bool

    def __init__(out self):
        self.marked = False
        self.god = False
        self.noclip = False

    def mark(mut self):
        self.marked = True

    def bits(self) -> UInt8:
        var b = UInt8(0)
        if self.marked:
            b |= CHEAT_MARKED
        if self.god:
            b |= CHEAT_GOD
        if self.noclip:
            b |= CHEAT_NOCLIP
        return b

    @staticmethod
    def from_bits(b: UInt8) raises -> CheatMark:
        if b & ~(CHEAT_MARKED | CHEAT_GOD | CHEAT_NOCLIP):
            raise Error("cheat mark: unknown bits " + String(Int(b)))
        if (b & (CHEAT_GOD | CHEAT_NOCLIP)) and not (b & CHEAT_MARKED):
            raise Error("cheat mark: a cheat is on but the run is not marked")
        return CheatMark((b & CHEAT_MARKED) != 0, (b & CHEAT_GOD) != 0, (b & CHEAT_NOCLIP) != 0)
