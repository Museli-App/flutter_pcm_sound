# Native output timing

`setupOutput`, `feedWithStatus` and `status` include a nullable `presentation`
anchor, sample rate and actual output route identifier. Queue consumption remains
separate from timestamp validity.

- Android uses `AudioTrack.getTimestamp`. Its wrapping 32-bit frame position is
  extended against written frames. It is polled on status, at most every
  100 ms, while the track plays, and every reading is published (a failed poll
  keeps the last): raw readings jitter and a restarted track's first ones can
  lag by seconds, so the consumer judges them. A route change clears the anchor.
  A track left unfed for 500 ms (iOS's idle grace) pauses, with no anchor, and
  plays again on the next feed; a shorter stall underruns and resumes. `starts`
  counts each play, so a consumer restarts its timing there. The routed device
  is re-read only after AudioTrack's routing listener fires (or while unrouted),
  not on every status. No playback-head fallback is presented as hardware timing.
- iOS publishes the callback's `AudioTimeStamp.mHostTime` with the first PCM
  frame it reads from the ring. Atomic versioned snapshots avoid blocking or
  allocating in the callback. Silence-only callbacks invalidate the anchor.
  A different route cannot reuse a setup's anchor. The route is cached and
  re-read only after `AVAudioSessionRouteChangeNotification` or reactivation.
  `starts` is 0 on iOS, whose restarted unit anchors from its first callback.
- `underruns` counts one per starvation episode on iOS, idle drains included;
  Android reports the track's `getUnderrunCount`, and its unfed track pauses
  after the grace rather than keep underrunning.
- Five clock exchanges map native monotonic time to `Timeline.now`; the shortest
  round trip sets the offset (`timelineOffsetUs`, the same estimator as
  flutter_audio_capture's). Neither platform reports a bound on driver,
  converter or acoustic latency, so none is exposed.
- Setup is cancellable during its claim and clock synchronization. A release
  cannot be followed by a late setup creating an orphan output.
  Generation-specific cleanup does not release a newer output.
- `setupOutput` claims first and sends the claim as its `owner`. Native refuses
  an owned setup once a newer claim exists (`Superseded`), with no side effects,
  so the setup begun last wins across isolates. Legacy `setup` claims afresh.
  Callers must reach `setupOutput` in the same event turn as their last stop
  check: a native round trip in between lets a stopped caller claim after its
  successor. `setLogLevel` makes none.
- Errors carry one code on both platforms (`PcmErrorCode`): `Arguments`,
  `Setup`, `Generation`, `Capacity`, `Superseded`, `AudioUnitError` (a failed
  or stopped output) and `Detached`, with details `{generation}` where an
  output exists; iOS adds `Memory` and `AVAudioSessionError`.

The iOS callback timestamp is a scheduling anchor. Physical loopback must establish
its residual relation to capture on each route before using it for grading.
Extrapolating from the anchor through queued frames is an application estimate,
invalid across starvation or route changes.

Sources: [Android AudioTrack timestamps](https://developer.android.com/reference/android/media/AudioTrack#getTimestamp(android.media.AudioTimestamp)),
[Android AudioTimestamp](https://developer.android.com/reference/android/media/AudioTimestamp),
[Apple AudioUnitRender](https://developer.apple.com/documentation/audiotoolbox/audiounitrender(_:_:_:_:_:_:)).
