/* ===========================================================================
 * Minimal freestanding wasm runtime shim.
 *
 * Any LLVM-based core compiled `-nostdlib` for wasm32 may still emit calls to
 * mem* libcalls (the optimizer turns init loops / struct copies into them).
 * A Mojo wasm core needs exactly the same handful of primitives. Keeping them
 * here -- tiny, auditable, target-agnostic -- is the whole "runtime shim" that
 * the retarget strategy commits to maintaining (vs. porting the native stdlib).
 * ===========================================================================*/

typedef unsigned long usize;

__attribute__((visibility("default")))
void *memset(void *dst, int c, usize n) {
  unsigned char *d = (unsigned char *)dst;
  for (usize i = 0; i < n; i++) d[i] = (unsigned char)c;
  return dst;
}

__attribute__((visibility("default")))
void *memcpy(void *dst, const void *src, usize n) {
  unsigned char *d = (unsigned char *)dst;
  const unsigned char *s = (const unsigned char *)src;
  for (usize i = 0; i < n; i++) d[i] = s[i];
  return dst;
}

__attribute__((visibility("default")))
void *memmove(void *dst, const void *src, usize n) {
  unsigned char *d = (unsigned char *)dst;
  const unsigned char *s = (const unsigned char *)src;
  if (d < s) {
    for (usize i = 0; i < n; i++) d[i] = s[i];
  } else {
    for (usize i = n; i != 0; i--) d[i - 1] = s[i - 1];
  }
  return dst;
}
