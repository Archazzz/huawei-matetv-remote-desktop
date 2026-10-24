#ifndef MATETV_DECODE_QUALITY_H
#define MATETV_DECODE_QUALITY_H
#include <algorithm>
#include <atomic>
#include <cmath>

// The TV app owns one active desktop session. A live quality change is read
// atomically by the software presentation worker on its next frame.
namespace MateTv {
inline std::atomic<int> decodeQuality {1};
inline void setDecodeQuality(int quality) {
    decodeQuality.store(quality == 2 ? 2 : 1, std::memory_order_relaxed);
}
inline void outputSize(int width, int height, int quality, int& outWidth, int& outHeight) {
    outWidth = width;
    outHeight = height;
    if (width <= 0 || height <= 0) return;
    const double edgeLimit = quality == 2 ? 8192.0 : 1600.0;
    // Bound a BGRA frame to ~32 MiB. Both 4K and 5120x1440 keep source pixels.
    const double pixelLimit = quality == 2 ? 3840.0 * 2160.0 : 1600.0 * 1600.0;
    const double scale = std::min({1.0, edgeLimit / std::max(width, height),
        std::sqrt(pixelLimit / (static_cast<double>(width) * height))});
    if (scale >= 1.0) return;
    outWidth = std::max(2, static_cast<int>(width * scale) & ~1);
    outHeight = std::max(2, static_cast<int>(height * scale) & ~1);
}
}
#endif
