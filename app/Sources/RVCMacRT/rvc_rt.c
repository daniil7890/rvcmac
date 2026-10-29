#include "rvc_rt.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#include <mach/mach_time.h>
#else
#include <time.h>
#endif

// ---------------------------------------------------------------------------
// Ring
// ---------------------------------------------------------------------------
struct rvc_ring {
    float *buf;
    int64_t cap;
    _Atomic uint64_t w;
    _Atomic uint64_t r;
    _Atomic uint64_t dropped;
};

rvc_ring *rvc_ring_create(int64_t capacity) {
    if (capacity < 1) capacity = 1;
    rvc_ring *ring = calloc(1, sizeof(rvc_ring));
    if (!ring) return NULL;
    ring->buf = calloc((size_t)capacity, sizeof(float));
    if (!ring->buf) { free(ring); return NULL; }
    ring->cap = capacity;
    atomic_init(&ring->w, 0);
    atomic_init(&ring->r, 0);
    atomic_init(&ring->dropped, 0);
    return ring;
}

void rvc_ring_destroy(rvc_ring *ring) {
    if (!ring) return;
    free(ring->buf);
    free(ring);
}

int64_t rvc_ring_write(rvc_ring *ring, const float *src, int64_t n) {
    if (n <= 0) return 0;
    uint64_t w = atomic_load_explicit(&ring->w, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&ring->r, memory_order_acquire);
    int64_t space = ring->cap - (int64_t)(w - r);
    int64_t m = n < space ? n : space;
    if (m < 0) m = 0;
    if (m < n) atomic_fetch_add_explicit(&ring->dropped, (uint64_t)(n - m), memory_order_relaxed);
    if (m > 0) {
        int64_t idx = (int64_t)(w % (uint64_t)ring->cap);
        int64_t first = ring->cap - idx;
        if (first > m) first = m;
        memcpy(ring->buf + idx, src, (size_t)first * sizeof(float));
        if (m > first) memcpy(ring->buf, src + first, (size_t)(m - first) * sizeof(float));
    }
    atomic_store_explicit(&ring->w, w + (uint64_t)m, memory_order_release);
    return m;
}

static int64_t ring_consume(rvc_ring *ring, float *dst, int64_t n) {
    if (n <= 0) return 0;
    uint64_t r = atomic_load_explicit(&ring->r, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&ring->w, memory_order_acquire);
    int64_t avail = (int64_t)(w - r);
    int64_t m = n < avail ? n : avail;
    if (m <= 0) return 0;
    if (dst) {
        int64_t idx = (int64_t)(r % (uint64_t)ring->cap);
        int64_t first = ring->cap - idx;
        if (first > m) first = m;
        memcpy(dst, ring->buf + idx, (size_t)first * sizeof(float));
        if (m > first) memcpy(dst + first, ring->buf, (size_t)(m - first) * sizeof(float));
    }
    atomic_store_explicit(&ring->r, r + (uint64_t)m, memory_order_release);
    return m;
}

int64_t rvc_ring_read(rvc_ring *ring, float *dst, int64_t n) { return ring_consume(ring, dst, n); }
int64_t rvc_ring_skip(rvc_ring *ring, int64_t n) { return ring_consume(ring, NULL, n); }

int64_t rvc_ring_available(const rvc_ring *ring) {
    uint64_t r = atomic_load_explicit(&((rvc_ring *)ring)->r, memory_order_acquire);
    uint64_t w = atomic_load_explicit(&((rvc_ring *)ring)->w, memory_order_acquire);
    int64_t a = (int64_t)(w - r);
    return a < 0 ? 0 : a;
}

int64_t rvc_ring_capacity(const rvc_ring *ring) { return ring->cap; }
uint64_t rvc_ring_write_pos(const rvc_ring *ring) { return atomic_load_explicit(&((rvc_ring *)ring)->w, memory_order_acquire); }
uint64_t rvc_ring_read_pos(const rvc_ring *ring) { return atomic_load_explicit(&((rvc_ring *)ring)->r, memory_order_acquire); }
uint64_t rvc_ring_dropped(const rvc_ring *ring) { return atomic_load_explicit(&((rvc_ring *)ring)->dropped, memory_order_relaxed); }

