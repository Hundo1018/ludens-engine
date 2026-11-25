"""The in-game console (docs/console.md, issue #146): registered commands and cvars, a line editor, and a log that a
replay plays back.

What a game registers (`GameMode.console_commands`, game/mode.mojo) is a list of `CommandSpec`: a command with a usage
line and a number of arguments, or a cvar with a type, a default and bounds. A cheat is a command with `cheat=True`.
`submit(line, frame)` checks a line against them and queues it; it never touches the game. The host takes the queue at
the start of the next frame (`take`) and hands each line to `GameMode.run_command` before `step`, so a command lands
between two frames, at the same place in a replay as in the run that typed it.

Every queued line is also appended to the log with its frame number. `log_text()` writes the log as one `frame line`
pair per line; `load_replay(text)` reads that back, and `due(frame)` then returns the lines of a frame in their order.
A run that plays the same inputs and calls `due` before each frame reaches the same state as the run that typed them
(tests/console.mojo checks the hash).

Builds: the console exists unless the program is built with `-D LUDENS_RELEASE`. In a release build every method body
below is removed by `comptime if CONSOLE_BUILT` (the strings and the parser are not in the binary; scripts/test_console.py
looks for them): `submit` answers "" without queueing, `toggle` keeps it closed, `take` and `due` return nothing."""
from std.sys import is_defined

comptime CONSOLE_BUILT: Bool = not is_defined["LUDENS_RELEASE"]()
"""True unless built with `-D LUDENS_RELEASE`."""

comptime SPEC_COMMAND = 0
comptime SPEC_CVAR_INT = 1
comptime SPEC_CVAR_FLOAT = 2
comptime CONSOLE_LINES = 12  # output lines kept for drawing
comptime CONSOLE_MAX_LINE = 120  # bytes the line editor accepts
comptime CONSOLE_LOG_LIMIT = 4096  # log entries kept; beyond this a line is refused (a replay must not lose one)


struct CommandSpec(Copyable, Movable):
    var name: String
    var kind: Int  # SPEC_COMMAND, SPEC_CVAR_INT or SPEC_CVAR_FLOAT
    var usage: String  # the arguments, e.g. "x y z", shown by `help`
    var min_args: Int
    var max_args: Int
    var cheat: Bool  # running it marks the save and the achievements as cheated (game/cheats.mojo)
    var value: Float64  # a cvar's current value (applied: after `take`)
    var lo: Float64
    var hi: Float64

    def __init__(out self, name: String, usage: String, min_args: Int, max_args: Int, cheat: Bool = False):
        self.name = name
        self.kind = SPEC_COMMAND
        self.usage = usage
        self.min_args = min_args
        self.max_args = max_args
        self.cheat = cheat
        self.value = 0
        self.lo = 0
        self.hi = 0

    @staticmethod
    def cvar(name: String, is_int: Bool, default: Float64, lo: Float64, hi: Float64, cheat: Bool = False) -> CommandSpec:
        var s = CommandSpec(name, "[value]", 0, 1, cheat)
        s.kind = SPEC_CVAR_INT if is_int else SPEC_CVAR_FLOAT
        s.value = default
        s.lo = lo
        s.hi = hi
        return s^


struct ConsoleLine(Copyable, Movable):
    """One accepted line: the command (or cvar) name and its arguments, split on spaces."""
    var name: String
    var args: List[String]
    var frame: Int
    var cheat: Bool

    def __init__(out self, name: String, var args: List[String], frame: Int, cheat: Bool):
        self.name = name
        self.args = args^
        self.frame = frame
        self.cheat = cheat

    def text(self) -> String:
        var out = self.name
        for a in self.args:
            out += " " + a
        return out^

    def number(self, i: Int) raises -> Float64:
        """Argument i as a finite number; raises with the command's name otherwise."""
        if i >= len(self.args):
            raise Error(self.name + ": argument " + String(i + 1) + " is missing")
        var v: Float64
        try:
            v = Float64(self.args[i])
        except:
            raise Error(self.name + ": `" + self.args[i] + "` is not a number")
        if v != v or v > 1.0e300 or v < -1.0e300:
            raise Error(self.name + ": `" + self.args[i] + "` is not finite")
        return v


