"""Directional focus navigation for a set of focusable rectangles (ludens-engine #17).

Arrow keys, a gamepad d-pad or a swipe all say "move focus that way": `focus_next` picks, among the rectangles that
lie that way from the current one, the one with the lowest weighted distance: 13 x (the gap along the direction)^2
+ (the offset across it)^2, the weighting Android's FocusFinder uses. One unit of gap costs sqrt(13), about 3.6
units of sideways offset, so a target straight ahead beats a nearer one that is far off to the side. Ties go to the
lower index. With `wrap`, a move off the edge continues from the opposite end of the same row (column)."""
from ui.geom import Rect

comptime DIR_LEFT = 0
comptime DIR_RIGHT = 1
comptime DIR_UP = 2
comptime DIR_DOWN = 3


def _beyond(cur: Rect, c: Rect, d: Int) -> Bool:
    """True when `c` is a candidate for a move `d` from `cur` (Android FocusFinder's rule): it lies past `cur`'s far
    edge, or starts after `cur`'s near edge and ends beyond its far edge. A wide rectangle spanning over `cur` that
    starts at or before `cur`'s near edge is not "to the right" of it."""
    if d == DIR_RIGHT:
        return (cur.x < c.x or cur.right() <= c.x) and cur.right() < c.right()
    if d == DIR_LEFT:
        return (cur.right() > c.right() or cur.x >= c.right()) and cur.x > c.x
    if d == DIR_DOWN:
        return (cur.y < c.y or cur.bottom() <= c.y) and cur.bottom() < c.bottom()
    return (cur.bottom() > c.bottom() or cur.y >= c.bottom()) and cur.y > c.y


def _gap(cur: Rect, c: Rect, d: Int) -> Float32:
    var g: Float32
    if d == DIR_RIGHT:
        g = c.x - cur.right()
    elif d == DIR_LEFT:
        g = cur.x - c.right()
    elif d == DIR_DOWN:
        g = c.y - cur.bottom()
    else:
        g = cur.y - c.bottom()
    return g if g > 0 else Float32(0)


def _side(cur: Rect, c: Rect, d: Int) -> Float32:
    var s = (c.center_y() - cur.center_y()) if (d == DIR_LEFT or d == DIR_RIGHT) else (c.center_x() - cur.center_x())
    return s if s >= 0 else -s


def _score(cur: Rect, c: Rect, d: Int) -> Float32:
    var major = _gap(cur, c, d)
    var minor = _side(cur, c, d)
    return 13 * major * major + minor * minor


def focus_next(rects: List[Rect], current: Int, d: Int, wrap: Bool = False) -> Int:
    """The index to focus after moving `d` from `current`, or -1 when nothing lies that way. `current` < 0 (no
    focus yet) picks the first rectangle in reading order (top, then left)."""
    var n = len(rects)
    if n == 0:
        return -1
    if current < 0 or current >= n:
        var best = 0
        for i in range(1, n):
            if rects[i].y < rects[best].y or (rects[i].y == rects[best].y and rects[i].x < rects[best].x):
                best = i
        return best
    var cur = rects[current]
    var pick = -1
    var pick_score = Float32(0)
    for i in range(n):
        if i == current or not _beyond(cur, rects[i], d):
            continue
        var s = _score(cur, rects[i], d)
        if pick < 0 or s < pick_score:
            pick = i
            pick_score = s
    if pick >= 0 or not wrap:
        return pick
    # Wrap: among the rectangles that share the current one's row (column), the one at the opposite end.
    var lane_pick = -1
    var lane_key = Float32(0)
    for i in range(n):
        if i == current:
            continue
        var r = rects[i]
        var in_lane: Bool
        var along: Float32
        if d == DIR_LEFT or d == DIR_RIGHT:
            in_lane = r.y < cur.bottom() and r.bottom() > cur.y
            along = r.center_x()
        else:
            in_lane = r.x < cur.right() and r.right() > cur.x
            along = r.center_y()
        if not in_lane:
            continue
        var key = along if (d == DIR_RIGHT or d == DIR_DOWN) else -along
        if lane_pick < 0 or key < lane_key:
            lane_pick = i
            lane_key = key
    return lane_pick
