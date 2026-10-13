// Stand-in for the AVFoundation declarations the engine uses: microphone
// permission on the Mac; the audio session and its permission on the iPhone;
// reading movies on both.
#pragma once
#include "../macstubs.h"
#include "../CoreMedia/CoreMedia.h"
#ifndef CF_RETURNS_RETAINED
#define CF_RETURNS_RETAINED __attribute__((cf_returns_retained))
#endif
@interface NSArray<ObjectType> (First)
@property (readonly) ObjectType firstObject;
@end
@interface NSString (Comparison)
- (BOOL)isEqualToString:(NSString *)other;
@end
typedef NSString *AVMediaType;
extern AVMediaType const AVMediaTypeAudio, AVMediaTypeVideo;

// ---- reading movies ------------------------------------------------------------
@interface NSURL : NSObject
+ (NSURL *)fileURLWithPath:(NSString *)path;
@end
@interface NSFileManager : NSObject
@property (class, readonly, strong) NSFileManager *defaultManager;
- (BOOL)fileExistsAtPath:(NSString *)path;
@end
@interface NSString (Paths)
@property (readonly, copy) NSString *stringByExpandingTildeInPath;
@end
@interface NSNumber (Literals)
+ (NSNumber *)numberWithInt:(int)value;
+ (NSNumber *)numberWithUnsignedInt:(unsigned int)value;
+ (NSNumber *)numberWithDouble:(double)value;
+ (NSNumber *)numberWithBool:(BOOL)value;
@end
@interface NSDictionary<K, V> (Literals)
+ (instancetype)dictionaryWithObjects:(const V[])objects forKeys:(const K[])keys count:(NSUInteger)count;
@end
@interface NSArray<ObjectType> (Literals)
+ (instancetype)arrayWithObjects:(const ObjectType[])objects count:(NSUInteger)count;
@end
@protocol NSCopying @end
typedef NSInteger AVKeyValueStatus;
enum { AVKeyValueStatusUnknown = 0, AVKeyValueStatusLoading = 1, AVKeyValueStatusLoaded = 2,
       AVKeyValueStatusFailed = 3, AVKeyValueStatusCancelled = 4 };
@protocol AVAsynchronousKeyValueLoading
- (AVKeyValueStatus)statusOfValueForKey:(NSString *)key error:(NSError **)outError;
- (void)loadValuesAsynchronouslyForKeys:(NSArray<NSString *> *)keys completionHandler:(void (^)(void))handler;
@end
struct CGAffineTransform { CGFloat a, b, c, d, tx, ty; };
@interface AVAssetTrack : NSObject <AVAsynchronousKeyValueLoading>
@property (readonly) CGSize naturalSize;
@property (readonly) struct CGAffineTransform preferredTransform;
@property (readonly) NSArray *formatDescriptions;
@property (readonly) CMTimeRange timeRange;
@end
@interface AVAsset : NSObject <AVAsynchronousKeyValueLoading>
- (void)loadTracksWithMediaType:(AVMediaType)mediaType
              completionHandler:(void (^)(NSArray<AVAssetTrack *> *tracks, NSError *error))handler;
@end
extern NSString *const AVURLAssetPreferPreciseDurationAndTimingKey;
@interface AVURLAsset : AVAsset
+ (instancetype)URLAssetWithURL:(NSURL *)URL options:(NSDictionary<NSString *, id> *)options;
@end
@interface AVCompositionTrack : AVAssetTrack @end
@interface AVMutableCompositionTrack : AVCompositionTrack
- (BOOL)insertTimeRange:(CMTimeRange)timeRange ofTrack:(AVAssetTrack *)track atTime:(CMTime)startTime error:(NSError **)outError;
@end
@interface AVComposition : AVAsset @end
@interface AVMutableComposition : AVComposition
+ (instancetype)composition;
- (AVMutableCompositionTrack *)addMutableTrackWithMediaType:(AVMediaType)mediaType preferredTrackID:(CMPersistentTrackID)preferredTrackID;
- (void)scaleTimeRange:(CMTimeRange)timeRange toDuration:(CMTime)duration;
@end
typedef NSString *AVAudioTimePitchAlgorithm;
extern AVAudioTimePitchAlgorithm const AVAudioTimePitchAlgorithmSpectral;
@interface AVAssetReaderOutput : NSObject
@property BOOL alwaysCopiesSampleData;
- (CMSampleBufferRef)copyNextSampleBuffer CF_RETURNS_RETAINED;
@end
@interface AVAssetReaderTrackOutput : AVAssetReaderOutput
+ (instancetype)assetReaderTrackOutputWithTrack:(AVAssetTrack *)track outputSettings:(NSDictionary<NSString *, id> *)outputSettings;
@end
@interface AVAssetReaderAudioMixOutput : AVAssetReaderOutput
+ (instancetype)assetReaderAudioMixOutputWithAudioTracks:(NSArray<AVAssetTrack *> *)audioTracks
                                   audioSettings:(NSDictionary<NSString *, id> *)audioSettings;
@property (copy) AVAudioTimePitchAlgorithm audioTimePitchAlgorithm;
@end
typedef NSInteger AVAssetReaderStatus;
enum { AVAssetReaderStatusUnknown = 0, AVAssetReaderStatusReading = 1, AVAssetReaderStatusCompleted = 2,
       AVAssetReaderStatusFailed = 3, AVAssetReaderStatusCancelled = 4 };
@interface AVAssetReader : NSObject
- (instancetype)initWithAsset:(AVAsset *)asset error:(NSError **)outError;
- (void)addOutput:(AVAssetReaderOutput *)output;
- (BOOL)startReading;
- (void)cancelReading;
@property CMTimeRange timeRange;
@property (readonly) AVAssetReaderStatus status;
@property (readonly) NSError *error;
@end
extern NSString *const AVFormatIDKey, *const AVSampleRateKey, *const AVNumberOfChannelsKey, *const AVLinearPCMBitDepthKey,
    *const AVLinearPCMIsFloatKey, *const AVLinearPCMIsNonInterleaved, *const AVLinearPCMIsBigEndianKey;

#ifndef PM_STUB_IOS
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
