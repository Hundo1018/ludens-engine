"""Display names of the input sources, as string tables (ludens-engine #116 tables, #117 prompts): English (the source
locale) and Traditional Chinese. `input_localizer()` is indexed like the game's own: 0 = en, 1 = zh-TW. A key is
`input.key.<snake_case DOM code>` (`input.key.key_w`, `input.key.arrow_up`), `input.pad.b0` (button 0 of a gamepad, the
standard mapping: A, B, X, Y ...), `input.vpad.b0` (the on-screen button's own label) and `input.mouse.b0`.

`prompt_text(map, loc, action, slot, device)` is the HUD's query: the name of the control that does `action` on `device`, "" when
that device has no binding for it. A layout label from the shell (`ActionMap.key_labels`, "KeyW=Z" pairs filled from
`navigator.keyboard.getLayoutMap()`) replaces the position name, so an AZERTY player sees Z where the key is at W's place."""
from game.action_map import ActionMap, DEV_KEY, key_name
from ui.loc import Localizer, PLURAL_ONE_OTHER, PLURAL_OTHER, StringTable


def _both(mut en: StringTable, mut zh: StringTable, key: String, en_text: String, zh_text: String, context: String):
    en.add(key, en_text, context, 12)
    zh.add(key, zh_text, "", 12)


def input_localizer() -> Localizer:
    var en = StringTable("en", PLURAL_ONE_OTHER)
    var zh = StringTable("zh-TW", PLURAL_OTHER, "en")
    var k = "Name of a keyboard key on a prompt such as `Press {0} to jump`"
    for c in range(26):
        var letter = chr(65 + c)
        _both(en, zh, "input.key.key_" + chr(97 + c), letter, letter, k)
    for d in range(10):
        _both(en, zh, "input.key.digit" + String(d), String(d), String(d), k)
    _both(en, zh, "input.key.space", "Space", "空白鍵", k)
    _both(en, zh, "input.key.escape", "Esc", "Esc", k)
    _both(en, zh, "input.key.enter", "Enter", "Enter", k)
    _both(en, zh, "input.key.tab", "Tab", "Tab", k)
    _both(en, zh, "input.key.backspace", "Backspace", "退格鍵", k)
    _both(en, zh, "input.key.arrow_up", "Up", "上", k)
    _both(en, zh, "input.key.arrow_down", "Down", "下", k)
    _both(en, zh, "input.key.arrow_left", "Left", "左", k)
    _both(en, zh, "input.key.arrow_right", "Right", "右", k)
    _both(en, zh, "input.key.f2", "F2", "F2", k)
    _both(en, zh, "input.key.shift_left", "Shift", "Shift", k)
    _both(en, zh, "input.key.control_left", "Ctrl", "Ctrl", k)
    _both(en, zh, "input.key.alt_left", "Alt", "Alt", k)
    var m = "Name of a mouse button on a prompt"
    _both(en, zh, "input.mouse.b0", "Left click", "左鍵", m)
    _both(en, zh, "input.mouse.b1", "Right click", "右鍵", m)
    _both(en, zh, "input.mouse.b2", "Middle click", "中鍵", m)
    _both(en, zh, "input.mouse.drag0", "Drag", "拖曳", m)
    var g = "Name of a gamepad control on a prompt (standard mapping)"
    _both(en, zh, "input.pad.b0", "A", "A", g)
    _both(en, zh, "input.pad.b1", "B", "B", g)
    _both(en, zh, "input.pad.b2", "X", "X", g)
    _both(en, zh, "input.pad.b3", "Y", "Y", g)
    _both(en, zh, "input.pad.b9", "Start", "Start", g)
    _both(en, zh, "input.pad.b12", "D-pad up", "方向鍵上", g)
    _both(en, zh, "input.pad.b13", "D-pad down", "方向鍵下", g)
    _both(en, zh, "input.pad.b14", "D-pad left", "方向鍵左", g)
    _both(en, zh, "input.pad.b15", "D-pad right", "方向鍵右", g)
    _both(en, zh, "input.pad.a0", "Left stick", "左搖桿", g)
    _both(en, zh, "input.pad.a1", "Left stick", "左搖桿", g)
    _both(en, zh, "input.pad.a1n", "Left stick", "左搖桿", g)
    var v = "Label of an on-screen button, shown on a touch device's prompt"
    _both(en, zh, "input.vpad.b0", "Jump", "跳躍", v)
    _both(en, zh, "input.vpad.b3", "R", "R", v)
    _both(en, zh, "input.vpad.b9", "II", "II", v)
    _both(en, zh, "input.vpad.a0", "Stick", "搖桿", v)
    _both(en, zh, "input.vpad.a1", "Stick", "搖桿", v)
    _both(en, zh, "input.vpad.a1n", "Stick", "搖桿", v)
    var loc = Localizer()
    loc.add_table(en^)
    loc.add_table(zh^)
    return loc^


def prompt_text(map: ActionMap, mut loc: Localizer, action: String, slot: Int, device: Int) -> String:
    var key = map.prompt_source(action, slot, device)
    if key.byte_length() == 0:
        return ""
    if device == DEV_KEY:
        # the first binding of the slot on the keyboard names the position; a layout label may rename it
        var ai = map.index(action)
        for s in range(len(map.actions[ai].bindings)):
            var sb = map.actions[ai].bindings[s]
            if sb.slot == slot and sb.b.device == DEV_KEY:
                var pos = key_name(sb.b.code)
                for i in range(len(map.key_labels)):
                    var eq = map.key_labels[i].find("=")
                    if eq > 0 and String(map.key_labels[i][byte=:eq]) == pos:
                        return String(map.key_labels[i][byte = eq + 1 :])
                break
    return loc.get(key)
