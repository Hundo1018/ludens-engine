# tier: unit
"""The action map (game/action_map.mojo, ludens-engine #117): parsing with line-numbered errors, analog sticks through a
radial dead zone and a response curve, physical key codes, rebinding with conflict detection, a profile saved to a file
and restored by a fresh map, the input buffer window, and prompt keys. Standard library plus the game's own files; native only:
`pixi run -e wasm test-game`."""
from game.action_map import (
    ActionMap, DEV_KEY, DEV_PAD, DEV_VPAD, InputBuffer, InputFrame, SLOT_MAIN, SLOT_UP, SLOT_X, VPAD_DEVICE, key_code, pad_button_key, parse_source, shape_stick, label_key,
)
from game.controls import Controls
from game.demo_actions import DEMO_ACTIONS_TEXT
from game.input_strings import input_localizer, prompt_text
from std.math import sqrt


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


def near(a: Float64, b: Float64) -> Bool:
    return abs(a - b) < 1.0e-9


def parse_fails(text: String, contains: String) -> Bool:
    try:
        _ = ActionMap.parse(text)
    except e:
        return String(e).find(contains) >= 0
    return False


def demo() raises -> ActionMap:
    return ActionMap.parse(DEMO_ACTIONS_TEXT)


def main() raises:
    var c = Check()

    # --- the asset: the file on disk is the text the game embeds, and it parses
    var m = demo()
    c.ok(len(m.actions) == 5, "the demo map has 5 actions: move, look, jump, pause, restart")
    c.ok(near(m.buffer_ms("jump"), 100.0) and near(m.actions[m.index("move")].deadzone, 0.2), "buffer_ms and deadzone come from the asset")
    var on_disk = String()
    with open("game/data/demo.actions", "r") as f:
        on_disk = f.read()
    c.ok(on_disk == DEMO_ACTIONS_TEXT, "game/demo_actions.mojo embeds game/data/demo.actions byte for byte")

    # --- errors name the line
    c.ok(parse_fails("nope\n", "1: the first row must be"), "a wrong header is refused")
    c.ok(parse_fails("ludens-actions 1\naction jump button\nbind jump key:Banana\n", "3: `Banana` is not a key name"), "an unknown key names line 3")
    c.ok(parse_fails("ludens-actions 1\nbind jump key:Space\n", "2: `jump` is not an action"), "a bind before its action is refused")
    c.ok(parse_fails("ludens-actions 1\naction move stick\nbind move.x key:KeyA\n", "3: slot `x` takes an axis"), "a key on an analog slot is refused")
    c.ok(parse_fails("ludens-actions 1\naction a button\naction a button\n", "3: action `a` is defined twice"), "a duplicate action is refused")
    c.ok(parse_fails("ludens-actions 1\naction s stick deadzone=1\n", "2: deadzone"), "a dead zone of 1 is refused")

    # --- physical key codes: a binding is a position name, never the character on the keycap
    var i = Controls()
    var f = InputFrame()
    f.hold(key_code("KeyW"))  # on an AZERTY board the key labelled Z sends code KeyW (DOM KeyboardEvent.code), the same GLFW 87
    var intent = i.poll(f)
    c.ok(key_code("KeyW") == 87 and intent.forward == 1, "the key at W's position moves forward (AZERTY sends KeyW for the key labelled Z)")
    f = InputFrame()
    f.hold(key_code("KeyZ"))  # on AZERTY this is the key labelled W; QWERTY's Z position is not a move key
    intent = i.poll(f)
    c.ok(intent.forward == 0 and intent.right == 0, "the key at Z's position does nothing by default")

    # --- digital movement is what it was: unit steps, two keys are (1, 1), opposite keys cancel
    f = InputFrame()
    f.hold(key_code("KeyW"))
    f.hold(key_code("KeyD"))
    intent = i.poll(f)
    c.ok(intent.forward == 1 and intent.right == 1, "W + D: forward 1 and right 1, not normalised")
    f.hold(key_code("KeyS"))
    f.hold(key_code("KeyA"))
    intent = i.poll(f)
    c.ok(intent.forward == 0 and intent.right == 0, "opposite keys cancel")

    # --- analog: dead zone and curve, checked against hand-computed values
    var s0 = shape_stick(0.1, 0.1, 0.2, 1.0)
    c.ok(s0[0] == 0.0 and s0[1] == 0.0, "(0.1, 0.1) has length 0.141, inside the 0.2 dead zone: zero")
    var s1 = shape_stick(0.6, 0.0, 0.2, 1.0)
    c.ok(near(s1[0], 0.5) and s1[1] == 0.0, "0.6 with dead zone 0.2: (0.6 - 0.2) / 0.8 = 0.5")
    var s2 = shape_stick(0.6, 0.0, 0.2, 2.0)
    c.ok(near(s2[0], 0.25), "the same with curve 2: 0.5 ^ 2 = 0.25")
    var d = 0.3 / sqrt(2.0)
    var s3 = shape_stick(d * 2.0, d * 2.0, 0.2, 1.0)  # a diagonal of length 0.6: direction kept, length 0.5
    c.ok(near(s3[0], 0.5 / sqrt(2.0)) and near(s3[1], 0.5 / sqrt(2.0)), "a diagonal keeps its direction: the dead zone is radial, not per axis")
    var s4 = shape_stick(1.0, 1.0, 0.2, 1.0)
    c.ok(near(s4[0], 1.0 / sqrt(2.0)) and near(s4[1], 1.0 / sqrt(2.0)), "a corner (1, 1) is clamped to length 1")
    # --- an axis fed through the real map: pad left stick, y is down in the pad API and forward in the intent
    f = InputFrame()
    f.set_axis(0, 0, 0.6)
    f.set_axis(0, 1, 0.0)
    intent = i.poll(f)
    c.ok(near(Float64(intent.right), 0.5) and intent.forward == 0, "pad axis 0 = 0.6 is right = 0.5")
    f = InputFrame()
    f.set_axis(0, 1, -1.0)
    intent = i.poll(f)
    c.ok(near(Float64(intent.forward), 1.0), "pad axis 1 = -1 (stick up) is forward = 1")
    f = InputFrame()
    f.set_axis(0, 0, 0.14)
    f.set_axis(0, 1, 0.14)
    intent = i.poll(f)
    c.ok(intent.forward == 0 and intent.right == 0, "a stick resting at (0.14, 0.14), length 0.198, is inside the dead zone: no drift")
    f = InputFrame()
    f.set_axis(VPAD_DEVICE, 0, -1.0)
    intent = i.poll(f)
    c.ok(near(Float64(intent.right), -1.0), "the on-screen pad's stick (device 3) moves left")
    f = InputFrame()
    f.set_axis(1, 0, 1.0)  # the second gamepad
    intent = i.poll(f)
    c.ok(near(Float64(intent.right), 1.0), "a second gamepad works too")

    # --- gamepad buttons arrive as key codes
    f = InputFrame()
    f.press(pad_button_key(0, 0))
    intent = i.poll(f)
    c.ok(intent.jump, "pad button 0 jumps")
    f = InputFrame()
    f.press(pad_button_key(1, 0))
    intent = i.poll(f)
    c.ok(intent.jump, "button 0 of the second gamepad jumps")
    f = InputFrame()
    f.press(pad_button_key(3, 0))
    intent = i.poll(f)
    c.ok(intent.jump, "the on-screen pad's button 0 jumps")
    f = InputFrame()
    f.hold(pad_button_key(0, 12))
    intent = i.poll(f)
    c.ok(intent.forward == 1, "d-pad up (button 12) moves forward")

    # --- edges: one frame, whatever is held after
    f = InputFrame()
    f.press(key_code("Space"))
    intent = i.poll(f)
    c.ok(intent.jump and intent.jump_buffer_ms == 100, "Space jumps and carries the 100 ms buffer window")
    f = InputFrame()
    f.hold(key_code("Space"))
    intent = i.poll(f)
    c.ok(not intent.jump, "held Space is not another jump")
    f = InputFrame()
    f.tap(key_code("Space"))
    intent = i.poll(f)
    c.ok(intent.jump, "a press and release inside one frame still jumps")

    # --- rebinding with conflicts
    var r = demo()
    var key_k = parse_source("key:KeyK")
    var none = r.rebind("jump", SLOT_MAIN, key_k)
    c.ok(len(none) == 0, "jump to K: no conflict")
    var f2 = InputFrame()
    f2.press(key_code("KeyK"))
    r.update(f2)
    c.ok(r.pressed("jump"), "K now jumps")
    f2 = InputFrame()
    f2.press(key_code("Space"))
    r.update(f2)
    c.ok(not r.pressed("jump"), "Space no longer jumps (the keyboard binding was replaced)")
    f2 = InputFrame()
    f2.press(pad_button_key(0, 0))
    r.update(f2)
    c.ok(r.pressed("jump"), "the gamepad binding of jump is untouched")
    var clash = r.rebind("restart", SLOT_MAIN, parse_source("key:KeyK"))
    c.ok(len(clash) == 1 and clash[0] == "jump.main", "restart to K reports the conflict with jump.main")
    c.ok(r.prompt_source("restart", SLOT_MAIN, DEV_KEY) == "input.key.key_r", "a refused rebind changes nothing: restart keeps R")
    f2 = InputFrame()
    f2.press(key_code("KeyR"))
    r.update(f2)
    c.ok(r.pressed("restart"), "R still restarts after the refused rebind")
    var taken = r.rebind("restart", SLOT_MAIN, parse_source("key:KeyK"), True)
    c.ok(len(taken) == 0, "with take = True restart gets K")
    f2 = InputFrame()
    f2.press(key_code("KeyK"))
    r.update(f2)
    c.ok(r.pressed("restart") and not r.pressed("jump") and not r.has_binding("jump", SLOT_MAIN, DEV_KEY), "K now restarts and no longer jumps; jump has no keyboard key")
    var inside = r.rebind("move", SLOT_UP, parse_source("key:KeyS"))
    c.ok(len(inside) == 1 and inside[0] == "move.down", "up to S conflicts with the same action's down slot")
    var wrong = False
    try:
        _ = r.rebind("move", SLOT_X, parse_source("key:KeyJ"))
    except e:
        wrong = True
    c.ok(wrong, "a key on the analog slot x raises")
    r.reset()
    f2 = InputFrame()
    f2.press(key_code("Space"))
    r.update(f2)
    c.ok(r.pressed("jump"), "reset puts the default back")

    # --- a profile: rebind, save to a file, start over, load, check
    var p = demo()
    c.ok(p.profile() == "ludens-profile 1\n", "a map on its defaults has an empty profile")
    _ = p.rebind("jump", SLOT_MAIN, parse_source("key:KeyJ"))
    _ = p.rebind("move", SLOT_UP, parse_source("key:KeyI"))
    var text = p.profile()
    with open("build/test_actions_profile.txt", "w") as out:
        out.write(text)
    var restarted = demo()  # a new process: defaults again
    var saved = String()
    with open("build/test_actions_profile.txt", "r") as inp:
        saved = inp.read()
    var problems = restarted.load_profile(saved)
    c.ok(len(problems) == 0, "the saved profile loads with no problems")
    var f3 = InputFrame()
    f3.press(key_code("KeyJ"))
    f3.hold(key_code("KeyI"))
    restarted.update(f3)
    c.ok(restarted.pressed("jump") and restarted.y("move") == 1, "after the restart J jumps and I moves forward")
    f3 = InputFrame()
    f3.hold(key_code("KeyW"))
    restarted.update(f3)
    c.ok(restarted.y("move") == 0, "W no longer moves: the profile replaced that slot's keyboard keys")
    c.ok(restarted.profile() == text, "saving again gives the same text")
    var bad_map = demo()
    var bad = bad_map.load_profile("ludens-profile 1\nset jump.main key:KeyQ\nset nothing.main key:KeyX\nset move.up key:KeyS\nset pause.main key:Nope\nset restart key:KeyT\n")
    c.ok(len(bad) == 3, "three bad rows are reported (unknown action, a taken key, an unknown key name); got " + String(len(bad)))
    var ok_rows = demo()
    _ = ok_rows.load_profile("ludens-profile 1\nset jump.main key:KeyQ\nset nothing.main key:KeyX\nset restart key:KeyT\n")
    c.ok(ok_rows.prompt_source("jump", SLOT_MAIN, DEV_KEY) == "input.key.key_q" and ok_rows.prompt_source("restart", SLOT_MAIN, DEV_KEY) == "input.key.key_t", "the good rows around a bad one still apply")
    var garbage_map = demo()
    c.ok(len(garbage_map.load_profile("garbage\n")) == 1, "a file with the wrong header is one problem and changes nothing")

    # --- the input buffer
    var b = InputBuffer()
    b.press(100.0)
    b.age(16.0)
    c.ok(b.live(), "a press 16 ms ago is pending")
    for _ in range(5):
        b.age(16.0)
    c.ok(b.live(), "96 ms after the press it is still pending")
    b.age(16.0)
    c.ok(not b.live() and not b.take(), "112 ms after the press it has expired")
    b.press(100.0)
    c.ok(b.take() and not b.take(), "take answers once per press")
    var b0 = InputBuffer()
    b0.press(0.0)
    c.ok(b0.take(), "a press with no window is pending in its own frame")
    b0.press(0.0)
    b0.age(16.0)
    c.ok(not b0.take(), "and is gone in the next")

    # --- prompts: the key to show per device, and its text from a string table
    var loc = input_localizer()
    var pm = demo()
    c.ok(prompt_text(pm, loc, "jump", SLOT_MAIN, DEV_KEY) == "Space", "prompt(jump, keyboard) = Space")
    c.ok(prompt_text(pm, loc, "jump", SLOT_MAIN, DEV_PAD) == "A", "prompt(jump, gamepad) = A")
    c.ok(prompt_text(pm, loc, "jump", SLOT_MAIN, DEV_VPAD) == "Jump", "prompt(jump, on-screen pad) = Jump")
    c.ok(prompt_text(pm, loc, "move", SLOT_UP, DEV_KEY) == "W", "prompt(move up, keyboard) = W")
    _ = pm.rebind("jump", SLOT_MAIN, parse_source("key:KeyJ"))
    c.ok(prompt_text(pm, loc, "jump", SLOT_MAIN, DEV_KEY) == "J", "after a rebind the prompt shows J")
    pm.key_labels.append("KeyJ=Ü")
    c.ok(prompt_text(pm, loc, "jump", SLOT_MAIN, DEV_KEY) == "Ü", "a layout label from the shell replaces the position name")
    c.ok(prompt_text(pm, loc, "pause", SLOT_MAIN, DEV_PAD) == "Start", "prompt(pause, gamepad) = Start")
    c.ok(loc.missing_keys == 0, "no string key was missing")
    c.ok(len(loc.validate()) == 0, "the string table validates (context notes, maximum lengths)")
    c.ok(label_key(parse_source("-pad:a1")) == "input.pad.a1n", "a negated axis has its own label key")

    print("action_map:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("action_map: " + String(c.failed) + " checks failed")
