# tier: integration
"""The demo game (game/demo_mode.mojo): the same input gives the same hash, the ball moves and jumps, a jump raises its
cue once and its clip is audible, pause freezes the world, restart returns to the start. Native only:
`pixi run -e wasm test-game`."""
from game.demo_mode import DemoMode, CUE_IMPACT, CUE_JUMP
from game.camera_view import View
from game.intent import Intent
from geometry.vec import Real
from ui.batch import build_batch_font
from ui.draw import CMD_FILL, CMD_TEXT, DrawList
from ui.geom import Insets, Rect
from ui.scale import UiEnv
from ui.sdf_font import SdfFont


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


def overlaps(a: Rect, b: Rect) -> Bool:
    return a.x < b.right() and b.x < a.right() and a.y < b.bottom() and b.y < a.bottom()


def inside(inner: Rect, outer: Rect) -> Bool:
    return inner.x >= outer.x - 0.01 and inner.y >= outer.y - 0.01 and inner.right() <= outer.right() + 0.01 and inner.bottom() <= outer.bottom() + 0.01


def check_hud(mut c: Check, mut font: SdfFont, w: Float32, h: Float32, scale: Float32, locale: Int, pseudo: Bool, insets: Insets) raises -> Int:
    """Lay the HUD out (paused, so all three panels show), then: panels do not overlap each other, lie inside the safe area,
    each text run's wrapped height fits inside its panel, no string key is missing, no glyph is missing. Returns the number
    of failed conditions."""
    var g = DemoMode()
    g.set_font_metrics(font.m)
    g.set_ui_env(UiEnv(scale, insets, locale, pseudo))
    g.paused = True
    g.set_ui_env(UiEnv(scale, insets, locale, pseudo))  # texts again after the pause flag (the key does not include it)
    var dl = g.hud(w, h, 1.0)
    var safe = g.ui.safe_rect(w, h)
    var fills = List[Rect]()
    var texts = List[Int]()
    for i in range(len(dl.cmds)):
        if dl.cmds[i].kind == CMD_FILL:
            fills.append(dl.cmds[i].rect)
        elif dl.cmds[i].kind == CMD_TEXT:
            texts.append(i)
    var bad = 0
    if len(fills) != 3 or len(texts) != 3:
        bad += 1
    for i in range(len(fills)):
        if not inside(fills[i], safe):
            bad += 1
        for j in range(i + 1, len(fills)):
            if overlaps(fills[i], fills[j]):
                bad += 1
    for k in range(min(len(texts), len(fills))):
        ref cmd = dl.cmds[texts[k]]
        var th = font.text_height(cmd.text, cmd.value, cmd.rect.w)
        if cmd.rect.y + th > fills[k].bottom() + 0.01 or cmd.rect.x < fills[k].x or cmd.rect.x + cmd.rect.w > fills[k].right() + 0.5 + cmd.rect.w * 0.05:
            bad += 1
    font.reset_missing()
    var batch = build_batch_font(dl, font)
    if font.missing != 0 or g.loc.missing_keys != 0 or len(batch.glyph_verts) == 0:
        bad += 1
    var label = String("HUD ") + String(Int(w)) + "x" + String(Int(h)) + " text " + String(Int(scale * 100)) + "%, locale " + String(locale) + (", pseudo" if pseudo else "") + ", insets " + String(Int(insets.left)) + "/" + String(Int(insets.bottom))
    c.ok(bad == 0, label + ": 3 panels, no overlap, inside the safe area, text fits, 0 missing keys, 0 missing glyphs")
    return bad


def script(t: Int) -> Intent:
    return Intent(Real(1) if t < 120 else Real(0), Real(1) if t < 60 else Real(0), Real(0), Real(0), t == 30, False, False)


def run(frames: Int) raises -> DemoMode:
    var m = DemoMode()
    for t in range(frames):
        m.step(script(t), 1.0 / 60.0)
    return m^


