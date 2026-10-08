"""Closed triangle meshes used as fixtures by the fracture tests and bench
(ROADMAP 17.5): flat Float64 vertices and Int indices, CCW from outside."""


struct MeshData(Movable):
    var v: List[Float64]
    var t: List[Int]

    def __init__(out self):
        self.v = List[Float64]()
        self.t = List[Int]()

    def vert(mut self, x: Float64, y: Float64, z: Float64) -> Int:
        self.v.append(x)
        self.v.append(y)
        self.v.append(z)
        return len(self.v) // 3 - 1

    def tri(mut self, a: Int, b: Int, c: Int):
        self.t.append(a)
        self.t.append(b)
        self.t.append(c)


def prism(outline: List[Float64], tris: List[Int], z0: Float64, z1: Float64) -> MeshData:
    """Extrude the CCW polygon `outline` (flat x, y) between z0 and z1; `tris`
    is a CCW triangulation of the polygon (indices into the outline)."""
    var m = MeshData()
    var n = len(outline) // 2
    for i in range(n):
        _ = m.vert(outline[2 * i], outline[2 * i + 1], z0)
    for i in range(n):
        _ = m.vert(outline[2 * i], outline[2 * i + 1], z1)
    for f in range(len(tris) // 3):
        m.tri(n + tris[3 * f], n + tris[3 * f + 1], n + tris[3 * f + 2])  # top
        m.tri(tris[3 * f], tris[3 * f + 2], tris[3 * f + 1])  # bottom
    for i in range(n):
        var j = (i + 1) % n
        m.tri(i, j, n + j)
        m.tri(i, n + j, n + i)
    return m^


def l_prism(thick: Float64) -> MeshData:
    """An L-shaped slab: the 2 x 2 square minus its upper-right unit square,
    z in [0, thick]. Volume 3 * thick; concave along the inner corner."""
    var o = List[Float64]()
    for q in [0.0, 0.0, 2.0, 0.0, 2.0, 1.0, 1.0, 1.0, 1.0, 2.0, 0.0, 2.0]:
        o.append(q)
    var t = List[Int]()
    for q in [0, 1, 2, 0, 2, 3, 0, 3, 4, 0, 4, 5]:
        t.append(q)
    return prism(o, t, 0.0, thick)


def u_prism(thick: Float64) -> MeshData:
    """A U-shaped slab: 3 x 2 minus a 1 x 1 notch cut from the top middle."""
    var o = List[Float64]()
    for q in [0.0, 0.0, 3.0, 0.0, 3.0, 2.0, 2.0, 2.0, 2.0, 1.0, 1.0, 1.0, 1.0, 2.0, 0.0, 2.0]:
        o.append(q)
    var t = List[Int]()
    # CCW fan-free triangulation of the U outline
    for q in [0, 1, 4, 0, 4, 5, 0, 5, 7, 5, 6, 7, 1, 2, 3, 1, 3, 4]:
        t.append(q)
    return prism(o, t, 0.0, thick)


def box_mesh(hx: Float64, hy: Float64, hz: Float64) -> MeshData:
    """A closed box centred on the origin, 12 triangles."""
    var o = List[Float64]()
    for q in [-hx, -hy, hx, -hy, hx, hy, -hx, hy]:
        o.append(q)
    var t = List[Int]()
    for q in [0, 1, 2, 0, 2, 3]:
        t.append(q)
    return prism(o, t, -hz, hz)
