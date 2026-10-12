"""Navmesh for the embedding boundary (ROADMAP 12.1): bake from a triangle
soup, find a smoothed path. A navmesh is independent of any world (the host
passes the level geometry it already has)."""

from std.math import isfinite
from geometry.vec import Real, Vec3
from nav.heightfield import NavBakeConfig
from nav.navmesh import NavMesh, bake_navmesh
from nav.path import NavPath, PathFinder, PolyFunnel


struct EmbedNav(Movable):
    var mesh: NavMesh
    var finder: PolyFunnel

    def __init__(out self, verts: List[Vec3], tris: List[Int], cfg: NavBakeConfig) raises:
        for v in verts:
            if not (isfinite(v[0]) and isfinite(v[1]) and isfinite(v[2])):
                raise Error("nav_bake: vertices must be finite")
        if len(tris) % 3 != 0:
            raise Error("nav_bake: index count must be a multiple of 3")
        for t in tris:
            if t < 0 or t >= len(verts):
                raise Error("nav_bake: triangle index out of range")
        self.mesh = bake_navmesh(verts, tris, cfg)
        self.finder = PolyFunnel()

    def find_path(mut self, start: Vec3, goal: Vec3) raises -> NavPath:
        if not (isfinite(start[0]) and isfinite(start[1]) and isfinite(start[2])
                and isfinite(goal[0]) and isfinite(goal[1]) and isfinite(goal[2])):
            raise Error("nav_find_path: points must be finite")
        return self.finder.find(self.mesh, start, goal)

    def poly_count(self) -> Int:
        return self.mesh.poly_count()
