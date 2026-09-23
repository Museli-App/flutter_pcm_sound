import 'dart:math' as math;
import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:typed_data';
import 'package:flutter/services.dart';

enum LogLevel { none, error, standard, verbose }

// Apple Documentation: https://developer.apple.com/documentation/avfaudio/avaudiosessioncategory
enum IosAudioCategory {
  soloAmbient, // same as ambient, but other apps will be muted. Other apps will be muted.
  ambient, // same as soloAmbient, but other apps are not muted.
  playback, // audio will play when phone is locked, like the music app
  playAndRecord, //
}

/// A snapshot of one native output generation. Counters never include rejected feeds.
class PcmOutputStatus {
  final int generation;
  final int acceptedFrames;
  final int consumedFrames;
  final int capacityFrames;
  final int nativeBufferFrames;
  final int totalFeeds;
  /// Starvation episodes since setup, counted as Android's getUnderrunCount counts them.
  final int underruns;
  final String? failure;
  final int? sampleRate;
  final String? outputRoute;
  final PcmPresentationTimestamp? presentation;

  const PcmOutputStatus({
    required this.generation,
    required this.acceptedFrames,
    required this.consumedFrames,
    required this.capacityFrames,
    required this.nativeBufferFrames,
    required this.totalFeeds,
    required this.underruns,
    this.failure,
    this.sampleRate,
    this.outputRoute,
    this.presentation,
  });

  factory PcmOutputStatus.fromMap(Map<dynamic, dynamic> map,
          {int? clockOffsetNs}) =>
      PcmOutputStatus(
        generation: map['generation'] as int,
        acceptedFrames: map['accepted_frames'] as int,
        consumedFrames: map['consumed_frames'] as int,
        capacityFrames: map['capacity_frames'] as int,
        nativeBufferFrames: map['native_buffer_frames'] as int,
        totalFeeds: map['total_feeds'] as int,
        underruns: map['underruns'] as int,
        failure: map['failure'] as String?,
        sampleRate: map['sample_rate'] as int?,
        outputRoute: map['output_route'] as String?,
        presentation: PcmPresentationTimestamp.fromMap(map,
            clockOffsetNs: clockOffsetNs),
      );

  int get remainingFrames => acceptedFrames - consumedFrames;
}

/// Native monotonic time for an output frame, not the time its receipt arrived.
class PcmPresentationTimestamp {
  const PcmPresentationTimestamp({
    required this.frame,
    required this.nativeTimeNs,
    this.hostTimeUs,
  });
  final int frame;
  final int nativeTimeNs;
  final int? hostTimeUs;

  static PcmPresentationTimestamp? fromMap(Map<dynamic, dynamic> map,
      {int? clockOffsetNs}) {
    final frame = map['timestamp_frame'] as int?;
    final time = map['timestamp_ns'] as int?;
    if (frame == null || time == null || frame < 0 || time <= 0) return null;
    return PcmPresentationTimestamp(
      frame: frame,
      nativeTimeNs: time,
      hostTimeUs: clockOffsetNs == null ? null : (time + clockOffsetNs) ~/ 1000,
    );
  }
}

class FlutterPcmSound {
  static const MethodChannel _channel = const MethodChannel(
    'flutter_pcm_sound/methods',
  );

  static Function(int)? onFeedSamplesCallback;

  static Function(int remainingFrames, int totalFeeds)? onFeedTelemetryCallback;

  static LogLevel _logLevel = LogLevel.standard;

  static bool _needsStart = true;
  static var _setupRevision = 0;
  static int? _requestedGeneration;
  static int? _clockGeneration;
  static int? _clockOffsetNs;

  static Future<int> _synchronizeClock() async {
    int? offset;
    var bestRoundTripNs = 0;
    for (var sample = 0; sample < 5; sample++) {
      final beforeNs = Timeline.now * 1000;
      final nativeNs = await _nativeClockNs();
      final afterNs = Timeline.now * 1000;
      // The shortest round trip gives the tightest offset.
      if (offset == null || afterNs - beforeNs < bestRoundTripNs) {
        bestRoundTripNs = afterNs - beforeNs;
        offset = (beforeNs + afterNs) ~/ 2 - nativeNs;
      }
    }
    return offset!;
  }

  static PcmOutputStatus _decodeStatus(Map<dynamic, dynamic> map) {
    // Only the current generation's exchange maps its timestamps.
    final mapped = map['generation'] == _clockGeneration;
    return PcmOutputStatus.fromMap(
      map,
      clockOffsetNs: mapped ? _clockOffsetNs : null,
    );
  }

  /// Exchanges the same monotonic clock used by output timestamps.
  static Future<int> _nativeClockNs() async =>
      (await _invokeMethod<int>('clock'))!;

  /// set log level
  static Future<void> setLogLevel(LogLevel level) async {
    _logLevel = level;
    return await _invokeMethod('setLogLevel', {'log_level': level.index});
  }

