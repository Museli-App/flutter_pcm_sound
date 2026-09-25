# Native output timing

`setupOutput`, `feedWithStatus` and `status` include a nullable `presentation`
anchor, sample rate and actual output route identifier. Queue consumption remains
separate from timestamp validity.

- Android uses `AudioTrack.getTimestamp`. Its wrapping 32-bit frame position is
  extended against written frames. Polling starts at 100 ms, then slows to 10 s
  after advancing readings. Route changes and underruns invalidate the cached
  anchor. The routed device is re-read only after AudioTrack's routing listener
  fires (or while unrouted), not on every status. No playback-head fallback is
  presented as hardware timing.
- iOS publishes the callback's `AudioTimeStamp.mHostTime` with the first PCM
  frame it reads from the ring. Atomic versioned snapshots avoid blocking or
  allocating in the callback. Silence-only callbacks invalidate the anchor.
  A different route cannot reuse a setup's anchor. The route is cached and
  re-read only after `AVAudioSessionRouteChangeNotification` or reactivation.
- Five clock exchanges map native monotonic time to `Timeline.now`; the shortest
  round trip sets the offset. Neither platform reports a bound on driver,
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

The iOS callback timestamp is a scheduling anchor. Physical loopback must establish
its residual relation to capture on each route before using it for grading.
Extrapolating from the anchor through queued frames is an application estimate,
invalid across starvation or route changes.

Sources: [Android AudioTrack timestamps](https://developer.android.com/reference/android/media/AudioTrack#getTimestamp(android.media.AudioTimestamp)),
[Android AudioTimestamp](https://developer.android.com/reference/android/media/AudioTimestamp),
[Apple AudioUnitRender](https://developer.apple.com/documentation/audiotoolbox/audiounitrender(_:_:_:_:_:_:)).
