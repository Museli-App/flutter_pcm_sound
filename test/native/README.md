# Native regression tests

From the fork root, on a host with Clang and a JDK:

```sh
clang -std=c11 -Wall -Wextra -Werror -pthread -fsanitize=thread \
  test/native/pcm_ring_test.c -o /tmp/pcm-ring-tsan
/tmp/pcm-ring-tsan
clang -std=c11 -Wall -Wextra -Werror -pthread -fsanitize=address,undefined \
  test/native/pcm_ring_test.c -o /tmp/pcm-ring-asan
/tmp/pcm-ring-asan
javac -d /tmp/pcm-tests \
  android/src/main/java/com/lib/flutter_pcm_sound/PcmHead.java \
  android/src/main/java/com/lib/flutter_pcm_sound/PcmTimestamp.java \
  android/src/main/java/com/lib/flutter_pcm_sound/PcmQueue.java \
  android/src/main/java/com/lib/flutter_pcm_sound/PcmWritePump.java \
  android/src/main/java/com/lib/flutter_pcm_sound/PcmWorkerShutdown.java \
  android/src/main/java/com/lib/flutter_pcm_sound/PcmClaims.java \
  android/src/main/java/com/lib/flutter_pcm_sound/PcmDrain.java \
  test/native/com/lib/flutter_pcm_sound/*.java
java -cp /tmp/pcm-tests com.lib.flutter_pcm_sound.PcmTimestampTest
java -cp /tmp/pcm-tests com.lib.flutter_pcm_sound.PcmHeadTest
java -cp /tmp/pcm-tests com.lib.flutter_pcm_sound.PcmQueueTest
java -cp /tmp/pcm-tests com.lib.flutter_pcm_sound.PcmWritePumpTest
java -cp /tmp/pcm-tests com.lib.flutter_pcm_sound.PcmClaimsTest
java -cp /tmp/pcm-tests com.lib.flutter_pcm_sound.PcmDrainTest
flutter test
```

The C test checks capacity rejection, wraparound, empty reads, a million
concurrent producer/consumer transfers, the idle-stop grace and one underrun per
starvation episode. JVM tests check the widened, capped playback head, frame
alignment, bounded storage, short/zero writes, dead-track/error returns,
preserved tails, cleanup through exceptions and bounded shutdown. JVM and C claim tests check that
only the newest owned setup is admitted and an unowned one claims afresh. The JVM drain test checks that a
track left drained and unfed pauses only after the grace (a feed or playing frames restart it), a refill plays
it again and counts a start unless stopping, and the timestamp anchor is polled at most every 100 ms, keeps its
last reading within a route and clears on a pause, a route change or while not playing. Method-channel tests
cover generation receipts, byte-view offsets/lengths, validation, rejected feeds and the clock estimator.

These are host regressions, not measurements of AudioTrack/AudioUnit behavior on
physical devices. Setup, route changes, interruptions, latency and long-run CPU,
underruns and memory still require profile/release testing on iOS and Android.

Plugin compile check (Android can't be built here; any JDK 11+ `javac` works,
e.g. Android Studio's bundled one, with the annotation jar from `~/.gradle/caches`):

```sh
javac -Xlint:all -source 8 -target 8 -d /tmp/pcm-plugin \
  -cp "$ANDROID_SDK_ROOT/platforms/android-33/android.jar:$FLUTTER_ROOT/bin/cache/artifacts/engine/android-arm/flutter.jar:<annotation-jvm.jar>" \
  android/src/main/java/com/lib/flutter_pcm_sound/*.java
```

Output timestamp snapshot regression (one million concurrent publications):

```sh
clang -std=c11 -Wall -Wextra -Werror -pthread -fsanitize=address,undefined \
  test/native/pcm_timing_test.c -o /tmp/pcm-timing-test
/tmp/pcm-timing-test
```

Takeover claim regression (the same rule as `PcmClaims.java`):

```sh
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
  test/native/pcm_claims_test.c -o /tmp/pcm-claims-test
/tmp/pcm-claims-test
```
