/* ===========================================================================
 * Hot-reload experiment core: engine_core.c plus the hooks a live module swap
 * needs. Built several times with different -D knobs to play the role of
 * "the developer edited the source and rebuilt" (see variants in run.py).
 *
 * Knobs (compile-time, the "edits"):
 *   SPEED        px/s the boxes move                (code-only edit)
 *   COLOR        rgba of every box                   (code-only edit)
 *   MSG_V3       engine_init log text, same length   (read-only data edit)
 *   LAYOUT_V2    insert a field at the FRONT of the state struct (layout edit)
 *   LAYOUT_SWAP  swap two same-size fields            (layout edit, same size)
 *   EXTRA_STATIC new static declared before `g`, EngineState unchanged
 *
 * All engine state lives in ONE static struct `g` plus the SparseSet on the
 * bump heap, so "state" = linear memory. Two transfer paths are exported:
 *   engine_layout_id()          compile-time fingerprint of struct layout
 *   engine_save() / engine_load()  layout-independent snapshot through a
 *                               fixed scratch buffer (engine_snapshot_ptr()).
 * ===========================================================================*/

#ifndef SPEED
#define SPEED 60.0f
#endif
#ifndef COLOR
#define COLOR 0xff0000ffu
#endif
#ifdef MSG_V3
#define MSG "ludens: engine_init v3"
#else
#define MSG "ludens: engine_init v1"
#endif

__attribute__((import_module("host"), import_name("log")))
extern void host_log(const char *ptr, int len);
__attribute__((import_module("host"), import_name("draw_rect")))
extern void host_draw_rect(float x, float y, float w, float h, unsigned rgba);

extern void *ss_create(int fixed_size);
extern void ss_add(void *s, int key);
extern void ss_remove(void *s, int key);
extern int ss_len(void *s);
extern int ss_dense_at(void *s, int i);

typedef struct {
#ifdef LAYOUT_V2
  float speed_scale; /* new field inserted first: shifts every offset by 4 */
#endif
#ifdef LAYOUT_SWAP
  unsigned frame;
  unsigned capacity;
#else
  unsigned capacity;
  unsigned frame;
#endif
  float box_x;
  void *entities;
} EngineState;

#ifdef EXTRA_STATIC
static unsigned g_updates; /* debug counter added by the "edit" */
#endif
static EngineState g;

#define OFF(f) ((unsigned)__builtin_offsetof(EngineState, f))
__attribute__((export_name("engine_layout_id")))
unsigned engine_layout_id(void) {
  unsigned h = 2166136261u; /* FNV-1a over (sizeof, offsetof...) */
  unsigned v[] = {(unsigned)sizeof(EngineState), OFF(capacity), OFF(frame),
                  OFF(box_x), OFF(entities)};
  for (unsigned i = 0; i < sizeof(v) / sizeof(v[0]); i++) {
    h ^= v[i];
    h *= 16777619u;
  }
  return h;
}

static int cstrlen(const char *s) {
  int n = 0;
  while (s[n]) n++;
  return n;
}

__attribute__((export_name("engine_init")))
void engine_init(unsigned capacity) {
#ifdef LAYOUT_V2
  g.speed_scale = 1.0f;
#endif
  g.capacity = capacity;
  g.frame = 0;
  g.box_x = 0.0f;
  g.entities = ss_create((int)capacity);
  for (unsigned i = 0; i < capacity; i++) ss_add(g.entities, (int)i);
  const char *m = MSG;
  host_log(m, cstrlen(m));
}

__attribute__((export_name("engine_despawn")))
void engine_despawn(int e) { ss_remove(g.entities, e); }

__attribute__((export_name("engine_update")))
void engine_update(float dt) {
#ifdef LAYOUT_V2
  g.box_x += SPEED * g.speed_scale * dt;
#else
  g.box_x += SPEED * dt;
#endif
  g.frame += 1;
#ifdef EXTRA_STATIC
  g_updates += 1;
#endif
  int n = ss_len(g.entities);
  for (int i = 0; i < n; i++) {
    int e = ss_dense_at(g.entities, i);
    host_draw_rect(g.box_x + (float)e * 24.0f, 0.0f, 20.0f, 20.0f, COLOR);
  }
}

__attribute__((export_name("engine_entity_count")))
unsigned engine_entity_count(void) { return (unsigned)ss_len(g.entities); }

__attribute__((export_name("engine_frame")))
unsigned engine_frame(void) { return g.frame; }

#ifdef EXTRA_STATIC
__attribute__((export_name("engine_updates")))
unsigned engine_updates(void) { return g_updates; }
#endif

__attribute__((export_name("engine_log_msg")))
void engine_log_msg(void) {
  const char *m = MSG;
  host_log(m, cstrlen(m));
}

/* ---- snapshot: [magic, schema, capacity, frame, box_x bits, n, keys...] ----
 * Fixed-size static buffer so the host can find it without calling an
 * allocator. Schema 1 is independent of EngineState's in-memory layout. */
#define SNAP_MAGIC 0x4c444e53u /* "SNDL" */
#define SNAP_MAX_WORDS 4096
static unsigned g_snap[SNAP_MAX_WORDS];

__attribute__((export_name("engine_snapshot_ptr")))
unsigned *engine_snapshot_ptr(void) { return g_snap; }

/* returns number of bytes written, 0 if it does not fit */
__attribute__((export_name("engine_save")))
unsigned engine_save(void) {
  int n = ss_len(g.entities);
  if (6 + n > SNAP_MAX_WORDS) return 0;
  union { float f; unsigned u; } bx = {g.box_x};
  g_snap[0] = SNAP_MAGIC;
  g_snap[1] = 1;
  g_snap[2] = g.capacity;
  g_snap[3] = g.frame;
  g_snap[4] = bx.u;
  g_snap[5] = (unsigned)n;
  for (int i = 0; i < n; i++) g_snap[6 + i] = (unsigned)ss_dense_at(g.entities, i);
  return (unsigned)(6 + n) * 4u;
}

/* returns 1 on success; rebuilds the SparseSet in the NEW module's heap,
 * preserving dense order */
__attribute__((export_name("engine_load")))
int engine_load(void) {
  if (g_snap[0] != SNAP_MAGIC || g_snap[1] != 1) return 0;
  union { unsigned u; float f; } bx = {g_snap[4]};
#ifdef LAYOUT_V2
  g.speed_scale = 1.0f; /* field absent in schema 1: default */
#endif
  g.capacity = g_snap[2];
  g.frame = g_snap[3];
  g.box_x = bx.f;
  g.entities = ss_create((int)g.capacity);
  unsigned n = g_snap[5];
  for (unsigned i = 0; i < n; i++) ss_add(g.entities, (int)g_snap[6 + i]);
  return 1;
}
