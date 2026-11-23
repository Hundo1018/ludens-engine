"""In-memory Transport backend: two ends of one pipe in the same process, for tests and for a local game whose server
runs in the same program.

`MemoryPipe().end(0)` and `.end(1)` are the two ends. Each direction is a queue of at most `MEMORY_QUEUE_LIMIT` messages (more is NET_FULL:
the new message is dropped and counted). Closing one end lets the other drain what was already queued, then it polls
NET_CLOSED; a send to a closed peer is NET_NO_PEER. Delivery is reliable and ordered. Standard library only, so it
also builds for wasm64."""
from std.memory import ArcPointer
from platform.transport import (
    DELIVERY_RELIABLE_ORDERED,
    NET_CLOSED,
    NET_DROPPED,
    NET_FULL,
    NET_INVALID,
    NET_NONE,
    NET_NO_PEER,
    NET_OK,
    STREAM_MAX_MESSAGE,
    Transport,
    copy_bytes,
)

comptime MEMORY_QUEUE_LIMIT = 4096


struct _Pipe(Movable):
    var queue: List[List[List[UInt8]]]  # queue[side]: messages waiting for end `side`
    var head: List[Int]  # index of the next unread message of queue[side]
    var closed: List[Bool]  # closed[side]: end `side` was closed

    def __init__(out self):
        self.queue = List[List[List[UInt8]]]()
        self.queue.append(List[List[UInt8]]())
        self.queue.append(List[List[UInt8]]())
        self.head = [0, 0]
        self.closed = [False, False]


struct MemoryTransport(Transport):
    var _pipe: ArcPointer[_Pipe]
    var _side: Int
    var _max: Int
    var _dropped: Int
    var _send_dropped: Int

    def __init__(out self, pipe: ArcPointer[_Pipe], side: Int, max_message: Int):
        self._pipe = pipe
        self._side = side
        self._max = max_message
        self._dropped = 0
        self._send_dropped = 0

    def delivery(self) -> Int:
        return DELIVERY_RELIABLE_ORDERED

    def max_message(self) -> Int:
        return self._max

    def send(mut self, ptr: UInt64, length: Int) -> Int:
        if length <= 0 or length > self._max:
            return NET_INVALID
        var other = 1 - self._side
        if self._pipe[].closed[self._side] or self._pipe[].closed[other]:
            return NET_NO_PEER
        if len(self._pipe[].queue[other]) - self._pipe[].head[other] >= MEMORY_QUEUE_LIMIT:
            self._send_dropped += 1
            return NET_FULL
        var msg = List[UInt8](length=length, fill=0)
        copy_bytes(UInt64(Int(msg.unsafe_ptr())), ptr, length)
        self._pipe[].queue[other].append(msg^)
        return NET_OK

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        var me = self._side
        if self._pipe[].closed[me]:
            return NET_CLOSED
        var h = self._pipe[].head[me]
        if h >= len(self._pipe[].queue[me]):
            return NET_CLOSED if self._pipe[].closed[1 - me] else NET_NONE
        var n = len(self._pipe[].queue[me][h])
        self._pipe[].head[me] = h + 1
        if n > cap:
            self._dropped += 1
            n = NET_DROPPED
        else:
            copy_bytes(buf, UInt64(Int(self._pipe[].queue[me][h].unsafe_ptr())), n)
        self._pipe[].queue[me][h] = List[UInt8]()  # free the payload now; the slot goes at the next compaction
        if self._pipe[].head[me] == len(self._pipe[].queue[me]):
            self._pipe[].queue[me].clear()
            self._pipe[].head[me] = 0
        return n

    def dropped(self) -> Int:
        return self._dropped

    def send_dropped(self) -> Int:
        return self._send_dropped

    def close(mut self):
        self._pipe[].closed[self._side] = True


struct MemoryPipe(Movable):
    """A new pipe: what `end(0)` sends, `end(1)` polls, and the other way round."""

    var _pipe: ArcPointer[_Pipe]
    var _max: Int

    def __init__(out self, max_message: Int = STREAM_MAX_MESSAGE):
        self._pipe = ArcPointer(_Pipe())
        self._max = max_message

    def end(self, side: Int) -> MemoryTransport:
        """End 0 or 1. Take each end once: two transports on one side would share its queue."""
        return MemoryTransport(self._pipe, side & 1, self._max)
