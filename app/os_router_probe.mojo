"""A module with the input profile, the save seam and the clipboard all reading results through one `OsRouter`, so a test can have
their requests in flight together (tests/test_os_router.mjs)."""
from std.memory import alloc
from game.action_map import ActionMap, DEV_KEY, SLOT_MAIN
from game.demo_actions import DEMO_ACTIONS_TEXT
from os import os_clipboard_read_request
from os_cloud_save import OsCloudSave
from os_router import OsRouter
from profile import ProfileStore


struct Bundle(Movable):
    var router: OsRouter
    var profile: ProfileStore
    var saves: OsCloudSave
    var actions: ActionMap

    def __init__(out self) raises:
        self.router = OsRouter()
        self.profile = ProfileStore(self.router)
        self.saves = OsCloudSave(self.router)
        self.actions = ActionMap.parse(DEMO_ACTIONS_TEXT)


def _str(ptr: UInt64, n: Int) -> String:
    var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(ptr))
    var out = String()
    for i in range(n):
        out += chr(Int(p[i]))
    return out^


def _b(h: UInt64) -> UnsafePointer[Bundle, MutAnyOrigin]:
    return UnsafePointer[Bundle, MutAnyOrigin](unsafe_from_address=Int(h))


@export
def p_new() abi("C") -> UInt64:
    var p = alloc[Bundle](1)
    try:
        p.unsafe_write(Bundle())
    except:
        return 0
    return UInt64(Int(p))


@export
def p_request_profile(h: UInt64) abi("C") -> Int32:
    return _b(h)[].profile.request()


@export
def p_request_save(h: UInt64, id: Int32, sp: UInt64, sl: UInt64) abi("C") -> Int32:
    return Int32(_b(h)[].saves.read_request(Int(id), _str(sp, Int(sl))))


@export
def p_request_clipboard() abi("C") -> Int32:
    return os_clipboard_read_request()


@export
def p_poll_save(h: UInt64, buf: UInt64, cap: Int32) abi("C") -> Int32:
    return Int32(_b(h)[].saves.poll(buf, Int(cap)))


@export
def p_poll_profile(h: UInt64) abi("C") -> Int32:
    """1 once the profile result has been applied."""
    _b(h)[].profile.poll(_b(h)[].actions)
    return 1 if _b(h)[].profile.loaded else 0


@export
def p_poll_clipboard(h: UInt64, buf: UInt64, cap: Int32) abi("C") -> Int32:
    return Int32(_b(h)[].router.take_clipboard(buf, Int(cap)))


@export
def p_jump_key_is_j(h: UInt64) abi("C") -> Int32:
    return 1 if _b(h)[].actions.prompt_source("jump", SLOT_MAIN, DEV_KEY) == "input.key.key_j" else 0


@export
def p_foreign(h: UInt64) abi("C") -> Int32:
    return Int32(_b(h)[].router.foreign())
