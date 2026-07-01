"""The physics step driver: collide via the existing pipeline, then solve.

`collide_boxes` reuses the collision pipeline (`BruteForce` broadphase +
`AABBNarrowPhase`) to turn the bodies' AABBs into `Manifold`s whose `a`/`b` are
body indices (the proxy id is set to the body index, and narrowphase boxes are
added in the same order). `PhysicsWorld[dim, S]` owns the bodies and runs one
substep through the chosen `ContactSolver` — swap `S` to compare solvers with
zero change to the scene code. A fresh pipeline is built each step so moving
bodies' geometry is always current.
"""

from geometry.vec import WorldType, Real
from collision.broadphase import BoxProxy, BruteForce
from collision.narrowphase import AABBNarrowPhase
from collision.pipeline import CollisionPipeline, Manifold
from .rigidbody import RigidBody
from .solver import ContactSolver


def collide_boxes[dim: Int](
    bodies: List[RigidBody[dim]]
) raises -> List[Manifold[dim]]:
    var items = List[BoxProxy[dim]]()
    var narrow = AABBNarrowPhase[dim]()
    for i in range(len(bodies)):
        var box = bodies[i].aabb()
        _ = narrow.add(box)
        items.append(BoxProxy[dim](i, box))
    var pipe = CollisionPipeline(BruteForce[dim](), narrow^)
    return pipe.step(items)


struct PhysicsWorld[dim: Int, S: ContactSolver](Movable, ImplicitlyDeletable):
    var bodies: List[RigidBody[Self.dim]]
    var gravity: SIMD[WorldType, Self.dim]
    var iterations: Int

    def __init__(
        out self, gravity: SIMD[WorldType, Self.dim], iterations: Int = 8
    ):
        self.bodies = List[RigidBody[Self.dim]]()
        self.gravity = gravity
        self.iterations = iterations

    def add(mut self, var b: RigidBody[Self.dim]) -> Int:
        self.bodies.append(b^)
        return len(self.bodies) - 1

    def step(mut self, dt: Real) raises:
        var manifolds = collide_boxes(self.bodies)
        Self.S.substep[Self.dim](
            self.bodies, manifolds, self.gravity, dt, self.iterations
        )

    def body(self, i: Int) -> RigidBody[Self.dim]:
        return self.bodies[i]
