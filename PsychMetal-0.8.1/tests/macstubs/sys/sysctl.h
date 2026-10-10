// Stand-in for the Darwin <sys/sysctl.h> declarations the engine uses.
#pragma once
#include <stddef.h>
#define CTL_KERN 1
#define KERN_PROC 14
#define KERN_PROC_PID 1
#define P_TRACED 0x00000800
struct extern_proc { int p_flag; };
struct kinfo_proc { struct extern_proc kp_proc; };
extern "C" int sysctl(int *name, unsigned int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen);
