package com.lib.flutter_pcm_sound;

public final class PcmDrainTest {
    private static final long MS = 1_000_000L, T = 1_000 * MS;
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        // A track left drained and unfed pauses only after the grace, and waits unbounded once paused.
        PcmDrain d = new PcmDrain();
        d.started();
        check(!d.pauseDue(true, 1, false, T)); // the first drained check starts the grace
        check(d.waitMs(T) == 500 && d.waitMs(T + 499 * MS + 1) == 1);
        check(!d.pauseDue(true, 1, false, T + 499 * MS));
        check(d.pauseDue(true, 1, false, T + 500 * MS));
        check(d.paused() && d.waitMs(T + 500 * MS) == 0);
        check(!d.pauseDue(true, 1, false, T + 900 * MS)); // pauses once

        // A refill with frames plays again and counts a start; nothing pending, or stopping, does not.
        check(!d.resume(false, false) && !d.resume(true, true) && d.paused());
        check(d.resume(true, false) && !d.paused() && d.starts() == 2);
        check(!d.resume(true, false) && d.starts() == 2);

        // A feed inside the grace, or frames still playing, restarts it.
        PcmDrain fed = new PcmDrain();
        check(!fed.pauseDue(true, 1, false, T));
        check(!fed.pauseDue(true, 2, false, T + 400 * MS));
        check(!fed.pauseDue(true, 2, false, T + 800 * MS));
        check(!fed.pauseDue(false, 2, false, T + 850 * MS) && fed.waitMs(T + 850 * MS) == PcmDrain.HEAD_POLL_MS);
        check(!fed.pauseDue(true, 2, false, T + 900 * MS));
        check(fed.pauseDue(true, 2, false, T + 1400 * MS));
        // A stopping output never pauses.
        PcmDrain stopping = new PcmDrain();
        check(!stopping.pauseDue(true, 1, true, T) && !stopping.pauseDue(true, 1, true, T + 2000 * MS));

        // Polls at most every 100 ms; a failed or invalid poll keeps the last reading within a route.
        PcmDrain clock = new PcmDrain();
        check(clock.playing(true) && clock.anchorFrame() == -1);
        clock.routed("2:5");
        check(clock.pollDue(T));
        clock.reading(100, 5000);
        check(clock.anchorFrame() == 100 && clock.anchorNs() == 5000);
        check(!clock.pollDue(T + 99 * MS) && clock.pollDue(T + 100 * MS));
        clock.reading(-1, 6000);
        clock.reading(200, 0);
        check(clock.anchorFrame() == 100 && clock.anchorNs() == 5000);
        clock.routed("2:5");
        check(clock.anchorFrame() == 100 && !clock.pollDue(T + 150 * MS));
        // A route change clears the anchor and polls afresh.
        clock.routed("8:9");
        check(clock.anchorFrame() == -1 && clock.route().equals("8:9") && clock.pollDue(T + 150 * MS));
        clock.reading(300, 7000);
        // Not playing clears it at the next status.
        check(!clock.playing(false) && clock.anchorFrame() == -1);

        // A pause clears the anchor with no status call in between; a resumed track polls at once.
        clock.reading(400, 8000);
        check(!clock.pauseDue(true, 3, false, T + 200 * MS) && clock.anchorFrame() == 400);
        check(clock.pauseDue(true, 3, false, T + 700 * MS) && clock.anchorFrame() == -1);
        check(!clock.playing(true));
        check(clock.resume(true, false) && clock.playing(true) && clock.pollDue(T + 710 * MS));
    }
}
