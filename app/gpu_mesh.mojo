"""What the mesh, skinned and shadow passes share (plan 2.2): the GPU copies of the registered meshes, the grouping of
draw items by mesh, and the camera header.

GpuMeshCache holds one set of vertex and index buffers per mesh; every pass that draws meshes binds from it, so a
mesh is uploaded once however many passes draw it. MeshBatches[SKINNED] groups the static (SKINNED False) or the
skinned (True) mesh items by mesh, in first-seen order, and lists the items of each group in their order in the frame:
the instance records are written in that order and each group is one instanced draw from base[k]. cam_floats packs a
View into the 16-float camera header the mesh shaders read.
"""
from wgpu import WGPUBufferUsage
from wgpu.buffer import Buffer
from wgpu.device import Device
from game.draw_item import DrawItem
from game.camera_view import View
from app.mesh_data import MeshRegistry

# the buffers of one static mesh, in GpuMeshCache.vbufs[STATIC_BUFFERS * mesh + k]
comptime STATIC_BUFFERS = 3
comptime S_POS = 0  # float32x3
comptime S_NRM = 1  # float32x3
comptime S_UV = 2  # float32x2
# the buffers of one skinned mesh, in GpuMeshCache.skin_vbufs[SKINNED_BUFFERS * mesh + k]
comptime SKINNED_BUFFERS = 5
comptime K_POS = 0  # float32x3
comptime K_NRM = 1  # float32x3
comptime K_UV = 2  # float32x2
comptime K_JNT = 3  # uint16x4
comptime K_WGT = 4  # float32x4


def _vertex_buffer[T: Copyable & Movable](device: Device, data: List[T], bytes_per: Int, label: String) raises -> Buffer:
    var b = device.create_buffer(UInt64(len(data) * bytes_per), WGPUBufferUsage.VERTEX | WGPUBufferUsage.COPY_DST, label=label)
    device.queue_write_data(b, UInt64(0), data)
    return b^


struct GpuMeshCache(Movable):
    """The GPU copies of a MeshRegistry's meshes. sync() uploads the meshes added since the last call and rewrites the
    positions and normals of a dynamic mesh whose version changed. Meshes are never freed here."""

    var vbufs: List[Buffer]  # STATIC_BUFFERS per static mesh
    var ibufs: List[Buffer]  # one per static mesh
    var seen: List[Int]  # per static mesh: the registry version its buffers hold
    var skin_vbufs: List[Buffer]  # SKINNED_BUFFERS per skinned mesh
    var skin_ibufs: List[Buffer]  # one per skinned mesh

    def __init__(out self):
        self.vbufs = List[Buffer]()
        self.ibufs = List[Buffer]()
        self.seen = List[Int]()
        self.skin_vbufs = List[Buffer]()
        self.skin_ibufs = List[Buffer]()

    def uploaded(self) -> Int:
        """Static meshes with GPU copies."""
        return len(self.ibufs)

    def skinned_uploaded(self) -> Int:
        """Skinned meshes with GPU copies."""
        return len(self.skin_ibufs)

    def sync(mut self, device: Device, registry: MeshRegistry) raises:
        while self.uploaded() < registry.count():
            var i = self.uploaded()
            self.vbufs.append(_vertex_buffer(device, registry.meshes[i].positions, 4, "mesh_pos"))
            self.vbufs.append(_vertex_buffer(device, registry.meshes[i].normals, 4, "mesh_nrm"))
            self.vbufs.append(_vertex_buffer(device, registry.meshes[i].uv, 4, "mesh_uv"))
            var ib = device.create_buffer(
                UInt64(len(registry.meshes[i].indices) * 4), WGPUBufferUsage.INDEX | WGPUBufferUsage.COPY_DST, label="mesh_idx",
            )
            device.queue_write_data(ib, UInt64(0), registry.meshes[i].indices)
            self.ibufs.append(ib^)
            self.seen.append(registry.versions[i])
        # dynamic meshes whose positions changed since the last sync
        for i in range(self.uploaded()):
            if registry.versions[i] != self.seen[i]:
                device.queue_write_data(self.vbufs[STATIC_BUFFERS * i + S_POS], UInt64(0), registry.meshes[i].positions)
                device.queue_write_data(self.vbufs[STATIC_BUFFERS * i + S_NRM], UInt64(0), registry.meshes[i].normals)
                self.seen[i] = registry.versions[i]
        while self.skinned_uploaded() < len(registry.skinned):
            var i = self.skinned_uploaded()
            self.skin_vbufs.append(_vertex_buffer(device, registry.skinned[i].positions, 4, "skin_pos"))
            self.skin_vbufs.append(_vertex_buffer(device, registry.skinned[i].normals, 4, "skin_nrm"))
            self.skin_vbufs.append(_vertex_buffer(device, registry.skinned[i].uv, 4, "skin_uv"))
            self.skin_vbufs.append(_vertex_buffer(device, registry.skinned[i].joints, 2, "skin_joints"))
            self.skin_vbufs.append(_vertex_buffer(device, registry.skinned[i].weights, 4, "skin_weights"))
            var ib = device.create_buffer(
                UInt64(len(registry.skinned[i].indices) * 4), WGPUBufferUsage.INDEX | WGPUBufferUsage.COPY_DST, label="skin_idx",
            )
            device.queue_write_data(ib, UInt64(0), registry.skinned[i].indices)
            self.skin_ibufs.append(ib^)


