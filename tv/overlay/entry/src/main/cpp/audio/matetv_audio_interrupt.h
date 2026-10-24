#ifndef MATETV_AUDIO_INTERRUPT_H
#define MATETV_AUDIO_INTERRUPT_H
#include <atomic>
#include <cstdint>

namespace MateTv {
// The platform callback only publishes events. Renderer operations run on the
// foreground control thread; an older completion must not consume a newer hint.
class AudioInterruptRecovery {
public:
    void pause() { replace(Paused); }
    void stop() { replace(Stopped); }
    void resume() {
        uint64_t previous = state_.load();
        while ((previous & 7U) == Paused) {
            if (state_.compare_exchange_weak(previous, next(previous, Pending))) { return; }
        }
    }
    bool blocksPlayback() const { return (state_.load() & 7U) != Idle; }
    uint64_t claim(bool foreground, bool muted) {
        if (!foreground || muted) { return 0; }
        uint64_t previous = state_.load();
        while ((previous & 7U) == Pending) {
            const uint64_t claimed = next(previous, Starting);
            if (state_.compare_exchange_weak(previous, claimed)) { return claimed; }
        }
        return 0;
    }
    bool current(uint64_t token) const { return token != 0 && state_.load() == token; }
    void finish(uint64_t token, bool success) {
        if (token == 0) { return; }
        // Failure does not create a periodic focus-grabbing retry loop.
        state_.compare_exchange_strong(token, next(token, success ? Idle : Paused));
    }
private:
    enum Phase : uint64_t { Idle = 0, Paused = 1, Pending = 2, Starting = 3, Stopped = 4 };
    std::atomic<uint64_t> state_ {Idle};
    static uint64_t next(uint64_t value, Phase phase) { return ((value & ~uint64_t(7)) + 8) | phase; }
    void replace(Phase phase) {
        uint64_t previous = state_.load();
        while (!state_.compare_exchange_weak(previous, next(previous, phase))) {}
    }
};
}
#endif
