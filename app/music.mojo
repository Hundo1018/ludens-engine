"""Looping music with layers and transitions quantized to the next bar (ludens-engine #120). Standard library only.

A track is a tempo, a bar length in beats and one clip per layer (all layers the same length, interleaved stereo at the
mixer's rate). The loop is the clip length. A request to change track, or to switch a layer on or off, is held until the
next bar boundary of the playback position and applied at that exact frame, even inside a render block. The bar length
in frames is an integer, `round(60 / bpm * beats_per_bar * rate)`, so the boundary is the same on every platform.

The new track continues from the same position inside its loop (modulo its length), so a track that has the same length
and bar grid enters on the same bar it left."""


struct MusicTrack(Copyable, Movable):
    var bpm: Float32
    var beats_per_bar: Int
    var layers: List[Int]  # clip ids, one per layer

    def __init__(out self, bpm: Float32, beats_per_bar: Int, var layers: List[Int]):
        self.bpm = bpm
        self.beats_per_bar = beats_per_bar
        self.layers = layers^


struct Music(Movable):
    var tracks: List[MusicTrack]
    var rate: Int
    var current: Int  # -1: stopped
    var pos: Int  # frames into the current loop
    var pending_track: Int  # -1: none
    var layer_on: List[Bool]  # per layer of the current track
    var pending_layer: List[Int]  # -1 none, 0 off, 1 on at the next bar
    var switches: Int  # how many bar-quantized changes have been applied

    def __init__(out self, rate: Int):
        self.tracks = List[MusicTrack]()
        self.rate = rate
        self.current = -1
        self.pos = 0
        self.pending_track = -1
        self.layer_on = List[Bool]()
        self.pending_layer = List[Int]()
        self.switches = 0

    def add_track(mut self, var track: MusicTrack) raises -> Int:
        if track.bpm <= 0.0 or track.beats_per_bar < 1 or len(track.layers) == 0:
            raise Error("music track needs bpm > 0, beats per bar >= 1 and at least one layer")
        self.tracks.append(track^)
        return len(self.tracks) - 1

    def bar_frames(self, track: Int) -> Int:
        var t = self.tracks[track].bpm
        var exact = Float64(60.0) / Float64(t) * Float64(self.tracks[track].beats_per_bar) * Float64(self.rate)
        return Int(exact + 0.5)

    def start(mut self, track: Int):
        """Begin `track` at once, from its first frame, with every layer on."""
        self.current = track
        self.pos = 0
        self.pending_track = -1
        self._reset_layers()

    def stop(mut self):
        self.current = -1
        self.pending_track = -1

    def request_track(mut self, track: Int):
        """Switch to `track` at the next bar boundary (now, if the position is exactly on one)."""
        if self.current < 0:
            self.start(track)
        else:
            self.pending_track = track

    def request_layer(mut self, layer: Int, on: Bool):
        """Switch a layer of the current track on or off at the next bar boundary."""
        if self.current >= 0 and layer >= 0 and layer < len(self.pending_layer):
            self.pending_layer[layer] = 1 if on else 0

    def frames_to_boundary(self) -> Int:
        """Frames from the playback position to the next bar boundary (0 when on one); -1 when stopped."""
        if self.current < 0:
            return -1
        var bar = self.bar_frames(self.current)
        var r = self.pos % bar
        return 0 if r == 0 else bar - r

    def _reset_layers(mut self):
        var n = len(self.tracks[self.current].layers)
        self.layer_on = List[Bool]()
        self.pending_layer = List[Int]()
        for _ in range(n):
            self.layer_on.append(True)
            self.pending_layer.append(-1)

    def _apply_pending(mut self):
        if self.pending_track >= 0:
            var next = self.pending_track
            self.pending_track = -1
            if next != self.current:
                self.current = next  # `pos` is kept; the render loop wraps it to the new loop length
                self._reset_layers()
            self.switches += 1
        for i in range(len(self.pending_layer)):
            if self.pending_layer[i] >= 0:
                self.layer_on[i] = self.pending_layer[i] == 1
                self.pending_layer[i] = -1
                self.switches += 1

    def render(mut self, clips: List[List[Float32]], mut out: List[Float32], frames: Int):
        """Add `frames` stereo frames of music to `out` (interleaved, already sized, not cleared)."""
        var done = 0
        while done < frames and self.current >= 0:
            var loop_len = len(clips[self.tracks[self.current].layers[0]]) // 2
            if loop_len <= 0:
                return
            if self.pos >= loop_len:
                self.pos = self.pos % loop_len
            var bar = self.bar_frames(self.current)
            if self.pos % bar == 0 and self._has_pending():
                self._apply_pending()
                loop_len = len(clips[self.tracks[self.current].layers[0]]) // 2
                self.pos = self.pos % loop_len
                continue
            var run = frames - done
            var to_end = loop_len - self.pos
            if to_end < run:
                run = to_end
            if self._has_pending():
                var to_bar = bar - (self.pos % bar)
                if to_bar < run:
                    run = to_bar
            for layer in range(len(self.layer_on)):
                if not self.layer_on[layer]:
                    continue
                ref clip = clips[self.tracks[self.current].layers[layer]]
                for i in range(run):
                    out[2 * (done + i)] += clip[2 * (self.pos + i)]
                    out[2 * (done + i) + 1] += clip[2 * (self.pos + i) + 1]
            self.pos += run
            done += run

    def _has_pending(self) -> Bool:
        if self.pending_track >= 0:
            return True
        for p in self.pending_layer:
            if p >= 0:
                return True
        return False
