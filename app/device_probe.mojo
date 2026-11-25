"""A module that drives the web device backends (app/os_device.mojo) from JS, so tests/test_device.mjs can run the same
script as tests/platform_device.mojo against the real os_dev_* imports. One router, shared by every seam, as in the app."""
from std.memory import alloc
from os_device import WebCamera, WebHaptics, WebMicrophone, WebMotion, WebPointerLock, WebScreen
from os_router import OsRouter
from platform.camera import Camera
from platform.haptics import Haptics
from platform.microphone import Microphone
from platform.motion import Motion
from platform.pointer_lock import PointerLock
from platform.screen import Screen


struct Seams(Movable):
    var router: OsRouter
    var haptics: WebHaptics
    var motion: WebMotion
    var screen: WebScreen
    var pointer: WebPointerLock
    var camera: WebCamera
    var mic: WebMicrophone

    def __init__(out self):
        self.router = OsRouter(1024 * 1024)
        self.haptics = WebHaptics(self.router)
        self.motion = WebMotion(self.router)
        self.screen = WebScreen(self.router)
        self.pointer = WebPointerLock(self.router)
        self.camera = WebCamera(self.router)
        self.mic = WebMicrophone(self.router)


def _s(h: UInt64) -> UnsafePointer[Seams, MutAnyOrigin]:
    return UnsafePointer[Seams, MutAnyOrigin](unsafe_from_address=Int(h))


@export
def p_new() abi("C") -> UInt64:
    var p = alloc[Seams](1)
    p.unsafe_write(Seams())
    return UInt64(Int(p))


@export
def p_hap_avail(h: UInt64) abi("C") -> Int32:
    return Int32(_s(h)[].haptics.availability())


@export
def p_hap_caps(h: UInt64) abi("C") -> Int32:
    return Int32(_s(h)[].haptics.capabilities())


@export
def p_hap_vibrate(h: UInt64, ms: Int32) abi("C") -> Int32:
    return Int32(_s(h)[].haptics.vibrate(Int(ms)))


@export
def p_hap_pattern(h: UInt64, ptr: UInt64, count: Int32) abi("C") -> Int32:
    return Int32(_s(h)[].haptics.vibrate_pattern(ptr, Int(count)))


@export
def p_hap_rumble(h: UInt64, pad: Int32, strong: Int32, weak: Int32, ms: Int32) abi("C") -> Int32:
    return Int32(_s(h)[].haptics.rumble(Int(pad), Int(strong), Int(weak), Int(ms)))


@export
def p_hap_cancel(h: UInt64) abi("C") -> Int32:
    return Int32(_s(h)[].haptics.cancel())


@export
def p_mot_avail(h: UInt64) abi("C") -> Int32:
    return Int32(_s(h)[].motion.availability())


@export
def p_mot_caps(h: UInt64) abi("C") -> Int32:
    return Int32(_s(h)[].motion.capabilities())


@export
def p_mot_request(h: UInt64, id: Int32) abi("C") -> Int32:
    return Int32(_s(h)[].motion.request_permission(Int(id)))


@export
def p_mot_poll(h: UInt64, buf: UInt64, cap: Int32) abi("C") -> Int32:
    return Int32(_s(h)[].motion.poll(buf, Int(cap)))


@export
def p_mot_start(h: UInt64) abi("C") -> Int32:
    return Int32(_s(h)[].motion.start())


@export
def p_mot_stop(h: UInt64) abi("C"):
    _s(h)[].motion.stop()


@export
def p_mot_read(h: UInt64, ptr: UInt64) abi("C") -> Int32:
    return Int32(_s(h)[].motion.read(ptr))


@export
def p_scr_request(h: UInt64, id: Int32, op: Int32, arg: Int32) abi("C") -> Int32:
    return Int32(_s(h)[].screen.request(Int(id), Int(op), Int(arg)))


@export
def p_scr_state(h: UInt64) abi("C") -> Int32:
    return Int32(_s(h)[].screen.state())


@export
def p_scr_caps(h: UInt64) abi("C") -> Int32:
    return Int32(_s(h)[].screen.capabilities())


@export
def p_scr_poll(h: UInt64, buf: UInt64, cap: Int32) abi("C") -> Int32:
    return Int32(_s(h)[].screen.poll(buf, Int(cap)))


@export
def p_ptr_request(h: UInt64, id: Int32, on: Int32) abi("C") -> Int32:
    return Int32(_s(h)[].pointer.request(Int(id), on != 0))


@export
def p_ptr_locked(h: UInt64) abi("C") -> Int32:
    return Int32(1 if _s(h)[].pointer.locked() else 0)


@export
def p_ptr_delta(h: UInt64, ptr: UInt64) abi("C") -> Int32:
    return Int32(_s(h)[].pointer.take_delta(ptr))


@export
def p_ptr_poll(h: UInt64, buf: UInt64, cap: Int32) abi("C") -> Int32:
    return Int32(_s(h)[].pointer.poll(buf, Int(cap)))


@export
def p_cam_avail(h: UInt64) abi("C") -> Int32:
    return Int32(_s(h)[].camera.availability())


@export
def p_cam_open(h: UInt64, id: Int32, w: Int32, hh: Int32) abi("C") -> Int32:
    return Int32(_s(h)[].camera.open(Int(id), Int(w), Int(hh)))


@export
def p_cam_close(h: UInt64) abi("C"):
    _s(h)[].camera.close()


@export
def p_cam_size(h: UInt64) abi("C") -> Int32:
    return Int32(_s(h)[].camera.frame_width() * 65536 + _s(h)[].camera.frame_height())


@export
def p_cam_frame(h: UInt64, buf: UInt64, cap: Int32) abi("C") -> Int32:
    return Int32(_s(h)[].camera.read_frame(buf, Int(cap)))


@export
def p_cam_skipped(h: UInt64) abi("C") -> Int32:
    return Int32(_s(h)[].camera.skipped())


@export
def p_cam_request(h: UInt64, id: Int32) abi("C") -> Int32:
    return Int32(_s(h)[].camera.request_permission(Int(id)))


@export
def p_cam_poll(h: UInt64, buf: UInt64, cap: Int32) abi("C") -> Int32:
    return Int32(_s(h)[].camera.poll(buf, Int(cap)))


@export
def p_mic_avail(h: UInt64) abi("C") -> Int32:
    return Int32(_s(h)[].mic.availability())


@export
def p_mic_open(h: UInt64, id: Int32, rate: Int32) abi("C") -> Int32:
    return Int32(_s(h)[].mic.open(Int(id), Int(rate)))


@export
def p_mic_close(h: UInt64) abi("C"):
    _s(h)[].mic.close()


@export
def p_mic_rate(h: UInt64) abi("C") -> Int32:
    return Int32(_s(h)[].mic.sample_rate())


@export
def p_mic_read(h: UInt64, buf: UInt64, n: Int32) abi("C") -> Int32:
    return Int32(_s(h)[].mic.read(buf, Int(n)))


@export
def p_mic_overruns(h: UInt64) abi("C") -> Int32:
    return Int32(_s(h)[].mic.overruns())


@export
def p_mic_poll(h: UInt64, buf: UInt64, cap: Int32) abi("C") -> Int32:
    return Int32(_s(h)[].mic.poll(buf, Int(cap)))


@export
def p_foreign(h: UInt64) abi("C") -> Int32:
    return Int32(_s(h)[].router.foreign())
