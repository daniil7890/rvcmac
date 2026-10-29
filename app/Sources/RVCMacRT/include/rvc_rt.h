#ifndef RVC_RT_H
#define RVC_RT_H

// Real-time safe primitives for the Core Audio callbacks.
// Nothing here allocates, locks or calls into the OS after creation.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Single-producer / single-consumer float ring buffer (lock-free).
// Positions are monotonically increasing 64-bit sample counters, so a sample
// keeps the same absolute index from write to read. That is what lets the
// telemetry match an output sample to the input sample it came from.
// ---------------------------------------------------------------------------
typedef struct rvc_ring rvc_ring;

rvc_ring *rvc_ring_create(int64_t capacity);
void rvc_ring_destroy(rvc_ring *ring);

/// Producer side. Writes up to n samples; when the ring is full the rest is dropped
/// (counted in rvc_ring_dropped). Returns the number written.
int64_t rvc_ring_write(rvc_ring *ring, const float *src, int64_t n);
/// Consumer side. Reads up to n samples, returns the number read.
int64_t rvc_ring_read(rvc_ring *ring, float *dst, int64_t n);
/// Consumer side. Discards up to n of the oldest samples, returns the number discarded.
int64_t rvc_ring_skip(rvc_ring *ring, int64_t n);
/// Samples currently stored (safe from either side, may be momentarily stale).
int64_t rvc_ring_available(const rvc_ring *ring);
int64_t rvc_ring_capacity(const rvc_ring *ring);
uint64_t rvc_ring_write_pos(const rvc_ring *ring);
uint64_t rvc_ring_read_pos(const rvc_ring *ring);
/// Samples rejected by rvc_ring_write because the ring was full.
uint64_t rvc_ring_dropped(const rvc_ring *ring);
/// Only call while neither side is running.
void rvc_ring_reset(rvc_ring *ring);

// ---------------------------------------------------------------------------
// Seqlock holding the latest (sample position, host time) pair published by an
// audio callback. One writer (the callback), any number of readers.
// ---------------------------------------------------------------------------
typedef struct rvc_clock rvc_clock;

rvc_clock *rvc_clock_create(void);
void rvc_clock_destroy(rvc_clock *clock);
void rvc_clock_publish(rvc_clock *clock, uint64_t position, uint64_t host_time);
/// Returns 1 and fills the outputs when a consistent pair is available, 0 otherwise.
int rvc_clock_read(const rvc_clock *clock, uint64_t *position, uint64_t *host_time);
void rvc_clock_reset(rvc_clock *clock);

// ---------------------------------------------------------------------------
// Atomic 64-bit integer (flags, counters, settings shared with callbacks).
// ---------------------------------------------------------------------------
typedef struct rvc_atomic rvc_atomic;

rvc_atomic *rvc_atomic_create(int64_t initial);
void rvc_atomic_destroy(rvc_atomic *a);
int64_t rvc_atomic_load(const rvc_atomic *a);
void rvc_atomic_store(rvc_atomic *a, int64_t value);
/// Returns the new value.
int64_t rvc_atomic_add(rvc_atomic *a, int64_t delta);

// ---------------------------------------------------------------------------
// Host time helpers (mach_absolute_time ticks <-> nanoseconds).
// ---------------------------------------------------------------------------
uint64_t rvc_host_now(void);
double rvc_host_to_ns(uint64_t ticks);
double rvc_host_delta_ms(uint64_t from, uint64_t to);

#ifdef __cplusplus
}
#endif

#endif
