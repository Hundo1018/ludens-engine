"""Checkpoints and respawn (ROADMAP 17.72).

`GameFlow` is the whole flow state as one value: the state stack, the world
flags, the objective log, the inventories, the gameplay RNG and the tick.
A checkpoint is that value and the physics scene (the 6.10 snapshot,
`physics.serialize.scene_to_bytes`) as one byte blob:

    magic "LCKP" | format | flow section | scene section | FNV-1a 64 of all before

`take_checkpoint` / `restore_checkpoint` round-trip it bit for bit -- the
RNG continues the same stream, objectives keep their progress and
completion order. A blob that is truncated, has another magic or format,
or fails the checksum raises.

`respawn` restores a checkpoint under a policy: `KEEP_*` bits say which
parts of the current flow survive the death (flags, objectives,
inventories); everything else, the scene included, comes from the blob.
`KEEP_NONE` is a plain reload.

Flags are restored by name into a fresh `Flags`, so a blob written by a
build with another flag order loads; the `changed` list stays empty (a
restore is not a gameplay change).
"""

from physics.rigid6 import QuatBody6
from physics.solver6 import ContactScene6
from physics.serialize import scene_to_bytes, scene_from_bytes
from scheduler.rng import Pcg32
from .flow import FlowStack, FlowState, Flags
from .objectives import ObjectiveLog, Objective
from .inventory import Inventory

comptime _CKP_MAGIC = 0x504B434C  # "LCKP"
comptime CHECKPOINT_FORMAT = 1

comptime KEEP_NONE = 0
comptime KEEP_FLAGS = 1
comptime KEEP_OBJECTIVES = 2
comptime KEEP_INVENTORY = 4


struct GameFlow(Copyable, Movable):
    var stack: FlowStack
    var flags: Flags
    var objectives: ObjectiveLog
    var inventories: List[Inventory]
    var rng: Pcg32
    var tick: Int

    def __init__(out self, seed: UInt64):
        self.stack = FlowStack()
        self.flags = Flags()
        self.objectives = ObjectiveLog()
        self.inventories = List[Inventory]()
        self.rng = Pcg32.seeded(seed)
        self.tick = 0

    def __init__(out self, *, copy: Self):
        self.stack = copy.stack.copy()
        self.flags = copy.flags.copy()
        self.objectives = copy.objectives.copy()
        self.inventories = copy.inventories.copy()
        self.rng = Pcg32(copy.rng.state, copy.rng.inc)
        self.tick = copy.tick

    def to_bytes(self) -> List[UInt8]:
        var b = List[UInt8]()
        _put(b, self.tick)
        _put(b, Int(self.rng.state))
        _put(b, Int(self.rng.inc))
        _put(b, len(self.stack.stack))
        for st in self.stack.stack:
            _put(b, st.id)
            _put(b, st.ticks)
        _put_blob(b, self.flags.to_bytes())
        ref o = self.objectives
        _put(b, o.mode)
        _put(b, len(o.objs))
        for i in range(len(o.objs)):
            _put(b, o.objs[i].event_type)
            _put(b, o.objs[i].target)
            _put(b, o.objs[i].progress)
            _put(b, Int(o.objs[i].optional))
            _put(b, Int(o.objs[i].done))
            _put(b, len(o.prereq[i]))
            for p in o.prereq[i]:
                _put(b, p)
        _put(b, len(o.completed))
        for c in o.completed:
            _put(b, c)
        _put(b, len(self.inventories))
        for ref inv in self.inventories:
            _put(b, len(inv.item))
            for s in range(len(inv.item)):
                _put(b, inv.item[s])
                _put(b, inv.count[s])
            _put(b, len(inv.stack_limit))
            for l in inv.stack_limit:
                _put(b, l)
        return b^

    @staticmethod
    def from_bytes(b: List[UInt8]) raises -> GameFlow:
        var at = 0
        var g = GameFlow(0)
        g.tick = _get(b, at)
        g.rng.state = UInt64(_get(b, at))
        g.rng.inc = UInt64(_get(b, at))
        var ns = _count(b, at)
        for _ in range(ns):
            var id = _get(b, at)
            var t = _get(b, at)
            g.stack.push(id, t)
        g.flags.load(_get_blob(b, at))
        var o = ObjectiveLog(_get(b, at))
        var no = _count(b, at)
        for _ in range(no):
            var ev = _get(b, at)
            var target = _get(b, at)
            var progress = _get(b, at)
            var optional = _get(b, at) != 0
            var done = _get(b, at) != 0
            var np = _count(b, at)
            var pre = List[Int]()
            for _ in range(np):
                pre.append(_get(b, at))
            var i = o.add(ev, target, pre, optional)
            o.objs[i].progress = progress
            o.objs[i].done = done
        var nc = _count(b, at)
        for _ in range(nc):
            o.completed.append(_get(b, at))
        g.objectives = o^
        var ni = _count(b, at)
        for _ in range(ni):
            var slots = _count(b, at)
            var item = List[Int]()
            var count = List[Int]()
            for _ in range(slots):
                item.append(_get(b, at))
                count.append(_get(b, at))
            var nl = _count(b, at)
            var lim = List[Int]()
            for _ in range(nl):
                lim.append(_get(b, at))
            var inv = Inventory(slots, lim)
            inv.item = item^
            inv.count = count^
            g.inventories.append(inv^)
        if at != len(b):
            raise Error("checkpoint: trailing bytes in the flow section")
        return g^


