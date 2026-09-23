package com.lib.flutter_pcm_sound;

/** Bounded frame-aligned FIFO. Callers serialize access on the output lock. */
final class PcmQueue {
    private final byte[] bytes;
    private final int frameBytes;
    private int read;
    private int size;

    PcmQueue(int frames, int frameBytes) {
        this.frameBytes = frameBytes;
        bytes = new byte[frames * frameBytes];
    }

    int frames() { return size / frameBytes; }

    boolean offer(byte[] source) {
        if (source.length % frameBytes != 0) throw new IllegalArgumentException("Unaligned PCM");
        if (source.length > bytes.length - size) return false;
        int write = (read + size) % bytes.length;
        int first = Math.min(source.length, bytes.length - write);
        System.arraycopy(source, 0, bytes, write, first);
        System.arraycopy(source, first, bytes, 0, source.length - first);
        size += source.length;
        return true;
    }

    int read(byte[] destination) {
        int count = Math.min(size, destination.length);
        count -= count % frameBytes;
        int first = Math.min(count, bytes.length - read);
        System.arraycopy(bytes, read, destination, 0, first);
        System.arraycopy(bytes, 0, destination, first, count - first);
        read = (read + count) % bytes.length;
        size -= count;
        return count;
    }
}
