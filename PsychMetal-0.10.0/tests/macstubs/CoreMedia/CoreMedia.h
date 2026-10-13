// Stand-in for the CoreMedia declarations the engine uses: times, sample buffers,
// block buffers and format descriptions, for reading movies.
#pragma once
#include "../macstubs.h"
#include "../AudioToolbox/AudioToolbox.h"
typedef int64_t CMTimeValue;
typedef int32_t CMTimeScale;
typedef uint32_t CMTimeFlags;
typedef int64_t CMTimeEpoch;
struct CMTime { CMTimeValue value; CMTimeScale timescale; CMTimeFlags flags; CMTimeEpoch epoch; };
struct CMTimeRange { CMTime start, duration; };
extern const CMTime kCMTimeZero, kCMTimePositiveInfinity, kCMTimeInvalid;
CMTime CMTimeMake(int64_t value, int32_t timescale);
CMTime CMTimeAdd(CMTime, CMTime);
CMTime CMTimeSubtract(CMTime, CMTime);
CMTime CMTimeMultiplyByFloat64(CMTime, double);
int32_t CMTimeCompare(CMTime, CMTime);
double CMTimeGetSeconds(CMTime);
CMTimeRange CMTimeRangeMake(CMTime start, CMTime duration);
CMTime CMTimeRangeGetEnd(CMTimeRange);
#define CMTIME_IS_VALID(t) ((bool)(((t).flags & 1) != 0))
typedef int32_t CMPersistentTrackID;
enum { kCMPersistentTrackID_Invalid = 0 };
typedef long CMItemCount;
typedef uint32_t FourCharCode;
typedef struct opaqueCMSampleBuffer *CMSampleBufferRef;
typedef struct OpaqueCMBlockBuffer *CMBlockBufferRef;
typedef const struct opaqueCMFormatDescription *CMFormatDescriptionRef;
typedef CMFormatDescriptionRef CMAudioFormatDescriptionRef;
typedef struct __CVBuffer *CVImageBufferRef;
struct CMSampleTimingInfo { CMTime duration, presentationTimeStamp, decodeTimeStamp; };
OSStatus CMSampleBufferGetSampleTimingInfoArray(CMSampleBufferRef, CMItemCount entries, CMSampleTimingInfo *array,
                                                CMItemCount *entriesNeeded);
CMTime CMSampleBufferGetPresentationTimeStamp(CMSampleBufferRef);
CMItemCount CMSampleBufferGetNumSamples(CMSampleBufferRef);
size_t CMSampleBufferGetTotalSampleSize(CMSampleBufferRef);
CVImageBufferRef CMSampleBufferGetImageBuffer(CMSampleBufferRef);
CMBlockBufferRef CMSampleBufferGetDataBuffer(CMSampleBufferRef);
size_t CMBlockBufferGetDataLength(CMBlockBufferRef);
OSStatus CMBlockBufferCopyDataBytes(CMBlockBufferRef, size_t offset, size_t length, void *destination);
enum { kCMBlockBufferNoErr = 0 };
FourCharCode CMFormatDescriptionGetMediaSubType(CMFormatDescriptionRef);
const AudioStreamBasicDescription *CMAudioFormatDescriptionGetStreamBasicDescription(CMAudioFormatDescriptionRef);