  /// setup audio
  /// 'avAudioCategory' is for iOS only,
  /// enabled by default on other platforms
  /// A null 'iosAudioCategory' leaves the AVAudioSession to the app.
  /// Returns the native output buffer's capacity in frames, which the feed
  /// callback's count includes; 0 where the platform has none (iOS).
  static Future<int> setup({
    required int sampleRate,
    required int channelCount,
    IosAudioCategory? iosAudioCategory = IosAudioCategory.playback,
    bool iosAllowBackgroundAudio = false,
  }) async {
    ++_setupRevision;
    _requestedGeneration = null;
    _clockGeneration = null;
    final reply = await _invokeMethod<Object>('setup', {
      'sample_rate': sampleRate,
      'num_channels': channelCount,
      'ios_audio_category': iosAudioCategory?.name,
      'ios_allow_background_audio': iosAllowBackgroundAudio,
    });
    _needsStart = true;
    return reply is int ? reply : 0;
  }

  /// Creates bounded output without unsolicited callbacks. Suitable for background isolates.
  static Future<PcmOutputStatus> setupOutput({
    required int sampleRate,
    required int channelCount,
    required int generation,
    int capacityFrames = 5120,
    IosAudioCategory? iosAudioCategory,
    bool iosAllowBackgroundAudio = false,
  }) async {
    if (sampleRate < 8000 ||
        sampleRate > 192000 ||
        (channelCount != 1 && channelCount != 2) ||
        capacityFrames < 512 ||
        capacityFrames > 1920000) {
      throw ArgumentError('Invalid PCM format or capacity');
    }
    final revision = ++_setupRevision;
    _requestedGeneration = generation;
    final offsetNs = await _synchronizeClock();
    if (revision != _setupRevision) throw StateError('PCM setup cancelled');
    _clockOffsetNs = offsetNs;
    _clockGeneration = generation;
    final reply = await _invokeMethod<Map<dynamic, dynamic>>('setupOutput', {
      'sample_rate': sampleRate,
      'num_channels': channelCount,
      'generation': generation,
      'capacity_frames': capacityFrames,
      'ios_audio_category': iosAudioCategory?.name,
      'ios_allow_background_audio': iosAllowBackgroundAudio,
    });
    if (revision != _setupRevision) {
      await _invokeMethod<void>('release', {'generation': generation});
      throw StateError('PCM setup cancelled');
    }
    return _decodeStatus(reply!);
  }

  static Future<PcmOutputStatus> feedWithStatus(
    PcmArrayInt16 buffer, {
    required int generation,
  }) async {
    final reply = await _invokeMethod<Map<dynamic, dynamic>>('feed', {
      'buffer': buffer.bytes.buffer.asUint8List(
        buffer.bytes.offsetInBytes,
        buffer.bytes.lengthInBytes,
      ),
      'generation': generation,
      'status': true,
    });
    return _decodeStatus(reply!);
  }

  static Future<PcmOutputStatus> status({required int generation}) async =>
      _decodeStatus(
        (await _invokeMethod<Map<dynamic, dynamic>>('status', {
          'generation': generation,
        }))!,
      );

  /// queue 16-bit samples (little endian)
  static Future<void> feed(PcmArrayInt16 buffer) async {
    if (_needsStart && buffer.count != 0) _needsStart = false;
    return await _invokeMethod('feed', {
      'buffer': buffer.bytes.buffer.asUint8List(
        buffer.bytes.offsetInBytes,
        buffer.bytes.lengthInBytes,
      ),
    });
  }

  /// set the threshold at which we call the
  /// feed callback. i.e. if we have less than X
  /// queued frames, the feed callback will be invoked
  static Future<void> setFeedThreshold(int threshold) async {
    return await _invokeMethod('setFeedThreshold', {
      'feed_threshold': threshold,
    });
  }

  /// Your feed callback is invoked _once_ for each of these events:
  /// - Low-buffer event: when the number of buffered frames falls below the threshold set with `setFeedThreshold`
  /// - Zero event: when the buffer is fully drained (`remainingFrames == 0`)
  /// Note: once means once per `feed()`. Every time you feed new data, it allows
  /// the plugin to trigger another low-buffer or zero event.
  static void setFeedCallback(Function(int)? callback) {
    onFeedSamplesCallback = callback;
    _channel.setMethodCallHandler(_methodCallHandler);
  }

  /// As [setFeedCallback], plus `totalFeeds`: how many `feed()` calls since `setup`
  /// the frame count includes, so a caller whose feeds outrun the callback can add
  /// back the ones a reading missed. Native readings only: [start] never invokes it.
  static void setFeedTelemetryCallback(
    Function(int remainingFrames, int totalFeeds)? callback,
  ) {
    onFeedTelemetryCallback = callback;
    _channel.setMethodCallHandler(_methodCallHandler);
  }

  /// convenience function:
  ///   * if needed, invokes your feed callback to start playback
  ///   * returns true if your callback was invoked
  static bool start() {
    if (_needsStart && onFeedSamplesCallback != null) {
      onFeedSamplesCallback!(0);
      return true;
    } else {
      return false;
    }
  }

