// TEST INFRASTRUCTURE ONLY: which Apple system the type check pretends to build
// for. -DPM_STUB_IOS selects the iPhone; the default is the Mac.
#ifdef PM_STUB_IOS
#define TARGET_OS_IPHONE 1
#define TARGET_OS_OSX 0
#else
#define TARGET_OS_IPHONE 0
#define TARGET_OS_OSX 1
#endif
#ifdef PM_STUB_SIMULATOR
#define TARGET_OS_SIMULATOR 1
#else
#define TARGET_OS_SIMULATOR 0
#endif
