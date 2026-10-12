/* C side of benchmarks/bench_capi.mojo (ROADMAP 12.1): the same work the
 * Mojo bench does natively, driven through build/libludens.so.
 * Prints "row|variant|n|op|total_ns|iters|hash" lines. */
#define _POSIX_C_SOURCE 199309L
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "ludens.h"

static long long now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000000000LL + t.tv_nsec;
}

typedef struct {
    ld_body* bodies;
    int n;
} pushers;

/* PRE system: every 10th box gets a sideways velocity that flips each second. */
static int32_t push(ld_world* w, double dt, int64_t tick, void* user) {
    (void)dt;
    pushers* p = (pushers*)user;
    float st[13];
    float vx = ((tick / 60) % 2 == 0) ? 1.0f : -1.0f;
    for (int i = 0; i < p->n; i += 10) {
        ld_body_get_state(w, p->bodies[i], st);
        ld_body_set_velocity(w, p->bodies[i], vx, st[8], 0.0f, st[10], st[11], st[12]);
    }
    return 0;
}

static ld_world* scene(int n, ld_body* out) {
    ld_world* w = NULL;
    ld_world_create(1.0 / 60.0, 0.0f, -9.8f, 0.0f, &w);
    int side = 1;
    while (side * side * 2 < n) side++;
    float L = (float)side * 2.0f;
    ld_body_add_box(w, L / 2, -0.5f, L / 2, L / 2 + 1, 0.5f, L / 2 + 1, 0.0f, 1);
    int made = 0;
    for (int gx = 0; gx < side && made < n; gx++)
        for (int gz = 0; gz < side && made < n; gz++)
            for (int k = 0; k < 2 && made < n; k++)
                out[made++] = ld_body_add_box(w, (float)gx * 2 + 1, 0.25f + 0.51f * (float)k, (float)gz * 2 + 1,
                                              0.25f, 0.25f, 0.25f, 1.0f, 0);
    return w;
}

int main(int argc, char** argv) {
    int n = argc > 1 ? atoi(argv[1]) : 1000;
    int ticks = argc > 2 ? atoi(argv[2]) : 60;
    ld_body* bodies = (ld_body*)malloc(sizeof(ld_body) * (size_t)n);
    pushers p = {bodies, n};

    ld_world* w = scene(n, bodies);
    ld_world_add_system(w, LD_PHASE_PRE, push, &p);
    ld_world_step_ticks(w, 20); /* warm-up, untimed (same as the native side) */
    long long t0 = now_ns();
    ld_world_step_ticks(w, ticks);
    long long t1 = now_ns();
    uint64_t h = 0;
    ld_world_hash(w, &h);
    printf("row|C host: step with a PRE system pushing every 10th box|%d|tick|%lld|%d|%016llx\n", n, t1 - t0, ticks,
           (unsigned long long)h);

    float st[13];
    int calls = 0;
    t0 = now_ns();
    int reps = 1000000 / n;
    for (int r = 0; r < reps; r++)
        for (int i = 0; i < n; i++, calls++) ld_body_get_state(w, bodies[i], st);
    t1 = now_ns();
    printf("row|C host: ld_body_get_state per body|%d|call|%lld|%d|0\n", n, t1 - t0, calls);

    ld_body* hs = (ld_body*)malloc(sizeof(ld_body) * (size_t)(n + 1));
    float* ps = (float*)malloc(sizeof(float) * 7 * (size_t)(n + 1));
    t0 = now_ns();
    for (int r = 0; r < reps; r++) ld_world_get_bodies(w, hs, ps, n + 1);
    t1 = now_ns();
    printf("row|C host: ld_world_get_bodies (all poses, one call)|%d|body|%lld|%d|0\n", n, t1 - t0, reps * (n + 1));

    int64_t sz = ld_world_save_size(w);
    uint8_t* blob = (uint8_t*)malloc((size_t)sz);
    t0 = now_ns();
    for (int r = 0; r < 20; r++) ld_world_save(w, blob, sz);
    t1 = now_ns();
    printf("row|C host: ld_world_save (%lld B)|%d|save|%lld|%d|0\n", (long long)sz, n, t1 - t0, 20);
    t0 = now_ns();
    for (int r = 0; r < 20; r++) ld_world_load(w, blob, sz);
    t1 = now_ns();
    printf("row|C host: ld_world_load|%d|load|%lld|%d|0\n", n, t1 - t0, 20);
    ld_world_destroy(w);
    free(blob);
    free(hs);
    free(ps);
    free(bodies);
    return 0;
}
