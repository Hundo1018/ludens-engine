"""Host-side platform seams (docs/platform.md): each one a compile-time trait with a web and a native implementation.

Standard library only. Import a backend module by name: the native ones call libc and must not be reachable from the
wasm64 module, so this package re-exports nothing."""
