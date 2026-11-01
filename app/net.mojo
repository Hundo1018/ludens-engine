"""WebSocket bridge: two imports the JS host (shell/web/net_host.mjs) provides; declared in wasm.toml `host_imports`.

net_send(ptr, len) -> 0 queued/sent, -1 no socket.  net_poll(buf, cap) -> bytes of the next packet copied to
`buf`, 0 if none, -1 if the next packet is larger than `cap` (it stays queued)."""
from std.ffi import external_call


def net_send(ptr: UInt64, length: UInt64) -> Int32:
    return external_call["net_send", Int32](ptr, length)


def net_poll(buf: UInt64, cap: UInt64) -> Int64:
    return external_call["net_poll", Int64](buf, cap)
