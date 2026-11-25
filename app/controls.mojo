"""Shell side of the controls: read `InputState` (filled by `app_input`) into the device-free `InputFrame`.

Which key does what is the action map's business (`game/action_map.mojo`, `game/data/demo.actions`): this file only
copies every key, mouse button and axis the frame saw. Gamepad and on-screen pad buttons arrive as key codes from
`PAD_BUTTON_BASE` up (shell/web/pad.ts), their sticks as `AXIS` events."""
from game.action_map import AXIS_DEVICES, InputFrame, MAX_AXES, MAX_KEYS, MAX_MOUSE
from wgpu.rendercanvas.input import InputState

comptime KEY_F2: Int32 = 291  # opens the game's overlay panel (GameMode.overlay)
comptime KEY_F3: Int32 = 292  # shows the frame-time overlay (app/perf_overlay.mojo)
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
