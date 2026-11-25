"""The ludens-core `diag/outbox` drained into the telemetry queue (app/telemetry_outbox.mojo, #147), then sent as one batch over
a MemoryTransport: every record arrives as an event with its kind, tick, key and [a, b]; kinds that are not event kinds
are skipped and counted; a rollback's re-simulated tick is not sent twice (the outbox refuses it). Needs the engine:
`pixi run -e wasm test-telemetry`."""
from diag.outbox import Outbox
from platform.save_store import get_uint
from platform.telemetry import Telemetry, install_id_from
from platform.transport import NET_OK, poll_bytes
from platform.transport_memory import MemoryPipe
from telemetry_outbox import OutboxForward


def main() raises:
    var passed = 0
    var failed = 0

    var box = Outbox(8)
    var tel = Telemetry("outbox-test", 1)
    _ = tel.grant(install_id_from(5, 6))
    var fw = OutboxForward()
    for t in range(10):
        _ = box.push(300, t, 42, t * 2, -t)
    _ = box.push(0, 3, 0)  # an 11th record: the outbox is full, so it is dropped there
    var n = fw.forward(box, tel, 1000)
    var results = List[Bool]()
    var labels = List[String]()
    results.append(n == 8 and fw.outbox_dropped == 3 and tel.pending() == 8)
    labels.append("an outbox of 8 takes 8 of 11 records (3 dropped by the outbox and carried over): 8 events queued, got " + String(n))
    _ = box.push(300, 5, 42)  # a rollback re-simulating tick 5: the outbox refuses a delivered tick
    _ = box.push(0, 12, 0)
    _ = box.push(300, 12, 43, 7, 8)
    var n2 = fw.forward(box, tel, 2000)
    results.append(n2 == 1 and fw.skipped == 1)
    labels.append("the re-simulated tick 5 is not delivered again; kind 0 is skipped and counted; tick 12 queued")
    var pipe = MemoryPipe()
    var a = pipe.end(0)
    var b = pipe.end(1)
    results.append(tel.flush(a) == NET_OK)
    labels.append("flush")
    var buf = List[UInt8](length=4096, fill=0)
    var got = poll_bytes(b, buf)
    # header: 4+2+2+16+8+4+4 = 40, build id len 1 + 11, tag count 1, event count 4 at 53
    var count = Int(get_uint(buf, 53, 4))
    var first_kind = Int(get_uint(buf, 57, 2))
    var first_values = Int(get_uint(buf, 57 + 24, 8))
    results.append(got > 0 and count == 9 and first_kind == 300 and first_values == 0)
    labels.append("one batch of 9 events; the first is kind 300 with a = 0")
    for i in range(len(results)):
        if results[i]:
            passed += 1
        else:
            failed += 1
        print("  [" + ("PASS" if results[i] else "FAIL") + "] " + labels[i])
    print("outbox_forward: " + String(passed) + " passed, " + String(failed) + " failed")
    if failed:
        raise Error("outbox_forward failed")
