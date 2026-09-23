package com.lib.flutter_pcm_sound;

final class PcmTimestamp {
    private static final long WRAP = 1L << 32;

    // AudioTrack timestamps wrap at 32 bits; never include frames not yet written.
    static long extend(long position, long written) {
        long extended = (written & ~(WRAP - 1)) | (position & (WRAP - 1));
        if (extended > written) extended -= WRAP;
        return extended < 0 || written - extended >= WRAP / 2 ? -1 : extended;
    }
}
