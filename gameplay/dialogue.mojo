"""Dialogue graphs (ROADMAP 17.72): traversal state, conditions, effects.

The engine holds no text: a node carries a speaker key and a line key, a
choice a text key (`loc_keys.loc_id` ids, 17.73); the host looks them up
and draws them. What the engine owns is which choices are open and what
picking one does:

  * a choice may require a flag comparison (`flag OP value`, `CMP_*`);
  * a choice may write a flag (`EFF_SET` / `EFF_ADD`), the side effect a
    quest or a later conversation reads;
  * it leads to another node, or ends the conversation (`next = -1`).

`DialogueState` is (node, done): the whole traversal, so it saves with the
flags (17.72 checkpoints) and replays. `DialogueGraph.validate` checks
every `next` and flag index once, before the first conversation.
"""

from .flow import Flags, FLAG_BOOL

comptime CMP_NONE = 0
comptime CMP_EQ = 1
comptime CMP_NE = 2
comptime CMP_GE = 3
comptime CMP_LT = 4

comptime EFF_NONE = 0
comptime EFF_SET = 1
comptime EFF_ADD = 2


@fieldwise_init
struct DialogueNode(Copyable, ImplicitlyCopyable, Movable):
    var speaker: Int  # loc key id
    var line: Int  # loc key id
    var first: Int  # choices[first .. first + count]
    var count: Int


@fieldwise_init
struct Choice(Copyable, ImplicitlyCopyable, Movable):
    var text: Int  # loc key id
    var next: Int  # node, -1 = end
    var cmp: Int
    var cmp_flag: Int
    var cmp_value: Int
    var eff: Int
    var eff_flag: Int
    var eff_value: Int


@fieldwise_init
struct DialogueState(Copyable, ImplicitlyCopyable, Movable):
    var node: Int
    var done: Bool


struct DialogueGraph(Copyable, Movable):
    var nodes: List[DialogueNode]
    var choices: List[Choice]

    def __init__(out self):
        self.nodes = List[DialogueNode]()
        self.choices = List[Choice]()

    def node(mut self, speaker: Int, line: Int) -> Int:
        self.nodes.append(DialogueNode(speaker, line, len(self.choices), 0))
        return len(self.nodes) - 1

    def choice(
        mut self, node: Int, text: Int, next: Int, cmp: Int = CMP_NONE, cmp_flag: Int = -1, cmp_value: Int = 0,
        eff: Int = EFF_NONE, eff_flag: Int = -1, eff_value: Int = 0,
    ) raises:
        """Choices are stored contiguously: only the last node takes them."""
        if node != len(self.nodes) - 1:
            raise Error("DialogueGraph.choice: only the most recent node takes choices")
        self.choices.append(Choice(text, next, cmp, cmp_flag, cmp_value, eff, eff_flag, eff_value))
        self.nodes[node].count += 1

    def validate(self, flags: Flags) raises:
        var nf = len(flags.names)
        for i in range(len(self.choices)):
            ref c = self.choices[i]
            if c.next < -1 or c.next >= len(self.nodes):
                raise Error("DialogueGraph: choice " + String(i) + " leads to missing node " + String(c.next))
            if c.cmp != CMP_NONE and (c.cmp_flag < 0 or c.cmp_flag >= nf):
                raise Error("DialogueGraph: choice " + String(i) + " tests an undeclared flag")
            if c.eff != EFF_NONE and (c.eff_flag < 0 or c.eff_flag >= nf):
                raise Error("DialogueGraph: choice " + String(i) + " writes an undeclared flag")
            if c.eff == EFF_ADD and flags.kinds[c.eff_flag] == FLAG_BOOL:
                raise Error("DialogueGraph: choice " + String(i) + " adds to a boolean flag")

    def start(self, node: Int) -> DialogueState:
        return DialogueState(node, False)

    def open(self, c: Int, flags: Flags) -> Bool:
        ref ch = self.choices[c]
        if ch.cmp == CMP_NONE:
            return True
        var v = flags.get(ch.cmp_flag)
        if ch.cmp == CMP_EQ:
            return v == ch.cmp_value
        if ch.cmp == CMP_NE:
            return v != ch.cmp_value
        if ch.cmp == CMP_GE:
            return v >= ch.cmp_value
        return v < ch.cmp_value

    def available(self, st: DialogueState, flags: Flags) -> List[Int]:
        """Open choices of the current node (indices into `choices`)."""
        var out = List[Int]()
        if st.done:
            return out^
        ref n = self.nodes[st.node]
        for c in range(n.first, n.first + n.count):
            if self.open(c, flags):
                out.append(c)
        return out^

    def choose(self, mut st: DialogueState, mut flags: Flags, c: Int) raises:
        if st.done:
            raise Error("DialogueGraph.choose: the conversation has ended")
        ref n = self.nodes[st.node]
        if c < n.first or c >= n.first + n.count:
            raise Error("DialogueGraph.choose: choice " + String(c) + " is not on node " + String(st.node))
        if not self.open(c, flags):
            raise Error("DialogueGraph.choose: choice " + String(c) + " is closed")
        ref ch = self.choices[c]
        if ch.eff == EFF_SET:
            flags.set(ch.eff_flag, ch.eff_value)
        elif ch.eff == EFF_ADD:
            flags.set(ch.eff_flag, flags.get(ch.eff_flag) + ch.eff_value)
        if ch.next < 0:
            st.done = True
        else:
            st.node = ch.next
