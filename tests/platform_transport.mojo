"""The Transport seam (platform/transport.mojo): one send / poll script over every native backend.

Each backend runs the same script and must receive the same byte sequences: the in-memory pipe, UDP on 127.0.0.1, TCP
on 127.0.0.1, and UDP and TCP on ::1 when the host has IPv6 loopback (skipped with a printed line when it does not).
Checked per backend: an empty poll, the refusal of an empty and an over-long message, a message larger than the
receiver's `cap` (dropped once, counted, the next one arrives intact), and what the other end sees after a close.
Every wait is bounded by a deadline, so a lost UDP datagram fails the check instead of hanging.

Standard library only: `pixi run -e wasm test-transport` builds it without the engine on the include path."""
from std.time import perf_counter_ns
from platform.transport import (
    DELIVERY_RELIABLE_ORDERED,
    NET_CLOSED,
    NET_DROPPED,
    NET_INVALID,
    NET_NONE,
    NET_NO_PEER,
    NET_OK,
    Transport,
    poll_bytes,
    send_bytes,
)
from platform.socket import SockAddr
from platform.transport_memory import MemoryPipe
from platform.transport_tcp import TcpListener, TcpTransport
from platform.transport_udp import UdpTransport

comptime CAP = 65536
comptime WAIT_NS = 2_000_000_000


def sizes() -> List[Int]:
    """Message lengths of the script, up to the largest UDP payload."""
    return [1, 2, 7, 100, 1000, 1400, 1500, 4000, 9000, 30000, 65507, 3, 64, 512, 65000, 17]
comptime BURST = 8


struct Check:
    var passed: Int
    var failed: Int

    def __init__(out self):
        self.passed = 0
        self.failed = 0

    def check(mut self, ok: Bool, label: String):
        if ok:
            self.passed += 1
        else:
            self.failed += 1
        print("  [" + ("PASS" if ok else "FAIL") + "] " + label)


def message(seed: Int, n: Int) -> List[UInt8]:
    var out = List[UInt8](length=n, fill=0)
    var s = UInt64(seed) * 0x9E3779B97F4A7C15 + 1
    for i in range(n):
        s = s * 6364136223846793005 + 1442695040888963407
        out[i] = UInt8(s >> 56)
    return out^


def fnv(h: UInt64, data: List[UInt8], n: Int) -> UInt64:
    var x = (h ^ UInt64(n)) * 0x100000001B3
    for i in range(n):
        x = (x ^ UInt64(data[i])) * 0x100000001B3
    return x


def wait_poll[T: Transport](mut t: T, mut buf: List[UInt8]) -> Int:
    """Poll until something other than NET_NONE comes back, or the deadline passes (then NET_NONE)."""
    var end = perf_counter_ns() + WAIT_NS
    while perf_counter_ns() < end:
        var r = poll_bytes(t, buf)
        if r != NET_NONE:
            return r
    return NET_NONE


def script_hash() -> UInt64:
    """What the script sends, hashed the way the receiver hashes what it gets."""
    var h = UInt64(0xCBF29CE484222325)
    var sz = sizes()
    for i in range(len(sz)):
        var m = message(i, sz[i])
        h = fnv(h, m, len(m))
    for i in range(BURST):
        var m = message(100 + i, 10 + i)
        h = fnv(h, m, len(m))
    return h


def run_script[T: Transport](mut c: Check, name: String, mut a: T, mut b: T) -> UInt64:
    """The shared script: messages alternate a -> b and b -> a, each polled before the next is sent; then a burst
    of BURST a -> b, sent before any is polled. Returns the hash of everything received, in order."""
    var buf = List[UInt8](length=CAP, fill=0)
    c.check(poll_bytes(a, buf) == NET_NONE and poll_bytes(b, buf) == NET_NONE, name + ": empty poll is NET_NONE")
    var empty = List[UInt8]()
    var too_long = List[UInt8](length=a.max_message() + 1, fill=1)
    c.check(send_bytes(a, empty) == NET_INVALID, name + ": an empty message is NET_INVALID")
    c.check(send_bytes(a, too_long) == NET_INVALID, name + ": a message over max_message() is NET_INVALID")
    var h = UInt64(0xCBF29CE484222325)
    var sent_ok = True
    var sz = sizes()
    for i in range(len(sz)):
        var m = message(i, sz[i])
        var r: Int
        var got: Int
        if i % 2 == 0:
            r = send_bytes(a, m)
            got = wait_poll(b, buf)
        else:
            r = send_bytes(b, m)
            got = wait_poll(a, buf)
        sent_ok = sent_ok and r == NET_OK and got == len(m)
        if got > 0:
            h = fnv(h, buf, got)
    for i in range(BURST):
        sent_ok = sent_ok and send_bytes(a, message(100 + i, 10 + i)) == NET_OK
    for _ in range(BURST):
        var got = wait_poll(b, buf)
        if got > 0:
            h = fnv(h, buf, got)
    c.check(sent_ok, name + ": " + String(len(sz) + BURST) + " messages sent with NET_OK, each received at its length")
    return h


