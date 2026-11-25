"""The web backends of the device seams (platform/haptics.mojo and the others) over the `os_dev_*` imports of
shell/web/device_host.mjs, declared by wasm.toml's `os_*` pattern.

Each backend takes the app's `OsRouter` (app/os_router.mojo), the one reader of `os_poll`: its results are the packets of
kind 32 to 36 the router keeps in one queue per kind, so two seams never take each other's results.

What a backend adds over the host: it checks the arguments the seam's contract names before the import is called, so a
bad call returns the same DEV_* code on the web as on MemoryHaptics, MemoryCamera and the others."""
from std.ffi import external_call
from os_router import OsRouter
from platform.camera import Camera, MAX_CAMERA_DIM
from platform.device import (
    AVAIL_DENIED,
    AVAIL_UNSUPPORTED,
    DEV_NOT_GRANTED,
    DEV_CAMERA,
    DEV_HAPTICS,
    DEV_INVALID,
    DEV_MICROPHONE,
    DEV_MOTION,
    DEV_UNSUPPORTED,
    DEV_POINTER_LOCK,
    DEV_SCREEN,
    KIND_DEV_CAMERA,
    KIND_DEV_MIC,
    KIND_DEV_POINTER,
    KIND_DEV_SCREEN,
)
from platform.haptics import HAP_RUMBLE, HAP_VIBRATE, Haptics, MAX_PADS, MAX_VIBRATE_MS, pattern_ok
from platform.microphone import MIC_MAX_RATE, MIC_MIN_RATE, Microphone
from platform.motion import Motion
from platform.pointer_lock import PointerLock
from platform.screen import ORIENT_ANY, ORIENT_PORTRAIT, SCREEN_ORIENT_LOCK, Screen, op_cap


def os_dev_state(dev: Int) -> Int:
    return Int(external_call["os_dev_state", Int32](Int32(dev)))


def os_dev_caps(dev: Int) -> Int:
    return Int(external_call["os_dev_caps", Int32](Int32(dev)))


def os_dev_permission_request(dev: Int, id: Int) -> Int:
    return Int(external_call["os_dev_permission_request", Int32](Int32(dev), Int32(id)))


def os_dev_vibrate(ptr: UInt64, count: Int) -> Int:
    return Int(external_call["os_dev_vibrate", Int32](ptr, Int32(count)))


def os_dev_rumble(pad: Int, strong: Int, weak: Int, ms: Int) -> Int:
    return Int(external_call["os_dev_rumble", Int32](Int32(pad), Int32(strong), Int32(weak), Int32(ms)))


def os_dev_motion_start() -> Int:
    return Int(external_call["os_dev_motion_start", Int32]())


def os_dev_motion_stop() -> Int:
    return Int(external_call["os_dev_motion_stop", Int32]())


def os_dev_motion_read(ptr: UInt64) -> Int:
    return Int(external_call["os_dev_motion_read", Int32](ptr))


def os_dev_screen_request(id: Int, op: Int, arg: Int) -> Int:
    return Int(external_call["os_dev_screen_request", Int32](Int32(id), Int32(op), Int32(arg)))


def os_dev_screen_state() -> Int:
    return Int(external_call["os_dev_screen_state", Int32]())


def os_dev_pointer_request(id: Int, on: Bool) -> Int:
    return Int(external_call["os_dev_pointer_request", Int32](Int32(id), Int32(1 if on else 0)))


def os_dev_pointer_delta(ptr: UInt64) -> Int:
    return Int(external_call["os_dev_pointer_delta", Int32](ptr))


def os_dev_camera_open(id: Int, w: Int, h: Int) -> Int:
    return Int(external_call["os_dev_camera_open", Int32](Int32(id), Int32(w), Int32(h)))


def os_dev_camera_close() -> Int:
    return Int(external_call["os_dev_camera_close", Int32]())


def os_dev_camera_size() -> Int:
    return Int(external_call["os_dev_camera_size", Int32]())


def os_dev_camera_skipped() -> Int:
    return Int(external_call["os_dev_camera_skipped", Int32]())


def os_dev_pointer_locked() -> Int:
    return Int(external_call["os_dev_pointer_locked", Int32]())


