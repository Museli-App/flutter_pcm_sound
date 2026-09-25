#import "FlutterPcmSoundPlugin.h"
#import "PcmClaims.h"
#import "PcmRing.h"
#import "PcmTiming.h"
#import <mach/mach_time.h>
#import <AudioToolbox/AudioToolbox.h>
#if TARGET_OS_IOS
#import <AVFoundation/AVFoundation.h>
#endif

static const NSUInteger DefaultCapacity = 48000;
static const uint64_t TelemetryPeriodNs = 10 * NSEC_PER_MSEC;
static const uint64_t TelemetryLeewayNs = NSEC_PER_MSEC;
static const uint32_t IdleStopTicks = 50; // 500 ms of telemetry ticks: outlasts the longest isolate stall seen (277 ms, debug).
static OSStatus RenderCallback(void *, AudioUnitRenderActionFlags *, const AudioTimeStamp *,
                               UInt32, UInt32, AudioBufferList *);

@interface FlutterPcmSoundPlugin () {
@public
    PcmRing _ring;
    PcmTiming _timing;
    double _hostTicksToNs;
    _Atomic(uint64_t) _underruns;
    _Atomic(bool) _starved;
    _Atomic(bool) _routeDirty; // set on a route change or reactivation: status re-reads the route once
    PcmIdle _idle; // only under @synchronized(self)
    PcmClaims _claims; // only under @synchronized(self)
}
@property(nonatomic) FlutterMethodChannel *channel;
@property(nonatomic) AudioComponentInstance unit;
@property(nonatomic) dispatch_source_t telemetry;
@property(nonatomic) uint64_t generation;
@property(nonatomic) NSInteger sampleRate;
@property(nonatomic) NSString *setupRoute;
@property(nonatomic) NSString *route; // cached currentRoute, only under @synchronized(self)
@property(nonatomic) uint64_t feeds;
@property(nonatomic) uint64_t lastLowFeed;
@property(nonatomic) uint64_t lastZeroFeed;
@property(nonatomic) NSUInteger threshold;
@property(nonatomic) BOOL configured;
@property(nonatomic) BOOL attached;
@property(nonatomic) BOOL running;
@property(nonatomic) BOOL active;
@property(nonatomic) BOOL allowBackground;
@property(nonatomic) BOOL legacyCallbacks;
@property(nonatomic) NSString *failure;
@end

@implementation FlutterPcmSoundPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    FlutterPcmSoundPlugin *instance = [FlutterPcmSoundPlugin new];
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    instance->_hostTicksToNs = (double)timebase.numer / timebase.denom;
    instance.active = YES;
    instance.attached = YES;
    instance.threshold = 8000;
    instance.channel = [[FlutterMethodChannel alloc] initWithName:@"flutter_pcm_sound/methods"
        binaryMessenger:registrar.messenger codec:FlutterStandardMethodCodec.sharedInstance
        taskQueue:[registrar.messenger makeBackgroundTaskQueue]];
    [registrar addMethodCallDelegate:instance channel:instance.channel];
#if TARGET_OS_IOS
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:instance selector:@selector(resign:) name:UIApplicationWillResignActiveNotification object:nil];
    [nc addObserver:instance selector:@selector(activate:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:instance selector:@selector(routeChanged:) name:AVAudioSessionRouteChangeNotification
        object:AVAudioSession.sharedInstance];
#endif
}

// Starts a stopped unit that holds frames; a refused start keeps them for the next feed or activation.
- (void)startIfQueued {
    if (!self.configured || self.running || self.failure || !(self.active || self.allowBackground)) return;
    uint64_t written = atomic_load_explicit(&_ring.written, memory_order_acquire);
    if (written == atomic_load_explicit(&_ring.read, memory_order_acquire)) return;
    atomic_store_explicit(&_starved, true, memory_order_relaxed);
    if (AudioOutputUnitStart(_unit) != noErr) return;
    self.running = YES;
    PcmIdleReset(&_idle, written);
    dispatch_source_set_timer(self.telemetry, dispatch_time(DISPATCH_TIME_NOW, TelemetryPeriodNs),
        TelemetryPeriodNs, TelemetryLeewayNs);
}

