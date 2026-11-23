"""The Identity seam (docs/platform.md): who the player is on this backend, and a token a game server can verify.

`player_id` is stable for this player on this backend. `token` is opaque bytes the game sends to its own server, which
checks them with the backend (Steam: the Web API ticket check; OIDC: the provider's keys). `sign_in(id)` starts a sign
in; its result is a KIND_SIGN_IN packet (platform/packets.mojo) with the player id as payload.

LocalIdentity is the offline implementation: the player id is given, the token is "local:" + the id (no server can
trust it), and a sign in always succeeds. Standard library only."""
from platform.packets import KIND_SIGN_IN, PacketQueue, STATUS_OK, packet, text_bytes


trait Identity(Movable):
    def player_id(self) -> String:
        """Empty until signed in."""
        ...

    def token(self) -> List[UInt8]:
        """Empty until signed in."""
        ...

    def sign_in(mut self, id: Int) -> Int:
        """Start a sign in: REQ_QUEUED or REQ_FULL. The result is a KIND_SIGN_IN packet."""
        ...

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        ...

    def dropped(self) -> Int:
        ...


struct LocalIdentity(Identity):
    var _name: String
    var _signed_in: Bool
    var _q: PacketQueue

    def __init__(out self, name: String):
        self._name = name
        self._signed_in = False
        self._q = PacketQueue()

    def player_id(self) -> String:
        return self._name if self._signed_in else String("")

    def token(self) -> List[UInt8]:
        return text_bytes("local:" + self._name) if self._signed_in else List[UInt8]()

    def sign_in(mut self, id: Int) -> Int:
        self._signed_in = True
        return self._q.push(packet(KIND_SIGN_IN, id, STATUS_OK, text_bytes(self._name)))

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        return self._q.poll(buf, cap)

    def dropped(self) -> Int:
        return self._q.dropped()
