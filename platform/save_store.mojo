"""Save games over the CloudSave seam (docs/save-games.md, issue #122): slots, an autosave slot, a profile kept apart from
the run saves, a version per save with a stepwise migration chain, a checksum, and a write that never leaves a slot
without a loadable file.

File format (all integers little-endian), HEADER_BYTES = 30 bytes and then the payload:

    magic u32 "LSVE" | format u16 | version u32 | generation u64 | payload_length u32 | checksum u64 | payload

`format` is this container's layout (SAVE_FORMAT = 1). Every format version keeps the magic, `format`, payload length and
checksum at these offsets, with the same checksum coverage, so an older build can verify a newer file before it reads `format`. `version` is the game's own payload version, 1 or more.
`generation` counts the writes to the slot. `checksum` is FNV-1a 64 over the first 22 header bytes and the payload.

A slot is two files, `<key>.0` and `<key>.1`. os_file_* has write and read but no rename, so a write goes to the file that
does NOT hold the newest generation and the older generation stays untouched until the next write: if the write is cut
off, the other file is still complete. A load reads both files and takes the valid one with the higher generation.

Rules a load follows:
  - version greater than the build's: refused (SAVE_NEWER, with a message). `format` is read only after the checksum passes. The slot is not marked writable, so this build
    cannot overwrite a newer build's save. The same for a `format` greater than SAVE_FORMAT.
  - version smaller than the build's: SAVE_NEEDS_MIGRATION. `migrate_payload` applies one registered step per version.
  - bad magic, a length that is not header + payload_length (truncated or extended) or a checksum mismatch: the file is
    corrupt. If the other file is valid the result is SAVE_BACKUP_OFFERED: the payload is the other file's, the message
    says what was wrong, and the caller decides whether to use it. If no file is valid it is SAVE_CORRUPT.
  - neither file exists: SAVE_NOT_FOUND.

A slot must be loaded (`begin_load`) before it is saved, so the store knows which file is free. Standard library only."""
from platform.cloud_save import CloudSave
from platform.packets import KIND_SAVE_READ, KIND_SAVE_WRITE, PACKET_HEADER, REQ_QUEUED, STATUS_NOT_FOUND, STATUS_OK, text_bytes

comptime SAVE_MAGIC = 0x4556534C  # "LSVE" read as bytes 4C 53 56 45
comptime SAVE_FORMAT: Int = 1
comptime HEADER_BYTES: Int = 30
comptime CHECKED_HEADER: Int = 22

comptime SAVE_OK: Int = 0
comptime SAVE_NOT_FOUND: Int = 1
comptime SAVE_NEWER: Int = 2
comptime SAVE_CORRUPT: Int = 3
comptime SAVE_BACKUP_OFFERED: Int = 4
comptime SAVE_NEEDS_MIGRATION: Int = 5
comptime SAVE_WRITE_FAILED: Int = 6
comptime SAVE_REFUSED: Int = 7
"""A save request that was not made: the slot was not loaded first, or the name or size is invalid (the message says which)."""

comptime AUTOSAVE_SLOT = "auto"
comptime MAX_SLOT_NAME: Int = 32
comptime DEFAULT_MAX_PAYLOAD: Int = 4 * 1024 * 1024


def fnv1a64(data: List[UInt8], start: Int, end: Int, seed: UInt64) -> UInt64:
    var h = seed
    for i in range(start, end):
        h = (h ^ UInt64(data[i])) * UInt64(0x100000001B3)
    return h


comptime FNV_BASIS = UInt64(0xCBF29CE484222325)


def put_uint(mut out: List[UInt8], v: UInt64, bytes: Int):
    for k in range(bytes):
        out.append(UInt8((v >> UInt64(8 * k)) & 0xFF))


def get_uint(data: List[UInt8], pos: Int, bytes: Int) -> UInt64:
    var v = UInt64(0)
    for k in range(bytes):
        v |= UInt64(data[pos + k]) << UInt64(8 * k)
    return v


