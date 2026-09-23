package com.lib.flutter_pcm_sound;
import java.util.Arrays;
public class PcmQueueTest {
    public static void main(String[] args) {
        PcmQueue queue = new PcmQueue(4, 2);
        byte[] first = {1,2,3,4,5,6};
        if (!queue.offer(first) || queue.offer(first)) throw new AssertionError("capacity");
        byte[] out = new byte[4];
        if (queue.read(out) != 4 || !Arrays.equals(out, new byte[]{1,2,3,4})) throw new AssertionError("read");
        if (!queue.offer(first)) throw new AssertionError("wrap write");
        byte[] all = new byte[8];
        if (queue.read(all) != 8 || !Arrays.equals(all, new byte[]{5,6,1,2,3,4,5,6})) throw new AssertionError("wrap read");
        try { queue.offer(new byte[1]); throw new AssertionError("alignment"); }
        catch (IllegalArgumentException expected) { }
    }
}
