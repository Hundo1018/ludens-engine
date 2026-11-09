"""What is held and what went down this frame -> `Intent`. Knows no device and no window, so a test can drive it.

`app/controls.mojo` fills `Keys` from the shell's `InputState`; `Controls.poll` turns it into the `Intent` the game reads."""
from game.intent import Intent
from geometry.vec import Real


struct Keys(Copyable, ImplicitlyCopyable, Movable):
    var up: Bool  # W or arrow up, held
    var down: Bool
    var left: Bool
    var right: Bool
    var look_held: Bool  # left mouse button, held
    var mouse_dx: Real  # pointer movement since the last frame, pixels
    var mouse_dy: Real
    var jump: Bool  # Space went down this frame
    var pause: Bool  # P or Esc went down this frame
    var restart: Bool  # R went down this frame

    def __init__(out self):
        self.up = False
        self.down = False
        self.left = False
        self.right = False
        self.look_held = False
        self.mouse_dx = 0
        self.mouse_dy = 0
        self.jump = False
        self.pause = False
        self.restart = False


struct Controls:
    # The first pointer event reports a move from (0, 0) to wherever the pointer is. It is not a camera turn.
    var primed: Bool

    def __init__(out self):
        self.primed = False

    def poll(mut self, k: Keys) -> Intent:
        var fwd = Real(0)
        var right = Real(0)
        if k.up:
            fwd += 1
        if k.down:
            fwd -= 1
        if k.right:
            right += 1
        if k.left:
            right -= 1
        var dx = Real(0)
        var dy = Real(0)
        if self.primed and k.look_held:
            dx = k.mouse_dx
            dy = k.mouse_dy
        if k.mouse_dx != 0 or k.mouse_dy != 0:
            self.primed = True
        return Intent(fwd, right, dx, dy, k.jump, k.pause, k.restart)
