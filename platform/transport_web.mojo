"""Web Transport backend: a WebSocket in the page, behind two imports the JS host (shell/web/net_host.mjs) provides;
declared in wasm.toml `host_imports` as `net_*`.

net_send(ptr, len) -> 0 queued/sent, -1 no socket.  net_poll(buf, cap) -> bytes of the next packet copied to `buf`, 0
if none, -1 if the next packet was larger than `cap`: the host drops it and counts it (`status.dropped`), so the next
call returns the packet behind it. The socket's end is not reported (a closed socket polls as empty), so this backend
never returns NET_CLOSED.

WebSocketTransport passes every call to the host as it is: no length check of its own (an empty message is handed to
the host, which sends it, and the receiver never sees it), and no queue on the Mojo side."""
from std.ffi import external_call
from platform.transport import DELIVERY_RELIABLE_ORDERED, NET_DROPPED, Transport

comptime WEB_MAX_MESSAGE = 1 << 30
"""No limit of its own: the receiver's `cap` is the bound (`NET_CAP` in app/main.mojo)."""


def net_send(ptr: UInt64, length: UInt64) -> Int32:
    return external_call["net_send", Int32](ptr, length)


def net_poll(buf: UInt64, cap: UInt64) -> Int64:
    return external_call["net_poll", Int64](buf, cap)


struct WebSocketTransport(Transport):
    var _dropped: Int

    def __init__(out self):
        self._dropped = 0

    def delivery(self) -> Int:
        return DELIVERY_RELIABLE_ORDERED

    def max_message(self) -> Int:
        return WEB_MAX_MESSAGE

    def send(mut self, ptr: UInt64, length: Int) -> Int:
        return Int(net_send(ptr, UInt64(length)))

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        var n = Int(net_poll(buf, UInt64(cap)))
        if n == NET_DROPPED:
            self._dropped += 1
        return n

    def dropped(self) -> Int:
        return self._dropped

    def send_dropped(self) -> Int:
        return 0

    def close(mut self):
        pass  # the page owns the socket (net_host.mjs `connect`); there is no close import yet
