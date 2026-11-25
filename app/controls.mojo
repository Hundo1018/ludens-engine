"""Shell side of the controls: read `InputState` (filled by `app_input`) into the device-free `InputFrame`.

Which key does what is the action map's business (`game/action_map.mojo`, `game/data/demo.actions`): this file only
copies every key, mouse button and axis the frame saw. Gamepad and on-screen pad buttons arrive as key codes from
`PAD_BUTTON_BASE` up (shell/web/pad.ts), their sticks as `AXIS` events."""
from game.action_map import AXIS_DEVICES, InputFrame, MAX_AXES, MAX_KEYS, MAX_MOUSE
from wgpu.rendercanvas.input import InputState

comptime KEY_F2: Int32 = 291  # opens the game's overlay panel (GameMode.overlay)
comptime KEY_F3: Int32 = 292  # shows the frame-time overlay (app/perf_overlay.mojo)
comptime KEY_GRAVE: Int32 = 96  # ` opens and closes the in-game console (game/console.mojo; not in a release build)
comptime KEY_F8: Int32 = 297  # in photo mode: capture a PNG at the capture size (game/photo_camera.mojo)
comptime KEY_F9: Int32 = 298  # enters and leaves photo mode
comptime KEY_ENTER: Int32 = 257
comptime KEY_BACKSPACE: Int32 = 259
comptime KEY_E: Int32 = 69  # photo mode: up
comptime KEY_Q: Int32 = 81  # photo mode: down
comptime KEY_Z: Int32 = 90  # photo mode: zoom in (longer focal length)
comptime KEY_X: Int32 = 88  # photo mode: zoom out
comptime MOUSE_LEFT: Int32 = 0


def read_frame(input: InputState) -> InputFrame:
    var f = InputFrame()
    for k in range(MAX_KEYS):
        if input.is_key_pressed(Int32(k)):
            f.down[k] = True
        if input.is_key_just_pressed(Int32(k)):
            f.edge[k] = True
    for b in range(MAX_MOUSE):
        f.mouse_down[b] = input.is_mouse_button_pressed(Int32(b))
        f.mouse_edge[b] = input.is_mouse_button_just_pressed(Int32(b))
    for d in range(AXIS_DEVICES):
        for a in range(MAX_AXES):
            f.axes[d * MAX_AXES + a] = input.get_axis(Int32(d), Int32(a))
    f.mouse_dx = input.mouse_dx
    f.mouse_dy = input.mouse_dy
    return f^


def typed_text(input: InputState) -> String:
    """The characters of the keys that went down this frame, for the console's line editor: letters (lower case),
    digits, space, minus and full stop, in key-code order. Key codes are GLFW's (shell/web/keys.ts)."""
    var out = String()
    for k in range(32, 91):
        if not input.is_key_just_pressed(Int32(k)):
            continue
        if k >= 65 and k <= 90:
            out += chr(k + 32)
        elif (k >= 48 and k <= 57) or k == 32 or k == 45 or k == 46:
            out += chr(k)
    return out^
