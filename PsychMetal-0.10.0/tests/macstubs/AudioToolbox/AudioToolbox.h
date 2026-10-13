// Stand-in for the AudioToolbox and CoreAudioTypes declarations the engine uses.
#pragma once
#include "../macstubs.h"
typedef int32_t OSStatus;
typedef uint32_t UInt32;
typedef double Float64;
typedef uint32_t OSType;
enum { noErr = 0, kAudio_ParamError = -50 };
struct SMPTETime { int16_t unused; };
struct AudioTimeStamp { Float64 mSampleTime; uint64_t mHostTime; Float64 mRateScalar; uint64_t mWordClockTime;
                        SMPTETime mSMPTETime; UInt32 mFlags; UInt32 mReserved; };
enum { kAudioTimeStampSampleTimeValid = 1, kAudioTimeStampHostTimeValid = 2, kAudioTimeStampRateScalarValid = 4 };
struct AudioBuffer { UInt32 mNumberChannels; UInt32 mDataByteSize; void *mData; };
struct AudioBufferList { UInt32 mNumberBuffers; AudioBuffer mBuffers[1]; };
struct AudioStreamBasicDescription { Float64 mSampleRate; UInt32 mFormatID, mFormatFlags, mBytesPerPacket, mFramesPerPacket,
                                     mBytesPerFrame, mChannelsPerFrame, mBitsPerChannel, mReserved; };
struct AudioStreamPacketDescription { int64_t mStartOffset; UInt32 mVariableFramesInPacket, mDataByteSize; };
enum { kAudioFormatLinearPCM = 0x6c70636d, kAudioFormatFlagsNativeFloatPacked = 9, kAudioFormatFlagIsNonInterleaved = 32 };
struct AudioComponentDescription { OSType componentType, componentSubType, componentManufacturer; UInt32 componentFlags, componentFlagsMask; };
typedef struct OpaqueAudioComponent *AudioComponent;
typedef struct ComponentInstanceRecord *AudioComponentInstance;
typedef AudioComponentInstance AudioUnit;
typedef UInt32 AudioUnitRenderActionFlags, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement;
enum { kAudioUnitType_Output = 0x61756f75, kAudioUnitSubType_HALOutput = 0x6168616c, kAudioUnitSubType_RemoteIO = 0x72696f63,
       kAudioUnitManufacturer_Apple = 0x6170706c };
enum { kAudioUnitScope_Global = 0, kAudioUnitScope_Input = 1, kAudioUnitScope_Output = 2 };
enum { kAudioOutputUnitProperty_CurrentDevice = 2000, kAudioOutputUnitProperty_EnableIO = 2003,
       kAudioOutputUnitProperty_SetInputCallback = 2005, kAudioUnitProperty_StreamFormat = 8,
       kAudioUnitProperty_SetRenderCallback = 23, kAudioUnitProperty_MaximumFramesPerSlice = 14 };
typedef OSStatus (*AURenderCallback)(void *, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
struct AURenderCallbackStruct { AURenderCallback inputProc; void *inputProcRefCon; };
extern "C" {
AudioComponent AudioComponentFindNext(AudioComponent, const AudioComponentDescription *);
OSStatus AudioComponentInstanceNew(AudioComponent, AudioComponentInstance *);
OSStatus AudioComponentInstanceDispose(AudioComponentInstance);
OSStatus AudioUnitSetProperty(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
OSStatus AudioUnitInitialize(AudioUnit);
OSStatus AudioUnitUninitialize(AudioUnit);
OSStatus AudioOutputUnitStart(AudioUnit);
OSStatus AudioOutputUnitStop(AudioUnit);
OSStatus AudioUnitRender(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
}
typedef struct OpaqueAudioConverter *AudioConverterRef;
typedef UInt32 AudioConverterPropertyID;
enum { kAudioConverterSampleRateConverterQuality = 0x73726371, kAudioConverterQuality_Max = 0x7F };
typedef OSStatus (*AudioConverterComplexInputDataProc)(AudioConverterRef, UInt32 *, AudioBufferList *,
                                                       AudioStreamPacketDescription **, void *);
extern "C" {
OSStatus AudioConverterNew(const AudioStreamBasicDescription *, const AudioStreamBasicDescription *, AudioConverterRef *);
OSStatus AudioConverterDispose(AudioConverterRef);
OSStatus AudioConverterSetProperty(AudioConverterRef, AudioConverterPropertyID, UInt32, const void *);
OSStatus AudioConverterFillComplexBuffer(AudioConverterRef, AudioConverterComplexInputDataProc, void *, UInt32 *,
                                         AudioBufferList *, AudioStreamPacketDescription *);
}
