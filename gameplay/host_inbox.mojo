"""Inbound host data as recorded input (ROADMAP 17.73).

Remote config, entitlements and feature flags come from the host at any
time; the simulation must only see them at a tick boundary, and a replay
must see them at the same boundary, or it diverges. `ConfigInbox`:

  * `post(key, value)`: the host, whenever data arrives (between frames, or
    while a `begin_advance` step is in flight); it only queues;
  * `take(tick)`: the runtime, at the start of a frame: stamps everything
    queued with `tick` (the first tick of the frame), appends it to `log`
    and returns it -- data that arrived during a frame lands on the next;
  * `log` is part of the recording, like `InputFrame`s; a replay builds the
    inbox with `scripted(log)`, whose `take(tick)` returns the logged
    entries of that tick and ignores `post`.

Keys and values are integers (no strings: same rule as the outbox).
"""


@fieldwise_init
struct ConfigEntry(Copyable, ImplicitlyCopyable, Movable):
    var tick: Int
    var key: Int
    var value: Int


struct ConfigInbox(Copyable, Movable):
    var pending: List[Tuple[Int, Int]]
    var log: List[ConfigEntry]
    var script: List[ConfigEntry]
    var at: Int  # next script entry
    var replaying: Bool

    def __init__(out self):
        self.pending = List[Tuple[Int, Int]]()
        self.log = List[ConfigEntry]()
        self.script = List[ConfigEntry]()
        self.at = 0
        self.replaying = False

    @staticmethod
    def scripted(log: List[ConfigEntry]) -> ConfigInbox:
        var b = ConfigInbox()
        b.script = log.copy()
        b.replaying = True
        return b^

    def post(mut self, key: Int, value: Int):
        if not self.replaying:
            self.pending.append((key, value))

    def take(mut self, tick: Int) -> List[ConfigEntry]:
        var out = List[ConfigEntry]()
        if self.replaying:
            while self.at < len(self.script) and self.script[self.at].tick <= tick:
                out.append(self.script[self.at])
                self.at += 1
        else:
            for p in self.pending:
                out.append(ConfigEntry(tick, p[0], p[1]))
            self.pending = List[Tuple[Int, Int]]()
        for e in out:
            self.log.append(e)
        return out^
