package com.lib.flutter_pcm_sound;

public final class PcmHeadTest {
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        PcmHead h = new PcmHead();
        check(h.consumed(300, 512) == 300);
        check(h.consumed(900, 512) == 512); // a read inside the copy-to-written window, capped
        check(h.consumed(900, 1024) == 900); // the capped advance is kept

        PcmHead m = new PcmHead();
        check(m.consumed(400, 1024) == 400);
        check(m.consumed(400, 300) == 400); // never goes backwards

        PcmHead w = new PcmHead();
        check(w.consumed(0xFFFFFF00, Long.MAX_VALUE) == 0xFFFFFF00L);
        check(w.consumed(0x100, Long.MAX_VALUE) == 0x100000100L);
    }
}
