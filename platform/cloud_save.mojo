"""The CloudSave seam (docs/platform.md): named slots of bytes (for example the output of ludens-core's
ld_world_save), written and read asynchronously.

`write_request(id, slot, ptr, length)` copies the bytes at once and returns; its result is a KIND_SAVE_WRITE packet.
`read_request(id, slot)` answers with a KIND_SAVE_READ packet: status STATUS_OK and the bytes, or STATUS_NOT_FOUND and
no payload. A read result larger than the poll's `cap` is dropped and counted like any packet (platform/packets.mojo);
the caller polls with a buffer of PACKET_HEADER + MAX_SAVE_BYTES to be sure. A slot name is 1 to 128 bytes and a save
at most MAX_SAVE_BYTES (the limit os_host.mjs puts on a file); otherwise the request is REQ_INVALID.

MemoryCloudSave keeps the slots in memory, for tests. Standard library only."""
from platform.packets import (
    KIND_SAVE_READ,
    KIND_SAVE_WRITE,
    PacketQueue,
    REQ_INVALID,
    STATUS_NOT_FOUND,
    STATUS_OK,
    packet,
)
from platform.transport import copy_bytes

comptime MAX_SAVE_BYTES = 64 * 1024 * 1024
comptime MAX_SLOT = 128


trait CloudSave(Movable):
    def write_request(mut self, id: Int, slot: String, ptr: UInt64, length: Int) -> Int:
        ...

    def read_request(mut self, id: Int, slot: String) -> Int:
        ...

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        ...

    def dropped(self) -> Int:
        ...


struct MemoryCloudSave(CloudSave):
    var _slots: List[String]
    var _data: List[List[UInt8]]
    var _q: PacketQueue

    def __init__(out self):
        self._slots = List[String]()
        self._data = List[List[UInt8]]()
        self._q = PacketQueue()

    def _find(self, slot: String) -> Int:
        for i in range(len(self._slots)):
            if self._slots[i] == slot:
                return i
        return -1

    def write_request(mut self, id: Int, slot: String, ptr: UInt64, length: Int) -> Int:
        if slot.byte_length() == 0 or slot.byte_length() > MAX_SLOT or length < 0 or length > MAX_SAVE_BYTES:
            return REQ_INVALID
        var data = List[UInt8](length=length, fill=0)
        copy_bytes(UInt64(Int(data.unsafe_ptr())), ptr, length)
        var i = self._find(slot)
        if i < 0:
            self._slots.append(slot)
            self._data.append(data^)
        else:
            self._data[i] = data^
        return self._q.push(packet(KIND_SAVE_WRITE, id, STATUS_OK, List[UInt8]()))

    def read_request(mut self, id: Int, slot: String) -> Int:
        if slot.byte_length() == 0 or slot.byte_length() > MAX_SLOT:
            return REQ_INVALID
        var i = self._find(slot)
        if i < 0:
            return self._q.push(packet(KIND_SAVE_READ, id, STATUS_NOT_FOUND, List[UInt8]()))
        return self._q.push(packet(KIND_SAVE_READ, id, STATUS_OK, self._data[i]))

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        return self._q.poll(buf, cap)

    def dropped(self) -> Int:
        return self._q.dropped()
