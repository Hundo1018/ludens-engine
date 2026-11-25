"""Focal length in millimetres and a zoom that moves to it over time (docs/LIGHTS_CAMERA.md, "Focal length and zoom").

The camera itself keeps only a vertical field of view (`CameraPose.fov_y`, radians). A lens of focal length f on a
sensor of height h sees
    fov_y = 2 atan(h / 2 / f)
which is the same relation app/lens.mojo uses the other way round (f = h / 2 / tan(fov / 2)) to size the depth-of-field
blur, so a focal length set here gives the same f there. The default sensor is 24 mm, the height of a 35 mm frame:
50 mm is then 0.471 rad (27.0 degrees) and 24 mm is 0.927 rad (53.1 degrees).

`ZoomLens` holds the focal length the camera has now (`focal_mm`) and the one it is moving to (`target_mm`). `step(dt)`
moves `focal_mm` toward the target on a log scale: each `zoom_time` seconds closes 63 % of the remaining ratio
(1 - 1/e), so 24 -> 48 mm takes as long as 100 -> 200 mm. `zoom_time` 0 jumps at once. The target is clamped to
`min_mm` .. `max_mm`. A game calls `step` once a frame and writes `fov_y()` into its camera; photo mode
(game/photo_camera.mojo) does this for its own camera.

The camera does not take part in the simulation, so these use the standard library's tan / atan / exp / log, and
their last bits may differ between targets."""
from std.math import atan, exp, log, tan
from geometry.vec import Real

comptime SENSOR_MM: Float64 = 24.0  # height of a 35 mm frame; the same 0.024 m as the renderer's lens_sensor
comptime ZOOM_MIN_MM: Float64 = 10.0
comptime ZOOM_MAX_MM: Float64 = 400.0
comptime ZOOM_TIME: Float64 = 0.25  # seconds for 63 % of the way, on a log scale
comptime ZOOM_SNAP: Float64 = 1e-3  # |log(focal / target)| under this (0.1 %): the zoom has arrived and stops


def fov_from_focal(focal_mm: Float64, sensor_mm: Float64 = SENSOR_MM) -> Real:
    """The vertical field of view (radians) of a lens of this focal length on a sensor of this height."""
    return Real(2.0 * atan(sensor_mm * 0.5 / focal_mm))


def focal_from_fov(fov_y: Real, sensor_mm: Float64 = SENSOR_MM) -> Float64:
    """The focal length (mm) that gives this vertical field of view on a sensor of this height."""
    return sensor_mm * 0.5 / tan(Float64(fov_y) * 0.5)


struct ZoomLens(Copyable, Movable):
    var focal_mm: Float64  # the focal length now
    var target_mm: Float64  # the focal length the zoom moves to
    var sensor_mm: Float64
    var min_mm: Float64
    var max_mm: Float64
    var zoom_time: Float64  # seconds; 0 = jump at once

    def __init__(out self, focal_mm: Float64 = 50.0):
        self.sensor_mm = SENSOR_MM
        self.min_mm = ZOOM_MIN_MM
        self.max_mm = ZOOM_MAX_MM
        self.zoom_time = ZOOM_TIME
        self.focal_mm = 50.0
        self.target_mm = 50.0
        self.jump_to(focal_mm)

    def clamp(self, mm: Float64) -> Float64:
        if not (mm > self.min_mm):  # NaN goes to the shortest lens too
            return self.min_mm
        return min(self.max_mm, mm)

    def set_range(mut self, min_mm: Float64, max_mm: Float64):
        """The lens's shortest and longest focal length; the current and target values are clamped into it."""
        self.min_mm = max(1.0, min(min_mm, max_mm))
        self.max_mm = max(self.min_mm, max_mm)
        self.focal_mm = self.clamp(self.focal_mm)
        self.target_mm = self.clamp(self.target_mm)

    def zoom_to(mut self, mm: Float64) -> Float64:
        """Move to this focal length over time; returns the target kept after clamping."""
        self.target_mm = self.clamp(mm)
        return self.target_mm

    def jump_to(mut self, mm: Float64) -> Float64:
        """Set this focal length now, with no transition."""
        self.target_mm = self.clamp(mm)
        self.focal_mm = self.target_mm
        return self.target_mm

    def match_fov(mut self, fov_y: Real):
        """Start from a camera's field of view (clamped to the lens's range), with no transition."""
        _ = self.jump_to(focal_from_fov(fov_y, self.sensor_mm))

    def zoom_by(mut self, stops: Float64) -> Float64:
        """Multiply the target by 2^stops (1 = twice the focal length, half the field); returns the target kept."""
        return self.zoom_to(self.target_mm * exp(stops * 0.6931471805599453))

    def moving(self) -> Bool:
        return self.focal_mm != self.target_mm

    def step(mut self, dt: Float64):
        """Move the focal length toward the target for dt seconds."""
        if not self.moving():
            return
        var gap = log(self.target_mm / self.focal_mm)
        if self.zoom_time <= 0 or not (dt >= 0):
            self.focal_mm = self.target_mm
            return
        var left = gap * exp(-dt / self.zoom_time)
        if abs(left) < ZOOM_SNAP:
            self.focal_mm = self.target_mm
        else:
            self.focal_mm = self.target_mm * exp(-left)

    def fov_y(self) -> Real:
        return fov_from_focal(self.focal_mm, self.sensor_mm)
