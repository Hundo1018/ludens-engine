"""Two-way drag coupling of a rigid body to the 2-D grid gas (ROADMAP 17.61).

A body is a set of sample points; each sample carries the area `area` of one
grid cell. Sample k is dragged toward the local gas velocity,

    F_k = kappa * area * (u_gas(p_k) - v_body),

the gas receives -F_k dt through `MacFluid2.add_impulse`, and the body receives
the sum of F_k dt. Both sides take the same impulse, so body plus gas momentum
is exact to rounding after each `couple` call. The non-conservative part is the
semi-Lagrangian advection in `MacFluid2`, which is outside this module.

The explicit drag is stable while kappa dt <= 1/2 (one sample changes the gas
velocity at its own point by about F dt / dx^2 per step).
"""

from geometry.vec import Real
from physics.mac_fluid import MacFluid2


def disk_samples(radius: Real, dx: Real) raises -> Tuple[List[Real], List[Real]]:
    """Centres of the grid cells (side dx) whose centre lies inside a disk of
    the given radius about the origin. Returns the (x, y) offsets."""
    if not (radius > 0) or not (dx > 0):
        raise Error("disk_samples: radius > 0 and dx > 0")
    var ox = List[Real]()
    var oy = List[Real]()
    var half = Int(radius / dx) + 2
    for j in range(-half, half):
        for i in range(-half, half):
            var px = (Real(i) + 0.5) * dx
            var py = (Real(j) + 0.5) * dx
            if px * px + py * py <= radius * radius:
                ox.append(px)
                oy.append(py)
    if len(ox) == 0:
        raise Error("disk_samples: no cell centre inside the disk; radius too small for dx")
    return (ox^, oy^)


def square_samples(half_side: Real, dx: Real) raises -> Tuple[List[Real], List[Real]]:
    """Centres of the grid cells (side dx) whose centre lies inside the square
    |x| <= half_side, |y| <= half_side about the origin. Returns the (x, y) offsets."""
    if not (half_side > 0) or not (dx > 0):
        raise Error("square_samples: half_side > 0 and dx > 0")
    var ox = List[Real]()
    var oy = List[Real]()
    var half = Int(half_side / dx) + 2
    for j in range(-half, half):
        for i in range(-half, half):
            var px = (Real(i) + 0.5) * dx
            var py = (Real(j) + 0.5) * dx
            if abs(px) <= half_side and abs(py) <= half_side:
                ox.append(px)
                oy.append(py)
    if len(ox) == 0:
        raise Error("square_samples: no cell centre inside the square; half_side too small for dx")
    return (ox^, oy^)


struct DragBody2(Movable):
    var mass: Real
    var x: Real  # centre
    var y: Real
    var vx: Real
    var vy: Real
    var ox: List[Real]  # sample offsets from the centre
    var oy: List[Real]
    var area: Real  # area carried by one sample
    var kappa: Real  # drag per unit area per unit relative speed (1/s)

    def __init__(
        out self,
        var ox: List[Real],
        var oy: List[Real],
        area: Real,
        mass: Real,
        kappa: Real,
        x: Real,
        y: Real,
    ) raises:
        if len(ox) == 0 or len(ox) != len(oy):
            raise Error("DragBody2: needs one or more samples, with matching x and y offsets")
        if not (area > 0) or not (mass > 0) or not (kappa >= 0):
            raise Error("DragBody2: area > 0, mass > 0, kappa >= 0")
        self.mass = mass
        self.x = x
        self.y = y
        self.vx = 0
        self.vy = 0
        self.ox = ox^
        self.oy = oy^
        self.area = area
        self.kappa = kappa

    def couple(mut self, mut fluid: MacFluid2, dt: Real, gravity: Real):
        """One explicit coupling step: samples read the gas velocity at the start
        of the step, the gas gets the reaction, the body gets the drag and gravity,
        and the centre moves with the new velocity."""
        var n = len(self.ox)
        var fx = List[Real](length=n, fill=0)
        var fy = List[Real](length=n, fill=0)
        for k in range(n):
            var g = fluid.velocity(self.x + self.ox[k], self.y + self.oy[k])
            fx[k] = self.kappa * self.area * (g[0] - self.vx)
            fy[k] = self.kappa * self.area * (g[1] - self.vy)
        var dpx = Real(0)
        var dpy = Real(0)
        for k in range(n):
            fluid.add_impulse(self.x + self.ox[k], self.y + self.oy[k], -fx[k] * dt, -fy[k] * dt)
            dpx += fx[k] * dt
            dpy += fy[k] * dt
        self.vx += dpx / self.mass
        self.vy += dpy / self.mass - gravity * dt
        self.x += self.vx * dt
        self.y += self.vy * dt
