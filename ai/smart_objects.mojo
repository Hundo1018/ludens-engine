"""Smart objects: interaction slots with reservation (ROADMAP 17.15).

An object (bench, door, workstation) publishes slots; each slot has a
position, a tag mask (what interaction it offers: sit, use, open...) and a
state: free -> reserved (an agent is walking to it) -> occupied (in use) ->
free. `claim(agent, tags, near)` reserves the nearest free slot offering all
`tags`; a reservation that is not converted to occupation within its
timeout expires on `update(tick)`, so a slot is never held by an agent that
was despawned or got distracted. Disabled objects offer nothing.
Deterministic: ties go to the lower slot id.
"""

from geometry.vec import Real, Vec3, dot

comptime SLOT_FREE = 0
comptime SLOT_RESERVED = 1
comptime SLOT_OCCUPIED = 2


struct SmartObjects(Movable):
    var obj_enabled: List[Bool]
    var slot_obj: List[Int]
    var slot_pos: List[Vec3]
    var slot_tags: List[UInt64]
    var slot_state: List[Int]
    var slot_agent: List[Int]
    var slot_expires: List[Int]
    var reserve_ticks: Int

    def __init__(out self, reserve_ticks: Int = 300):
        self.obj_enabled = List[Bool]()
        self.slot_obj = List[Int]()
        self.slot_pos = List[Vec3]()
        self.slot_tags = List[UInt64]()
        self.slot_state = List[Int]()
        self.slot_agent = List[Int]()
        self.slot_expires = List[Int]()
        self.reserve_ticks = reserve_ticks

    def add_object(mut self) -> Int:
        self.obj_enabled.append(True)
        return len(self.obj_enabled) - 1

    def add_slot(mut self, obj: Int, pos: Vec3, tags: UInt64) raises -> Int:
        if obj < 0 or obj >= len(self.obj_enabled):
            raise Error("SmartObjects.add_slot: unknown object")
        self.slot_obj.append(obj)
        self.slot_pos.append(pos)
        self.slot_tags.append(tags)
        self.slot_state.append(SLOT_FREE)
        self.slot_agent.append(-1)
        self.slot_expires.append(0)
        return len(self.slot_obj) - 1

    def set_enabled(mut self, obj: Int, on: Bool):
        """Disabling frees every slot of the object."""
        self.obj_enabled[obj] = on
        if not on:
            for s in range(len(self.slot_obj)):
                if self.slot_obj[s] == obj:
                    self.slot_state[s] = SLOT_FREE
                    self.slot_agent[s] = -1

    def claim(mut self, agent: Int, tags: UInt64, near: Vec3, tick: Int) -> Int:
        """Reserve the nearest free slot offering `tags`; -1 when none. An
        agent holds at most one slot: a previous one is released first."""
        self.release_agent(agent)
        var best = -1
        var best_d = Real(1e30)
        for s in range(len(self.slot_obj)):
            if self.slot_state[s] != SLOT_FREE or not self.obj_enabled[self.slot_obj[s]]:
                continue
            if (self.slot_tags[s] & tags) != tags:
                continue
            var d = self.slot_pos[s] - near
            var d2 = dot(d, d)
            if d2 < best_d:
                best_d = d2
                best = s
        if best >= 0:
            self.slot_state[best] = SLOT_RESERVED
            self.slot_agent[best] = agent
            self.slot_expires[best] = tick + self.reserve_ticks
        return best

    def occupy(mut self, slot: Int, agent: Int) raises:
        if self.slot_agent[slot] != agent or self.slot_state[slot] != SLOT_RESERVED:
            raise Error("SmartObjects.occupy: slot is not reserved by this agent")
        self.slot_state[slot] = SLOT_OCCUPIED

    def release(mut self, slot: Int, agent: Int) raises:
        if self.slot_agent[slot] != agent:
            raise Error("SmartObjects.release: slot is not held by this agent")
        self.slot_state[slot] = SLOT_FREE
        self.slot_agent[slot] = -1

    def release_agent(mut self, agent: Int):
        """Free whatever this agent holds (despawn, distraction)."""
        for s in range(len(self.slot_obj)):
            if self.slot_agent[s] == agent:
                self.slot_state[s] = SLOT_FREE
                self.slot_agent[s] = -1

    def update(mut self, tick: Int) -> Int:
        """Expire reservations past their timeout; returns how many."""
        var n = 0
        for s in range(len(self.slot_obj)):
            if self.slot_state[s] == SLOT_RESERVED and tick >= self.slot_expires[s]:
                self.slot_state[s] = SLOT_FREE
                self.slot_agent[s] = -1
                n += 1
        return n

    def free_count(self, tags: UInt64) -> Int:
        var n = 0
        for s in range(len(self.slot_obj)):
            if self.slot_state[s] == SLOT_FREE and self.obj_enabled[self.slot_obj[s]] and (self.slot_tags[s] & tags) == tags:
                n += 1
        return n
