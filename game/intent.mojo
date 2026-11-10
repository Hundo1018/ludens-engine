"""What the player asked for in one frame, independent of the device that produced it.

`app/controls.mojo` fills it from the keyboard and mouse; tests fill it from a script. The game logic in
`game/arena.mojo` reads only this, so it needs neither a window nor an input library."""
from geometry.vec import Real


@fieldwise_init
struct Intent(Copyable, ImplicitlyCopyable, Movable):
    var forward: Real  # +1 = toward where the camera looks, -1 = back
    var right: Real  # +1 = to the camera's right
    var look_dx: Real  # camera turn, pixels of mouse movement
    var look_dy: Real
    var jump: Bool  # went down this frame
    var pause: Bool  # went down this frame
    var restart: Bool  # went down this frame

    @staticmethod
    def idle() -> Intent:
        return Intent(0, 0, 0, 0, False, False, False)
