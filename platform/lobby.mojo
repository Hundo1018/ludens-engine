"""The Lobby seam (docs/platform.md): create, join and leave a named lobby, and hear who else is in it.

Requests return at once; results and events are packets (platform/packets.mojo):

  KIND_LOBBY_ENTERED        the answer to create / join: STATUS_OK (payload: the lobby name), STATUS_NOT_FOUND (join:
                            no such lobby), STATUS_ERROR (create: the name is taken; join: the lobby is full)
  KIND_LOBBY_MEMBER_JOINED  payload: a member's player id. After entering, one for every member already there; later,
                            one per new member
  KIND_LOBBY_MEMBER_LEFT    payload: the player id of a member who left
  KIND_LOBBY_LEFT           the answer to leave

A member in a lobby must leave before it creates or joins another (otherwise REQ_INVALID), and leave outside a lobby is
REQ_INVALID. A lobby ends when its last member leaves. How a lobby hands out the address to open a Transport to is an
open question (docs/platform.md), so no address is carried yet.

MemoryLobbyHub is the in-process implementation: every MemoryLobby taken from one hub sees the same lobbies. Standard
library only."""
from std.memory import ArcPointer
from platform.packets import (
    KIND_LOBBY_ENTERED,
    KIND_LOBBY_LEFT,
    KIND_LOBBY_MEMBER_JOINED,
    KIND_LOBBY_MEMBER_LEFT,
    PacketQueue,
    REQ_INVALID,
    STATUS_ERROR,
    STATUS_NOT_FOUND,
    STATUS_OK,
    packet,
    text_bytes,
)

comptime MAX_LOBBY_NAME = 128


trait Lobby(Movable):
    def create(mut self, id: Int, name: String, max_members: Int) -> Int:
        ...

    def join(mut self, id: Int, name: String) -> Int:
        ...

    def leave(mut self, id: Int) -> Int:
        ...

    def current(self) -> String:
        """The lobby this member is in, as of the last answer it produced; empty when in none."""
        ...

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        ...

    def dropped(self) -> Int:
        ...


struct _Hub(Movable):
    var names: List[String]  # lobby names; "" for a lobby that ended (indices stay stable)
    var caps: List[Int]
    var members: List[List[Int]]  # member slots of each lobby, in the order they entered
    var player: List[String]  # player id of each member slot
    var queues: List[PacketQueue]  # result queue of each member slot
    var where: List[Int]  # lobby index of each member slot, -1 for none

    def __init__(out self):
        self.names = List[String]()
        self.caps = List[Int]()
        self.members = List[List[Int]]()
        self.player = List[String]()
        self.queues = List[PacketQueue]()
        self.where = List[Int]()

    def find(self, name: String) -> Int:
        for i in range(len(self.names)):
            if self.names[i] == name:
                return i
        return -1

    def enter(mut self, slot: Int, lobby: Int, id: Int) -> Int:
        """Put `slot` into `lobby`, tell it who is there and tell them about it."""
        var r = self.queues[slot].push(packet(KIND_LOBBY_ENTERED, id, STATUS_OK, text_bytes(self.names[lobby])))
        for m in self.members[lobby]:
            _ = self.queues[slot].push(packet(KIND_LOBBY_MEMBER_JOINED, 0, STATUS_OK, text_bytes(self.player[m])))
            _ = self.queues[m].push(packet(KIND_LOBBY_MEMBER_JOINED, 0, STATUS_OK, text_bytes(self.player[slot])))
        self.members[lobby].append(slot)
        self.where[slot] = lobby
        return r


struct MemoryLobbyHub(Movable):
    var _hub: ArcPointer[_Hub]

    def __init__(out self):
        self._hub = ArcPointer(_Hub())

    def member(self, player_id: String) -> MemoryLobby:
        """A new member of this hub, in no lobby."""
        var slot = len(self._hub[].player)
        self._hub[].player.append(player_id)
        self._hub[].queues.append(PacketQueue())
        self._hub[].where.append(-1)
        return MemoryLobby(self._hub, slot)


struct MemoryLobby(Lobby):
    var _hub: ArcPointer[_Hub]
    var _slot: Int

    def __init__(out self, hub: ArcPointer[_Hub], slot: Int):
        self._hub = hub
        self._slot = slot

    def create(mut self, id: Int, name: String, max_members: Int) -> Int:
        if name.byte_length() == 0 or name.byte_length() > MAX_LOBBY_NAME or max_members < 1 or self._hub[].where[self._slot] >= 0:
            return REQ_INVALID
        if self._hub[].find(name) >= 0:
            return self._hub[].queues[self._slot].push(packet(KIND_LOBBY_ENTERED, id, STATUS_ERROR, List[UInt8]()))
        self._hub[].names.append(name)
        self._hub[].caps.append(max_members)
        self._hub[].members.append(List[Int]())
        return self._hub[].enter(self._slot, len(self._hub[].names) - 1, id)

    def join(mut self, id: Int, name: String) -> Int:
        if name.byte_length() == 0 or name.byte_length() > MAX_LOBBY_NAME or self._hub[].where[self._slot] >= 0:
            return REQ_INVALID
        var lobby = self._hub[].find(name)
        if lobby < 0:
            return self._hub[].queues[self._slot].push(packet(KIND_LOBBY_ENTERED, id, STATUS_NOT_FOUND, List[UInt8]()))
        if len(self._hub[].members[lobby]) >= self._hub[].caps[lobby]:
            return self._hub[].queues[self._slot].push(packet(KIND_LOBBY_ENTERED, id, STATUS_ERROR, List[UInt8]()))
        return self._hub[].enter(self._slot, lobby, id)

    def leave(mut self, id: Int) -> Int:
        var lobby = self._hub[].where[self._slot]
        if lobby < 0:
            return REQ_INVALID
        var rest = List[Int]()
        for m in self._hub[].members[lobby]:
            if m != self._slot:
                rest.append(m)
                _ = self._hub[].queues[m].push(
                    packet(KIND_LOBBY_MEMBER_LEFT, 0, STATUS_OK, text_bytes(self._hub[].player[self._slot]))
                )
        if len(rest) == 0:
            self._hub[].names[lobby] = String("")  # the lobby ends with its last member
        self._hub[].members[lobby] = rest^
        self._hub[].where[self._slot] = -1
        return self._hub[].queues[self._slot].push(packet(KIND_LOBBY_LEFT, id, STATUS_OK, List[UInt8]()))

    def current(self) -> String:
        var lobby = self._hub[].where[self._slot]
        return self._hub[].names[lobby] if lobby >= 0 else String("")

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        return self._hub[].queues[self._slot].poll(buf, cap)

    def dropped(self) -> Int:
        return self._hub[].queues[self._slot].dropped()
