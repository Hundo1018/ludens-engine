"""The renderer's passes as a compile-time list (plan 2.4, issue #90).

A RenderPass is made once per device by `create`, then each frame `prepare` does everything that can fail (uploads,
grouping, capacity checks, buffer writes) before the render pass opens, and `record_color` only sets state and draws
into the frame's colour pass. `Then[P, Q]` is itself a RenderPass that runs P, then Q, so any list of passes is a nested
`Then`, chosen at compile time:

    comptime MyPasses = Then[PrimitivePass, Then[MeshPass, Then[SkinnedPass, MyOutlinePass]]]
    var r = ArenaRendererOf[MyPasses](device, format, view)

The renderer (app/render3d.mojo) owns what the passes share and hands it to them: the draw items, the mesh registry and
its GPU copies (GpuMeshCache), the skinning palette, the view, the textures and RenderResources (camera, shadow map and
uniform, atmosphere, AO). The camera header is written by the renderer before `prepare`.

Why a binary composite and not `Pipeline[*Ps]`: the renderer must build its passes itself (`ArenaRenderer(device,
format, view)`), and Mojo 1.2.0 has no safe way to build the elements of a `Tuple[*Ps]` one by one inside a
`comptime for`; `Then.create` builds both halves with ordinary calls.
"""
from wgpu.device import Device
from wgpu.render_pass import FrameRenderPass, RenderPassEncoder
from game.draw_item import DrawItem
from game.camera_view import View
from app.mesh_data import MeshRegistry
from app.gpu_mesh import GpuMeshCache
from app.render_res import RenderResources, RenderCaps
from app.textures import TextureArray


trait RenderPass(Movable, Deinitable):
    comptime SHADOW: Bool
    """True if the pass records into the shadow map (record_shadow); the renderer opens the depth pass only then."""

    @staticmethod
    def create(
        device: Device, color_format: UInt32, depth_format: UInt32, ref textures: TextureArray,
        ref res: RenderResources, caps: RenderCaps,
    ) raises -> Self:
        """Build the pass's pipelines and buffers for this device and these formats."""
        ...

    def prepare(
        mut self, device: Device, items: List[DrawItem], meshes: MeshRegistry, mut gpu: GpuMeshCache,
        palette: List[Float32], view: View, res: RenderResources,
    ) raises:
        """Everything that can fail this frame, before the colour pass opens."""
        ...

    def record_color(self, mut rpass: FrameRenderPass, meshes: MeshRegistry, gpu: GpuMeshCache):
        """Set state and draw into the frame's colour pass. Nothing here can fail."""
        pass

    def record_shadow(self, mut rpass: RenderPassEncoder, meshes: MeshRegistry, gpu: GpuMeshCache):
        """Draw into the shadow map's depth pass, opened before the colour pass while the renderer's shadow is on."""
        pass

    @staticmethod
    def sig() -> String:
        """A short name of the pass (and of what configures it), for listing a pipeline's structure."""
        return "pass"


struct Then[P: RenderPass, Q: RenderPass](RenderPass):
    """P, then Q: prepared and recorded in that order."""

    comptime SHADOW: Bool = Self.P.SHADOW or Self.Q.SHADOW

    var first: Self.P
    var second: Self.Q

    def __init__(out self, var first: Self.P, var second: Self.Q):
        self.first = first^
        self.second = second^

    @staticmethod
    def create(
        device: Device, color_format: UInt32, depth_format: UInt32, ref textures: TextureArray,
        ref res: RenderResources, caps: RenderCaps,
    ) raises -> Self:
        var p = Self.P.create(device, color_format, depth_format, textures, res, caps)
        var q = Self.Q.create(device, color_format, depth_format, textures, res, caps)
        return Self(p^, q^)

    def prepare(
        mut self, device: Device, items: List[DrawItem], meshes: MeshRegistry, mut gpu: GpuMeshCache,
        palette: List[Float32], view: View, res: RenderResources,
    ) raises:
        self.first.prepare(device, items, meshes, gpu, palette, view, res)
        self.second.prepare(device, items, meshes, gpu, palette, view, res)

    def record_color(self, mut rpass: FrameRenderPass, meshes: MeshRegistry, gpu: GpuMeshCache):
        self.first.record_color(rpass, meshes, gpu)
        self.second.record_color(rpass, meshes, gpu)

    @staticmethod
    def sig() -> String:
        return Self.P.sig() + " + " + Self.Q.sig()

    def record_shadow(self, mut rpass: RenderPassEncoder, meshes: MeshRegistry, gpu: GpuMeshCache):
        self.first.record_shadow(rpass, meshes, gpu)
        self.second.record_shadow(rpass, meshes, gpu)


trait AuxTarget(Movable, Deinitable):
    """A second picture of the frame's items for the post stages to read (app/post.mojo `aux`), drawn by a pass list
    of its own into an RGBA8 target the size of the frame, with its own depth buffer."""

    comptime ON: Bool

    @staticmethod
    def create(
        device: Device, color_format: UInt32, depth_format: UInt32, ref textures: TextureArray,
        ref res: RenderResources, caps: RenderCaps,
    ) raises -> Self:
        ...

    def prepare(
        mut self, device: Device, items: List[DrawItem], meshes: MeshRegistry, mut gpu: GpuMeshCache,
        palette: List[Float32], view: View, res: RenderResources,
    ) raises:
        ...

    def record(self, mut rpass: FrameRenderPass, meshes: MeshRegistry, gpu: GpuMeshCache):
        ...

    @staticmethod
    def sig() -> String:
        return ""


struct NoAux(AuxTarget):
    comptime ON: Bool = False

    def __init__(out self):
        pass

    @staticmethod
    def create(
        device: Device, color_format: UInt32, depth_format: UInt32, ref textures: TextureArray,
        ref res: RenderResources, caps: RenderCaps,
    ) raises -> Self:
        return Self()

    def prepare(
        mut self, device: Device, items: List[DrawItem], meshes: MeshRegistry, mut gpu: GpuMeshCache,
        palette: List[Float32], view: View, res: RenderResources,
    ) raises:
        pass

    def record(self, mut rpass: FrameRenderPass, meshes: MeshRegistry, gpu: GpuMeshCache):
        pass


struct Aux[G: RenderPass](AuxTarget):
    """The pass list G drawn into the aux target. What it holds is G's choice; the convention the post prelude's
    `gnormal` and `gedge` read is rgb = 0.5 + 0.5 world normal, a = 1 on a surface (the target is cleared to a = 0):
    `Aux[NormalPasses]` (app/gbuffer.mojo)."""

    comptime ON: Bool = True
    var passes: Self.G

    def __init__(out self, var passes: Self.G):
        self.passes = passes^

    @staticmethod
    def create(
        device: Device, color_format: UInt32, depth_format: UInt32, ref textures: TextureArray,
        ref res: RenderResources, caps: RenderCaps,
    ) raises -> Self:
        return Self(Self.G.create(device, color_format, depth_format, textures, res, caps))

    def prepare(
        mut self, device: Device, items: List[DrawItem], meshes: MeshRegistry, mut gpu: GpuMeshCache,
        palette: List[Float32], view: View, res: RenderResources,
    ) raises:
        self.passes.prepare(device, items, meshes, gpu, palette, view, res)

    def record(self, mut rpass: FrameRenderPass, meshes: MeshRegistry, gpu: GpuMeshCache):
        self.passes.record_color(rpass, meshes, gpu)

    @staticmethod
    def sig() -> String:
        return "Aux[" + Self.G.sig() + "]"
