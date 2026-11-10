"""Shell side of the controls: read `InputState` (filled by `app_input`) into the device-free `Keys`.

WASD or the arrow keys move, Space jumps, R restarts, P or Esc pauses, the mouse turns the camera while the left
button is held. The mapping from `Keys` to `Intent` is `game/controls.mojo`."""
from game.controls import Keys
from geometry.vec import Real
from wgpu.rendercanvas.glfw import MojoInputEvent
from wgpu.rendercanvas.input import InputState

comptime KEY_SPACE: Int32 = 32
comptime KEY_A: Int32 = 65
comptime KEY_D: Int32 = 68
comptime KEY_P: Int32 = 80
comptime KEY_R: Int32 = 82
comptime KEY_S: Int32 = 83
comptime KEY_W: Int32 = 87
comptime KEY_ESCAPE: Int32 = 256
comptime KEY_RIGHT: Int32 = 262
comptime KEY_LEFT: Int32 = 263
comptime KEY_DOWN: Int32 = 264
comptime KEY_UP: Int32 = 265
comptime MOUSE_LEFT: Int32 = 0


def read_keys(input: InputState) -> Keys:
    var k = Keys()
    k.up = input.is_key_pressed(KEY_W) or input.is_key_pressed(KEY_UP)
    k.down = input.is_key_pressed(KEY_S) or input.is_key_pressed(KEY_DOWN)
    k.left = input.is_key_pressed(KEY_A) or input.is_key_pressed(KEY_LEFT)
    k.right = input.is_key_pressed(KEY_D) or input.is_key_pressed(KEY_RIGHT)
    k.look_held = input.is_mouse_button_pressed(MOUSE_LEFT)
    k.mouse_dx = Real(input.mouse_dx)
    k.mouse_dy = Real(input.mouse_dy)
    k.jump = input.is_key_just_pressed(KEY_SPACE)
    k.pause = input.is_key_just_pressed(KEY_P) or input.is_key_just_pressed(KEY_ESCAPE)
    k.restart = input.is_key_just_pressed(KEY_R)
    return k^


def release_all(mut input: InputState):
    """The window lost focus: a key released elsewhere never reports its release, so let go of every one."""
    for key in range(512):
        if input.is_key_pressed(Int32(key)):
            input.process_event(MojoInputEvent(1, Int32(key), 0, 0, 0.0, 0.0))
    for b in range(8):
        if input.is_mouse_button_pressed(Int32(b)):
            input.process_event(MojoInputEvent(2, Int32(b), 0, 0, 0.0, 0.0))
