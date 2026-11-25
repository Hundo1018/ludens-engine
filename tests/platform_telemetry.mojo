"""Telemetry and crash reports (platform/telemetry.mojo, platform/crash_report.mojo, issue #147): opt-in and withdrawal,
the bounded queue (the newest event dropped and counted), batches over a MemoryTransport (split by the transport's
max_message, kept on a refused send), the consent record, a crash report saved to a CloudSave slot and sent on the next
launch, and what happens without consent or with a damaged file. Writes build/telemetry_sample.batch and
build/telemetry_sample.crash for scripts/telemetry_read.py. Standard library only: `pixi run -e wasm test-telemetry`."""
from platform.cloud_save import CloudSave, MemoryCloudSave
from platform.crash_report import (
    CRASH_SLOT,
    CrashFrame,
    CrashReporter,
    CrashUpload,
    MAX_LOG_LINE,
    UP_CORRUPT,
    UP_DISCARDED,
    UP_NONE,
    UP_SENT,
    UP_SEND_FAILED,
    UP_WAITING,
    decode_crash,
    encode_crash,
    save_crash,
)
from platform.packets import KIND_SAVE_READ, PACKET_HEADER, STATUS_OK
from platform.save_store import FNV_BASIS, fnv1a64, get_uint
from platform.telemetry import (
    CONSENT_GRANTED,
    CONSENT_UNSET,
    CONSENT_WITHDRAWN,
    EV_DEATH,
    EV_GAME_FIRST,
    EV_LEVEL_START,
    NET_FULL_LATER,
    TEL_DROPPED,
    TEL_INVALID,
    TEL_MAGIC,
    TEL_NO_CONSENT,
    TEL_QUEUED,
    Telemetry,
    install_id_from,
    install_id_text,
)
from platform.transport import NET_NONE, NET_NO_PEER, NET_OK, Transport, poll_bytes
from platform.transport_memory import MemoryPipe, MemoryTransport


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


def write_file(path: String, data: List[UInt8]) raises:
    with open(path, "w") as f:
        f.write_bytes(Span(data))


def received(mut t: MemoryTransport) -> List[List[UInt8]]:
    var out = List[List[UInt8]]()
    var buf = List[UInt8](length=1 << 20, fill=0)
    while True:
        var n = poll_bytes(t, buf)
        if n <= 0:
            break
        var m = List[UInt8](capacity=n)
        for i in range(n):
            m.append(buf[i])
        out.append(m^)
    return out^


def batch_events(b: List[UInt8]) -> Int:
    """The event count of a batch (its offset depends on the build id and tag lengths)."""
    var at = 4 + 2 + 2 + 16 + 8 + 4 + 4
    var bl = Int(b[at])
    at += 1 + bl
    var tags = Int(b[at])
    at += 1 + 8 * tags
    return Int(get_uint(b, at, 4))


def batch_valid(b: List[UInt8]) -> Bool:
    return len(b) > 8 and get_uint(b, 0, 4) == UInt64(TEL_MAGIC) and fnv1a64(b, 0, len(b) - 8, FNV_BASIS) == get_uint(b, len(b) - 8, 8)


def test_consent(mut c: Check):
    var id = install_id_from(0x0123456789ABCDEF, 0xFEDCBA9876543210)
    c.check(install_id_text(id) == "efcdab89-6745-4301-9032-547698badcfe", "install id as a UUID, version 4 and variant bits set: " + install_id_text(id))
    var tel = Telemetry("ludens-engine 61aeac2", 7)
    c.check(tel.state() == CONSENT_UNSET and tel.record(EV_LEVEL_START, 0, 0, 1) == TEL_NO_CONSENT and tel.pending() == 0,
            "not asked yet: an event is refused and nothing is queued")
    c.check(not tel.grant(List[UInt8](length=16, fill=0)) and not tel.grant(List[UInt8](length=15, fill=1)), "an all-zero or 15-byte id is not a grant")
    c.check(tel.grant(id) and tel.state() == CONSENT_GRANTED, "grant with a 16-byte id")
    c.check(tel.level_start(10, 160, 3) == TEL_QUEUED and tel.pending() == 1, "after the grant an event is queued")
    c.check(tel.record(0, 0, 0, 0) == TEL_INVALID and tel.record(70000, 0, 0, 0) == TEL_INVALID, "kind 0 and kind 70000 are TEL_INVALID")
    c.check(tel.record(EV_GAME_FIRST, 0, 0, 0, [1, 2, 3, 4, 5, 6, 7]) == TEL_INVALID, "7 values are TEL_INVALID (at most 6)")
    var rec = tel.encode_consent()
    tel.withdraw()
    var zero = True
    for b in tel.install_id():
        zero = zero and b == 0
    c.check(tel.state() == CONSENT_WITHDRAWN and tel.pending() == 0 and zero, "withdraw: the queue is empty and the install id all zero")
    c.check(tel.death(11, 170, 3, 1, 0, 0, 0) == TEL_NO_CONSENT, "after withdrawing an event is refused")
    var again = Telemetry("ludens-engine 61aeac2", 8)
    c.check(again.apply_consent(rec) and again.granted() and install_id_text(again.install_id()) == install_id_text(id),
            "the consent record restores the grant and the same id on the next launch")
    var out = tel.encode_consent()
    c.check(again.apply_consent(out) and again.state() == CONSENT_WITHDRAWN, "a withdrawn record restores the withdrawal")
    var bad = rec.copy()
    bad[10] ^= 1
    var fresh = Telemetry("x", 9)
    c.check(not fresh.apply_consent(bad) and fresh.state() == CONSENT_UNSET, "a record with a flipped byte is refused; the state stays unset")


