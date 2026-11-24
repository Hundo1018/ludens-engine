"""CloudSave over a directory of files, for the native build (docs/save-games.md). A slot name is a relative path under
`root` with the same rules as the web host's file paths (shell/web/os_host.mjs `validPath`): 1 to 128 bytes of A-Z a-z 0-9 . _ - /
and space, no empty, `.` or `..` segment, no leading or trailing `/`. Parent directories are created on a write.

Reads and writes happen inside the request and the result is queued, so a result is ready at the next poll. A write
replaces the file in place; the two-file scheme of platform/save_store.mojo is what makes that safe. Standard library only."""
from std.os import makedirs
from std.os.path import exists
from platform.cloud_save import CloudSave, MAX_SAVE_BYTES, MAX_SLOT
from platform.packets import (
    KIND_SAVE_READ,
    KIND_SAVE_WRITE,
    PacketQueue,
    REQ_INVALID,
    STATUS_ERROR,
    STATUS_NOT_FOUND,
    STATUS_OK,
    packet,
)
from platform.transport import copy_bytes


def valid_path(path: String) -> Bool:
    var n = path.byte_length()
    if n == 0 or n > MAX_SLOT:
        return False
    var seg = 0  # length of the current segment
    var dots = 0  # how many of its characters are `.`
    for b in path.as_bytes():
        var c = Int(b)
        if c == 47:
            if seg == 0 or dots == seg and seg <= 2:
                return False
            seg = 0
            dots = 0
            continue
        var ok = (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 46 or c == 95 or c == 45 or c == 32
        if not ok:
            return False
        seg += 1
        if c == 46:
            dots += 1
    return seg > 0 and not (dots == seg and seg <= 2)


struct FileCloudSave(CloudSave):
    var root: String
    var _q: PacketQueue

    def __init__(out self, root: String):
        self.root = root
        self._q = PacketQueue()

    def _path(self, slot: String) -> String:
        return self.root + String("/") + slot

    def write_request(mut self, id: Int, slot: String, ptr: UInt64, length: Int) -> Int:
        if not valid_path(slot) or length < 0 or length > MAX_SAVE_BYTES:
            return REQ_INVALID
        var data = List[UInt8](length=length, fill=0)
        copy_bytes(UInt64(Int(data.unsafe_ptr())), ptr, length)
        var status = STATUS_OK
        try:
            var path = self._path(slot)
            var cut = path.rfind("/")
            makedirs(String(path[byte=0:cut]), exist_ok=True)
            with open(path, "w") as f:
                f.write_bytes(data)
        except:
            status = STATUS_ERROR
        return self._q.push(packet(KIND_SAVE_WRITE, id, status, List[UInt8]()))

    def read_request(mut self, id: Int, slot: String) -> Int:
        if not valid_path(slot):
            return REQ_INVALID
        var path = self._path(slot)
        if not exists(path):
            return self._q.push(packet(KIND_SAVE_READ, id, STATUS_NOT_FOUND, List[UInt8]()))
        try:
            var data = List[UInt8]()
            with open(path, "r") as f:
                data = f.read_bytes()
            return self._q.push(packet(KIND_SAVE_READ, id, STATUS_OK, data))
        except:
            return self._q.push(packet(KIND_SAVE_READ, id, STATUS_ERROR, List[UInt8]()))

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        return self._q.poll(buf, cap)

    def dropped(self) -> Int:
        return self._q.dropped()
