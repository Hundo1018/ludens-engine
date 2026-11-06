"""Touch gestures (ludens-shell #17): a scripted finger sequence in, the recognized gestures out. Standard library only.

Build and run: `pixi run -e wasm test-ui`."""
from ui.gesture import (
    DRAG, DRAG_END, DRAG_START, GestureEvent, GestureRecognizer, LONG_PRESS, PINCH, PINCH_END, PINCH_START, TAP, Touch,
)


struct Check:
    var passed: Int
    var failed: Int

    def __init__(out self):
        self.passed = 0
        self.failed = 0

    def ok(mut self, cond: Bool, label: String):
        if cond:
            self.passed += 1
        else:
            self.failed += 1
            print("  [FAIL]", label)


def one(x: Float32, y: Float32) -> List[Touch]:
    var t = List[Touch]()
    t.append(Touch(x, y))
    return t^


def two(x0: Float32, y0: Float32, x1: Float32, y1: Float32) -> List[Touch]:
    var t = one(x0, y0)
    t.append(Touch(x1, y1))
    return t^


def kinds(ev: List[GestureEvent]) -> String:
    var s = String()
    for e in ev:
        s += String(e.kind) + " "
    return s


def main() raises:
    var c = Check()

    # tap: down, up 100 ms later
    var g = GestureRecognizer()
    c.ok(len(g.feed(one(50, 50), 0)) == 0, "finger down: nothing yet")
    c.ok(len(g.feed(one(52, 51), 50)) == 0, "small movement inside the slop: nothing")
    var ev = g.feed(List[Touch](), 100)
    c.ok(len(ev) == 1 and ev[0].kind == TAP and ev[0].x == 52, "lift-off after 100 ms: one tap at the last position")

    # too slow for a tap, and not a long press when lifted before LONG_MS
    g = GestureRecognizer()
    _ = g.feed(one(10, 10), 0)
    _ = g.feed(one(10, 10), 400)
    c.ok(len(g.feed(List[Touch](), 450)) == 0, "lifted after 450 ms inside the slop: neither tap nor long press")

    # long press once, and the lift is not a tap
    g = GestureRecognizer()
    _ = g.feed(one(10, 10), 0)
    ev = g.feed(one(10, 10), 500)
    c.ok(len(ev) == 1 and ev[0].kind == LONG_PRESS, "held 500 ms: long press")
    c.ok(len(g.feed(one(10, 10), 700)) == 0, "the long press is reported once")
    c.ok(len(g.feed(List[Touch](), 800)) == 0, "lifting after a long press is not a tap")

    # drag
    g = GestureRecognizer()
    _ = g.feed(one(100, 100), 0)
    ev = g.feed(one(130, 100), 16)
    c.ok(kinds(ev) == "2 3 " and ev[1].dx == 30, "leaving the slop: DRAG_START, then DRAG with dx = 30 from the start")
    ev = g.feed(one(135, 108), 32)
    c.ok(len(ev) == 1 and ev[0].kind == DRAG and ev[0].dx == 5 and ev[0].dy == 8, "next frame: DRAG with the movement since the last frame")
    c.ok(len(g.feed(one(135, 108), 48)) == 0, "no movement: no event")
    ev = g.feed(List[Touch](), 64)
    c.ok(len(ev) == 1 and ev[0].kind == DRAG_END, "lift-off ends the drag (no tap)")

    # pinch: spread from 100 apart to 150 apart
    g = GestureRecognizer()
    ev = g.feed(two(100, 100, 200, 100), 0)
    c.ok(len(ev) == 1 and ev[0].kind == PINCH_START and ev[0].x == 150, "second finger: PINCH_START at the midpoint")
    ev = g.feed(two(75, 100, 225, 100), 16)
    c.ok(len(ev) == 1 and ev[0].kind == PINCH and ev[0].scale == 1.5 and ev[0].dx == 0, "spread to 150: scale 1.5, midpoint did not move")
    ev = g.feed(two(85, 110, 235, 110), 32)
    c.ok(len(ev) == 1 and ev[0].scale == 1.5 and ev[0].dx == 10 and ev[0].dy == 10, "two-finger pan: midpoint movement reported")
    ev = g.feed(one(85, 110), 48)
    c.ok(len(ev) == 1 and ev[0].kind == PINCH_END, "one finger lifts: PINCH_END")
    c.ok(len(g.feed(one(200, 200), 64)) == 0, "the remaining finger moving does not start a drag")
    c.ok(len(g.feed(List[Touch](), 80)) == 0, "...and lifting it is not a tap")
    c.ok(len(g.feed(one(5, 5), 100)) == 0 and kinds(g.feed(List[Touch](), 150)) == "0 ", "a new touch after that works: a tap")

    # a drag that becomes a pinch
    g = GestureRecognizer()
    _ = g.feed(one(0, 0), 0)
    _ = g.feed(one(40, 0), 16)
    ev = g.feed(two(40, 0, 140, 0), 32)
    c.ok(kinds(ev) == "4 5 ", "a second finger during a drag: DRAG_END, then PINCH_START")

    print("ui_gesture:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("ui_gesture: " + String(c.failed) + " checks failed")
