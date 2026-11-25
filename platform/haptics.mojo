"""The Haptics seam (docs/platform.md, "Device seams"): vibrate a phone, rumble a gamepad.

- `vibrate(ms)` and `vibrate_pattern(ptr, count)`: an on / off pattern, no strength. `count` u16 LE millisecond values at
  `ptr`, starting with "on". Web: `navigator.vibrate`. iOS Safari has none, so `capabilities()` lacks HAP_VIBRATE there.
- `rumble(pad, strong, weak, ms)`: two motors with a strength each, 0 to 255. Web: `Gamepad.vibrationActuator`.
- `cancel()` stops both.

Limits, the same on every backend: a duration is 1 to MAX_VIBRATE_MS, a pattern has 1 to MAX_PATTERN entries each 0 to
MAX_VIBRATE_MS, a pad is 0 to 3, a strength 0 to 255. Checked in this order: HAP_* capability missing -> DEV_UNSUPPORTED,
then bad arguments -> DEV_INVALID, otherwise DEV_OK. Nothing is queued, so there is no result packet (`poll` carries the
permission result only). A haptic call needs no permission on the web; the platform may still ignore it before the page has
had a tap (Chrome), which no backend can report.

MemoryHaptics records the calls, for tests. Standard library only."""
from platform.device import (
    AVAIL_GRANTED,
    AVAIL_UNSUPPORTED,
    DEV_HAPTICS,
    DEV_INVALID,
    DEV_NOT_GRANTED,
    DEV_OK,
    DEV_UNSUPPORTED,
    PermissionGate,
)
from platform.packets import PacketQueue

comptime HAP_VIBRATE = 1
comptime HAP_RUMBLE = 2
comptime MAX_VIBRATE_MS = 5000
comptime MAX_PATTERN = 32
comptime MAX_PADS = 4


trait Haptics(Movable):
    def availability(self) -> Int:
        ...

    def capabilities(self) -> Int:
        ...

    def request_permission(mut self, id: Int) -> Int:
        ...

    def vibrate(mut self, ms: Int) -> Int:
        ...

    def vibrate_pattern(mut self, ptr: UInt64, count: Int) -> Int:
        ...

    def rumble(mut self, pad: Int, strong: Int, weak: Int, ms: Int) -> Int:
        ...

    def cancel(mut self) -> Int:
        ...

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        ...

    def dropped(self) -> Int:
        ...


def pattern_ok(ptr: UInt64, count: Int) -> Bool:
    if count < 1 or count > MAX_PATTERN:
        return False
    var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(ptr))
    for i in range(count):
        if (Int(p[2 * i]) | (Int(p[2 * i + 1]) << 8)) > MAX_VIBRATE_MS:
            return False
    return True


struct MemoryHaptics(Haptics):
    var gate: PermissionGate
    var caps: Int
    var pattern: List[Int]
    """The last vibration, as the on / off milliseconds the platform would have been given."""
    var vibrations: Int
    var rumbles: Int
    var last_rumble: List[Int]
    """[pad, strong, weak, ms] of the last rumble."""
    var cancels: Int
    var _q: PacketQueue

    def __init__(out self, caps: Int = HAP_VIBRATE | HAP_RUMBLE, state: Int = AVAIL_GRANTED):
        self.gate = PermissionGate(DEV_HAPTICS, state if caps != 0 else AVAIL_UNSUPPORTED)
        self.caps = caps
        self.pattern = List[Int]()
        self.vibrations = 0
        self.rumbles = 0
        self.last_rumble = List[Int]()
        self.cancels = 0
        self._q = PacketQueue()

    def availability(self) -> Int:
        return self.gate.state

    def capabilities(self) -> Int:
        return self.caps

    def request_permission(mut self, id: Int) -> Int:
        return self.gate.request(id, self._q)

    def vibrate(mut self, ms: Int) -> Int:
        if self.caps & HAP_VIBRATE == 0:
            return DEV_UNSUPPORTED
        if ms < 1 or ms > MAX_VIBRATE_MS:
            return DEV_INVALID
        self.pattern = List[Int]()
        self.pattern.append(ms)
        self.vibrations += 1
        return DEV_OK

    def vibrate_pattern(mut self, ptr: UInt64, count: Int) -> Int:
        if self.caps & HAP_VIBRATE == 0:
            return DEV_UNSUPPORTED
        if not pattern_ok(ptr, count):
            return DEV_INVALID
        var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(ptr))
        self.pattern = List[Int]()
        for i in range(count):
            self.pattern.append(Int(p[2 * i]) | (Int(p[2 * i + 1]) << 8))
        self.vibrations += 1
        return DEV_OK

    def rumble(mut self, pad: Int, strong: Int, weak: Int, ms: Int) -> Int:
        if self.caps & HAP_RUMBLE == 0:
            return DEV_UNSUPPORTED
        if pad < 0 or pad >= MAX_PADS or strong < 0 or strong > 255 or weak < 0 or weak > 255 or ms < 1 or ms > MAX_VIBRATE_MS:
            return DEV_INVALID
        self.last_rumble = List[Int]()
        self.last_rumble.append(pad)
        self.last_rumble.append(strong)
        self.last_rumble.append(weak)
        self.last_rumble.append(ms)
        self.rumbles += 1
        return DEV_OK

    def cancel(mut self) -> Int:
        if self.caps == 0:
            return DEV_UNSUPPORTED
        self.pattern = List[Int]()
        self.cancels += 1
        return DEV_OK

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        return self._q.poll(buf, cap)

    def dropped(self) -> Int:
        return self._q.dropped()
