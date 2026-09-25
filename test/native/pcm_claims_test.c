#include "../../ios/Classes/PcmClaims.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    PcmClaims claims = {0};
    uint64_t old = PcmClaimsTake(&claims), current = PcmClaimsTake(&claims);
    assert(!PcmClaimsAdmit(&claims, true, old)); // a stale owner is refused, changing nothing
    assert(PcmClaimsAdmit(&claims, true, current));
    assert(PcmClaimsAdmit(&claims, true, current)); // admitting does not advance the claim
    assert(PcmClaimsAdmit(&claims, false, 0)); // an unowned setup claims afresh...
    assert(!PcmClaimsAdmit(&claims, true, current)); // ...so it fences every older owner
    assert(PcmClaimsTake(&claims) == current + 2);
    puts("PCM claim regressions passed");
}
