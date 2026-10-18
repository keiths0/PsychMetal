"""Run the native completed-export commit with real files, without an encoder."""
from pathlib import Path
import subprocess
import sys
import tempfile

if sys.platform != 'darwin':
    print('Recording-file fixture SKIPPED: requires Foundation.')
    raise SystemExit(0)
root = Path(__file__).resolve().parents[1]
s = (root / 'PsychMetalRecord.h').read_text()
a = s.index('static void commitRecordedFile(')
commit = s[a:s.index('\n}\n', a) + 3]
assert 'fileURLWithPath:r->stagingPath' in s
assert 'removeItemAtURL:url error:nil' not in s
code = r'''
#import <Foundation/Foundation.h>
#include "PsychMetalEngine.h"
#include <cassert>
#include <cstdio>
#include <cerrno>
#include <cstring>
#include <fstream>
#include <stdexcept>
struct PMRecorder { NSString *stagingPath=nil, *finalPath=nil; std::string path; };
void failWith(const char *, const char *, ...) { throw std::runtime_error("commit failed"); }
''' + commit + r'''
std::string read(const char *path) {
    std::ifstream in(path);
    return std::string(std::istreambuf_iterator<char>(in), {});
}
int main(int argc, char **argv) { @autoreleasepool {
    assert(argc == 2);
    PMRecorder r;
    r.finalPath = [[NSString stringWithUTF8String:argv[1]] stringByAppendingString:@"/export.mov"];
    r.stagingPath = [r.finalPath stringByAppendingString:@".staging"];
    r.path = r.finalPath.UTF8String;
    { std::ofstream old(r.finalPath.fileSystemRepresentation); old << "previous export"; }
    bool failed=false;
    try { commitRecordedFile(&r); } catch(const std::runtime_error &) { failed=true; }
    assert(failed && read(r.finalPath.fileSystemRepresentation) == "previous export" && r.stagingPath);
    { std::ofstream staged(r.stagingPath.fileSystemRepresentation); staged << "completed export"; }
    commitRecordedFile(&r);
    assert(!r.stagingPath && read(r.finalPath.fileSystemRepresentation) == "completed export");
} }
'''
with tempfile.TemporaryDirectory(prefix='psychmetal-recording-file-') as temp:
    p = Path(temp)
    (p / 'test.mm').write_text(code)
    subprocess.run(['clang++', '-std=c++17', '-fobjc-arc', '-fsanitize=address,undefined',
                    '-iquote', str(root), '-framework', 'Foundation', str(p / 'test.mm'),
                    '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test'), str(p)], check=True)
print('PASS: failed export preserves the existing file; successful export replaces it atomically.')
