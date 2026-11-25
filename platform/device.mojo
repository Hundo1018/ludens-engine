"""Shared parts of the device seams (docs/platform.md, "Device seams"): which device, what state its permission is in,
the result packet kinds, the return codes, and `PermissionGate`, the permission state the in-memory backends use.

A device request returns at once. When it finishes (a permission prompt answered, a camera opened, fullscreen entered) the
result is a packet in the layout `os_poll` uses, `[kind u8][id u32 LE][status u8][payload]` (platform/packets.mojo); the
game takes it with the seam's `poll(buf, cap)`. Reads of a device that is already open (the latest motion sample, a camera
frame, microphone samples, pointer movement) are plain calls that copy into a buffer the game owns.

Standard library only."""
from platform.packets import PacketQueue, REQ_INVALID, STATUS_ERROR, STATUS_OK, packet

comptime DEV_HAPTICS = 1
comptime DEV_MOTION = 2
comptime DEV_SCREEN = 3
comptime DEV_POINTER_LOCK = 4
comptime DEV_CAMERA = 5
comptime DEV_MICROPHONE = 6

comptime AVAIL_UNSUPPORTED = 0
"""No such device or API here (no camera, iOS Safari's `navigator.vibrate`, an insecure page)."""
comptime AVAIL_PROMPT = 1
"""Usable after a request: the user has not been asked yet, or the platform asks on first use."""
comptime AVAIL_GRANTED = 2
comptime AVAIL_DENIED = 3

comptime DEV_OK = 0
comptime DEV_INVALID = REQ_INVALID
"""An argument is out of range (-3, the value REQ_INVALID has)."""
comptime DEV_UNSUPPORTED = -5
comptime DEV_NOT_GRANTED = -6
"""The permission was denied, or is not asked for yet and the call does not ask."""
comptime DEV_BUSY = -7
"""The device is already open."""

comptime KIND_DEV_PERMISSION = 32
"""Result of `request_permission`. Payload: [device u8][availability u8]. Status STATUS_OK when granted, else STATUS_ERROR."""
comptime KIND_DEV_SCREEN = 33
"""Result of a screen request. Payload: [op u8][state flags u8]. STATUS_ERROR when the platform refused."""
comptime KIND_DEV_POINTER = 34
"""Result of a pointer lock request, or the lock ending (id 0). Payload: [locked u8]."""
comptime KIND_DEV_CAMERA = 35
"""Result of a camera open. STATUS_OK: payload [width u32 LE][height u32 LE]. STATUS_ERROR: payload [availability u8]."""
comptime KIND_DEV_MIC = 36
"""Result of a microphone open. STATUS_OK: payload [sample rate u32 LE]. STATUS_ERROR: payload [availability u8]."""
comptime DEV_KIND_FIRST = 32
comptime DEV_KIND_COUNT = 8


def u32_bytes(v: Int) -> List[UInt8]:
    var out = List[UInt8](length=4, fill=0)
    for i in range(4):
        out[i] = UInt8((v >> (8 * i)) & 0xFF)
    return out^


def write_f32(addr: UInt64, index: Int, v: Float32):
    """Write one f32 at `addr + 4 * index` (little endian, the host's layout)."""
    var p = UnsafePointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(addr))
    p[index] = v


def read_f32(addr: UInt64, index: Int) -> Float32:
    var p = UnsafePointer[Float32, MutUntrackedOrigin](unsafe_from_address=Int(addr))
    return p[index]


struct PermissionGate(Movable):
    """The permission state of one in-memory device. `answer` is what the user will say when asked (`True`: allow). A
    device that is AVAIL_UNSUPPORTED stays so. `resolve()` is the prompt: AVAIL_PROMPT becomes GRANTED or DENIED, and a
    decision that was already made stays."""
    var device: Int
    var state: Int
    var answer: Bool
    var asked: Int

    def __init__(out self, device: Int, state: Int = AVAIL_PROMPT, answer: Bool = True):
        self.device = device
        self.state = state
        self.answer = answer
        self.asked = 0

    def resolve(mut self) -> Bool:
        """True when the device may be used now. Shows the prompt once if the state is AVAIL_PROMPT."""
        if self.state == AVAIL_PROMPT:
            self.asked += 1
            self.state = AVAIL_GRANTED if self.answer else AVAIL_DENIED
        return self.state == AVAIL_GRANTED

    def request(mut self, id: Int, mut q: PacketQueue) -> Int:
        """Queue a KIND_DEV_PERMISSION result for `request_permission(id)`."""
        var ok = self.resolve()
        var payload = List[UInt8]()
        payload.append(UInt8(self.device))
        payload.append(UInt8(self.state))
        return q.push(packet(KIND_DEV_PERMISSION, id, STATUS_OK if ok else STATUS_ERROR, payload^))