def oversize[T: Transport](mut c: Check, name: String, mut a: T, mut b: T):
    """100, 3000 and 50 bytes against a 1000-byte cap: 100, NET_DROPPED once, then 50."""
    var small = List[UInt8](length=1000, fill=0)
    _ = send_bytes(a, message(7, 100))
    _ = send_bytes(a, message(8, 3000))
    _ = send_bytes(a, message(9, 50))
    var r1 = wait_poll(b, small)
    var r2 = wait_poll(b, small)
    var r3 = wait_poll(b, small)
    var want = message(9, 50)
    var same = r3 == 50
    for i in range(50):
        same = same and r3 == 50 and small[i] == want[i]
    c.check(r1 == 100, name + ": first message within cap arrives (" + String(r1) + ")")
    c.check(r2 == NET_DROPPED and b.dropped() == 1, name + ": the message over cap is NET_DROPPED once and counted")
    c.check(same, name + ": the message behind the dropped one arrives intact")


def closed_reliable[T: Transport](mut c: Check, name: String, mut a: T, mut b: T):
    """End a sends two messages and closes: b gets both, then NET_CLOSED; sends either way are NET_NO_PEER."""
    var buf = List[UInt8](length=CAP, fill=0)
    _ = send_bytes(a, message(20, 40))
    _ = send_bytes(a, message(21, 41))
    a.close()
    var r1 = wait_poll(b, buf)
    var r2 = wait_poll(b, buf)
    var r3 = wait_poll(b, buf)
    c.check(r1 == 40 and r2 == 41, name + ": messages sent before the close are delivered first")
    c.check(r3 == NET_CLOSED, name + ": then NET_CLOSED (" + String(r3) + ")")
    c.check(send_bytes(b, message(22, 5)) == NET_NO_PEER, name + ": a send to the closed peer is NET_NO_PEER")
    c.check(send_bytes(a, message(23, 5)) == NET_NO_PEER and poll_bytes(a, buf) == NET_CLOSED,
            name + ": the closed end sends NET_NO_PEER and polls NET_CLOSED")
    a.close()
    c.check(poll_bytes(a, buf) == NET_CLOSED, name + ": closing twice is a no-op")


def closed_udp(mut c: Check, name: String, mut a: UdpTransport, mut b: UdpTransport):
    """UDP has no connection: after a closes, b's polls are NET_NONE or NET_CLOSED (ICMP port unreachable), never a hang."""
    var buf = List[UInt8](length=CAP, fill=0)
    a.close()
    _ = send_bytes(b, message(24, 5))
    var ok = True
    var end = perf_counter_ns() + 200_000_000
    var saw_closed = False
    while perf_counter_ns() < end:
        var r = poll_bytes(b, buf)
        ok = ok and (r == NET_NONE or r == NET_CLOSED)
        saw_closed = saw_closed or r == NET_CLOSED
    c.check(ok, name + ": after the peer closes, poll is NET_NONE or NET_CLOSED (saw NET_CLOSED: " + String(saw_closed) + ")")
    c.check(send_bytes(a, message(25, 5)) == NET_NO_PEER and poll_bytes(a, buf) == NET_CLOSED,
            name + ": the closed end sends NET_NO_PEER and polls NET_CLOSED")


