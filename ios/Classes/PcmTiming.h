#ifndef PCM_TIMING_H
#define PCM_TIMING_H
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

// One realtime writer. Atomic fields make unsuccessful snapshots data-race free.
typedef struct {
    _Atomic(uint64_t) version, frame, hostNs;
    _Atomic(bool) valid;
} PcmTiming;
typedef struct { uint64_t frame, hostNs; } PcmTimingSnapshot;

static inline void PcmTimingPublish(PcmTiming *timing, uint64_t frame,
                                   uint64_t hostNs, bool valid) {
    atomic_fetch_add(&timing->version, 1);
    atomic_store(&timing->frame, frame);
    atomic_store(&timing->hostNs, hostNs);
    atomic_store(&timing->valid, valid);
    atomic_fetch_add(&timing->version, 1);
}

static inline bool PcmTimingRead(PcmTiming *timing, PcmTimingSnapshot *snapshot) {
    for (int attempt = 0; attempt < 3; attempt++) {
        uint64_t version = atomic_load(&timing->version);
        if (version & 1) continue;
        snapshot->frame = atomic_load(&timing->frame);
        snapshot->hostNs = atomic_load(&timing->hostNs);
        bool valid = atomic_load(&timing->valid);
        if (version == atomic_load(&timing->version)) return valid;
    }
    return false;
}
#endif