def encode_save(version: Int, generation: Int, payload: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8](capacity=HEADER_BYTES + len(payload))
    put_uint(out, UInt64(SAVE_MAGIC), 4)
    put_uint(out, UInt64(SAVE_FORMAT), 2)
    put_uint(out, UInt64(version), 4)
    put_uint(out, UInt64(generation), 8)
    put_uint(out, UInt64(len(payload)), 4)
    var h = fnv1a64(out, 0, CHECKED_HEADER, FNV_BASIS)
    h = fnv1a64(payload, 0, len(payload), h)
    put_uint(out, h, 8)
    out.extend(payload.copy())
    return out^


comptime FILE_ABSENT: Int = 0
comptime FILE_VALID: Int = 1
comptime FILE_CORRUPT: Int = 2
comptime FILE_FORMAT_NEWER: Int = 3


struct DecodedFile(Copyable, Movable):
    var state: Int
    var reason: String
    var version: Int
    var generation: Int
    var payload: List[UInt8]

    def __init__(out self, state: Int, reason: String = String()):
        self.state = state
        self.reason = reason
        self.version = 0
        self.generation = 0
        self.payload = List[UInt8]()


def decode_save(data: List[UInt8]) -> DecodedFile:
    """Check one file. FILE_VALID has version, generation and payload set; FILE_CORRUPT and FILE_FORMAT_NEWER have a reason."""
    if len(data) < HEADER_BYTES:
        return DecodedFile(FILE_CORRUPT, String("truncated: ") + String(len(data)) + String(" bytes, the header alone is ") + String(HEADER_BYTES))
    if get_uint(data, 0, 4) != UInt64(SAVE_MAGIC):
        return DecodedFile(FILE_CORRUPT, String("not a save file (bad magic)"))
    var n = Int(get_uint(data, 18, 4))
    if len(data) != HEADER_BYTES + n:
        return DecodedFile(FILE_CORRUPT, String("truncated or extended: the header says ") + String(n) + String(" payload bytes, the file has ") + String(len(data) - HEADER_BYTES))
    var h = fnv1a64(data, 0, CHECKED_HEADER, FNV_BASIS)
    h = fnv1a64(data, HEADER_BYTES, len(data), h)
    if h != get_uint(data, CHECKED_HEADER, 8):
        return DecodedFile(FILE_CORRUPT, String("checksum mismatch"))
    # `format` is trusted only after the checksum has passed, so one damaged byte there is corruption, not a newer build's file
    var fmt = Int(get_uint(data, 4, 2))
    if fmt > SAVE_FORMAT:
        return DecodedFile(FILE_FORMAT_NEWER, String("file format ") + String(fmt) + String(" is newer than this build reads (") + String(SAVE_FORMAT) + String(")"))
    var d = DecodedFile(FILE_VALID)
    d.version = Int(get_uint(data, 6, 4))
    d.generation = Int(get_uint(data, 10, 8))
    for i in range(HEADER_BYTES, len(data)):
        d.payload.append(data[i])
    return d^


trait Migrator:
    """The game's migration chain: one step per version, `migrate(v, payload)` turns a version-v payload into version v + 1."""

    def can_migrate(self, from_version: Int) -> Bool:
        ...

    def migrate(self, from_version: Int, payload: List[UInt8]) raises -> List[UInt8]:
        ...


def migrate_payload[M: Migrator](m: M, payload: List[UInt8], from_version: Int, to_version: Int) raises -> List[UInt8]:
    """Apply the steps from_version, from_version + 1, ... to_version - 1. A missing step raises with its version."""
    var data = payload.copy()
    var v = from_version
    while v < to_version:
        if not m.can_migrate(v):
            raise Error("save: no migration from version " + String(v) + " to " + String(v + 1))
        data = m.migrate(v, data)
        v += 1
    return data^


struct SaveEvent(Copyable, Movable):
    var op: Int
    var is_load: Bool
    var key: String
    var status: Int
    var message: String
    var version: Int  # of the payload, as stored (a load)
    var generation: Int
    var needs_migration: Bool  # the payload's version is older than the build's, whatever the status (a backup can be older too)
    var payload: List[UInt8]

    def __init__(out self, op: Int, is_load: Bool, key: String, status: Int):
        self.op = op
        self.is_load = is_load
        self.key = key
        self.status = status
        self.message = String()
        self.version = 0
        self.generation = 0
        self.needs_migration = False
        self.payload = List[UInt8]()

    def usable(self) -> Bool:
        """True when `payload` holds a save the caller may use (after migrating it if status is SAVE_NEEDS_MIGRATION). A
        SAVE_BACKUP_OFFERED payload is usable only if the caller accepts the backup."""
        return self.status == SAVE_OK or self.status == SAVE_NEEDS_MIGRATION or self.status == SAVE_BACKUP_OFFERED


