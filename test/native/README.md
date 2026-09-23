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
  test/native/com/lib/flutter_pcm_sound/*.java
java -cp /tmp/pcm-tests com.lib.flutter_pcm_sound.PcmTimestampTest
java -cp /tmp/pcm-tests com.lib.flutter_pcm_sound.PcmHeadTest
java -cp /tmp/pcm-tests com.lib.flutter_pcm_sound.PcmQueueTest
java -cp /tmp/pcm-tests com.lib.flutter_pcm_sound.PcmWritePumpTest
flutter test
```

The C test checks capacity rejection, wraparound, empty reads, a million
concurrent producer/consumer transfers, the idle-stop grace and one underrun per
starvation episode. JVM tests check the widened, capped playback head, frame
alignment, bounded storage, short/zero writes, dead-track/error returns,
preserved tails, cleanup through exceptions and bounded shutdown. Method-channel tests cover generation
receipts, byte-view offsets/lengths, validation and rejected feeds.

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
