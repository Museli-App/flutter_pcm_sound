#ifndef PCM_RING_H
#define PCM_RING_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// One serialized producer, one audio callback. Storage never moves while running.
typedef struct {
    uint8_t *bytes;
    size_t capacity;
    size_t frameBytes;
    _Atomic(uint64_t) written;
    _Atomic(uint64_t) read;
} PcmRing;

static inline int PcmRingInit(PcmRing *ring, size_t frames, size_t frameBytes) {
    if (!frames || !frameBytes || frames > SIZE_MAX / frameBytes) return 0;
    ring->bytes = calloc(frames, frameBytes);
    ring->capacity = frames;
    ring->frameBytes = frameBytes;
    atomic_init(&ring->written, 0);
    atomic_init(&ring->read, 0);
    return ring->bytes != NULL;
}

static inline int PcmRingWrite(PcmRing *ring, const void *bytes, size_t frames) {
    if (!frames) return 1;
    if (!bytes) return 0;
    uint64_t written = atomic_load_explicit(&ring->written, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&ring->read, memory_order_acquire);
    if (frames > ring->capacity - (written - read)) return 0;
    size_t offset = written % ring->capacity;
    size_t first = frames < ring->capacity - offset ? frames : ring->capacity - offset;
    memcpy(ring->bytes + offset * ring->frameBytes, bytes, first * ring->frameBytes);
    memcpy(ring->bytes, (const uint8_t *)bytes + first * ring->frameBytes,
           (frames - first) * ring->frameBytes);
    atomic_store_explicit(&ring->written, written + frames, memory_order_release);
    return 1;
}

static inline size_t PcmRingRead(PcmRing *ring, void *bytes, size_t frames) {
    if (!frames) return 0;
    uint64_t read = atomic_load_explicit(&ring->read, memory_order_relaxed);
    uint64_t written = atomic_load_explicit(&ring->written, memory_order_acquire);
    size_t available = (size_t)(written - read);
    size_t count = frames < available ? frames : available;
    size_t offset = read % ring->capacity;
    size_t first = count < ring->capacity - offset ? count : ring->capacity - offset;
    memcpy(bytes, ring->bytes + offset * ring->frameBytes, first * ring->frameBytes);
    memcpy((uint8_t *)bytes + first * ring->frameBytes, ring->bytes,
           (count - first) * ring->frameBytes);
    memset((uint8_t *)bytes + count * ring->frameBytes, 0, (frames - count) * ring->frameBytes);
    atomic_store_explicit(&ring->read, read + count, memory_order_release);
    return count;
}

static inline void PcmRingDispose(PcmRing *ring) {
    free(ring->bytes);
    ring->bytes = NULL;
}

// Idle stop: expires after graceTicks checks in a row that find the ring empty and unfed.
typedef struct { uint64_t written; uint32_t ticks; } PcmIdle;

static inline void PcmIdleReset(PcmIdle *idle, uint64_t written) { idle->written = written; idle->ticks = 0; }

static inline bool PcmIdleExpired(PcmIdle *idle, uint64_t written, uint64_t read, uint32_t graceTicks) {
    // A feed between checks moves 'written' even if the callback already drained it.
    if (written != read || written != idle->written) { PcmIdleReset(idle, written); return false; }
    return ++idle->ticks >= graceTicks;
}

// One underrun per starvation episode, as Android's getUnderrunCount counts them.
static inline bool PcmUnderrunEdge(_Atomic(bool) *starved, size_t read, size_t requested) {
    bool starving = read < requested;
    bool was = atomic_exchange_explicit(starved, starving, memory_order_relaxed);
    return starving && !was;
}
#endif
