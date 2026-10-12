// Stand-in for the Input Monitoring access check, which the SDK declares in
// <IOKit/hidsystem/IOHIDLib.h>, not with IOHIDManager; the Mac only.
#pragma once
#ifdef PM_STUB_IOS
#error "Input Monitoring is the Mac's."
#endif
typedef enum { kIOHIDRequestTypePostEvent, kIOHIDRequestTypeListenEvent } IOHIDRequestType;
typedef enum { kIOHIDAccessTypeGranted, kIOHIDAccessTypeDenied, kIOHIDAccessTypeUnknown } IOHIDAccessType;
extern "C" {
IOHIDAccessType IOHIDCheckAccess(IOHIDRequestType);
bool IOHIDRequestAccess(IOHIDRequestType);
}
