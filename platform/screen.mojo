"""The Screen seam: fullscreen, orientation lock, wake lock (docs/platform.md, "Device seams").

`request(id, op, arg)` queues one operation and returns REQ_QUEUED; its result is a KIND_DEV_SCREEN packet, STATUS_OK or
STATUS_ERROR, with payload [op u8][state flags u8]. `state()` is the flags now:
SCREEN_F_FULLSCREEN, SCREEN_F_WAKE (screen kept on), SCREEN_F_ORIENT (orientation locked).

    SCREEN_FULLSCREEN_ENTER / _EXIT        Fullscreen API. The browser accepts it only inside a user gesture.
    SCREEN_ORIENT_LOCK, arg ORIENT_*       Screen Orientation API. Browsers accept it only while fullscreen.
    SCREEN_ORIENT_UNLOCK
    SCREEN_WAKE_ON / _OFF                  Wake Lock API. The browser drops the lock when the page is hidden.

Leaving fullscreen releases an orientation lock. An op the platform does not offer (its SCREEN_CAP_* bit is missing from
`capabilities()`) returns DEV_UNSUPPORTED at once and queues nothing; an op or arg out of range returns DEV_INVALID.

MemoryScreen follows those rules, with `grant_activation()` standing in for a tap. Standard library only."""
from platform.device import (
    AVAIL_GRANTED,
    AVAIL_UNSUPPORTED,
    DEV_INVALID,
    DEV_UNSUPPORTED,
    KIND_DEV_SCREEN,
)
from platform.packets import PacketQueue, REQ_QUEUED, STATUS_ERROR, STATUS_OK, packet

comptime SCREEN_FULLSCREEN_ENTER = 1
comptime SCREEN_FULLSCREEN_EXIT = 2
comptime SCREEN_ORIENT_LOCK = 3
comptime SCREEN_ORIENT_UNLOCK = 4
comptime SCREEN_WAKE_ON = 5
comptime SCREEN_WAKE_OFF = 6

comptime ORIENT_PORTRAIT = 1
comptime ORIENT_LANDSCAPE = 2
comptime ORIENT_ANY = 3

comptime SCREEN_F_FULLSCREEN = 1
comptime SCREEN_F_WAKE = 2
comptime SCREEN_F_ORIENT = 4

comptime SCREEN_CAP_FULLSCREEN = 1
comptime SCREEN_CAP_WAKE = 2
comptime SCREEN_CAP_ORIENT = 4


def op_cap(op: Int) -> Int:
    """The capability bit an op needs, or 0 for an op that does not exist."""
    if op == SCREEN_FULLSCREEN_ENTER or op == SCREEN_FULLSCREEN_EXIT:
        return SCREEN_CAP_FULLSCREEN
    if op == SCREEN_ORIENT_LOCK or op == SCREEN_ORIENT_UNLOCK:
        return SCREEN_CAP_ORIENT
    if op == SCREEN_WAKE_ON or op == SCREEN_WAKE_OFF:
        return SCREEN_CAP_WAKE
    return 0


trait Screen(Movable):
    def availability(self) -> Int:
        ...

    def capabilities(self) -> Int:
        ...

    def request(mut self, id: Int, op: Int, arg: Int) -> Int:
        ...

    def state(self) -> Int:
        ...

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        ...

    def dropped(self) -> Int:
        ...


struct MemoryScreen(Screen):
    var caps: Int
    var orientation: Int
    """The ORIENT_* of the current lock, 0 when unlocked."""
    var _flags: Int
    var _activation: Bool
    var _q: PacketQueue

    def __init__(out self, caps: Int = SCREEN_CAP_FULLSCREEN | SCREEN_CAP_WAKE | SCREEN_CAP_ORIENT):
        self.caps = caps
        self.orientation = 0
        self._flags = 0
        self._activation = False
        self._q = PacketQueue()

    def grant_activation(mut self):
        """A tap: the next fullscreen entry is allowed (one use, like a browser's transient activation)."""
        self._activation = True

    def availability(self) -> Int:
        return AVAIL_GRANTED if self.caps != 0 else AVAIL_UNSUPPORTED

    def capabilities(self) -> Int:
        return self.caps

    def state(self) -> Int:
        return self._flags

    def request(mut self, id: Int, op: Int, arg: Int) -> Int:
        var need = op_cap(op)
        if need == 0 or (op == SCREEN_ORIENT_LOCK and (arg < ORIENT_PORTRAIT or arg > ORIENT_ANY)):
            return DEV_INVALID
        if self.caps & need == 0:
            return DEV_UNSUPPORTED
        var ok = True
        if op == SCREEN_FULLSCREEN_ENTER:
            ok = self._activation
            self._activation = False
            if ok:
                self._flags |= SCREEN_F_FULLSCREEN
        elif op == SCREEN_FULLSCREEN_EXIT:
            self._flags &= ~(SCREEN_F_FULLSCREEN | SCREEN_F_ORIENT)
            self.orientation = 0
        elif op == SCREEN_ORIENT_LOCK:
            ok = (self._flags & SCREEN_F_FULLSCREEN) != 0
            if ok:
                self._flags |= SCREEN_F_ORIENT
                self.orientation = arg
        elif op == SCREEN_ORIENT_UNLOCK:
            self._flags &= ~SCREEN_F_ORIENT
            self.orientation = 0
        elif op == SCREEN_WAKE_ON:
            self._flags |= SCREEN_F_WAKE
        else:
            self._flags &= ~SCREEN_F_WAKE
        var payload = List[UInt8]()
        payload.append(UInt8(op))
        payload.append(UInt8(self._flags))
        _ = self._q.push(packet(KIND_DEV_SCREEN, id, STATUS_OK if ok else STATUS_ERROR, payload^))
        return REQ_QUEUED

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        return self._q.poll(buf, cap)

    def dropped(self) -> Int:
        return self._q.dropped()