def os_dev_camera_frame(ptr: UInt64, cap: Int) -> Int:
    return Int(external_call["os_dev_camera_frame", Int64](ptr, Int64(cap)))


def os_dev_mic_open(id: Int, rate: Int) -> Int:
    return Int(external_call["os_dev_mic_open", Int32](Int32(id), Int32(rate)))


def os_dev_mic_close() -> Int:
    return Int(external_call["os_dev_mic_close", Int32]())


def os_dev_mic_rate() -> Int:
    return Int(external_call["os_dev_mic_rate", Int32]())


def os_dev_mic_overruns() -> Int:
    return Int(external_call["os_dev_mic_overruns", Int64]())


def os_dev_mic_read(ptr: UInt64, max_samples: Int) -> Int:
    return Int(external_call["os_dev_mic_read", Int32](ptr, Int32(max_samples)))


struct WebHaptics(Haptics):
    var _router: OsRouter

    def __init__(out self, router: OsRouter):
        self._router = router

    def availability(self) -> Int:
        return os_dev_state(DEV_HAPTICS)

    def capabilities(self) -> Int:
        return os_dev_caps(DEV_HAPTICS)

    def request_permission(mut self, id: Int) -> Int:
        return os_dev_permission_request(DEV_HAPTICS, id)

    def vibrate(mut self, ms: Int) -> Int:
        if self.capabilities() & HAP_VIBRATE == 0:
            return DEV_UNSUPPORTED
        if ms < 1 or ms > MAX_VIBRATE_MS:
            return DEV_INVALID
        var entry = List[UInt8](length=2, fill=0)
        entry[0] = UInt8(ms & 255)
        entry[1] = UInt8((ms >> 8) & 255)
        var rc = os_dev_vibrate(UInt64(Int(entry.unsafe_ptr())), 1)
        _ = len(entry)
        return rc

    def vibrate_pattern(mut self, ptr: UInt64, count: Int) -> Int:
        if self.capabilities() & HAP_VIBRATE == 0:
            return DEV_UNSUPPORTED
        if not pattern_ok(ptr, count):
            return DEV_INVALID
        return os_dev_vibrate(ptr, count)

    def rumble(mut self, pad: Int, strong: Int, weak: Int, ms: Int) -> Int:
        if self.capabilities() & HAP_RUMBLE == 0:
            return DEV_UNSUPPORTED
        if pad < 0 or pad >= MAX_PADS or strong < 0 or strong > 255 or weak < 0 or weak > 255 or ms < 1 or ms > MAX_VIBRATE_MS:
            return DEV_INVALID
        return os_dev_rumble(pad, strong, weak, ms)

    def cancel(mut self) -> Int:
        if self.capabilities() == 0:
            return DEV_UNSUPPORTED
        return os_dev_vibrate(0, 0)

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        return self._router.take_permission(DEV_HAPTICS, buf, cap)

    def dropped(self) -> Int:
        return self._router.device_dropped()


struct WebMotion(Motion):
    var _router: OsRouter

    def __init__(out self, router: OsRouter):
        self._router = router

    def availability(self) -> Int:
        return os_dev_state(DEV_MOTION)

    def capabilities(self) -> Int:
        return os_dev_caps(DEV_MOTION)

    def request_permission(mut self, id: Int) -> Int:
        return os_dev_permission_request(DEV_MOTION, id)

    def start(mut self) -> Int:
        return os_dev_motion_start()

    def stop(mut self):
        _ = os_dev_motion_stop()

    def read(mut self, ptr: UInt64) -> Int:
        return os_dev_motion_read(ptr)

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        return self._router.take_permission(DEV_MOTION, buf, cap)

    def dropped(self) -> Int:
        return self._router.device_dropped()


struct WebScreen(Screen):
    var _router: OsRouter

    def __init__(out self, router: OsRouter):
        self._router = router

    def availability(self) -> Int:
        return os_dev_state(DEV_SCREEN)

    def capabilities(self) -> Int:
        return os_dev_caps(DEV_SCREEN)

    def request(mut self, id: Int, op: Int, arg: Int) -> Int:
        var need = op_cap(op)
        if need == 0 or (op == SCREEN_ORIENT_LOCK and (arg < ORIENT_PORTRAIT or arg > ORIENT_ANY)):
            return DEV_INVALID
        if self.capabilities() & need == 0:
            return DEV_UNSUPPORTED
        return os_dev_screen_request(id, op, arg)

    def state(self) -> Int:
        return os_dev_screen_state()

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        return self._router.take_device(KIND_DEV_SCREEN, buf, cap)

    def dropped(self) -> Int:
        return self._router.device_dropped()


