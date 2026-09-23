#include "../../ios/Classes/PcmRing.h"
#include <assert.h>
#include <pthread.h>
#include <sched.h>

static PcmRing ring;
static const uint32_t count = 1000000;

static void *produce(void *unused) {
    (void)unused;
    for (uint32_t i = 1; i <= count; i++) {
        while (!PcmRingWrite(&ring, &i, 1)) sched_yield();
    }
    return NULL;
}

int main(void) {
    assert(PcmRingInit(&ring, 7, sizeof(uint32_t)));
    assert(PcmRingWrite(&ring, NULL, 0));
    assert(PcmRingRead(&ring, NULL, 0) == 0);
    assert(!PcmRingWrite(&ring, NULL, 1));
    uint32_t values[8] = {1, 2, 3, 4, 5, 6, 7, 8};
    assert(!PcmRingWrite(&ring, values, 8));
    assert(PcmRingWrite(&ring, values, 7));
    assert(!PcmRingWrite(&ring, values, 1));
    uint32_t out[9];
    assert(PcmRingRead(&ring, out, 9) == 7);
    assert(out[6] == 7 && out[7] == 0 && out[8] == 0);
    // Multi-frame copies that straddle the end run both memcpy halves.
    assert(PcmRingWrite(&ring, values, 5));
    assert(PcmRingRead(&ring, out, 5) == 5);
    assert(PcmRingWrite(&ring, values + 1, 5));
    assert(PcmRingRead(&ring, out, 5) == 5);
    for (int i = 0; i < 5; i++) assert(out[i] == values[i + 1]);
    pthread_t thread;
    assert(pthread_create(&thread, NULL, produce, NULL) == 0);
    for (uint32_t i = 1; i <= count;) {
        if (PcmRingRead(&ring, out, 1)) assert(out[0] == i++);
        else sched_yield();
    }
    assert(pthread_join(thread, NULL) == 0);
    assert(atomic_load(&ring.written) == count + 17);
    assert(atomic_load(&ring.read) == count + 17);
    PcmRingDispose(&ring);

    // Idle stop expires only after an unbroken run of empty, unfed checks.
    PcmIdle idle;
    PcmIdleReset(&idle, 5);
    for (int i = 0; i < 49; i++) assert(!PcmIdleExpired(&idle, 5, 5, 50));
    assert(PcmIdleExpired(&idle, 5, 5, 50));
    PcmIdleReset(&idle, 5);
    for (int i = 0; i < 30; i++) assert(!PcmIdleExpired(&idle, 5, 5, 50));
    assert(!PcmIdleExpired(&idle, 9, 9, 50)); // fed and drained between ticks
    for (int i = 0; i < 49; i++) assert(!PcmIdleExpired(&idle, 9, 9, 50));
    assert(!PcmIdleExpired(&idle, 12, 9, 50)); // not empty
    for (int i = 0; i < 49; i++) assert(!PcmIdleExpired(&idle, 12, 12, 50));
    assert(PcmIdleExpired(&idle, 12, 12, 50));

    // One underrun per starvation episode; a start arms the flag so the first short pull is free.
    _Atomic(bool) starved;
    atomic_init(&starved, true);
    assert(!PcmUnderrunEdge(&starved, 256, 512)); // before the first full pull
    assert(!PcmUnderrunEdge(&starved, 512, 512));
    assert(PcmUnderrunEdge(&starved, 100, 512));
    assert(!PcmUnderrunEdge(&starved, 0, 512)); // idle pull, same episode
    assert(!PcmUnderrunEdge(&starved, 512, 512));
    assert(PcmUnderrunEdge(&starved, 0, 512));
    return 0;
}
