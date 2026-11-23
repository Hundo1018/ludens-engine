"""Native TCP Transport backend: one TCP stream carrying messages framed as [u32 little-endian length][payload]
(libc, platform/socket.mojo). Native only.

    var server = TcpListener.listen("127.0.0.1", 0)       # port 0: the OS picks one (server.local_port())
    var client = TcpTransport.connect("127.0.0.1", server.local_port())
    var peer = server.accept()                            # Optional[TcpTransport], None when nobody is waiting

Delivery is reliable and ordered. `connect` blocks until the connection is set up; `send` and `poll` never block.
Outgoing bytes the kernel does not take at once wait in a queue of at most TCP_SEND_QUEUE bytes and go out on the next
`send` or `poll`; a message that does not fit is dropped and counted (NET_FULL). A received message larger than `cap` is
skipped in the stream without being buffered (NET_DROPPED, counted). When the peer ends the stream, the messages that
arrived before the end are returned first, then NET_CLOSED. A length of 0 or above STREAM_MAX_MESSAGE in the stream is a
protocol error and ends the connection. IPv4 and IPv6 (by the form of the address)."""
from std.ffi import external_call
from platform.socket import (
    IPPROTO_TCP,
    SOCK_STREAM,
    SOL_SOCKET,
    SO_REUSEADDR,
    TCP_NODELAY,
    SockAddr,
    bind_to,
    close_fd,
    connect_to,
    errno,
    local_port,
    open_socket,
    readable,
    recv_raw,
    send_raw,
    set_int_option,
    would_block,
)
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

comptime TCP_SEND_QUEUE = 4 * 1024 * 1024
comptime _CHUNK = 65536
comptime _HEADER = 4


