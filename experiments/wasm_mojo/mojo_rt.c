/* ===========================================================================
 * The Mojo runtime symbols a retargeted Mojo core needs on freestanding
 * wasm32 (W1). Found by listing the `declare`s of experiments/wasm_mojo's
 * retargeted IR (build.py prints them); nothing else is provided.
 *
 *   KGEN_CompilerRT_AlignedAlloc(align, size) / KGEN_CompilerRT_AlignedFree
 *       every Mojo heap allocation (List growth included)
 *   KGEN_CompilerRT_fprintf, write, dup, fdopen, fflush, fclose
 *       only on the stdlib's error-reporting path, right before llvm.trap
 *       (unreachable in wasm); stubs that report failure
 *
 * Allocator: power-of-two size classes from 16 bytes, one free list per
 * class, fresh memory from a bump pointer over __heap_base, growing linear
 * memory with memory.grow. Every block has a 16-byte header holding its
 * class, so the user pointer is 16-byte aligned; a request for a larger
 * alignment traps. Mojo's List reallocates by alloc + copy + free, so a free
 * list matters: with a bump pointer alone every growth step would leak.
 * ===========================================================================*/

typedef unsigned long usize;
typedef long long i64;
typedef int i32;

extern unsigned char __heap_base;

#define HDR 16u
#define CLASSES 40

static usize g_bump = 0;
static void *g_free[CLASSES];

static unsigned class_of(usize n) {
  unsigned c = 0;
  usize cap = 16;
  while (cap < n) {
    cap <<= 1;
    c++;
  }
  return c;
}

static void *bump(usize n) {
  if (g_bump == 0) g_bump = ((usize)&__heap_base + 15u) & ~(usize)15u;
  usize end = g_bump + n;
  usize have = __builtin_wasm_memory_size(0) * 65536u;
  if (end > have) {
    usize pages = (end - have + 65535u) / 65536u;
    if (__builtin_wasm_memory_grow(0, pages) == (usize)-1) __builtin_trap();
  }
  void *p = (void *)g_bump;
  g_bump = end;
  return p;
}

__attribute__((visibility("default")))
void *KGEN_CompilerRT_AlignedAlloc(i64 align, i64 size) {
  if (align > (i64)HDR || size < 0) __builtin_trap();
  unsigned c = class_of((usize)size);
  unsigned char *blk;
  if (g_free[c]) {
    blk = (unsigned char *)g_free[c];
    g_free[c] = *(void **)(blk + HDR);
  } else {
    blk = (unsigned char *)bump(HDR + ((usize)16 << c));
  }
  *(unsigned *)blk = c;
  return blk + HDR;
}

__attribute__((visibility("default")))
void KGEN_CompilerRT_AlignedFree(void *p) {
  if (!p) return;
  unsigned char *blk = (unsigned char *)p - HDR;
  unsigned c = *(unsigned *)blk;
  *(void **)(blk + HDR) = g_free[c];
  g_free[c] = blk;
}

/* error-path stubs */
__attribute__((visibility("default"))) i32 KGEN_CompilerRT_fprintf(i64 f, const char *fmt, ...) { return -1; }
__attribute__((visibility("default"))) i64 write(i64 fd, const void *buf, i64 n) { return -1; }
__attribute__((visibility("default"))) i32 dup(i32 fd) { return -1; }
__attribute__((visibility("default"))) i64 fdopen(i32 fd, const char *mode) { return 0; }
__attribute__((visibility("default"))) i32 fflush(i64 f) { return 0; }
__attribute__((visibility("default"))) i32 fclose(i64 f) { return 0; }

/* allocator statistics for tests: bytes taken from the bump pointer */
__attribute__((export_name("mojo_rt_heap_used")))
i32 mojo_rt_heap_used(void) { return g_bump ? (i32)(g_bump - (usize)&__heap_base) : 0; }
