"""Execute the generated native interruption handlers with a synchronous platform mock."""
from pathlib import Path
import argparse
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--client', type=Path, default=root / '.work/client')
client = parser.parse_args().client
source = (client / 'entry/src/main/cpp/audio/audio_player.cpp').read_text()
start = source.index('void AudioPlayer::OnInterrupt(')
handlers = source[start:source.index('void AudioPlayer::Pause() {', start)]
accept_start = source.index('bool AudioPlayer::CanAcceptPcm() const {')
accept_method = source[accept_start:source.index('size_t AudioPlayer::FrameBytes()', accept_start)]
dispatch_start = source.index('    auto playerLease = g_audioRegistry.acquire(handle, owner);',
                              source.index('int AudioPlayerNapi::DispatchActiveNative(\n'))
dispatch = source[dispatch_start:source.index('    playerLease = {};', dispatch_start)]
# Keep the integration gates under test as well as the event state machine.
assert 'OH_AudioStreamBuilder_SetRendererInterruptCallback(' in source
assert 'builder, AudioPlayer::OnWriteData, callbackContext_.get());' in source
assert 'OH_AudioStreamBuilder_SetRendererCallback(' not in source
assert 'if (interruptRecovery_.blocksPlayback()) { return static_cast<int>(size); }' in source
resume = source[source.index('void AudioPlayer::Resume() {'):source.index('void AudioPlayer::Stop() {')]
assert 'if (interruptRecovery_.blocksPlayback()) { return; }' in resume
assert 'foreground && AudioFocusAllows(owner)' in source