def test_queue_and_batches(mut c: Check) raises:
    var pipe = MemoryPipe(max_message=1000)
    var game = pipe.end(0)
    var collector = pipe.end(1)
    var tel = Telemetry("ludens-engine 61aeac2", 0x1122334455667788, capacity=100)
    _ = tel.grant(install_id_from(1, 2))
    _ = tel.set_tag(0xAB01, 2)  # experiment 0xAB01, bucket 2 (#149)
    var queued = 0
    for i in range(130):
        if tel.death(i, i * 16, 7, 2, i * 1000, 0, -i * 1000) == TEL_QUEUED:
            queued += 1
    c.check(queued == 100 and tel.pending() == 100 and tel.dropped() == 30, "130 events into a queue of 100: 100 queued, the newest 30 dropped and counted")
    c.check(tel.death(200, 0, 7, 0, 0, 0, 0) == TEL_DROPPED, "one more is TEL_DROPPED")
    var first = tel.encode_batch(1000)
    # header 47 + 21 (build id) + 8 (one tag) + checksum 8 = 84; an event with 4 values is 24 + 32 = 56: 16 fit in 1000
    c.check(first[1] == 16 and len(first[0]) <= 1000, "a 1000-byte message holds 16 death events: " + String(first[1]) + " in " + String(len(first[0])) + " bytes")
    var ok = tel.flush(game, max_batches=4)
    c.check(ok == NET_FULL_LATER and tel.sent_batches() == 4, "4 batches per flush call, events still pending: NET_FULL_LATER")
    var r = tel.flush(game, max_batches=100)
    c.check(r == NET_OK and tel.pending() == 0, "the next flush empties the queue")
    var msgs = received(collector)
    var total = 0
    var all_valid = True
    for m in msgs:
        total += batch_events(m)
        all_valid = all_valid and batch_valid(m) and len(m) <= 1000
    c.check(len(msgs) == 7 and total == 100 and all_valid, String(len(msgs)) + " batches of at most 1000 bytes, " + String(total) + " events, every checksum valid")
    c.check(Int(get_uint(msgs[0], 36, 4)) == 31 and Int(get_uint(msgs[1], 36, 4)) == 0, "the first batch header carries the 31 dropped events, the second 0")
    c.check(Int(get_uint(msgs[0], 32, 4)) == 0 and Int(get_uint(msgs[6], 32, 4)) == 6, "seq 0 .. 6")
    write_file("build/telemetry_sample.batch", msgs[0])
    # a refused send keeps the events
    _ = tel.level_start(500, 8000, 9)
    game.close()
    var refused = tel.flush(game)
    c.check(refused == NET_NO_PEER and tel.pending() == 1, "send refused (NET_NO_PEER): the event stays queued")