def udp_case(mut c: Check, host: String, want: UInt64) raises:
    var name = "udp " + host
    var a = UdpTransport.bind(host, 0)
    var b = UdpTransport.bind(host, 0)
    a.connect(host, b.local_port())
    b.connect(host, a.local_port())
    c.check(a.delivery() != DELIVERY_RELIABLE_ORDERED, name + ": delivery is unreliable")
    c.check(run_script(c, name, a, b) == want, name + ": received bytes hash to the script's hash")
    oversize(c, name, a, b)
    closed_udp(c, name, a, b)


def accept_within(mut server: TcpListener) raises -> TcpTransport:
    var end = perf_counter_ns() + WAIT_NS
    while perf_counter_ns() < end:
        var acc = server.accept()
        if acc:
            return acc.take()
    raise Error("tcp: accept timed out")


def tcp_case(mut c: Check, host: String, want: UInt64) raises:
    var name = "tcp " + host
    var server = TcpListener.listen(host, 0)
    c.check(server.accept() == None, name + ": accept with nobody waiting is None")
    var a = TcpTransport.connect(host, server.local_port())
    var b = accept_within(server)
    c.check(a.delivery() == DELIVERY_RELIABLE_ORDERED, name + ": delivery is reliable and ordered")
    c.check(run_script(c, name, a, b) == want, name + ": received bytes hash to the script's hash")
    oversize(c, name, a, b)
    # A dropped message far larger than what one recv returns is skipped in the stream, not buffered.
    var big = message(30, 1 << 20)
    var after = message(31, 77)
    var buf = List[UInt8](length=CAP, fill=0)
    _ = send_bytes(a, big)
    _ = send_bytes(a, after)
    var r1 = wait_poll(b, buf)
    var r2 = wait_poll(b, buf)
    var same = r2 == 77
    for i in range(77):
        same = same and r2 == 77 and buf[i] == after[i]
    c.check(r1 == NET_DROPPED and b.dropped() == 2 and same, name + ": a 1 MiB message over cap is skipped, the next arrives")
    closed_reliable(c, name, a, b)
    server.close()


def memory_case(mut c: Check, want: UInt64):
    var name = String("memory")
    var pipe = MemoryPipe()
    var a = pipe.end(0)
    var b = pipe.end(1)
    c.check(a.delivery() == DELIVERY_RELIABLE_ORDERED, name + ": delivery is reliable and ordered")
    c.check(run_script(c, name, a, b) == want, name + ": received bytes hash to the script's hash")
    oversize(c, name, a, b)
    closed_reliable(c, name, a, b)


def addr_layout(mut c: Check) raises:
    """The sockaddr bytes, checked without a socket (inet_pton is libc only), so the IPv6 layout is checked even where
    the kernel has no IPv6 (Linux layout: family u16 little-endian, port big-endian)."""
    var v4 = SockAddr("127.0.0.1", 0x1234)
    var want4: List[UInt8] = [2, 0, 0x12, 0x34, 127, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]
    c.check(v4.bytes == want4, "sockaddr_in for 127.0.0.1:0x1234")
    var v6 = SockAddr("::1", 0x1234)
    var want6 = List[UInt8](length=28, fill=0)
    want6[0] = 10
    want6[2] = 0x12
    want6[3] = 0x34
    want6[23] = 1  # sin6_addr is bytes 8..23; flowinfo (4..7) and scope_id (24..27) stay 0
    c.check(v6.bytes == want6, "sockaddr_in6 for [::1]:0x1234")
    var bad = False
    try:
        _ = SockAddr("localhost", 1)
    except:
        bad = True
    c.check(bad, "a host name (not a numeric address) is refused")


def main() raises:
    var c = Check()
    addr_layout(c)
    var want = script_hash()
    memory_case(c, want)
    udp_case(c, "127.0.0.1", want)
    tcp_case(c, "127.0.0.1", want)
    var v6 = True
    try:
        var probe = UdpTransport.bind("::1", 0)
        probe.close()
    except e:
        v6 = False
        print("  [SKIP] ::1 (no IPv6 loopback here: " + String(e) + ")")
    if v6:
        udp_case(c, "::1", want)
        tcp_case(c, "::1", want)
    print("platform_transport: " + String(c.passed) + " passed, " + String(c.failed) + " failed")
    if c.failed:
        raise Error("platform_transport: " + String(c.failed) + " checks failed")
