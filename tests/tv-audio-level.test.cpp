#include "../tv/overlay/entry/src/main/cpp/audio/matetv_pcm_level.h"
#include <cassert>
int main() {
    const uint8_t silence[] = {0,0,0,0};
    assert(MateTv::pcmLevel(silence,4).peak == 0);
    const uint8_t extrema[] = {0,128,255,127};
    auto level = MateTv::pcmLevel(extrema,4);
    assert(level.peak == 32768 && level.rms == 32767);
    const uint8_t unaligned[] = {99, 232,3, 24,252, 255};
    level = MateTv::pcmLevel(unaligned+1,5);
    assert(level.peak == 1000 && level.rms == 1000);
    assert(MateTv::pcmLevel(nullptr,100).peak == 0);
    assert(MateTv::pcmLevel(extrema,1).rms == 0);
}
