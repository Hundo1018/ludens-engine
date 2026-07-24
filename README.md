# LudensEngine

An ECS game engine written in **Mojo**, retargeted to **WebAssembly** and
architected browser-first: the simulation core compiles to wasm, while
rendering / input / audio live in the JavaScript host (WebGPU).

Mojo has no official wasm target yet (Modular issues
[#5367](https://github.com/modular/modular/issues/5367),
[#19](https://github.com/modular/modular/issues/19)). This repo takes the
**LLVM-IR retarget** path — intercept the IR the official Mojo compiler already
emits and lower it to `wasm32` with LLVM — so every current and future Mojo
language feature that reaches LLVM IR comes along for free, with no compiler fork.

## Architecture

```
              ┌──────────────────────── engine core (wasm) ────────────────────────┐
  Mojo src ──▶│  Mojo ─emit LLVM IR─▶ llc ─▶ wasm-ld ─┐                              │
              │                                        ├─ layer A: link C/C++/Rust   │
  C/C++/Rust ─┼──────────── clang --target=wasm32 ─────┘  into ONE linear memory     │
              └───────────────────────────────┬─────────────────────────────────────┘
                                               │ exports engine.*  / imports host.*
                        layer B (WIT + Component Model, jco) │
                                               ▼
         browser JS host (WebGPU, input, audio)  ·  Python via Pyodide/componentize-py
```

- **Layer A — zero copy.** Mojo, C, C++ and Rust all lower through LLVM, so
  `wasm-ld` links them into one module sharing one linear memory. Physics
  libraries, math kernels and existing C code integrate with no serialization.
- **Layer B — typed composition.** [`wit/ludens.wit`](wit/ludens.wit) is the
  cross-language contract; the Component Model + `jco` turn it into typed JS
  bindings (and, later, Python components). Rendering is inverted out of the
  core into the host — the wasm core just emits draw commands.

Full rationale, feature-preservation and testing strategy: see the approved
plan and **[STATUS.md](STATUS.md)**.

## Layout

| Path | What |
|---|---|
| `src/core/sparse_set.mojo` | the real engine core (nightly Mojo); native oracle |
| `wit/ludens.wit` | layer-B interface: `engine` exports, `host` imports |
| `toolchain/standin/` | faithful C stand-in for the wasm pipeline (until `mojo` can emit IR) |
| `toolchain/ir/` | golden LLVM-IR drift guard (baseline bootstrapped per toolchain by `scripts/ir-snapshot.sh`) |
| `bindings/js/` | browser host (`index.html`, `web.mjs`) + headless Node driver |
| `bindings/c/` | layer-A C physics linked into the core module |
| `tests/` | differential harness, capability corpus, layer-A test |
| `scripts/` | `emit-and-link`, `build-all`, `componentize`, `ir-snapshot`, `test-all` |
| `legacy/` | retired desktop pygfx/glfw prototype (not in the wasm path) |

## Quick start

Needs LLVM ≥ 18 (`clang`, `llc`, `wasm-ld`) and Node ≥ 20. **No Mojo toolchain
required** to build and test the wasm pipeline today (see STATUS.md for why, and
how to close the gate once `mojo` is available).

```bash
make test        # build every wasm artifact + run all proofs
make component   # WIT -> component -> typed JS bindings (needs npm for jco)
make serve       # then open http://localhost:8080/bindings/js/ for the browser demo
```

## Status

The retarget back-half, both interop layers, and the differential testing
methodology are **built and passing** on LLVM 18 + Node. The single gated stage
— Mojo emitting LLVM IR — is isolated behind a stable boundary and documented in
**[STATUS.md](STATUS.md)**.
