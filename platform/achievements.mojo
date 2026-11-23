"""The Achievements seam (docs/platform.md): achievements and integer stats, in one seam because every listed backend
(Steam, Google Play Games) has both.

`unlock(id, name)` and `set_stat(id, name, value)` return at once; the result is a KIND_UNLOCK or KIND_STAT packet
(platform/packets.mojo) whose payload is the name. Unlocking twice succeeds both times. A name is 1 to 128 bytes;
otherwise the request is REQ_INVALID.

LocalAchievements keeps them in memory (a game that wants them kept across runs saves them through CloudSave).
Standard library only."""
from platform.packets import KIND_STAT, KIND_UNLOCK, PacketQueue, REQ_INVALID, STATUS_OK, packet, text_bytes

comptime MAX_NAME = 128


trait Achievements(Movable):
    def unlock(mut self, id: Int, name: String) -> Int:
        ...

    def set_stat(mut self, id: Int, name: String, value: Int64) -> Int:
        ...

    def is_unlocked(self, name: String) -> Bool:
        """What this backend knows locally (a remote backend: as of its last confirmed result)."""
        ...

    def stat(self, name: String) -> Int64:
        """0 for a stat never set."""
        ...

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        ...

    def dropped(self) -> Int:
        ...


struct LocalAchievements(Achievements):
    var _unlocked: List[String]
    var _stat_names: List[String]
    var _stat_values: List[Int64]
    var _q: PacketQueue

    def __init__(out self):
        self._unlocked = List[String]()
        self._stat_names = List[String]()
        self._stat_values = List[Int64]()
        self._q = PacketQueue()

    def unlock(mut self, id: Int, name: String) -> Int:
        if name.byte_length() == 0 or name.byte_length() > MAX_NAME:
            return REQ_INVALID
        if not self.is_unlocked(name):
            self._unlocked.append(name)
        return self._q.push(packet(KIND_UNLOCK, id, STATUS_OK, text_bytes(name)))

    def set_stat(mut self, id: Int, name: String, value: Int64) -> Int:
        if name.byte_length() == 0 or name.byte_length() > MAX_NAME:
            return REQ_INVALID
        var found = False
        for i in range(len(self._stat_names)):
            if self._stat_names[i] == name:
                self._stat_values[i] = value
                found = True
        if not found:
            self._stat_names.append(name)
            self._stat_values.append(value)
        return self._q.push(packet(KIND_STAT, id, STATUS_OK, text_bytes(name)))

    def is_unlocked(self, name: String) -> Bool:
        for i in range(len(self._unlocked)):
            if self._unlocked[i] == name:
                return True
        return False

    def stat(self, name: String) -> Int64:
        for i in range(len(self._stat_names)):
            if self._stat_names[i] == name:
                return self._stat_values[i]
        return 0

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        return self._q.poll(buf, cap)

    def dropped(self) -> Int:
        return self._q.dropped()
