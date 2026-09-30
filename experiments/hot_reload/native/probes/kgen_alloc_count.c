/* LD_PRELOAD shim: counts Mojo heap allocations that are still live.
 *
 * Mojo code allocates through KGEN_CompilerRT_AlignedAlloc / AlignedFree
 * (libKGENCompilerRTShared.so), which forward to TCMalloc
 * (modular/modular Mojo/lib/CompilerRT/Memory.cpp). TCMalloc keeps freed
 * memory in its own free lists, so VmRSS cannot tell a leak from memory
 * the allocator retains. This shim interposes both symbols, keeps
 * ptr -> size for every live block and prints at exit:
 *
 *   kgen_alloc live_count=<n> live_bytes=<b> allocs=<a> frees=<f>
 *
 *   cc -O2 -shared -fPIC -o kgen_alloc_count.so kgen_alloc_count.c -ldl
 *   LD_PRELOAD=./kgen_alloc_count.so build/hot_native/host ...
 *
 * Used by run_native.py r1 (1000 swaps). Single-threaded use only: the host
 * and engines call it from one thread.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/types.h>

#define SLOTS (1u << 20)
static uintptr_t keys[SLOTS];
static size_t sizes[SLOTS];
static long live_count, live_bytes, allocs, frees;
static void *(*real_alloc)(ssize_t, ssize_t);
static void (*real_free)(void *);

static size_t slot(uintptr_t p) { return (size_t)((p >> 4) * 0x9E3779B97F4A7C15ull) & (SLOTS - 1); }

static void put(uintptr_t p, size_t n) {
    for (size_t i = slot(p);; i = (i + 1) & (SLOTS - 1))
        if (keys[i] == 0 || keys[i] == 1) { keys[i] = p; sizes[i] = n; return; }
}

static long take(uintptr_t p) {
    for (size_t i = slot(p);; i = (i + 1) & (SLOTS - 1)) {
        if (keys[i] == 0) return -1;
        if (keys[i] == p) { keys[i] = 1; return (long)sizes[i]; } /* 1 = tombstone */
    }
}

void *KGEN_CompilerRT_AlignedAlloc(ssize_t alignment, ssize_t size) {
    if (!real_alloc) real_alloc = (void *(*)(ssize_t, ssize_t))dlsym(RTLD_NEXT, "KGEN_CompilerRT_AlignedAlloc");
    void *p = real_alloc(alignment, size);
    if (p) { put((uintptr_t)p, (size_t)size); live_count++; live_bytes += size; allocs++; }
    return p;
}

void KGEN_CompilerRT_AlignedFree(void *p) {
    if (!real_free) real_free = (void (*)(void *))dlsym(RTLD_NEXT, "KGEN_CompilerRT_AlignedFree");
    if (p) {
        long n = take((uintptr_t)p);
        if (n >= 0) { live_count--; live_bytes -= n; }
        frees++;
    }
    real_free(p);
}

__attribute__((destructor)) static void report(void) {
    fprintf(stderr, "kgen_alloc live_count=%ld live_bytes=%ld allocs=%ld frees=%ld\n",
            live_count, live_bytes, allocs, frees);
}
