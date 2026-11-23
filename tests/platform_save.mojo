"""Save games (platform/save_store.mojo, issue #122) over an in-memory CloudSave that can cut a write short or flip a stored
byte: round trip, slots / autosave / profile, version migration (a save written at version 1 loads at version 2, a newer
one is refused), an interrupted write leaves the previous save loadable, corruption (flipped byte, truncation, bad
magic, extension) is reported and the backup offered. Standard library only: `pixi run -e wasm test-transport`."""
from std.os import remove
from std.os.path import exists
from platform.cloud_save import CloudSave, MemoryCloudSave
from platform.file_cloud_save import FileCloudSave, valid_path
from platform.packets import KIND_SAVE_READ, PACKET_HEADER, STATUS_OK
from platform.save_store import (
    AUTOSAVE_SLOT,
    HEADER_BYTES,
    Migrator,
    SAVE_BACKUP_OFFERED,
    SAVE_CORRUPT,
    SAVE_NEEDS_MIGRATION,
    SAVE_NEWER,
    SAVE_NOT_FOUND,
    SAVE_OK,
    SaveEvent,
    SaveStore,
    decode_save,
    encode_save,
    migrate_payload,
)


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


struct FaultyCloudSave(CloudSave):
    """MemoryCloudSave that keeps only the first `cut` bytes of the next write when `cut` >= 0 (a write interrupted part way;
    the write is still acknowledged, the way a crash after the data reached storage but before it was whole looks)."""

    var inner: MemoryCloudSave
    var cut: Int
    var writes: Int

    def __init__(out self):
        self.inner = MemoryCloudSave()
        self.cut = -1
        self.writes = 0

    def write_request(mut self, id: Int, slot: String, ptr: UInt64, length: Int) -> Int:
        self.writes += 1
        var n = length
        if self.cut >= 0 and self.cut < length:
            n = self.cut
        self.cut = -1
        return self.inner.write_request(id, slot, ptr, n)

    def read_request(mut self, id: Int, slot: String) -> Int:
        return self.inner.read_request(id, slot)

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        return self.inner.poll(buf, cap)

    def dropped(self) -> Int:
        return self.inner.dropped()


def bytes_of(values: List[Int]) -> List[UInt8]:
    var out = List[UInt8]()
    for v in values:
        out.append(UInt8(v & 0xFF))
    return out^


def read_file(mut store: SaveStore[FaultyCloudSave], path: String) -> List[UInt8]:
    """The bytes stored under `path`, read straight from the backend."""
    var buf = List[UInt8](length=PACKET_HEADER + 4096, fill=0)
    _ = store.cloud.read_request(900000, path)
    var n = store.cloud.poll(UInt64(Int(buf.unsafe_ptr())), len(buf))
    var out = List[UInt8]()
    if n > PACKET_HEADER and Int(buf[5]) == STATUS_OK:
        for i in range(PACKET_HEADER, n):
            out.append(buf[i])
    return out^


def put_file(mut store: SaveStore[FaultyCloudSave], path: String, data: List[UInt8]):
    _ = store.cloud.write_request(900001, path, UInt64(Int(data.unsafe_ptr())), len(data))
    _ = len(data)
    var buf = List[UInt8](length=64, fill=0)
    _ = store.cloud.poll(UInt64(Int(buf.unsafe_ptr())), 64)
    _ = buf[0]  # keep the buffer alive until the poll has written into it


def one(var events: List[SaveEvent]) -> SaveEvent:
    """The only event of a poll; a poll that did not return exactly one gives a SAVE_CORRUPT event with message `no event`."""
    if len(events) != 1:
        var e = SaveEvent(-1, True, String(""), SAVE_CORRUPT)
        e.message = String("no event: ") + String(len(events))
        return e^
    return events[0].copy()


def load(mut store: SaveStore[FaultyCloudSave], slot: String, current: Int) -> SaveEvent:
    _ = store.begin_load(slot, current)
    return one(store.poll())


