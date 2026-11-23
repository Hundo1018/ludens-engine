"""The Transport seam (docs/platform.md): one connection to one peer that carries byte messages.

A program picks its backend when it is built (`comptime NetTransport = WebSocketTransport` in `app/main.mojo`); nothing
is looked up at run time. Backends:

  platform/transport_web.mojo     WebSocketTransport  web: the `net_send` / `net_poll` imports (shell/web/net_host.mjs)
  platform/transport_memory.mojo  MemoryTransport     an in-process pair, for tests
  platform/transport_udp.mojo     UdpTransport        native: one connected UDP socket (unreliable datagrams)
  platform/transport_tcp.mojo     TcpTransport        native: one TCP stream, messages framed by a u32 LE length

Messages are addressed by a raw address and a length, the same form as the wasm imports, so the web backend passes them
through unchanged. Results:

  send  NET_OK (sent or queued), NET_NO_PEER (not connected, closed, or the peer is gone), NET_INVALID (length 0 or
        more than `max_message()`), NET_FULL (the outgoing queue is full: the new message is dropped and counted)
  poll  > 0 the length of the next message, copied to `buf`; NET_NONE (0) nothing waiting; NET_DROPPED (-1) the next
        message was larger than `cap`: it is dropped and counted, and the next call returns the message behind it;
        NET_CLOSED (-2) the connection is over and every message that arrived before the end has been returned.

An empty message cannot be told from NET_NONE, so it is never delivered (native backends refuse it with NET_INVALID).
`poll` never blocks."""

comptime NET_OK = 0
comptime NET_NONE = 0
comptime NET_DROPPED = -1
comptime NET_NO_PEER = -1
comptime NET_CLOSED = -2
comptime NET_INVALID = -3
comptime NET_FULL = -4

comptime DELIVERY_UNRELIABLE = 0
"""Messages may be lost, duplicated or reordered; each one arrives whole or not at all."""
comptime DELIVERY_RELIABLE_ORDERED = 1
"""Every message arrives once, in the order sent, until the connection closes."""

comptime UDP_MAX_MESSAGE = 65507
"""The largest UDP payload over IPv4 (65535 - 8 UDP - 20 IP header bytes)."""
comptime STREAM_MAX_MESSAGE = 16 * 1024 * 1024
"""The largest message of the stream backends (TCP, memory): a bound on what a peer can make the receiver buffer."""


trait Transport(Movable):
    def delivery(self) -> Int:
        """DELIVERY_UNRELIABLE or DELIVERY_RELIABLE_ORDERED: what the caller may assume about arrival."""
        ...

    def max_message(self) -> Int:
        """The longest message `send` accepts."""
        ...

    def send(mut self, ptr: UInt64, length: Int) -> Int:
        """Send `length` bytes at address `ptr` as one message: NET_OK, NET_NO_PEER, NET_INVALID or NET_FULL."""
        ...

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        """Copy the next received message to `buf` (at most `cap` bytes): its length, NET_NONE, NET_DROPPED or NET_CLOSED."""
        ...

    def dropped(self) -> Int:
        """Received messages dropped because they were larger than `cap` (each one answered NET_DROPPED once)."""
        ...

    def send_dropped(self) -> Int:
        """Outgoing messages dropped with NET_FULL."""
        ...

    def close(mut self):
        """End the connection. Afterwards `send` returns NET_NO_PEER and `poll` NET_CLOSED. Closing twice is a no-op."""
        ...


def send_bytes[T: Transport](mut t: T, data: List[UInt8]) -> Int:
    """`t.send` for a byte list."""
    return t.send(UInt64(Int(data.unsafe_ptr())), len(data))


def poll_bytes[T: Transport](mut t: T, mut buf: List[UInt8]) -> Int:
    """`t.poll` into a byte list of fixed length (its length is the capacity); the result as for `poll`."""
    return t.poll(UInt64(Int(buf.unsafe_ptr())), len(buf))


def copy_bytes(dst: UInt64, src: UInt64, n: Int):
    """Copy `n` bytes between two raw addresses (standard library only, so every backend and target can use it)."""
    var d = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(dst))
    var s = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(src))
    for i in range(n):
        d[i] = s[i]
