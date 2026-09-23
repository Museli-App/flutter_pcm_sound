package com.lib.flutter_pcm_sound;

public class PcmTimestampTest {
    public static void main(String[] args) {
        long wrap = 1L << 32;
        check(PcmTimestamp.extend(64, 512) == 64);
        check(PcmTimestamp.extend(600, 512) == -1);
        check(PcmTimestamp.extend(64, wrap + 512) == wrap + 64);
        check(PcmTimestamp.extend(wrap - 32, wrap + 512) == wrap - 32);
        check(PcmTimestamp.extend(64, 3 * wrap + 512) == 3 * wrap + 64);
        System.out.println("PCM timestamp regressions passed");
    }
    private static void check(boolean condition) { if (!condition) throw new AssertionError(); }
}
