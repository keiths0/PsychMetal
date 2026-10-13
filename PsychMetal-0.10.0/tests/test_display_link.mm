// Exercise the real native handoff without creating a window or GPU device.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <thread>
#include <cassert>
#include <chrono>
#include <vector>
#include "../PsychMetalDisplayLink.h"

@interface PMDisplayDriver (Test)
- (instancetype)initForTest;
- (BOOL)testRequested;
- (void)finishForTest;
@end
@implementation PMDisplayDriver (Test)
- (instancetype)initForTest {
    if ((self=[super init])) { gate=[NSCondition new]; ready=YES; }
    return self;
}
- (BOOL)testRequested { [gate lock]; BOOL value=requested; [gate unlock]; return value; }
- (void)finishForTest {
    [gate lock]; stopping=YES; finished=YES; [gate broadcast]; [gate unlock];
}
@end
@interface PMTestUpdate : NSObject
@property double targetPresentationTimestamp;
@property(strong) id<CAMetalDrawable> drawable;
@end
@implementation PMTestUpdate
@end
static PMTestUpdate *update(double target) {
    PMTestUpdate *u=[PMTestUpdate new]; u.targetPresentationTimestamp=target;
    u.drawable=(id<CAMetalDrawable>)[NSObject new]; return u;
}
static void awaitRequest(PMDisplayDriver *d) {
    double deadline=CACurrentMediaTime()+1;
    while (![d testRequested] && CACurrentMediaTime()<deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    assert([d testRequested]);
}

static std::vector<int> calls;
@interface PMFakeCommand : NSObject
- (void)commit;
- (void)presentDrawable:(id)drawable;
- (void)presentDrawable:(id)drawable atTime:(double)when;
@end
@implementation PMFakeCommand
- (void)commit { calls.push_back(1); }
- (void)presentDrawable:(id)drawable { (void)drawable; calls.push_back(3); }
- (void)presentDrawable:(id)drawable atTime:(double)when {
    (void)drawable; assert(when==123.); calls.push_back(4);
}
@end
@interface PMFakeDrawable : NSObject
- (void)present;
@end
@implementation PMFakeDrawable
- (void)present { assert(calls==std::vector<int>{1}); calls.push_back(2); }
@end
int main() { @autoreleasepool {
    id<MTLCommandBuffer> cb=(id<MTLCommandBuffer>)[PMFakeCommand new];
    id<CAMetalDrawable> drawable=(id<CAMetalDrawable>)[PMFakeDrawable new];
    commitPresentation(cb,drawable,true,123.);
    assert((calls==std::vector<int>{1,2}));
    calls.clear(); commitPresentation(cb,drawable,false,123.);
    assert((calls==std::vector<int>{4,1}));
    calls.clear(); commitPresentation(cb,drawable,false,NAN);
    assert((calls==std::vector<int>{3,1}));
    puts("PASS: display-link commits then presents directly; only direct backend uses timed command-buffer presentation.");
    PMDisplayDriver *d=[[PMDisplayDriver alloc] initForTest];
    CAMetalDisplayLink *dummy=(CAMetalDisplayLink *)[NSObject new];
    double now=CACurrentMediaTime();
    PMTestUpdate *idle=update(now+10), *early=update(now+.1), *wanted=update(now+1);
    [d metalDisplayLink:dummy needsUpdate:(CAMetalDisplayLinkUpdate *)idle];
    CAMetalDisplayLinkUpdate *received=nil;
    std::thread consumer([&] { @autoreleasepool { received=[d nextUpdate:now+.5]; } });
    awaitRequest(d);
    [d metalDisplayLink:dummy needsUpdate:(CAMetalDisplayLinkUpdate *)early];
    assert([d testRequested]);
    [d metalDisplayLink:dummy needsUpdate:(CAMetalDisplayLinkUpdate *)wanted];
    consumer.join();
    assert((id)received==wanted); // idle callbacks and too-early updates never leak through
    std::thread cancelled([&] { @autoreleasepool { received=[d nextUpdate:0]; } });
    awaitRequest(d);
    [d finishForTest];
    cancelled.join(); assert(received==nil);
    [d stop];
    stopDisplayDriver();
    puts("PASS: native display-link handoff discards idle/early updates, delivers one fresh drawable, and wakes cancellation.");
} }
