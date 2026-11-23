"""libc sockets for the native Transport backends (platform/transport_udp.mojo, platform/transport_tcp.mojo), through
`external_call`. Native only: nothing here may be reachable from the wasm64 module (its import audit would reject
`socket`, `send`, ...).

Every call that could wait is made non-blocking per call: `MSG_DONTWAIT` on send / recv, and `poll(2)` with a zero
timeout before `accept`. No `fcntl` (a variadic C function, which `external_call` cannot call correctly on arm64).
`connect` for TCP does block, once, while the connection is set up.

The constants are Linux x86-64 / arm64 values, measured by this repo's test; the macOS branch is from the macOS
headers and has not been built or run."""
from std.ffi import external_call
from std.sys import CompilationTarget


def _pick(linux: Int, macos: Int) -> Int:
    comptime if CompilationTarget.is_macos():
        return macos
    else:
        return linux


comptime AF_INET = 2
comptime AF_INET6 = _pick(10, 30)
comptime SOCK_STREAM = 1
comptime SOCK_DGRAM = 2
comptime IPPROTO_TCP = 6
comptime TCP_NODELAY = 1
comptime SOL_SOCKET = _pick(1, 0xFFFF)
comptime SO_REUSEADDR = _pick(2, 4)
comptime SO_NOSIGPIPE = 0x1022  # macOS only: Linux uses MSG_NOSIGNAL per call
comptime MSG_DONTWAIT = _pick(0x40, 0x80)
comptime MSG_NOSIGNAL = _pick(0x4000, 0)
comptime POLLIN = 1
comptime EAGAIN = _pick(11, 35)
comptime EINTR = 4
comptime ENOBUFS = _pick(105, 55)
comptime ECONNREFUSED = _pick(111, 61)


def errno() -> Int:
    var p: UInt64
    comptime if CompilationTarget.is_macos():
        p = external_call["__error", UInt64]()
    else:
        p = external_call["__errno_location", UInt64]()
    return Int(Pointer[Int32, MutUntrackedOrigin](unsafe_from_address=Int(p))[])


def would_block(e: Int) -> Bool:
    return e == EAGAIN or e == EINTR


struct SockAddr(Movable):
    """A sockaddr_in (16 bytes) or sockaddr_in6 (28 bytes) in a buffer this struct owns."""

    var bytes: List[UInt8]
    var family: Int

    def __init__(out self, host: String, port: Int) raises:
        """`host` is a numeric IPv4 ("127.0.0.1") or IPv6 ("::1") address; names are not resolved."""
        if port < 0 or port > 65535:
            raise Error("SockAddr: port out of range: " + String(port))
        self.family = AF_INET6 if ":" in host else AF_INET
        var size = 28 if self.family == AF_INET6 else 16
        self.bytes = List[UInt8](length=size, fill=0)
        comptime if CompilationTarget.is_macos():
            self.bytes[0] = UInt8(size)  # sin_len
            self.bytes[1] = UInt8(self.family)
        else:
            self.bytes[0] = UInt8(self.family & 0xFF)
            self.bytes[1] = UInt8(self.family >> 8)
        self.bytes[2] = UInt8(port >> 8)  # network byte order
        self.bytes[3] = UInt8(port & 0xFF)
        var c = List[UInt8]()
        for b in host.as_bytes():
            c.append(b)
        c.append(0)
        var at = 8 if self.family == AF_INET6 else 4
        var ok = external_call["inet_pton", Int32](
            Int32(self.family), Int(c.unsafe_ptr()), Int(self.bytes.unsafe_ptr()) + at
        )
        _ = c^
        if ok != 1:
            raise Error("SockAddr: not a numeric IPv4 or IPv6 address: " + host)

    def ptr(self) -> Int:
        return Int(self.bytes.unsafe_ptr())

    def size(self) -> Int:
        return len(self.bytes)


def open_socket(family: Int, kind: Int) raises -> Int32:
    var fd = external_call["socket", Int32](Int32(family), Int32(kind), Int32(0))
    if fd < 0:
        raise Error("socket() failed, errno " + String(errno()))
    comptime if CompilationTarget.is_macos():
        set_int_option(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)
    return fd


def set_int_option(fd: Int32, level: Int, name: Int, value: Int):
    var v = List[UInt8](length=4, fill=0)
    v[0] = UInt8(value & 0xFF)
    _ = external_call["setsockopt", Int32](fd, Int32(level), Int32(name), Int(v.unsafe_ptr()), UInt32(4))
    _ = v^


def bind_to(fd: Int32, addr: SockAddr) raises:
    if external_call["bind", Int32](fd, addr.ptr(), UInt32(addr.size())) != 0:
        raise Error("bind() failed, errno " + String(errno()))


def connect_to(fd: Int32, addr: SockAddr) raises:
    if external_call["connect", Int32](fd, addr.ptr(), UInt32(addr.size())) != 0:
        raise Error("connect() failed, errno " + String(errno()))


def local_port(fd: Int32) -> Int:
    """The port the socket is bound to (getsockname), or -1."""
    var a = List[UInt8](length=28, fill=0)
    var n = List[UInt8](length=4, fill=0)
    n[0] = 28
    var r = external_call["getsockname", Int32](fd, Int(a.unsafe_ptr()), Int(n.unsafe_ptr()))
    var port = (Int(a[2]) << 8) | Int(a[3])
    _ = a^
    _ = n^
    return port if r == 0 else -1


def readable(fd: Int32) -> Bool:
    """True when a read (or an accept) would not block: poll(2) with a zero timeout."""
    var p = List[UInt8](length=8, fill=0)  # struct pollfd { int fd; short events; short revents; }
    p[0] = UInt8(Int(fd) & 0xFF)
    p[1] = UInt8((Int(fd) >> 8) & 0xFF)
    p[2] = UInt8((Int(fd) >> 16) & 0xFF)
    p[3] = UInt8((Int(fd) >> 24) & 0xFF)
    p[4] = UInt8(POLLIN)
    var r = external_call["poll", Int32](Int(p.unsafe_ptr()), UInt64(1), Int32(0))
    var revents = Int(p[6]) | (Int(p[7]) << 8)
    _ = p^
    return r > 0 and revents != 0


def send_raw(fd: Int32, ptr: Int, length: Int) -> Int:
    """send(2) without blocking and without SIGPIPE: bytes sent, or -1 (see `errno()`)."""
    return external_call["send", Int](fd, ptr, length, Int32(MSG_DONTWAIT | MSG_NOSIGNAL))


def recv_raw(fd: Int32, ptr: Int, length: Int) -> Int:
    """recv(2) without blocking: bytes read, 0 at the peer's orderly end, or -1 (see `errno()`)."""
    return external_call["recv", Int](fd, ptr, length, Int32(MSG_DONTWAIT))


def close_fd(fd: Int32):
    if fd >= 0:
        _ = external_call["close", Int32](fd)
