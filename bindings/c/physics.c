/* ===========================================================================
 * LAYER A demo: a SEPARATE language/translation-unit (here C; equally C++/Rust)
 * linked into the SAME wasm module as the engine core via `wasm-ld`.
 *
 * Because Mojo, C, C++ and Rust all lower through LLVM, their wasm objects link
 * together and share ONE linear memory. This function reads the core's packed
 * `dense` array straight out of shared memory -- zero copy, zero serialization.
 * That is the tight-integration tier the strategy reserves for LLVM-family
 * languages (physics engines, math kernels, existing C libraries).
 *
 * Two access styles are shown:
 *   physics_sum_keys(set)          -> via the core's exported accessors
 *   physics_sum_dense(ptr, n)      -> straight over raw shared linear memory
 * Both must equal the oracle's sum of the dense keys.
 * ===========================================================================*/

/* Imported from the engine core, resolved at link time (NOT a runtime import). */
extern int ss_len(void *set);
extern int ss_dense_at(void *set, int i);

__attribute__((export_name("physics_sum_keys")))
int physics_sum_keys(void *set) {
  int n = ss_len(set);
  int acc = 0;
  for (int i = 0; i < n; i++) acc += ss_dense_at(set, i);
  return acc;
}

/* Raw shared-memory access: `dense` is an int* into the same linear memory. */
__attribute__((export_name("physics_sum_dense")))
int physics_sum_dense(const int *dense, int n) {
  int acc = 0;
  for (int i = 0; i < n; i++) acc += dense[i];
  return acc;
}
