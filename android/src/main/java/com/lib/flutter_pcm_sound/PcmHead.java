package com.lib.flutter_pcm_sound;

/** Widens the 32-bit playback head; consumption never passes what was written, nor drops an advance. */
final class PcmHead {
    private long last, frames, consumed;
    long consumed(int head, long written) {
        long raw = head & 0xffffffffL;
        frames += (raw - last) & 0xffffffffL;
        last = raw;
        return consumed = Math.max(consumed, Math.min(written, frames));
    }
}