struct WebPointerLock(PointerLock):
    var _router: OsRouter

    def __init__(out self, router: OsRouter):
        self._router = router

    def availability(self) -> Int:
        return os_dev_state(DEV_POINTER_LOCK)

    def request(mut self, id: Int, on: Bool) -> Int:
        return os_dev_pointer_request(id, on)

    def locked(self) -> Bool:
        return os_dev_pointer_locked() == 1

    def take_delta(mut self, ptr: UInt64) -> Int:
        return os_dev_pointer_delta(ptr)

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        return self._router.take_device(KIND_DEV_POINTER, buf, cap)

    def dropped(self) -> Int:
        return self._router.device_dropped()


struct WebCamera(Camera):
    var _router: OsRouter

    def __init__(out self, router: OsRouter):
        self._router = router

    def availability(self) -> Int:
        return os_dev_state(DEV_CAMERA)

    def request_permission(mut self, id: Int) -> Int:
        return os_dev_permission_request(DEV_CAMERA, id)

    def open(mut self, id: Int, width: Int, height: Int) -> Int:
        var state = os_dev_state(DEV_CAMERA)
        if state == AVAIL_UNSUPPORTED:
            return DEV_UNSUPPORTED
        if state == AVAIL_DENIED:
            return DEV_NOT_GRANTED
        if width < 1 or width > MAX_CAMERA_DIM or height < 1 or height > MAX_CAMERA_DIM:
            return DEV_INVALID
        return os_dev_camera_open(id, width, height)

    def close(mut self):
        _ = os_dev_camera_close()

    def is_open(self) -> Bool:
        return os_dev_camera_size() != 0

    def frame_width(self) -> Int:
        return os_dev_camera_size() >> 16

    def frame_height(self) -> Int:
        return os_dev_camera_size() & 0xFFFF

    def read_frame(mut self, buf: UInt64, cap: Int) -> Int:
        return os_dev_camera_frame(buf, cap)

    def skipped(self) -> Int:
        return os_dev_camera_skipped()

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        var n = self._router.take_device(KIND_DEV_CAMERA, buf, cap)
        return n if n != 0 else self._router.take_permission(DEV_CAMERA, buf, cap)

    def dropped(self) -> Int:
        return self._router.device_dropped()


struct WebMicrophone(Microphone):
    var _router: OsRouter

    def __init__(out self, router: OsRouter):
        self._router = router

    def availability(self) -> Int:
        return os_dev_state(DEV_MICROPHONE)

    def request_permission(mut self, id: Int) -> Int:
        return os_dev_permission_request(DEV_MICROPHONE, id)

    def open(mut self, id: Int, sample_rate: Int) -> Int:
        var state = os_dev_state(DEV_MICROPHONE)
        if state == AVAIL_UNSUPPORTED:
            return DEV_UNSUPPORTED
        if state == AVAIL_DENIED:
            return DEV_NOT_GRANTED
        if sample_rate < MIC_MIN_RATE or sample_rate > MIC_MAX_RATE:
            return DEV_INVALID
        return os_dev_mic_open(id, sample_rate)

    def close(mut self):
        _ = os_dev_mic_close()

    def is_open(self) -> Bool:
        return os_dev_mic_rate() != 0

    def sample_rate(self) -> Int:
        return os_dev_mic_rate()

    def read(mut self, buf: UInt64, max_samples: Int) -> Int:
        return os_dev_mic_read(buf, max_samples)

    def overruns(self) -> Int:
        return os_dev_mic_overruns()

    def poll(mut self, buf: UInt64, cap: Int) -> Int:
        var n = self._router.take_device(KIND_DEV_MIC, buf, cap)
        return n if n != 0 else self._router.take_permission(DEV_MICROPHONE, buf, cap)

    def dropped(self) -> Int:
        return self._router.device_dropped()
