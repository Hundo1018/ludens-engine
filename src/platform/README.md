# Platform layer

The engine core is WASI-clean and imports all platform services (rendering,
input, time, audio) rather than calling the OS. Those services are:

- **declared** once, language-neutrally, as the `host` interface in
  [`../../wit/ludens.wit`](../../wit/ludens.wit);
- **implemented per host** — the browser/Node host lives in
  [`../../bindings/js/host.mjs`](../../bindings/js/host.mjs) (WebGPU in
  production); a `wasmtime`/WASI host would implement the same interface.

So there is deliberately no platform *code* in the wasm core here — that is the
point of the inversion. Mojo-side platform shims (e.g. the wasm bump allocator
that stands in for the native stdlib allocator, see
`../../toolchain/standin/wasm_rt.c`) will live in this directory once the Mojo
front-end is wired in (STATUS.md).