struct _Slot(Copyable, Movable):
    var key: String
    var known: Bool
    var generation: Int  # of the newest valid file
    var target: Int  # the file the next write goes to (0 or 1)
    var repair_both: Bool  # no valid file was found: the next write goes to both files, so no corrupt file is left behind

    def __init__(out self, key: String):
        self.key = key
        self.known = False
        self.generation = 0
        self.target = 0
        self.repair_both = False


struct _Op(Copyable, Movable):
    var id: Int
    var key: String
    var is_load: Bool
    var current_version: Int
    var got: List[Bool]  # per file
    var status: List[Int]  # STATUS_* of each read result
    var data: List[List[UInt8]]
    var write_version: Int
    var write_generation: Int
    var write_target: Int
    var writes_left: Int
    var write_failed: Bool

    def __init__(out self, id: Int, key: String, is_load: Bool):
        self.id = id
        self.key = key
        self.is_load = is_load
        self.current_version = 0
        self.got = List[Bool](length=2, fill=False)
        self.status = List[Int](length=2, fill=0)
        self.data = List[List[UInt8]]()
        self.data.append(List[UInt8]())
        self.data.append(List[UInt8]())
        self.write_version = 0
        self.write_generation = 0
        self.write_target = 0
        self.writes_left = 1
        self.write_failed = False


