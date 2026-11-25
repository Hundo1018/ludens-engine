"""Bind group layout entries the vertex-pulling passes repeat (the terrain, decal and trail passes of #140): a read-only
storage buffer, a float 2D-array texture and a filtering sampler. Same fields as app/particle_pass.mojo writes out."""
from wgpu import (
    WGPUBufferBindingType, WGPUBindGroupLayoutEntry, WGPUBufferBindingLayout, WGPUSamplerBindingLayout,
    WGPUTextureBindingLayout, WGPUStorageTextureBindingLayout, WGPUBindGroupEntry, WGPU_WHOLE_SIZE,
)
from wgpu import null_opaque
from wgpu.buffer import Buffer
from wgpu.sampler import Sampler
from wgpu.texture import TextureView


def storage_entry(binding: UInt32, visibility: UInt64) -> WGPUBindGroupLayoutEntry:
    return WGPUBindGroupLayoutEntry(
        null_opaque(), binding, visibility, UInt32(0),
        WGPUBufferBindingLayout(null_opaque(), WGPUBufferBindingType.ReadOnlyStorage, UInt32(0), UInt64(0)),
        WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
        WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
        WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
    )


def texture_array_entry(binding: UInt32, visibility: UInt64) -> WGPUBindGroupLayoutEntry:
    return WGPUBindGroupLayoutEntry(
        null_opaque(), binding, visibility, UInt32(0),
        WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),
        WGPUSamplerBindingLayout(null_opaque(), UInt32(0)),
        WGPUTextureBindingLayout(null_opaque(), UInt32(2), UInt32(3), UInt32(0)),  # float, 2D array
        WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
    )


def sampler_entry(binding: UInt32, visibility: UInt64) -> WGPUBindGroupLayoutEntry:
    return WGPUBindGroupLayoutEntry(
        null_opaque(), binding, visibility, UInt32(0),
        WGPUBufferBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt64(0)),
        WGPUSamplerBindingLayout(null_opaque(), UInt32(2)),  # filtering
        WGPUTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
        WGPUStorageTextureBindingLayout(null_opaque(), UInt32(0), UInt32(0), UInt32(0)),
    )


def buffer_bind(binding: UInt32, buffer: Buffer) -> WGPUBindGroupEntry:
    return WGPUBindGroupEntry(null_opaque(), binding, buffer.handle().raw, 0, WGPU_WHOLE_SIZE, null_opaque(), null_opaque())


def view_bind(binding: UInt32, view: TextureView) -> WGPUBindGroupEntry:
    return WGPUBindGroupEntry(null_opaque(), binding, null_opaque(), 0, UInt64(0), null_opaque(), view.handle().raw)


def sampler_bind(binding: UInt32, sampler: Sampler) -> WGPUBindGroupEntry:
    return WGPUBindGroupEntry(null_opaque(), binding, null_opaque(), 0, UInt64(0), sampler.handle().raw, null_opaque())
