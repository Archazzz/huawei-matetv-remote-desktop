#pragma once
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace MateTv {
// Control threads only publish targetDb_. Envelope state belongs exclusively to
// the renderer's serialized PCM callback. No system or device volume is touched.
class RemoteAudioGain {
public:
    static constexpr float kMaxDb = 60.0f;
    static constexpr float kPeakCeiling = 29490.0f; // 90% of positive S16 full scale.

    bool setDb(float db) {
        if (!std::isfinite(db) || db < 0.0f || db > kMaxDb) { return false; }
        targetDb_.store(db, std::memory_order_relaxed);
        return true;
    }

    void process(uint8_t* bytes, size_t length, int channels, int sampleRate) {
        if (!bytes || channels < 1 || channels > 8 || sampleRate < 1000 || sampleRate > 384000) { return; }
        const float db = targetDb_.load(std::memory_order_relaxed);
        if (db == 0.0f) {
            // Default/reset is bit-exact, including full-scale input and trailing bytes.
            requestedScale_ = 1.0f;
            limiterScale_ = 1.0f;
            return;
        }
        const float target = std::pow(10.0f, db / 20.0f);
        const float rise = std::exp(-1.0f / (0.020f * sampleRate));
        const float release = std::exp(-1.0f / (0.200f * sampleRate));
        const size_t frameBytes = static_cast<size_t>(channels) * 2;
        for (size_t offset = 0; offset + frameBytes <= length; offset += frameBytes) {
            requestedScale_ = target < requestedScale_ ? target :
                target + (requestedScale_ - target) * rise;
            int32_t peak = 0;
            for (int channel = 0; channel < channels; ++channel) {
                peak = std::max(peak, std::abs(read(bytes + offset + channel * 2)));
            }
            const float allowed = peak == 0 ? 1.0f :
                std::min(1.0f, kPeakCeiling / (peak * requestedScale_));
            // Immediate linked attenuation prevents a transient overshoot. Recovery
            // is gradual so a single peak cannot pump gain back up next sample.
            limiterScale_ = std::min(allowed, 1.0f + (limiterScale_ - 1.0f) * release);
            const float scale = requestedScale_ * limiterScale_;
            for (int channel = 0; channel < channels; ++channel) {
                uint8_t* sample = bytes + offset + channel * 2;
                const int32_t value = static_cast<int32_t>(std::lround(read(sample) * scale));
                const uint16_t encoded = static_cast<uint16_t>(value);
                sample[0] = static_cast<uint8_t>(encoded & 255U);
                sample[1] = static_cast<uint8_t>(encoded >> 8);
            }
        }
    }

private:
    std::atomic<float> targetDb_ {0.0f};
    float requestedScale_ = 1.0f;
    float limiterScale_ = 1.0f;
    static int32_t read(const uint8_t* sample) {
        const uint32_t raw = sample[0] | (uint32_t(sample[1]) << 8);
        return raw >= 32768 ? static_cast<int32_t>(raw) - 65536 : static_cast<int32_t>(raw);
    }
};
}
