"""The request / poll seams (docs/platform.md) through their local implementations: LocalIdentity, LocalAchievements,
MemoryCloudSave and MemoryLobbyHub. Each result is read back as a packet ([kind u8][id u32 LE][status u8][payload],
platform/packets.mojo), and a result larger than the poll's `cap` is answered -1 once, counted, and the next one
still arrives.

Standard library only: `pixi run -e wasm test-transport` builds and runs it after tests/platform_transport.mojo."""
from platform.achievements import LocalAchievements
from platform.cloud_save import MemoryCloudSave
from platform.identity import LocalIdentity
from platform.lobby import MemoryLobbyHub
from platform.packets import (
    KIND_LOBBY_ENTERED,
    KIND_LOBBY_LEFT,
    KIND_LOBBY_MEMBER_JOINED,
    KIND_LOBBY_MEMBER_LEFT,
    KIND_SAVE_READ,
    KIND_SAVE_WRITE,
    KIND_SIGN_IN,
    KIND_STAT,
    KIND_UNLOCK,
    PACKET_HEADER,
    REQ_INVALID,
    REQ_QUEUED,
    STATUS_ERROR,
    STATUS_NOT_FOUND,
    STATUS_OK,
    text_bytes,
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


struct Got(Copyable, Movable):
    var n: Int
    var kind: Int
    var id: Int
    var status: Int
    var payload: List[UInt8]

    def __init__(out self, n: Int, buf: List[UInt8]):
        self.n = n
        self.kind = -1
        self.id = -1
        self.status = -1
        self.payload = List[UInt8]()
        if n >= PACKET_HEADER:
            self.kind = Int(buf[0])
            self.id = Int(buf[1]) | (Int(buf[2]) << 8) | (Int(buf[3]) << 16) | (Int(buf[4]) << 24)
            self.status = Int(buf[5])
            for i in range(PACKET_HEADER, n):
                self.payload.append(buf[i])

    def text(self) -> String:
        var s = String("")
        for b in self.payload:
            s += chr(Int(b))
        return s

    def is_(self, kind: Int, id: Int, status: Int) -> Bool:
        return self.kind == kind and self.id == id and self.status == status


def take(mut buf: List[UInt8], n: Int) -> Got:
    return Got(n, buf)


def main() raises:
    var c = Check()
    var buf = List[UInt8](length=4096, fill=0)
    var p = UInt64(Int(buf.unsafe_ptr()))

    # Identity
    var ident = LocalIdentity("alice")
    c.check(ident.player_id() == "" and len(ident.token()) == 0, "identity: nothing before sign in")
    c.check(ident.poll(p, 4096) == 0, "identity: empty poll is 0")
    c.check(ident.sign_in(7) == REQ_QUEUED, "identity: sign in is queued")
    var g = take(buf, ident.poll(p, 4096))
    c.check(g.is_(KIND_SIGN_IN, 7, STATUS_OK) and g.text() == "alice", "identity: KIND_SIGN_IN, id 7, ok, payload alice")
    c.check(ident.player_id() == "alice" and len(ident.token()) == 11, "identity: player id and token after sign in")

    # Achievements and stats
    var ach = LocalAchievements()
    c.check(ach.unlock(1, "first_jump") == REQ_QUEUED and ach.is_unlocked("first_jump"), "achievements: unlock")
    c.check(ach.unlock(2, "first_jump") == REQ_QUEUED, "achievements: unlocking twice succeeds")
    c.check(ach.unlock(3, "") == REQ_INVALID, "achievements: an empty name is REQ_INVALID")
    c.check(ach.set_stat(4, "jumps", 3) == REQ_QUEUED and ach.set_stat(5, "jumps", 9) == REQ_QUEUED and ach.stat("jumps") == 9,
            "achievements: set_stat keeps the last value")
    c.check(ach.stat("never") == 0 and not ach.is_unlocked("never"), "achievements: unknown names read as 0 / locked")
    var a1 = take(buf, ach.poll(p, 4096))
    var a2 = take(buf, ach.poll(p, 4096))
    var a3 = take(buf, ach.poll(p, 4096))
    var a4 = take(buf, ach.poll(p, 4096))
    c.check(a1.is_(KIND_UNLOCK, 1, STATUS_OK) and a2.is_(KIND_UNLOCK, 2, STATUS_OK) and a1.text() == "first_jump",
            "achievements: two KIND_UNLOCK results in order")
    c.check(a3.is_(KIND_STAT, 4, STATUS_OK) and a4.is_(KIND_STAT, 5, STATUS_OK) and a4.text() == "jumps",
            "achievements: two KIND_STAT results in order")
    c.check(ach.poll(p, 4096) == 0, "achievements: then empty (the invalid request queued nothing)")

    # Cloud save
    var save = MemoryCloudSave()
    var blob = List[UInt8](length=3000, fill=0)
    for i in range(3000):
        blob[i] = UInt8((i * 7) & 0xFF)
    c.check(save.read_request(10, "slot1") == REQ_QUEUED, "cloud save: read of a missing slot is queued")
    var s1 = take(buf, save.poll(p, 4096))
    c.check(s1.is_(KIND_SAVE_READ, 10, STATUS_NOT_FOUND) and s1.n == PACKET_HEADER, "cloud save: missing slot is STATUS_NOT_FOUND, no payload")
    c.check(save.write_request(11, "slot1", UInt64(Int(blob.unsafe_ptr())), len(blob)) == REQ_QUEUED, "cloud save: write is queued")
    blob[0] = 255  # the write copied the bytes when it was made
    c.check(save.read_request(12, "slot1") == REQ_QUEUED and save.read_request(13, "") == REQ_INVALID, "cloud save: read queued, empty slot name REQ_INVALID")
    var s2 = take(buf, save.poll(p, 4096))
    var s3 = take(buf, save.poll(p, 4096))
    var same = s3.n == PACKET_HEADER + 3000
    for i in range(3000):
        same = same and s3.n == PACKET_HEADER + 3000 and s3.payload[i] == UInt8((i * 7) & 0xFF)
    c.check(s2.is_(KIND_SAVE_WRITE, 11, STATUS_OK), "cloud save: KIND_SAVE_WRITE ok")
    c.check(s3.is_(KIND_SAVE_READ, 12, STATUS_OK) and same, "cloud save: KIND_SAVE_READ returns the 3000 bytes as written")
    _ = save.read_request(14, "slot1")
    _ = save.read_request(15, "nope")
    c.check(save.poll(p, 1000) == -1 and save.dropped() == 1, "cloud save: a result over cap is -1 once and counted")
    var s4 = take(buf, save.poll(p, 1000))
    c.check(s4.is_(KIND_SAVE_READ, 15, STATUS_NOT_FOUND), "cloud save: the result behind it arrives")

    # Lobby
    var hub = MemoryLobbyHub()
    var la = hub.member("alice")
    var lb = hub.member("bob")
    var lc = hub.member("carol")
    c.check(la.leave(1) == REQ_INVALID, "lobby: leave outside a lobby is REQ_INVALID")
    c.check(lb.join(2, "room") == REQ_QUEUED, "lobby: join of a missing lobby is queued")
    c.check(take(buf, lb.poll(p, 4096)).is_(KIND_LOBBY_ENTERED, 2, STATUS_NOT_FOUND), "lobby: ...and answered STATUS_NOT_FOUND")
    _ = la.create(3, "room", 2)
    var e1 = take(buf, la.poll(p, 4096))
    c.check(e1.is_(KIND_LOBBY_ENTERED, 3, STATUS_OK) and e1.text() == "room" and la.current() == "room", "lobby: create enters the lobby")
    _ = lb.create(4, "room", 2)
    c.check(take(buf, lb.poll(p, 4096)).is_(KIND_LOBBY_ENTERED, 4, STATUS_ERROR), "lobby: create of a taken name is STATUS_ERROR")
    _ = lb.join(5, "room")
    var b1 = take(buf, lb.poll(p, 4096))
    var b2 = take(buf, lb.poll(p, 4096))
    var a_j = take(buf, la.poll(p, 4096))
    c.check(b1.is_(KIND_LOBBY_ENTERED, 5, STATUS_OK) and b2.is_(KIND_LOBBY_MEMBER_JOINED, 0, STATUS_OK) and b2.text() == "alice",
            "lobby: the joiner is told who is there")
    c.check(a_j.is_(KIND_LOBBY_MEMBER_JOINED, 0, STATUS_OK) and a_j.text() == "bob", "lobby: the member there is told who joined")
    _ = lc.join(6, "room")
    c.check(take(buf, lc.poll(p, 4096)).is_(KIND_LOBBY_ENTERED, 6, STATUS_ERROR) and lc.current() == "", "lobby: a full lobby is STATUS_ERROR")
    c.check(la.create(7, "other", 4) == REQ_INVALID, "lobby: create while in a lobby is REQ_INVALID")
    _ = la.leave(8)
    c.check(take(buf, la.poll(p, 4096)).is_(KIND_LOBBY_LEFT, 8, STATUS_OK) and la.current() == "", "lobby: leave is answered")
    var b3 = take(buf, lb.poll(p, 4096))
    c.check(b3.is_(KIND_LOBBY_MEMBER_LEFT, 0, STATUS_OK) and b3.text() == "alice", "lobby: the others are told who left")
    _ = lb.leave(9)
    _ = lb.poll(p, 4096)
    _ = lc.join(10, "room")
    c.check(take(buf, lc.poll(p, 4096)).is_(KIND_LOBBY_ENTERED, 10, STATUS_NOT_FOUND), "lobby: a lobby ends with its last member")

    print("platform_services: " + String(c.passed) + " passed, " + String(c.failed) + " failed")
    if c.failed:
        raise Error("platform_services: " + String(c.failed) + " checks failed")