def main() raises:
    var c = Check()
    var a = run(180)
    var b = run(180)
    c.ok(a.hash() == b.hash(), "the same input gives the same hash")
    c.ok(DemoMode().hash() != a.hash(), "the hash changes while the game runs")

    var m = DemoMode()
    var start = m.camera().position
    var cues = 0  # the jump is a positioned cue now (#120): at the ball, and logged like a plain cue
    var jump_y = Float32(9.0)
    var impacts = 0
    var impact_near_ball = False
    for t in range(180):
        m.step(script(t), 1.0 / 60.0)
        var b = m.world.state(m.ball).pos
        for cue in m.cues():
            cues += 1000  # a plain cue would be a second source of the jump
        for pc in m.positioned_cues():
            if pc.cue == CUE_JUMP and pc.logged:
                cues += 1
                jump_y = pc.y
            if pc.cue == CUE_IMPACT:
                impacts += 1
                if abs(pc.x - Float32(b[0])) < 0.6 and abs(pc.z - Float32(b[2])) < 0.6 and pc.y < 0.15 and t > 30:
                    impact_near_ball = True
                c.ok(not pc.logged and pc.gain_db >= -30.0 and pc.gain_db <= 0.0 and t >= 30, "an impact is not logged, is -30 .. 0 dB and not in the settling ticks (frame " + String(t) + ")")
    c.ok(cues == 1 and m.jumps == 1, "one jump from one Space press (" + String(cues) + " cue, " + String(m.jumps) + " jumps)")
    c.ok(abs(jump_y - 0.4) < 0.05, "the jump cue is at the ball on the floor: y = " + String(jump_y))
    c.ok(impacts == 1 and impact_near_ball, "the ball's landing raises one impact, at the contact point under it; resting contacts raise none (" + String(impacts) + " impacts)")
    c.ok(abs(m.camera().position[0] - start[0]) + abs(m.camera().position[2] - start[2]) > 1.0, "the chase camera follows the ball")
    var view = View(m.camera(), 1.78)
    var ball = m.world.state(m.ball).pos
    c.ok(view.project(ball).on_screen(), "the ball is on screen")
    c.ok(len(m.scene()) == 9, "the scene has the floor, four pillars, three crates and the ball (" + String(len(m.scene())) + ")")

    var clips = m.sounds(48000)
    var peak = Float32(0)
    for v in clips[0]:
        peak = max(peak, abs(v))
    c.ok(len(clips) == 2 and len(clips[0]) == 2 * 7680 and peak > 0.2, "the jump clip of 0.16 s, audible (peak " + String(peak) + ")")
    var thud_peak = Float32(0)
    for v in clips[1]:
        thud_peak = max(thud_peak, abs(v))
    c.ok(len(clips[1]) == 2 * 6720 and thud_peak > 0.2, "the impact clip of 0.14 s, audible (peak " + String(thud_peak) + ")")

    # a host that never takes the cues: jumping every 40 frames lands many times, impacts stay at 4 per step and the list stays short
    var deaf = DemoMode()
    var worst_step = 0
    for t in range(600):
        var before = len(deaf.placed_cues)
        deaf.step(Intent(Real(0), Real(0), Real(0), Real(0), t % 40 == 30, False, False), 1.0 / 60.0)
        var added = 0
        for pc in deaf.placed_cues[before:]:
            if pc.cue == CUE_IMPACT:
                added += 1
        worst_step = max(worst_step, added)
    var total_impacts = 0
    for pc in deaf.placed_cues:
        if pc.cue == CUE_IMPACT:
            total_impacts += 1
    c.ok(total_impacts > 4, "cues nobody takes are not capped at the first four impacts (" + String(total_impacts) + " queued)")
    c.ok(worst_step <= 4 and len(deaf.placed_cues) <= 32 + 15, "at most 4 impacts per step, and the list is bounded (" + String(len(deaf.placed_cues)) + " cues after 600 steps)")
    var jump_cues = 0
    var jump_vy = Float32(0)
    for pc in deaf.placed_cues:
        if pc.cue == CUE_JUMP:
            jump_cues += 1
            jump_vy = pc.vy
    c.ok(jump_cues > 0 and jump_vy > 1.0, "a jump cue carries the ball's upward velocity (" + String(jump_vy) + " m/s)")

    # a load does not replay cues raised before it: the jump below is queued, a save taken, the queue is gone after load_state
    var saved = DemoMode()
    for t in range(35):
        saved.step(Intent(Real(0), Real(0), Real(0), Real(0), t == 31, False, False), 1.0 / 60.0)
    var blob = saved.save_state()
    c.ok(len(saved.placed_cues) > 0, "a jump cue is queued before the load (" + String(len(saved.placed_cues)) + " cues)")
    c.ok(saved.load_state(blob) and len(saved.positioned_cues()) == 0, "load_state drops the cues queued before it")

    # an airborne ball cannot jump again
    var air = DemoMode()
    for t in range(60):
        air.step(Intent(Real(0), Real(0), Real(0), Real(0), t % 2 == 0, False, False), 1.0 / 60.0)
    c.ok(air.jumps < 30, "jumping needs the ground (" + String(air.jumps) + " jumps in 30 presses)")

    # pause freezes the world; restart returns to the start
    var p = DemoMode()
    var h0 = p.hash()
    p.step(Intent(Real(0), Real(0), Real(0), Real(0), False, True, False), 1.0 / 60.0)
    var hp = p.hash()
    for _ in range(30):
        p.step(Intent(Real(1), Real(0), Real(0), Real(0), False, False, False), 1.0 / 60.0)
    c.ok(p.paused and p.hash() == hp and hp != h0, "paused: moving does nothing")
    p.step(Intent(Real(0), Real(0), Real(0), Real(0), False, True, False), 1.0 / 60.0)
    for _ in range(30):
        p.step(Intent(Real(1), Real(0), Real(0), Real(0), False, False, False), 1.0 / 60.0)
    c.ok(not p.paused and p.hash() != hp, "unpaused: the world moves again")
    p.step(Intent(Real(0), Real(0), Real(0), Real(0), False, False, True), 1.0 / 60.0)
    c.ok(p.tick == 1 or p.tick == 0, "restart returns the tick count to the start")
    c.ok(len(p.hud(960.0, 540.0, 1.0).cmds) > 0, "the HUD draws")
    # hud_key (the host's HUD cache, app/hud.mojo refresh_hud): unchanged while what the HUD shows is unchanged,
    # different when the jump count, the pause banner or the size changes
    var k = DemoMode()
    var k0 = k.hud_key(960.0, 540.0)
    for t in range(20):
        k.step(Intent(Real(1), Real(0), Real(0), Real(0), False, False, False), 1.0 / 60.0)
    c.ok(k0 >= 0 and k.hud_key(960.0, 540.0) == k0, "moving without jumping keeps the HUD key")
    c.ok(k.hud_key(1280.0, 720.0) != k0, "a new size changes the HUD key")
    var jumped = False
    for t in range(60):
        k.step(Intent(Real(0), Real(0), Real(0), Real(0), t == 0, False, False), 1.0 / 60.0)
        if k.jumps > 0:
            jumped = True
    c.ok(jumped and k.hud_key(960.0, 540.0) != k0, "a jump changes the HUD key (the count is drawn)")
    var kj = k.hud_key(960.0, 540.0)
    k.step(Intent(Real(0), Real(0), Real(0), Real(0), False, True, False), 1.0 / 60.0)
    c.ok(k.paused and k.hud_key(960.0, 540.0) != kj, "pausing changes the HUD key (the banner is drawn)")

    # HUD layout at text scale 100 % .. 200 %: three window sizes, both locales, pseudo-localization, a phone's safe area
    var font: SdfFont
    with open("assets/fonts/NotoSansTC-Regular-24.lfont", "r") as f:
        font = SdfFont(f.read_bytes())
    var sizes_w = [960.0, 640.0, 1280.0, 844.0]
    var sizes_h = [540.0, 360.0, 720.0, 390.0]
    var scales = [1.0, 1.5, 2.0]
    for si in range(4):
        for sc in range(3):
            for loc in range(2):
                _ = check_hud(c, font, Float32(sizes_w[si]), Float32(sizes_h[si]), Float32(scales[sc]), loc, False, Insets.none())
    _ = check_hud(c, font, 960, 540, 2.0, 0, True, Insets.none())
    _ = check_hud(c, font, 960, 540, 2.0, 1, True, Insets.none())
    _ = check_hud(c, font, 844, 390, 2.0, 0, True, Insets(44, 0, 44, 21))
    _ = check_hud(c, font, 844, 390, 2.0, 1, False, Insets(44, 0, 44, 21))

    # the settings are part of the HUD key; a locale switch changes the drawn text
    var u = DemoMode()
    u.set_font_metrics(font.m)
    var ku = u.hud_key(960.0, 540.0)
    u.set_ui_env(UiEnv(2.0, Insets.none(), 0, False))
    var k2 = u.hud_key(960.0, 540.0)
    u.set_ui_env(UiEnv(2.0, Insets.none(), 1, False))
    var k3 = u.hud_key(960.0, 540.0)
    u.set_ui_env(UiEnv(2.0, Insets(10, 0, 0, 0), 1, False))
    c.ok(ku != k2 and k2 != k3 and k3 != u.hud_key(960.0, 540.0), "text scale, locale and insets each change the HUD key")
    c.ok(u.loc.missing_keys == 0, "the demo's strings resolve: 0 missing keys")
    c.ok(len(u.loc.validate()) == 0 and len(u.loc.missing_glyphs(font)) == 0, "the demo's tables validate and every glyph they use is in the font atlas")

    # state(), seeds and scenes (the automation hook, docs/automation.md)
    var st = a.state()
    c.ok(st.startswith('{"tick":180,') and '"ball":{"pos":[' in st and st.endswith('"hash":"' + String(a.hash()) + '"}'), "state() is JSON with the tick, the ball and the hash: " + st)
    var s0 = DemoMode()
    c.ok(s0.reset(0, ""), "reset(0, \"\") is supported")
    for t in range(180):
        s0.step(script(t), 1.0 / 60.0)
    c.ok(s0.hash() == a.hash(), "seed 0, default scene: the hash of a run with no reset (" + String(a.hash()) + ")")
    var s1 = DemoMode()
    var s1b = DemoMode()
    var s2 = DemoMode()
    _ = s1.reset(1, "arena")
    _ = s1b.reset(1, "arena")
    _ = s2.reset(2, "arena")
    for t in range(180):
        s1.step(script(t), 1.0 / 60.0)
        s1b.step(script(t), 1.0 / 60.0)
        s2.step(script(t), 1.0 / 60.0)
    c.ok(s1.hash() == s1b.hash(), "the same seed gives the same hash")
    c.ok(s1.hash() != a.hash() and s1.hash() != s2.hash(), "different seeds give different hashes")
    var bare = DemoMode()
    _ = bare.reset(0, "bare")
    c.ok(len(bare.scene()) == 2 and '"crates":[]' in bare.state(), "scene bare: the floor and the ball, no crates")
    var bad = False
    try:
        _ = bare.reset(0, "nope")
    except:
        bad = True
    c.ok(bad, "an unknown scene raises")
    var kept = DemoMode()
    _ = kept.reset(7, "arena")
    kept.step(Intent(Real(1), Real(0), Real(0), Real(0), False, False, False), 1.0 / 60.0)
    kept.step(Intent(Real(0), Real(0), Real(0), Real(0), False, False, True), 1.0 / 60.0)  # R: restart, then one zero-input tick
    var fresh = DemoMode()
    _ = fresh.reset(7, "arena")
    fresh.step(Intent.idle(), 1.0 / 60.0)
    var unseeded = DemoMode()
    unseeded.step(Intent.idle(), 1.0 / 60.0)
    c.ok(kept.hash() == fresh.hash(), "R restarts into the seeded layout: the hash equals a fresh reset(7) plus one idle step (" + String(fresh.hash()) + ")")
    c.ok(fresh.hash() != unseeded.hash(), "that layout is not the unseeded one, so the comparison above would catch a restart that dropped the seed")

    print("demo_mode:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("demo_mode: " + String(c.failed) + " checks failed")
