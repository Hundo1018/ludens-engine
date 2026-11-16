"""A frame's skinning palette with shared poses (ludens-engine#71, second half): instances that show the same sampled pose
point at one copy of its matrices, so a crowd's palette cost follows the number of distinct poses, not of members.

The host builds the palette each frame: `begin`, then for each skinned instance either `find(key)` (a pose already in
the table) or `add(key, matrices)`; the base returned is the instance's pose_id. A key is the host's name for a sampled
pose, for example clip * 65536 + frame; key -1 is a pose nobody shares (a ragdoll, a blended pose), always added. The
table holds at most `capacity` matrices (the renderer's RenderCaps.palette_matrices): an `add` that does not fit returns
-1 and counts a drop, and the caller skips that instance.
"""


struct PaletteTable(Movable):
    var palette: List[Float32]  # 16 floats per matrix, column-major, as the skinned pass takes it
    var capacity: Int  # matrices
    var keys: List[Int]  # per stored pose: its key (-1 unshared)
    var bases: List[Int]  # per stored pose: its first matrix
    var dropped: Int  # adds refused this frame
    var shared: Int  # finds that hit this frame

    def __init__(out self, capacity: Int) raises:
        if capacity < 1:
            raise Error("PaletteTable: capacity must be at least 1 matrix")
        self.palette = List[Float32]()
        self.capacity = capacity
        self.keys = List[Int]()
        self.bases = List[Int]()
        self.dropped = 0
        self.shared = 0

    def begin(mut self):
        """Start a frame: empty the table (the capacity stays)."""
        self.palette.clear()
        self.keys.clear()
        self.bases.clear()
        self.dropped = 0
        self.shared = 0

    def matrices(self) -> Int:
        return len(self.palette) // 16

    def room(self, n: Int) -> Bool:
        """Whether n more matrices fit."""
        return self.matrices() + n <= self.capacity

    def find(mut self, key: Int) -> Int:
        """The base of the pose stored under `key`, or -1 (key -1 is never found)."""
        if key < 0:
            return -1
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                self.shared += 1
                return self.bases[i]
        return -1

    def add(mut self, key: Int, matrices: List[Float32]) raises -> Int:
        """Store a pose (16 floats per matrix) under `key` and return its base, or -1 when it does not fit (a drop).
        A key that is already stored raises: call `find` first."""
        if len(matrices) == 0 or len(matrices) % 16 != 0:
            raise Error("PaletteTable.add: a pose is 16 floats per matrix")
        if key >= 0:
            for k in self.keys:
                if k == key:
                    raise Error("PaletteTable.add: key " + String(key) + " is already stored")
        var n = len(matrices) // 16
        if not self.room(n):
            self.dropped += 1
            return -1
        var base = self.matrices()
        self.palette.extend(matrices.copy())
        self.keys.append(key)
        self.bases.append(base)
        return base
