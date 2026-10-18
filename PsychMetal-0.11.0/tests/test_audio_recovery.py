"""Run the native iOS notification/recovery/close code with a fake audio unit.

Foundation notifications and the serial dispatch queue are real; only the iOS
audio session and audio-unit calls are replaced. No microphone/device required.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

if sys.platform != 'darwin':
    print('Audio recovery notification fixture SKIPPED: requires Foundation.')
    raise SystemExit(0)
root = Path(__file__).resolve().parents[1]
source = (root / 'PsychMetalAudioEngine.h').read_text()
a = source.index('struct AudioRecovery {')
state = source[a:source.index('\n};', a) + 3]
a = source.index('    auto recovery = a.recovery;', source.index('void openIOS('))
observer = source[a:source.index('    // A device arriving', a)]
a = source.index('void closePlatform(Audio &a) {', source.index('void openIOS('))
close = source[a:source.index('\n}\n', a) + 3]
fixture = r'''
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include "PsychMetalAudio.h"
#include <cassert>
#include <memory>
using AudioComponentInstance = void *;
constexpr NSUInteger AVAudioSessionInterruptionTypeBegan = 1;
constexpr NSUInteger AVAudioSessionInterruptionTypeEnded = 0;
constexpr NSUInteger AVAudioSessionInterruptionOptionShouldResume = 1;
constexpr NSUInteger AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation = 1;
NSString *const AVAudioSessionInterruptionNotification = @"interrupt";
NSString *const AVAudioSessionInterruptionTypeKey = @"kind";
NSString *const AVAudioSessionInterruptionOptionKey = @"options";
bool activationWorks = true, unitWorks = true;
int starts = 0, stops = 0, disposals = 0;
double CACurrentMediaTime() { return 100; }
int AudioOutputUnitStop(void *) { ++stops; return 0; }
int AudioOutputUnitStart(void *) { ++starts; return unitWorks ? 0 : -1; }
void disposeUnit(void *&unit) { unit = nullptr; ++disposals; }
#define AVAudioSession PMTestAudioSession
@interface AVAudioSession : NSObject
+ (instancetype)sharedInstance;
- (BOOL)setActive:(BOOL)active error:(NSError **)error;
- (BOOL)setActive:(BOOL)active withOptions:(NSUInteger)options error:(NSError **)error;
@end
@implementation AVAudioSession
+ (instancetype)sharedInstance { static AVAudioSession *s = [AVAudioSession new]; return s; }
- (BOOL)setActive:(BOOL)active error:(NSError **)error { return !active || activationWorks; }
- (BOOL)setActive:(BOOL)active withOptions:(NSUInteger)options error:(NSError **)error { return !active || activationWorks; }
@end
'''
fixture += state + r'''
struct Session { pm::audio::Mixer mixer; pm::audio::Recorder recorder; };
struct Audio {
    void *output = (void *)1, *input = (void *)1;
    std::unique_ptr<Session> session = std::make_unique<Session>();
    std::shared_ptr<std::atomic<bool>> lost = std::make_shared<std::atomic<bool>>(false);
    std::shared_ptr<AudioRecovery> recovery = std::make_shared<AudioRecovery>();
    id interruptionObserver = nil, routeObserver = nil;
};
void observe(Audio &a) {
    auto lost = a.lost;
    auto nc = NSNotificationCenter.defaultCenter;
    auto s = [AVAudioSession sharedInstance];
''' + observer + '\n}\n' + close + r'''
void post(Audio &a, NSUInteger kind, NSUInteger options) {
    [NSNotificationCenter.defaultCenter postNotificationName:AVAudioSessionInterruptionNotification
        object:[AVAudioSession sharedInstance]
        userInfo:@{AVAudioSessionInterruptionTypeKey:@(kind), AVAudioSessionInterruptionOptionKey:@(options)}];
    dispatch_sync(a.recovery->queue, ^{});
}
int main() { @autoreleasepool {
    Audio a; observe(a);
    post(a, 1, 0);
    assert(a.recovery->paused.load() && a.lost->load() && stops == 1);
    assert(a.session->mixer.interruptionGeneration.load() == 1);
    post(a, 0, 0); // iOS did not authorize automatic resume.
    assert(starts == 0 && a.recovery->paused.load());
    post(a, 0, 1);
    assert(starts == 1 && !a.recovery->paused.load());
    post(a, 1, 0); activationWorks = false;
    post(a, 0, 1);
    assert(starts == 1 && a.recovery->paused.load());
    activationWorks = true; unitWorks = false;
    post(a, 0, 1);
    assert(starts == 2 && a.recovery->paused.load());
    unitWorks = true;
    auto retained = a.recovery;
    closePlatform(a);
    assert(retained->closed && !retained->mixer && !retained->output);
    assert(disposals == 1 && !a.output && !a.input);
    post(a, 0, 1); // removed observer cannot restart a disposed audio unit.
    assert(starts == 2);
    a.session.reset();
    dispatch_sync(retained->queue, ^{ assert(retained->closed); });
} }
'''
with tempfile.TemporaryDirectory(prefix='psychmetal-audio-recovery-') as temp:
    p = Path(temp)
    (p / 'test.mm').write_text(fixture)
    subprocess.run(['clang++', '-std=c++17', '-fobjc-arc', '-fblocks', '-pthread',
                    '-fsanitize=address,undefined', '-iquote', str(root),
                    '-framework', 'Foundation', str(p / 'test.mm'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True, timeout=20)
print('PASS: native iOS audio begin/end, resume permission, failed restart and close lifetime with real notifications/dispatch.')
