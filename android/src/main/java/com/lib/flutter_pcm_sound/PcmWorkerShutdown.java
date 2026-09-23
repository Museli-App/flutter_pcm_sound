package com.lib.flutter_pcm_sound;

final class PcmWorkerShutdown {
    static void await(Thread worker, Runnable unblock, long timeoutMillis) {
        unblock.run();
        worker.interrupt();
        try { worker.join(timeoutMillis); }
        catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException(error);
        }
        if (worker.isAlive()) throw new IllegalStateException("PCM worker shutdown timed out");
    }
}
