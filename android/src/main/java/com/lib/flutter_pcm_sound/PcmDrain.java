package com.lib.flutter_pcm_sound;

import java.util.Objects;

/** An output's pause/play and timestamp rules, off the AudioTrack so a host JVM tests them. Callers hold its lock. */
final class PcmDrain {
    // As iOS's idle stop: outlasts the longest isolate stall seen (277 ms, debug) and ends inside the
    // framework's underrun retries, so a stall mid-play underruns and resumes rather than pausing.
    static final long IDLE_GRACE_NS = 500_000_000L;
    static final long POLL_NS = 100_000_000L;
    static final long HEAD_POLL_MS = 10;

    private boolean paused;
    private long starts;
    private boolean idle;
    private long idleFeeds;
    private long idleSinceNs;
    private long anchorFrame = -1;
    private long anchorNs;
    private long pollNs;
    private String route;

    boolean paused() { return paused; }
    /** play() calls: a track left unfed for the grace pauses, so a consumer restarts its timing on each. */
    long starts() { return starts; }
    String route() { return route; }
    /** The latest anchor frame, or -1 when there is none. */
    long anchorFrame() { return anchorFrame; }
    long anchorNs() { return anchorNs; }

    void started() { starts++; }

    /** Before a write: a paused track with frames to write plays again, unless the output is stopping. */
    boolean resume(boolean pending, boolean stopping) {
        if (!paused || stopping || !pending) return false;
        paused = false;
        idle = false;
        starts++;
        pollNs = 0;
        return true;
    }

    /** Nothing to write: true once the track has stayed drained and unfed for the grace, and is to pause. */
    boolean pauseDue(boolean drained, long feeds, boolean stopping, long nowNs) {
        if (paused || stopping) return false;
        // A feed between checks moves 'feeds' even if the track already played it.
        if (!drained || !idle || feeds != idleFeeds) {
            idle = drained;
            idleFeeds = feeds;
            idleSinceNs = nowNs;
            return false;
        }
        if (nowNs - idleSinceNs < IDLE_GRACE_NS) return false;
        paused = true;
        anchorFrame = -1; // load-bearing: a restarted track publishes nothing until it reads afresh
        return true;
    }

    /** How long a worker with nothing to write waits for a feed: 0 (unbounded) once paused. */
    long waitMs(long nowNs) {
        if (paused) return 0;
        if (!idle) return HEAD_POLL_MS;
        return Math.max(1, (idleSinceNs + IDLE_GRACE_NS - nowNs + 999_999) / 1_000_000);
    }

    /** A status call: true while the track plays; otherwise its anchor is cleared. */
    boolean playing(boolean live) {
        if (live && !paused) return true;
        anchorFrame = -1;
        return false;
    }

    /** The routed output: a change clears the anchor and polls afresh, so a reading never crosses routes. */
    void routed(String id) {
        if (!Objects.equals(id, route)) {
            anchorFrame = -1;
            pollNs = 0;
        }
        route = id;
    }

    /** At most one timestamp poll per POLL_NS. */
    boolean pollDue(long nowNs) {
        if (nowNs - pollNs < POLL_NS) return false;
        pollNs = nowNs;
        return true;
    }

    /** A successful poll. An invalid one, like a failed poll, keeps the last reading. */
    void reading(long frame, long ns) {
        if (frame < 0 || ns <= 0) return;
        anchorFrame = frame;
        anchorNs = ns;
    }
}
