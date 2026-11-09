"""Phase A probe for the arena sample game: do the engine's gameplay, ai and nav packages compile here, native and wasm64,
and do they give the same answer? One world, a dynamic character, a spring-arm camera, rules, a behavior tree, a navmesh
path, a game flow and a timer heap, stepped and hashed.

`main` prints the numbers for the native build; `spike_probe_run` is exported for wasm64."""
from embed.world import EmbedWorld
from gameplay.camera_rig import SpringArm
from gameplay.checkpoint import GameFlow
from gameplay.phys_character import DynamicCharacter
from gameplay.rules import Rules, Actor
from geometry.vec import Real, Vec3
from nav.heightfield import NavBakeConfig
from nav.navmesh import bake_navmesh
from nav.path import PolyFunnel
from physics.rigid6 import QuatBody6, Inertia3
from scheduler.timers import TimerHeap, TimerFire
from ai.blackboard import Blackboard, CMP_TRUE
from ai.bt import BehaviorTree, BtState, BtHost, bt_tick, SUCCESS, FAILURE, RUNNING

comptime DT: Real = 1.0 / 60.0


struct Host(BtHost):
    """Action 0 counts its runs and keeps running, action 1 succeeds at once."""

    var runs0: Int
    var runs1: Int

    def __init__(out self):
        self.runs0 = 0
        self.runs1 = 0

    def run(mut self, agent: Int, action: Int, mut bb: Blackboard) -> Int:
        if action == 0:
            self.runs0 += 1
            return RUNNING
        self.runs1 += 1
        return SUCCESS

    def abort(mut self, agent: Int, action: Int, mut bb: Blackboard):
        pass

    def check(mut self, agent: Int, cond: Int, bb: Blackboard) -> Bool:
        return True

    def service(mut self, agent: Int, svc: Int, mut bb: Blackboard):
        pass


def _tri(mut verts: List[Vec3], mut tris: List[Int], a: Vec3, b: Vec3, c: Vec3):
    var n = len(verts)
    verts.append(a)
    verts.append(b)
    verts.append(c)
    tris.append(n)
    tris.append(n + 1)
    tris.append(n + 2)


def run(res: Pointer[UInt64, MutAnyOrigin]) raises:
    var g = Vec3(0.0, -9.81, 0.0, 0.0)
    var w = EmbedWorld(1.0 / 60.0, g)
    _ = w.add_box(Vec3(0.0, -0.5, 0.0, 0.0), Vec3(20.0, 0.5, 20.0, 0.0), 0.0, True)
    var ch = DynamicCharacter.spawn(
        w.scene, QuatBody6.at_rest(Vec3(0.0, 2.0, 0.0, 0.0), Inertia3.box(80.0, 0.3, 0.9, 0.3)), 80.0, 0.3, 0.3, 1.0
    )
    var arm = SpringArm(6.0)
    arm.aim(0.0, 0.4)
    var cam_ok = 0
    for t in range(240):
        var wish = Vec3(2.0, 0.0, 0.0, 0.0) if t > 60 else Vec3(0.0, 0.0, 0.0, 0.0)
        ch.update(w.scene, wish, DT, g)
        w.physics_tick()
        var pose = arm.update(w.scene, w.scene.pose(ch.id).pos, DT)
        if pose.position[1] > 0.0:
            cam_ok += 1

    # rules: 100 health, one 30-point hit
    var rules = Rules(0)
    var actor = Actor(1, 1)
    actor.attrs.set_base(0, 100)
    var lost = rules.damage(actor, 0, 30, 0)

    # behavior tree: a selector whose first branch (condition true -> action 0) keeps running
    var tree = BehaviorTree()
    var sel = tree.selector()
    var seq = tree.sequence()
    tree.add_child(sel, seq)
    tree.add_child(seq, tree.condition(0, CMP_TRUE))
    tree.add_child(seq, tree.action(0))
    tree.add_child(sel, tree.action(1))
    tree.set_root(sel)
    tree.validate()
    var bb = Blackboard(1)
    bb.set_flag(0, True)
    var st = BtState(tree)
    var host = Host()
    var last = -1
    for _ in range(10):
        last = bt_tick(tree, st, host, 0, bb)

    # navmesh: a 20 x 20 floor, a path across it
    var verts = List[Vec3]()
    var tris = List[Int]()
    _tri(verts, tris, Vec3(0.0, 0.0, 0.0, 0.0), Vec3(0.0, 0.0, 20.0, 0.0), Vec3(20.0, 0.0, 0.0, 0.0))
    _tri(verts, tris, Vec3(20.0, 0.0, 0.0, 0.0), Vec3(0.0, 0.0, 20.0, 0.0), Vec3(20.0, 0.0, 20.0, 0.0))
    var mesh = bake_navmesh(verts, tris, NavBakeConfig(0.25, 0.1, 1.8, 0.3, 0.4, 45.0, 16))
    var pf = PolyFunnel()
    var path = pf.find(mesh, Vec3(2.0, 0.0, 2.0, 0.0), Vec3(18.0, 0.0, 18.0, 0.0))

    # game flow and timers
    var flow = GameFlow(12345)
    var rnd = flow.rng.next_u32()
    var heap = TimerHeap()
    _ = heap.schedule(5, 7, 5)
    var fired = List[TimerFire]()
    heap.advance(23, fired)

    res[0] = w.hash()
    res[1] = UInt64(lost)
    res[2] = UInt64(Int(last))
    res[3] = UInt64(host.runs0)
    res[4] = UInt64(mesh.poly_count())
    res[5] = UInt64(1 if path.found else 0)
    res[6] = UInt64(rnd)
    res[7] = UInt64(len(fired))
    res[8] = UInt64(cam_ok)


@export
def spike_probe_run(out_ptr: UInt64) abi("C") -> Int32:
    try:
        run(Pointer[UInt64, MutAnyOrigin](unsafe_from_address=Int(out_ptr)))
        return 0
    except e:
        print("spike_probe_run:", e)
        return -1


def main() raises:
    var buf = List[UInt64](length=9, fill=0)
    run(Pointer[UInt64, MutAnyOrigin](unsafe_from_address=Int(buf.unsafe_ptr())))
    print(
        "hash", buf[0], "lost", buf[1], "bt", buf[2], "runs0", buf[3], "polys", buf[4], "path", buf[5],
        "rng", buf[6], "fired", buf[7], "cam", buf[8],
    )
