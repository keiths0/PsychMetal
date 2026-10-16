// Stand-in for the Mach thread-policy declarations the engine uses.
#pragma once
#include "../macstubs.h"
#ifdef PM_STUB_IOS
enum { KERN_SUCCESS = 0 };   // the Mac stubs declare it with IOKit
#endif
typedef unsigned int thread_port_t;
typedef unsigned int thread_policy_flavor_t;
typedef int *thread_policy_t;
typedef unsigned int mach_msg_type_number_t;
typedef unsigned int boolean_t;
enum { THREAD_STANDARD_POLICY = 1, THREAD_TIME_CONSTRAINT_POLICY = 2 };
struct thread_time_constraint_policy_data_t { uint32_t period, computation, constraint; boolean_t preemptible; };
struct thread_standard_policy_data_t { unsigned int no_data; };
#define THREAD_TIME_CONSTRAINT_POLICY_COUNT ((mach_msg_type_number_t)4)
#define THREAD_STANDARD_POLICY_COUNT ((mach_msg_type_number_t)0)
extern "C" kern_return_t thread_policy_set(thread_port_t, thread_policy_flavor_t, thread_policy_t, mach_msg_type_number_t);
extern "C" kern_return_t thread_policy_get(thread_port_t, thread_policy_flavor_t, thread_policy_t,
                                           mach_msg_type_number_t *, boolean_t *);
extern "C" thread_port_t pthread_mach_thread_np(pthread_t);
