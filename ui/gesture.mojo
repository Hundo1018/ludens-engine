"""Touch gestures from raw touch points (ludens-engine #17): tap, long press, drag and pinch.

Standard library only. The host calls `feed` once per frame with the touches that are down and the time in
milliseconds; `feed` returns the gestures recognized in that frame. Recognition is a small state machine, so it can
be driven by synthetic events in tests and by any platform's touch API:

- tap: one finger down and up within `TAP_MS`, never further than `SLOP` from where it went down;
- long press: one finger held for `LONG_MS` without leaving `SLOP`; reported once, and the lift-off is then not a tap;
- drag: one finger that has left `SLOP`: `DRAG_START` once, `DRAG` with the movement since the last frame, `DRAG_END`
  on lift-off;
- pinch: a second finger cancels any one-finger gesture; `PINCH_START`, then `PINCH` with `scale` (distance now over
  distance at the start) and the movement of the midpoint since the last frame, `PINCH_END` when either finger lifts.
  The remaining finger does not start a drag until it is lifted and put down again.
"""

from std.math import sqrt

comptime TAP = 0
comptime LONG_PRESS = 1
comptime DRAG_START = 2
comptime DRAG = 3
comptime DRAG_END = 4
comptime PINCH_START = 5
comptime PINCH = 6
comptime PINCH_END = 7

comptime TAP_MS = 250
comptime LONG_MS = 500
comptime SLOP: Float32 = 10

comptime _IDLE = 0
comptime _DOWN = 1  # one finger, undecided
comptime _LONG = 2  # long press reported
comptime _DRAGGING = 3
comptime _PINCHING = 4
comptime _WAIT_UP = 5  # a pinch ended; ignore the remaining finger until all fingers are up


@fieldwise_init
struct Touch(Copyable, ImplicitlyCopyable, Movable):
    var x: Float32
    var y: Float32


@fieldwise_init
struct GestureEvent(Copyable, ImplicitlyCopyable, Movable):
    var kind: Int
    var x: Float32  # position (the midpoint for a pinch)
    var y: Float32
    var dx: Float32  # movement since the last frame (DRAG, PINCH)
    var dy: Float32
    var scale: Float32  # PINCH: distance now / distance at the start


def _dist(a: Touch, b: Touch) -> Float32:
    var dx = a.x - b.x
    var dy = a.y - b.y
    return sqrt(dx * dx + dy * dy)


struct GestureRecognizer(Movable):
    var state: Int
    var t0: Int
    var start: Touch
    var last: Touch
    var d0: Float32
    var mid: Touch

    def __init__(out self):
        self.state = _IDLE
        self.t0 = 0
        self.start = Touch(0, 0)
        self.last = Touch(0, 0)
        self.d0 = 1
        self.mid = Touch(0, 0)

    def feed(mut self, touches: List[Touch], now_ms: Int) -> List[GestureEvent]:
        var out = List[GestureEvent]()
        var n = len(touches)
        if n == 0:
            if self.state == _DOWN:
                if now_ms - self.t0 <= TAP_MS:
                    out.append(GestureEvent(TAP, self.last.x, self.last.y, 0, 0, 1))
            elif self.state == _DRAGGING:
                out.append(GestureEvent(DRAG_END, self.last.x, self.last.y, 0, 0, 1))
            elif self.state == _PINCHING:
                out.append(GestureEvent(PINCH_END, self.mid.x, self.mid.y, 0, 0, 1))
            self.state = _IDLE
            return out^
        if n >= 2:
            var a = touches[0]
            var b = touches[1]
            var m = Touch((a.x + b.x) * 0.5, (a.y + b.y) * 0.5)
            if self.state == _PINCHING:
                var d = _dist(a, b)
                out.append(GestureEvent(PINCH, m.x, m.y, m.x - self.mid.x, m.y - self.mid.y, d / self.d0 if self.d0 > 0 else Float32(1)))
                self.mid = m
            elif self.state != _WAIT_UP:
                if self.state == _DRAGGING:
                    out.append(GestureEvent(DRAG_END, self.last.x, self.last.y, 0, 0, 1))
                self.state = _PINCHING
                self.d0 = _dist(a, b)
                self.mid = m
                out.append(GestureEvent(PINCH_START, m.x, m.y, 0, 0, 1))
            return out^
        # exactly one finger
        var p = touches[0]
        if self.state == _PINCHING:
            out.append(GestureEvent(PINCH_END, self.mid.x, self.mid.y, 0, 0, 1))
            self.state = _WAIT_UP
            return out^
        if self.state == _WAIT_UP:
            return out^
        if self.state == _IDLE:
            self.state = _DOWN
            self.t0 = now_ms
            self.start = p
            self.last = p
            return out^
        var moved = _dist(p, self.start)
        if self.state == _DOWN:
            if moved > SLOP:
                self.state = _DRAGGING
                out.append(GestureEvent(DRAG_START, self.start.x, self.start.y, 0, 0, 1))
                out.append(GestureEvent(DRAG, p.x, p.y, p.x - self.start.x, p.y - self.start.y, 1))
            elif now_ms - self.t0 >= LONG_MS:
                self.state = _LONG
                out.append(GestureEvent(LONG_PRESS, p.x, p.y, 0, 0, 1))
        elif self.state == _DRAGGING:
            if p.x != self.last.x or p.y != self.last.y:
                out.append(GestureEvent(DRAG, p.x, p.y, p.x - self.last.x, p.y - self.last.y, 1))
        self.last = p
        return out^
