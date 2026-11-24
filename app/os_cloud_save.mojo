"""CloudSave over the web host's file imports (os_file_write, os_file_read_request, os_poll; shell/web/os_host.mjs), so a
save lives in the browser's origin-private file system. A slot `run/a.0` is the file `saves/run/a.0`.

`os_file_write` returns once the write is queued and sends no result, so the KIND_SAVE_WRITE packet is made here, at that
moment: it says "queued", not "stored". The two-file scheme of platform/save_store.mojo is what keeps a write that never
finishes from damaging the previous save. A read result arrives through `os_poll` as a file packet (kind 2) and is
re-labelled KIND_SAVE_READ with the same id and status. `os_poll` is the host's one result queue: a clipboard packet
(kind 1) taken here is dropped and counted in `foreign()`, so an app that also reads the clipboard polls in one place
and passes the file packets on."""
from os import os_file_read_request, os_file_write, os_poll
from platform.cloud_save import CloudSave, MAX_SAVE_BYTES, MAX_SLOT
from platform.file_cloud_save import valid_path
from platform.packets import KIND_SAVE_READ, KIND_SAVE_WRITE, PACKET_HEADER, PacketQueue, REQ_INVALID, STATUS_ERROR, STATUS_OK, packet

comptime KIND_HOST_FILE = 2
comptime SAVE_DIR = "saves/"


struct OsCloudSave(CloudSave):
    var _acks: PacketQueue
    var _foreign: Int

    def __init__(out self):
        self._acks = PacketQueue()
        self._foreign = 0

    def write_request(mut self, id: Int, slot: String, ptr: UInt64, length: Int) -> Int:
        if not valid_path(slot) or length < 0 or length > MAX_SAVE_BYTES:
            return REQ_INVALID
        var path = String(SAVE_DIR) + slot
        var rc = os_file_write(UInt64(Int(path.unsafe_ptr())), UInt64(path.byte_length()), ptr, UInt64(length))
        _ = path.byte_length()
        return self._acks.push(packet(KIND_SAVE_WRITE, id, STATUS_OK if rc == 0 else STATUS_ERROR, List[UInt8]()))

    def read_request(mut self, id: Int, slot: String) -> Int:
        if not valid_path(slot):
            return REQ_INVALID
        var path = String(SAVE_DIR) + slot
        var rc = os_file_read_request(Int32(id), UInt64(Int(path.unsafe_ptr())), UInt64(path.byte_length()))
        _ = path.byte_length()
        if rc != 0:
            return self._acks.push(packet(KIND_SAVE_READ, id, STATUS_ERROR, List[UInt8]()))
        return 0

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        var n = self._acks.poll(buf, cap)
        if n != 0:
            return n
        while True:
            var got = Int(os_poll(buf, UInt64(cap)))
            if got <= 0:
                return got
            var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(buf))
            if got >= PACKET_HEADER and Int(p[0]) == KIND_HOST_FILE:
                p[0] = UInt8(KIND_SAVE_READ)
                return got
            self._foreign += 1  # another kind of result: not ours, dropped

    def dropped(self) -> Int:
        return self._acks.dropped()

    def foreign(self) -> Int:
        return self._foreign
