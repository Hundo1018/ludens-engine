"""The shell's input path with the real device struct: events into wgpu's `InputState`, `app/controls.read_frame` into
`InputFrame`, `game/controls` into an `Intent`, frame by frame as `App.frame` does it. Native only: `pixi run -e wasm test-game`."""
from controls import read_frame
from game.controls import Controls
from game.intent import Intent
from wgpu.rendercanvas.glfw import MojoInputEvent
from wgpu.rendercanvas.input import InputState

comptime KEY: Int32 = 1
comptime BUTTON: Int32 = 2
comptime CURSOR: Int32 = 3
comptime UP: Int32 = 0
comptime DOWN: Int32 = 1
comptime AXIS: Int32 = 5


struct Check:
    var passed: Int
    var failed: Int

    def __init__(out self):
        self.passed = 0
        self.failed = 0

    def ok(mut self, cond: Bool, label: String):
        if cond:
            self.passed += 1
            print("  [PASS]", label)
        else:
            self.failed += 1
            print("  [FAIL]", label)


def frame(mut ctl: Controls, mut input: InputState) -> Intent:
    """One app frame: read the intent, then end the frame."""
    var i = ctl.poll(read_frame(input))
    input.begin_frame()
    return i


def main() raises:
    var c = Check()
    var input = InputState()
    var ctl = Controls()

    input.process_event(MojoInputEvent(KEY, 87, DOWN, 0, 0.0, 0.0))  # W
    input.process_event(MojoInputEvent(KEY, 262, DOWN, 0, 0.0, 0.0))  # arrow right
    var i = frame(ctl, input)
    c.ok(i.forward == 1 and i.right == 1, "W and the right arrow: forward and right")
    i = frame(ctl, input)
    c.ok(i.forward == 1 and i.right == 1, "held keys stay held on the next frame")

    input.process_event(MojoInputEvent(KEY, 32, DOWN, 0, 0.0, 0.0))  # Space
    i = frame(ctl, input)
    var again = frame(ctl, input)
    c.ok(i.jump and not again.jump, "Space is one jump, on one frame, while it stays held")
    input.process_event(MojoInputEvent(KEY, 32, DOWN, 0, 0.0, 0.0))
    input.process_event(MojoInputEvent(KEY, 32, UP, 0, 0.0, 0.0))
    i = frame(ctl, input)
    c.ok(i.jump, "a press and release inside one frame still jumps (a touch tap)")

    input.process_event(MojoInputEvent(KEY, 256, DOWN, 0, 0.0, 0.0))  # Esc
    input.process_event(MojoInputEvent(KEY, 82, DOWN, 0, 0.0, 0.0))  # R
    i = frame(ctl, input)
    c.ok(i.pause and i.restart, "Esc pauses, R restarts")

    # the pointer: its first event places it, a drag with the left button turns the camera
    input.process_event(MojoInputEvent(BUTTON, 0, DOWN, 0, 500.0, 300.0))
    input.process_event(MojoInputEvent(CURSOR, 0, 0, 0, 500.0, 300.0))
    i = frame(ctl, input)
    c.ok(i.look_dx == 0 and i.look_dy == 0, "the pointer's first event is not a camera turn")
    input.process_event(MojoInputEvent(CURSOR, 0, 0, 0, 503.0, 300.0))
    _ = frame(ctl, input)
    input.process_event(MojoInputEvent(CURSOR, 0, 0, 0, 515.0, 296.0))
    i = frame(ctl, input)
    c.ok(i.look_dx == 12 and i.look_dy == -4, "a drag with the left button held turns the camera by its pixels")
    input.process_event(MojoInputEvent(BUTTON, 0, UP, 0, 515.0, 296.0))
    input.process_event(MojoInputEvent(CURSOR, 0, 0, 0, 600.0, 296.0))
    i = frame(ctl, input)
    c.ok(i.look_dx == 0, "moving the pointer with no button held does not")

    # a gamepad: AXIS events (device 0, left stick) and button 0 as key code 400 (PAD_BUTTON_BASE)
    input.process_event(MojoInputEvent(KEY, 87, UP, 0, 0.0, 0.0))  # let go of W and the right arrow from above
    input.process_event(MojoInputEvent(KEY, 262, UP, 0, 0.0, 0.0))
    input.process_event(MojoInputEvent(AXIS, 0, 0, 0, 0.6, 0.0))
    i = frame(ctl, input)
    c.ok(abs(Float64(i.right) - 0.5) < 1.0e-6 and i.forward == 0, "AXIS events: stick x = 0.6 gives right 0.5 ((0.6 - 0.2) / 0.8, dead zone 0.2)")
    input.process_event(MojoInputEvent(AXIS, 0, 0, 0, 0.0, 0.0))
    input.process_event(MojoInputEvent(AXIS, 1, 0, 0, -1.0, 0.0))
    i = frame(ctl, input)
    c.ok(i.right == 0 and abs(Float64(i.forward) - 1.0) < 1.0e-6, "stick up (y = -1) is forward 1")
    input.process_event(MojoInputEvent(AXIS, 1, 0, 0, 0.0, 0.0))
    input.process_event(MojoInputEvent(KEY, 400, DOWN, 0, 0.0, 0.0))  # gamepad 0, button 0
    i = frame(ctl, input)
    c.ok(i.jump, "a gamepad button sent as key code 400 jumps")
    input.process_event(MojoInputEvent(KEY, 400, UP, 0, 0.0, 0.0))
    input.process_event(MojoInputEvent(AXIS, 0, 3, 0, -1.0, 0.0))  # axis 0 of device 3, the on-screen pad
    i = frame(ctl, input)
    c.ok(i.right == -1, "the on-screen pad's stick (device 3) moves left")
    input.process_event(MojoInputEvent(AXIS, 0, 3, 0, 0.0, 0.0))

    # focus is lost while W is held: the key-up never arrives
    input.release_all()
    i = frame(ctl, input)
    c.ok(i.forward == 0 and i.right == 0 and not i.jump, "after a focus loss nothing is held")

    print("input_path:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("input_path: " + String(c.failed) + " checks failed")