def valid_slot_name(name: String) -> Bool:
    var n = name.byte_length()
    if n == 0 or n > MAX_SLOT_NAME:
        return False
    for b in name.as_bytes():
        var c = Int(b)
        var ok = (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 45 or c == 95
        if not ok:
            return False
    return True


struct SaveStore[C: CloudSave & Deinitable](Movable):
    """Run slots (`save` / `begin_load`), the autosave slot (AUTOSAVE_SLOT) and one profile, over any CloudSave. Every call
    that touches storage returns an op number at once (negative: refused, see `last_error`); `poll` returns the finished
    ones as SaveEvents."""

    var cloud: Self.C
    var max_payload: Int
    var last_error: String
    var _slots: List[_Slot]
    var _ops: List[_Op]
    var _next_op: Int
    var _buf: List[UInt8]

    def __init__(out self, var cloud: Self.C, max_payload: Int = DEFAULT_MAX_PAYLOAD):
        self.cloud = cloud^
        self.max_payload = max_payload
        self.last_error = String()
        self._slots = List[_Slot]()
        self._ops = List[_Op]()
        self._next_op = 1
        self._buf = List[UInt8](length=PACKET_HEADER + HEADER_BYTES + max_payload, fill=0)

    def _slot(mut self, key: String) -> Int:
        for i in range(len(self._slots)):
            if self._slots[i].key == key:
                return i
        self._slots.append(_Slot(key))
        return len(self._slots) - 1

    def slot_known(mut self, key: String) -> Bool:
        return self._slots[self._slot(key)].known

    def _file(self, key: String, i: Int) -> String:
        return key + String(".") + String(i)

    def _begin_load(mut self, key: String, current_version: Int) -> Int:
        var id = self._next_op
        self._next_op += 1
        var op = _Op(id, key, True)
        op.current_version = current_version
        for i in range(2):
            if self.cloud.read_request(id * 2 + i, self._file(key, i)) != REQ_QUEUED:
                self.last_error = String("storage refused the read of ") + self._file(key, i)
                return -1
        self._ops.append(op^)
        return id

    def _begin_save(mut self, key: String, version: Int, payload: List[UInt8]) -> Int:
        if version < 1 or version > 0x7FFFFFFF:
            self.last_error = String("save version must be 1 or more")
            return -1
        if len(payload) > self.max_payload:
            self.last_error = String("payload of ") + String(len(payload)) + String(" bytes is over the limit of ") + String(self.max_payload)
            return -1
        var s = self._slot(key)
        if not self._slots[s].known:
            self.last_error = String("slot ") + key + String(" has not been loaded: a save could overwrite a file this build has not looked at (a newer build's save, or the only valid copy)")
            return -1
        var id = self._next_op
        self._next_op += 1
        var op = _Op(id, key, False)
        op.write_version = version
        op.write_generation = self._slots[s].generation + 1
        op.write_target = self._slots[s].target
        var bytes = encode_save(version, op.write_generation, payload)
        var both = self._slots[s].repair_both
        var accepted = self.cloud.write_request(id * 2, self._file(key, op.write_target), UInt64(Int(bytes.unsafe_ptr())), len(bytes))
        if accepted == REQ_QUEUED and both:
            accepted = self.cloud.write_request(id * 2 + 1, self._file(key, 1 - op.write_target), UInt64(Int(bytes.unsafe_ptr())), len(bytes))
            op.writes_left = 2
        _ = len(bytes)  # keep the buffer alive until the backend has copied it
        if accepted != REQ_QUEUED:
            self.last_error = String("storage refused the write of ") + self._file(key, op.write_target)
            self._slots[s].known = False
            return -1
        self._slots[s].repair_both = False
        self._slots[s].generation = op.write_generation
        self._slots[s].target = 1 - op.write_target
        self._ops.append(op^)
        return id

    def forget(mut self):
        """Drop what this store knows about the slots and any operation in flight, as a restart of the program would; the
        storage keeps its files. Every slot must be loaded again before it is saved."""
        self._slots = List[_Slot]()
        self._ops = List[_Op]()

    def begin_load(mut self, slot: String, current_version: Int) -> Int:
        """Read run slot `slot` (two files). `current_version` is this build's payload version."""
        if not valid_slot_name(slot):
            self.last_error = String("invalid slot name `") + slot + String("`: 1 to 32 of A-Z a-z 0-9 - _")
            return -1
        return self._begin_load(String("run/") + slot, current_version)

    def save(mut self, slot: String, version: Int, payload: List[UInt8]) -> Int:
        """Write run slot `slot`. The slot must have been loaded in this session (a missing slot counts: the load says NOT_FOUND)."""
        if not valid_slot_name(slot):
            self.last_error = String("invalid slot name `") + slot + String("`")
            return -1
        return self._begin_save(String("run/") + slot, version, payload)

    def autosave(mut self, version: Int, payload: List[UInt8]) -> Int:
        """Write the AUTOSAVE_SLOT run slot. Call it at a safe point: between ticks, never inside one."""
        return self._begin_save(String("run/") + String(AUTOSAVE_SLOT), version, payload)

    def begin_load_profile(mut self, current_version: Int) -> Int:
        return self._begin_load(String("profile"), current_version)

    def save_profile(mut self, version: Int, payload: List[UInt8]) -> Int:
        """Settings and progress that outlive a run. A separate slot, so deleting or corrupting a run save leaves it alone."""
        return self._begin_save(String("profile"), version, payload)

    def poll(mut self) -> List[SaveEvent]:
        """Take every result the storage has ready and return the operations they complete, oldest first."""
        var done = List[SaveEvent]()
        while True:
            var n = self.cloud.poll(UInt64(Int(self._buf.unsafe_ptr())), len(self._buf))
            if n == 0:
                break
            if n < 0:
                # A result over the buffer was dropped by the backend, and which request it answered is not known. Every
                # load still waiting would wait for ever, so each ends with an error that names the limit.
                done.extend(self._fail_pending_loads())
                continue
            if n < PACKET_HEADER:
                continue
            var kind = Int(self._buf[0])
            var rid = Int(get_uint(self._buf, 1, 4))
            var status = Int(self._buf[5])
            var oi = -1
            for i in range(len(self._ops)):
                if self._ops[i].id == rid // 2:
                    oi = i
            if oi < 0:
                continue
            if kind == KIND_SAVE_WRITE:
                self._ops[oi].writes_left -= 1
                if status != STATUS_OK:
                    self._ops[oi].write_failed = True
                if self._ops[oi].writes_left > 0:
                    continue
                var failed = self._ops[oi].write_failed
                var ev = SaveEvent(self._ops[oi].id, False, self._ops[oi].key, SAVE_WRITE_FAILED if failed else SAVE_OK)
                ev.version = self._ops[oi].write_version
                ev.generation = self._ops[oi].write_generation
                if failed:
                    ev.message = String("the storage reported a failed write in ") + ev.key
                    # a file may be half written; the next save must not trust the slot's bookkeeping
                    self._slots[self._slot(ev.key)].known = False
                done.append(ev^)
                self._remove(oi)
            elif kind == KIND_SAVE_READ:
                var f = rid % 2
                self._ops[oi].got[f] = True
                self._ops[oi].status[f] = status
                if status == STATUS_OK:
                    self._ops[oi].data[f] = List[UInt8](length=n - PACKET_HEADER, fill=0)
                    for k in range(n - PACKET_HEADER):
                        self._ops[oi].data[f][k] = self._buf[PACKET_HEADER + k]
                if self._ops[oi].got[0] and self._ops[oi].got[1]:
                    done.append(self._finish_load(oi))
                    self._remove(oi)
        return done^

    def _fail_pending_loads(mut self) -> List[SaveEvent]:
        var failed = List[SaveEvent]()
        var keep = List[_Op]()
        while len(self._ops) > 0:
            var op = self._ops.pop()
            if op.is_load:
                var ev = SaveEvent(op.id, True, op.key, SAVE_CORRUPT)
                ev.message = String("a file of ") + op.key + String(" is larger than max_payload (") + String(self.max_payload) + String(" bytes) and was dropped by the storage; raise max_payload to load it")
                self._slots[self._slot(op.key)].known = False  # an unread file may hold the newest save: no write over it
                failed.append(ev^)
            else:
                keep.append(op^)
        while len(keep) > 0:
            self._ops.append(keep.pop())
        return failed^

    def _remove(mut self, oi: Int):
        _ = self._ops.pop(oi)

    def _finish_load(mut self, oi: Int) -> SaveEvent:
        var op_id = self._ops[oi].id
        var op_key = self._ops[oi].key.copy()
        var current = self._ops[oi].current_version
        var files = List[DecodedFile]()
        for i in range(2):
            if self._ops[oi].status[i] == STATUS_NOT_FOUND:
                files.append(DecodedFile(FILE_ABSENT))
            elif self._ops[oi].status[i] != STATUS_OK:
                files.append(DecodedFile(FILE_CORRUPT, String("the storage could not read it")))
            else:
                files.append(decode_save(self._ops[oi].data[i]))
        var ev = SaveEvent(op_id, True, op_key, SAVE_NOT_FOUND)
        var s = self._slot(op_key)
        var best = -1
        var corrupt = -1
        for i in range(2):
            if files[i].state == FILE_FORMAT_NEWER:
                ev.status = SAVE_NEWER
                ev.message = self._file(op_key, i) + String(": ") + files[i].reason + String("; update the game to load it")
                self._slots[s].known = False
                return ev^
            if files[i].state == FILE_CORRUPT:
                corrupt = i
            if files[i].state == FILE_VALID and (best < 0 or files[i].generation > files[best].generation):
                best = i
        if best < 0:
            self._slots[s].known = True
            self._slots[s].generation = 0
            self._slots[s].target = corrupt if corrupt >= 0 else 0
            self._slots[s].repair_both = corrupt >= 0
            if corrupt >= 0:
                ev.status = SAVE_CORRUPT
                ev.message = self._file(op_key, corrupt) + String(": ") + files[corrupt].reason + String("; no valid backup")
            return ev^
        ev.version = files[best].version
        ev.generation = files[best].generation
        if files[best].version > current:
            ev.status = SAVE_NEWER
            ev.message = String("save version ") + String(files[best].version) + String(" is newer than this build (") + String(current) + String("); update the game to load it")
            self._slots[s].known = False
            return ev^
        ev.payload = files[best].payload.copy()
        ev.needs_migration = files[best].version < current
        ev.status = SAVE_NEEDS_MIGRATION if ev.needs_migration else SAVE_OK
        self._slots[s].known = True
        self._slots[s].repair_both = False
        self._slots[s].generation = files[best].generation
        self._slots[s].target = corrupt if corrupt >= 0 else 1 - best
        if corrupt >= 0:
            ev.status = SAVE_BACKUP_OFFERED
            ev.message = self._file(op_key, corrupt) + String(": ") + files[corrupt].reason + String("; the other copy (generation ") + String(files[best].generation) + String(", version ") + String(files[best].version) + String(") is offered")
        return ev^