def split_words(line: String) -> List[String]:
    var out = List[String]()
    var cur = String()
    for ch in line.codepoints():
        var c = ch.to_u32()
        if c == 32 or c == 9:
            if cur.byte_length() > 0:
                out.append(cur)
                cur = String()
        else:
            cur += String(ch)
    if cur.byte_length() > 0:
        out.append(cur)
    return out^


struct Console(Movable):
    var specs: List[CommandSpec]
    var open: Bool
    var edit: String  # the line being typed
    var lines: List[String]  # what the console printed, newest last (at most CONSOLE_LINES)
    var queue: List[ConsoleLine]
    var log_frames: List[Int]
    var log_lines: List[String]
    var replay_frames: List[Int]
    var replay_lines: List[String]
    var replay_at: Int
    var cheats_run: Int  # cheat lines taken so far (this run, replayed ones included)

    def __init__(out self):
        self.specs = List[CommandSpec]()
        self.open = False
        self.edit = String()
        self.lines = List[String]()
        self.queue = List[ConsoleLine]()
        self.log_frames = List[Int]()
        self.log_lines = List[String]()
        self.replay_frames = List[Int]()
        self.replay_lines = List[String]()
        self.replay_at = 0
        self.cheats_run = 0
        comptime if CONSOLE_BUILT:
            self.specs.append(CommandSpec("help", "", 0, 0))

    def register(mut self, var spec: CommandSpec) raises:
        comptime if CONSOLE_BUILT:
            if spec.name.byte_length() == 0 or len(split_words(spec.name)) != 1:
                raise Error("console: a name is one word, not `" + spec.name + "`")
            if self.find(spec.name) >= 0:
                raise Error("console: `" + spec.name + "` is registered twice")
            if spec.kind != SPEC_COMMAND and not (spec.lo <= spec.value and spec.value <= spec.hi):
                raise Error("console: the default of `" + spec.name + "` is outside its bounds")
            self.specs.append(spec^)

    def find(self, name: String) -> Int:
        for i in range(len(self.specs)):
            if self.specs[i].name == name:
                return i
        return -1

    def value(self, name: String) -> Float64:
        """A cvar's applied value; 0 for an unknown name (or in a release build)."""
        var i = self.find(name)
        return self.specs[i].value if i >= 0 else 0.0

    def print_line(mut self, text: String):
        self.lines.append(text)
        if len(self.lines) > CONSOLE_LINES:
            var keep = List[String]()
            for k in range(len(self.lines) - CONSOLE_LINES, len(self.lines)):
                keep.append(self.lines[k])
            self.lines = keep^

    def submit(mut self, line: String, frame: Int) raises -> String:
        """Check `line` and queue it for the next frame; returns what the console prints for it at once (a cvar's
        value, the help text) or "". Raises with the reason for an unknown name, a wrong number of arguments or a
        value that is not of the cvar's type or out of its bounds; nothing is queued or logged then."""
        comptime if CONSOLE_BUILT:
            var words = split_words(line)
            if len(words) == 0:
                return String()
            var name = words[0]
            var args = List[String]()
            for k in range(1, len(words)):
                args.append(words[k])
            var i = self.find(name)
            if i < 0:
                raise Error("console: unknown command `" + name + "` (help lists them)")
            if name == "help":
                var out = String()
                for s in self.specs:
                    out += (" " if out.byte_length() > 0 else "") + s.name + ("*" if s.cheat else "")
                return out^
            ref spec = self.specs[i]
            if len(args) < spec.min_args or len(args) > spec.max_args:
                raise Error(name + ": usage `" + name + (" " + spec.usage if spec.usage.byte_length() > 0 else String("")) + "`")
            if spec.kind != SPEC_COMMAND:
                if len(args) == 0:
                    return name + " = " + String(spec.value)
                var v = ConsoleLine(name, args.copy(), frame, False).number(0)
                if spec.kind == SPEC_CVAR_INT and Float64(Int(v)) != v:
                    raise Error(name + ": `" + args[0] + "` is not a whole number")
                if v < spec.lo or v > spec.hi:
                    raise Error(name + ": " + args[0] + " is outside " + String(spec.lo) + " .. " + String(spec.hi))
            if len(self.log_lines) >= CONSOLE_LOG_LIMIT:
                raise Error("console: the log is full (" + String(CONSOLE_LOG_LIMIT) + " lines)")
            var cl = ConsoleLine(name, args^, frame, spec.cheat)
            self.log_frames.append(frame)
            self.log_lines.append(cl.text())
            self.queue.append(cl^)
            return String()
        else:
            return String()

    def take(mut self) -> List[ConsoleLine]:
        """The queued lines, oldest first, for the host to run before the next step; a cvar's value is applied here."""
        var out = List[ConsoleLine]()
        comptime if CONSOLE_BUILT:
            out = self.queue^
            self.queue = List[ConsoleLine]()
            for l in out:
                if l.cheat:
                    self.cheats_run += 1
                var i = self.find(l.name)
                if i >= 0 and self.specs[i].kind != SPEC_COMMAND and len(l.args) == 1:
                    try:
                        self.specs[i].value = l.number(0)
                    except:
                        pass  # checked in submit
        return out^

    def log_text(self) -> String:
        var out = String()
        for k in range(len(self.log_lines)):
            out += String(self.log_frames[k]) + " " + self.log_lines[k] + "\n"
        return out^

    def load_replay(mut self, text: String) raises:
        """Read a `log_text()`: lines `frame command args...`, frames not decreasing. Raises on a malformed line; the
        replay already loaded is kept then."""
        comptime if CONSOLE_BUILT:
            var frames = List[Int]()
            var lines = List[String]()
            var n = 0
            for raw in text.split("\n"):
                n += 1
                var words = split_words(String(raw))
                if len(words) == 0:
                    continue
                if len(words) < 2:
                    raise Error("console replay line " + String(n) + ": `frame command` expected")
                var f: Int
                try:
                    f = Int(words[0])
                except:
                    raise Error("console replay line " + String(n) + ": `" + words[0] + "` is not a frame number")
                if f < 0 or (len(frames) > 0 and f < frames[len(frames) - 1]):
                    raise Error("console replay line " + String(n) + ": frames must not go back")
                var rest = words[1]
                for k in range(2, len(words)):
                    rest += " " + words[k]
                frames.append(f)
                lines.append(rest^)
            self.replay_frames = frames^
            self.replay_lines = lines^
            self.replay_at = 0

    def due(mut self, frame: Int) raises:
        """Submit the replay's lines of `frame` (each is checked and logged as if typed). Call before `take`."""
        comptime if CONSOLE_BUILT:
            while self.replay_at < len(self.replay_frames) and self.replay_frames[self.replay_at] <= frame:
                var line = self.replay_lines[self.replay_at]
                var at = self.replay_frames[self.replay_at]
                _ = self.submit(line, at)
                self.replay_at += 1

    def toggle(mut self):
        comptime if CONSOLE_BUILT:
            self.open = not self.open

    def type_text(mut self, text: String):
        """Characters typed while the console is open (the host maps key presses to text)."""
        comptime if CONSOLE_BUILT:
            if self.open and self.edit.byte_length() + text.byte_length() <= CONSOLE_MAX_LINE:
                self.edit += text

    def backspace(mut self):
        comptime if CONSOLE_BUILT:
            var b = self.edit.as_bytes()
            if len(b) > 0:
                var keep = String()
                var cps = List[String]()
                for ch in self.edit.codepoints():
                    cps.append(String(ch))
                for k in range(len(cps) - 1):
                    keep += cps[k]
                self.edit = keep^

    def enter(mut self, frame: Int):
        """Submit the edited line; the console prints the line, then the answer or the error."""
        comptime if CONSOLE_BUILT:
            var line = self.edit
            self.edit = String()
            if line.byte_length() == 0:
                return
            self.print_line("> " + line)
            try:
                var answer = self.submit(line, frame)
                if answer.byte_length() > 0:
                    self.print_line(answer)
            except e:
                self.print_line(String(e))