struct TcpTransport(Transport):
    var _fd: Int32
    var _rx: List[UInt8]  # received bytes; [_rx_lo, _rx_hi) are not consumed yet
    var _rx_lo: Int
    var _rx_hi: Int
    var _skip: Int  # bytes of a dropped message still to discard from the stream
    var _tx: List[UInt8]  # framed bytes the kernel has not taken yet: [_tx_lo, len)
    var _tx_lo: Int
    var _eof: Bool  # the peer ended the stream (or it failed): nothing more will arrive
    var _dropped: Int
    var _send_dropped: Int

    def __init__(out self, fd: Int32):
        self._fd = fd
        self._rx = List[UInt8](length=_CHUNK, fill=0)
        self._rx_lo = 0
        self._rx_hi = 0
        self._skip = 0
        self._tx = List[UInt8]()
        self._tx_lo = 0
        self._eof = False
        self._dropped = 0
        self._send_dropped = 0
        set_int_option(fd, IPPROTO_TCP, TCP_NODELAY, 1)  # a message goes out when it is sent, not batched

    @staticmethod
    def connect(host: String, port: Int) raises -> TcpTransport:
        """Connect to `host`:`port`; blocks until the connection is set up or refused."""
        var addr = SockAddr(host, port)
        var fd = open_socket(addr.family, SOCK_STREAM)
        try:
            connect_to(fd, addr)
        except e:
            close_fd(fd)
            raise e^
        return TcpTransport(fd)

    def delivery(self) -> Int:
        return DELIVERY_RELIABLE_ORDERED

    def max_message(self) -> Int:
        return STREAM_MAX_MESSAGE

    def send(mut self, ptr: UInt64, length: Int) -> Int:
        if length <= 0 or length > STREAM_MAX_MESSAGE:
            return NET_INVALID
        if self._fd < 0 or self._eof:
            return NET_NO_PEER
        if len(self._tx) - self._tx_lo + _HEADER + length > TCP_SEND_QUEUE:
            self._flush()
            if len(self._tx) - self._tx_lo + _HEADER + length > TCP_SEND_QUEUE:
                self._send_dropped += 1
                return NET_FULL
        var at = len(self._tx)
        self._tx.resize(at + _HEADER + length, 0)
        for i in range(_HEADER):
            self._tx[at + i] = UInt8((length >> (8 * i)) & 0xFF)
        copy_bytes(UInt64(Int(self._tx.unsafe_ptr()) + at + _HEADER), ptr, length)
        self._flush()
        return NET_NO_PEER if self._eof else NET_OK

    def _flush(mut self):
        while self._fd >= 0 and not self._eof and self._tx_lo < len(self._tx):
            var n = send_raw(self._fd, Int(self._tx.unsafe_ptr()) + self._tx_lo, len(self._tx) - self._tx_lo)
            if n > 0:
                self._tx_lo += n
                continue
            if n < 0 and would_block(errno()):
                break
            self._eof = True  # EPIPE, ECONNRESET: the peer is gone
        if self._tx_lo == len(self._tx):
            self._tx.clear()
            self._tx_lo = 0

    def _fill(mut self):
        """Read what the kernel has, without blocking; stop once a whole message of the largest size could be parsed."""
        while self._fd >= 0 and not self._eof and self._rx_hi - self._rx_lo < _HEADER + STREAM_MAX_MESSAGE:
            if self._rx_lo > 0 and self._rx_lo == self._rx_hi:
                self._rx_lo = 0
                self._rx_hi = 0
            if len(self._rx) - self._rx_hi < _CHUNK:
                if self._rx_lo > 0:  # move the unread bytes to the front before growing
                    var live = self._rx_hi - self._rx_lo
                    var base = Int(self._rx.unsafe_ptr())
                    copy_bytes(UInt64(base), UInt64(base + self._rx_lo), live)
                    self._rx_lo = 0
                    self._rx_hi = live
                if len(self._rx) - self._rx_hi < _CHUNK:
                    self._rx.resize(self._rx_hi + _CHUNK, 0)
            var n = recv_raw(self._fd, Int(self._rx.unsafe_ptr()) + self._rx_hi, len(self._rx) - self._rx_hi)
            if n > 0:
                self._rx_hi += n
                self._discard()
                continue
            if n < 0 and would_block(errno()):
                break
            self._eof = True  # 0: the peer's orderly end; -1 otherwise: ECONNRESET and the like

    def _discard(mut self):
        var k = min(self._skip, self._rx_hi - self._rx_lo)
        self._skip -= k
        self._rx_lo += k

    def _header(self) -> Int:
        var n = 0
        for i in range(_HEADER):
            n |= Int(self._rx[self._rx_lo + i]) << (8 * i)
        return n

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        if self._fd < 0:
            return NET_CLOSED
        self._flush()
        self._fill()
        self._discard()
        var have = self._rx_hi - self._rx_lo
        if self._skip == 0 and have >= _HEADER:
            var n = self._header()
            if n <= 0 or n > STREAM_MAX_MESSAGE:
                self.close()  # not a stream of this framing
                return NET_CLOSED
            if n > cap:
                self._rx_lo += _HEADER
                self._skip = n
                self._discard()
                self._dropped += 1
                return NET_DROPPED
            if have >= _HEADER + n:
                copy_bytes(buf, UInt64(Int(self._rx.unsafe_ptr()) + self._rx_lo + _HEADER), n)
                self._rx_lo += _HEADER + n
                return n
        if self._eof:
            self.close()
            return NET_CLOSED
        return NET_NONE

    def dropped(self) -> Int:
        return self._dropped

    def send_dropped(self) -> Int:
        return self._send_dropped

    def close(mut self):
        close_fd(self._fd)
        self._fd = -1
        self._eof = True
        self._tx.clear()
        self._tx_lo = 0

    def __deinit__(deinit self):
        close_fd(self._fd)


struct TcpListener(Movable):
    """A listening TCP socket; `accept` hands out one TcpTransport per incoming connection, without blocking."""

    var _fd: Int32

    def __init__(out self, fd: Int32):
        self._fd = fd

    @staticmethod
    def listen(host: String, port: Int, backlog: Int = 16) raises -> TcpListener:
        var addr = SockAddr(host, port)
        var fd = open_socket(addr.family, SOCK_STREAM)
        set_int_option(fd, SOL_SOCKET, SO_REUSEADDR, 1)
        try:
            bind_to(fd, addr)
        except e:
            close_fd(fd)
            raise e^
        if external_call["listen", Int32](fd, Int32(backlog)) != 0:
            close_fd(fd)
            raise Error("listen() failed, errno " + String(errno()))
        return TcpListener(fd)

    def local_port(self) -> Int:
        return local_port(self._fd)

    def accept(mut self) -> Optional[TcpTransport]:
        """The next waiting connection, or None."""
        if self._fd < 0 or not readable(self._fd):
            return None
        var fd = external_call["accept", Int32](self._fd, Int(0), Int(0))
        if fd < 0:
            return None
        return TcpTransport(fd)

    def close(mut self):
        close_fd(self._fd)
        self._fd = -1

    def __deinit__(deinit self):
        close_fd(self._fd)