def test_crash(mut c: Check) raises:
    var id = install_id_from(3, 4)
    var rep = CrashReporter("ludens-engine 61aeac2", log_lines=4)
    rep.log("before the grant")
    c.check(rep.arm(1, 1) == 0 and len(rep.lines()) == 0, "no consent: nothing is kept and the context is empty")
    rep.set_install_id(id)
    for i in range(6):
        rep.log("line " + String(i))
    var long = String()
    for _ in range(MAX_LOG_LINE + 10):
        long += "x"
    rep.log(long)
    var ls = rep.lines()
    c.check(len(ls) == 4 and ls[0] == "line 3" and ls[3].byte_length() == MAX_LOG_LINE, "a ring of 4 lines keeps the newest 4, a long line cut to 512 bytes")
    var bb = List[UInt8]()
    for i in range(300):
        bb.append(UInt8(i & 0xFF))
    _ = rep.set_blackbox(bb)
    var n = rep.arm(1234, 20500)
    var frames = List[CrashFrame]()
    frames.append(CrashFrame(12, 0x3F2, 88, 5, "app/crash_probe.mojo", "crash_now"))
    frames.append(CrashFrame(40, 0x1100, 0, 0, "", ""))
    var report = encode_crash(rep.context(), "RuntimeError: unreachable", frames)
    var d = decode_crash(report)
    c.check(n == rep.context_len() and d.tick == 1234 and d.session_ms == 20500 and d.build_id == "ludens-engine 61aeac2", "decode: tick, time and build id")
    c.check(len(d.log) == 4 and d.log[1] == "line 4" and len(d.blackbox) == 300 and d.blackbox[299] == 43, "decode: 4 log lines and the 300-byte black box")
    c.check(len(d.frames) == 2 and d.frames[0].line == 88 and d.frames[0].file == "app/crash_probe.mojo" and d.frames[1].line == 0, "decode: a mapped and an unmapped frame")
    c.check(d.reason == "RuntimeError: unreachable" and install_id_text(d.install_id) == install_id_text(id), "decode: reason and install id")
    write_file("build/telemetry_sample.crash", report)
    var flipped = report.copy()
    flipped[40] ^= 0x10
    var raised = False
    try:
        _ = decode_crash(flipped)
    except:
        raised = True
    c.check(raised, "a flipped byte: decode raises (checksum)")

    # the next launch: saved, sent, cleared
    var save = MemoryCloudSave()
    _ = save_crash(save, 1, report)
    var pipe = MemoryPipe()
    var game = pipe.end(0)
    var collector = pipe.end(1)
    var up = CrashUpload()
    c.check(up.start(save, 5) == UP_WAITING, "upload: waiting for the read")
    var st = up.step(save, game, True)
    var got = received(collector)
    c.check(st == UP_SENT and len(got) == 1 and len(got[0]) == len(report), "consent: the report is sent whole (" + String(len(report)) + " bytes)")
    var up2 = CrashUpload()
    _ = up2.start(save, 6)
    c.check(up2.step(save, game, True) == UP_NONE, "after sending the slot is empty: the launch after that finds nothing")

    # no consent: deleted unsent
    _ = save_crash(save, 1, report)
    var up3 = CrashUpload()
    _ = up3.start(save, 7)
    c.check(up3.step(save, game, False) == UP_DISCARDED and len(received(collector)) == 0, "no consent: the report is deleted, nothing sent")
    var up4 = CrashUpload()
    _ = up4.start(save, 8)
    c.check(up4.step(save, game, True) == UP_NONE, "and it is gone")

    # damaged file: deleted, reason given
    _ = save_crash(save, 1, flipped)
    var up5 = CrashUpload()
    _ = up5.start(save, 9)
    c.check(up5.step(save, game, True) == UP_CORRUPT and up5.reason == "crash report: checksum mismatch", "a damaged file is UP_CORRUPT: " + up5.reason)

    # no peer: kept for the launch after
    _ = save_crash(save, 1, report)
    game.close()
    var up6 = CrashUpload()
    _ = up6.start(save, 10)
    c.check(up6.step(save, game, True) == UP_SEND_FAILED, "no peer: UP_SEND_FAILED")
    var pipe2 = MemoryPipe()
    var game2 = pipe2.end(0)
    var col2 = pipe2.end(1)
    var up7 = CrashUpload()
    _ = up7.start(save, 11)
    c.check(up7.step(save, game2, True) == UP_SENT and len(received(col2)) == 1, "the report was kept and goes out on the next launch")

    rep.clear()
    c.check(not rep.enabled() and rep.arm(5, 5) == 0 and len(rep.lines()) == 0, "clear (withdrawal): lines, black box and context gone")


def main() raises:
    var c = Check()
    print("telemetry: consent")
    test_consent(c)
    print("telemetry: queue and batches")
    test_queue_and_batches(c)
    print("crash reports")
    test_crash(c)
    print("platform_telemetry: " + String(c.passed) + " passed, " + String(c.failed) + " failed")
    if c.failed:
        raise Error("platform_telemetry failed")
