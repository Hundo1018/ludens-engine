"""The shell's input path with the real device struct: events into wgpu's `InputState`, `app/controls.read_keys` into
`Keys`, `game/controls` into an `Intent`, frame by frame as `App.frame` does it. Native only: `pixi run -e wasm test-game`."""
from controls import read_keys
from game.controls import Controls
from game.intent import Intent
from wgpu.rendercanvas.glfw import MojoInputEvent
from wgpu.rendercanvas.input import InputState

comptime KEY: Int32 = 1
comptime BUTTON: Int32 = 2
comptime CURSOR: Int32 = 3
comptime UP: Int32 = 0
comptime DOWN: Int32 = 1


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
    var i = ctl.poll(read_keys(input))
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

    # focus is lost while W is held: the key-up never arrives
    input.release_all()
    i = frame(ctl, input)
    c.ok(i.forward == 0 and i.right == 0 and not i.jump, "after a focus loss nothing is held")

    print("arena_input:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("arena_input: " + String(c.failed) + " checks failed")
