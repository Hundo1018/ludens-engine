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
 * Addresses cross the boundary as 64-bit integers: Mojo's `Int` stays i64 in
 * the retargeted IR (experiments/wasm_mojo/retarget_ir.py), and a signature
 * mismatch between caller and callee is a wasm-ld error.
 * ===========================================================================*/

typedef unsigned long usize;
typedef long long i64;

__attribute__((import_module("host"), import_name("log")))
extern void host_log(const char *ptr, int len);
__attribute__((import_module("host"), import_name("draw_rect")))
extern void host_draw_rect(float x, float y, float w, float h, unsigned rgba);

static i64 g_state;

#define SNAP_MAX_WORDS 4096
static unsigned g_snap[SNAP_MAX_WORDS];

__attribute__((visibility("default"))) i64 ludens_state_slot(void) { return (i64)(usize)&g_state; }
__attribute__((visibility("default"))) i64 ludens_snap_ptr(void) { return (i64)(usize)g_snap; }

__attribute__((export_name("engine_snapshot_ptr")))
unsigned *engine_snapshot_ptr(void) { return g_snap; }

__attribute__((visibility("default")))
void ludens_host_log(i64 ptr, int len) { host_log((const char *)(usize)ptr, len); }

__attribute__((visibility("default")))
void ludens_host_draw_rect(float x, float y, float w, float h, unsigned rgba) { host_draw_rect(x, y, w, h, rgba); }
