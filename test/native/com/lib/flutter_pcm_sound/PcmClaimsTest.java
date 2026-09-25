package com.lib.flutter_pcm_sound;

public final class PcmClaimsTest {
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        PcmClaims c = new PcmClaims();
        long old = c.take(), current = c.take();
        check(!c.admit(old)); // a stale owner is refused, changing nothing
        check(c.admit(current));
        check(c.admit(current)); // admitting does not advance the claim
        check(c.admit(null)); // an unowned setup claims afresh...
        check(!c.admit(current)); // ...so it fences every older owner
        check(c.take() == current + 2);
    }
}
