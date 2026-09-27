package com.lib.flutter_pcm_sound;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioRouting;
import android.media.AudioTrack;
import android.media.AudioTimestamp;
import android.media.AudioDeviceInfo;
import android.os.Handler;
import android.os.Looper;
import androidx.annotation.NonNull;
import java.util.HashMap;
import java.util.Map;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.StandardMethodCodec;

public class FlutterPcmSoundPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
    private final Object lifecycle = new Object();
    private final Handler main = new Handler(Looper.getMainLooper());
    private MethodChannel channel;
    private Output output;
    private long nextGeneration;
    private final PcmClaims claims = new PcmClaims();
    private long threshold = 8000;
    private boolean attached;

    @Override public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        synchronized (lifecycle) {
            BinaryMessenger messenger = binding.getBinaryMessenger();
            channel = new MethodChannel(messenger, "flutter_pcm_sound/methods", StandardMethodCodec.INSTANCE,
                    messenger.makeBackgroundTaskQueue());
            attached = true;
            channel.setMethodCallHandler(this);
        }
    }

    @Override public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        synchronized (lifecycle) {
            attached = false;
            channel.setMethodCallHandler(null);
            // Runs on the main thread: a wedged worker must not crash engine teardown.
            try { release(); } catch (IllegalStateException ignored) { }
        }
    }

    private static long number(MethodCall call, String key, long fallback) {
        Object value = call.argument(key);
        return value instanceof Number ? ((Number) value).longValue() : fallback;
    }

    @Override public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        synchronized (lifecycle) {
            try {
                if (!attached) throw new IllegalStateException("Plugin detached");
                switch (call.method) {
                    case "setup":
                    case "setupOutput": {
                        int rate = (int) number(call, "sample_rate", 0);
                        int channels = (int) number(call, "num_channels", 0);
                        int capacity = (int) number(call, "capacity_frames", 48000);
                        if (rate < 8000 || rate > 192000 || (channels != 1 && channels != 2)
                                || capacity < 512 || capacity > 1920000)
                            throw new IllegalArgumentException("Invalid PCM format or capacity");
                        // A setup begun before a newer claim must not replace that owner.
                        if (!claims.admit(call.hasArgument("owner") ? number(call, "owner", 0) : null))
                            throw new SupersededException();
                        release();
                        long generation = call.hasArgument("generation") ? number(call, "generation", 0) : ++nextGeneration;
                        boolean legacy = call.method.equals("setup");
                        // Published only once its worker runs, so feeds never queue into a dead output.
                        Output created = new Output(rate, channels, capacity, generation, legacy);
                        created.start();
                        output = created;
                        result.success(legacy ? created.nativeFrames : created.status());
                        break;
                    }
                    case "feed": {
                        Output current = requireOutput(call);
                        byte[] data = call.argument("buffer");
                        current.feed(data);
                        result.success(Boolean.TRUE.equals(call.argument("status")) ? current.status() : true);
                        break;
                    }
                    case "status": result.success(requireOutput(call).status()); break;
                    case "clock": result.success(System.nanoTime()); break;
                    case "claim": result.success(claims.take()); break;
                    case "release":
                        // Releasing an older generation is a harmless no-op, as on iOS.
                        if (output != null && number(call, "generation", output.generation) != output.generation) {
                            result.success(false); break;
                        }
                        release(); result.success(true); break;
                    case "setFeedThreshold":
                        threshold = Math.max(0, number(call, "feed_threshold", 8000));
                        if (output != null) output.threshold = threshold;
                        result.success(true); break;
                    default: result.notImplemented();
                }
            } catch (CapacityException e) {
                result.error("Capacity", e.getMessage(), null);
            } catch (SupersededException e) {
                result.error("Superseded", e.getMessage(), null);
            } catch (Exception e) {
                result.error("PcmOutput", e.toString(), null);
            }
        }
    }

    private Output requireOutput(MethodCall call) {
        if (output == null) throw new IllegalStateException("Must call setup first");
        if (number(call, "generation", output.generation) != output.generation)
            throw new IllegalStateException("Stale output generation");
        return output;
    }

    private void release() {
        Output old = output;
        if (old == null) return;
        // Retain the failed generation if shutdown times out: never open a second track over it.
        old.close();
        output = null;
    }

    private static final class CapacityException extends IllegalStateException {
        CapacityException() { super("PCM capacity exceeded"); }
    }

    private static final class SupersededException extends IllegalStateException {
        SupersededException() { super("A newer setup claimed the output"); }
    }

    private final class Output {
        // Every reading is published: the consumer judges them, as raw readings jitter and a restart's
        // first ones can lag by seconds.
        private static final long TIMESTAMP_POLL_NS = 100_000_000L;
        final Object lock = new Object();
        final long generation;
        final AudioTrack track;
        final PcmQueue queue;
        final int frameBytes;
        final int sampleRate;
        final AudioTimestamp timestamp = new AudioTimestamp();
        long timestampFrame = -1;
        long timestampNs;
        long timestampPollNs;
        // play() calls: a drained track pauses, so a consumer restarts its timing on each start.
        long starts;
        boolean paused;
        String routeId;
        volatile boolean routeDirty = true; // set by the routing listener: status re-reads the route once
        // AudioRouting's type, so registration skips the deprecated AudioTrack overload.
        final AudioRouting.OnRoutingChangedListener routing = router -> routeDirty = true;
        final int nativeFrames;
        final int capacityFrames;
        final boolean legacy;
        final Thread worker;
        volatile boolean stopping;
        volatile long threshold = FlutterPcmSoundPlugin.this.threshold;
        long accepted;
        long written;
        long consumed;
        final PcmHead head = new PcmHead(); // guarded by lock
        long feeds;
        long lastLow;
        long lastZero;
        String failure;
        boolean running;
        int underruns; // last count read while running: stays monotonic once the track is released

        Output(int rate, int channels, int capacity, long generation, boolean legacy) {
            this.generation = generation;
            this.sampleRate = rate;
            this.legacy = legacy;
            frameBytes = channels * 2;
            int mask = channels == 2 ? AudioFormat.CHANNEL_OUT_STEREO : AudioFormat.CHANNEL_OUT_MONO;
            int minimum = AudioTrack.getMinBufferSize(rate, mask, AudioFormat.ENCODING_PCM_16BIT);
            if (minimum <= 0) throw new IllegalArgumentException("Unsupported PCM format");
            AudioTrack created = new AudioTrack.Builder().setAudioAttributes(new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                .setAudioFormat(new AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(rate).setChannelMask(mask).build())
                .setBufferSizeInBytes(minimum).setTransferMode(AudioTrack.MODE_STREAM).build();
            if (created.getState() != AudioTrack.STATE_INITIALIZED) {
                created.release();
                throw new IllegalStateException("AudioTrack initialization failed");
            }
            try {
                nativeFrames = created.getBufferSizeInFrames();
                capacityFrames = nativeFrames + capacity;
                queue = new PcmQueue(capacityFrames, frameBytes);
                worker = new Thread(this::run, "PCMPlaybackThread");
                track = created;
            } catch (RuntimeException | Error error) {
                created.release();
                throw error;
            }
        }

        void start() {
            try { worker.start(); }
            catch (RuntimeException | Error error) { track.release(); throw error; }
        }

        void feed(byte[] bytes) {
            synchronized (lock) {
                if (stopping || failure != null) throw new IllegalStateException(failure == null ? "Output stopped" : failure);
                if (bytes == null || bytes.length % frameBytes != 0)
                    throw new IllegalArgumentException("PCM data is not frame aligned");
                int frames = bytes.length / frameBytes;
                if (accepted - consumed + frames > capacityFrames || !queue.offer(bytes)) throw new CapacityException();
                accepted += frames;
                feeds++;
                lock.notifyAll();
            }
        }

        Map<String, Object> status() {
            synchronized (lock) {
                // Receipts stay current while the worker blocks in write(); a stopping track's head reads 0.
                if (running && !stopping) updateConsumed();
                Map<String, Object> result = new HashMap<>();
                result.put("generation", generation);
                result.put("accepted_frames", accepted);
                result.put("consumed_frames", consumed);
                result.put("remaining_frames", accepted - consumed);
                result.put("capacity_frames", capacityFrames);
                result.put("native_buffer_frames", nativeFrames);
                result.put("total_feeds", feeds);
                if (running) underruns = track.getUnderrunCount();
                result.put("underruns", underruns);
                result.put("failure", failure);
                updateTimestamp();
                result.put("sample_rate", sampleRate);
                result.put("output_route", routeId);
                result.put("starts", starts);
                result.put("timestamp_frame", timestampFrame < 0 ? null : timestampFrame);
                result.put("timestamp_ns", timestampFrame < 0 ? null : timestampNs);
                return result;
            }
        }

        // The latest reading while the track plays: a failed poll keeps the last, a pause clears it, so a
        // restarted track publishes nothing until it reads afresh.
        private void updateTimestamp() {
            if (!running || stopping || paused || failure != null) { timestampFrame = -1; return; }
            // Re-read only after a routing change, or while unrouted: registration follows play().
            if (routeDirty || routeId == null) {
                routeDirty = false;
                AudioDeviceInfo route = track.getRoutedDevice();
                routeId = route == null ? null : route.getType() + ":" + route.getId();
            }
            long now = System.nanoTime();
            if (now - timestampPollNs < TIMESTAMP_POLL_NS) return;
            timestampPollNs = now;
            if (!track.getTimestamp(timestamp)) return;
            long frame = PcmTimestamp.extend(timestamp.framePosition, written);
            if (frame < 0 || timestamp.nanoTime <= 0) return;
            timestampFrame = frame;
            timestampNs = timestamp.nanoTime;
        }

        // Under lock. A playing track that is fed nothing underruns every mixer cycle and is disabled;
        // pausing it once its buffer has played keeps its restart, and its timestamps, the framework's.
        private void pauseDrained() {
            if (paused || stopping) return;
            track.pause();
            paused = true;
            timestampFrame = -1;
        }

        private void playIfPaused() {
            if (!paused) return;
            track.play();
            paused = false;
            starts++;
            timestampPollNs = 0;
        }

        void close() {
            stopping = true;
            synchronized (lock) { lock.notifyAll(); }
            PcmWorkerShutdown.await(worker, () -> {
                try { track.pause(); track.flush(); } catch (IllegalStateException ignored) { }
            }, 1000);
        }

        private void notifyLegacy() {
            if (!legacy) return;
            Map<String, Object> reading;
            synchronized (lock) {
                long remaining = accepted - consumed;
                boolean low = remaining <= threshold && lastLow != feeds;
                boolean zero = remaining == 0 && lastZero != feeds;
                if (!low && !zero) return;
                if (low) lastLow = feeds;
                if (zero) lastZero = feeds;
                reading = status();
            }
            main.post(() -> {
                synchronized (lifecycle) {
                    if (attached && output == this && !stopping) channel.invokeMethod("OnFeedSamples", reading);
                }
            });
        }

        private void updateConsumed() {
            synchronized (lock) { consumed = head.consumed(track.getPlaybackHeadPosition(), written); }
        }

        private void run() {
            try {
                PcmWritePump pump = new PcmWritePump(512, frameBytes);
                // Blocks until the device takes the chunk; close()'s pause() cuts it short.
                PcmWritePump.Sink sink = (bytes, offset, length) -> track.write(bytes, offset, length);
                android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO);
                track.play();
                track.addOnRoutingChangedListener(routing, main);
                synchronized (lock) { running = true; starts = 1; }
                while (!stopping) {
                    if (!pump.hasPending()) {
                        synchronized (lock) {
                            pump.refill(queue);
                            if (pump.hasPending()) playIfPaused();
                        }
                    }
                    if (pump.hasPending()) {
                        int count = pump.write(sink);
                        synchronized (lock) { written += count / frameBytes; }
                        // Only an interrupted write (close) comes back empty: back off rather than spin.
                        if (count == 0) Thread.sleep(2);
                    } else {
                        synchronized (lock) {
                            if (!stopping && queue.frames() == 0) {
                                boolean drained = accepted == consumed;
                                if (drained) pauseDrained();
                                lock.wait(drained ? 0 : 10);
                            }
                        }
                    }
                    if (!stopping) { updateConsumed(); notifyLegacy(); }
                }
            } catch (InterruptedException e) {
                if (!stopping) synchronized (lock) { failure = "PCM worker interrupted"; }
            } catch (Throwable e) {
                synchronized (lock) { failure = e.toString(); }
            } finally {
                synchronized (lock) { running = false; }
                try { track.stop(); } catch (IllegalStateException ignored) { }
                try { track.flush(); } catch (IllegalStateException ignored) { }
                track.removeOnRoutingChangedListener(routing);
                track.release();
            }
        }
    }
}
