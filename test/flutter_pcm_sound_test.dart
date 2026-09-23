import 'dart:typed_data';
import 'dart:async';
import 'dart:developer' show Timeline;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_pcm_sound/methods');
  final calls = <MethodCall>[];
  final status = <String, Object?>{
    'generation': 42,
    'accepted_frames': 512,
    'consumed_frames': 64,
    'capacity_frames': 5120,
    'native_buffer_frames': 0,
    'total_feeds': 1,
    'underruns': 0,
    'failure': null,
    'sample_rate': 48000,
    'output_route': 'speaker:1',
  };
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'clock') return Timeline.now * 1000 + 9000000000;
          if (call.method == 'setupOutput' ||
              call.method == 'status' ||
              call.method == 'feed' && call.arguments['status'] == true)
            return status;
          return true;
        });
  });
  tearDown(() {
    FlutterPcmSound.setFeedCallback(null);
    FlutterPcmSound.setFeedTelemetryCallback(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test('feed sends only a ByteData view, for both APIs', () async {
    final storage = Uint8List.fromList([99, 99, 1, 0, 2, 0, 99, 99]);
    final pcm = PcmArrayInt16(bytes: ByteData.view(storage.buffer, 2, 4));
    await FlutterPcmSound.feed(pcm);
    expect(calls.last.arguments['buffer'], [1, 0, 2, 0]);
    final reply = await FlutterPcmSound.feedWithStatus(pcm, generation: 42);
    expect(calls.last.arguments['buffer'], [1, 0, 2, 0]);
    expect(calls.last.arguments['generation'], 42);
    expect(reply.remainingFrames, 448);
  });
  test('setup and status preserve output generation and counters', () async {
    final output = await FlutterPcmSound.setupOutput(
      sampleRate: 48000,
      channelCount: 1,
      generation: 42,
    );
    expect(calls.last.arguments['capacity_frames'], 5120);
    expect(calls.last.arguments['ios_audio_category'], isNull);
    expect(output.generation, 42);
    expect((await FlutterPcmSound.status(generation: 42)).consumedFrames, 64);
    await FlutterPcmSound.release(generation: 42);
    expect(calls.last.arguments['generation'], 42);
  });
  test('bad formats fail before the native channel', () async {
    await expectLater(
      FlutterPcmSound.setupOutput(
        sampleRate: 0,
        channelCount: 1,
        generation: 1,
      ),
      throwsArgumentError,
    );
    await expectLater(
      FlutterPcmSound.setupOutput(
        sampleRate: 48000,
        channelCount: 3,
        generation: 1,
      ),
      throwsArgumentError,
    );
    expect(calls, isEmpty);
  });
  test('a rejected feed stays an error', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          throw PlatformException(code: 'Capacity');
        });
    await expectLater(
      FlutterPcmSound.feedWithStatus(
        PcmArrayInt16.zeros(count: 512),
        generation: 42,
      ),
      throwsA(isA<PlatformException>()),
    );
  });
  test('native frame times are mapped independently of receipt arrival',
      () async {
    status['timestamp_frame'] = 64;
    status['timestamp_ns'] = Timeline.now * 1000 + 9000000000;
    addTearDown(() => status
      ..remove('timestamp_frame')
      ..remove('timestamp_ns'));
    final before = Timeline.now;
    final output = await FlutterPcmSound.setupOutput(
      sampleRate: 48000,
      channelCount: 1,
      generation: 42,
    );
    expect(output.presentation!.frame, 64);
    expect(output.presentation!.hostTimeUs!, closeTo(before, 20000));
    final original = output.presentation!.hostTimeUs;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
        (await FlutterPcmSound.status(generation: 42)).presentation!.hostTimeUs,
        original);
  });
  test('another generation\'s timestamps stay unmapped', () async {
    await FlutterPcmSound.setupOutput(
        sampleRate: 48000, channelCount: 1, generation: 42);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => {
              ...status,
              'generation': 43,
              'timestamp_frame': 64,
              'timestamp_ns': Timeline.now * 1000 + 9000000000,
            });
    final presentation =
        (await FlutterPcmSound.status(generation: 43)).presentation!;
    expect(presentation.frame, 64);
    expect(presentation.hostTimeUs, isNull);
  });
  test('unavailable native timestamps remain unavailable', () {
    expect(PcmOutputStatus.fromMap(status).presentation, isNull);
  });

  test('release during clock synchronization cannot create a late output',
      () async {
    final clock = Completer<int>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'clock') return clock.future;
      return null;
    });
    final pending = FlutterPcmSound.setupOutput(
        sampleRate: 48000, channelCount: 1, generation: 88);
    final expected = expectLater(pending, throwsStateError);
    await FlutterPcmSound.release(generation: 88);
    clock.complete(Timeline.now * 1000);
    await expected;
    expect(calls.where((call) => call.method == 'setupOutput'), isEmpty);
  });
  test('release during native setup releases the late output', () async {
    final setup = Completer<Map<String, Object?>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'clock') return Timeline.now * 1000;
      if (call.method == 'setupOutput') return setup.future;
      return null;
    });
    final pending = FlutterPcmSound.setupOutput(
        sampleRate: 48000, channelCount: 1, generation: 90);
    final expected = expectLater(pending, throwsStateError);
    await pumpEventQueue();
    expect(calls.last.method, 'setupOutput');
    await FlutterPcmSound.release(generation: 90);
    setup.complete({...status, 'generation': 90});
    await expected;
    final releases = calls.where((call) => call.method == 'release').toList();
    expect(releases, hasLength(2));
    expect(calls.last.method, 'release');
    expect(calls.last.arguments['generation'], 90);
  });
}