def save(mut store: SaveStore[FaultyCloudSave], slot: String, version: Int, payload: List[UInt8]) -> SaveEvent:
    _ = store.save(slot, version, payload)
    return one(store.poll())


def same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


struct ScoreMigrator(Migrator):
    """Version 1 payload: [score]. Version 2: [score, lives = 3]. Version 3: [score, lives, 7]."""

    def __init__(out self):
        pass

    def can_migrate(self, from_version: Int) -> Bool:
        return from_version == 1 or from_version == 2

    def migrate(self, from_version: Int, payload: List[UInt8]) raises -> List[UInt8]:
        var out = payload.copy()
        if from_version == 1:
            out.append(3)
        else:
            out.append(7)
        return out^


struct GapMigrator(Migrator):
    """Only the 2 -> 3 step is registered."""

    def __init__(out self):
        pass

    def can_migrate(self, from_version: Int) -> Bool:
        return from_version == 2

    def migrate(self, from_version: Int, payload: List[UInt8]) raises -> List[UInt8]:
        return payload.copy()


def main() raises:
    var c = Check()
    var store = SaveStore[FaultyCloudSave](FaultyCloudSave())
    var p1 = bytes_of([10, 20, 30])

    # A save must follow a load of the slot
    c.check(store.save("a", 1, p1) == -1 and store.last_error.byte_length() > 0, "save before load is refused, with a message")
    c.check(store.begin_load("../x", 1) == -1 and store.begin_load("", 1) == -1 and store.begin_load("a b", 1) == -1, "slot names outside 1-32 of A-Z a-z 0-9 - _ are refused")
    var e = load(store, "a", 1)
    c.check(e.status == SAVE_NOT_FOUND and not e.usable(), "load of a slot never written: SAVE_NOT_FOUND")

    # Round trip, generations and file alternation
    e = save(store, "a", 1, p1)
    c.check(e.status == SAVE_OK and not e.is_load and e.generation == 1, "first save: ok, generation 1")
    var f0 = read_file(store, "run/a.0")
    var f1 = read_file(store, "run/a.1")
    c.check(len(f0) == HEADER_BYTES + 3 and len(f1) == 0, "generation 1 is in run/a.0, run/a.1 does not exist yet")
    e = save(store, "a", 1, bytes_of([11, 21, 31]))
    c.check(e.generation == 2 and len(read_file(store, "run/a.1")) == HEADER_BYTES + 3, "generation 2 goes to run/a.1")
    e = load(store, "a", 1)
    c.check(e.status == SAVE_OK and e.generation == 2 and same(e.payload, bytes_of([11, 21, 31])), "load returns the newest generation (2)")
    e = save(store, "a", 1, bytes_of([12, 22, 32]))
    c.check(e.generation == 3 and decode_save(read_file(store, "run/a.0")).generation == 3, "generation 3 replaces generation 1 in run/a.0")
    c.check(decode_save(read_file(store, "run/a.1")).generation == 2, "generation 2 in run/a.1 is the backup and is untouched")

    # A new store (a new session) sees the same slot after a load
    var store2 = SaveStore[FaultyCloudSave](FaultyCloudSave())
    c.check(store2.save("a", 1, p1) == -1, "a fresh store cannot save a slot it has not loaded")

    # Slots, autosave and profile do not touch each other
    e = load(store, "b", 1)
    e = save(store, "b", 1, bytes_of([1]))
    c.check(e.status == SAVE_OK, "slot b saves")
    _ = store.begin_load(AUTOSAVE_SLOT, 1)
    _ = store.poll()
    _ = store.autosave(1, bytes_of([9, 9]))
    var ea = one(store.poll())
    c.check(ea.status == SAVE_OK and ea.key == "run/auto", "autosave writes run/auto")
    _ = store.begin_load_profile(1)
    _ = store.poll()
    _ = store.save_profile(1, bytes_of([5, 5, 5, 5]))
    var ep = one(store.poll())
    c.check(ep.status == SAVE_OK and ep.key == "profile", "the profile is its own slot, `profile`")
    e = load(store, "a", 1)
    c.check(same(e.payload, bytes_of([12, 22, 32])), "slot a still holds its own payload")
    _ = store.begin_load_profile(1)
    var pl = one(store.poll())
    c.check(same(pl.payload, bytes_of([5, 5, 5, 5])), "the profile loads its own payload")
    put_file(store, "run/b.0", bytes_of([0, 1, 2]))
    put_file(store, "run/b.1", bytes_of([0, 1, 2]))
    pl = load(store, "b", 1)
    _ = store.begin_load_profile(1)
    pl = one(store.poll())
    c.check(pl.status == SAVE_OK and same(pl.payload, bytes_of([5, 5, 5, 5])), "destroying run slot b leaves the profile loadable")

    # Versions: save at 1, build is at 2
    var s = SaveStore[FaultyCloudSave](FaultyCloudSave())
    _ = load(s, "v", 1)
    _ = save(s, "v", 1, bytes_of([42]))
    e = load(s, "v", 2)
    c.check(e.status == SAVE_NEEDS_MIGRATION and e.version == 1 and e.usable(), "a version 1 save loaded by a version 2 build: SAVE_NEEDS_MIGRATION")
    var m = migrate_payload(ScoreMigrator(), e.payload, e.version, 2)
    c.check(same(m, bytes_of([42, 3])), "the registered 1 -> 2 step adds lives = 3: [42] becomes [42, 3]")
    var m3 = migrate_payload(ScoreMigrator(), e.payload, e.version, 3)
    c.check(same(m3, bytes_of([42, 3, 7])), "two steps run in order: 1 -> 2 then 2 -> 3")
    var gap_raised = False
    try:
        _ = migrate_payload(GapMigrator(), e.payload, 1, 3)
    except err:
        gap_raised = "no migration from version 1 to 2" in String(err)
    c.check(gap_raised, "a missing step raises, naming the version (`no migration from version 1 to 2`)")
    e = save(s, "v", 2, m)
    c.check(e.status == SAVE_OK, "the migrated payload saves as version 2")
    e = load(s, "v", 2)
    c.check(e.status == SAVE_OK and e.version == 2 and same(e.payload, bytes_of([42, 3])), "and loads at version 2 with no migration")

    # A save from a newer build
    var n = SaveStore[FaultyCloudSave](FaultyCloudSave())
    _ = load(n, "n", 5)
    _ = save(n, "n", 5, bytes_of([1, 2, 3]))
    e = load(n, "n", 4)
    c.check(e.status == SAVE_NEWER and not e.usable() and "newer than this build" in e.message and len(e.payload) == 0,
            "a version 5 save loaded by a version 4 build is refused: " + e.message)
    c.check(n.save("n", 4, bytes_of([9])) == -1, "after the refusal this build cannot overwrite that slot")
    var before = read_file(n, "run/n.0")
    c.check(len(before) == HEADER_BYTES + 3, "the newer build's file is intact")
    var fmt = read_file(n, "run/n.0")
    fmt[4] = 9  # container format 9
    put_file(n, "run/n.0", fmt)
    e = load(n, "n", 5)
    c.check(e.status == SAVE_NEWER and "file format 9" in e.message, "a file format newer than SAVE_FORMAT is refused: " + e.message)

    # An interrupted write keeps the previous save
    var w = SaveStore[FaultyCloudSave](FaultyCloudSave())
    _ = load(w, "w", 1)
    _ = save(w, "w", 1, bytes_of([1, 1, 1, 1]))  # generation 1 -> w.0
    _ = save(w, "w", 1, bytes_of([2, 2, 2, 2]))  # generation 2 -> w.1
    w.cloud.cut = 17  # the next write keeps 17 of its 34 bytes
    _ = save(w, "w", 1, bytes_of([3, 3, 3, 3]))  # generation 3 -> w.0, cut
    c.check(len(read_file(w, "run/w.0")) == 17, "the interrupted write left 17 bytes in run/w.0")
    e = load(w, "w", 1)
    c.check(e.status == SAVE_BACKUP_OFFERED and e.generation == 2 and same(e.payload, bytes_of([2, 2, 2, 2])), "after the interruption the previous save (generation 2) is offered")
    c.check("run/w.0: truncated" in e.message and "offered" in e.message, "the message names the file and the fault: " + e.message)
    e = save(w, "w", 1, bytes_of([4, 4, 4, 4]))
    c.check(e.status == SAVE_OK and e.generation == 3, "the next save overwrites the damaged file, as generation 3")
    e = load(w, "w", 1)
    c.check(e.status == SAVE_OK and e.generation == 3 and same(e.payload, bytes_of([4, 4, 4, 4])), "and the slot is clean again")
    # Interrupt at every possible length: the previous generation is always recoverable
    var all_cut_ok = True
    var cut_cases = 0
    for keep in range(0, HEADER_BYTES + 4):
        var t = SaveStore[FaultyCloudSave](FaultyCloudSave())
        _ = load(t, "t", 1)
        _ = save(t, "t", 1, bytes_of([7, 7, 7, 7]))
        _ = save(t, "t", 1, bytes_of([8, 8, 8, 8]))
        t.cloud.cut = keep
        _ = save(t, "t", 1, bytes_of([9, 9, 9, 9]))
        var r = load(t, "t", 1)
        cut_cases += 1
        if not (r.status == SAVE_BACKUP_OFFERED and same(r.payload, bytes_of([8, 8, 8, 8]))):
            all_cut_ok = False
    c.check(all_cut_ok and cut_cases == HEADER_BYTES + 4, "a write cut at each of 0 .. 33 bytes: generation 2 is always the one offered (" + String(cut_cases) + " cases)")

    # Corruption: flipped byte, truncation, bad magic, extension
    var k = SaveStore[FaultyCloudSave](FaultyCloudSave())
    _ = load(k, "k", 1)
    _ = save(k, "k", 1, bytes_of([5, 6, 7, 8]))
    _ = save(k, "k", 1, bytes_of([15, 16, 17, 18]))  # gen 2 in k.1, gen 1 in k.0
    var good = read_file(k, "run/k.1")
    var flipped = good.copy()
    flipped[HEADER_BYTES + 1] ^= 0x40
    put_file(k, "run/k.1", flipped)
    e = load(k, "k", 1)
    c.check(e.status == SAVE_BACKUP_OFFERED and "checksum mismatch" in e.message and same(e.payload, bytes_of([5, 6, 7, 8])), "a flipped payload bit: checksum mismatch, generation 1 offered: " + e.message)
    var hdr = good.copy()
    hdr[10] ^= 0x01  # the generation field
    put_file(k, "run/k.1", hdr)
    e = load(k, "k", 1)
    c.check(e.status == SAVE_BACKUP_OFFERED and "checksum mismatch" in e.message, "a flipped header bit (the generation) is caught by the checksum too")
    var magic = good.copy()
    magic[0] = 0
    put_file(k, "run/k.1", magic)
    e = load(k, "k", 1)
    c.check(e.status == SAVE_BACKUP_OFFERED and "bad magic" in e.message, "bad magic: " + e.message)
    var ext = good.copy()
    ext.append(0)
    put_file(k, "run/k.1", ext)
    e = load(k, "k", 1)
    c.check(e.status == SAVE_BACKUP_OFFERED and "extended" in e.message, "one extra byte at the end: " + e.message)
    var short = List[UInt8]()
    for i in range(10):
        short.append(good[i])
    put_file(k, "run/k.1", short)
    e = load(k, "k", 1)
    c.check(e.status == SAVE_BACKUP_OFFERED and "header alone" in e.message, "shorter than the header: " + e.message)
    put_file(k, "run/k.1", List[UInt8]())
    e = load(k, "k", 1)
    c.check(e.status == SAVE_BACKUP_OFFERED, "a zero-length file is corrupt, not absent")
    # both copies bad
    put_file(k, "run/k.0", magic)
    e = load(k, "k", 1)
    c.check(e.status == SAVE_CORRUPT and not e.usable() and "no valid backup" in e.message, "both copies bad: SAVE_CORRUPT, no payload: " + e.message)
    e = save(k, "k", 1, bytes_of([99]))
    c.check(e.status == SAVE_OK, "a slot with no valid copy can be written again")
    e = load(k, "k", 1)
    c.check(e.status == SAVE_OK and same(e.payload, bytes_of([99])), "and then loads with no backup prompt: the save rewrote both files")

    # A one-file slot with the other absent and the one present corrupt: no backup
    var one_file = SaveStore[FaultyCloudSave](FaultyCloudSave())
    _ = load(one_file, "o", 1)
    _ = save(one_file, "o", 1, bytes_of([1, 2]))
    var bad = read_file(one_file, "run/o.0")
    bad[HEADER_BYTES] ^= 1
    put_file(one_file, "run/o.0", bad)
    e = load(one_file, "o", 1)
    c.check(e.status == SAVE_CORRUPT and "run/o.0" in e.message, "the only copy corrupt: SAVE_CORRUPT: " + e.message)

    # Size limit and the encoder
    var small = SaveStore[FaultyCloudSave](FaultyCloudSave(), 8)
    _ = load(small, "s", 1)
    c.check(small.save("s", 1, List[UInt8](length=9, fill=1)) == -1 and "over the limit" in small.last_error, "a payload over max_payload is refused: " + small.last_error)
    c.check(small.save("s", 0, bytes_of([1])) == -1, "version 0 is refused (versions start at 1)")
    var enc = encode_save(3, 7, bytes_of([1, 2]))
    var dec = decode_save(enc)
    c.check(len(enc) == HEADER_BYTES + 2 and dec.version == 3 and dec.generation == 7 and same(dec.payload, bytes_of([1, 2])), "encode / decode round trip: version 3, generation 7, 30 + 2 bytes")

    # The same store over real files (the native backend)
    var root = String("build/save_test_files")
    for i in range(2):
        var stale = root + "/run/disk." + String(i)
        if exists(stale):
            remove(stale)  # a run starts with no files
    var fs = SaveStore[FileCloudSave](FileCloudSave(root))
    _ = fs.begin_load("disk", 1)
    var fe = one(fs.poll())
    c.check(fe.status == SAVE_NOT_FOUND, "files: a slot with no files is SAVE_NOT_FOUND")
    _ = fs.save("disk", 1, bytes_of([1, 2, 3, 4, 5]))
    _ = fs.save("disk", 1, bytes_of([6, 7, 8, 9, 10]))
    var fw = fs.poll()
    c.check(len(fw) == 2 and fw[0].status == SAVE_OK and fw[1].status == SAVE_OK and fw[1].generation == 2, "files: two saves are acknowledged (generations 1 and 2)")
    fs.forget()
    _ = fs.begin_load("disk", 1)
    fe = one(fs.poll())
    c.check(fe.status == SAVE_OK and fe.generation == 2 and same(fe.payload, bytes_of([6, 7, 8, 9, 10])), "files: a load after forget() reads generation 2 from disk")
    var raw = decode_save(List[UInt8]())
    c.check(raw.state != 1, "files: an empty buffer does not decode")
    c.check(valid_path("run/a.0") and valid_path("profile.1") and not valid_path("../x") and not valid_path("a//b") and not valid_path("/a") and not valid_path("a/") and not valid_path("a/./b") and not valid_path("a:b") and not valid_path(""),
            "files: path rules match shell/web/os_host.mjs validPath")

    print("platform_save: " + String(c.passed) + " passed, " + String(c.failed) + " failed")
    if c.failed > 0:
        raise Error("platform_save failed")