def take_checkpoint(flow: GameFlow, scene: ContactScene6[QuatBody6]) -> List[UInt8]:
    var b = List[UInt8]()
    _put(b, _CKP_MAGIC)
    _put(b, CHECKPOINT_FORMAT)
    _put_blob(b, flow.to_bytes())
    _put_blob(b, scene_to_bytes(scene))
    _put(b, Int(_fnv(b, len(b))))
    return b^


struct Restored(Movable):
    var flow: GameFlow
    var scene: ContactScene6[QuatBody6]

    def __init__(out self, var flow: GameFlow, var scene: ContactScene6[QuatBody6]):
        self.flow = flow^
        self.scene = scene^


def restore_checkpoint(blob: List[UInt8]) raises -> Restored:
    if len(blob) < 24:
        raise Error("checkpoint: truncated")
    var end = len(blob) - 8
    var at_sum = end
    if UInt64(_get(blob, at_sum)) != _fnv(blob, end):
        raise Error("checkpoint: checksum mismatch")
    var at = 0
    if _get(blob, at) != _CKP_MAGIC:
        raise Error("checkpoint: not a checkpoint")
    var fmt = _get(blob, at)
    if fmt != CHECKPOINT_FORMAT:
        raise Error("checkpoint: format " + String(fmt) + ", this build reads " + String(CHECKPOINT_FORMAT))
    var flow = GameFlow.from_bytes(_get_blob(blob, at))
    var scene = scene_from_bytes(_get_blob(blob, at))
    if at != end:
        raise Error("checkpoint: trailing bytes")
    return Restored(flow^, scene^)


def respawn(blob: List[UInt8], current: GameFlow, keep: Int) raises -> Restored:
    """Restore `blob`, then put back the parts of `current` named in `keep`."""
    var r = restore_checkpoint(blob)
    if keep & KEEP_FLAGS != 0:
        r.flow.flags = current.flags.copy()
        r.flow.flags.changed = List[Int]()
    if keep & KEEP_OBJECTIVES != 0:
        r.flow.objectives = current.objectives.copy()
    if keep & KEEP_INVENTORY != 0:
        r.flow.inventories = current.inventories.copy()
    return r^


def _fnv(b: List[UInt8], n: Int) -> UInt64:
    var h = UInt64(0xCBF29CE484222325)
    for k in range(n):
        h = (h ^ UInt64(b[k])) * 0x100000001B3
    return h


def _put(mut b: List[UInt8], v: Int):
    var u = UInt64(v)
    for k in range(8):
        b.append(UInt8((u >> UInt64(8 * k)) & 0xFF))


def _get(b: List[UInt8], mut at: Int) raises -> Int:
    if at + 8 > len(b):
        raise Error("checkpoint: truncated")
    var u = UInt64(0)
    for k in range(8):
        u |= UInt64(b[at + k]) << UInt64(8 * k)
    at += 8
    return Int(u)


def _count(b: List[UInt8], mut at: Int) raises -> Int:
    """A length field: at most one entry per remaining 8 bytes."""
    var n = _get(b, at)
    if n < 0 or n > (len(b) - at) // 8 + 1:
        raise Error("checkpoint: corrupt count")
    return n


def _put_blob(mut b: List[UInt8], data: List[UInt8]):
    _put(b, len(data))
    for c in data:
        b.append(c)


def _get_blob(b: List[UInt8], mut at: Int) raises -> List[UInt8]:
    var n = _get(b, at)
    if n < 0 or at + n > len(b):
        raise Error("checkpoint: truncated section")
    var out = List[UInt8](capacity=n)
    for k in range(n):
        out.append(b[at + k])
    at += n
    return out^