void rvc_ring_reset(rvc_ring *ring) {
    atomic_store(&ring->w, 0);
    atomic_store(&ring->r, 0);
    atomic_store(&ring->dropped, 0);
}

// ---------------------------------------------------------------------------
// Clock (seqlock)
// ---------------------------------------------------------------------------
struct rvc_clock {
    _Atomic uint32_t seq;
    _Atomic uint64_t pos;
    _Atomic uint64_t host;
};

rvc_clock *rvc_clock_create(void) {
    rvc_clock *c = calloc(1, sizeof(rvc_clock));
    if (!c) return NULL;
    atomic_init(&c->seq, 0);
    atomic_init(&c->pos, 0);
    atomic_init(&c->host, 0);
    return c;
}

void rvc_clock_destroy(rvc_clock *clock) { free(clock); }

void rvc_clock_publish(rvc_clock *c, uint64_t position, uint64_t host_time) {
    uint32_t s = atomic_load_explicit(&c->seq, memory_order_relaxed);
    atomic_store_explicit(&c->seq, s + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    atomic_store_explicit(&c->pos, position, memory_order_relaxed);
    atomic_store_explicit(&c->host, host_time, memory_order_relaxed);
    atomic_store_explicit(&c->seq, s + 2, memory_order_release);
}

int rvc_clock_read(const rvc_clock *cc, uint64_t *position, uint64_t *host_time) {
    rvc_clock *c = (rvc_clock *)cc;
    for (int i = 0; i < 64; i++) {
        uint32_t s1 = atomic_load_explicit(&c->seq, memory_order_acquire);
        if (s1 == 0) return 0;  // never published
        if (s1 & 1u) continue;  // write in progress
        uint64_t p = atomic_load_explicit(&c->pos, memory_order_relaxed);
        uint64_t h = atomic_load_explicit(&c->host, memory_order_relaxed);
        atomic_thread_fence(memory_order_acquire);
        uint32_t s2 = atomic_load_explicit(&c->seq, memory_order_relaxed);
        if (s1 == s2) {
            *position = p;
            *host_time = h;
            return 1;
        }
    }
    return 0;
}

void rvc_clock_reset(rvc_clock *c) {
    atomic_store(&c->seq, 0);
    atomic_store(&c->pos, 0);
    atomic_store(&c->host, 0);
}

// ---------------------------------------------------------------------------
// Atomic integer
// ---------------------------------------------------------------------------
struct rvc_atomic {
    _Atomic int64_t v;
};

rvc_atomic *rvc_atomic_create(int64_t initial) {
    rvc_atomic *a = calloc(1, sizeof(rvc_atomic));
    if (!a) return NULL;
    atomic_init(&a->v, initial);
    return a;
}

void rvc_atomic_destroy(rvc_atomic *a) { free(a); }
int64_t rvc_atomic_load(const rvc_atomic *a) { return atomic_load_explicit(&((rvc_atomic *)a)->v, memory_order_acquire); }
void rvc_atomic_store(rvc_atomic *a, int64_t value) { atomic_store_explicit(&a->v, value, memory_order_release); }
int64_t rvc_atomic_add(rvc_atomic *a, int64_t delta) {
    return atomic_fetch_add_explicit(&a->v, delta, memory_order_acq_rel) + delta;
}

// ---------------------------------------------------------------------------
// Host time
// ---------------------------------------------------------------------------
#if defined(__APPLE__)
static double host_ns_per_tick(void) {
    static double factor = 0;
    if (factor == 0) {
        mach_timebase_info_data_t info;
        mach_timebase_info(&info);
        factor = (double)info.numer / (double)info.denom;
    }
    return factor;
}
uint64_t rvc_host_now(void) { return mach_absolute_time(); }
double rvc_host_to_ns(uint64_t ticks) { return (double)ticks * host_ns_per_tick(); }
#else
uint64_t rvc_host_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}
double rvc_host_to_ns(uint64_t ticks) { return (double)ticks; }
#endif

double rvc_host_delta_ms(uint64_t from, uint64_t to) {
    if (to >= from) return rvc_host_to_ns(to - from) / 1e6;
    return -rvc_host_to_ns(from - to) / 1e6;
}
