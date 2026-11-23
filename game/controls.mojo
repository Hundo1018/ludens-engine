"""The action map -> `Intent`. Knows no device and no window, so a test can drive it.

`app/controls.read_frame` fills an `InputFrame` from the shell's `InputState`; `Controls.poll` evaluates the action map
(`game/action_map.mojo`, default bindings in `game/data/demo.actions`) and reads the demo game's actions: `move`, `look`,
`jump`, `pause`, `restart`. Rebinding, profiles and prompts are on `Controls.actions`."""
from game.action_map import ActionMap, InputFrame
from game.demo_actions import DEMO_ACTIONS_TEXT
from game.intent import Intent
from geometry.vec import Real


struct Controls(Movable):
    var actions: ActionMap

    def __init__(out self) raises:
        self.actions = ActionMap.parse(DEMO_ACTIONS_TEXT)

    def __init__(out self, var actions: ActionMap):
        self.actions = actions^

    def poll(mut self, f: InputFrame) -> Intent:
        self.actions.update(f)
        return Intent(
            Real(self.actions.y("move")),
            Real(self.actions.x("move")),
            Real(self.actions.x("look")),
            Real(self.actions.y("look")),
            self.actions.pressed("jump"),
            self.actions.pressed("pause"),
            self.actions.pressed("restart"),
            Real(self.actions.buffer_ms("jump")),
        )
