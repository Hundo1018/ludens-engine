"""What the player asked for in one frame, independent of the device that produced it.

`game/controls.mojo` fills it from the action map (`game/action_map.mojo`); tests fill it from a script. A game's logic
reads only this, so it needs neither a window nor an input library."""
from geometry.vec import Real


struct Intent(Copyable, ImplicitlyCopyable, Movable):
    var forward: Real  # +1 = toward where the camera looks, -1 = back
    var right: Real  # +1 = to the camera's right
    var look_dx: Real  # camera turn, pixels of mouse movement
    var look_dy: Real
    var jump: Bool  # went down this frame
    var pause: Bool  # went down this frame
    var restart: Bool  # went down this frame
    var jump_buffer_ms: Real  # how long a jump press stays pending (the action's `buffer_ms`); the game keeps it in an `InputBuffer`

    def __init__(
        out self, forward: Real, right: Real, look_dx: Real, look_dy: Real, jump: Bool, pause: Bool, restart: Bool, jump_buffer_ms: Real = 0
    ):
        self.forward = forward
        self.right = right
        self.look_dx = look_dx
        self.look_dy = look_dy
        self.jump = jump
        self.pause = pause
        self.restart = restart
        self.jump_buffer_ms = jump_buffer_ms

    @staticmethod
    def idle() -> Intent:
        return Intent(0, 0, 0, 0, False, False, False)