struct MeshBatches[SKINNED: Bool](Movable):
    """The frame's static (SKINNED False: mesh_id >= 0, pose_id < 0) or skinned (True: mesh_id >= 0, pose_id >= 0)
    mesh items grouped by mesh. order[k] is group k's mesh, counts[k] its instances, base[k] its first instance;
    members lists item indices group by group, each group in frame order (the order of the instance records)."""

    var order: List[Int]
    var counts: List[Int]
    var base: List[Int]
    var members: List[Int]
    var total: Int

    def __init__(out self):
        self.order = List[Int]()
        self.counts = List[Int]()
        self.base = List[Int]()
        self.members = List[Int]()
        self.total = 0

    def __init__(out self, items: List[DrawItem]):
        self = Self()
        for it in items:
            if not Self.member(it):
                continue
            var found = -1
            for k in range(len(self.order)):
                if self.order[k] == it.mesh_id:
                    found = k
            if found < 0:
                self.order.append(it.mesh_id)
                self.counts.append(0)
                found = len(self.order) - 1
            self.counts[found] += 1
        for k in range(len(self.order)):
            self.base.append(self.total)
            self.total += self.counts[k]
            for i in range(len(items)):
                if items[i].mesh_id == self.order[k] and Self.member(items[i]):
                    self.members.append(i)

    @staticmethod
    def member(it: DrawItem) -> Bool:
        comptime if Self.SKINNED:
            return it.mesh_id >= 0 and it.pose_id >= 0
        else:
            return it.mesh_id >= 0 and it.pose_id < 0


def cam_floats(v: View) -> List[Float32]:
    """The camera header of the mesh shaders' `Cam` (16 floats): eye, right, up, fwd as vec4, with eye.w = sx,
    right.w = sy, up.w = near and fwd.w = far (the arena's projection). A parallel projection (View.orthographic) is
    marked by a negative sx: the shaders then scale by |sx| and sy without dividing by depth."""
    var cam = List[Float32]()
    for e in [v.eye, v.right, v.up, v.fwd]:
        for c in range(3):
            cam.append(Float32(e[c]))
        cam.append(0.0)
    cam[3] = Float32(-v.sx) if v.ortho else Float32(v.sx)
    cam[7] = Float32(v.sy)
    cam[11] = Float32(v.near)
    cam[15] = Float32(v.far)
    return cam^
