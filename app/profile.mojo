"""The player's input profile (game/action_map.mojo `profile()` / `load_profile`) through the host's file storage: written to
`profile/actions.txt` with os_file_write when a binding changes, requested with os_file_read_request when the app starts and
applied when the result arrives (a frame or two later; until then the defaults are in force).

The result is taken from the shared `OsRouter` (app/os_router.mojo), the only caller of `os_poll`: this file never reads the
host's queue itself, so a save result in flight is not taken here, and the profile result is not taken by the save seam.
Result packet: [kind u8][id u32 LE][status u8][payload] (shell/web/os_host.mjs)."""
from game.action_map import ActionMap
from os import os_file_read_request, os_file_write
from os_router import OsRouter, PROFILE_READ_ID

comptime PROFILE_PATH = "profile/actions.txt"
comptime PROFILE_CAP = 16384  # a profile is a few dozen short rows; a larger packet is dropped and counted
comptime _PER_FRAME = 4


struct ProfileStore(Movable):
    var router: OsRouter
    var rx: List[UInt8]
    var requested: Bool
    var loaded: Bool  # a profile (or "no profile") came back
    var problems: Int  # rows of the loaded profile that were skipped

    def __init__(out self, router: OsRouter):
        self.router = router
        self.rx = List[UInt8](length=PROFILE_CAP, fill=0)
        self.requested = False
        self.loaded = False
        self.problems = 0

    def request(mut self) -> Int32:
        """Ask the host for the saved profile, once."""
        if self.requested:
            return 0
        self.requested = True
        var path = String(PROFILE_PATH)
        return os_file_read_request(PROFILE_READ_ID, UInt64(Int(path.unsafe_ptr())), UInt64(path.byte_length()))

    def save(self, text: String) -> Int32:
        """Write the profile. 0 = queued."""
        var path = String(PROFILE_PATH)
        return os_file_write(UInt64(Int(path.unsafe_ptr())), UInt64(path.byte_length()), UInt64(Int(text.unsafe_ptr())), UInt64(text.byte_length()))

    def poll(mut self, mut actions: ActionMap):
        """Take the profile result, if it has come; apply it."""
        if not self.requested or self.loaded:
            return
        for _ in range(_PER_FRAME):
            var n = self.router.take_profile(UInt64(Int(self.rx.unsafe_ptr())), PROFILE_CAP)
            if n == 0:
                return
            if n < 6:
                continue  # dropped for being larger than PROFILE_CAP (-1), or not a packet
            self.loaded = True
            if self.rx[5] == 0:
                var text = String()  # a profile is ASCII: action names, slots and `device:code` sources
                for i in range(6, n):
                    text += chr(Int(self.rx[i]))
                self.problems = len(actions.load_profile(text))
            return
