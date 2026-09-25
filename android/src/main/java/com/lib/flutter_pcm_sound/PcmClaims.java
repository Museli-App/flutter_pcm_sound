package com.lib.flutter_pcm_sound;

/** Orders takeovers across isolates: the setup begun last wins. Callers serialize access. */
final class PcmClaims {
    private long latest;

    long take() { return ++latest; }

    /** An owned setup is admitted only while its claim is the newest; an unowned one claims afresh. */
    boolean admit(Long owner) {
        if (owner == null) { ++latest; return true; }
        return owner == latest;
    }
}
