/* ===========================================================================
 * Stand-in ENGINE CORE demonstrating the platform-inversion architecture.
 *
 * The core is pure compute. It IMPORTS platform services from the host
 * (`host.log`, `host.now_ms`, `host.draw_rect`) and EXPORTS the engine loop
 * (`engine_init`, `engine_update`). It reuses the SparseSet (linked in the same
 * module, layer A) as its entity registry.
 *
 * This is the wasm reincarnation of legacy/renderer.mojo: that desktop loop did
 * `box1.local.x += 1` each frame and called into pygfx/wgpu. Here the core does
 * the simulation and hands draw commands to the host, which owns WebGPU. Same
 * game, but the renderer moved out of the core and into JS -- exactly what the
 * browser-first decision requires.
 *
 * Imports use import_module("host") / import_name(...) so they line up with the
 * `host` interface in wit/ludens.wit; the component tooling (scripts/
 * componentize.sh) later formalizes this same shape as the canonical ABI.
 * ===========================================================================*/

__attribute__((import_module("host"), import_name("log")))
extern void host_log(const char *ptr, int len);
__attribute__((import_module("host"), import_name("now_ms")))
extern double host_now_ms(void);
__attribute__((import_module("host"), import_name("draw_rect")))
extern void host_draw_rect(float x, float y, float w, float h, unsigned rgba);

/* From the SparseSet core, resolved at link time (layer A). */
extern void *ss_create(int fixed_size);
extern void ss_add(void *s, int key);
extern int ss_len(void *s);
extern int ss_dense_at(void *s, int i);

static void *g_entities = 0;
static float g_box_x = 0.0f; /* mirrors renderer.mojo: box1.local.x += 1 */
static double g_start_ms = 0.0;

static int cstrlen(const char *s) {
  int n = 0;
  while (s[n]) n++;
  return n;
}

__attribute__((export_name("engine_init")))
void engine_init(unsigned capacity) {
  g_entities = ss_create((int)capacity);
  for (unsigned i = 0; i < capacity; i++) ss_add(g_entities, (int)i);
  g_box_x = 0.0f;
  g_start_ms = host_now_ms();
  const char *m = "ludens: engine_init ok";
  host_log(m, cstrlen(m));
}

__attribute__((export_name("engine_update")))
void engine_update(float dt) {
  g_box_x += 60.0f * dt; /* 60 px/s, framerate-independent */
  int n = ss_len(g_entities);
  for (int i = 0; i < n; i++) {
    int e = ss_dense_at(g_entities, i);
    float x = g_box_x + (float)e * 24.0f;
    unsigned rgba = 0xff0000ffu; /* red, like MeshBasicMaterial((1,0,0,1)) */
    host_draw_rect(x, 0.0f, 20.0f, 20.0f, rgba);
  }
}

__attribute__((export_name("engine_entity_count")))
unsigned engine_entity_count(void) { return (unsigned)ss_len(g_entities); }
