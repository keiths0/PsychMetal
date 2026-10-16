#!/usr/bin/env python3
"""Actual iOS export observer/idle cleanup with Foundation and an app-state stub."""
from pathlib import Path
import subprocess,tempfile,sys
if sys.platform!='darwin':
 print('SKIP: export lifecycle fixture requires Foundation.');raise SystemExit(0)
root=Path(__file__).resolve().parents[1]
s=(root/'PsychMetalIOS.h').read_text();a=s.index('static id iosExportObserver=');b=s.index('static void iosRequireFront(void)',a)
body=s[a:b]
source=r'''
#import <Foundation/Foundation.h>
#include <atomic>
#include <cassert>
#include <thread>
#include <stdexcept>
namespace pm {static const char *kErrGeneral="error";}
static NSString *UIApplicationWillResignActiveNotification=@"resign";
enum {UIApplicationStateActive=0,UIApplicationStateBackground=2};
@interface UIApplication:NSObject
@property(class,readonly) UIApplication *sharedApplication;
@property int applicationState;
@property BOOL idleTimerDisabled;
@end
@implementation UIApplication
+(UIApplication *)sharedApplication {static UIApplication *app=[UIApplication new];return app;}
@end
static std::atomic<bool> iosLeftFront{false};
static void onMainSync(void (^block)(void)){block();}
[[noreturn]] static void failOpen(const char*,NSString *s){throw std::runtime_error(s.UTF8String);}
''' +body+r'''
int main(){@autoreleasepool {
 UIApplication *app=UIApplication.sharedApplication;
 for(BOOL previous:{NO,YES}) {
  app.applicationState=UIApplicationStateActive;app.idleTimerDisabled=previous;
  iosOpenExport();assert(iosExportActive&&app.idleTimerDisabled&&!iosLeftFront.load());
  std::thread resign([]{@autoreleasepool{[NSNotificationCenter.defaultCenter postNotificationName:UIApplicationWillResignActiveNotification object:nil];}});
  resign.join();assert(iosLeftFront.load());
  iosCloseExport();assert(!iosExportActive&&app.idleTimerDisabled==previous&&iosExportObserver==nil);
  iosLeftFront.store(false);[NSNotificationCenter.defaultCenter postNotificationName:UIApplicationWillResignActiveNotification object:nil];
  assert(!iosLeftFront.load());iosCloseExport();assert(app.idleTimerDisabled==previous);
 }
 app.applicationState=UIApplicationStateBackground;app.idleTimerDisabled=YES;
 bool rejected=false;try{iosOpenExport();}catch(const std::runtime_error&){rejected=true;}
 assert(rejected&&!iosExportActive);iosCloseExport();assert(app.idleTimerDisabled);
}}
'''
with tempfile.TemporaryDirectory(prefix='pm-export-lifecycle-') as temp:
 p=Path(temp)/'test.mm';p.write_text(source)
 for sanitizer in ('address,undefined','thread'):
  binary=Path(temp)/sanitizer
  subprocess.run(['clang++','-std=c++17','-fobjc-arc','-fblocks','-pthread','-iquote',str(root),'-framework','Foundation','-fsanitize='+sanitizer,str(p),'-o',str(binary)],check=True)
  subprocess.run([str(binary)],check=True)
print('PASS: actual iOS export foreground guard, resign notification, observer removal, idle restoration, idempotent close and background-open refusal.')
