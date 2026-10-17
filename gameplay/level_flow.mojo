"""Level transitions (ROADMAP 17.72): the engine asks, the host loads.

`LevelDirector.request(level, spawn)` checks the level id against the
registered ones (an unknown id raises) and queues a `LoadLevel` command;
the host drains `take_commands`, loads assets, rebuilds the scene through
the embedding boundary (12.1) and reports `loaded(level)`. Between the
request and the report the director is `LEVEL_LOADING`:

  * gameplay events posted with `post` are held, not dropped, and reach
    the objective log in posting order when the load completes;
  * `can_save` is False (a checkpoint taken mid-load would pair the new
    flow state with a half-built scene); `checked_checkpoint` raises;
  * a second request raises, and `loaded` with another level id raises.

What crosses levels is whatever lives outside the scene: the `GameFlow`
(flags, objectives, inventories) is untouched by a transition.

World partition cell events (17.8, `large_world.CellEvent`) go through the
same door: `post_cells` turns loads / unloads into gameplay events of two
caller-chosen types.
"""

from geometry.vec import Vec3
from physics.rigid6 import QuatBody6
from physics.solver6 import ContactScene6
from .objectives import ObjectiveLog
from .large_world import CellEvent, EV_LOAD
from .checkpoint import GameFlow, take_checkpoint

comptime LEVEL_IDLE = 0
comptime LEVEL_LOADING = 1


@fieldwise_init
struct LoadLevel(Copyable, ImplicitlyCopyable, Movable):
    var level: Int
    var spawn: Vec3
    var tick: Int


struct LevelDirector(Movable):
    var known: List[Int]
    var current: Int  # -1 before the first load
    var state: Int
    var pending: Int
    var spawn: Vec3
    var commands: List[LoadLevel]
    var held: List[Tuple[Int, Int]]  # (event type, amount) posted while loading

    def __init__(out self, known: List[Int]):
        self.known = known.copy()
        self.current = -1
        self.state = LEVEL_IDLE
        self.pending = -1
        self.spawn = Vec3(0, 0, 0, 0)
        self.commands = List[LoadLevel]()
        self.held = List[Tuple[Int, Int]]()

    def request(mut self, level: Int, spawn: Vec3, tick: Int) raises:
        if self.state == LEVEL_LOADING:
            raise Error("LevelDirector.request: level " + String(self.pending) + " is still loading")
        if level not in self.known:
            raise Error("LevelDirector.request: unknown level id " + String(level))
        self.state = LEVEL_LOADING
        self.pending = level
        self.spawn = spawn
        self.commands.append(LoadLevel(level, spawn, tick))

    def take_commands(mut self) -> List[LoadLevel]:
        var out = self.commands^
        self.commands = List[LoadLevel]()
        return out^

    def loaded(mut self, level: Int, mut log: ObjectiveLog) raises:
        """The host finished loading `level`: release the held events."""
        if self.state != LEVEL_LOADING or level != self.pending:
            raise Error("LevelDirector.loaded: level " + String(level) + " was not requested")
        self.state = LEVEL_IDLE
        self.current = level
        self.pending = -1
        for e in self.held:
            log.on_event(e[0], e[1])
        self.held = List[Tuple[Int, Int]]()

    def post(mut self, mut log: ObjectiveLog, event_type: Int, amount: Int = 1):
        if self.state == LEVEL_LOADING:
            self.held.append((event_type, amount))
        else:
            log.on_event(event_type, amount)

    def post_cells(mut self, mut log: ObjectiveLog, events: List[CellEvent], load_type: Int, unload_type: Int):
        for e in events:
            self.post(log, load_type if e.kind == EV_LOAD else unload_type)

    def can_save(self) -> Bool:
        return self.state == LEVEL_IDLE


def checked_checkpoint(d: LevelDirector, flow: GameFlow, scene: ContactScene6[QuatBody6]) raises -> List[UInt8]:
    if not d.can_save():
        raise Error("checkpoint: refused while level " + String(d.pending) + " is loading")
    return take_checkpoint(flow, scene)
