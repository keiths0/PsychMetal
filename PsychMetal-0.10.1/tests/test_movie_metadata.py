"""Actual AVFoundation metadata-wait helpers with delayed Foundation callbacks.

Shorten only the timeout; verify success and timeout with safe late completion.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
if sys.platform!='darwin':
 print('Movie metadata fixture SKIPPED: requires Foundation.');raise SystemExit(0)
root=Path(__file__).resolve().parents[1];source=(root/'PsychMetalMovie.h').read_text()
a=source.index('static bool loadKeys(');helpers=source[a:source.index('// Decode frame',a)]
helpers=helpers.replace('30 * NSEC_PER_SEC','20 * NSEC_PER_MSEC')
code=r'''
#import <Foundation/Foundation.h>
#include <cassert>
#include <stdexcept>
#include <unistd.h>
using AVMediaType=NSString *;
constexpr NSInteger AVKeyValueStatusLoaded=2;
@protocol AVAsynchronousKeyValueLoading
- (void)loadValuesAsynchronouslyForKeys:(NSArray<NSString *> *)keys completionHandler:(void (^)(void))handler;
- (NSInteger)statusOfValueForKey:(NSString *)key error:(NSError **)error;
@end
@interface PMMetadataTrack:NSObject @end
@implementation PMMetadataTrack @end
@interface PMMetadataAsset:NSObject<AVAsynchronousKeyValueLoading>
@property double delay;
- (void)loadTracksWithMediaType:(AVMediaType)type completionHandler:(void (^)(NSArray<PMMetadataTrack *> *, NSError *))handler;
@end
@implementation PMMetadataAsset
- (void)loadValuesAsynchronouslyForKeys:(NSArray<NSString *> *)keys completionHandler:(void (^)(void))handler {
 (void)keys;
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(self.delay*NSEC_PER_SEC)),dispatch_get_global_queue(0,0),handler);
}
- (NSInteger)statusOfValueForKey:(NSString *)key error:(NSError **)error { (void)key; (void)error; return AVKeyValueStatusLoaded; }
- (void)loadTracksWithMediaType:(AVMediaType)type completionHandler:(void (^)(NSArray<PMMetadataTrack *> *, NSError *))handler {
 (void)type;
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(self.delay*NSEC_PER_SEC)),dispatch_get_global_queue(0,0),^{ handler(@[[PMMetadataTrack new]],nil); });
}
@end
#define AVAsset PMMetadataAsset
#define AVAssetTrack PMMetadataTrack
[[noreturn]] void fail(const char *s) { throw std::runtime_error(s); }
'''+helpers+r'''
int main() { @autoreleasepool {
 PMMetadataAsset *asset=[PMMetadataAsset new];
 assert(loadKeys(asset,@[@"duration"])); assert(tracksOf(asset,@"video").count==1);
 asset.delay=.1;
 bool failed=false;
 try { loadKeys(asset,@[@"duration"]); } catch(const std::runtime_error &) { failed=true; }
 assert(failed); failed=false;
 try { tracksOf(asset,@"video"); } catch(const std::runtime_error &) { failed=true; }
 assert(failed);
 // Both helpers have returned: completion blocks must still own their captured storage.
 asset=nil; usleep(200000);
} }
'''
with tempfile.TemporaryDirectory() as temp:
 src=Path(temp)/'metadata.mm';src.write_text(code);binary=Path(temp)/'metadata'
 subprocess.run(['clang++','-std=c++17','-fobjc-arc','-O1','-g','-fsanitize=address,undefined',src,'-framework','Foundation','-o',binary],check=True)
 subprocess.run([binary],check=True,timeout=10)
print('PASS: native movie metadata success/timeouts and safe completion after timeout, ASan/UBSan.')
