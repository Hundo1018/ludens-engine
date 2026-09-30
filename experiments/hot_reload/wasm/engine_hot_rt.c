/* ===========================================================================
 * What engine_hot.mojo needs on wasm32 and cannot express in Mojo (W1):
 *
 *   ludens_state_slot()   the address of one 8-byte static holding the
 *                         engine's state pointer (Mojo has no globals)
 *   ludens_snap_ptr()     the snapshot buffer; also exported as
 *                         engine_snapshot_ptr, the ABI of engine_hot.c
 *   ludens_host_log / ludens_host_draw_rect
 *                         calls to the `host` module's imports. Mojo's
 *                         external_call declares a plain symbol, which
 *                         wasm-ld would import from module "env"; the
 *                         import attributes live here instead.
 *
 * Addresses cross the boundary as Mojo `Int`, 32-bit because the IR is
 * emitted for riscv32 (experiments/wasm_mojo/build.py); caller and callee
 * signatures must match exactly, or wasm-ld reports a mismatch.
 * ===========================================================================*/

typedef unsigned long usize;
typedef long iptr;

__attribute__((import_module("host"), import_name("log")))
extern void host_log(const char *ptr, int len);
__attribute__((import_module("host"), import_name("draw_rect")))
extern void host_draw_rect(float x, float y, float w, float h, unsigned rgba);

static iptr g_state;

#define SNAP_MAX_WORDS 16384 /* 64 KiB: engine_hot.mojo's SNAP_MAX_BYTES (schema records, W2) */
static unsigned long long g_snap_storage[SNAP_MAX_WORDS / 2]; /* 8-byte aligned for the u64 header */
#define g_snap ((unsigned *)g_snap_storage)

__attribute__((visibility("default"))) iptr ludens_state_slot(void) { return (iptr)&g_state; }
__attribute__((visibility("default"))) iptr ludens_snap_ptr(void) { return (iptr)g_snap; }

__attribute__((export_name("engine_snapshot_ptr")))
unsigned *engine_snapshot_ptr(void) { return g_snap; }

__attribute__((visibility("default")))
void ludens_host_log(iptr ptr, int len) { host_log((const char *)ptr, len); }

__attribute__((visibility("default")))
void ludens_host_draw_rect(float x, float y, float w, float h, unsigned rgba) { host_draw_rect(x, y, w, h, rgba); }
