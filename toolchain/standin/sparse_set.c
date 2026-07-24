/* ===========================================================================
 * FAITHFUL STAND-IN for src/core/sparse_set.mojo  (NOT the engine source).
 *
 * Why this file exists
 * --------------------
 * The Mojo compiler cannot yet emit LLVM IR for a whole module, and Modular's
 * package channel is unreachable from this build environment, so we cannot run
 * `mojo` here. This C file reproduces the EXACT semantics and the EXACT wasm
 * ABI that the Mojo `SparseSet` core will expose, so the entire retarget
 * back-half (IR -> llc -> wasm-ld -> .wasm), the host bindings, the layer-A
 * linking and the differential test harness can be built and PROVEN today.
 *
 * When `mojo` can emit IR, drop its `-emit-llvm` output in front of `llc` in
 * scripts/emit-and-link.sh; this file is then only kept as a cross-check.
 * The `export_name(...)` symbols below are the contract both sides must honor.
 *
 * Runtime model: freestanding wasm32 (-nostdlib). No libc. Memory comes from a
 * bump allocator over `__heap_base` (a symbol wasm-ld provides) -- this mirrors
 * exactly what a Mojo wasm core needs: its own allocator for `List`, because
 * the native stdlib's mmap/malloc do not exist on wasm.
 * ===========================================================================*/

typedef unsigned long usize;

/* wasm-ld defines __heap_base at the end of static data. */
extern unsigned char __heap_base;
static usize g_bump = 0;

static void *balloc(usize n) {
  if (g_bump == 0) g_bump = (usize)&__heap_base;
  g_bump = (g_bump + 7u) & ~(usize)7u; /* 8-byte align */
  void *p = (void *)g_bump;
  g_bump += n;
  return p;
}

/* Mirrors: struct SparseSet[fixed_size, *keys] { _sparse, _dense } */
typedef struct {
  int fixed_size;
  int dense_len;
  int *sparse; /* fixed_size ints: key -> index into dense (or -1)          */
  int *dense;  /* up to fixed_size ints: the packed keys                    */
} SparseSet;

__attribute__((export_name("ss_create")))
SparseSet *ss_create(int fixed_size) {
  SparseSet *s = (SparseSet *)balloc(sizeof(SparseSet));
  s->fixed_size = fixed_size;
  s->dense_len = 0;
  s->sparse = (int *)balloc(sizeof(int) * (usize)fixed_size);
  s->dense = (int *)balloc(sizeof(int) * (usize)fixed_size);
  for (int i = 0; i < fixed_size; i++) s->sparse[i] = -1;
  return s;
}

__attribute__((export_name("ss_contains")))
int ss_contains(SparseSet *s, int key) {
  if (key < 0 || key >= s->fixed_size) return 0;
  int idx = s->sparse[key];
  return (idx >= 0 && idx < s->dense_len && s->dense[idx] == key) ? 1 : 0;
}

__attribute__((export_name("ss_add")))
void ss_add(SparseSet *s, int key) {
  if (key < 0 || key >= s->fixed_size) return;
  if (ss_contains(s, key)) return;
  s->sparse[key] = s->dense_len;
  s->dense[s->dense_len] = key;
  s->dense_len += 1;
}

__attribute__((export_name("ss_remove")))
void ss_remove(SparseSet *s, int key) {
  if (!ss_contains(s, key)) return;
  int idx = s->sparse[key];
  int last = s->dense[s->dense_len - 1];
  /* canonical swap-remove: move `last` into the hole AND fix its sparse index,
   * clearing the removed key's slot last.
   * NOTE: the original sparseset.mojo omits the `sparse[last] = idx` update
   * -- a real bug that this stand-in (and the migrated Mojo core) correct. */
  s->dense[idx] = last;
  s->sparse[last] = idx;
  s->dense_len -= 1;
  s->sparse[key] = -1;
}

__attribute__((export_name("ss_len")))
int ss_len(SparseSet *s) { return s->dense_len; }

__attribute__((export_name("ss_dense_at")))
int ss_dense_at(SparseSet *s, int i) { return s->dense[i]; }

/* Zero-copy view: byte offset (into linear memory) of the dense array.
 * This is the layer-A hand-off point -- C/C++/Rust/JS read the packed keys
 * directly out of shared linear memory, no serialization. */
__attribute__((export_name("ss_dense_ptr")))
int *ss_dense_ptr(SparseSet *s) { return s->dense; }
