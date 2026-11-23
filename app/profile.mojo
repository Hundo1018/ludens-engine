"""The player's input profile (game/action_map.mojo `profile()` / `load_profile`) through the host's file storage: written to
`profile/actions.txt` with os_file_write when a binding changes, requested with os_file_read_request when the app starts and
applied when the result arrives through os_poll (a frame or two later; until then the defaults are in force).
Result packet: [kind u8][id u32 LE][status u8][payload] (shell/web/os_host.mjs)."""
from game.action_map import ActionMap
from os import os_file_read_request, os_file_write, os_poll

comptime PROFILE_PATH = "profile/actions.txt"
comptime PROFILE_READ_ID: Int32 = 117
comptime PROFILE_CAP = 16384  # a profile is a few dozen short rows; a larger packet is dropped by the host and counted
comptime _KIND_FILE = 2
comptime _PER_FRAME = 4


struct ProfileStore(Movable):
    var rx: List[UInt8]
    var requested: Bool
    var loaded: Bool  # a profile (or "no profile") came back
    var problems: Int  # rows of the loaded profile that were skipped

    def __init__(out self):
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
        """Take the host's results; apply a profile that came back for our request."""
        if not self.requested or self.loaded:
            return
        for _ in range(_PER_FRAME):
            var n = os_poll(UInt64(Int(self.rx.unsafe_ptr())), UInt64(PROFILE_CAP))
            if n == 0:
                return
            if n < 0 or n < 6:
                continue
            var id = Int(self.rx[1]) | (Int(self.rx[2]) << 8) | (Int(self.rx[3]) << 16) | (Int(self.rx[4]) << 24)
            if Int(self.rx[0]) != _KIND_FILE or id != Int(PROFILE_READ_ID):
                continue
            self.loaded = True
            if self.rx[5] == 0:
                var text = String()  # a profile is ASCII: action names, slots and `device:code` sources
                for i in range(6, Int(n)):
                    text += chr(Int(self.rx[i]))
                self.problems = len(actions.load_profile(text))
            return
