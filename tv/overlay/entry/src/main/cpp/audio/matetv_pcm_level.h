#pragma once
#include <cstddef>
#include <cstdint>
#include <cmath>

namespace MateTv {
struct PcmLevel { uint32_t peak = 0; uint32_t rms = 0; };
// Signed 16-bit little-endian PCM. Retain no waveform or notification content.
inline PcmLevel pcmLevel(const uint8_t* bytes, size_t length) {
    PcmLevel result;
    if (!bytes) return result;
    const size_t samples = (length / 2 < 65536) ? length / 2 : 65536;
    uint64_t squares = 0;
    for (size_t i = 0; i < samples; ++i) {
        const uint32_t raw = bytes[i * 2] | (uint32_t(bytes[i * 2 + 1]) << 8);
        const int32_t value = raw >= 32768 ? int32_t(raw) - 65536 : int32_t(raw);
        const uint32_t amplitude = value < 0 ? -value : value;
        if (amplitude > result.peak) result.peak = amplitude;
        squares += uint64_t(amplitude) * amplitude;
    }
    if (samples) result.rms = static_cast<uint32_t>(std::sqrt(double(squares) / samples));
    return result;
}
}
