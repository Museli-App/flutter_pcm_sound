#ifndef PCM_CLAIMS_H
#define PCM_CLAIMS_H
#include <stdbool.h>
#include <stdint.h>

// Orders takeovers across isolates: the setup begun last wins. Callers serialize access.
typedef struct { uint64_t latest; } PcmClaims;

static inline uint64_t PcmClaimsTake(PcmClaims *claims) { return ++claims->latest; }

// An owned setup is admitted only while its claim is the newest; an unowned one claims afresh.
static inline bool PcmClaimsAdmit(PcmClaims *claims, bool owned, uint64_t owner) {
    if (!owned) { claims->latest++; return true; }
    return owner == claims->latest;
}
#endif
