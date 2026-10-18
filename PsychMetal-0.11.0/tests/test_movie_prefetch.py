"""Exercise the actual native movie prefetch path with real serial dispatch.

Only decoding is fake: verifies bounded work, repeat/seek identity, error timing,
and ownership while a decode completes after the movie handle is closed.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

if sys.platform != 'darwin':
    print('Movie prefetch fixture SKIPPED: requires Foundation.')
    raise SystemExit(0)
root = Path(__file__).resolve().parents[1]
source = (root/'PsychMetalMovie.h').read_text()
a = source.index('static PMTextureRef frameOf(')
helper = source[a:source.index('\nuint64_t pm::openMovie', a)]
code = r'''
#import <Foundation/Foundation.h>
#include <atomic>
#include <cassert>
#include <exception>
#include <memory>
#include <map>
#include <stdexcept>
#include <vector>
using PMTextureRef = std::shared_ptr<int>;
static std::atomic<int> calls{0};
static bool preparing=false;
struct PMMovie {
    dispatch_queue_t queue = dispatch_queue_create("test movie", DISPATCH_QUEUE_SERIAL);
    std::vector<int> times = std::vector<int>(100);
    struct {double width=100,height=50;} info;
    size_t cacheCapacity=8;bool preloaded=false;
    std::map<int64_t,PMTextureRef> decodedCache;
    PMTextureRef frame, requestedFrame;
    int64_t decoded=-1, requested=-1, failedPrefetch=-1;
    std::exception_ptr prefetchFailure;
    int bad=-1, pause=-1;
    dispatch_semaphore_t entered=dispatch_semaphore_create(0), resume=dispatch_semaphore_create(0);
};
static PMTextureRef decodeFrame(PMMovie &m, int64_t index) {
    if(preparing)assert(m.decodedCache.empty());
    if (m.decoded==index && m.frame) return m.frame;
    ++calls;
    if (index==m.pause) {
        dispatch_semaphore_signal(m.entered);
        dispatch_semaphore_wait(m.resume, DISPATCH_TIME_FOREVER);
    }
    if (index==m.bad) throw std::runtime_error("bad movie frame");
    m.decoded=index; m.frame=std::make_shared<int>((int)index);
    return m.frame;
}
static std::atomic<int> prefetchJobs{0};
static void countedAsync(dispatch_queue_t queue, dispatch_block_t job) {
    ++prefetchJobs;
    dispatch_async(queue,job);
}
#define dispatch_async countedAsync
''' + helper + r'''
#undef dispatch_async
namespace pm {uint64_t prepareMovie(uint64_t,uint32_t,uint64_t);}
static std::shared_ptr<PMMovie> testMovie;
static std::shared_ptr<PMMovie> movieFor(uint64_t){return testMovie;}
[[noreturn]] static void fail(const char *s){throw std::runtime_error(s);}
''' + source[source.index('uint64_t pm::prepareMovie('):source.index('std::vector<double> pm::movieFrameTimes(')] + r'''
void drain(std::shared_ptr<PMMovie> m) { dispatch_sync(m->queue, ^{}); }
int main() { @autoreleasepool {
    auto m=std::make_shared<PMMovie>();
    auto zero=frameOf(m,0); drain(m);
    assert(*zero==0 && calls==8 && m->decoded==7);
    int jobs=prefetchJobs;
    for(int i=0;i<50;i++) { assert(frameOf(m,0)==zero); drain(m); }
    assert(calls==8 && prefetchJobs==jobs); // repeats neither decode nor enqueue work
    auto one=frameOf(m,1); drain(m);
    assert(*one==1 && calls==9 && m->decoded==8);
    auto seek=frameOf(m,50); drain(m);
    assert(*seek==50 && calls==17 && m->decoded==57);
    auto last=frameOf(m,99); drain(m);
    assert(*last==99 && calls==18); // EOF is not prefetched
    // A failure in tomorrow's frame must not prevent today's frame drawing.
    m->bad=6;
    assert(*frameOf(m,5)==5); drain(m);
    bool failed=false;
    try { frameOf(m,6); } catch(const std::runtime_error &) { failed=true; }
    assert(failed);
    assert(*frameOf(m,20)==20); drain(m); // unrelated seek remains usable
    // Preload checks the complete decoded size BEFORE doing any decoding.
    testMovie=std::make_shared<PMMovie>();
    int before=calls;bool budget=false;
    try {pm::prepareMovie(1,0,100);}catch(const std::runtime_error &){budget=true;}
    assert(budget&&calls==before);
    preparing=true;assert(pm::prepareMovie(1,0,100*100*50*4)==100);preparing=false;
    before=calls;jobs=prefetchJobs;
    for(int i:{99,0,50,1}){assert(*frameOf(testMovie,i)==i);drain(testMovie);}
    assert(calls==before && prefetchJobs==jobs); // preloaded seeks enqueue no worker jobs
    preparing=true;assert(pm::prepareMovie(1,4,100*50*4*4)==4);preparing=false;
    assert(*frameOf(testMovie,80)==80);drain(testMovie);
    assert(testMovie->decodedCache.size()<=4);
    testMovie.reset();
    // Once its handle is closed, an outstanding worker job owns the movie.
    auto delayed=std::make_shared<PMMovie>(); delayed->pause=1;
    auto entered=delayed->entered, resume=delayed->resume;
    assert(*frameOf(delayed,0)==0);
    assert(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0);
    std::weak_ptr<PMMovie> weak=delayed;
    auto queue=delayed->queue;
    delayed.reset(); assert(!weak.expired());
    dispatch_semaphore_signal(resume);
    // Sync via a retained queue, rather than keeping PMMovie alive ourselves.
    dispatch_sync(queue, ^{});
    assert(weak.expired());
} }
'''
with tempfile.TemporaryDirectory() as tmp:
    src=Path(tmp)/'prefetch.mm'; src.write_text(code)
    for sanitizer in ('address,undefined','thread'):
        binary=Path(tmp)/sanitizer.replace(',','-')
        subprocess.run(['clang++','-std=c++17','-fobjc-arc','-O1','-g',
                        '-fsanitize='+sanitizer,src,'-framework','Foundation','-o',binary],check=True)
        subprocess.run([binary],check=True,timeout=20)
print('PASS: native movie prefetch: bounded work, repeats/seeks, future error isolation, delayed close; ASan/UBSan/TSan.')
