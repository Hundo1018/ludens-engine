"""Clip events and sync markers (ROADMAP 17.64).

An `EventTrack` holds (time, id) pairs on a clip of length `L`. `fire`
reports every event crossed when playback moves from clip time `t0` to
`t1` (unwrapped: the times keep growing across loops), each crossing exactly
once:

  * an event at time e fires for every k with t0 <= e + k L < t1 -- the
    interval is half-open, so an event at 0 fires when playback starts at 0
    and an event exactly at a tick boundary fires in the tick that starts
    there, never in both;
  * a looping clip wraps (a tick longer than the clip fires the event once
    per pass); a non-looping clip stops at L, and an event at exactly L fires
    once when playback reaches the end;
  * reverse playback (t1 < t0) fires the events in (t1, t0], latest first.

Sync markers map one clip's phase onto another's: `marker_phase` gives the
fraction of the way between the two markers around time t, and
`sync_time` finds the time in a second clip with the same marker index and
fraction (walk and run of different lengths stay foot-aligned).
"""

from geometry.vec import Real


struct EventTrack(Copyable, Movable):
    var times: List[Real]  # ascending
    var ids: List[Int]

    def __init__(out self):
        self.times = List[Real]()
        self.ids = List[Int]()

    def add(mut self, t: Real, id: Int) raises:
        if not (t >= 0):
            raise Error("EventTrack.add: time must be >= 0")
        var k = len(self.times)
        while k > 0 and self.times[k - 1] > t:
            k -= 1
        self.times.insert(k, t)
        self.ids.insert(k, id)

    def fire(self, t0: Real, t1: Real, length: Real, loop: Bool, mut out: List[Int]):
        """Append the ids of events crossed going from `t0` to `t1`."""
        if len(self.times) == 0 or t0 == t1:
            return
        if not loop or length <= 0:
            var a = max(min(t0, t1), Real(0))
            var b = min(max(t0, t1), length) if length > 0 else max(t0, t1)
            if t1 > t0:
                for k in range(len(self.times)):
                    var e = self.times[k]
                    if (e >= a and e < b) or (e == length and t1 >= length and t0 < length):
                        out.append(self.ids[k])
            else:
                var k = len(self.times) - 1
                while k >= 0:
                    var e = self.times[k]
                    if e > a and e <= b:
                        out.append(self.ids[k])
                    k -= 1
            return
        if t1 > t0:
            var c0 = Int(t0 / length)
            if Real(c0) * length > t0:
                c0 -= 1
            var c = c0
            while Real(c) * length < t1:
                var base = Real(c) * length
                for k in range(len(self.times)):
                    var e = base + self.times[k]
                    if self.times[k] < length and e >= t0 and e < t1:
                        out.append(self.ids[k])
                c += 1
        else:
            var c = Int(t0 / length)
            if Real(c) * length > t0:
                c -= 1
            while Real(c + 1) * length > t1:
                var base = Real(c) * length
                var k = len(self.times) - 1
                while k >= 0:
                    var e = base + self.times[k]
                    if self.times[k] < length and e <= t0 and e > t1:
                        out.append(self.ids[k])
                    k -= 1
                c -= 1


def marker_phase(t: Real, markers: List[Real], length: Real) -> Tuple[Int, Real]:
    """(index of the last marker at or before t, fraction of the way to the
    next one), on a looping clip. Markers ascending in [0, length)."""
    var n = len(markers)
    if n == 0 or length <= 0:
        return (0, Real(0))
    var u = t - length * Real(Int(t / length))
    if u < 0:
        u += length
    var i = n - 1
    for k in range(n):
        if markers[k] <= u:
            i = k
    var start = markers[i]
    var end = markers[(i + 1) % n] + (length if i == n - 1 else Real(0))
    if u < markers[0]:
        start = markers[n - 1] - length
        i = n - 1
        end = markers[0]
    var span = end - start
    return (i, (u - start) / span if span > 0 else Real(0))


def sync_time(t: Real, src: List[Real], src_len: Real, dst: List[Real], dst_len: Real) -> Real:
    """Time in the destination clip at the same marker index and fraction
    as time `t` of the source clip (marker counts must match)."""
    var ph = marker_phase(t, src, src_len)
    var n = len(dst)
    if n == 0:
        return 0
    var i = ph[0] % n
    var start = dst[i]
    var end = dst[(i + 1) % n] + (dst_len if i == n - 1 else Real(0))
    var r = start + (end - start) * ph[1]
    return r - dst_len if r >= dst_len else r
