package com.lib.flutter_pcm_sound;

/** Owns an unwritten tail until the device acknowledges every byte. */
final class PcmWritePump {
    interface Sink { int write(byte[] bytes, int offset, int length); }
    private final byte[] pending;
    private final int frameBytes;
    private int offset;
    private int length;

    PcmWritePump(int frames, int frameBytes) {
        this.frameBytes = frameBytes;
        pending = new byte[frames * frameBytes];
    }

    boolean hasPending() { return offset < length; }

    void refill(PcmQueue queue) {
        if (hasPending()) return;
        length = queue.read(pending);
        offset = 0;
    }

    int write(Sink sink) {
        if (!hasPending()) return 0;
        int count = sink.write(pending, offset, length - offset);
        if (count < 0) throw new IllegalStateException("AudioTrack.write failed: " + count);
        if (count > length - offset || count % frameBytes != 0)
            throw new IllegalStateException("Invalid AudioTrack write count: " + count);
        offset += count;
        return count;
    }
}
