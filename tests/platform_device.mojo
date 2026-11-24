"""The device seams (docs/platform.md, "Device seams") through their in-memory backends: Haptics, Motion, Screen,
PointerLock, Camera, Microphone. Each check names a rule of the contract the web backend (app/os_device.mojo, tested in
tests/test_device.mjs) has to follow too: argument limits and their order, permission states and their result packets,
reads that return 0 when nothing is new, the drop-and-count rules, one-shot user activation.

Standard library only: `pixi run -e wasm test-transport` builds and runs it with the other platform tests."""
from platform.camera import MAX_CAMERA_DIM, MemoryCamera
from platform.device import (
    AVAIL_DENIED,
    AVAIL_GRANTED,
    AVAIL_PROMPT,
    AVAIL_UNSUPPORTED,
    DEV_BUSY,
    DEV_CAMERA,
    DEV_INVALID,
    DEV_MICROPHONE,
    DEV_MOTION,
    DEV_NOT_GRANTED,
    DEV_OK,
    DEV_UNSUPPORTED,
    KIND_DEV_CAMERA,
    KIND_DEV_MIC,
    KIND_DEV_PERMISSION,
    KIND_DEV_POINTER,
    KIND_DEV_SCREEN,
    read_f32,
    write_f32,
)
from platform.haptics import HAP_RUMBLE, HAP_VIBRATE, MAX_PATTERN, MAX_VIBRATE_MS, MemoryHaptics
from platform.microphone import MemoryMicrophone
from platform.motion import MOTION_ACCEL, MOTION_GYRO, MOTION_ORIENT, MemoryMotion
from platform.packets import PACKET_HEADER, REQ_INVALID, REQ_QUEUED, STATUS_ERROR, STATUS_OK
from platform.pointer_lock import MemoryPointerLock
from platform.screen import (
    MemoryScreen,
    ORIENT_ANY,
    ORIENT_LANDSCAPE,
    SCREEN_CAP_FULLSCREEN,
    SCREEN_CAP_WAKE,
    SCREEN_F_FULLSCREEN,
    SCREEN_F_ORIENT,
    SCREEN_F_WAKE,
    SCREEN_FULLSCREEN_ENTER,
    SCREEN_FULLSCREEN_EXIT,
    SCREEN_ORIENT_LOCK,
    SCREEN_ORIENT_UNLOCK,
    SCREEN_WAKE_OFF,
    SCREEN_WAKE_ON,
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


struct Pkt(Copyable, Movable):
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

    def u32_at(self, at: Int) -> Int:
        return Int(self.payload[at]) | (Int(self.payload[at + 1]) << 8) | (Int(self.payload[at + 2]) << 16) | (Int(self.payload[at + 3]) << 24)

    def is_(self, kind: Int, id: Int, status: Int) -> Bool:
        return self.kind == kind and self.id == id and self.status == status


def addr(mut b: List[UInt8]) -> UInt64:
    return UInt64(Int(b.unsafe_ptr()))


def u16s(values: List[Int]) -> List[UInt8]:
    var out = List[UInt8]()
    for v in values:
        out.append(UInt8(v & 255))
        out.append(UInt8((v >> 8) & 255))
    return out^


def test_haptics(mut c: Check):
    print("Haptics")
    var h = MemoryHaptics()
    c.check(h.availability() == AVAIL_GRANTED and h.capabilities() == (HAP_VIBRATE | HAP_RUMBLE), "phone with a gamepad: granted, vibrate and rumble")
    c.check(h.vibrate(50) == DEV_OK and len(h.pattern) == 1 and h.pattern[0] == 50 and h.vibrations == 1, "vibrate(50) is a one-entry pattern [50]")
    c.check(h.vibrate(0) == DEV_INVALID and h.vibrate(MAX_VIBRATE_MS + 1) == DEV_INVALID and h.vibrate(-3) == DEV_INVALID, "vibrate(0), vibrate(5001), vibrate(-3) are DEV_INVALID")
    c.check(h.vibrate(MAX_VIBRATE_MS) == DEV_OK, "vibrate(5000) is the longest allowed")
    var p = u16s([100, 50, 200])
    c.check(h.vibrate_pattern(addr(p), 3) == DEV_OK and len(h.pattern) == 3 and h.pattern[0] == 100 and h.pattern[1] == 50 and h.pattern[2] == 200, "a pattern of 100 on, 50 off, 200 on is recorded in order")
    var big = u16s([10, 6000])
    c.check(h.vibrate_pattern(addr(big), 2) == DEV_INVALID and len(h.pattern) == 3, "a pattern entry over 5000 is DEV_INVALID and the last pattern stays")
    c.check(h.vibrate_pattern(addr(p), 0) == DEV_INVALID, "a pattern of 0 entries is DEV_INVALID")
    var long = List[UInt8](length=2 * (MAX_PATTERN + 1), fill=0)
    c.check(h.vibrate_pattern(addr(long), MAX_PATTERN) == DEV_OK and h.vibrate_pattern(addr(long), MAX_PATTERN + 1) == DEV_INVALID, "32 entries pass, 33 are DEV_INVALID")
    c.check(h.rumble(1, 255, 128, 300) == DEV_OK and h.last_rumble[0] == 1 and h.last_rumble[1] == 255 and h.last_rumble[2] == 128 and h.last_rumble[3] == 300 and h.rumbles == 1, "rumble(pad 1, strong 255, weak 128, 300 ms) is recorded")
    c.check(h.rumble(4, 0, 0, 10) == DEV_INVALID and h.rumble(0, 256, 0, 10) == DEV_INVALID and h.rumble(0, 0, -1, 10) == DEV_INVALID and h.rumble(0, 0, 0, 0) == DEV_INVALID, "pad 4, strong 256, weak -1, 0 ms are DEV_INVALID")
    c.check(h.rumbles == 1, "the refused rumbles were not recorded")
    c.check(h.cancel() == DEV_OK and len(h.pattern) == 0 and h.cancels == 1, "cancel clears the pattern")
    var phone = MemoryHaptics(HAP_VIBRATE)
    c.check(phone.rumble(0, 1, 1, 10) == DEV_UNSUPPORTED and phone.vibrate(10) == DEV_OK, "a phone without a gamepad: rumble is DEV_UNSUPPORTED, vibrate works")
    var ios = MemoryHaptics(HAP_RUMBLE)
    c.check(ios.vibrate(10) == DEV_UNSUPPORTED and ios.vibrate_pattern(addr(p), 3) == DEV_UNSUPPORTED and ios.rumble(0, 1, 1, 10) == DEV_OK, "iOS Safari (no navigator.vibrate): vibrate is DEV_UNSUPPORTED")
    c.check(ios.vibrate(0) == DEV_UNSUPPORTED, "unsupported is reported before a bad argument")
    var none = MemoryHaptics(0)
    c.check(none.availability() == AVAIL_UNSUPPORTED and none.cancel() == DEV_UNSUPPORTED and none.rumble(0, 1, 1, 10) == DEV_UNSUPPORTED, "no haptics at all: AVAIL_UNSUPPORTED, every call DEV_UNSUPPORTED")
    _ = len(p)
    _ = len(big)
    _ = len(long)


def test_motion(mut c: Check):
    print("Motion")
    var buf = List[UInt8](length=64, fill=0)
    var a = addr(buf)
    for i in range(9):
        write_f32(a, i, Float32(-99))
    var m = MemoryMotion()
    c.check(m.start() == DEV_OK, "start with the permission granted")
    var s = List[Float32]()
    for i in range(9):
        s.append(Float32(i + 1) * 0.5)
    m.feed(s)
    c.check(m.read(a) == 1 and read_f32(a, 0) == 0.5 and read_f32(a, 4) == 2.5 and read_f32(a, 8) == 4.5, "read returns sequence 1 and 9 f32: accel, rate, orientation")
    write_f32(a, 0, Float32(-99))
    c.check(m.read(a) == 0 and read_f32(a, 0) == -99, "a second read with no new sample returns 0 and leaves the buffer alone")
    m.feed(s)
    s[0] = 7
    m.feed(s)
    c.check(m.read(a) == 3 and read_f32(a, 0) == 7, "two samples between reads: the newest is returned, sequence 3")
    m.feed(s)
    m.stop()
    m.feed(s)
    c.check(m.read(a) == 0, "a stopped sensor delivers nothing")
    c.check(m.start() == DEV_OK and m.read(a) == 0, "restarting does not return a sample that was unread when it stopped")
    var gyro_only = MemoryMotion(MOTION_GYRO)
    _ = gyro_only.start()
    gyro_only.feed(s)
    _ = gyro_only.read(a)
    c.check(read_f32(a, 0) == 0 and read_f32(a, 3) == 2 and read_f32(a, 6) == 0, "a device with only a gyroscope reports 0 for the other groups")
    c.check(gyro_only.capabilities() == MOTION_GYRO and (MOTION_ACCEL | MOTION_ORIENT) != 0, "capabilities names the groups present")

    var ios = MemoryMotion(MOTION_ACCEL | MOTION_GYRO | MOTION_ORIENT, AVAIL_PROMPT, True)
    c.check(ios.availability() == AVAIL_PROMPT and ios.start() == DEV_NOT_GRANTED, "iOS: AVAIL_PROMPT, start() before the permission is DEV_NOT_GRANTED (it never prompts)")
    c.check(ios.request_permission(7) == REQ_QUEUED and ios.availability() == AVAIL_GRANTED, "the request is answered: granted")
    var rx = List[UInt8](length=32, fill=0)
    var p = Pkt(ios.poll(addr(rx), 32), rx)
    c.check(p.is_(KIND_DEV_PERMISSION, 7, STATUS_OK) and len(p.payload) == 2 and Int(p.payload[0]) == DEV_MOTION and Int(p.payload[1]) == AVAIL_GRANTED, "result: KIND_DEV_PERMISSION, id 7, OK, payload [motion, granted]")
    c.check(ios.start() == DEV_OK, "start works after the grant")
    var deny = MemoryMotion(MOTION_ACCEL, AVAIL_PROMPT, False)
    _ = deny.request_permission(8)
    p = Pkt(deny.poll(addr(rx), 32), rx)
    c.check(p.is_(KIND_DEV_PERMISSION, 8, STATUS_ERROR) and Int(p.payload[1]) == AVAIL_DENIED, "denied: STATUS_ERROR, payload says AVAIL_DENIED")
    c.check(deny.start() == DEV_NOT_GRANTED and deny.gate.asked == 1, "start after a denial is DEV_NOT_GRANTED")
    _ = deny.request_permission(9)
    c.check(deny.gate.asked == 1, "a second request does not ask the user again")
    var none = MemoryMotion(0)
    c.check(none.availability() == AVAIL_UNSUPPORTED and none.start() == DEV_UNSUPPORTED, "no sensors (or an insecure page): AVAIL_UNSUPPORTED, start is DEV_UNSUPPORTED")
    _ = len(buf)
    _ = len(rx)


def test_screen(mut c: Check):
    print("Screen")
    var s = MemoryScreen()
    var rx = List[UInt8](length=32, fill=0)
    c.check(s.request(1, SCREEN_FULLSCREEN_ENTER, 0) == REQ_QUEUED, "a fullscreen request is queued")
    var p = Pkt(s.poll(addr(rx), 32), rx)
    c.check(p.is_(KIND_DEV_SCREEN, 1, STATUS_ERROR) and s.state() == 0, "without a tap the browser refuses fullscreen: STATUS_ERROR, state unchanged")
    s.grant_activation()
    _ = s.request(2, SCREEN_FULLSCREEN_ENTER, 0)
    p = Pkt(s.poll(addr(rx), 32), rx)
    c.check(p.is_(KIND_DEV_SCREEN, 2, STATUS_OK) and Int(p.payload[0]) == SCREEN_FULLSCREEN_ENTER and Int(p.payload[1]) == SCREEN_F_FULLSCREEN, "after a tap: OK, payload [op, flags = fullscreen]")
    _ = s.request(3, SCREEN_FULLSCREEN_ENTER, 0)
    p = Pkt(s.poll(addr(rx), 32), rx)
    c.check(p.status == STATUS_ERROR, "the tap was used up by the first entry")
    _ = s.request(4, SCREEN_ORIENT_LOCK, ORIENT_LANDSCAPE)
    p = Pkt(s.poll(addr(rx), 32), rx)
    c.check(p.is_(KIND_DEV_SCREEN, 4, STATUS_OK) and s.state() == (SCREEN_F_FULLSCREEN | SCREEN_F_ORIENT) and s.orientation == ORIENT_LANDSCAPE, "orientation lock while fullscreen: OK, landscape")
    _ = s.request(5, SCREEN_WAKE_ON, 0)
    c.check(s.state() == (SCREEN_F_FULLSCREEN | SCREEN_F_ORIENT | SCREEN_F_WAKE), "wake lock adds its flag")
    _ = s.request(6, SCREEN_FULLSCREEN_EXIT, 0)
    c.check(s.state() == SCREEN_F_WAKE and s.orientation == 0, "leaving fullscreen releases the orientation lock and keeps the wake lock")
    var q = MemoryScreen()
    _ = q.request(1, SCREEN_ORIENT_LOCK, ORIENT_ANY)
    p = Pkt(q.poll(addr(rx), 32), rx)
    c.check(p.status == STATUS_ERROR and q.state() == 0, "orientation lock outside fullscreen is refused")
    q.grant_activation()
    _ = q.request(2, SCREEN_FULLSCREEN_ENTER, 0)
    _ = q.request(3, SCREEN_ORIENT_LOCK, ORIENT_ANY)
    _ = q.request(4, SCREEN_ORIENT_UNLOCK, 0)
    c.check(q.state() == SCREEN_F_FULLSCREEN, "unlock clears the orientation flag only")
    _ = q.request(5, SCREEN_WAKE_ON, 0)
    _ = q.request(6, SCREEN_WAKE_OFF, 0)
    c.check((q.state() & SCREEN_F_WAKE) == 0, "wake off clears the wake flag")
    c.check(q.request(7, 0, 0) == DEV_INVALID and q.request(7, 7, 0) == DEV_INVALID and q.request(7, SCREEN_ORIENT_LOCK, 0) == DEV_INVALID and q.request(7, SCREEN_ORIENT_LOCK, 4) == DEV_INVALID, "op 0, op 7, orientation 0 and 4 are DEV_INVALID")
    var drained = 0
    while q.poll(addr(rx), 32) > 0:
        drained += 1
    c.check(drained == 5, "requests 2 to 6 queued 5 results; the four DEV_INVALID requests queued none")
    var nowake = MemoryScreen(SCREEN_CAP_FULLSCREEN)
    c.check(nowake.request(1, SCREEN_WAKE_ON, 0) == DEV_UNSUPPORTED and nowake.poll(addr(rx), 32) == 0, "an op the platform lacks is DEV_UNSUPPORTED and queues nothing")
    var tiny = MemoryScreen(SCREEN_CAP_WAKE)
    c.check(tiny.request(1, SCREEN_FULLSCREEN_ENTER, 0) == DEV_UNSUPPORTED and tiny.availability() == AVAIL_GRANTED and MemoryScreen(0).availability() == AVAIL_UNSUPPORTED, "capabilities decide availability")
    var small = MemoryScreen()
    _ = small.request(77, SCREEN_WAKE_ON, 0)
    var tiny_buf = List[UInt8](length=4, fill=0)
    c.check(small.poll(addr(tiny_buf), 4) == -1 and small.dropped() == 1 and small.poll(addr(rx), 32) == 0, "a result larger than cap is -1 once and counted")
    _ = len(rx)
    _ = len(tiny_buf)


def test_pointer_lock(mut c: Check):
    print("PointerLock")
    var p = MemoryPointerLock()
    var rx = List[UInt8](length=32, fill=0)
    var d = List[UInt8](length=8, fill=0)
    p.inject(5, 5)
    c.check(not p.locked() and p.take_delta(addr(d)) == 0, "unlocked: movement is ignored, take_delta returns 0")
    _ = p.request(1, True)
    var k = Pkt(p.poll(addr(rx), 32), rx)
    c.check(k.is_(KIND_DEV_POINTER, 1, STATUS_ERROR) and Int(k.payload[0]) == 0 and not p.locked(), "a lock request without a tap is refused")
    p.grant_activation()
    _ = p.request(2, True)
    k = Pkt(p.poll(addr(rx), 32), rx)
    c.check(k.is_(KIND_DEV_POINTER, 2, STATUS_OK) and Int(k.payload[0]) == 1 and p.locked(), "after a tap: locked, payload 1")
    p.inject(3, -2)
    p.inject(4, 1)
    c.check(p.take_delta(addr(d)) == 1 and read_f32(addr(d), 0) == 7 and read_f32(addr(d), 1) == -1, "deltas add up: (3, -2) + (4, 1) = (7, -1)")
    c.check(p.take_delta(addr(d)) == 1 and read_f32(addr(d), 0) == 0 and read_f32(addr(d), 1) == 0, "and are cleared by the read")
    p.inject(9, 9)
    p.platform_release()
    k = Pkt(p.poll(addr(rx), 32), rx)
    c.check(k.is_(KIND_DEV_POINTER, 0, STATUS_OK) and Int(k.payload[0]) == 0 and not p.locked(), "Esc: an id-0 packet with locked 0")
    p.grant_activation()
    _ = p.request(3, True)
    _ = p.poll(addr(rx), 32)
    c.check(p.take_delta(addr(d)) == 1 and read_f32(addr(d), 0) == 0, "movement from before the release is not delivered after a new lock")
    _ = p.request(4, False)
    k = Pkt(p.poll(addr(rx), 32), rx)
    c.check(k.is_(KIND_DEV_POINTER, 4, STATUS_OK) and Int(k.payload[0]) == 0 and not p.locked(), "an explicit release")
    var none = MemoryPointerLock(False)
    c.check(none.availability() == AVAIL_UNSUPPORTED and none.request(1, True) == DEV_UNSUPPORTED, "no Pointer Lock API: DEV_UNSUPPORTED")
    _ = len(rx)
    _ = len(d)


def test_camera(mut c: Check):
    print("Camera")
    var cam = MemoryCamera(AVAIL_PROMPT)
    var rx = List[UInt8](length=64, fill=0)
    c.check(cam.availability() == AVAIL_PROMPT and cam.open(1, 0, 480) == DEV_INVALID and cam.open(1, 640, MAX_CAMERA_DIM + 1) == DEV_INVALID, "a size of 0 or over 4096 is DEV_INVALID before any prompt")
    c.check(cam.gate.asked == 0, "an invalid open does not show the prompt")
    c.check(cam.open(1, 1920, 1080) == REQ_QUEUED and cam.is_open(), "open(1920 x 1080) is queued")
    var p = Pkt(cam.poll(addr(rx), 64), rx)
    c.check(p.is_(KIND_DEV_CAMERA, 1, STATUS_OK) and len(p.payload) == 8 and p.u32_at(0) == 1280 and p.u32_at(4) == 720, "the result is the size the camera gave: 1280 x 720")
    c.check(cam.frame_width() == 1280 and cam.frame_height() == 720 and cam.gate.asked == 1 and cam.availability() == AVAIL_GRANTED, "frame size, one prompt, state granted")
    c.check(cam.open(2, 640, 480) == DEV_BUSY, "a second open is DEV_BUSY")
    cam.close()
    c.check(cam.open(3, 4, 3) == REQ_QUEUED and cam.gate.asked == 1, "open after close: no second prompt")
    _ = cam.poll(addr(rx), 64)
    var frame = List[UInt8](length=4 * 3 * 4 + 8, fill=7)
    var f = addr(frame)
    c.check(cam.read_frame(f, len(frame)) == 0, "no frame yet: 0")
    cam.push_frame(9)
    c.check(cam.read_frame(f, 47) == -1 and Int(frame[0]) == 7, "a buffer of 47 bytes for a 48-byte frame: -1 and nothing written")
    c.check(cam.read_frame(f, len(frame)) == 48, "the frame stayed; a big enough buffer takes it: 48 bytes")
    # pixel (x=2, y=1) at offset (1 * 4 + 2) * 4 = 24: (2 + 9, 1 + 18, 3, 255)
    c.check(Int(frame[24]) == 11 and Int(frame[25]) == 19 and Int(frame[26]) == 3 and Int(frame[27]) == 255 and Int(frame[48]) == 7, "pixel (2, 1) is RGBA (11, 19, 3, 255); nothing past the frame is written")
    c.check(cam.read_frame(f, len(frame)) == 0, "the same frame is not returned twice")
    cam.push_frame(1)
    cam.push_frame(2)
    cam.push_frame(3)
    c.check(cam.skipped() == 2 and cam.read_frame(f, len(frame)) == 48 and Int(frame[0]) == 3, "three frames between reads: the newest is read, 2 skipped")
    cam.close()
    cam.push_frame(5)
    c.check(not cam.is_open() and cam.read_frame(f, len(frame)) == 0 and cam.frame_width() == 0, "a closed camera reads 0")
    var denied = MemoryCamera(AVAIL_PROMPT, False)
    _ = denied.open(5, 640, 480)
    p = Pkt(denied.poll(addr(rx), 64), rx)
    c.check(p.is_(KIND_DEV_CAMERA, 5, STATUS_ERROR) and Int(p.payload[0]) == AVAIL_DENIED and not denied.is_open(), "the user says no: STATUS_ERROR with AVAIL_DENIED, camera stays closed")
    c.check(denied.open(6, 640, 480) == DEV_NOT_GRANTED and denied.poll(addr(rx), 64) == 0, "opening after a denial is DEV_NOT_GRANTED, without a prompt or packet")
    var none = MemoryCamera()
    c.check(none.availability() == AVAIL_UNSUPPORTED and none.open(1, 640, 480) == DEV_UNSUPPORTED, "no camera: DEV_UNSUPPORTED")
    c.check(none.open(1, 0, 480) == DEV_UNSUPPORTED and denied.open(1, 0, 480) == DEV_NOT_GRANTED, "unsupported and denied are reported before a bad size")
    var pre = MemoryCamera(AVAIL_PROMPT)
    _ = pre.request_permission(11)
    p = Pkt(pre.poll(addr(rx), 64), rx)
    c.check(p.is_(KIND_DEV_PERMISSION, 11, STATUS_OK) and Int(p.payload[0]) == DEV_CAMERA and pre.open(12, 640, 480) == REQ_QUEUED and pre.gate.asked == 1, "request_permission asks once; the later open does not ask again")
    _ = len(rx)
    _ = len(frame)


def test_microphone(mut c: Check):
    print("Microphone")
    var mic = MemoryMicrophone(AVAIL_PROMPT, True, 48000)
    var rx = List[UInt8](length=64, fill=0)
    c.check(mic.open(1, 7999) == DEV_INVALID and mic.open(1, 192001) == DEV_INVALID and mic.gate.asked == 0, "7999 Hz and 192001 Hz are DEV_INVALID, without a prompt")
    c.check(mic.open(1, 44100) == REQ_QUEUED, "open(44100)")
    var p = Pkt(mic.poll(addr(rx), 64), rx)
    c.check(p.is_(KIND_DEV_MIC, 1, STATUS_OK) and p.u32_at(0) == 48000 and mic.sample_rate() == 48000, "the device runs at 48000 Hz whatever was asked: the result says so")
    c.check(mic.open(2, 44100) == DEV_BUSY, "a second open is DEV_BUSY")
    var data = List[Float32]()
    for i in range(10):
        data.append(Float32(i) / 10)
    mic.push(data)
    var out = List[UInt8](length=4 * 16, fill=0)
    var o = addr(out)
    c.check(mic.read(o, 4) == 4 and read_f32(o, 0) == 0 and read_f32(o, 3) == Float32(3) / 10, "read(4) returns the 4 oldest samples")
    c.check(mic.read(o, 16) == 6 and read_f32(o, 0) == Float32(4) / 10 and read_f32(o, 5) == Float32(9) / 10, "the rest comes next, in order: 6 samples")
    c.check(mic.read(o, 16) == 0 and mic.read(o, 0) == 0, "an empty ring reads 0")
    var second = List[Float32](length=48000, fill=0.25)
    mic.push(second)
    var tail = List[Float32]()
    for i in range(100):
        tail.append(Float32(i + 1))
    mic.push(tail)
    c.check(mic.overruns() == 100, "100 samples over one second of ring: 100 oldest discarded and counted")
    var big = List[UInt8](length=4 * 48000, fill=0)
    c.check(mic.read(addr(big), 48000) == 48000 and read_f32(addr(big), 47999) == 100 and read_f32(addr(big), 47900) == 1 and read_f32(addr(big), 0) == 0.25, "what remains is the newest second: the last sample is 100.0")
    mic.close()
    mic.push(data)
    c.check(not mic.is_open() and mic.read(o, 4) == 0 and mic.sample_rate() == 0, "closed: nothing is kept or read")
    var denied = MemoryMicrophone(AVAIL_PROMPT, False)
    _ = denied.open(3, 16000)
    p = Pkt(denied.poll(addr(rx), 64), rx)
    c.check(p.is_(KIND_DEV_MIC, 3, STATUS_ERROR) and Int(p.payload[0]) == AVAIL_DENIED and denied.open(4, 16000) == DEV_NOT_GRANTED, "denied: STATUS_ERROR, and later opens are DEV_NOT_GRANTED")
    var nomic = MemoryMicrophone()
    c.check(nomic.open(1, 16000) == DEV_UNSUPPORTED and nomic.availability() == AVAIL_UNSUPPORTED, "no microphone: DEV_UNSUPPORTED")
    c.check(nomic.open(1, 1) == DEV_UNSUPPORTED and denied.open(1, 1) == DEV_NOT_GRANTED, "unsupported and denied are reported before a bad rate")
    var granted = MemoryMicrophone(AVAIL_GRANTED)
    _ = granted.open(1, 16000)
    c.check(granted.gate.asked == 0 and granted.sample_rate() == 16000, "already granted: no prompt, the asked rate is used")
    _ = len(rx)
    _ = len(out)
    _ = len(big)


def main() raises:
    var c = Check()
    test_haptics(c)
    test_motion(c)
    test_screen(c)
    test_pointer_lock(c)
    test_camera(c)
    test_microphone(c)
    print("platform_device: " + String(c.passed) + " passed, " + String(c.failed) + " failed")
    if c.failed > 0:
        raise Error("platform_device: " + String(c.failed) + " checks failed")
