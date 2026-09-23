import 'dart:typed_data';
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
  };
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
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
}
