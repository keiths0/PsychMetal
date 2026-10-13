// Stand-in for the CoreAudio hardware (HAL) declarations the engine uses; the Mac only.
#pragma once
#include "../AudioToolbox/AudioToolbox.h"
#ifdef PM_STUB_IOS
#error "CoreAudio's hardware interface is the Mac's; the iPhone uses the audio session."
#endif
typedef UInt32 AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope, AudioObjectPropertyElement;
typedef AudioObjectID AudioStreamID;
struct AudioObjectPropertyAddress { AudioObjectPropertySelector mSelector; AudioObjectPropertyScope mScope;
                                    AudioObjectPropertyElement mElement; };
struct AudioValueRange { Float64 mMinimum, mMaximum; };
enum { kAudioObjectSystemObject = 1, kAudioObjectPropertyElementMain = 0 };
enum { kAudioObjectPropertyScopeGlobal = 0x676c6f62, kAudioObjectPropertyScopeInput = 0x696e7074,
       kAudioObjectPropertyScopeOutput = 0x6f757470 };
enum { kAudioHardwarePropertyDevices = 0x64657623, kAudioHardwarePropertyDefaultOutputDevice = 0x644f7574,
       kAudioHardwarePropertyDefaultInputDevice = 0x64496e20, kAudioObjectPropertyName = 0x6c6e616d,
       kAudioDevicePropertyStreamConfiguration = 0x736c6179, kAudioDevicePropertyNominalSampleRate = 0x6e737274,
       kAudioDevicePropertyTransportType = 0x7472616e, kAudioDevicePropertyBufferFrameSize = 0x6673697a,
       kAudioDevicePropertyBufferFrameSizeRange = 0x66737a23, kAudioDevicePropertyLatency = 0x6c746e63,
       kAudioDevicePropertyStreams = 0x73746d23, kAudioStreamPropertyLatency = 0x6c746e63,
       kAudioDevicePropertyDeviceIsAlive = 0x6c69766e,
       kAudioDevicePropertyAvailableNominalSampleRates = 0x6e737223 };
enum { kAudioDeviceTransportTypeBuiltIn = 0x626c746e, kAudioDeviceTransportTypeUSB = 0x75736220,
       kAudioDeviceTransportTypeBluetooth = 0x626c7565, kAudioDeviceTransportTypeBluetoothLE = 0x626c6561,
       kAudioDeviceTransportTypeAirPlay = 0x61697270, kAudioDeviceTransportTypeHDMI = 0x68646d69,
       kAudioDeviceTransportTypeDisplayPort = 0x64707274, kAudioDeviceTransportTypeThunderbolt = 0x7468756e,
       kAudioDeviceTransportTypeFireWire = 0x31333934, kAudioDeviceTransportTypePCI = 0x70636920,
       kAudioDeviceTransportTypeAggregate = 0x67727570, kAudioDeviceTransportTypeVirtual = 0x76697274 };
typedef OSStatus (*AudioObjectPropertyListenerProc)(AudioObjectID, UInt32, const AudioObjectPropertyAddress *, void *);
typedef void (^AudioObjectPropertyListenerBlock)(UInt32, const AudioObjectPropertyAddress *);
extern "C" {
OSStatus AudioObjectGetPropertyDataSize(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *);
OSStatus AudioObjectGetPropertyData(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *, void *);
OSStatus AudioObjectSetPropertyData(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, const void *);
OSStatus AudioObjectAddPropertyListener(AudioObjectID, const AudioObjectPropertyAddress *, AudioObjectPropertyListenerProc, void *);
OSStatus AudioObjectRemovePropertyListener(AudioObjectID, const AudioObjectPropertyAddress *, AudioObjectPropertyListenerProc, void *);
OSStatus AudioObjectAddPropertyListenerBlock(AudioObjectID, const AudioObjectPropertyAddress *, dispatch_queue_t, AudioObjectPropertyListenerBlock);
OSStatus AudioObjectRemovePropertyListenerBlock(AudioObjectID, const AudioObjectPropertyAddress *, dispatch_queue_t, AudioObjectPropertyListenerBlock);
CFIndex CFStringGetLength(CFStringRef);
bool CFStringGetCString(CFStringRef, char *, CFIndex, CFStringEncoding);
}
