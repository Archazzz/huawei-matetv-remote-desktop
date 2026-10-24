"""Run the actual native keyframe signal expressions against the queue controller."""
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[1]
cpp = root / '.work/client/entry/src/main/cpp'
source = (cpp / 'render/hw_decoder.cpp').read_text()
# Extract the production expressions so the test catches a missing return signal,
# not just a correct queue policy whose caller ignores it.
request = re.search(r'        requestKeyframe = !requestAlreadyPending[\s\S]*?;', source).group()
block = source[source.index('    if (droppedIncomingForKeyframe) {'):source.index('    if (droppedIncomingForCapacity) {', source.index('    if (droppedIncomingForKeyframe) {'))]
result = re.search(r'        return ([^;]+);', block).group(1)
program = r'''
#include "render/video_backpressure_controller.h"
#include <cassert>
class Harness {
    Render::VideoBackpressureController backpressure_{3};
public:
    int submit(int queued, bool key) {
        constexpr int kDecodeKeyframeRequired = 1;
        bool requestKeyframe = false;
        const bool requestAlreadyPending = backpressure_.shouldRequestKeyframe();
        const auto admission = backpressure_.admitFrame(queued, key);
        REQUEST
        if (admission == Render::VideoFrameAdmission::DropAndWaitForKeyframe ||
            admission == Render::VideoFrameAdmission::DropWaitingKeyframe) return RESULT;
        return requestKeyframe ? kDecodeKeyframeRequired : 0;
    }
};
int main() {
    Harness decoder;
    assert(decoder.submit(0,false) == 0);
    assert(decoder.submit(3,false) == 1); // overflow MUST request a new IDR
    for (int i=0; i<100; ++i) assert(decoder.submit(0,false) == 0); // no refresh storm
    assert(decoder.submit(0,true) == 0); // fresh keyframe releases the gate
    assert(decoder.submit(1,false) == 0);
    assert(decoder.submit(3,false) == 1); // next independent overload can recover
}
'''.replace('REQUEST', request).replace('RESULT', result)
output = root / '.work/tv-decoder-recovery-test.cpp'
output.write_text(program)
binary = output.with_suffix('')
subprocess.run(['c++','-std=c++17','-pthread','-I'+str(cpp),str(output),str(cpp/'render/video_backpressure_controller.cpp'),'-o',str(binary)],check=True)
subprocess.run([str(binary)],check=True)
print('Native overflow requests one keyframe; resumes after IDR; repeated overflow recovers.')

# Exercise the actual lock-miss branch: dropping a compressed reference frame
# must ask RustDesk for a new IDR, while the generation-owned caller retains its
# existing backpressure contract.
start = source.index('    if (!pipelineLock.owns_lock()) {', source.index('OwnedDecodeOutcome DecodeNativeForOwnerOutcome'))
end = source.index('\n    if (!decoderLease->ownerActive', start)
branch = source[start:end]
program = r'''
#include <cassert>
#include <mutex>
#include <initializer_list>
#define LOG_APP 0
#define OH_LOG_DEBUG(...) ((void)0)
enum class CodecType { H264, H265, VP9 };
namespace DecoderNapi {
constexpr int kDecodeHardwareKeyframeRequired = 2;
enum class OwnedSubmitStatus { Backpressure, NeedKeyframe };
}
struct Outcome { int legacy; DecoderNapi::OwnedSubmitStatus status; };
struct Frame { CodecType codec; };
Outcome miss(unsigned expectedDecoderGeneration, CodecType codec) {
    std::mutex mutex;
    std::unique_lock<std::mutex> pipelineLock(mutex, std::defer_lock);
    Frame frame {codec};
    BRANCH
    assert(false);
    return {};
}
int main() {
    for (auto codec : {CodecType::H264, CodecType::H265}) {
        auto out = miss(0,codec);
        assert(out.legacy == DecoderNapi::kDecodeHardwareKeyframeRequired);
        assert(out.status == DecoderNapi::OwnedSubmitStatus::NeedKeyframe);
        assert(miss(42,codec).status == DecoderNapi::OwnedSubmitStatus::Backpressure);
    }
    assert(miss(0,CodecType::VP9).legacy == -1);
}
'''.replace('BRANCH', branch)
output.write_text(program)
subprocess.run(['c++','-std=c++17','-pthread',str(output),'-o',str(binary)],check=True)
subprocess.run([str(binary)],check=True)
print('H.264/H.265 ownership contention requests a keyframe; generation-owned contract preserved.')
