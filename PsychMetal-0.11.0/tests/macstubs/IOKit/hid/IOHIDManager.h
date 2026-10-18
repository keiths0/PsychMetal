// Stand-in for the IOHIDManager declarations the engine uses; the Mac only.
#pragma once
#include "../IOKitLib.h"
#ifdef PM_STUB_IOS
#error "IOHIDManager is the Mac's; the iPhone's keys come through UIKit."
#endif
typedef int IOReturn;
enum { kIOReturnSuccess = 0, kIOReturnError = (int)0xe00002bc };
enum { kIOHIDOptionsTypeNone = 0 };
typedef struct __IOHIDManager *IOHIDManagerRef;
typedef struct __IOHIDValue *IOHIDValueRef;
typedef struct __IOHIDElement *IOHIDElementRef;
typedef void (*IOHIDValueCallback)(void *context, IOReturn result, void *sender, IOHIDValueRef value);
enum { kHIDPage_GenericDesktop = 0x01, kHIDPage_KeyboardOrKeypad = 0x07 };
enum { kHIDUsage_GD_Keyboard = 0x06, kHIDUsage_GD_Keypad = 0x07 };
#define kIOHIDDeviceUsagePageKey "DeviceUsagePage"
#define kIOHIDDeviceUsageKey "DeviceUsage"
extern "C" {
IOHIDManagerRef IOHIDManagerCreate(CFAllocatorRef, IOOptionBits);
void IOHIDManagerSetDeviceMatchingMultiple(IOHIDManagerRef, CFArrayRef);
void IOHIDManagerRegisterInputValueCallback(IOHIDManagerRef, IOHIDValueCallback, void *context);
void IOHIDManagerScheduleWithRunLoop(IOHIDManagerRef, CFRunLoopRef, CFStringRef mode);
void IOHIDManagerUnscheduleFromRunLoop(IOHIDManagerRef, CFRunLoopRef, CFStringRef mode);
IOReturn IOHIDManagerOpen(IOHIDManagerRef, IOOptionBits);
IOReturn IOHIDManagerClose(IOHIDManagerRef, IOOptionBits);
IOHIDElementRef IOHIDValueGetElement(IOHIDValueRef);
uint64_t IOHIDValueGetTimeStamp(IOHIDValueRef);
CFIndex IOHIDValueGetIntegerValue(IOHIDValueRef);
uint32_t IOHIDElementGetUsagePage(IOHIDElementRef);
uint32_t IOHIDElementGetUsage(IOHIDElementRef);
}
