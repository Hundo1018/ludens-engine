"""The result queue of the request / poll seams (identity, achievements, cloud save, lobby; docs/platform.md).

A request returns at once; its result is queued as a packet and the game takes it with `poll(buf, cap)` inside a
frame, the way `os_poll` returns file reads (shell/web/os_host.mjs). Packet layout, the same as os_poll's:

    [kind u8][id u32 LE][status u8][payload]

`id` is the number the caller gave the request (0 for events nobody asked for). poll returns the packet's length, 0
when nothing waits, or -1 when the next packet is larger than `cap`: it is dropped and counted (`dropped()`), and the
next call returns the packet behind it. A full queue (PACKET_QUEUE_LIMIT packets) drops the new packet and counts it
(`overflowed()`). Standard library only."""
from platform.transport import NET_DROPPED, NET_NONE, copy_bytes

comptime PACKET_HEADER = 6
comptime PACKET_QUEUE_LIMIT = 1024

comptime STATUS_OK = 0
comptime STATUS_NOT_FOUND = 1
comptime STATUS_ERROR = 2

comptime REQ_QUEUED = 0
"""A request was accepted; its result arrives through poll."""
comptime REQ_INVALID = -3
"""A request was refused at once (empty or too long a name, a payload over the backend's limit); nothing is queued."""
comptime REQ_FULL = -4
"""The result queue was full: the result is dropped and counted (`overflowed()`)."""
comptime REQ_CHEATED = -5
"""A request refused because the run used a cheat (platform/achievements.mojo `CheatGuard`); nothing is queued."""

comptime KIND_SIGN_IN = 16
comptime KIND_UNLOCK = 17
comptime KIND_STAT = 18
comptime KIND_SAVE_WRITE = 19
comptime KIND_SAVE_READ = 20
comptime KIND_LOBBY_ENTERED = 21
comptime KIND_LOBBY_MEMBER_JOINED = 22
comptime KIND_LOBBY_MEMBER_LEFT = 23
comptime KIND_LOBBY_LEFT = 24


def packet(kind: Int, id: Int, status: Int, payload: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8](length=PACKET_HEADER + len(payload), fill=0)
    out[0] = UInt8(kind)
    for i in range(4):
        out[1 + i] = UInt8((id >> (8 * i)) & 0xFF)
    out[5] = UInt8(status)
    for i in range(len(payload)):
        out[PACKET_HEADER + i] = payload[i]
    return out^


def text_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


struct PacketQueue(Copyable, Movable):
    var _items: List[List[UInt8]]
    var _head: Int
    var _dropped: Int
    var _overflowed: Int

    def __init__(out self):
        self._items = List[List[UInt8]]()
        self._head = 0
        self._dropped = 0
        self._overflowed = 0

    def push(mut self, var p: List[UInt8]) -> Int:
        """REQ_QUEUED, or REQ_FULL when PACKET_QUEUE_LIMIT packets already wait (the new one is dropped and counted)."""
        if len(self._items) - self._head >= PACKET_QUEUE_LIMIT:
            self._overflowed += 1
            return REQ_FULL
        self._items.append(p^)
        return REQ_QUEUED

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        if self._head >= len(self._items):
            return NET_NONE
        var n = len(self._items[self._head])
        if n > cap:
            self._dropped += 1
            n = NET_DROPPED
        else:
            copy_bytes(buf, UInt64(Int(self._items[self._head].unsafe_ptr())), n)
        self._items[self._head] = List[UInt8]()
        self._head += 1
        if self._head == len(self._items):
            self._items.clear()
            self._head = 0
        return n

    def dropped(self) -> Int:
        return self._dropped

    def overflowed(self) -> Int:
        return self._overflowed
