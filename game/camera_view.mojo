"""A camera pose as the numbers the vertex shader needs, and the same projection on the CPU so a test can check it.

Right-handed view space looking down -z. `project` returns clip coordinates (x, y, z, w); the point is on screen when
-w <= x <= w, -w <= y <= w and 0 <= z <= w. z is linear in view depth, which is all the painter's-order renderer needs."""
from geometry.trig import sin, cos
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose


struct Clip(Copyable, ImplicitlyCopyable, Movable):
    var x: Real
    var y: Real
    var z: Real
    var w: Real

    def __init__(out self, x: Real, y: Real, z: Real, w: Real):
        self.x = x
        self.y = y
        self.z = z
        self.w = w

    def on_screen(self) -> Bool:
        return self.w > 0 and abs(self.x) <= self.w and abs(self.y) <= self.w and self.z >= 0 and self.z <= self.w


struct View(Copyable, Movable):
    var eye: Vec3
    var right: Vec3
    var up: Vec3
    var fwd: Vec3
    var sx: Real  # 1 / (aspect * tan(fov / 2))
    var sy: Real  # 1 / tan(fov / 2)
    var near: Real
    var far: Real

    def __init__(out self, cam: CameraPose, aspect: Real):
        var half = cam.fov_y * 0.5
        var t = sin(half) / cos(half)
        self.eye = cam.position
        self.right = cam.right()
        self.up = cam.up()
        self.fwd = cam.forward()
        self.sx = 1.0 / (aspect * t)
        self.sy = 1.0 / t
        self.near = cam.near
        self.far = cam.far

    def depth(self, p: Vec3) -> Real:
        """Distance along the view direction; negative behind the camera."""
        var d = p - self.eye
        return d[0] * self.fwd[0] + d[1] * self.fwd[1] + d[2] * self.fwd[2]

    def project(self, p: Vec3) -> Clip:
        var d = p - self.eye
        var x = d[0] * self.right[0] + d[1] * self.right[1] + d[2] * self.right[2]
        var y = d[0] * self.up[0] + d[1] * self.up[1] + d[2] * self.up[2]
        var z = self.depth(p)
        return Clip(x * self.sx, y * self.sy, self.far * (z - self.near) / (self.far - self.near), z)
