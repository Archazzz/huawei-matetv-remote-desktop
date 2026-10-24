#include "../tv/overlay/entry/src/main/cpp/render/matetv_decode_quality.h"
#include <cassert>
#include <cstdint>
int main() {
    int w, h;
    MateTv::outputSize(5120,1440,2,w,h); assert(w == 5120 && h == 1440);
    MateTv::outputSize(3840,2160,2,w,h); assert(w == 3840 && h == 2160);
    MateTv::outputSize(1440,2560,2,w,h); assert(w == 1440 && h == 2560);
    MateTv::outputSize(1920,1080,1,w,h); assert(w == 1600 && h == 900);
    MateTv::outputSize(5120,1440,0,w,h); assert(w == 1600 && h == 450);
    MateTv::outputSize(7680,4320,2,w,h); assert(w == 3840 && h == 2160);
    MateTv::outputSize(2000000000,100,2,w,h); assert(w <= 8192 && h >= 2);
    assert(static_cast<int64_t>(w) * h <= 3840 * 2160);
    MateTv::setDecodeQuality(2); assert(MateTv::decodeQuality.load() == 2);
    MateTv::setDecodeQuality(1); assert(MateTv::decodeQuality.load() == 1);
    MateTv::outputSize(1281,721,2,w,h); assert(w == 1281 && h == 721);
    MateTv::outputSize(0,0,2,w,h); assert(w == 0 && h == 0);
}
