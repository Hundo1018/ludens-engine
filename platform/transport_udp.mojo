"""Native UDP Transport backend: one UDP socket connected to one peer (libc, platform/socket.mojo). Native only.

    var a = UdpTransport.bind("127.0.0.1", 0)    # port 0: the OS picks one, read it with local_port()
    a.connect("127.0.0.1", peer_port)

Delivery is unreliable: a datagram can be lost, duplicated or reordered, and arrives whole or not at all. A message is
at most UDP_MAX_MESSAGE bytes. Until `connect`, send is NET_NO_PEER. A full socket send buffer is NET_FULL (the message
is dropped and counted). A datagram larger than `cap` is dropped and counted (NET_DROPPED).

UDP has no connection, so the end of the peer is not guaranteed to be seen: poll keeps returning NET_NONE. When the OS
reports the peer's port unreachable (Linux, a connected socket after an ICMP error) poll returns NET_CLOSED and the
socket is closed. IPv4 and IPv6 (by the form of the address)."""
from platform.socket import (
    ECONNREFUSED,
    ENOBUFS,
    SOCK_DGRAM,
    SockAddr,
    bind_to,
    close_fd,
    connect_to,
    errno,
    local_port,
    open_socket,
    recv_raw,
    send_raw,
    would_block,
)
from platform.transport import (
    DELIVERY_UNRELIABLE,
    NET_CLOSED,
    NET_DROPPED,
    NET_FULL,
    NET_INVALID,
    NET_NONE,
    NET_NO_PEER,
    NET_OK,
    UDP_MAX_MESSAGE,
    Transport,
    copy_bytes,
)

comptime _SCRATCH = 65536  # more than the largest datagram, so a recv never truncates and the true length is known


struct UdpTransport(Transport):
    var _fd: Int32
    var _connected: Bool
    var _scratch: List[UInt8]
    var _dropped: Int
    var _send_dropped: Int

    def __init__(out self, fd: Int32):
        self._fd = fd
        self._connected = False
        self._scratch = List[UInt8](length=_SCRATCH, fill=0)
        self._dropped = 0
        self._send_dropped = 0

    @staticmethod
    def bind(host: String, port: Int) raises -> UdpTransport:
        """A socket bound to `host`:`port` (port 0 lets the OS choose)."""
        var addr = SockAddr(host, port)
        var fd = open_socket(addr.family, SOCK_DGRAM)
        try:
            bind_to(fd, addr)
        except e:
            close_fd(fd)
            raise e^
        return UdpTransport(fd)

    def connect(mut self, host: String, port: Int) raises:
        """Send to, and receive only from, `host`:`port`."""
        if self._fd < 0:
            raise Error("UdpTransport.connect: closed")
        connect_to(self._fd, SockAddr(host, port))
        self._connected = True

    def local_port(self) -> Int:
        return local_port(self._fd)

    def delivery(self) -> Int:
        return DELIVERY_UNRELIABLE

    def max_message(self) -> Int:
        return UDP_MAX_MESSAGE

    def send(mut self, ptr: UInt64, length: Int) -> Int:
        if length <= 0 or length > UDP_MAX_MESSAGE:
            return NET_INVALID
        if self._fd < 0 or not self._connected:
            return NET_NO_PEER
        var n = send_raw(self._fd, Int(ptr), length)
        if n == length:
            return NET_OK
        var e = errno()
        if would_block(e) or e == ENOBUFS:
            self._send_dropped += 1
            return NET_FULL
        return NET_NO_PEER  # ECONNREFUSED after an ICMP error, or the socket is unusable

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        if self._fd < 0:
            return NET_CLOSED
        while True:
            var n = recv_raw(self._fd, Int(self._scratch.unsafe_ptr()), _SCRATCH)
            if n < 0:
                var e = errno()
                if e == ECONNREFUSED:
                    self.close()
                    return NET_CLOSED
                return NET_NONE  # EAGAIN, or an error that leaves nothing to read
            if n == 0:
                continue  # an empty datagram: never sent by a Transport, and it cannot be told from NET_NONE
            if n > cap:
                self._dropped += 1
                return NET_DROPPED
            copy_bytes(buf, UInt64(Int(self._scratch.unsafe_ptr())), n)
            return n

    def dropped(self) -> Int:
        return self._dropped

    def send_dropped(self) -> Int:
        return self._send_dropped

    def close(mut self):
        close_fd(self._fd)
        self._fd = -1
        self._connected = False

    def __deinit__(deinit self):
        close_fd(self._fd)
