#include "../../ios/Classes/PcmTiming.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>

static PcmTiming timing;
static _Atomic(bool) finished;
static void *publish(void *unused) {
    (void)unused;
    for (uint64_t n = 1; n <= 1000000; n++)
        PcmTimingPublish(&timing, n, n * 20, true);
    atomic_store(&finished, true);
    return NULL;
}
int main(void) {
    PcmTimingSnapshot snapshot;
    assert(!PcmTimingRead(&timing, &snapshot));
    pthread_t writer;
    assert(!pthread_create(&writer, NULL, publish, NULL));
    while (!atomic_load(&finished)) {
        if (PcmTimingRead(&timing, &snapshot))
            assert(snapshot.hostNs == snapshot.frame * 20);
    }
    pthread_join(writer, NULL);
    PcmTimingPublish(&timing, 100, 2000, false);
    assert(!PcmTimingRead(&timing, &snapshot));
    puts("PCM timing regressions passed");
}