- (void)resign:(NSNotification *)note { @synchronized(self) { self.active = NO; } }
// Also re-reads the route: notifications can be missed while suspended.
- (void)activate:(NSNotification *)note {
    atomic_store(&_routeDirty, true);
    @synchronized(self) { self.active = YES; [self startIfQueued]; }
}
- (void)routeChanged:(NSNotification *)note { atomic_store(&_routeDirty, true); }

// Sorted so the same outputs always compare equal; nil where there is no session.
- (NSString *)currentRoute {
#if TARGET_OS_IOS
    NSMutableArray *ports = [NSMutableArray array];
    for (AVAudioSessionPortDescription *port in AVAudioSession.sharedInstance.currentRoute.outputs)
        [ports addObject:[NSString stringWithFormat:@"%@:%@", port.portType, port.UID]];
    return [[ports sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","];
#else
    return nil;
#endif
}

- (NSDictionary *)status {
    uint64_t accepted = self.configured ? atomic_load_explicit(&_ring.written, memory_order_acquire) : 0;
    uint64_t consumed = self.configured ? atomic_load_explicit(&_ring.read, memory_order_acquire) : 0;
    PcmTimingSnapshot timing;
    BOOL valid = self.running && PcmTimingRead(&_timing, &timing);
    if (atomic_exchange(&_routeDirty, false)) self.route = [self currentRoute];
    NSString *route = self.route;
    if (self.setupRoute && ![self.setupRoute isEqualToString:route]) valid = NO;
    return @{@"sample_rate": @(self.sampleRate), @"output_route": route ?: NSNull.null,
        @"timestamp_frame": valid ? @(timing.frame) : NSNull.null,
        @"timestamp_ns": valid ? @(timing.hostNs) : NSNull.null,
        @"generation": @(self.generation), @"accepted_frames": @(accepted),
        @"consumed_frames": @(consumed), @"remaining_frames": @(accepted - consumed),
        @"capacity_frames": @(self.configured ? _ring.capacity : 0), @"native_buffer_frames": @0,
        @"total_feeds": @(self.feeds), @"underruns": @(atomic_load_explicit(&_underruns, memory_order_relaxed)),
        @"failure": self.failure ?: NSNull.null};
}

- (FlutterError *)error:(NSString *)code message:(NSString *)message {
    return [FlutterError errorWithCode:code message:message details:@{@"generation": @(self.generation)}];
}

- (FlutterError *)checkOSStatus:(OSStatus)status operation:(NSString *)operation {
    if (status == noErr) return nil;
    self.failure = [NSString stringWithFormat:@"%@ failed (%d)", operation, (int)status];
    return [self error:@"AudioUnitError" message:self.failure];
}

- (void)cleanup {
    if (self.telemetry) { dispatch_source_cancel(self.telemetry); self.telemetry = nil; }
    if (_unit) {
        AudioOutputUnitStop(_unit);
        AudioUnitUninitialize(_unit);
        AudioComponentInstanceDispose(_unit);
        _unit = NULL;
    }
    // Stop/dispose synchronizes with the last callback before storage is freed.
    if (_ring.bytes) PcmRingDispose(&_ring);
    self.configured = self.running = NO;
    PcmTimingPublish(&_timing, 0, 0, false);
}

- (FlutterError *)setup:(NSDictionary *)args legacy:(BOOL)legacy {
    NSInteger rate = [args[@"sample_rate"] integerValue];
    NSInteger channels = [args[@"num_channels"] integerValue];
    NSInteger capacity = args[@"capacity_frames"] ? [args[@"capacity_frames"] integerValue] : DefaultCapacity;
    if (rate < 8000 || rate > 192000 || (channels != 1 && channels != 2) || capacity < 512 || capacity > 1920000)
        return [self error:@"Arguments" message:@"Invalid PCM format or capacity"];
    // A setup begun before a newer claim must not replace that owner.
    if (!PcmClaimsAdmit(&_claims, args[@"owner"] != nil, [args[@"owner"] unsignedLongLongValue]))
        return [self error:@"Superseded" message:@"A newer setup claimed the output"];
    [self cleanup];
    self.sampleRate = rate;
    self.generation = args[@"generation"] ? [args[@"generation"] unsignedLongLongValue] : self.generation + 1;
    self.feeds = self.lastLowFeed = self.lastZeroFeed = 0;
    self.failure = nil;
    self.allowBackground = [args[@"ios_allow_background_audio"] boolValue];
    self.legacyCallbacks = legacy;
    atomic_store(&_underruns, 0);
#if TARGET_OS_IOS
    id categoryName = args[@"ios_audio_category"];
    if ([categoryName isKindOfClass:NSString.class]) {
        NSDictionary *categories = @{@"ambient": AVAudioSessionCategoryAmbient,
            @"soloAmbient": AVAudioSessionCategorySoloAmbient, @"playback": AVAudioSessionCategoryPlayback,
            @"playAndRecord": AVAudioSessionCategoryPlayAndRecord};
        NSError *error = nil;
        [AVAudioSession.sharedInstance setCategory:categories[categoryName] ?: AVAudioSessionCategoryPlayback error:&error];
        if (!error) [AVAudioSession.sharedInstance setActive:YES error:&error];
        if (error) return [self error:@"AVAudioSessionError" message:error.localizedDescription];
    }
#endif
    if (!PcmRingInit(&_ring, (size_t)capacity, channels * sizeof(int16_t)))
        return [self error:@"Memory" message:@"Cannot allocate PCM ring"];
    AudioComponentDescription desc = {0};
    desc.componentType = kAudioUnitType_Output;
#if TARGET_OS_IOS
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
#else
    desc.componentSubType = kAudioUnitSubType_DefaultOutput;
#endif
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent component = AudioComponentFindNext(NULL, &desc);
    if (!component) { [self cleanup]; return [self error:@"AudioUnitError" message:@"No output component"]; }
    FlutterError *error = [self checkOSStatus:AudioComponentInstanceNew(component, &_unit) operation:@"create"];
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = rate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    format.mFramesPerPacket = 1;
    format.mChannelsPerFrame = (UInt32)channels;
    format.mBitsPerChannel = 16;
    format.mBytesPerFrame = format.mBytesPerPacket = (UInt32)channels * 2;
    if (!error) error = [self checkOSStatus:AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Input, 0, &format, sizeof(format)) operation:@"format"];
    AURenderCallbackStruct callback = {RenderCallback, (__bridge void *)self};
    if (!error) error = [self checkOSStatus:AudioUnitSetProperty(_unit, kAudioUnitProperty_SetRenderCallback,
        kAudioUnitScope_Global, 0, &callback, sizeof(callback)) operation:@"callback"];
    if (!error) error = [self checkOSStatus:AudioUnitInitialize(_unit) operation:@"initialize"];
    if (error) { [self cleanup]; return error; }
    self.configured = YES;
    // Clear before the query so a notification landing during it is not lost.
    atomic_store(&_routeDirty, false);
    self.route = self.setupRoute = [self currentRoute];
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    self.telemetry = timer;
    uint64_t generation = self.generation;
    __weak FlutterPcmSoundPlugin *weakSelf = self;
    dispatch_source_set_timer(timer, DISPATCH_TIME_FOREVER, TelemetryPeriodNs, TelemetryLeewayNs);
    dispatch_source_set_event_handler(timer, ^{
        FlutterPcmSoundPlugin *owner = weakSelf;
        if (!owner) return;
        @synchronized(owner) {
            if (!owner.configured || owner.generation != generation) return;
            uint64_t written = atomic_load_explicit(&owner->_ring.written, memory_order_acquire);
            uint64_t read = atomic_load_explicit(&owner->_ring.read, memory_order_acquire);
            uint64_t remaining = written - read;
            BOOL low = remaining <= owner.threshold && owner.lastLowFeed != owner.feeds;
            BOOL zero = remaining == 0 && owner.lastZeroFeed != owner.feeds;
            if (low) owner.lastLowFeed = owner.feeds;
            if (zero) owner.lastZeroFeed = owner.feeds;
            if (owner.running && PcmIdleExpired(&owner->_idle, written, read, IdleStopTicks)) {
                FlutterError *error = [owner checkOSStatus:AudioOutputUnitStop(owner.unit) operation:@"stop"];
                if (!error) owner.running = NO;
                dispatch_source_set_timer(owner.telemetry, DISPATCH_TIME_FOREVER, TelemetryPeriodNs, TelemetryLeewayNs);
            }
            if (owner.legacyCallbacks && (low || zero)) {
                NSDictionary *status = [owner status];
                dispatch_async(dispatch_get_main_queue(), ^{
                    @synchronized(owner) {
                        if (owner.configured && owner.generation == generation)
                            [owner.channel invokeMethod:@"OnFeedSamples" arguments:status];
                    }
                });
            }
        }
    });
    dispatch_resume(timer);
    return nil;
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    @synchronized(self) {
        @try {
            if (!self.attached) { result([self error:@"Detached" message:@"Plugin detached"]); return; }
            NSDictionary *args = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
            NSString *method = call.method;
            if ([method isEqualToString:@"clock"]) {
                result(@((uint64_t)(mach_absolute_time() * _hostTicksToNs)));
            } else if ([method isEqualToString:@"claim"]) {
                result(@(PcmClaimsTake(&_claims)));
            } else if ([method isEqualToString:@"setup"] || [method isEqualToString:@"setupOutput"]) {
                BOOL legacy = [method isEqualToString:@"setup"];
                FlutterError *error = [self setup:args legacy:legacy];
                result(error ?: (legacy ? (id)@0 : [self status]));
            } else if ([method isEqualToString:@"release"]) {
                // Releasing an older generation is a harmless no-op, as on Android.
                if (args[@"generation"] && [args[@"generation"] unsignedLongLongValue] != self.generation) {
                    result(@NO); return;
                }
                [self cleanup]; result(@YES);
            } else if ([method isEqualToString:@"setFeedThreshold"]) {
                self.threshold = MAX(0, [args[@"feed_threshold"] integerValue]); result(@YES);
            } else if ([method isEqualToString:@"status"] || [method isEqualToString:@"feed"]) {
                if (!self.configured) { result([self error:@"Setup" message:@"Must call setup first"]); return; }
                if (args[@"generation"] && [args[@"generation"] unsignedLongLongValue] != self.generation) {
                    result([self error:@"Generation" message:@"Stale output generation"]); return;
                }
                if ([method isEqualToString:@"status"]) { result([self status]); return; }
                FlutterStandardTypedData *buffer = args[@"buffer"];
                if (![buffer isKindOfClass:FlutterStandardTypedData.class] || buffer.data.length % _ring.frameBytes) {
                    result([self error:@"Arguments" message:@"PCM data is not frame aligned"]); return;
                }
                if (self.failure) { result([self error:@"AudioUnitError" message:self.failure]); return; }
                size_t frames = buffer.data.length / _ring.frameBytes;
                if (!PcmRingWrite(&_ring, buffer.data.bytes, frames)) {
                    result([self error:@"Capacity" message:@"PCM capacity exceeded"]); return;
                }
                self.feeds++;
                // A running unit plays on while inactive; only a start waits, since one just after unlock
                // fails (561015905).
                [self startIfQueued];
                result([args[@"status"] boolValue] ? [self status] : (id)@YES);
            } else result(FlutterMethodNotImplemented);
        } @catch (NSException *error) {
            [self cleanup];
            result([self error:@"AudioUnitError" message:error.reason]);
        }
    }
}

- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    @synchronized(self) { self.attached = NO; [self cleanup]; }
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
- (void)dealloc {
    [self cleanup];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
@end

static OSStatus RenderCallback(void *context, AudioUnitRenderActionFlags *flags,
    const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *data) {
    __unsafe_unretained FlutterPcmSoundPlugin *owner = (__bridge FlutterPcmSoundPlugin *)context;
    PcmRing *ring = &owner->_ring;
    size_t requested = data->mBuffers[0].mDataByteSize / ring->frameBytes;
    uint64_t firstFrame = atomic_load_explicit(&ring->read, memory_order_relaxed);
    size_t read = PcmRingRead(ring, data->mBuffers[0].mData, requested);
    BOOL valid = read > 0 && time && (time->mFlags & kAudioTimeStampHostTimeValid);
    PcmTimingPublish(&owner->_timing, firstFrame,
        valid ? (uint64_t)(time->mHostTime * owner->_hostTicksToNs) : 0, valid);
    if (PcmUnderrunEdge(&owner->_starved, read, requested)) atomic_fetch_add_explicit(&owner->_underruns, 1, memory_order_relaxed);
    return noErr;
}
