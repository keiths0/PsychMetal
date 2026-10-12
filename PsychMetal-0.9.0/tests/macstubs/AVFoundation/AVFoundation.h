// Stand-in for the AVFoundation declarations the engine uses: microphone
// permission on the Mac; the audio session and its permission on the iPhone.
#pragma once
#include "../macstubs.h"
@interface NSArray<ObjectType> (First)
@property (readonly) ObjectType firstObject;
@end
@interface NSString (Comparison)
- (BOOL)isEqualToString:(NSString *)other;
@end
#ifndef PM_STUB_IOS
typedef NSString *AVMediaType;
extern AVMediaType const AVMediaTypeAudio;
typedef NSInteger AVAuthorizationStatus;
enum { AVAuthorizationStatusNotDetermined = 0, AVAuthorizationStatusRestricted = 1, AVAuthorizationStatusDenied = 2,
       AVAuthorizationStatusAuthorized = 3 };
@interface AVCaptureDevice : NSObject
+ (AVAuthorizationStatus)authorizationStatusForMediaType:(AVMediaType)mediaType;
+ (void)requestAccessForMediaType:(AVMediaType)mediaType completionHandler:(void (^)(BOOL granted))handler;
@end
#else
typedef NSString *AVAudioSessionCategory, *AVAudioSessionMode, *AVAudioSessionPort;
extern AVAudioSessionCategory const AVAudioSessionCategoryPlayback, AVAudioSessionCategoryPlayAndRecord;
extern AVAudioSessionMode const AVAudioSessionModeDefault, AVAudioSessionModeMeasurement;
extern AVAudioSessionPort const AVAudioSessionPortBluetoothA2DP, AVAudioSessionPortBluetoothLE,
    AVAudioSessionPortBluetoothHFP, AVAudioSessionPortAirPlay, AVAudioSessionPortBuiltInReceiver;
typedef NSUInteger AVAudioSessionPortOverride;
enum { AVAudioSessionPortOverrideNone = 0, AVAudioSessionPortOverrideSpeaker = 0x73706b72 };
extern NSString *const AVAudioSessionInterruptionNotification, *const AVAudioSessionRouteChangeNotification;
extern NSString *const AVAudioSessionInterruptionTypeKey, *const AVAudioSessionRouteChangeReasonKey;
typedef NSUInteger AVAudioSessionInterruptionType;
enum { AVAudioSessionInterruptionTypeBegan = 1, AVAudioSessionInterruptionTypeEnded = 0 };
typedef NSUInteger AVAudioSessionRouteChangeReason;
enum { AVAudioSessionRouteChangeReasonUnknown = 0, AVAudioSessionRouteChangeReasonNewDeviceAvailable = 1,
       AVAudioSessionRouteChangeReasonOldDeviceUnavailable = 2, AVAudioSessionRouteChangeReasonCategoryChange = 3,
       AVAudioSessionRouteChangeReasonOverride = 4, AVAudioSessionRouteChangeReasonWakeFromSleep = 6,
       AVAudioSessionRouteChangeReasonNoSuitableRouteForCategory = 7,
       AVAudioSessionRouteChangeReasonRouteConfigurationChange = 8 };
typedef NSUInteger AVAudioSessionCategoryOptions;
enum { AVAudioSessionCategoryOptionDefaultToSpeaker = 0x8 };
typedef NSUInteger AVAudioSessionSetActiveOptions;
enum { AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation = 1 };
typedef NSUInteger AVAudioSessionRecordPermission;
enum { AVAudioSessionRecordPermissionUndetermined = 0x756e6474, AVAudioSessionRecordPermissionDenied = 0x64656e79,
       AVAudioSessionRecordPermissionGranted = 0x67726e74 };
@interface AVAudioSessionPortDescription : NSObject
@property (readonly) AVAudioSessionPort portType;
@property (readonly) NSString *portName;
@end
@interface AVAudioSessionRouteDescription : NSObject
@property (readonly) NSArray<AVAudioSessionPortDescription *> *inputs, *outputs;
@end
@interface AVAudioSession : NSObject
+ (AVAudioSession *)sharedInstance;
- (BOOL)setCategory:(AVAudioSessionCategory)category mode:(AVAudioSessionMode)mode
            options:(AVAudioSessionCategoryOptions)options error:(NSError **)error;
- (BOOL)setPreferredSampleRate:(double)rate error:(NSError **)error;
- (BOOL)setPreferredIOBufferDuration:(NSTimeInterval)duration error:(NSError **)error;
- (BOOL)setActive:(BOOL)active error:(NSError **)error;
- (BOOL)setActive:(BOOL)active withOptions:(AVAudioSessionSetActiveOptions)options error:(NSError **)error;
- (void)requestRecordPermission:(void (^)(BOOL granted))response;
- (BOOL)overrideOutputAudioPort:(AVAudioSessionPortOverride)portOverride error:(NSError **)error;
@property (readonly) double sampleRate;
@property (readonly) NSTimeInterval IOBufferDuration, outputLatency, inputLatency;
@property (readonly) NSInteger outputNumberOfChannels, inputNumberOfChannels, maximumOutputNumberOfChannels;
@property (readonly) AVAudioSessionRouteDescription *currentRoute;
@property (readonly) AVAudioSessionRecordPermission recordPermission;
@end
typedef NSInteger AVAudioApplicationRecordPermission;
enum { AVAudioApplicationRecordPermissionUndetermined = 0x756e6474, AVAudioApplicationRecordPermissionDenied = 0x64656e79,
       AVAudioApplicationRecordPermissionGranted = 0x67726e74 };
@interface AVAudioApplication : NSObject
+ (AVAudioApplication *)sharedInstance;
@property (readonly) AVAudioApplicationRecordPermission recordPermission;
+ (void)requestRecordPermissionWithCompletionHandler:(void (^)(BOOL granted))response;
@end
#endif
