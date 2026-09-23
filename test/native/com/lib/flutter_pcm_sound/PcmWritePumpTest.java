package com.lib.flutter_pcm_sound;

import java.io.ByteArrayOutputStream;
import java.util.Arrays;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicBoolean;

public final class PcmWritePumpTest {
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) throws Exception {
        PcmQueue queue = new PcmQueue(8, 2);
        byte[] bytes = {0, 1, 2, 3, 4, 5, 6, 7};
        check(queue.offer(bytes));
        PcmWritePump pump = new PcmWritePump(4, 2);
        pump.refill(queue);
        ByteArrayOutputStream written = new ByteArrayOutputStream();
        PcmWritePump.Sink shortWrite = (data, offset, length) -> {
            written.write(data, offset, 2); return 2;
        };
        check(pump.write(shortWrite) == 2);
        check(pump.write((data, offset, length) -> 0) == 0);
        pump.refill(queue); // Must not replace a partially written block.
        check(pump.hasPending());
        while (pump.hasPending()) pump.write(shortWrite);
        check(Arrays.equals(bytes, written.toByteArray()));

        queue.offer(bytes);
        pump.refill(queue);
        for (int bad : new int[] {-6, -3, 1, 100}) {
            boolean failed = false;
            try { pump.write((data, offset, length) -> bad); }
            catch (IllegalStateException expected) { failed = true; }
            check(failed && pump.hasPending());
        }

        CountDownLatch blocked = new CountDownLatch(1);
        CountDownLatch unblock = new CountDownLatch(1);
        AtomicBoolean released = new AtomicBoolean();
        Thread worker = new Thread(() -> {
            try { blocked.countDown(); unblock.await(); }
            catch (InterruptedException ignored) { }
            finally { released.set(true); }
        });
        worker.start(); blocked.await();
        PcmWorkerShutdown.await(worker, unblock::countDown, 500);
        check(released.get() && !worker.isAlive());

        AtomicBoolean stop = new AtomicBoolean();
        Thread wedged = new Thread(() -> { while (!stop.get()) Thread.yield(); });
        wedged.start();
        boolean timedOut = false;
        try { PcmWorkerShutdown.await(wedged, () -> {}, 10); }
        catch (IllegalStateException expected) { timedOut = true; }
        finally { stop.set(true); wedged.join(500); }
        check(timedOut);
    }
}