program = r'''
#include "matetv_audio_interrupt.h"
#include <cassert>
#include <functional>
#include <memory>
#include <mutex>
#include <vector>
#define LOG_APP 0
#define OH_LOG_INFO(...) ((void)0)
enum OH_AudioInterrupt_ForceType { AUDIOSTREAM_INTERRUPT_FORCE, AUDIOSTREAM_INTERRUPT_SHARE };
enum OH_AudioInterrupt_Hint { NONE, AUDIOSTREAM_INTERRUPT_HINT_RESUME, AUDIOSTREAM_INTERRUPT_HINT_PAUSE,
    AUDIOSTREAM_INTERRUPT_HINT_STOP, DUCK, UNDUCK };
enum OH_AudioStream_State { AUDIOSTREAM_STATE_RUNNING, AUDIOSTREAM_STATE_PAUSED };
constexpr int AUDIOSTREAM_SUCCESS = 0;
struct OH_AudioRenderer {
    OH_AudioStream_State state = AUDIOSTREAM_STATE_RUNNING;
    int starts = 0, pauses = 0, result = 0;
    std::function<void()> onStart;
};
int OH_AudioRenderer_GetCurrentState(OH_AudioRenderer* renderer, OH_AudioStream_State* state) {
    *state = renderer->state; return 0;
}
int OH_AudioRenderer_Start(OH_AudioRenderer* renderer) {
    ++renderer->starts;
    renderer->state = AUDIOSTREAM_STATE_RUNNING;
    if (renderer->onStart) { renderer->onStart(); }
    return renderer->result;
}
int OH_AudioRenderer_Pause(OH_AudioRenderer* renderer) {
    ++renderer->pauses; renderer->state = AUDIOSTREAM_STATE_PAUSED; return 0;
}
namespace Render {
struct Snapshot { int token = 1, owner = 1; };
struct CallbackLease {
    bool valid;
    explicit operator bool() const { return valid; }
    Snapshot snapshot() const { return {}; }
};
struct CallbackAdmissionContext {
    bool open = true;
    CallbackLease tryAcquire() { return {open}; }
};
struct OwnerRegistry {
    bool valid = true;
    bool acquire(int) { return valid; }
};
OwnerRegistry& SharedSessionSinkOwnerLease() { static OwnerRegistry registry; return registry; }
}
struct Activity {
    bool muted = false;
    int resumed = 0;
    bool isMuted() const { return muted; }
    void markResumed() { ++resumed; }
};
enum class AudioPlayerState { RUNNING, PAUSED, RELEASED };
class AudioPlayer {
public:
    OH_AudioRenderer native;
    OH_AudioRenderer* renderer_ = &native;
    mutable std::mutex lifecycleMutex_;
    std::mutex bufferMutex_;
    bool destroying_ = false, rendererStopped_ = false, suspendedForInactivity_ = false, prebuffering_ = false;
    AudioPlayerState state_ = AudioPlayerState::RUNNING;
    std::shared_ptr<Activity> activity_ = std::make_shared<Activity>();
    MateTv::AudioInterruptRecovery interruptRecovery_;
    std::vector<unsigned char> pcmBuffer_ {1,2,3,4};
    size_t pcmReadOffset_ = 2;
    int writes = 0;
    int SampleRate() const { return 48000; }
    int Channels() const { return 2; }
    int Write(const unsigned char*, size_t size) { ++writes; return static_cast<int>(size); }
    bool CanAcceptPcm() const;
    bool IsSystemInterrupted() const { return interruptRecovery_.blocksPlayback(); }
    static void OnInterrupt(OH_AudioRenderer*, void*, OH_AudioInterrupt_ForceType, OH_AudioInterrupt_Hint);
    void PollInterruptRecovery(bool foreground);
};
struct PlayerRegistry {
    AudioPlayer* player = nullptr;
    AudioPlayer* acquire(int, int) { return player; }
} g_audioRegistry;
HANDLERS
ACCEPT_METHOD
int dispatchPcm(int safeRate = 48000, int safeChannels = 2) {
    int handle = 1, owner = 1;
    const unsigned char* data = nullptr;
    size_t writableSize = 1920;
    DISPATCH
    return -999; // The production path would destroy/recreate the existing player here.
}
struct Fixture {
    AudioPlayer player;
    Render::CallbackAdmissionContext context;
    Fixture() { g_audioRegistry.player = &player; Render::SharedSessionSinkOwnerLease().valid = true; }
    void hint(OH_AudioInterrupt_Hint hint) {
        AudioPlayer::OnInterrupt(&player.native, &context, AUDIOSTREAM_INTERRUPT_FORCE, hint);
    }
};
int main() {
    { // Stray resume/duck cannot start sound.
        Fixture f; f.hint(AUDIOSTREAM_INTERRUPT_HINT_RESUME); f.hint(DUCK); f.hint(UNDUCK);
        f.player.PollInterruptRecovery(true); assert(f.player.native.starts == 0);
    }
    { // Resume permission survives a background period but cannot start there.
        Fixture f; f.hint(AUDIOSTREAM_INTERRUPT_HINT_PAUSE);
        f.player.PollInterruptRecovery(false); assert(f.player.native.state == AUDIOSTREAM_STATE_PAUSED);
        f.hint(AUDIOSTREAM_INTERRUPT_HINT_RESUME);
        f.player.PollInterruptRecovery(false); assert(f.player.native.starts == 0);
        f.player.PollInterruptRecovery(true); assert(f.player.native.starts == 1);
        assert(f.player.pcmBuffer_.empty() && f.player.pcmReadOffset_ == 0 && f.player.prebuffering_);
        f.player.PollInterruptRecovery(true); assert(f.player.native.starts == 1);
    }
    { // User mute is independent of platform resume.
        Fixture f; f.player.activity_->muted = true;
        f.hint(AUDIOSTREAM_INTERRUPT_HINT_PAUSE); f.hint(AUDIOSTREAM_INTERRUPT_HINT_RESUME);
        f.player.PollInterruptRecovery(true); assert(f.player.native.starts == 0);
        f.player.activity_->muted = false; f.player.PollInterruptRecovery(true);
        assert(f.player.native.starts == 1);
    }
    { // A system STOP never converts into an automatic restart.
        Fixture f; f.hint(AUDIOSTREAM_INTERRUPT_HINT_STOP); f.hint(AUDIOSTREAM_INTERRUPT_HINT_RESUME);
        f.player.PollInterruptRecovery(true); assert(f.player.native.starts == 0);
    }
    { // Start synchronously re-enters the interrupt callback while lifecycleMutex is held.
        Fixture f; f.hint(AUDIOSTREAM_INTERRUPT_HINT_PAUSE); f.hint(AUDIOSTREAM_INTERRUPT_HINT_RESUME);
        f.player.native.onStart = [&] { f.hint(AUDIOSTREAM_INTERRUPT_HINT_PAUSE); };
        f.player.PollInterruptRecovery(true);
        assert(f.player.interruptRecovery_.blocksPlayback());
        assert(f.player.native.state == AUDIOSTREAM_STATE_PAUSED);
        f.player.PollInterruptRecovery(true); assert(f.player.native.starts == 1);
        f.player.native.onStart = nullptr; f.hint(AUDIOSTREAM_INTERRUPT_HINT_RESUME);
        f.player.PollInterruptRecovery(true); assert(f.player.native.starts == 2);
    }
    { // Failed Start consumes its permission, without retrying every timer tick.
        Fixture f; f.player.native.result = -1;
        f.hint(AUDIOSTREAM_INTERRUPT_HINT_PAUSE); f.hint(AUDIOSTREAM_INTERRUPT_HINT_RESUME);
        for (int n=0; n<10; n++) { f.player.PollInterruptRecovery(true); }
        assert(f.player.native.starts == 1 && f.player.interruptRecovery_.blocksPlayback());
    }
    { // Teardown and stale callbacks cannot mutate a new/live player.
        Fixture f; f.context.open = false; f.hint(AUDIOSTREAM_INTERRUPT_HINT_PAUSE);
        assert(!f.player.interruptRecovery_.blocksPlayback());
        f.context.open = true; Render::SharedSessionSinkOwnerLease().valid = false;
        f.hint(AUDIOSTREAM_INTERRUPT_HINT_PAUSE); assert(!f.player.interruptRecovery_.blocksPlayback());
        Render::SharedSessionSinkOwnerLease().valid = true;
        f.hint(AUDIOSTREAM_INTERRUPT_HINT_PAUSE); f.hint(AUDIOSTREAM_INTERRUPT_HINT_RESUME);
        f.player.destroying_ = true; f.player.PollInterruptRecovery(true);
        assert(f.player.native.starts == 0);
    }
    { // A newer pause between claiming and finishing cannot be erased.
        MateTv::AudioInterruptRecovery state; state.pause(); state.resume();
        auto old = state.claim(true,false); assert(old); state.pause();
        state.finish(old,true); assert(state.blocksPlayback()); assert(state.claim(true,false)==0);
    }
    { // Inactivity suspension after system pause must not rebuild and lose its recovery gate.
        Fixture f; f.hint(AUDIOSTREAM_INTERRUPT_HINT_PAUSE);
        f.player.state_ = AudioPlayerState::PAUSED; f.player.suspendedForInactivity_ = true;
        assert(dispatchPcm() == 1920); assert(f.player.native.starts == 0);
        assert(f.player.interruptRecovery_.blocksPlayback());
        // Even a format change must wait for system permission before replacing the renderer.
        assert(dispatchPcm(44100,1) == 1920);
        assert(f.player.interruptRecovery_.blocksPlayback());
        f.hint(AUDIOSTREAM_INTERRUPT_HINT_RESUME); f.player.PollInterruptRecovery(true);
        assert(!f.player.interruptRecovery_.blocksPlayback());
        assert(dispatchPcm(44100,1) == -999);
    }
    { // A same-format paused or user-muted instance is retained; only teardown invalidates it.
        Fixture f; f.player.state_ = AudioPlayerState::PAUSED; f.player.activity_->muted = true;
        assert(dispatchPcm() == 1920); assert(f.player.native.starts == 0);
        f.player.destroying_ = true; assert(dispatchPcm() == -999);
    }
}
'''.replace('HANDLERS', handlers).replace('ACCEPT_METHOD', accept_method).replace('DISPATCH', dispatch)
output = root / '.work/tv-audio-interrupt-test.cpp'
output.write_text(program)
binary = output.with_suffix('')
subprocess.run(['c++', '-std=c++17', '-pthread',
    '-I' + str(root / 'tv/overlay/entry/src/main/cpp/audio'), str(output), '-o', str(binary)], check=True)
subprocess.run([str(binary)], check=True, timeout=10)
print('Native audio resume requires a valid hint, foreground and unmuted owner; reentrant pause and teardown are safe.')
