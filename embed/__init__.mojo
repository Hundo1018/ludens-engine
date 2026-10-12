"""Embedding boundary (ROADMAP 12.1): the API a host engine drives through
the C-ABI shared library built from `embed/capi.mojo` (`pixi run capi`).
`world` holds the simulation a handle points at, `navigation` a baked
navmesh; both validate caller input once and raise, and the C layer turns
raises into status codes."""
