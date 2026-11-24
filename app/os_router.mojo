"""The one reader of `os_poll`. The host has a single result queue (shell/web/os_host.mjs): whoever calls `os_poll` takes the next
packet whoever asked for it, so two consumers that each poll drop each other's results. The router drains it and keeps a queue per
owner, chosen by what the packet is:

    kind 2 (file read) with id PROFILE_READ_ID  -> the input profile (app/profile.mojo)
    kind 2 (file read) with any other id        -> the save seam (app/os_cloud_save.mojo)
    kind 1 (clipboard text)                     -> the clipboard consumer
    anything else                               -> dropped and counted in `foreign()`

An owner takes only its own queue (`take_profile`, `take_file`, `take_clipboard`; each pumps first), so a packet waits until
its owner asks. A packet larger than `cap` given to `OsRouter(cap)` (default 4 MiB) is dropped by the host and counted in
`oversized()`: the router reads into one buffer of its own, not the caller's.

An `OsRouter` is a handle: a copy shares the queues, so the app gives the same router to every consumer."""
from std.memory import alloc
from os import os_poll
from platform.packets import PACKET_HEADER, PacketQueue

comptime PROFILE_READ_ID: Int32 = 117  # the request id the input profile read is made with (app/profile.mojo)
comptime ROUTER_CAP = 4 * 1024 * 1024
comptime _KIND_CLIPBOARD = 1
comptime _KIND_FILE = 2
comptime _PER_PUMP = 256


struct _Inbox(Movable):
    var profile: PacketQueue
    var files: PacketQueue
    var clipboard: PacketQueue
    var rx: List[UInt8]
    var foreign: Int
    var oversized: Int

    def __init__(out self, cap: Int):
        self.profile = PacketQueue()
        self.files = PacketQueue()
        self.clipboard = PacketQueue()
        self.rx = List[UInt8](length=cap, fill=0)
        self.foreign = 0
        self.oversized = 0


struct OsRouter(Copyable, ImplicitlyCopyable, Movable):
    var _p: UnsafePointer[_Inbox, MutUntrackedOrigin]

    def __init__(out self, cap: Int = ROUTER_CAP):
        var p = alloc[_Inbox](1)
        p.unsafe_write(_Inbox(cap))
        self._p = UnsafePointer[_Inbox, MutUntrackedOrigin](unsafe_from_address=Int(p))

    def pump(self):
        """Move what the host has queued (at most 256 packets) into the owners' queues."""
        for _ in range(_PER_PUMP):
            var n = Int(os_poll(UInt64(Int(self._p[].rx.unsafe_ptr())), UInt64(len(self._p[].rx))))
            if n == 0:
                return
            if n < 0:
                self._p[].oversized += 1
                continue
            if n < PACKET_HEADER:
                self._p[].foreign += 1
                continue
            var kind = Int(self._p[].rx[0])
            var id = Int(self._p[].rx[1]) | (Int(self._p[].rx[2]) << 8) | (Int(self._p[].rx[3]) << 16) | (Int(self._p[].rx[4]) << 24)
            var bytes = List[UInt8](length=n, fill=0)
            for i in range(n):
                bytes[i] = self._p[].rx[i]
            if kind == _KIND_FILE and id == Int(PROFILE_READ_ID):
                _ = self._p[].profile.push(bytes^)
            elif kind == _KIND_FILE:
                _ = self._p[].files.push(bytes^)
            elif kind == _KIND_CLIPBOARD:
                _ = self._p[].clipboard.push(bytes^)
            else:
                self._p[].foreign += 1

    def take_profile(self, buf: UInt64, cap: Int) -> Int:
        """The next profile packet (PacketQueue.poll: length, 0 none, -1 dropped for being larger than cap)."""
        self.pump()
        return self._p[].profile.poll(buf, cap)

    def take_file(self, buf: UInt64, cap: Int) -> Int:
        self.pump()
        return self._p[].files.poll(buf, cap)

    def take_clipboard(self, buf: UInt64, cap: Int) -> Int:
        self.pump()
        return self._p[].clipboard.poll(buf, cap)

    def foreign(self) -> Int:
        return self._p[].foreign

    def oversized(self) -> Int:
        return self._p[].oversized