  /// release all audio resources
  static Future<void> release({int? generation}) async {
    if (generation == null || generation == _requestedGeneration) {
      ++_setupRevision;
      _requestedGeneration = null;
      _clockGeneration = null;
    }
    await _invokeMethod('release', {
      if (generation != null) 'generation': generation,
    });
    _needsStart = true;
  }

  static Future<T?> _invokeMethod<T>(String method, [dynamic arguments]) async {
    if (_logLevel.index >= LogLevel.standard.index) {
      String args = '';
      if (method == 'feed') {
        Uint8List data = arguments['buffer'];
        if (data.lengthInBytes > 6) {
          args =
              '(${data.lengthInBytes ~/ 2} samples) ${data.sublist(0, 6)} ...';
        } else {
          args = '(${data.lengthInBytes ~/ 2} samples) $data';
        }
      } else if (arguments != null) {
        args = arguments.toString();
      }
      print("[PCM] invoke: $method $args");
    }
    return await _channel.invokeMethod(method, arguments);
  }

  static Future<dynamic> _methodCallHandler(MethodCall call) async {
    if (_logLevel.index >= LogLevel.standard.index) {
      String func = '[[ ${call.method} ]]';
      String args = call.arguments.toString();
      print("[PCM] $func $args");
    }
    switch (call.method) {
      case 'OnFeedSamples':
        int remainingFrames = call.arguments["remaining_frames"];
        _needsStart = remainingFrames == 0;
        if (onFeedSamplesCallback != null) {
          onFeedSamplesCallback!(remainingFrames);
        }
        if (onFeedTelemetryCallback != null) {
          int totalFeeds = call.arguments["total_feeds"];
          onFeedTelemetryCallback!(remainingFrames, totalFeeds);
        }
        break;
      default:
        print('Method not implemented');
    }
  }
}

class PcmArrayInt16 {
  final ByteData bytes;

  PcmArrayInt16({required this.bytes});

  factory PcmArrayInt16.zeros({required int count}) {
    Uint8List list = Uint8List(count * 2);
    return PcmArrayInt16(bytes: list.buffer.asByteData());
  }

  factory PcmArrayInt16.empty() {
    return PcmArrayInt16.zeros(count: 0);
  }

  factory PcmArrayInt16.fromList(List<int> list) {
    var byteData = ByteData(list.length * 2);
    for (int i = 0; i < list.length; i++) {
      byteData.setInt16(i * 2, list[i], Endian.little);
    }
    return PcmArrayInt16(bytes: byteData);
  }

  int get count => bytes.lengthInBytes ~/ 2;

  operator [](int idx) {
    int vv = bytes.getInt16(idx * 2, Endian.little);
    return vv;
  }

  operator []=(int idx, int value) {
    return bytes.setInt16(idx * 2, value, Endian.little);
  }
}

// for testing
class MajorScale {
  int _periodCount = 0;
  int sampleRate = 44100;
  double noteDuration = 0.25;

  MajorScale({required this.sampleRate, required this.noteDuration});

  // C Major Scale (Just Intonation)
  List<double> get scale {
    List<double> c = [
      261.63,
      294.33,
      327.03,
      348.83,
      392.44,
      436.05,
      490.55,
      523.25,
    ];
    return [c[0]] + c + c.reversed.toList().sublist(0, c.length - 1);
  }

  // total periods needed to play the entire note
  int _periodsForNote(double freq) {
    int nFramesPerPeriod = (sampleRate / freq).round();
    int totalFramesForDuration = (noteDuration * sampleRate).round();
    return totalFramesForDuration ~/ nFramesPerPeriod;
  }

  // total periods needed to play the whole scale
  int get _periodsForScale {
    int total = 0;
    for (double freq in scale) {
      total += _periodsForNote(freq);
    }
    return total;
  }

  // what note are we currently playing
  int get noteIdx {
    int accum = 0;
    for (int n = 0; n < scale.length; n++) {
      accum += _periodsForNote(scale[n]);
      if (_periodCount < accum) {
        return n;
      }
    }
    return scale.length - 1;
  }

  // generate a sine wave
  List<int> cosineWave({
    int periods = 1,
    int sampleRate = 44100,
    double freq = 440,
    double volume = 0.5,
  }) {
    final period = 1.0 / freq;
    final nFramesPerPeriod = (period * sampleRate).toInt();
    final totalFrames = nFramesPerPeriod * periods;
    final step = math.pi * 2 / nFramesPerPeriod;
    List<int> data = List.filled(totalFrames, 0);
    for (int i = 0; i < totalFrames; i++) {
      data[i] =
          (math.cos(step * (i % nFramesPerPeriod)) * volume * 32768).toInt() -
          16384;
    }
    return data;
  }

  void reset() {
    _periodCount = 0;
  }

  // generate the next X periods of the major scale
  List<int> generate({required int periods, double volume = 0.5}) {
    List<int> frames = [];
    for (int i = 0; i < periods; i++) {
      _periodCount %= _periodsForScale;
      frames += cosineWave(
        periods: 1,
        sampleRate: sampleRate,
        freq: scale[noteIdx],
        volume: volume,
      );
      _periodCount++;
    }
    return frames;
  }
}
